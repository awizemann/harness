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

/// Two-tier sidebar:
/// - **Library** sections are always visible (`applications`, `personas`, `actions`).
/// - **Workspace** sections (`newRun`, `activeRun`, `history`, `friction`) only
///   render when an `Application` is selected via `selectedApplicationID`.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {

    // Library (always visible)
    case applications
    case personas
    case actions

    // Workspace (gated on selectedApplicationID != nil)
    case newRun
    case activeRun
    case history
    case friction

    var id: String { rawValue }

    enum Category: Hashable {
        case library
        case workspace
    }

    var category: Category {
        switch self {
        case .applications, .personas, .actions:
            return .library
        case .newRun, .activeRun, .history, .friction:
            return .workspace
        }
    }

    var title: String {
        switch self {
        case .applications: return "Applications"
        case .personas: return "Personas"
        case .actions: return "Actions"
        case .newRun: return "New Run"
        case .activeRun: return "Active Run"
        case .history: return "History"
        case .friction: return "Friction"
        }
    }

    var systemImage: String {
        switch self {
        case .applications: return "square.stack.3d.up.fill"
        case .personas: return "person.2"
        case .actions: return "text.cursor"
        case .newRun: return "plus.circle"
        case .activeRun: return "play.circle"
        case .history: return "clock.arrow.circlepath"
        case .friction: return "exclamationmark.triangle"
        }
    }
}

@Observable
@MainActor
final class AppCoordinator {

    // MARK: Sidebar / detail

    /// Default landing section is `.applications` — the user picks an
    /// Application before they can compose a run.
    var selectedSection: SidebarSection = .applications

    /// The currently scoped Application. When nil, the workspace sections
    /// (newRun / activeRun / history / friction) are hidden in the sidebar.
    /// Setting this to nil while the user is in a workspace section bounces
    /// them back to `.applications`. Persisted by `AppState` to
    /// `~/Library/Application Support/Harness/settings.json`.
    var selectedApplicationID: UUID? {
        didSet {
            // Bounce out of a now-hidden workspace section if the user
            // cleared the active Application (e.g. by deleting it).
            if selectedApplicationID == nil,
               selectedSection.category == .workspace {
                selectedSection = .applications
            }
        }
    }

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

    /// One-shot anchor: when non-nil at the moment a replay opens, the
    /// `RunReplayViewModel` seeks to that step on first load and clears
    /// the value. Set by FrictionReport's "Jump to step" buttons.
    var replayJumpToStep: Int?

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
