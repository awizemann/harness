//
//  HarnessApp.swift
//  Harness
//
//  Application entry point. Builds the dependency graph and injects the
//  shared coordinator/state into the environment.
//

import SwiftUI
import AppKit

@main
struct HarnessApp: App {

    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container.appCoordinator)
                .environment(container.appState)
                .environment(container)
                .frame(minWidth: 1200, minHeight: 760)
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
        // Open at a size that comfortably fits the three-pane layouts —
        // RunSession (sidebar + LeftRail ~280 + mirror + StepFeed ~360) and
        // the new run-history list/detail. macOS persists the user's last
        // window size after they resize, so this only affects first launch
        // and "Reset Saved State."
        .defaultSize(width: 1440, height: 900)
        // `.contentMinSize` honors `frame(minWidth:minHeight:)` as the
        // floor but lets the user resize the window above it. `.contentSize`
        // (the previous setting) couples the window to the content's
        // intrinsic frame, which is what made the window open too small
        // for its own contents.
        .windowResizability(.contentMinSize)
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
    /// `settings.json`, validate it against the live store, propagate to the
    /// coordinator, and seed built-in personas. Stale ids (deleted
    /// Applications) get cleared so the workspace doesn't render against a
    /// missing scope.
    @MainActor
    private func bootstrapPersistedScope() async {
        let state = container.appState
        let coordinator = container.appCoordinator
        await state.restorePersistedSettings()
        // Seed built-in personas every launch — idempotent, surfaces new
        // built-ins added in future updates.
        await container.bootstrapPersonas()
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
        // Persist the main window's size + position across launches.
        // Sets `NSWindow.frameAutosaveName` once on first appear; AppKit
        // takes it from there — frame is written to user defaults on
        // resize/move, restored automatically on the next launch. No
        // UserDefaults plumbing in our code.
        .background(WindowFrameAutosaver(name: "Harness.MainWindow"))
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

/// Hands the main window's frame persistence to AppKit. `setFrameAutosaveName`
/// is the native API — it saves the frame to UserDefaults on every resize /
/// move and restores it on the next launch automatically. No code of ours
/// runs after attach; AppKit owns it. Same mechanism every other Mac app uses.
///
/// Reset to default with: `defaults delete com.harness.app "NSWindow Frame Harness.MainWindow"`
private struct WindowFrameAutosaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        AutosaverView(name: name)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AutosaverView: NSView {
        private let autosaveName: NSWindow.FrameAutosaveName

        init(name: String) {
            self.autosaveName = NSWindow.FrameAutosaveName(name)
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Unconditional — AppKit reads any saved frame and applies it
            // when the name is set. Setting it again on the same window
            // is harmless.
            self.window?.setFrameAutosaveName(autosaveName)
        }
    }
}

private struct DetailRouter: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        switch coordinator.selectedSection {
        case .applications: ApplicationsView()
        case .personas:     PersonasView()
        case .actions:      ActionsView()
        case .newRun:       GoalInputView()
        case .activeRun:    RunSessionView()
        case .history:      RunHistoryView()
        case .friction:     FrictionReportView()
        }
    }
}
