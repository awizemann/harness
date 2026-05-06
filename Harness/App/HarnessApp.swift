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

/// Decoupled main-window frame persistence.
///
/// Three prior attempts (ec6e4f0, d807996, dcf4f9d) tried `setFrameAutosaveName`
/// — none stuck. AppKit's autosave is timing-sensitive in a SwiftUI WindowGroup
/// and we kept losing the race.
///
/// This implementation owns both ends of the read/write loop, so it can't lose
/// races with SwiftUI:
///
///   * On every `NSWindow.didResizeNotification` / `.didMoveNotification`
///     (observed app-wide, no `object:` filter), if the source is the main
///     content window, the frame is persisted to UserDefaults under
///     `com.harness.app.mainWindowFrame` via `NSStringFromRect`.
///   * On launch, after a small delay (so SwiftUI has materialised the
///     WindowGroup), the saved frame is read back and applied via
///     `setFrame(_:display:animate:)`. If the window isn't there yet, it
///     retries up to 5× at 100 ms intervals.
///   * `applicationSupportsSecureRestorableState` returns true so the system
///     restoration path is also willing to participate (belt + braces).
///
/// `print()` diagnostics throughout. Logger output went to unified logging
/// last time and the user couldn't see it; print writes to stderr/stdout
/// where it's visible from a terminal-launched run or Xcode's debug pane.
@MainActor
final class HarnessAppDelegate: NSObject, NSApplicationDelegate {

    private static let frameKey = "com.harness.app.mainWindowFrame"

    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Harness] applicationDidFinishLaunching ran. NSApp.windows.count=\(NSApp.windows.count)")
        for (idx, w) in NSApp.windows.enumerated() {
            print("[Harness]   window[\(idx)]: class=\(type(of: w)) titled=\(w.styleMask.contains(.titled)) resizable=\(w.styleMask.contains(.resizable)) panel=\(w is NSPanel) frame=\(NSStringFromRect(w.frame))")
        }

        // Hook resize / move on every window — filter to "main content
        // window" inside the closure. Avoids the race where the
        // WindowGroup window isn't realised yet at registration time.
        //
        // Closure body inlined (rather than calling a helper) because
        // Swift 6's strict concurrency flags a Notification crossing
        // any boundary, and inlining keeps everything in a single
        // closure scope that never sends `note` anywhere. The closure
        // runs on `queue: .main`, so the NSWindow / UserDefaults
        // accesses are safely on the main thread regardless of what
        // the type-system thinks.
        let persist: (Notification) -> Void = { note in
            guard let window = note.object as? NSWindow,
                  window.styleMask.contains(.titled),
                  window.styleMask.contains(.resizable),
                  !(window is NSPanel)
            else { return }
            let str = NSStringFromRect(window.frame)
            UserDefaults.standard.set(str, forKey: Self.frameKey)
            print("[Harness] persisted frame=\(str) (event=\(note.name.rawValue))")
        }
        let resize = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main,
            using: persist
        )
        let move = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main,
            using: persist
        )
        observers = [resize, move]

        // Read back the saved frame. SwiftUI hasn't always realised the
        // window by the time this runs, so poll briefly.
        applySavedFrame(retriesRemaining: 5, delay: 0.05)
    }

    /// Required for window restoration to be permitted by macOS 14+.
    /// Returning true also opts the app in to scene-state restoration as
    /// a fallback path; the explicit UserDefaults persistence below
    /// works regardless of this setting.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Private

    /// Walk `NSApp.windows`, find the first "looks like main content"
    /// window, apply the saved frame to it. If no window matches yet,
    /// schedule a retry — SwiftUI sometimes takes a runloop tick or two
    /// to put the WindowGroup window on screen after `didFinishLaunching`.
    private func applySavedFrame(retriesRemaining: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let window = NSApp.windows.first(where: Self.looksLikeMainContentWindow)
            print("[Harness] applySavedFrame tick: foundWindow=\(window != nil) retriesRemaining=\(retriesRemaining)")
            if let window {
                if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
                    let rect = NSRectFromString(saved)
                    if rect.width > 100, rect.height > 100 {
                        print("[Harness] restoring saved frame=\(saved)")
                        window.setFrame(rect, display: true, animate: false)
                    } else {
                        print("[Harness] saved frame degenerate; ignoring (\(saved))")
                    }
                } else {
                    print("[Harness] no saved frame yet — first launch path")
                }
                return
            }
            if retriesRemaining > 0 {
                self.applySavedFrame(retriesRemaining: retriesRemaining - 1, delay: 0.1)
            } else {
                print("[Harness] gave up looking for the main window after retries")
            }
        }
    }

    /// True for a SwiftUI WindowGroup-style content window: titled +
    /// resizable + not a panel (which excludes sheets, popovers, and
    /// the FirstRunWizard / Settings sheets that are NSPanel subclasses).
    nonisolated static func looksLikeMainContentWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && window.styleMask.contains(.resizable)
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
