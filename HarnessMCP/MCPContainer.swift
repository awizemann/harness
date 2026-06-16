//
//  MCPContainer.swift
//  HarnessMCP
//
//  The minimal dependency graph the MCP server needs, plus the in-process
//  registry that tracks active/finished runs (`RunSupervisor`). Mirrors
//  the shape `HarnessRunner` builds for the CLI, but opens the *shared
//  on-disk* history store (via `RunHistoryStore.at(url:)`) instead of the
//  CLI's in-memory store — so personas, applications, credentials, and
//  runs created over MCP show up in the Harness GUI and vice versa.
//

import Foundation

/// Shared, `Sendable` dependency bundle resolved once and reused for the
/// lifetime of the server process.
struct MCPContainer: Sendable {
    let history: any RunHistoryStoring
    let keychain: any KeychainStoring
    let supervisor: RunSupervisor
    /// Ollama / local-inference base URL (only consulted for `.local` models).
    let localBaseURL: URL

    /// Open the app's on-disk SwiftData store and assemble shared deps.
    ///
    /// `resetOnMigrationFailure: false` is deliberate: unlike the GUI's
    /// `openDefault()`, the MCP server must NEVER delete the user's history
    /// store on a transient open/migration hiccup — it surfaces the error
    /// instead, so every tool call returns a clear "store unavailable"
    /// rather than silently nuking data.
    static func makeShared() throws -> MCPContainer {
        try HarnessPaths.ensureDirectory(HarnessPaths.appSupport)
        let url = HarnessPaths.appSupport.appendingPathComponent("history.store")
        let history = try RunHistoryStore.at(url: url, resetOnMigrationFailure: false)

        let keychain = EnvKeychain.fromEnvironment()

        let localBaseURL: URL = {
            if let raw = ProcessInfo.processInfo.environment["HARNESS_OLLAMA_URL"],
               let u = URL(string: raw) {
                return u
            }
            return LLMClientFactory.defaultLocalBaseURL
        }()

        return MCPContainer(
            history: history,
            keychain: keychain,
            supervisor: RunSupervisor(history: history),
            localBaseURL: localBaseURL
        )
    }
}

/// Tracks runs started via `start_run`. Each run is driven on its own
/// detached task that consumes the coordinator's `RunEvent` stream and
/// folds it into a lightweight, pollable `Status`. The detached task does
/// the long-lived stream iteration so the actor itself is only ever held
/// briefly (per-event status update), keeping `get_run_status` responsive
/// while a run is in flight.
actor RunSupervisor {

    struct Status: Sendable {
        /// `starting | running | completed | failed | cancelled`.
        var phase: String
        var currentStep: Int
        var frictionCount: Int
        var verdict: String?
        var summary: String?
        var error: String?
        let startedAt: Date
        /// Wall-clock of the most recent `RunEvent`. The idle watchdog
        /// measures hangs against this — a stuck page-load settle emits no
        /// events, so the gap since `lastEventAt` grows until it trips.
        var lastEventAt: Date
        var finishedAt: Date?
    }

    private var statuses: [UUID: Status] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var watchdogs: [UUID: Task<Void, Never>] = [:]
    /// Live agent-session markers written to disk so the GUI (separate process)
    /// can show "agent session running" without cross-process store notifications.
    private var markers: [UUID: AgentSessionMarker] = [:]

    /// Used to persist a TERMINAL RunRecord when a run ends abnormally (cancel
    /// / watchdog / thrown error / stream-ended-without-completion). The
    /// coordinator only writes `markCompleted` on the happy path, so without
    /// this an aborted run is left a permanent "still running" skeleton in the
    /// shared store — a ghost row in the GUI's History and in `get_run_*` after
    /// this process exits and loses its in-memory status.
    private let history: any RunHistoryStoring

    init(history: any RunHistoryStoring) {
        self.history = history
    }

    /// Register the run, spawn its driving task, and (optionally) an idle
    /// watchdog that auto-cancels if no `RunEvent` arrives for
    /// `idleTimeoutSeconds`. A hung post-action settle (e.g. a tap that
    /// navigates to a non-completing page) emits nothing, so the watchdog is
    /// the backstop the step budget can't be — the budget is only checked at
    /// the top of the loop, which a wedged settle never reaches. Pass `0` to
    /// disable. Default is generous so slow local-model steps (which DO emit
    /// per-phase progress events) never false-trip.
    func start(id: UUID, request: RunRequest, coordinator: RunCoordinator, idleTimeoutSeconds: Int = 180) {
        let now = Date()
        statuses[id] = Status(
            phase: "starting",
            currentStep: 0,
            frictionCount: 0,
            verdict: nil,
            summary: nil,
            error: nil,
            startedAt: now,
            lastEventAt: now,
            finishedAt: nil
        )
        let marker = AgentSessionMarker(
            runID: id,
            goal: request.goal,
            platformRaw: request.platformKind.rawValue,
            modelRaw: request.model.rawValue,
            sourceRaw: RunOrigin.fromRunName(request.name).rawValue,
            startedAt: now,
            currentStep: 0,
            phase: "starting"
        )
        markers[id] = marker
        AgentSessionStore.write(marker)

        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await event in coordinator.run(request) {
                    await self.apply(id: id, event: event)
                }
                await self.finishIfNeeded(id: id)
            } catch is CancellationError {
                await self.fail(id: id, error: "run cancelled", cancelled: true)
            } catch {
                await self.fail(id: id, error: error.localizedDescription, cancelled: false)
            }
        }
        tasks[id] = task

        if idleTimeoutSeconds > 0 {
            watchdogs[id] = Task.detached { [weak self] in
                guard let self else { return }
                while true {
                    try? await Task.sleep(for: .seconds(5))
                    if await self.idleCheck(id: id, idleTimeoutSeconds: idleTimeoutSeconds) { return }
                }
            }
        }
    }

    func status(id: UUID) -> Status? { statuses[id] }

    /// Cancel a run (manual `cancel_run`). Cancels the driving task and marks
    /// the status cancelled. Note: cancellation is cooperative — if the run
    /// is wedged in a non-cancellation-aware driver await (a stuck WKWebView
    /// load), the underlying work may linger until the process exits, but the
    /// MCP-visible status flips to cancelled immediately.
    func cancel(id: UUID) async -> Bool {
        guard let task = tasks[id] else { return false }
        task.cancel()
        watchdogs[id]?.cancel()
        if var s = statuses[id], s.finishedAt == nil {
            s.phase = "cancelled"
            s.error = "cancelled via cancel_run"
            s.finishedAt = Date()
            statuses[id] = s
            await persistTerminal(id: id, verdict: .blocked, summary: "cancelled via cancel_run")
        }
        return true
    }

    // MARK: Event folding

    private func apply(id: UUID, event: RunEvent) {
        guard var s = statuses[id] else { return }
        // Once terminal, ignore late events (e.g. a runCompleted landing just
        // after a watchdog cancel) so the recorded outcome doesn't flip.
        guard s.finishedAt == nil else { return }
        s.lastEventAt = Date()
        switch event {
        case .runStarted:
            s.phase = "running"
            updateMarker(id: id) { $0.phase = "running" }
        case .stepStarted(let step, _, _):
            s.currentStep = step
            updateMarker(id: id) { $0.currentStep = step; $0.phase = "running" }
        case .frictionEmitted:
            s.frictionCount += 1
        case .runCompleted(let outcome):
            s.phase = "completed"
            s.verdict = outcome.verdict.rawValue
            s.summary = outcome.summary
            s.currentStep = outcome.stepCount
            s.frictionCount = outcome.frictionCount
            s.finishedAt = outcome.completedAt
            removeMarker(id: id)
        default:
            break
        }
        statuses[id] = s
    }

    private func fail(id: UUID, error: String, cancelled: Bool) async {
        watchdogs[id]?.cancel()
        guard var s = statuses[id], s.finishedAt == nil else { return }
        s.phase = cancelled ? "cancelled" : "failed"
        s.error = error
        s.finishedAt = Date()
        statuses[id] = s
        await persistTerminal(id: id, verdict: cancelled ? .blocked : .failure, summary: error)
    }

    /// If the stream ended without a terminal `runCompleted`, mark the run
    /// failed so a poller never sees a permanently "running" ghost.
    private func finishIfNeeded(id: UUID) async {
        watchdogs[id]?.cancel()
        guard var s = statuses[id], s.finishedAt == nil else { return }
        s.phase = "failed"
        let reason = s.error ?? "run ended without emitting run_completed"
        s.error = reason
        s.finishedAt = Date()
        statuses[id] = s
        await persistTerminal(id: id, verdict: .blocked, summary: reason)
    }

    /// Watchdog tick. Returns `true` when the watchdog should stop (run done,
    /// gone, or just auto-cancelled for inactivity).
    private func idleCheck(id: UUID, idleTimeoutSeconds: Int) async -> Bool {
        guard let s = statuses[id] else { return true }
        if s.finishedAt != nil { return true }
        let idle = Date().timeIntervalSince(s.lastEventAt)
        guard idle >= Double(idleTimeoutSeconds) else { return false }
        tasks[id]?.cancel()
        var updated = s
        updated.phase = "cancelled"
        let reason = "watchdog: no activity for ~\(Int(idle))s (likely a stuck page load / hung navigation); auto-cancelled"
        updated.error = reason
        updated.finishedAt = Date()
        statuses[id] = updated
        await persistTerminal(id: id, verdict: .blocked, summary: reason)
        return true
    }

    /// Persist a terminal RunRecord for an abnormally-ended run so it doesn't
    /// linger as a "still running" skeleton in the shared store. Best-effort;
    /// token totals are unknown here (the run dir's JSONL has the truth) so we
    /// record the steps/friction we observed and zero tokens.
    private func persistTerminal(id: UUID, verdict: Verdict, summary: String) async {
        removeMarker(id: id)
        let s = statuses[id]
        let outcome = RunOutcome(
            verdict: verdict,
            summary: summary,
            frictionCount: s?.frictionCount ?? 0,
            wouldRealUserSucceed: false,
            stepCount: s?.currentStep ?? 0,
            tokensUsedInput: 0,
            tokensUsedOutput: 0,
            completedAt: s?.finishedAt ?? Date()
        )
        try? await history.markCompleted(id: id, outcome: outcome)
    }

    // MARK: Agent-session markers (cross-process live signal for the GUI)

    private func updateMarker(id: UUID, _ mutate: (inout AgentSessionMarker) -> Void) {
        guard var m = markers[id] else { return }
        mutate(&m)
        markers[id] = m
        AgentSessionStore.write(m)
    }

    private func removeMarker(id: UUID) {
        guard markers[id] != nil else { return }
        markers[id] = nil
        AgentSessionStore.remove(runID: id)
    }
}
