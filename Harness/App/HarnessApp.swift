//
//  HarnessApp.swift
//  Harness
//
//  Application entry point. Builds the dependency graph and injects the
//  shared coordinator/state into the environment.
//

import SwiftUI
import AppKit
import os

@main
struct HarnessApp: App {

    @State private var container = AppContainer()
    /// Bridge to AppKit's lifecycle. Hosts the once-per-launch hook
    /// that wires the main window's frame autosave (see
    /// `HarnessAppDelegate.applicationDidFinishLaunching`). Required
    /// because SwiftUI's `.background(NSViewRepresentable)` route was
    /// applying the autosave name to a hosting view's window rather
    /// than the user-facing main window.
    @NSApplicationDelegateAdaptor(HarnessAppDelegate.self) private var appDelegate

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

/// AppKit-side lifecycle hook. SwiftUI doesn't expose
/// `applicationDidFinishLaunching` directly; `@NSApplicationDelegateAdaptor`
/// is the canonical bridge.
///
/// Sole responsibility: when the user's main window first becomes
/// main / key, apply `NSWindow.setFrameAutosaveName(_:)` so AppKit
/// persists its frame across launches. Once-only — guarded by a flag —
/// because every sheet (FirstRunWizard, Settings, Replay) also fires
/// `didBecomeMainNotification` and we don't want to clobber its frame.
final class HarnessAppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.harness.app", category: "HarnessAppDelegate")
    private static let autosaveName: NSWindow.FrameAutosaveName = "Harness.MainWindow"

    private var didApplyAutosave: Bool = false
    private var becomeMainObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wait for the first window to become main, then mark it. Using
        // `didBecomeMainNotification` instead of `NSApp.windows.first`
        // because at this point in launch SwiftUI may not have realised
        // its WindowGroup yet — `windows` can be empty for a few runloops.
        becomeMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  !self.didApplyAutosave,
                  let window = note.object as? NSWindow,
                  Self.looksLikeMainContentWindow(window)
            else { return }
            window.setFrameAutosaveName(Self.autosaveName)
            self.didApplyAutosave = true
            Self.logger.info("Applied autosave name to main window. Initial frame=\(NSStringFromRect(window.frame), privacy: .public)")
            // Drop the observer — we're done.
            if let token = self.becomeMainObserver {
                NotificationCenter.default.removeObserver(token)
                self.becomeMainObserver = nil
            }
        }
    }

    /// Heuristic: the user's WindowGroup window is titled, has a normal
    /// content size, and isn't a sheet / panel / inspector. Sheets are
    /// `NSPanel` subclasses and don't carry `.titled` style.
    private static func looksLikeMainContentWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && window.styleMask.contains(.resizable)
            && !window.styleMask.contains(.utilityWindow)
            && !(window is NSPanel)
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
