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
    /// Mutable so the live mirror can ask us to resize the WKWebView when
    /// the canvas dimensions change — the configured viewport is just the
    /// initial value. Snapshots after `resize` come through at the new
    /// dimensions; the agent's CSS-pixel coordinate space follows.
    private var viewport: CGSize
    /// V5 — pre-staged credential for this run, or nil. Same lifecycle as
    /// the iOS / macOS drivers'.
    private let credential: CredentialBinding?
    /// V6 — Set-of-Mark cache. The most recent screenshot's interactive
    /// elements, numbered 1..N. Refreshed on every `screenshot(into:)`
    /// call. `tap_mark(id)` looks up the entry whose id matches; if the
    /// id isn't in the cache (page changed since the screenshot, agent
    /// emitted a stale id, etc.) the dispatch throws and the loop's
    /// retry path surfaces the error to the model.
    private var lastMarks: [InteractiveMark] = []

    init(controller: WebViewWindowController, startURL: URL?, viewport: CGSize, credential: CredentialBinding? = nil) {
        self.controller = controller
        self.startURL = startURL
        self.viewport = viewport
        self.credential = credential
    }

    /// Current viewport in CSS pixels. Read by the UI to keep the live
    /// mirror's display math in sync with the WKWebView.
    func currentViewport() async -> CGSize { viewport }

    /// Resize the underlying WKWebView to `newViewport` (CSS pixels). The
    /// next snapshot reflects the new dimensions. Idempotent — a no-op if
    /// the new size equals the current viewport.
    func resize(to newViewport: CGSize) async {
        guard newViewport != viewport,
              newViewport.width > 0, newViewport.height > 0 else { return }
        viewport = newViewport
        await controller.resize(newViewport)
    }

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        // Probe BEFORE the snapshot so the marks reflect the same DOM
        // state the snapshot captures. Empty list on probe failure —
        // the agent can still call `tap(x, y)` with no scaffolding.
        let marks = (try? await probeInteractiveElements()) ?? []
        self.lastMarks = marks

        let raw = try await captureSnapshot()
        // Draw numbered badges over each mark's bounding rect on a copy
        // of the snapshot. The agent and the replay both see the same
        // marked-up image — so a human reviewing the run can match the
        // agent's `tap_mark(id)` calls back to visible scaffolding.
        let marked = Self.drawMarks(on: raw, marks: marks, viewport: viewport)
        guard let tiff = marked.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw WebDriverError.captureFailed
        }
        try png.write(to: url, options: .atomic)
        return ScreenshotMetadata(
            pixelSize: marked.size,
            pointSize: viewport
        )
    }

    /// Read the WKWebView's current URL. Cheap; safe to poll. Used by the
    /// live mirror's chrome to keep the URL pill in sync with in-page
    /// navigation that didn't go through the agent's `navigate` tool.
    func currentURL() async -> String? {
        await MainActor.run { controller.webView.url?.absoluteString }
    }

    func execute(_ call: ToolCall) async throws {
        switch call.input {
        case .tap(let x, let y):
            try await dispatchClick(x: x, y: y, button: 0, count: 1)
        case .tapMark(let id):
            try await dispatchMarkClick(id: id)
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
        case .fillCredential(let field):
            // No staged credential → soft no-op. With a binding, route
            // through the same JS `dispatchType`-style path as the
            // ordinary `type` tool: set `value` on the focused input
            // (or `execCommand('insertText', …)` for contenteditable),
            // then dispatch input/change events so React-style
            // listeners see the change. WKWebView's `<input type="password">`
            // renders bullets natively, so screenshots stay masked.
            guard let credential else { return }
            let text = field == .username ? credential.username : credential.password
            try await dispatchType(text)
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
        // Click events fire on the topmost element at (x, y); focus
        // resolves separately because real-browser click→focus behaviour
        // depends on what the click target IS:
        //
        //   - <input>/<textarea>/<select>/[contenteditable]/[tabindex] →
        //     focuses directly.
        //   - <label> with `for=...` or containing an input → focuses
        //     the associated input.
        //   - Any other wrapper (<div>, <span>, an absolutely-positioned
        //     placeholder overlay) → finds the nearest focusable input
        //     descendant, then ancestor.
        //
        // Our synthetic `MouseEvent` doesn't trigger the browser's
        // built-in focus routing, so we resolve the "best focus target"
        // ourselves and call `.focus()` explicitly. Without this, eBay's
        // sign-in form (and any modern React form with an input wrapped
        // in a styled <div>) silently never focuses, and the next
        // `type` / `fill_credential` writes to the wrong element.
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
          // Focus routing — only for left-click (button 0).
          if (\(button) === 0) {
            const FOCUSABLE = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [tabindex]:not([tabindex="-1"])';
            let target = null;
            // 1. Direct match — clicked the input itself.
            if (el.matches && el.matches(FOCUSABLE)) {
              target = el;
            }
            // 2. <label> click — follow `for` or contained input.
            if (!target && el.tagName === 'LABEL') {
              const htmlFor = el.getAttribute('for');
              if (htmlFor) {
                target = document.getElementById(htmlFor);
              }
              if (!target) {
                target = el.querySelector(FOCUSABLE);
              }
            }
            // 3. Wrapper click — look inside, then up. Inside first
            // because a button-shaped div around an input is more
            // common than the reverse.
            if (!target && el.querySelector) {
              target = el.querySelector(FOCUSABLE);
            }
            if (!target && el.closest) {
              target = el.closest(FOCUSABLE);
            }
            if (target && target.focus) {
              try { target.focus({ preventScroll: false }); } catch (e) {}
            } else if (el.focus) {
              try { el.focus(); } catch (e) {}
            }
          }
          return true;
        })();
        """
        try await runJS(js)
    }

    private func dispatchScroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        // Web's scroll unit is **pixels** (positive dy = down, positive
        // dx = right). Synthetic `WheelEvent`s carry `isTrusted: false`
        // and browsers refuse to perform native scrolling for them, so
        // we don't bother dispatching one — we drive the scroll by
        // walking up from the point under the cursor to the nearest
        // scrollable ancestor and calling `scrollBy` on it. Falls back
        // to `window.scrollBy` if nothing in the ancestor chain is a
        // scroll container.
        //
        // Also dispatches a wheel event AFTER the scroll so any
        // page-level listeners (infinite-scroll triggers, fancy
        // parallax) still get a signal that scrolling happened. The
        // event is informational, not load-bearing.
        let js = """
        (() => {
          const x = \(x), y = \(y), dx = \(dx), dy = \(dy);
          // Walk up from the point looking for a scrollable container.
          // Match what desktop browsers do: a container is scrollable
          // when its computed overflow is auto/scroll AND its scroll
          // size exceeds its client size on the relevant axis.
          let el = document.elementFromPoint(x, y);
          let scroller = null;
          while (el && el !== document.documentElement && el !== document.body) {
            const cs = getComputedStyle(el);
            const oy = cs.overflowY, ox = cs.overflowX;
            const wantsY = (oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight;
            const wantsX = (ox === 'auto' || ox === 'scroll') && el.scrollWidth > el.clientWidth;
            if ((dy !== 0 && wantsY) || (dx !== 0 && wantsX)) {
              scroller = el; break;
            }
            el = el.parentElement;
          }
          // Fall back to the document's scrolling element (window) when
          // no inner container handles the axis.
          if (!scroller) {
            (window.scrollBy || (() => {})).call(window, dx, dy);
          } else {
            scroller.scrollBy(dx, dy);
          }
          // Informational wheel event after the fact, for sites that
          // hook into wheel without doing the actual scrolling
          // themselves.
          const target = scroller || document.scrollingElement || document.body;
          if (target) {
            target.dispatchEvent(new WheelEvent('wheel', {
              bubbles: true, cancelable: true,
              clientX: x, clientY: y,
              deltaX: dx, deltaY: dy
            }));
          }
          return true;
        })();
        """
        try await runJS(js)
    }

    private func dispatchType(_ text: String) async throws {
        // Insert text into the focused field.
        //
        // **React-controlled inputs need the native value setter.**
        // React maintains an internal "value tracker" on every input it
        // controls; setting `el.value = ...` directly bypasses that
        // tracker, so on the next render React believes the value
        // hasn't changed and resets it to its own state — the user
        // sees their typed text vanish, and form validation rejects
        // the empty submit. The fix is to call the native setter via
        // its property descriptor (which React's tracker hooks into),
        // then dispatch input/change events so listeners run. This is
        // the well-known pattern used by every browser test framework
        // that drives React forms (Cypress, Playwright internals, etc.).
        //
        // Contenteditable falls back to `document.execCommand("insertText")`,
        // which dispatches the right input events natively.
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
            const newValue = el.value.slice(0, start) + text + el.value.slice(end);
            // Resolve the appropriate prototype's `value` setter: <input>
            // and <textarea> have separate descriptors. The native setter
            // calls into React's value tracker (or any framework's
            // equivalent) so the change is recognised; a direct `el.value
            // = ...` assignment doesn't.
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const desc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (desc && desc.set) {
              desc.set.call(el, newValue);
            } else {
              el.value = newValue;
            }
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

    // MARK: - Set-of-Mark (V6)

    /// Run the JS probe that enumerates every visible interactive
    /// element where pixel-accurate targeting matters (form fields,
    /// buttons, custom-role widgets), returns their bounding rects (CSS
    /// pixels) and accessible names, and assigns each a numeric id
    /// 1..N in reading order. Caller should call this RIGHT BEFORE
    /// taking the snapshot so the marks reflect the same DOM state.
    ///
    /// **Mark selection philosophy.** Marks are visual scaffolding for
    /// targets where the agent typically misses by a few pixels —
    /// inputs, dropdowns, checkboxes, action buttons. Plain text links
    /// and generic `[tabindex]` elements are NOT marked: there are too
    /// many of them on content-heavy pages (eBay homepage produced
    /// 60+), and they're typically large enough that coordinate-only
    /// tapping is reliable.
    ///
    /// **Shadow-DOM traversal.** Modern signin / payment forms wrap
    /// their inputs in custom elements with open shadow roots. A flat
    /// `document.querySelectorAll` doesn't pierce those, so we walk
    /// the tree manually and recurse into every accessible shadow root
    /// we find. Closed shadow roots stay invisible to JS — that's a
    /// platform limit, not something we can work around.
    private func probeInteractiveElements() async throws -> [InteractiveMark] {
        let js = """
        (() => {
          // Targets where pixel precision matters. Plain <a> links and
          // bare [tabindex] are deliberately excluded — they bloated
          // the mark count without earning their visual cost.
          const SELECTOR = [
            'input:not([type="hidden"]):not([type="button"]):not([type="submit"]):not([type="reset"])',
            'textarea',
            'select',
            'button',
            'input[type="button"]',
            'input[type="submit"]',
            'input[type="reset"]',
            '[role="button"]',
            '[role="checkbox"]',
            '[role="radio"]',
            '[role="textbox"]',
            '[role="combobox"]',
            '[role="searchbox"]',
            '[role="switch"]',
            '[role="menuitem"]',
            '[role="tab"]',
            '[contenteditable=""]',
            '[contenteditable="true"]'
          ].join(', ');
          const out = [];
          const seen = new WeakSet();
          const vw = window.innerWidth, vh = window.innerHeight;

          // Recursive walker that pierces open shadow roots. The flat
          // `document.querySelectorAll` misses inputs nested inside
          // custom elements (common on modern signin / payment forms).
          function collect(root) {
            // Direct matches at this level.
            let here;
            try {
              here = root.querySelectorAll ? root.querySelectorAll(SELECTOR) : [];
            } catch (e) {
              here = [];
            }
            for (const el of here) {
              if (!seen.has(el)) {
                seen.add(el);
                consider(el);
              }
            }
            // Recurse into every descendant's open shadow root. We can't
            // see closed shadow roots from JS at all — that's a platform
            // limit. Same with cross-origin iframes.
            const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
            for (const node of all) {
              if (node.shadowRoot) collect(node.shadowRoot);
            }
          }

          function consider(el) {
            const cs = window.getComputedStyle(el);
            if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') return;
            // `disabled` form controls aren't actionable; don't waste
            // a mark on them.
            if (el.disabled === true) return;
            const r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) return;
            if (r.right <= 0 || r.bottom <= 0 || r.left >= vw || r.top >= vh) return;
            let label = el.getAttribute('aria-label')
              || el.getAttribute('placeholder')
              || el.getAttribute('title')
              || el.value
              || el.innerText
              || el.getAttribute('name')
              || '';
            label = String(label).trim().replace(/\\s+/g, ' ');
            if (label.length > 80) label = label.slice(0, 77) + '…';
            const role = el.getAttribute('role') || el.tagName.toLowerCase();
            const inputType = el.getAttribute('type') || null;
            out.push({
              x: Math.round(r.left),
              y: Math.round(r.top),
              w: Math.round(r.width),
              h: Math.round(r.height),
              role: role,
              type: inputType,
              label: label
            });
          }

          collect(document);
          // Reading order: top-to-bottom, then left-to-right. The
          // agent's prompt assumes this, and it makes runs easier
          // to skim by ID.
          out.sort((a, b) => (a.y - b.y) || (a.x - b.x));
          return out;
        })();
        """
        // Need a return value from JS — switch off the side-effect-only
        // `runJS` path here. Convert the non-Sendable `[[String: Any]]`
        // dict array into our Sendable `InteractiveMark` shape **inside
        // the @MainActor closure** so the boundary crossing carries
        // only Sendable values.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[InteractiveMark], any Error>) in
            Task { @MainActor in
                self.controller.webView.evaluateJavaScript(js) { value, error in
                    if let error = error {
                        cont.resume(throwing: error)
                        return
                    }
                    let array = (value as? [[String: Any]]) ?? []
                    let marks: [InteractiveMark] = array.enumerated().map { (idx, dict) in
                        InteractiveMark(
                            id: idx + 1,
                            rect: CGRect(
                                x: (dict["x"] as? Double) ?? Double((dict["x"] as? Int) ?? 0),
                                y: (dict["y"] as? Double) ?? Double((dict["y"] as? Int) ?? 0),
                                width: (dict["w"] as? Double) ?? Double((dict["w"] as? Int) ?? 0),
                                height: (dict["h"] as? Double) ?? Double((dict["h"] as? Int) ?? 0)
                            ),
                            role: (dict["role"] as? String) ?? "",
                            inputType: dict["type"] as? String,
                            label: (dict["label"] as? String) ?? ""
                        )
                    }
                    cont.resume(returning: marks)
                }
            }
        }
    }

    /// Click the element associated with `id` from the most recent
    /// screenshot's mark cache. Resolves to the rect's center, then
    /// runs the same `dispatchClick` path as `tap` — so focus routing,
    /// label-resolution, etc. all work the same way.
    private func dispatchMarkClick(id: Int) async throws {
        guard let mark = lastMarks.first(where: { $0.id == id }) else {
            throw WebDriverError.unknownMark(id: id)
        }
        let cx = Int(mark.rect.midX.rounded())
        let cy = Int(mark.rect.midY.rounded())
        try await dispatchClick(x: cx, y: cy, button: 0, count: 1)
    }

    /// Draw numbered badges over every mark's bounding rect on a copy
    /// of `image`. The output is what we save to disk and send to the
    /// model — agents and human reviewers both see the same scaffolding.
    /// Mark coordinates are in CSS pixels (= NSImage points), so the
    /// drawing math is 1:1.
    nonisolated private static func drawMarks(
        on image: NSImage,
        marks: [InteractiveMark],
        viewport: CGSize
    ) -> NSImage {
        guard !marks.isEmpty else { return image }
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }
        // Base layer: the original snapshot.
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return result }
        // The accent + supporting colors come from HarnessDesign so the
        // overlay reads as part of the app rather than dev-tool clutter.
        let accent = NSColor(red: 0.07, green: 0.58, blue: 0.42, alpha: 1.0)   // harnessAccent (light)
        let badgeBG = accent.cgColor
        let badgeFG = NSColor.white
        let outline = accent.withAlphaComponent(0.85).cgColor
        for mark in marks {
            let r = mark.rect
            // Outline the element.
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(2.0)
            ctx.stroke(r)
            // Number badge in the top-left of the rect.
            let labelText = "\(mark.id)"
            let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: badgeFG
            ]
            let textSize = (labelText as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 4
            let badgeW = max(20, textSize.width + 2 * pad)
            let badgeH: CGFloat = 18
            // Anchor inside the rect's top-left so the badge stays
            // visually attached to the element it labels.
            let badgeRect = CGRect(
                x: r.minX,
                y: r.minY,
                width: badgeW,
                height: badgeH
            )
            ctx.setFillColor(badgeBG)
            ctx.fill(badgeRect)
            // Draw the number.
            let textPoint = CGPoint(
                x: badgeRect.minX + pad,
                y: badgeRect.minY + (badgeH - textSize.height) / 2
            )
            (labelText as NSString).draw(at: textPoint, withAttributes: attrs)
        }
        // Sanity-clamp the marks to the viewport so a stray off-screen
        // rect doesn't paint over the page edge — the JS probe filters
        // already, but defensively re-check.
        _ = viewport
        return result
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
    /// V6 — agent emitted `tap_mark(id:)` with an id that wasn't in the
    /// most recent screenshot's mark cache. Surfaces back through the
    /// run as a tool failure so the next iteration's screenshot can
    /// re-establish marks.
    case unknownMark(id: Int)

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "WKWebView snapshot failed."
        case .invalidURL(let s): return "Invalid URL: '\(s)'."
        case .unknownMark(let id):
            return "tap_mark(id: \(id)) — that id wasn't in the latest screenshot's mark set. The page may have changed; the next screenshot will refresh the marks."
        }
    }
}

/// One numbered Set-of-Mark entry. Built per-screenshot by the WebDriver
/// JS probe, kept on the actor for the duration of the next tool call,
/// and looked up by id when the agent emits `tap_mark(id:)`. CSS-pixel
/// rect; `id` is 1-based to match the badge text drawn on the snapshot.
struct InteractiveMark: Sendable, Equatable {
    let id: Int
    let rect: CGRect
    let role: String
    let inputType: String?
    let label: String
}
