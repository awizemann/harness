//
//  WebViewWindowController.swift
//  Harness
//
//  Hosts a `WKWebView` inside an `NSWindow` sized to the run's configured
//  viewport. Lives off-screen by default — the simulator-mirror UI in
//  `RunSessionView` shows the page contents via the snapshot pipeline,
//  so we don't need a visible window.
//
//  The window has to be a real `NSWindow` (not just an off-screen layer)
//  because `WKWebView.takeSnapshot(...)` requires the view to be in a
//  real window hierarchy with a non-zero size and a backing screen.
//

import AppKit
import WebKit

@MainActor
final class WebViewWindowController: NSWindowController {

    let webView: WKWebView

    /// Tracks pending navigation so callers can `await` page-load completion.
    private(set) var navigationDelegate: WebViewNavigationDelegate

    init(viewport: CGSize) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false

        // **Non-persistent website data store.** Every run starts with
        // a clean slate: no cookies, no localStorage, no IndexedDB, no
        // service-worker registrations. Two reasons this matters:
        //
        //  1. **Reproducibility.** SPAs that store theme / locale /
        //     dismissed-banner state in localStorage will render
        //     differently across runs depending on what the previous
        //     run did. Persistent state diverges between the CLI
        //     (`com.harness.cli`) and the GUI (`com.harness.app`)
        //     because each binary has its own data-store directory —
        //     producing different first-load renders even on the same
        //     machine. Non-persistent removes the variance entirely.
        //  2. **"What a fresh user sees."** Harness is a UX testing
        //     tool. The agent's screenshots are most informative when
        //     they reflect a first-time-visitor's experience. Stored
        //     auth tokens, dismissed CTAs, and persisted theme choices
        //     hide failure modes a new user would hit.
        //
        // Logged-in flows are handled per-run via
        // `fill_credential(field:)`; nothing in the credential path
        // depends on persistent storage.
        cfg.websiteDataStore = .nonPersistent()

        // Inspectable in dev builds — useful when authoring web personas
        // and debugging element targeting.
        if #available(macOS 13.3, *) {
            cfg.preferences.isElementFullscreenEnabled = true
        }
        let web = WKWebView(frame: NSRect(origin: .zero, size: viewport), configuration: cfg)
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        self.webView = web

        let nav = WebViewNavigationDelegate()
        web.navigationDelegate = nav
        self.navigationDelegate = nav

        // Off-screen window. Putting it at a far-negative origin keeps it
        // out of the way without triggering the AppKit "you must have a
        // visible screen" warnings — the window IS on a screen, just not
        // a visible region.
        let style: NSWindow.StyleMask = [.borderless]
        let frame = NSRect(x: -10_000, y: -10_000, width: viewport.width, height: viewport.height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden

        // Bind the window's NSAppearance to the **user's system Dark Mode
        // preference**, not the host app's appearance. WKWebView inherits
        // its window's appearance and uses it to resolve
        // `prefers-color-scheme` for the loaded page.
        //
        // Why not just inherit from NSApp:
        //   - In the GUI binary, the host app may render itself in a
        //     different mode than the user's system (e.g. an app that
        //     forces .aqua for branding while macOS is in Dark). The
        //     agent would then test the page's light variant even
        //     though every real user with Dark Mode on sees the dark
        //     variant. We want the agent's screenshots to match what
        //     a real user with the user's settings sees.
        //   - In the CLI binary, NSApp has no appearance set
        //     (`.prohibited` activation policy, no Info.plist
        //     `NSRequiresAquaSystemAppearance`), so it defaults to
        //     system anyway — this code path produces the same result
        //     there.
        //
        // `AppleInterfaceStyle` is the canonical user default for the
        // system-wide Dark Mode toggle (System Settings → Appearance).
        // It's absent ("nil") for Light, "Dark" for Dark. Reading it
        // via UserDefaults.standard cascades through NSGlobalDomain,
        // so it reflects the user's system choice regardless of the
        // host app's own preference.
        let appleInterfaceStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        let systemIsDark = appleInterfaceStyle == "Dark"
        window.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)

        super.init(window: window)
        // Make the window visible so layout pipelines run; off-screen
        // origin keeps it out of the user's way.
        window.orderBack(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WebViewWindowController is created in code only.")
    }

    /// Resize the WebView to a new CSS-pixel viewport. Called when the
    /// run's RunRequest carries a viewport override.
    func resize(_ viewport: CGSize) {
        webView.frame = NSRect(origin: .zero, size: viewport)
        if let window = self.window {
            var f = window.frame
            f.size = viewport
            window.setFrame(f, display: false)
        }
    }

    /// Tear down — closes the off-screen window and releases the WebView.
    /// `RunCoordinator` calls this at run teardown. Idempotent.
    func close() async {
        webView.stopLoading()
        webView.navigationDelegate = nil
        self.window?.contentView = nil
        self.window?.close()
    }
}

/// Tracks the most recent navigation completion so the driver can `await`
/// page load. WKWebView's delegate callbacks happen on the main actor.
@MainActor
final class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    /// Pending continuations waiting for `didFinish` to fire. We support
    /// at most one pending wait at a time — driver methods serialise on
    /// the actor, so concurrent waits aren't possible.
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    /// Block the driver until the next `didFinish` (or `didFail`) navigation.
    /// Times out after `timeout`; the driver continues regardless so a
    /// stuck navigation doesn't stall the run forever.
    func awaitNextLoad(timeout: Duration) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.pendingWaiters.append(cont)
            // Schedule a timeout that resumes the continuation if it
            // hasn't fired by then. Idempotent — `flushWaiters` clears
            // the list after firing, and `resume()` on an already-resumed
            // checked continuation traps, so we make the closure-side
            // resume conditional on the waiter still being present.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.flushPendingWaitersOnTimeout()
            }
        }
    }

    private func flushPendingWaitersOnTimeout() {
        let toResume = pendingWaiters
        pendingWaiters.removeAll()
        for cont in toResume { cont.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let waiters = self.pendingWaiters
            self.pendingWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiters = self.pendingWaiters
            self.pendingWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiters = self.pendingWaiters
            self.pendingWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
