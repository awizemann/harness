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
