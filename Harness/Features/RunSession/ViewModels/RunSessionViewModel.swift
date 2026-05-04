//
//  RunSessionViewModel.swift
//  Harness
//
//  Drives `RunSessionView`. Consumes the `AsyncThrowingStream<RunEvent>` from
//  `RunCoordinator.run(_:approvals:)` and maps each event onto observable
//  state. Owns the screenshot poller (3 fps) for the live mirror.
//

import Foundation
import Observation
import SwiftUI
import os
#if canImport(AppKit)
import AppKit
#endif

@Observable
@MainActor
final class RunSessionViewModel {

    private static let logger = Logger(subsystem: "com.harness.app", category: "RunSessionViewModel")

    // MARK: Public state (read by views)

    var status: Status = .idle
    var request: GoalRequest?
    var liveImage: NSImage?
    var lastTapPoint: CGPoint?
    var feed: [PreviewStep] = []
    var frictionFeed: [PreviewFrictionEvent] = []
    var pendingApproval: PendingApproval?
    var elapsedSeconds: Int = 0
    var runError: String?
    /// Per-leg progress for chain runs. One entry per leg in declaration
    /// order. Populated from `RunRequest.payload` at run start; mutated as
    /// `.legStarted` / `.legCompleted` events arrive. For single-action and
    /// ad-hoc runs, this holds one entry mirroring the synthesized leg the
    /// coordinator emits. The session view hides the chain block entirely
    /// when `legProgress.count <= 1`.
    var legProgress: [LegProgress] = []
    /// 0-based index of the leg currently executing, or `nil` between legs.
    var currentLegIndex: Int?
    /// Latest goal text the agent is driving against. For chain runs this
    /// flips per leg; for single-action runs it's the request's goal.
    var currentGoal: String = ""
    /// Latest leg name (the chain step's `actionName`) the agent is on. For
    /// single-action runs this stays the action's name from the request.
    var currentLegName: String = ""

    /// One leg's status in the chain progress list. The session view maps
    /// this onto the existing `StatusChip` primitive.
    struct LegProgress: Sendable, Hashable, Identifiable {
        enum Status: Sendable, Hashable {
            case pending
            case running
            case done(Verdict)
            case skipped
        }
        let id: Int             // 0-based leg index
        let actionName: String
        let goal: String
        let preservesState: Bool
        var status: Status
    }
    /// On a build failure, points at `<run-dir>/build/build.log`. The UI
    /// uses this to show a Reveal-in-Finder button.
    var buildLogURL: URL?
    /// Recovery hint from the failure's `LocalizedError.recoverySuggestion`.
    var recoveryHint: String?
    var outcome: RunOutcome?

    enum Status: Sendable {
        case idle
        case starting
        case building
        case launching
        case running
        case awaitingApproval
        case completed(Verdict)
        case failed
    }

    struct PendingApproval: Sendable, Equatable {
        let stepIndex: Int
        let toolCall: ToolCall

        var description: String {
            switch toolCall.input {
            case .tap(let x, let y): return "Tap (\(x), \(y))"
            case .doubleTap(let x, let y): return "Double-tap (\(x), \(y))"
            case .swipe(let x1, let y1, let x2, let y2, _): return "Swipe (\(x1), \(y1)) → (\(x2), \(y2))"
            case .type(let text): return "Type \"\(text)\""
            case .pressButton(let b): return "Press \(b.rawValue)"
            case .wait(let ms): return "Wait \(ms)ms"
            case .readScreen: return "Re-read the screen"
            case .noteFriction(let kind, _): return "Note friction (\(kind.rawValue))"
            case .markGoalDone(let v, _, _, _): return "Mark goal done (\(v.rawValue))"
            }
        }
    }

    // MARK: Dependencies

    private let container: AppContainer
    private var runTask: Task<Void, Never>?
    private var pollerTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var approvalContinuation: AsyncStream<UserApproval>.Continuation?
    private var startedAt: Date?

    /// Public read-only accessor for the run's wall-clock start. The
    /// LeftRail's "Started" sub-meta row uses this to render `today, 14:22`
    /// style labels.
    var startedAtForDisplay: Date? { startedAt }

    /// Latest known token usage for the run. Updated when the coordinator
    /// emits the final `runCompleted` event; `.zero` while the run is in
    /// flight (per-step token deltas aren't surfaced live yet — tracked in
    /// the design backlog). Drives the LeftRail's cost cell.
    var totalTokenUsage: TokenUsage = .zero

    /// Estimated API cost for the run, computed from `totalTokenUsage` and
    /// the request's model. `.zero` while no cost is measurable (live
    /// in-flight runs, ad-hoc test paths without a model).
    var totalCost: RunCost {
        guard let model = request?.model else { return .zero }
        return Pricing.cost(model: model, usage: totalTokenUsage)
    }

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: Lifecycle

    func startIfPending() {
        guard runTask == nil, let request = container.consumePendingRun() else { return }
        start(request: request)
    }

    func start(request: GoalRequest) {
        self.request = request
        self.status = .starting
        self.feed = []
        self.frictionFeed = []
        self.outcome = nil
        self.runError = nil
        self.startedAt = Date()
        self.elapsedSeconds = 0
        self.legProgress = Self.initialLegProgress(for: request)
        self.currentLegIndex = nil
        self.currentGoal = request.goal
        self.currentLegName = Self.initialLegName(for: request)
        self.totalTokenUsage = .zero

        let coordinator = container.makeRunCoordinator()
        let approvals = AsyncStream<UserApproval> { continuation in
            self.approvalContinuation = continuation
        }
        let stream = coordinator.run(request, approvals: approvals)

        // Elapsed-time ticker.
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    guard let s = self else { return }
                    if let started = s.startedAt {
                        s.elapsedSeconds = Int(Date().timeIntervalSince(started))
                    }
                }
            }
        }

        runTask = Task { [weak self] in
            do {
                for try await event in stream {
                    await MainActor.run { self?.handle(event: event) }
                }
            } catch is CancellationError {
                await MainActor.run { self?.markFailed(error: nil, recoveryHint: nil, buildLogURL: nil, message: "Run cancelled.") }
            } catch let buildFailure as BuildFailure {
                Self.logger.error("Build failed: \(buildFailure.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self?.markFailed(
                        error: buildFailure,
                        recoveryHint: buildFailure.recoverySuggestion,
                        buildLogURL: buildFailure.buildLogURL,
                        message: buildFailure.localizedDescription
                    )
                }
            } catch {
                Self.logger.error("Run failed: \(error.localizedDescription, privacy: .public)")
                let recovery = (error as? LocalizedError)?.recoverySuggestion
                await MainActor.run {
                    self?.markFailed(
                        error: error,
                        recoveryHint: recovery,
                        buildLogURL: nil,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Cancel the in-flight run.
    func stop() {
        approvalContinuation?.yield(.stop)
        approvalContinuation?.finish()
        approvalContinuation = nil
        runTask?.cancel()
        pollerTask?.cancel()
        elapsedTask?.cancel()
        status = .failed
    }

    /// Approval-gate decisions from the UI.
    func approve() { approvalContinuation?.yield(.approve); status = .running }
    func skip() { approvalContinuation?.yield(.skip); status = .running }
    func reject(note: String) { approvalContinuation?.yield(.reject(note: note)); status = .running }

    /// User clicked on the mirror — forward to the simulator via idb.
    /// Best-effort: we don't surface tap errors here (the agent loop will
    /// react to the next screenshot regardless). Updates the last-tap dot
    /// so the user sees their click registered.
    func userForwardedTap(at point: CGPoint) {
        guard let request else { return }
        self.lastTapPoint = point
        let driver = container.simulatorDriver
        let ref = request.simulator
        Task.detached {
            try? await driver.tap(at: point, on: ref)
        }
    }

    // MARK: Event handling

    private func handle(event: RunEvent) {
        switch event {
        case .runStarted(let req):
            self.request = req
            status = .building

        case .buildStarted:
            status = .building

        case .buildCompleted:
            status = .launching

        case .simulatorReady(let ref):
            status = .running
            startScreenshotPoller(for: ref)

        case .stepStarted(_, _, let url):
            // Use the step screenshot as the live mirror image so it updates
            // even between poll ticks.
            if let img = NSImage(contentsOf: url) {
                self.liveImage = img
            }

        case .toolProposed(let step, let call):
            // Append a feed cell with no thumbnail (we don't ferry the
            // screenshot data to the cell yet).
            feed.append(PreviewStep.make(
                n: step,
                observation: call.observation,
                intent: call.intent,
                toolCall: call,
                thumbnail: liveImage,
                friction: nil
            ))
            // Update the last-tap dot for the mirror overlay.
            if case .tap(let x, let y) = call.input {
                self.lastTapPoint = CGPoint(x: x, y: y)
            } else if case .doubleTap(let x, let y) = call.input {
                self.lastTapPoint = CGPoint(x: x, y: y)
            }

        case .awaitingApproval(let step, let call):
            self.pendingApproval = PendingApproval(stepIndex: step, toolCall: call)
            status = .awaitingApproval

        case .toolExecuted:
            self.pendingApproval = nil
            if case .running = status { /* keep */ } else if case .awaitingApproval = status { status = .running }

        case .frictionEmitted(let event):
            let pf = PreviewFrictionEvent(
                timestamp: formatElapsed(),
                stepN: event.step,
                kind: PreviewFrictionKind(event.kind),
                title: event.kind.rawValue,
                detail: event.detail,
                agentQuote: ""
            )
            frictionFeed.append(pf)

        case .stepCompleted:
            break

        case .legStarted(let index, let actionName, let goal, _):
            self.currentLegIndex = index
            self.currentLegName = actionName
            self.currentGoal = goal
            // Mark the active leg as running, leave earlier ones at their
            // recorded status, and reset any stragglers if the executor
            // somehow re-enters a leg (shouldn't happen — defensive).
            for i in legProgress.indices {
                if i == index {
                    legProgress[i].status = .running
                } else if i < index, case .pending = legProgress[i].status {
                    // Past leg never received a legCompleted (rare; treat
                    // as skipped so the chain view stays sane).
                    legProgress[i].status = .skipped
                }
            }

        case .legCompleted(let index, let verdict, let summary):
            guard legProgress.indices.contains(index) else { break }
            if summary == "skipped" {
                legProgress[index].status = .skipped
            } else if let verdict {
                legProgress[index].status = .done(verdict)
            } else {
                // No verdict + non-skipped summary — defensive fallback.
                legProgress[index].status = .skipped
            }
            // The current-leg pointer drops while we wait for the next
            // legStarted (or runCompleted). Keeping the last index here
            // would falsely highlight a finished leg.
            if currentLegIndex == index {
                currentLegIndex = nil
            }

        case .runCompleted(let outcome):
            self.outcome = outcome
            self.status = .completed(outcome.verdict)
            self.totalTokenUsage = TokenUsage(
                inputTokens: outcome.tokensUsedInput,
                outputTokens: outcome.tokensUsedOutput,
                cacheReadInputTokens: outcome.tokensUsedCacheRead,
                cacheCreationInputTokens: outcome.tokensUsedCacheCreation
            )
            stopBackgroundTasks()
        }
    }

    private func markFailed(error: (any Error)?, recoveryHint: String?, buildLogURL: URL?, message: String) {
        self.runError = message
        self.recoveryHint = recoveryHint
        self.buildLogURL = buildLogURL
        self.status = .failed
        stopBackgroundTasks()
    }

    private func stopBackgroundTasks() {
        pollerTask?.cancel(); pollerTask = nil
        elapsedTask?.cancel(); elapsedTask = nil
    }

    // MARK: Screenshot poller (3 fps)

    private func startScreenshotPoller(for ref: SimulatorRef) {
        pollerTask?.cancel()
        let driver = container.simulatorDriver
        pollerTask = Task { [weak self] in
            while !Task.isCancelled {
                let image = try? await driver.screenshotImage(ref)
                await MainActor.run {
                    if let image { self?.liveImage = image }
                }
                try? await Task.sleep(for: .milliseconds(333))
            }
        }
    }

    // MARK: Helpers

    private func formatElapsed() -> String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// True when the active run is a chain (≥2 legs). The session view
    /// uses this to gate the chain progress block in the LeftRail and to
    /// render leg dividers in the step feed (future work).
    var isChainRun: Bool {
        legProgress.count > 1
    }

    /// One-line label for the run-name chip in the toolbar. Falls back
    /// progressively: explicit run name → chain/action name → the request's
    /// goal text → "Run" so we never render an empty chip.
    var runDisplayName: String {
        if let req = request {
            let trimmed = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if !currentLegName.isEmpty { return currentLegName }
        return request?.goal.firstSentence ?? "Run"
    }

    nonisolated private static func initialLegProgress(for request: GoalRequest) -> [LegProgress] {
        switch request.payload {
        case .chain(_, let legs):
            return legs.map { leg in
                LegProgress(
                    id: leg.index,
                    actionName: leg.actionName,
                    goal: leg.goal,
                    preservesState: leg.preservesState,
                    status: .pending
                )
            }
        case .singleAction:
            // Single-action runs still emit one synthesized leg from the
            // coordinator. Seed a one-entry list so the VM's leg pointer
            // can flip without nil-checking; the view hides the panel
            // when count == 1.
            return [
                LegProgress(
                    id: 0,
                    actionName: request.name.isEmpty ? request.goal.firstSentence : request.name,
                    goal: request.goal,
                    preservesState: false,
                    status: .pending
                )
            ]
        case .ad_hoc:
            return [
                LegProgress(
                    id: 0,
                    actionName: request.goal.firstSentence,
                    goal: request.goal,
                    preservesState: false,
                    status: .pending
                )
            ]
        }
    }

    nonisolated private static func initialLegName(for request: GoalRequest) -> String {
        switch request.payload {
        case .chain(_, let legs): return legs.first?.actionName ?? request.name
        case .singleAction:       return request.name.isEmpty ? request.goal.firstSentence : request.name
        case .ad_hoc:             return request.goal.firstSentence
        }
    }

    /// Map the run's `Status` onto the `StatusChip` primitive's smaller enum.
    /// Returns `nil` for `.idle` (no run in flight → no chip rendered).
    var statusKind: StatusKind? {
        switch status {
        case .idle:                       return nil
        case .starting, .building, .launching, .running:
            return .running
        case .awaitingApproval:           return .awaiting
        case .completed:                  return .done
        case .failed:                     return .paused
        }
    }
}

// MARK: - Helpers

private extension String {
    /// Trim to the first sentence (or the first 60 characters), trimmed.
    /// Used for leg-name fallbacks when the user didn't supply an explicit
    /// run name and we need a label that fits the toolbar chip / chain row.
    var firstSentence: String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Run" }
        let firstChunk = trimmed.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? trimmed
        let cleaned = firstChunk.trimmingCharacters(in: .whitespaces)
        if cleaned.count <= 60 { return cleaned }
        return String(cleaned.prefix(57)) + "…"
    }
}
