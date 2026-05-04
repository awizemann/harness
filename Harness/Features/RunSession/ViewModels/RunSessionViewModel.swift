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

        case .runCompleted(let outcome):
            self.outcome = outcome
            self.status = .completed(outcome.verdict)
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
