//
//  AppCoordinator.swift
//  Harness
//
//  Single source of truth for navigation state, per
//  `standards/01-architecture.md §2`. Injected via `.environment()` at the
//  app root; views read state but never own independent navigation state.
//

import Foundation
import Observation

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case newRun
    case activeRun
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newRun: return "New Run"
        case .activeRun: return "Active Run"
        case .history: return "History"
        }
    }

    var systemImage: String {
        switch self {
        case .newRun: return "plus.circle"
        case .activeRun: return "play.circle"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@Observable
@MainActor
final class AppCoordinator {

    // MARK: Sidebar / detail

    var selectedSection: SidebarSection = .newRun

    // MARK: Active run

    /// Run ID currently being driven by `RunSessionViewModel`. Nil when no run
    /// is in flight. Set by the run-session VM when it receives `runStarted`.
    var activeRunID: UUID?

    // MARK: History selection

    /// Selected past-run id in the history list. Nil = nothing selected.
    var selectedHistoryRunID: UUID?

    // MARK: Modal flags

    var isFirstRunWizardOpen: Bool = false
    var isSettingsOpen: Bool = false
    /// Run id whose replay is open (in a sheet). Nil = closed.
    var replayingRunID: UUID?

    // MARK: Navigation helpers

    func startedRun(id: UUID) {
        activeRunID = id
        selectedSection = .activeRun
    }

    func clearActiveRun() {
        activeRunID = nil
    }

    func openReplay(runID: UUID) {
        replayingRunID = runID
    }

    func closeReplay() {
        replayingRunID = nil
    }

    func openSettings() { isSettingsOpen = true }
    func closeSettings() { isSettingsOpen = false }
}
