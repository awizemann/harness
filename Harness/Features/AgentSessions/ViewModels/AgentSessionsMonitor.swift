//
//  AgentSessionsMonitor.swift
//  Harness
//
//  Polls `AgentSessionStore` for live agent-session markers and publishes
//  them for the GUI's global banner + Agent Sessions section.
//
//  The GUI and the MCP server are separate processes sharing one on-disk
//  SwiftData store, and that store has no cross-process change feed. So the
//  MCP server drops a small marker file per in-flight run (see
//  `AgentSessionStore`) and this monitor tails the directory on a short
//  interval — the only signal the GUI gets that an agent is currently
//  driving Harness.
//
//  Owned by `AppContainer`, started once at launch, lives for the app's
//  lifetime. A `Task.sleep` loop (the codebase's established polling idiom)
//  rather than a `Timer`, to stay clean under Swift 6 strict concurrency.
//

import Foundation
import Observation

@Observable
@MainActor
final class AgentSessionsMonitor {

    /// Live agent sessions, oldest-started first. Empty when no agent run is
    /// in flight. Re-published each poll only when the set actually changes,
    /// so observers don't churn on identical reads.
    private(set) var activeSessions: [AgentSessionMarker] = []

    /// Bumped whenever the active set shrinks (≥1 session ended since the
    /// last poll). History observes this to reload so a just-finished agent
    /// run appears without a manual refresh or re-navigation.
    private(set) var endedGeneration: Int = 0

    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(pollInterval: Duration = .milliseconds(1500)) {
        self.pollInterval = pollInterval
    }

    /// Begin polling. Idempotent — a second call while already running is a
    /// no-op. The first read fires immediately so the banner/section reflect
    /// reality on launch without waiting a full interval.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.poll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        let latest = AgentSessionStore.readAll()
        guard latest != activeSessions else { return }
        // Bump on ANY session that disappeared since the last poll (compared
        // by run id), not just a net count drop: one run ending while another
        // starts in the same ~1.5s window is net-zero, and a count-only check
        // would skip the History reload for the run that just finished.
        let endedAny = !Set(activeSessions.map(\.id)).subtracting(latest.map(\.id)).isEmpty
        activeSessions = latest
        if endedAny { endedGeneration &+= 1 }
    }
}
