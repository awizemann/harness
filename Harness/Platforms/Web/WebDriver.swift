//
//  WebDriver.swift
//  Harness
//
//  `UXDriving` for an embedded `WKWebView`. Screenshots come from
//  `WKWebView.takeSnapshot(with:)`; mouse and keyboard events are
//  synthesised in JS via `dispatchEvent` on the topmost element at
//  the requested coordinate. Navigation goes through `WKWebView.load`
//  / `goBack` / `goForward` / `reload`.
//
//  CSS-pixel space: the agent's coordinates are in CSS pixels, which
//  matches WKWebView's logical layout space. No conversion needed.
//
//  v1 ships against WebKit only. A future opt-in CDP-based driver
//  (Chrome) would conform to the same `UXDriving` protocol — see the
//  Phase-3 standard `15-web-driver.md`.
//

import Foundation
import AppKit
import WebKit

actor WebDriver: UXDriving {

    private let controller: WebViewWindowController
    private let startURL: URL?
    private let viewport: CGSize

    init(controller: WebViewWindowController, startURL: URL?, viewport: CGSize) {
        self.controller = controller
        self.startURL = startURL
        self.viewport = viewport
    }

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        let image = try await captureSnapshot()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw WebDriverError.captureFailed
        }
        try png.write(to: url, options: .atomic)
        return ScreenshotMetadata(
            pixelSize: image.size,
            pointSize: viewport
        )
    }

    func execute(_ call: ToolCall) async throws {
        switch call.input {
        case .tap(let x, let y):
            try await dispatchClick(x: x, y: y, button: 0, count: 1)
        case .doubleTap(let x, let y):
            try await dispatchClick(x: x, y: y, button: 0, count: 2)
        case .rightClick(let x, let y):
            try await dispatchClick(x: x, y: y, button: 2, count: 1)
        case .scroll(let x, let y, let dx, let dy):
            try await dispatchScroll(x: x, y: y, dx: dx, dy: dy)
        case .type(let text):
            try await dispatchType(text)
        case .keyShortcut(let keys):
            try await dispatchKeyShortcut(keys)
        case .navigate(let urlString):
            try await navigate(urlString)
        case .back:
            await goBack()
        case .forward:
            await goForward()
        case .refresh:
            await reload()
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .readScreen, .noteFriction, .markGoalDone:
            return
        case .swipe, .pressButton:
            throw UXDriverError.unsupportedTool(name: call.tool.rawValue, platform: .web)
        }
    }

    func relaunchForNewLeg() async throws {
        // Reload the start URL — closest analogue to "reinstall + relaunch"
        // for a stateless web app. Cookies are preserved by the same
        // WKWebsiteDataStore, which matches expectations for chained
        // legs (you usually want to stay logged in).
        if let url = startURL {
            try await navigate(url.absoluteString)
        } else {
            await reload()
        }
    }

    /// Adapter-only teardown hook — closes the off-screen window
    /// controller hosting the WebView.
    func closeUnderlyingWindow() async {
        await controller.close()
    }

    // MARK: - WebKit primitives (run on the main actor)

    private func captureSnapshot() async throws -> NSImage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSImage, any Error>) in
            Task { @MainActor in
                let cfg = WKSnapshotConfiguration()
                cfg.afterScreenUpdates = true
                self.controller.webView.takeSnapshot(with: cfg) { image, error in
                    if let image = image {
                        cont.resume(returning: image)
                    } else {
                        cont.resume(throwing: error ?? WebDriverError.captureFailed)
                    }
                }
            }
        }
    }

    private func dispatchClick(x: Int, y: Int, button: Int, count: Int) async throws {
        let js = """
        (() => {
          const x = \(x), y = \(y);
          const el = document.elementFromPoint(x, y);
          if (!el) return false;
          const opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: \(button), buttons: \(button == 0 ? 1 : 2), view: window };
          for (let i = 0; i < \(count); i++) {
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            el.dispatchEvent(new MouseEvent(\(button == 2 ? "'contextmenu'" : "'click'"), opts));
          }
          if (el.focus) try { el.focus(); } catch (e) {}
          return true;
        })();
        """
        try await runJS(js)
    }

    private func dispatchScroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        // Convert "lines" to pixels — 40px per line is the de facto
        // browser convention.
        let pxX = dx * 40
        let pxY = dy * 40
        let js = """
        (() => {
          const x = \(x), y = \(y);
          const el = document.elementFromPoint(x, y) || document.scrollingElement;
          if (!el) return false;
          // Dispatch a wheel event on the element under the pointer.
          el.dispatchEvent(new WheelEvent('wheel', {
            bubbles: true, cancelable: true,
            clientX: x, clientY: y,
            deltaX: \(pxX), deltaY: \(pxY)
          }));
          // Also nudge the scrolling element directly so scrollable
          // containers without explicit wheel listeners still respond.
          (el.scrollBy || (() => {})).call(el, \(pxX), \(pxY));
          return true;
        })();
        """
        try await runJS(js)
    }

    private func dispatchType(_ text: String) async throws {
        // Insert text into the focused field. Falls back to
        // `document.execCommand("insertText")` on contenteditable
        // surfaces; otherwise sets `value` and dispatches input events
        // so React-style listeners pick the change up.
        let escaped = Self.jsEscape(text)
        let js = """
        (() => {
          const el = document.activeElement;
          if (!el) return false;
          const text = "\(escaped)";
          if (el.isContentEditable) {
            document.execCommand && document.execCommand('insertText', false, text);
          } else if ('value' in el) {
            const start = el.selectionStart ?? el.value.length;
            const end = el.selectionEnd ?? el.value.length;
            el.value = el.value.slice(0, start) + text + el.value.slice(end);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            return false;
          }
          return true;
        })();
        """
        try await runJS(js)
    }

    private func dispatchKeyShortcut(_ keys: [String]) async throws {
        // For browser apps, most "Cmd-key" shortcuts are intercepted by
        // the browser chrome rather than the page. Fire keydown/keyup
        // events with modifier flags so the page-level handlers (e.g.
        // SPA save shortcuts) still fire. Browser-chrome shortcuts
        // (Cmd+L, Cmd+T) won't work — that's a v2 CDP feature.
        let lowered = keys.map { $0.lowercased() }
        let modifierNames: Set<String> = ["cmd", "command", "shift", "option", "alt", "ctrl", "control", "fn"]
        let modifiers = lowered.filter { modifierNames.contains($0) }
        guard let finalKey = lowered.last(where: { !modifierNames.contains($0) }) else { return }

        let metaKey = modifiers.contains(where: { $0 == "cmd" || $0 == "command" })
        let shiftKey = modifiers.contains("shift")
        let altKey = modifiers.contains(where: { $0 == "option" || $0 == "alt" })
        let ctrlKey = modifiers.contains(where: { $0 == "ctrl" || $0 == "control" })

        let keyEsc = Self.jsEscape(finalKey)
        let js = """
        (() => {
          const el = document.activeElement || document.body;
          const opts = {
            key: "\(keyEsc)",
            code: "Key\(finalKey.uppercased())",
            bubbles: true,
            cancelable: true,
            metaKey: \(metaKey),
            shiftKey: \(shiftKey),
            altKey: \(altKey),
            ctrlKey: \(ctrlKey)
          };
          el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
          return true;
        })();
        """
        try await runJS(js)
    }

    private func navigate(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw WebDriverError.invalidURL(urlString) }
        await MainActor.run {
            self.controller.webView.load(URLRequest(url: url))
        }
        let nav = await MainActor.run { self.controller.navigationDelegate }
        await nav.awaitNextLoad(timeout: .seconds(20))
    }

    private func goBack() async {
        await MainActor.run {
            _ = self.controller.webView.goBack()
        }
    }

    private func goForward() async {
        await MainActor.run {
            _ = self.controller.webView.goForward()
        }
    }

    private func reload() async {
        await MainActor.run {
            _ = self.controller.webView.reload()
        }
        let nav = await MainActor.run { self.controller.navigationDelegate }
        await nav.awaitNextLoad(timeout: .seconds(20))
    }

    /// Run JS for its side-effects only. WKWebView's callback delivers a
    /// non-Sendable `Any?` result; we never need it for the input-event
    /// path, so we discard the value and only surface the error (if any).
    private func runJS(_ js: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                self.controller.webView.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    /// Escape a string for safe interpolation into a JS source literal.
    private static func jsEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return out
    }
}

enum WebDriverError: Error, Sendable, LocalizedError {
    case captureFailed
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "WKWebView snapshot failed."
        case .invalidURL(let s): return "Invalid URL: '\(s)'."
        }
    }
}
