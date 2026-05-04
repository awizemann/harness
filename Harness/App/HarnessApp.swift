//
//  HarnessApp.swift
//  Harness
//
//  Application entry point. Builds the dependency graph and injects the
//  shared coordinator/state into the environment.
//

import SwiftUI

@main
struct HarnessApp: App {

    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container.appCoordinator)
                .environment(container.appState)
                .environment(container)
                .frame(minWidth: 1024, minHeight: 640)
                .task { await container.appState.refreshAll() }
                .task {
                    await bootstrapPersistedScope()
                }
                .onAppear {
                    // First-run wizard if anything's not set up: API key
                    // missing, xcodebuild missing, or WebDriverAgent hasn't
                    // been built for the picked simulator's iOS version.
                    Task { @MainActor in
                        await container.appState.refreshAll()
                        let state = container.appState
                        let needsSetup = !state.apiKeyPresent
                            || !state.xcodebuildAvailable
                            || !state.wdaReady
                        if needsSetup {
                            container.appCoordinator.isFirstRunWizardOpen = true
                        }
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Run") {
                    container.appCoordinator.selectedSection = .newRun
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(container.appCoordinator.selectedApplicationID == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Applications") {
                    container.appCoordinator.selectedSection = .applications
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button("Personas") {
                    container.appCoordinator.selectedSection = .personas
                }
                .keyboardShortcut("2", modifiers: [.command])
                Button("Actions") {
                    container.appCoordinator.selectedSection = .actions
                }
                .keyboardShortcut("3", modifiers: [.command])
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    container.appCoordinator.openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }

    /// Restore the persisted `selectedApplicationID` (if any) from
    /// `settings.json`, validate it against the live store, and propagate
    /// to the coordinator. Stale ids (deleted Applications) get cleared so
    /// the workspace doesn't render against a missing scope.
    @MainActor
    private func bootstrapPersistedScope() async {
        let state = container.appState
        let coordinator = container.appCoordinator
        await state.restorePersistedSettings()
        guard let id = state.selectedApplicationID else { return }
        if let app = try? await container.runHistory.application(id: id), !app.archived {
            coordinator.selectedApplicationID = id
        } else {
            // Stale: clear and persist back so the file's accurate.
            state.selectedApplicationID = nil
            await state.persistSettings()
        }
    }
}

/// Top-level shell. Sidebar + detail. Sheets for first-run wizard, settings,
/// and replay all live here.
private struct RootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppState.self) private var state
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var coord = coordinator

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            DetailRouter()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    coord.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .sheet(isPresented: $coord.isFirstRunWizardOpen) {
            FirstRunWizard()
                .frame(width: 560, height: 460)
        }
        .sheet(isPresented: $coord.isSettingsOpen) {
            SettingsView()
                .frame(width: 520, height: 480)
        }
        .sheet(item: Binding(
            get: { coord.replayingRunID.map(IdentifiableUUID.init) },
            set: { coord.replayingRunID = $0?.id }
        )) { wrapped in
            RunReplayView(runID: wrapped.id)
                .frame(minWidth: 1100, minHeight: 740)
        }
    }
}

private struct IdentifiableUUID: Identifiable, Hashable { let id: UUID }

private struct DetailRouter: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        switch coordinator.selectedSection {
        case .applications: ApplicationsView()
        case .personas:     PlaceholderLibraryView(kind: .personas)
        case .actions:      PlaceholderLibraryView(kind: .actions)
        case .newRun:       GoalInputView()
        case .activeRun:    RunSessionView()
        case .history:      RunHistoryView()
        case .friction:     FrictionReportView()
        }
    }
}
