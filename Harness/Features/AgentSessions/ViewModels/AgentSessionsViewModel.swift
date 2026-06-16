//
//  AgentSessionsViewModel.swift
//  Harness
//
//  Backs the "Recent agent runs" list in `AgentSessionsView` — past runs
//  whose origin is `.mcp`, pulled from the shared history store. Live
//  (in-flight) sessions come from `AgentSessionsMonitor`, not here.
//
//  Mirrors the create-in-`.onAppear` lifecycle of `RunHistoryViewModel`:
//  the view injects `AppContainer` and constructs this with the store.
//

import Foundation
import Observation

@Observable
@MainActor
final class AgentSessionsViewModel {

    /// Completed agent (MCP) runs, most recent first.
    var pastRuns: [RunRecordSnapshot] = []
    var isLoading = false

    private let store: any RunHistoryStoring

    init(store: any RunHistoryStoring) {
        self.store = store
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let recent = (try? await store.fetchRecent(limit: 100)) ?? []
        // `fetchRecent` already returns newest-first; keep only agent-origin
        // runs. CLI runs have their own origin and are intentionally excluded
        // from the Agent Sessions surface.
        pastRuns = recent.filter { $0.source == .mcp }
    }
}
