//
//  RunCoordinator.swift
//  Harness
//
//  Orchestrator for one run, end-to-end. Wires:
//    XcodeBuilder → SimulatorDriver (boot/install/launch)
//    AgentLoop ↔ ClaudeClient (per-step decision)
//    SimulatorDriver (action execution + screenshot capture)
//    RunLogger (JSONL append + screenshot dump)
//    RunHistoryStore (skeleton-first SwiftData record + outcome update)
//
//  Exposes `run(_:)` which returns an `AsyncThrowingStream<RunEvent>` so the
//  view-model layer (Phase 3) can mirror the live state. In step mode, the
//  caller injects an `AsyncStream<UserApproval>` to drive the approval gate.
//
//  Per `standards/13-agent-loop.md`. The loop algorithm itself lives in
//  `AgentLoop`; this file owns the side-effecting pieces (process invocation,
//  filesystem writes, SwiftData updates) and the per-step bookkeeping.
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Coordinator

actor RunCoordinator {

    private static let logger = Logger(subsystem: "com.harness.app", category: "RunCoordinator")

    // MARK: Dependencies

    private let builder: any XcodeBuilding
    private let driver: any SimulatorDriving
    private let agent: any AgentLooping
    private let llm: any LLMClient
    private let history: any RunHistoryStoring
    private let windowController: any SimulatorWindowControlling
    private let hideSimulator: Bool

    /// Per-run iterator over the user-approval stream (step mode). The
    /// iterator's `next()` is `nonisolated`, so reading the iterator
    /// out of actor-isolated state would refuse to compile under Swift
    /// 6 strict concurrency. We mark this nonisolated(unsafe) — single
    /// run per coordinator means there's no real concurrency around
    /// this storage; reads/writes always come from inside `execute(...)`
    /// running on a single task.
    nonisolated(unsafe) private var approvalIterator: AsyncStream<UserApproval>.AsyncIterator?

    // MARK: Init

    init(
        builder: any XcodeBuilding,
        driver: any SimulatorDriving,
        agent: any AgentLooping,
        llm: any LLMClient,
        history: any RunHistoryStoring,
        windowController: any SimulatorWindowControlling = NoopWindowController(),
        hideSimulator: Bool = false
    ) {
        self.builder = builder
        self.driver = driver
        self.agent = agent
        self.llm = llm
        self.history = history
        self.windowController = windowController
        self.hideSimulator = hideSimulator
    }

    // MARK: Run

    /// Run one goal end-to-end. The returned stream yields `RunEvent` values
    /// for the UI. Pass `approvals` only when `request.mode == .stepByStep`.
    nonisolated func run(
        _ request: RunRequest,
        approvals: AsyncStream<UserApproval>? = nil
    ) -> AsyncThrowingStream<RunEvent, any Error> {
        AsyncThrowingStream<RunEvent, any Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    try await self.execute(request, approvals: approvals, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Execute

    private func execute(
        _ request: RunRequest,
        approvals: AsyncStream<UserApproval>?,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws {
        await agent.reset()

        // Stage the approval iterator for the run (step mode only).
        // Cleared at the end of the run so a stale iterator doesn't
        // leak into the next coordinator invocation.
        self.approvalIterator = approvals?.makeAsyncIterator()
        defer { self.approvalIterator = nil }

        // Skeleton-first SwiftData row (so the History view sees the run before it finishes).
        let skeleton = RunRecordSnapshot.skeleton(from: request)
        try? await history.upsert(skeleton)

        // Open the run logger.
        let logger = try await RunLogger.open(runID: request.id)
        defer { Task { await logger.close() } }

        try await logger.append(.runStarted(from: request))
        continuation.yield(.runStarted(request))

        // Build.
        continuation.yield(.buildStarted)
        let build = try await builder.build(
            project: request.project.path,
            scheme: request.project.scheme,
            runID: request.id
        )
        continuation.yield(.buildCompleted(appBundle: build.appBundle, bundleID: build.bundleIdentifier))

        // Lifecycle: cleanupWDA → boot → install → launch → startInputSession.
        //
        // WDA runs as `xcodebuild test-without-building` against the simulator;
        // a prior crash can leave an orphan xcodebuild process bound to the
        // same simulator. cleanupWDA pkills it before we boot so a fresh
        // session opens cleanly. (We migrated away from idb in Phase 5
        // because idb's HID injection no longer reaches the responder chain
        // on iOS 26+. WDA goes through XCUICoordinate.tap, which does.)
        await driver.cleanupWDA(udid: request.simulator.udid)
        try await driver.boot(request.simulator)
        try await driver.install(build.appBundle, on: request.simulator)
        try await driver.launch(bundleID: build.bundleIdentifier, on: request.simulator)
        try await driver.startInputSession(request.simulator)
        if hideSimulator {
            await windowController.hide()
        }
        continuation.yield(.simulatorReady(request.simulator))

        // From here down, the WDA input session is live. Whatever happens —
        // success, failure, cancellation — `endInputSession` must run before
        // we return so the xcodebuild test runner doesn't outlive the run.
        do {
            try await runAllLegs(
                request: request,
                build: build,
                approvals: approvals,
                continuation: continuation,
                logger: logger
            )
        } catch {
            await driver.endInputSession()
            if hideSimulator { await windowController.unhide() }
            throw error
        }
        await driver.endInputSession()
        if hideSimulator { await windowController.unhide() }
    }

    // MARK: - Leg orchestration

    /// Drive all legs of a run end-to-end. For `.singleAction` and
    /// `.ad_hoc` payloads, this runs exactly one leg. For `.chain`
    /// payloads, it runs each leg in order, reinstalling the app between
    /// legs whose `preservesState == false`, and short-circuits the
    /// remaining legs on the first failure/blocked verdict (writing
    /// `skipped` legs for the rest so the replay shape stays predictable).
    ///
    /// The token budget is enforced across the whole run; the step
    /// budget and cycle detector reset between legs (a leg starts with
    /// a clean window — the previous leg's "got stuck on the same
    /// screen" state shouldn't bleed into the next).
    private func runAllLegs(
        request: RunRequest,
        build: BuildResult,
        approvals: AsyncStream<UserApproval>?,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation,
        logger: RunLogger
    ) async throws {

        let legs = Self.expandedLegs(for: request)

        // Aggregate state across legs.
        var globalStepIndex = 1                  // 1-based, gap-free across all legs
        var totalUsage = TokenUsage.zero
        var totalFriction = 0
        var aggregateWRUS = false
        var aggregateVerdict: Verdict?
        var aggregateSummary = ""
        var legRecords: [LegRecord] = []
        // The approval iterator lives on `self` so successive legs
        // share progress without trying to pass an `AsyncIterator`
        // across actor isolation. See `execute(_:approvals:...)` for
        // setup.
        _ = approvals  // intentionally unused — see `self.approvalIterator`.

        for leg in legs {
            try Task.checkCancellation()

            // Reinstall + relaunch between legs when the chain step doesn't
            // preserve state. The first leg always inherits the install we
            // already did up in `execute()`, so `preservesState` on leg 0
            // is irrelevant.
            if leg.index > 0 && !leg.preservesState {
                try await driver.terminate(bundleID: build.bundleIdentifier, on: request.simulator)
                try await driver.install(build.appBundle, on: request.simulator)
                try await driver.launch(bundleID: build.bundleIdentifier, on: request.simulator)
            }

            // Reset the cycle detector and conversation history per leg.
            // The previous leg's screenshots / tool calls aren't relevant —
            // this leg has a fresh goal.
            await agent.reset()

            // Stamp leg_started and emit the in-process event.
            try? await logger.append(.legStarted(LegStartedPayload(
                leg: leg.index,
                actionName: leg.actionName,
                goal: leg.goal,
                preservesState: leg.preservesState
            )))
            continuation.yield(.legStarted(
                index: leg.index,
                actionName: leg.actionName,
                goal: leg.goal,
                preservesState: leg.preservesState
            ))

            // Drive the leg's loop. The leg sees the global token usage
            // (per-run total budget) but its own fresh step counter.
            let result: LegResult
            do {
                result = try await runLeg(
                    request: request,
                    leg: leg,
                    startStepIndex: globalStepIndex,
                    initialUsage: totalUsage,
                    continuation: continuation,
                    logger: logger
                )
            } catch {
                // Surface a synthesized leg_completed for the partial leg
                // so the JSONL stays well-formed, then rethrow.
                try? await logger.append(.legCompleted(LegCompletedPayload(
                    leg: leg.index,
                    verdict: Verdict.failure.rawValue,
                    summary: error.localizedDescription
                )))
                continuation.yield(.legCompleted(
                    index: leg.index,
                    verdict: .failure,
                    summary: error.localizedDescription
                ))
                throw error
            }

            // Roll up.
            globalStepIndex = result.nextGlobalStepIndex
            totalUsage = result.totalUsage
            totalFriction += result.frictionThisLeg
            aggregateWRUS = aggregateWRUS || result.wouldRealUserSucceed

            try? await logger.append(.legCompleted(LegCompletedPayload(
                leg: leg.index,
                verdict: (result.verdict ?? .blocked).rawValue,
                summary: result.summary
            )))
            continuation.yield(.legCompleted(
                index: leg.index,
                verdict: result.verdict,
                summary: result.summary
            ))

            legRecords.append(LegRecord(
                id: leg.id,
                index: leg.index,
                actionName: leg.actionName,
                goal: leg.goal,
                preservesState: leg.preservesState,
                verdictRaw: (result.verdict ?? .blocked).rawValue,
                summary: result.summary
            ))
            await persistLegRecords(legRecords, runID: request.id, isChain: legs.count > 1)

            // Decide whether to short-circuit the remaining legs.
            switch result.verdict {
            case .some(.success):
                // Keep going.
                aggregateSummary = result.summary
            case .some(.failure):
                aggregateVerdict = .failure
                aggregateSummary = result.summary
                try await synthesizeSkippedLegs(
                    after: leg.index,
                    in: legs,
                    accumulator: &legRecords,
                    runID: request.id,
                    logger: logger,
                    continuation: continuation,
                    isChain: legs.count > 1
                )
                break
            case .some(.blocked):
                aggregateVerdict = .blocked
                aggregateSummary = result.summary
                try await synthesizeSkippedLegs(
                    after: leg.index,
                    in: legs,
                    accumulator: &legRecords,
                    runID: request.id,
                    logger: logger,
                    continuation: continuation,
                    isChain: legs.count > 1
                )
                break
            case .none:
                // Treat missing verdict as blocked.
                aggregateVerdict = .blocked
                aggregateSummary = result.summary.isEmpty ? "ended without explicit verdict" : result.summary
                try await synthesizeSkippedLegs(
                    after: leg.index,
                    in: legs,
                    accumulator: &legRecords,
                    runID: request.id,
                    logger: logger,
                    continuation: continuation,
                    isChain: legs.count > 1
                )
                break
            }

            // Bail out of the leg loop on any non-success verdict.
            if aggregateVerdict != nil {
                break
            }
        }

        // All legs succeeded → aggregate verdict is .success. Summary is
        // the last leg's summary (most recent context).
        if aggregateVerdict == nil {
            aggregateVerdict = .success
        }

        let outcome = RunOutcome(
            verdict: aggregateVerdict ?? .blocked,
            summary: aggregateSummary.isEmpty ? "ended without explicit verdict" : aggregateSummary,
            frictionCount: totalFriction,
            wouldRealUserSucceed: aggregateVerdict == .success && aggregateWRUS,
            stepCount: globalStepIndex - 1,
            tokensUsedInput: totalUsage.inputTokens,
            tokensUsedOutput: totalUsage.outputTokens,
            completedAt: Date()
        )

        try? await logger.append(.runCompleted(RunCompletedPayload(
            verdict: outcome.verdict.rawValue,
            summary: outcome.summary,
            frictionCount: outcome.frictionCount,
            wouldRealUserSucceed: outcome.wouldRealUserSucceed,
            stepCount: outcome.stepCount,
            tokensUsedInputTotal: outcome.tokensUsedInput,
            tokensUsedOutputTotal: outcome.tokensUsedOutput
        )))
        try? await logger.writeMeta(outcome, request: request)

        // Update history index.
        try? await self.history.markCompleted(id: request.id, outcome: outcome)
        await persistLegRecords(legRecords, runID: request.id, isChain: legs.count > 1)

        continuation.yield(.runCompleted(outcome))
    }

    /// Per-leg loop result. The orchestrator aggregates these across legs.
    private struct LegResult {
        let verdict: Verdict?
        let summary: String
        let wouldRealUserSucceed: Bool
        let frictionThisLeg: Int
        let stepsExecuted: Int
        /// Where the next leg should start its `globalStepIndex`. Equals
        /// `(last step seen) + 1`, or `startStepIndex` if no steps ran.
        let nextGlobalStepIndex: Int
        let totalUsage: TokenUsage
    }

    /// Wraps `ChainExecutor.expandedLegs` so the call site reads naturally
    /// inside the coordinator. Test code targets `ChainExecutor` directly.
    private static func expandedLegs(for request: RunRequest) -> [ChainLeg] {
        ChainExecutor.expandedLegs(for: request)
    }

    /// Pull one approval off the per-run iterator. Returns:
    ///   - `nil` when no approval stream was registered (caller is in
    ///     step mode but no stream was provided — error path).
    ///   - `.some(nil)` when the stream finished (cancelled).
    ///   - `.some(.some(approval))` for a delivered value.
    ///
    /// Lives on the actor so the iterator never crosses isolation. The
    /// double-optional return shape keeps the call site able to
    /// distinguish "no stream" from "stream ended" without throwing
    /// inside this helper.
    private func popNextApproval() async -> UserApproval?? {
        guard var iter = self.approvalIterator else { return nil }
        let value = await iter.next()
        self.approvalIterator = iter
        return .some(value)
    }


    /// Append `skipped` LegRecord entries (and matching JSONL rows) for
    /// every leg after `index`. Keeps the replay shape predictable.
    private func synthesizeSkippedLegs(
        after index: Int,
        in legs: [ChainLeg],
        accumulator: inout [LegRecord],
        runID: UUID,
        logger: RunLogger,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation,
        isChain: Bool
    ) async throws {
        for leg in legs where leg.index > index {
            try? await logger.append(.legStarted(LegStartedPayload(
                leg: leg.index,
                actionName: leg.actionName,
                goal: leg.goal,
                preservesState: leg.preservesState
            )))
            continuation.yield(.legStarted(
                index: leg.index,
                actionName: leg.actionName,
                goal: leg.goal,
                preservesState: leg.preservesState
            ))
            try? await logger.append(.legCompleted(LegCompletedPayload(
                leg: leg.index,
                verdict: "skipped",
                summary: "skipped — earlier leg ended the run"
            )))
            continuation.yield(.legCompleted(
                index: leg.index,
                verdict: nil,
                summary: "skipped"
            ))
            accumulator.append(LegRecord(
                id: leg.id,
                index: leg.index,
                actionName: leg.actionName,
                goal: leg.goal,
                preservesState: leg.preservesState,
                verdictRaw: "skipped",
                summary: "skipped — earlier leg ended the run"
            ))
        }
        await persistLegRecords(accumulator, runID: runID, isChain: isChain)
    }

    /// Persist a fresh `legsJSON` blob to the SwiftData row. No-op for
    /// single-leg / ad-hoc runs (we don't pollute the history index with
    /// trivial single-leg blobs).
    private func persistLegRecords(_ records: [LegRecord], runID: UUID, isChain: Bool) async {
        guard isChain else { return }
        let blob = (try? JSONEncoder().encode(records))
            .flatMap { String(data: $0, encoding: .utf8) }
        try? await self.history.updateLegsJSON(id: runID, legsJSON: blob)
    }

    // MARK: - Single-leg loop

    /// Drive one leg's agent loop. Lifted from the pre-Phase-E `runLoop`
    /// implementation; the orchestration around build/install/launch now
    /// lives in `runAllLegs`. Uses the leg's `goal` as the LLM `{{GOAL}}`
    /// substitution, so a chain run feeds different goals to the model
    /// across legs without otherwise changing the loop's algorithm.
    ///
    /// The approval source is taken as the original `AsyncStream` (not
    /// an iterator) — each leg makes its own iterator. AsyncStream is
    /// reference-typed under the hood, so iterators created from the
    /// same stream share buffer state and progress between legs without
    /// losing positions.
    private func runLeg(
        request: RunRequest,
        leg: ChainLeg,
        startStepIndex: Int,
        initialUsage: TokenUsage,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation,
        logger: RunLogger
    ) async throws -> LegResult {

        // Per-leg shadow request whose `goal` is the leg's prompt. The
        // simulator/persona/model/budgets all stay the same; the agent
        // sees the leg-specific `{{GOAL}}` substitution via the existing
        // PromptLibrary template substitution.
        let legRequest = RunRequest(
            id: request.id,
            name: request.name,
            goal: leg.goal,
            persona: request.persona,
            applicationID: request.applicationID,
            personaID: request.personaID,
            payload: request.payload,
            project: request.project,
            simulator: request.simulator,
            model: request.model,
            mode: request.mode,
            stepBudget: request.stepBudget,
            tokenBudget: request.tokenBudget
        )

        var stepIndex = startStepIndex                     // global, gap-free
        var stepInLeg = 1                                  // resets per leg
        var history: [LLMTurn] = []
        var stepsExecuted = 0
        var frictionThisLeg = 0
        var verdict: Verdict?
        var summary = ""
        var wouldRealUserSucceed = false
        var totalUsage = initialUsage

        loop: while true {
            try Task.checkCancellation()

            if stepInLeg > request.stepBudget {
                // Per-leg step budget exhausted → leg ends blocked. The
                // chain executor decides whether to continue or skip
                // remaining legs based on this leg's verdict.
                verdict = .blocked
                summary = "step budget exhausted at step \(stepIndex - 1)"
                let f = FrictionEvent(step: stepIndex - 1, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionThisLeg += 1
                break loop
            }
            if totalUsage.inputTokens >= request.tokenBudget {
                // Token budget is per-run total — once we hit it, no
                // further legs can run either.
                verdict = .blocked
                summary = "token budget exhausted at step \(stepIndex - 1)"
                let f = FrictionEvent(step: stepIndex - 1, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionThisLeg += 1
                break loop
            }

            // Capture screenshot. Write PNG before stepStarted row (per standard 08).
            let screenshotURL: URL
            let screenshotData: Data
            do {
                let url = HarnessPaths.screenshot(for: request.id, step: stepIndex)
                _ = try await driver.screenshot(request.simulator, into: url)
                screenshotURL = url
                screenshotData = (try? Data(contentsOf: url)) ?? Data()
            } catch {
                Self.logger.error("Screenshot failed at step \(stepIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }

            try await logger.append(.stepStarted(StepStartedPayload(
                step: stepIndex,
                screenshot: "step-\(String(format: "%03d", stepIndex)).png",
                tokensUsedSoFar: totalUsage.inputTokens
            )))
            continuation.yield(.stepStarted(
                step: stepIndex,
                screenshotPath: "step-\(String(format: "%03d", stepIndex)).png",
                screenshot: screenshotURL
            ))

            let stepStartedAt = ContinuousClock().now

            // Compress screenshot for the LLM call.
            let jpegForLLM = Self.downscaleJPEG(screenshotData,
                                                 toPointSize: request.simulator.pointSize)
                ?? screenshotData

            // Decision. The agent loop sees the leg's `goal` via the
            // `legRequest` shadow — every other field is the run-level
            // value. Step index passed in is global so the agent can
            // contextualize its rolling history.
            let decision: AgentDecision
            do {
                decision = try await agent.step(state: AgentLoopState(
                    request: legRequest,
                    stepIndex: stepIndex,
                    history: history,
                    currentScreenshotJPEG: jpegForLLM,
                    tokensUsedSoFar: totalUsage
                ))
            } catch let e as AgentLoopError {
                // Loop-internal failure → emit `agent_blocked` friction and end the leg.
                verdict = .blocked
                summary = Self.summary(for: e)
                let f = FrictionEvent(step: stepIndex, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionThisLeg += 1
                break loop
            }

            continuation.yield(.toolProposed(step: stepIndex, toolCall: decision.toolCall))
            try await logger.append(.toolCall(step: stepIndex, call: decision.toolCall))

            // Approval gate (step mode only).
            var userDecision: UserDecision = .approved
            var userNote: String?
            if request.mode == .stepByStep {
                continuation.yield(.awaitingApproval(step: stepIndex, toolCall: decision.toolCall))
                let pulled = await self.popNextApproval()
                switch pulled {
                case .none:
                    throw RunCoordinatorError.missingApprovalStream
                case .some(.none):
                    throw CancellationError()
                case .some(.some(let nextValue)):
                    switch nextValue {
                    case .approve:
                        userDecision = .approved
                    case .skip:
                        userDecision = .skipped
                    case .reject(let note):
                        userDecision = .rejected
                        userNote = note
                    case .stop:
                        throw CancellationError()
                    }
                }
            }

            // Execute (or skip) the tool.
            var executionSuccess = true
            var executionError: String?
            let execStart = ContinuousClock().now

            if userDecision == .approved {
                do {
                    try await Self.executeTool(decision.toolCall, on: request.simulator, driver: driver)
                } catch {
                    executionSuccess = false
                    executionError = error.localizedDescription
                }
            } else {
                executionSuccess = false
            }

            let execDuration = ContinuousClock().now - execStart
            let execMillis = Int(Self.milliseconds(execDuration))

            let result = ToolResult(
                success: executionSuccess,
                durationMs: execMillis,
                error: executionError,
                userDecision: request.mode == .stepByStep ? userDecision : nil,
                userNote: userNote
            )
            try await logger.append(.toolResult(ToolResultPayload(
                step: stepIndex,
                tool: decision.toolCall.tool.rawValue,
                success: result.success,
                durationMs: result.durationMs,
                error: result.error,
                userDecision: result.userDecision?.rawValue,
                userNote: result.userNote
            )))
            continuation.yield(.toolExecuted(step: stepIndex, toolCall: decision.toolCall, result: result))

            // Inline friction (note_friction in the same turn).
            if case .noteFriction(let kind, let detail) = decision.toolCall.input {
                let f = FrictionEvent(step: stepIndex, kind: kind, detail: detail)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionThisLeg += 1
            }

            // Update token usage for cycle/budget tracking.
            totalUsage = TokenUsage(
                inputTokens: totalUsage.inputTokens + decision.usage.inputTokens,
                outputTokens: totalUsage.outputTokens + decision.usage.outputTokens,
                cacheReadInputTokens: totalUsage.cacheReadInputTokens + decision.usage.cacheReadInputTokens,
                cacheCreationInputTokens: totalUsage.cacheCreationInputTokens + decision.usage.cacheCreationInputTokens
            )

            // Step completed event.
            let stepDuration = ContinuousClock().now - stepStartedAt
            try await logger.append(.stepCompleted(StepCompletedPayload(
                step: stepIndex,
                durationMs: Int(Self.milliseconds(stepDuration)),
                tokensInput: decision.usage.inputTokens,
                tokensOutput: decision.usage.outputTokens
            )))
            continuation.yield(.stepCompleted(
                step: stepIndex,
                durationMs: Int(Self.milliseconds(stepDuration)),
                tokensInput: decision.usage.inputTokens,
                tokensOutput: decision.usage.outputTokens
            ))

            stepsExecuted = stepInLeg

            // Append to history for the next iteration.
            let inputJSON = (try? LogRow.toolInputJSONString(decision.toolCall.input)) ?? "{}"
            history.append(LLMTurn(
                observation: decision.toolCall.observation,
                intent: decision.toolCall.intent,
                toolName: decision.toolCall.tool.rawValue,
                toolInputJSON: Data(inputJSON.utf8),
                screenshotJPEG: jpegForLLM,
                toolResultSummary: result.success ? "ok" : (result.error ?? "fail")
            ))

            // Terminal tool: mark_goal_done. This ends *the current leg*,
            // not necessarily the run — chain executor decides next.
            if case .markGoalDone(let v, let s, _, let wrus) = decision.toolCall.input {
                verdict = v
                summary = s
                wouldRealUserSucceed = wrus
                break loop
            }

            // Cycle detector check (post-step).
            do {
                try await agent.recordPostStep(screenshotJPEG: jpegForLLM, toolCall: decision.toolCall)
            } catch is AgentLoopError {
                verdict = .blocked
                summary = "cycle detected — agent stuck on the same screen for 3 turns"
                let f = FrictionEvent(step: stepIndex, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionThisLeg += 1
                break loop
            }

            stepIndex += 1
            stepInLeg += 1
        }

        return LegResult(
            verdict: verdict,
            summary: summary,
            wouldRealUserSucceed: wouldRealUserSucceed,
            frictionThisLeg: frictionThisLeg,
            stepsExecuted: stepsExecuted,
            nextGlobalStepIndex: stepsExecuted > 0 ? stepIndex + 1 : stepIndex,
            totalUsage: totalUsage
        )
    }

    // MARK: Tool execution

    private static func executeTool(_ call: ToolCall, on ref: SimulatorRef, driver: any SimulatorDriving) async throws {
        switch call.input {
        case .tap(let x, let y):
            try await driver.tap(at: CGPoint(x: x, y: y), on: ref)
        case .doubleTap(let x, let y):
            try await driver.doubleTap(at: CGPoint(x: x, y: y), on: ref)
        case .swipe(let x1, let y1, let x2, let y2, let ms):
            try await driver.swipe(
                from: CGPoint(x: x1, y: y1),
                to: CGPoint(x: x2, y: y2),
                duration: .milliseconds(ms),
                on: ref
            )
        case .type(let text):
            try await driver.type(text, on: ref)
        case .pressButton(let button):
            try await driver.pressButton(button, on: ref)
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .readScreen, .noteFriction, .markGoalDone:
            // Non-action tools: no driver call needed.
            return
        }
    }

    // MARK: Helpers

    private static func milliseconds(_ duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1_000_000_000_000_000.0
    }

    private static func summary(for error: AgentLoopError) -> String {
        switch error {
        case .parseFailureExhausted(let detail):
            return "parse-failure retries exhausted: \(detail)"
        case .tokenBudgetExhausted(let used, let budget):
            return "token budget exhausted (\(used)/\(budget))"
        case .stepBudgetExhausted(let budget):
            return "step budget exhausted (\(budget))"
        case .cycleDetected:
            return "cycle detected — agent stuck"
        }
    }

    /// Downscale a retina screenshot to **exactly the device's point dimensions**
    /// before sending to Claude. Returns nil to fall through to the original
    /// PNG bytes if AppKit can't decode the input.
    ///
    /// **Why exact point dimensions:** the model needs to emit tap coordinates
    /// in screen-point space (440 × 956 for iPhone 17 Pro Max). If we send a
    /// differently-sized image (say 1024 wide), the model can't compute the
    /// scale factor reliably and emits coordinates in image space — taps land
    /// off-target or outside the screen rect. By making image dimensions ==
    /// point dimensions, image-space and point-space are identical and the
    /// model's coordinates flow straight to `idb tap` without conversion.
    ///
    /// **Anthropic-side resize:** Claude Vision resizes images to fit within
    /// 1568px on the long edge before tokenization. Modern iPhone point
    /// resolutions max out at ~956 on the long edge, so we stay under that
    /// cap and the image isn't resized again on Anthropic's end. Bonus: ~3×
    /// cheaper per image vs the prior 1024-wide downsample.
    static func downscaleJPEG(_ data: Data, toPointSize pointSize: CGSize) -> Data? {
        #if canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        let targetSize = NSSize(width: pointSize.width, height: pointSize.height)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: targetSize))
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #else
        return nil
        #endif
    }
}

// MARK: - Errors

enum RunCoordinatorError: Error, Sendable, LocalizedError {
    case missingApprovalStream

    var errorDescription: String? {
        switch self {
        case .missingApprovalStream:
            return "Internal error: a step-by-step run was started without an approval stream."
        }
    }
}
