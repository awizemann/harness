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

    // MARK: Init

    init(
        builder: any XcodeBuilding,
        driver: any SimulatorDriving,
        agent: any AgentLooping,
        llm: any LLMClient,
        history: any RunHistoryStoring
    ) {
        self.builder = builder
        self.driver = driver
        self.agent = agent
        self.llm = llm
        self.history = history
    }

    // MARK: Run

    /// Run one goal end-to-end. The returned stream yields `RunEvent` values
    /// for the UI. Pass `approvals` only when `request.mode == .stepByStep`.
    nonisolated func run(
        _ request: GoalRequest,
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
        _ request: GoalRequest,
        approvals: AsyncStream<UserApproval>?,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws {
        await agent.reset()

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

        // Boot + install + launch.
        try await driver.boot(request.simulator)
        try await driver.install(build.appBundle, on: request.simulator)
        try await driver.launch(bundleID: build.bundleIdentifier, on: request.simulator)
        continuation.yield(.simulatorReady(request.simulator))

        // Approval-stream iterator (step mode only).
        var approvalIterator = approvals?.makeAsyncIterator()

        // Loop.
        var stepIndex = 1
        var history: [LLMTurn] = []
        var stepCount = 0
        var frictionCount = 0
        var verdict: Verdict?
        var summary = ""
        var wouldRealUserSucceed = false
        var totalUsage = TokenUsage.zero

        loop: while true {
            try Task.checkCancellation()

            if stepIndex > request.stepBudget {
                // Budget exhausted → blocked.
                verdict = .blocked
                summary = "step budget exhausted at step \(stepIndex - 1)"
                let f = FrictionEvent(step: stepIndex - 1, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionCount += 1
                break loop
            }
            if totalUsage.inputTokens >= request.tokenBudget {
                verdict = .blocked
                summary = "token budget exhausted at step \(stepIndex - 1)"
                let f = FrictionEvent(step: stepIndex - 1, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionCount += 1
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

            let stepStarted = ContinuousClock().now

            // Compress screenshot for the LLM call.
            let jpegForLLM = Self.downscaleJPEG(screenshotData,
                                                 toPointSize: request.simulator.pointSize)
                ?? screenshotData

            // Decision.
            let decision: AgentDecision
            do {
                decision = try await agent.step(state: AgentLoopState(
                    request: request,
                    stepIndex: stepIndex,
                    history: history,
                    currentScreenshotJPEG: jpegForLLM,
                    tokensUsedSoFar: totalUsage
                ))
            } catch let e as AgentLoopError {
                // Loop-internal failure → emit `agent_blocked` friction and end.
                verdict = .blocked
                summary = Self.summary(for: e)
                let f = FrictionEvent(step: stepIndex, kind: .agentBlocked, detail: summary)
                try? await logger.append(.friction(FrictionPayload(
                    step: f.step, frictionKind: f.kind.rawValue, detail: f.detail
                )))
                continuation.yield(.frictionEmitted(f))
                frictionCount += 1
                break loop
            }

            continuation.yield(.toolProposed(step: stepIndex, toolCall: decision.toolCall))
            try await logger.append(.toolCall(step: stepIndex, call: decision.toolCall))

            // Approval gate (step mode only).
            var userDecision: UserDecision = .approved
            var userNote: String?
            if request.mode == .stepByStep {
                continuation.yield(.awaitingApproval(step: stepIndex, toolCall: decision.toolCall))
                guard var iter = approvalIterator else {
                    throw RunCoordinatorError.missingApprovalStream
                }
                guard let next = await iter.next() else {
                    throw CancellationError()
                }
                approvalIterator = iter
                switch next {
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
                frictionCount += 1
            }

            // Update token usage for cycle/budget tracking.
            totalUsage = TokenUsage(
                inputTokens: totalUsage.inputTokens + decision.usage.inputTokens,
                outputTokens: totalUsage.outputTokens + decision.usage.outputTokens,
                cacheReadInputTokens: totalUsage.cacheReadInputTokens + decision.usage.cacheReadInputTokens,
                cacheCreationInputTokens: totalUsage.cacheCreationInputTokens + decision.usage.cacheCreationInputTokens
            )

            // Step completed event.
            let stepDuration = ContinuousClock().now - stepStarted
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

            stepCount = stepIndex

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

            // Terminal tool: mark_goal_done.
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
                frictionCount += 1
                break loop
            }

            stepIndex += 1
        }

        // Wrap up.
        let outcome = RunOutcome(
            verdict: verdict ?? .blocked,
            summary: summary.isEmpty ? "ended without explicit verdict" : summary,
            frictionCount: frictionCount,
            wouldRealUserSucceed: wouldRealUserSucceed,
            stepCount: stepCount,
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

        continuation.yield(.runCompleted(outcome))
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
