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
import os

actor WebDriver: UXDriving {

    nonisolated private static let logger = Logger(subsystem: "com.harness.app", category: "WebDriver")

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
    /// Set by `dispatchClick` when the click changed `location.href`
    /// (an SPA route push or a hard navigation). Consumed by the
    /// next `settle(afterTool:)` to escalate to the navigation-class
    /// quietness window — see the rationale on `settle(afterTool:)`.
    /// Reset to `false` after each settle.
    private var lastClickNavigated: Bool = false
    /// Driver-side diagnostic text for the most recent `execute(_:)`
    /// call. Surfaced into the next turn's `toolResultSummary` via
    /// `lastExecutionDetail()` so the agent's prompt history sees
    /// objective progress signals alongside the model's own text
    /// observations. Today only `dispatchScroll` populates this;
    /// other tools leave it nil and the coordinator falls back to
    /// the bare "ok"/"fail" summary.
    private var lastDriverDetail: String?
    /// Count of consecutive `scroll` calls whose `scrollY` didn't
    /// move (within `scrollNoProgressEpsilonPx`). Used by the
    /// scroll-progress feedback path to surface a stronger signal
    /// to the model ("you've scrolled here 2 times without moving;
    /// try a different action") when the page can't scroll further
    /// in the requested direction. Resets on any successful (delta)
    /// scroll or on a different tool.
    private var consecutiveNoProgressScrolls: Int = 0
    /// Pixel threshold below which a scroll is considered to have
    /// produced no progress. Set to 4 to tolerate sub-pixel rounding
    /// and end-of-scroll bounce-back animations that briefly tick a
    /// few pixels before settling back.
    private static let scrollNoProgressEpsilonPx: Double = 4

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
        Self.logger.info("screenshot probed \(marks.count, privacy: .public) interactive marks (viewport=\(Int(self.viewport.width), privacy: .public)×\(Int(self.viewport.height), privacy: .public))")

        let raw = try await captureSnapshot()
        // Save the **unmarked** snapshot to disk. Replay, friction
        // reports, and exported screenshots all read this PNG — keeping
        // it clean means the green numbered overlay (which is agent
        // scaffolding, not part of the page) never leaks into surfaces
        // a human reviewer sees.
        guard let rawPNG = Self.pngData(from: raw) else {
            throw WebDriverError.captureFailed
        }
        try rawPNG.write(to: url, options: .atomic)

        // Render the marked copy in-memory only when there's something
        // to draw. The agent loop receives these bytes via
        // `ScreenshotMetadata.markedImageData`; everything else (disk,
        // replay, friction report) keeps using the unmarked PNG.
        let markedImage: NSImage? = marks.isEmpty
            ? nil
            : Self.drawMarks(on: raw, marks: marks, viewport: viewport)
        let markedData: Data? = markedImage.flatMap { Self.pngData(from: $0) }

        // Dev-only: when `HARNESS_DUMP_MARKED=1` is set, also write the
        // marked overlay to disk next to the unmarked PNG with a
        // `-marked.png` suffix. Lets HarnessCLI users inspect exactly
        // what the LLM sees (badge sizes, probe coverage, missing
        // anchors) without instrumenting the binary further. Skipped
        // for the GUI / shipping app — the env var is never set there.
        if let markedData,
           ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let markedURL = url
                .deletingPathExtension()
                .appendingPathExtension("marked.png")
            try? markedData.write(to: markedURL, options: .atomic)
        }

        let annotationText: String? = marks.isEmpty
            ? nil
            : Self.describeMarks(marks)

        return ScreenshotMetadata(
            pixelSize: raw.size,
            pointSize: viewport,
            markedImageData: markedData,
            markedAnnotationText: annotationText
        )
    }

    /// Render the Set-of-Mark cache into a compact text block the
    /// agent loop injects into the per-turn user message. Each mark
    /// gets one line of `id → "label" (role/inputType)` so the model
    /// can map intent → id by label without re-reading the badge
    /// numbers from the image. Crucial for small vision models —
    /// without it they reliably anchor on stale ids ("id 6 must still
    /// be Articles because it was Articles last turn") across page
    /// transitions where the numbering shifts.
    ///
    /// Format is intentionally terse — typical pages produce 10-30
    /// marks, capped at 80 by the probe. Even at the cap this lands
    /// well under 2KB of extra prompt tokens.
    nonisolated static func describeMarks(_ marks: [InteractiveMark]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(marks.count + 2)
        lines.append("MARKS — you MUST call `tap_mark(id)` using one of the ids below to click any of these elements. Never invent or remember an id from a prior turn — these ids are valid ONLY for the screenshot attached to THIS turn:")
        for mark in marks {
            let roleHint: String = {
                if let t = mark.inputType, !t.isEmpty { return "\(mark.role)/\(t)" }
                return mark.role
            }()
            let label = mark.label.isEmpty ? "(no label)" : "\"\(mark.label)\""
            lines.append("  \(mark.id) → \(label) (\(roleHint))")
        }
        return lines.joined(separator: "\n")
    }

    /// Read the WKWebView's current URL. Cheap; safe to poll. Used by the
    /// live mirror's chrome to keep the URL pill in sync with in-page
    /// navigation that didn't go through the agent's `navigate` tool.
    func currentURL() async -> String? {
        await MainActor.run { controller.webView.url?.absoluteString }
    }

    func execute(_ call: ToolCall) async throws {
        // Clear the previous tool's diagnostic detail. Only
        // `dispatchScroll` populates this today; other tools should
        // surface bare "ok" in the agent's history. The non-scroll
        // path's reset also ensures `consecutiveNoProgressScrolls`
        // restarts whenever the agent does something other than
        // scroll — a tap or wait between scrolls counts as a fresh
        // start.
        if case .scroll = call.input {
            // Keep counter; `dispatchScroll` manages it.
        } else {
            consecutiveNoProgressScrolls = 0
        }
        lastDriverDetail = nil
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

    /// Live-preview snapshot for the UI mirror — driven by
    /// `RunCoordinator`'s preview poller between `simulatorReady` and
    /// `runCompleted`. Captures the current WKWebView contents and
    /// returns JPEG bytes for display only (the LLM-bound step
    /// screenshot goes through `screenshot(into:)` separately).
    ///
    /// Returns nil on any error so the poller can keep ticking without
    /// noisy log spam — a transient capture failure is expected
    /// during navigations and isn't a run-fatal condition.
    func liveSnapshot() async -> Data? {
        do {
            let image = try await captureSnapshot()
            // JPEG at 0.7 quality is plenty for an off-the-hot-path
            // mirror — the LLM gets the higher-quality capture via
            // `screenshot(into:)`. Reduces per-tick memory by ~5×
            // versus PNG for typical web content.
            return jpegData(from: image, quality: 0.7)
        } catch {
            return nil
        }
    }

    /// Compress an NSImage to JPEG. Pulled out as a small helper so
    /// `liveSnapshot()` and any future capture path can share it.
    private nonisolated func jpegData(from image: NSImage, quality: Double) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: quality)]
        )
    }

    /// Per-tool settle delay, applied by `RunCoordinator` after the
    /// tool finishes and before the next screenshot capture. Sites with
    /// dynamic / lazy / JS-driven content commonly keep loading for
    /// hundreds of ms after `didFinish` fires, and an immediate
    /// screenshot can catch a half-painted page (the most visible
    /// failure mode on local-model runs where the screenshot then
    /// drives 30-second inference).
    ///
    /// Strategy: prefer a MutationObserver-backed quietness gate (the
    /// page tells us when it's actually done hydrating / animating),
    /// fall back to a fixed sleep if the JS bridge fails. Earlier
    /// versions used hard-coded delays; SPAs whose hydration arrived
    /// past the delay window left the agent reading sparse mid-render
    /// screenshots that misled it about what content existed.
    ///
    /// **SPA route-transition special case**: when a click changed
    /// `location.href` (set by `dispatchClick` via
    /// `lastClickNavigatedURL`), we escalate to the navigation-class
    /// settle window even for click-family tools. React's Suspense
    /// keeps the old DOM visible while the new route's components
    /// mount; the mutation observer sees no mutations during this
    /// lull and resolves early. The result without escalation: a
    /// screenshot of the old DOM at the new URL, which then drives
    /// the model's next decision against a hallucinated page state.
    /// Empirically verified against alanwizemann.com (Next.js App
    /// Router) — clicks on `<Link>` anchors triggered route changes
    /// but the post-click screenshot routinely caught the index page
    /// at the article URL.
    func settle(afterTool call: ToolCall) async {
        let idleMs: Int
        let minMs: Int
        let maxMs: Int
        var requireChildListMutation = false
        switch call.input {
        // Navigations re-render the whole page — give the most time.
        // Wide idle window (600ms) plus a long ceiling rides out
        // hydration + lazy image batches without spinning forever on
        // pages with persistent low-rate background activity (analytics
        // beacons, polling, etc.). Hard navigations always require a
        // childList mutation before resolving — a quiet observer
        // during the brief window between unmount-old-tree and
        // mount-new-tree shouldn't be mistaken for "page settled".
        case .navigate, .back, .forward, .refresh:
            idleMs = 600
            minMs = 600
            maxMs = 8000
            requireChildListMutation = true
        // Click-family tools. Default to the tight quietness window;
        // escalate to the navigation profile when the click triggered
        // a URL change (Next.js / React Router / etc. push the new
        // route via pushState inside the click handler, so by the
        // time settle runs we can already tell whether navigation
        // happened). SPA route transitions also require a childList
        // mutation — the original failure mode was the observer
        // catching a Suspense lull and resolving while React kept
        // the previous route's DOM mounted; requiring one structural
        // mutation guarantees the new component tree has begun
        // rendering before we accept idle.
        case .tap, .tapMark, .doubleTap, .rightClick,
             .scroll, .type, .keyShortcut, .fillCredential:
            if lastClickNavigated {
                idleMs = 600
                minMs = 800
                maxMs = 8000
                requireChildListMutation = true
            } else {
                idleMs = 250
                minMs = 250
                maxMs = 2000
            }
        // Pure-read / state-emit tools never change the page; no settle.
        case .wait, .readScreen, .noteFriction, .markGoalDone,
             .swipe, .pressButton:
            return
        }
        // Reset the navigation flag for the next tool — it only
        // applies to the immediately-following settle.
        lastClickNavigated = false
        _ = await awaitDOMSettled(
            idleMs: idleMs,
            minMs: minMs,
            maxMs: maxMs,
            requireChildListMutation: requireChildListMutation
        )
    }

    /// Block until the DOM has gone `idleMs` without a mutation, with a
    /// floor of `minMs` total wait and a ceiling of `maxMs`. Returns
    /// the actual wall-clock time waited (ms) — useful for `os_log`
    /// instrumentation when debugging "page wasn't ready" cases.
    ///
    /// Implementation: a single `callAsyncJavaScript` invocation
    /// installs a `MutationObserver` on `document.documentElement`,
    /// resolves when no callback fires within `idleMs` of the most
    /// recent mutation, with the bounding box enforced in JS so we
    /// only pay the JS-bridge cost once per call.
    ///
    /// When `requireChildListMutation == true`, the gate additionally
    /// refuses to resolve until at least one `childList` mutation has
    /// been observed since the start of the wait. This is the route-
    /// transition guard: a `MutationObserver` watching `document
    /// .documentElement` sees zero mutations during React's Suspense
    /// lull (the old tree is still mounted, no DOM changes occurring),
    /// which lets the idle window fire while the new route hasn't yet
    /// rendered. Requiring a `childList` mutation guarantees the new
    /// route's component tree has begun mounting before we accept
    /// idle as "settled" — attribute / characterData mutations alone
    /// (animations, cursor blinks) aren't enough. Verified against
    /// alanwizemann.com — settles that previously caught the homepage
    /// at `/articles` URL now wait for the index to actually render.
    ///
    /// Falls back to a fixed `minMs` sleep on JS bridge failure (the
    /// most likely cause is the page being navigated away mid-call;
    /// a fixed sleep is conservative).
    func awaitDOMSettled(idleMs: Int, minMs: Int, maxMs: Int, requireChildListMutation: Bool = false) async -> Int {
        // Async-JS body. Receives `idleMs`, `minMs`, `maxMs`,
        // `requireChildList` as locals via `arguments:` —
        // `callAsyncJavaScript` wraps the body in an
        // `async function (idleMs, minMs, maxMs, requireChildList) { ... }`.
        let js = """
        return await new Promise((resolve) => {
          const startedAt = performance.now();
          const target = document.documentElement || document.body;
          if (!target) { resolve(0); return; }
          let lastMut = startedAt;
          let childListSeen = false;
          const obs = new MutationObserver((records) => {
            lastMut = performance.now();
            if (!childListSeen) {
              for (const r of records) {
                if (r.type === 'childList' && (r.addedNodes.length > 0 || r.removedNodes.length > 0)) {
                  childListSeen = true;
                  break;
                }
              }
            }
          });
          obs.observe(target, { childList: true, subtree: true, attributes: true, characterData: true });
          const tick = () => {
            const now = performance.now();
            const sinceMut = now - lastMut;
            const elapsed = now - startedAt;
            if (elapsed >= maxMs) { obs.disconnect(); resolve(Math.round(elapsed)); return; }
            if (elapsed >= minMs && sinceMut >= idleMs && (!requireChildList || childListSeen)) {
              obs.disconnect();
              resolve(Math.round(elapsed));
              return;
            }
            const next = Math.max(50, Math.min(150, idleMs / 4));
            setTimeout(tick, next);
          };
          tick();
        });
        """
        let waitedMs: Int = await Task { @MainActor in
            do {
                // WKWebView's async `callAsyncJavaScript` returns `Any?`
                // — a Promise resolution from the JS body. The body
                // returns an Int via `Math.round`, which bridges to
                // NSNumber (cast as `Int` works), occasionally as
                // `Double` depending on platform — handle both.
                let value = try await self.controller.webView.callAsyncJavaScript(
                    js,
                    arguments: [
                        "idleMs": idleMs,
                        "minMs": minMs,
                        "maxMs": maxMs,
                        "requireChildList": requireChildListMutation
                    ],
                    in: nil,
                    contentWorld: .page
                )
                if let i = value as? Int { return i }
                if let d = value as? Double { return Int(d) }
                return 0
            } catch {
                Self.logger.warning("awaitDOMSettled JS bridge failed: \(error.localizedDescription, privacy: .public); falling back to fixed sleep")
                return -1
            }
        }.value
        if waitedMs < 0 {
            try? await Task.sleep(for: .milliseconds(minMs))
            return minMs
        }
        return waitedMs
    }

    /// Adapter-only teardown hook — closes the off-screen window
    /// controller hosting the WebView.
    func closeUnderlyingWindow() async {
        await controller.close()
    }

    /// Surface the most recent tool's driver-side diagnostic detail so
    /// `RunCoordinator` can fold it into the next turn's
    /// `toolResultSummary`. Today only populated by `dispatchScroll`
    /// — see the `lastDriverDetail` field's doc for rationale.
    func lastExecutionDetail() async -> String? {
        lastDriverDetail
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
        // Click dispatch has two flavours:
        //
        //   (a) Native HTMLElement.click() — for anchors, buttons, and
        //       role-based interactive elements. This is the most
        //       reliable path for SPAs (React Router, Next.js Link,
        //       Vue Router, etc) because:
        //         - For <a href="...">, the browser performs native
        //           navigation regardless of isTrusted.
        //         - For <button>, .click() fires a click event that
        //           bubbles through React's delegated listeners
        //           normally.
        //         - Routers that check `event.isTrusted` to filter out
        //           bot traffic will still see the trusted browser-
        //           generated navigation when href is set.
        //       Without this, runs on SPA sites loop forever clicking
        //       a nav link that "looks tapped" in the screenshot but
        //       never actually navigates — verified empirically on
        //       Next.js sites with smooth-scroll anchor + router-
        //       intercepted navigation.
        //
        //   (b) Synthetic MouseEvent dispatch — fallback for
        //       non-interactive elements (custom widgets, plain divs
        //       with attached onClick handlers, things React renders
        //       without any role hint). Still uses bubbles:true so the
        //       event reaches React's root-level synthetic listener.
        //
        // Focus routing happens after either path — same logic as
        // before. We resolve the "best focus target" ourselves because
        // synthetic clicks don't trigger the browser's built-in focus
        // routing the way real clicks do.
        let js = """
        (() => {
          const x = \(x), y = \(y);
          const button = \(button);
          const count = \(count);
          const beforeURL = location.href;
          const el = document.elementFromPoint(x, y);
          if (!el) return { ok: false, reason: 'no-element-at-point', urlChanged: false };

          // Prefer native .click() on anchors/buttons/role-interactive
          // elements (left-click only — right-clicks and double-clicks
          // keep synthetic dispatch since native .click() doesn't model
          // those well). Walks up the DOM in case the click landed on
          // a child span/icon inside an interactive parent.
          let interactiveTag = null;
          let interactive = null;
          if (button === 0) {
            interactive = el.closest('a[href], button, input[type="button"], input[type="submit"], [role="button"], [role="link"], [role="menuitem"], [role="tab"]');
            if (interactive) {
              interactiveTag = interactive.tagName + (interactive.getAttribute('href') ? '[href=' + interactive.getAttribute('href') + ']' : '');
            }
          }

          if (interactive && interactive.click) {
            for (let i = 0; i < count; i++) {
              try { interactive.click(); } catch (e) {}
            }
          } else {
            const opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: button, buttons: (button === 0 ? 1 : 2), view: window };
            for (let i = 0; i < count; i++) {
              el.dispatchEvent(new MouseEvent('mousedown', opts));
              el.dispatchEvent(new MouseEvent('mouseup', opts));
              el.dispatchEvent(new MouseEvent(button === 2 ? 'contextmenu' : 'click', opts));
            }
          }

          // Focus routing — only for left-click (button 0). Same logic
          // as before; runs regardless of which dispatch path above
          // fired so type/fill_credential after a click still lands
          // on the right input.
          if (button === 0) {
            const FOCUSABLE = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [tabindex]:not([tabindex="-1"])';
            let target = null;
            if (el.matches && el.matches(FOCUSABLE)) {
              target = el;
            }
            if (!target && el.tagName === 'LABEL') {
              const htmlFor = el.getAttribute('for');
              if (htmlFor) {
                target = document.getElementById(htmlFor);
              }
              if (!target) {
                target = el.querySelector(FOCUSABLE);
              }
            }
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

          return {
            ok: true,
            elementTag: el.tagName,
            interactiveTag: interactiveTag,
            url: location.href,
            urlChanged: location.href !== beforeURL
          };
        })();
        """
        // Capture the JS return value so we can log what was clicked
        // and where the page ended up. Helps diagnose "model keeps
        // tapping but page doesn't change" cases — if `interactiveTag`
        // is null and the URL didn't change, we know the click hit a
        // non-interactive element and a synthetic event was used.
        let result = try await runJSAndReturn(js)
        if let dict = result as? [String: Any] {
            let ok = (dict["ok"] as? Bool) ?? true
            let element = (dict["elementTag"] as? String) ?? "?"
            let interactive = (dict["interactiveTag"] as? String) ?? "none"
            let reason = (dict["reason"] as? String) ?? ""
            let url = (dict["url"] as? String) ?? ""
            let urlChanged = (dict["urlChanged"] as? Bool) ?? false
            self.lastClickNavigated = urlChanged

            // Surface the click's actual outcome to the agent through
            // `toolResultSummary` (via `lastDriverDetail`). Three cases
            // worth flagging — silently-ok clicks that didn't actually
            // do anything are the dominant "model loops on the same
            // tap" failure mode:
            //
            //   1. `no-element-at-point`: elementFromPoint returned
            //      null (point outside viewport, document not yet
            //      attached, etc.). Click was a hard no-op.
            //   2. `interactive=none` + URL unchanged: click landed on
            //      a non-interactive element (decorative span, image,
            //      whitespace). React onClick on a non-interactive
            //      parent may or may not have fired; the page didn't
            //      navigate either way. Worth telling the model so it
            //      doesn't re-click the same spot.
            //   3. Normal success: clicked an interactive element OR
            //      the URL changed (SPA route push). The agent gets
            //      "ok" with no additional detail.
            let detail: String?
            if !ok {
                detail = "click did not land on any element — \(reason.isEmpty ? "elementFromPoint returned null" : reason). Try a different tool or tap_mark id."
            } else if interactive == "none" && !urlChanged {
                detail = "click landed on <\(element)> but no interactive ancestor was found and the URL did not change. Click was effectively a no-op — try a different tool or tap_mark id."
            } else {
                detail = nil
            }
            if let detail {
                self.lastDriverDetail = detail
            }

            Self.logger.info("click (\(x, privacy: .public), \(y, privacy: .public)) → element=\(element, privacy: .public) interactive=\(interactive, privacy: .public) url=\(url, privacy: .public) urlChanged=\(urlChanged, privacy: .public)")
            if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
                let nav = urlChanged ? " [NAV]" : ""
                let line = "[WebDriver]   → element=\(element) interactive=\(interactive) url=\(url)\(nav)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
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
        // Returns enough metadata to build the agent-facing progress
        // string: the actual delta the page moved (often smaller than
        // requested `dy` near end-of-content), the scroller's post-scroll
        // top, and the maximum scrollable extent. Local sub-10B vision
        // models cannot reliably tell from a screenshot alone whether a
        // scroll moved 0px or 400px on a long uniform body; this text
        // signal is what stops the model from looping on identical-
        // looking states.
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
          const usingWindow = !scroller;
          const beforeY = usingWindow
            ? (window.scrollY || document.documentElement.scrollTop || 0)
            : scroller.scrollTop;
          const beforeX = usingWindow
            ? (window.scrollX || document.documentElement.scrollLeft || 0)
            : scroller.scrollLeft;
          // Fall back to the document's scrolling element (window) when
          // no inner container handles the axis.
          if (usingWindow) {
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
          const afterY = usingWindow
            ? (window.scrollY || document.documentElement.scrollTop || 0)
            : scroller.scrollTop;
          const afterX = usingWindow
            ? (window.scrollX || document.documentElement.scrollLeft || 0)
            : scroller.scrollLeft;
          const maxY = usingWindow
            ? Math.max(0, (document.documentElement.scrollHeight || 0) - (window.innerHeight || 0))
            : Math.max(0, (scroller.scrollHeight || 0) - (scroller.clientHeight || 0));
          const maxX = usingWindow
            ? Math.max(0, (document.documentElement.scrollWidth || 0) - (window.innerWidth || 0))
            : Math.max(0, (scroller.scrollWidth || 0) - (scroller.clientWidth || 0));
          return {
            beforeY: Math.round(beforeY),
            beforeX: Math.round(beforeX),
            afterY: Math.round(afterY),
            afterX: Math.round(afterX),
            maxY: Math.round(maxY),
            maxX: Math.round(maxX),
            scroller: usingWindow ? "window" : "inner"
          };
        })();
        """
        let result = try await runJSAndReturn(js)
        guard let dict = result as? [String: Any] else {
            lastDriverDetail = nil
            return
        }
        let beforeY = (dict["beforeY"] as? Double) ?? Double((dict["beforeY"] as? Int) ?? 0)
        let afterY = (dict["afterY"] as? Double) ?? Double((dict["afterY"] as? Int) ?? 0)
        let maxY = (dict["maxY"] as? Double) ?? Double((dict["maxY"] as? Int) ?? 0)
        let beforeX = (dict["beforeX"] as? Double) ?? Double((dict["beforeX"] as? Int) ?? 0)
        let afterX = (dict["afterX"] as? Double) ?? Double((dict["afterX"] as? Int) ?? 0)
        let maxX = (dict["maxX"] as? Double) ?? Double((dict["maxX"] as? Int) ?? 0)
        let scrollerKind = (dict["scroller"] as? String) ?? "window"

        let deltaY = afterY - beforeY
        let deltaX = afterX - beforeX
        let intendedNonZero = (dy != 0 || dx != 0)
        let movedMeaningfully =
            abs(deltaY) >= Self.scrollNoProgressEpsilonPx ||
            abs(deltaX) >= Self.scrollNoProgressEpsilonPx
        if intendedNonZero && !movedMeaningfully {
            consecutiveNoProgressScrolls += 1
        } else {
            consecutiveNoProgressScrolls = 0
        }

        // Build the agent-facing progress string. Two flavours:
        //   - Successful scroll: "scrolled 800 → 1200 (delta 400), now at
        //     47% of 2560 max scroll (window scroller)"
        //   - No-progress scroll: "scroll requested dy=400 but page did
        //     not move (already at end of scroll; consecutive 2 no-op
        //     scrolls — try a different tool such as `tap_mark` to
        //     navigate, or `mark_goal_done` if you've read enough)"
        let detail: String
        if intendedNonZero && !movedMeaningfully {
            let direction = dy > 0 ? "down" : (dy < 0 ? "up" : (dx > 0 ? "right" : "left"))
            let atEnd: String
            if dy > 0 && afterY >= maxY - Self.scrollNoProgressEpsilonPx {
                atEnd = "already at bottom of \(scrollerKind) scroller (scrollY=\(Int(afterY)) of \(Int(maxY)) max)"
            } else if dy < 0 && afterY <= Self.scrollNoProgressEpsilonPx {
                atEnd = "already at top of \(scrollerKind) scroller (scrollY=\(Int(afterY)))"
            } else {
                atEnd = "page did not move (scrollY=\(Int(afterY)))"
            }
            let nudge: String
            if consecutiveNoProgressScrolls >= 2 {
                nudge = " — \(consecutiveNoProgressScrolls) consecutive no-progress scrolls. Try a different tool: tap_mark on a link to navigate, or mark_goal_done if you have read enough."
            } else {
                nudge = ""
            }
            detail = "scroll \(direction) — \(atEnd)\(nudge)"
        } else {
            let percent: Int
            if maxY > 0 {
                percent = Int(((afterY / maxY) * 100).rounded())
            } else {
                percent = 100
            }
            detail = "scrolled to \(Int(afterY)) of \(Int(maxY)) (\(percent)% of \(scrollerKind) scroller, delta y=\(Int(deltaY)) x=\(Int(deltaX)))"
        }
        lastDriverDetail = detail
        Self.logger.info("scroll dy=\(dy, privacy: .public) dx=\(dx, privacy: .public) → \(detail, privacy: .public)")
        if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let line = "[WebDriver] scroll → \(detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
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

    /// Like `runJS` but surfaces the JS return value. Used by
    /// `dispatchClick` to capture diagnostic info (which element was
    /// clicked, whether the native or synthetic path fired, the URL
    /// after the click) — useful for diagnosing "agent keeps tapping
    /// but page doesn't change" failure modes that show up on SPA
    /// sites with intercepted routing. Return type is `Any?` because
    /// WKWebView's `evaluateJavaScript` returns dynamic JS — callers
    /// downcast at the use site.
    private func runJSAndReturn(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSReturn, any Error>) in
            Task { @MainActor in
                self.controller.webView.evaluateJavaScript(js) { value, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: JSReturn(value: value))
                    }
                }
            }
        }.value
    }

    /// Sendable wrapper around a JS return value (which is `Any?` and
    /// not itself Sendable). Confining cross-actor transport.
    private struct JSReturn: @unchecked Sendable {
        let value: Any?
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
          // Targets where pixel precision matters. `a[href]` is included
          // because nav links in SPAs (Next.js Link, React Router Link,
          // etc.) all render as anchors — excluding them leaves the
          // top-of-page navigation un-marked, forcing the agent to fall
          // back to `tap(x, y)`. For local sub-10B vision models that
          // see a downscaled screenshot, those raw coordinates frequently
          // land on a neighbour nav item (verified with Qwen3-VL 8B at
          // 768-wide vs 1280-wide viewport). Anchor inclusion is what
          // makes `tap_mark` actually usable for navigation.
          //
          // Decorative anchors (empty href, anchor jumps, javascript:
          // pseudo-protocols) stay excluded — they'd badge map markers
          // and footer scroll-to-top arrows without buying real value.
          const SELECTOR = [
            'input:not([type="hidden"]):not([type="button"]):not([type="submit"]):not([type="reset"])',
            'textarea',
            'select',
            'button',
            'input[type="button"]',
            'input[type="submit"]',
            'input[type="reset"]',
            'a[href]:not([href=""]):not([href="#"]):not([href^="javascript:"])',
            '[role="link"]',
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
            // Drop big, label-less interactive containers. They tend
            // to be invisible wrapper "buttons" that span a section
            // (e.g. a `<div role="button">` covering a whole hero
            // card with no text or aria-label of its own). Marking
            // them produces a badge floating over otherwise-empty
            // page area, which small vision models then misread as
            // "content I should click" — see the badge-11 misfire on
            // alanwizemann.com that drove this filter in. Small
            // label-less elements (icon buttons under 48×48) keep
            // their badge; their position is meaningful even without
            // a label and they're typically genuinely clickable.
            const big = r.width >= 200 || r.height >= 100;
            if (label.length === 0 && big) return;
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
          // Cap at 80 marks. With anchor inclusion (nav links, in-text
          // links, footer link grids), an article-heavy page like a
          // blog index can easily produce 200+ marks — past a point
          // they overlap onto the same badge column and degrade legibility
          // for the model. The cap keeps the most-likely-actionable
          // elements (top-of-page nav + above-the-fold content) badged;
          // anything below the fold gets badged once the agent scrolls.
          const CAP = 80;
          return out.length > CAP ? out.slice(0, CAP) : out;
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
    /// screenshot's mark cache. Resolves to a click point inside the
    /// rect's **visible-in-viewport** portion, then runs the same
    /// `dispatchClick` path as `tap` — so focus routing,
    /// label-resolution, etc. all work the same way.
    ///
    /// **Viewport clipping**: when the mark's rect extends past the
    /// viewport bottom (a common case for "Related Content" cards or
    /// long article cards on the index page), the geometric midpoint
    /// can land outside the visible area. `document.elementFromPoint`
    /// returns `null` for points outside the viewport, so the click
    /// is silently a no-op. Clipping the rect to the viewport BEFORE
    /// computing the midpoint guarantees the click lands on a hit-
    /// testable pixel. The element is still the same React anchor —
    /// we're just picking a click coordinate that the browser will
    /// route to it.
    ///
    /// Inset margins (4pt) keep the click point off the absolute
    /// edges, which can hit borders or scrollbar handles on some
    /// pages.
    private func dispatchMarkClick(id: Int) async throws {
        guard let mark = lastMarks.first(where: { $0.id == id }) else {
            throw WebDriverError.unknownMark(id: id)
        }
        let inset: CGFloat = 4
        let viewportW = viewport.width
        let viewportH = viewport.height
        // Intersect mark.rect with the visible viewport (0,0,vw,vh).
        let visibleMinX = max(mark.rect.minX, 0) + inset
        let visibleMinY = max(mark.rect.minY, 0) + inset
        let visibleMaxX = min(mark.rect.maxX, viewportW) - inset
        let visibleMaxY = min(mark.rect.maxY, viewportH) - inset
        let clampedCenterX: CGFloat
        let clampedCenterY: CGFloat
        if visibleMaxX > visibleMinX && visibleMaxY > visibleMinY {
            clampedCenterX = (visibleMinX + visibleMaxX) / 2
            clampedCenterY = (visibleMinY + visibleMaxY) / 2
        } else {
            // Edge case: rect is entirely off-screen (probe filter
            // bug, or page scrolled between probe and dispatch).
            // Fall back to the un-clipped midpoint — `dispatchClick`
            // will report `no-element-at-point` and the model gets
            // an honest signal.
            clampedCenterX = mark.rect.midX
            clampedCenterY = mark.rect.midY
        }
        let cx = Int(clampedCenterX.rounded())
        let cy = Int(clampedCenterY.rounded())
        Self.logger.info("tap_mark(\(id, privacy: .public)) → label=\"\(mark.label, privacy: .public)\" role=\(mark.role, privacy: .public) rect=(\(Int(mark.rect.minX), privacy: .public),\(Int(mark.rect.minY), privacy: .public),\(Int(mark.rect.width), privacy: .public),\(Int(mark.rect.height), privacy: .public)) → click(\(cx, privacy: .public),\(cy, privacy: .public))")
        if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let line = "[WebDriver] tap_mark(\(id)) label=\"\(mark.label)\" role=\(mark.role) rect=(\(Int(mark.rect.minX)),\(Int(mark.rect.minY)),\(Int(mark.rect.width)),\(Int(mark.rect.height))) → click(\(cx),\(cy))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        try await dispatchClick(x: cx, y: cy, button: 0, count: 1)
    }

    /// Draw numbered badges over every mark's bounding rect on a copy
    /// of `image`. The output is what we save to disk and send to the
    /// model — agents and human reviewers both see the same scaffolding.
    ///
    /// **Coordinate-system note.** Mark rects come from
    /// `getBoundingClientRect()` — CSS pixels with **top-left origin**
    /// (y increases downward). `NSImage.lockFocus()` exposes a
    /// `CGContext` whose default coordinate system is **bottom-left
    /// origin** (y increases upward). Drawing CSS rects directly into
    /// that context puts every mark at `imageHeight - cssY` instead of
    /// `cssY` — i.e. flipped to the bottom of the image. We translate
    /// each rect into NSImage coordinates explicitly here so marks land
    /// on the elements they label.
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
        // Base layer: the original snapshot. NSImage.draw handles its
        // own orientation, so this lands the page right-side-up.
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return result }
        // The accent + supporting colors come from HarnessDesign so the
        // overlay reads as part of the app rather than dev-tool clutter.
        let accent = NSColor(red: 0.07, green: 0.58, blue: 0.42, alpha: 1.0)   // harnessAccent (light)
        let badgeBG = accent.cgColor
        let badgeFG = NSColor.white
        let outline = accent.withAlphaComponent(0.85).cgColor
        for mark in marks {
            let css = mark.rect
            // Translate CSS (y-down) to NSImage (y-up). The element's
            // CSS top-edge is at NSImage y = `size.height - css.minY`;
            // CGRect's origin is its bottom-left, so the rect's NSImage
            // y is `size.height - css.maxY`.
            let outlineRect = CGRect(
                x: css.minX,
                y: size.height - css.maxY,
                width: css.width,
                height: css.height
            )
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(2.0)
            ctx.stroke(outlineRect)

            // Number badge floating just **above** the element so it
            // doesn't obscure the element's first characters. Earlier
            // we anchored at the top-left INSIDE the element's rect:
            // for nav anchors that meant the badge covered the first
            // 2-3 letters of the label, and the LLM saw "perience",
            // "sjects", "icles" instead of "Experience", "Projects",
            // "Articles" — verified empirically with Qwen3-VL 8B
            // against alanwizemann.com. Floating the badge just above
            // the element gives the model a clean read of both the
            // badge number AND the label.
            //
            // Sizing: tuned for legibility after the LLM-side
            // downscale. Local sub-10B vision models receive the image
            // clamped to a 768pt long edge (see
            // `AgentModel.screenshotMaxLongEdge`), so a 1280pt-wide
            // viewport scales to 0.6×. A 22pt-bold badge becomes
            // ~13pt — readable by Qwen3-VL and friends; the prior
            // 13pt sizing collapsed to ~8pt and was effectively
            // invisible. Cloud models receive the native-resolution
            // image so the slightly chunkier badges cost nothing.
            // Disk PNGs stay unmarked, so this overlay is invisible
            // to humans reviewing replays.
            let labelText = "\(mark.id)"
            let font = NSFont.systemFont(ofSize: 22, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: badgeFG
            ]
            let textSize = (labelText as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 6
            let badgeW = max(32, textSize.width + 2 * pad)
            let badgeH: CGFloat = 30
            // Float the badge just above the element's CSS-top edge.
            // CSS-top is at NSImage y = `size.height - css.minY`. A
            // 4pt gap separates the badge bottom from the element's
            // outline; the badge's TOP edge then lands at
            // `size.height - css.minY + 4 + badgeH`, so the badge's
            // BOTTOM (drawn from bottom-left in y-up CGContext) is at
            // `size.height - css.minY + 4`. When the element is right
            // at the top of the viewport (css.minY ≈ 0), the badge
            // would clip off-screen — clamp y so badges always stay
            // inside the image; for top-of-page nav this puts them
            // INSIDE the element at the very top edge, where they
            // overlap minimal label text.
            let preferredY = size.height - css.minY + 4
            let badgeY = min(preferredY, size.height - badgeH - 2)
            let badgeRect = CGRect(
                x: css.minX,
                y: badgeY,
                width: badgeW,
                height: badgeH
            )
            ctx.setFillColor(badgeBG)
            ctx.fill(badgeRect)
            // The CGContext is unflipped here, so `NSString.draw(at:)`
            // treats the point as the text's lower-left in y-up space.
            // Centring the text inside the badge then means a small
            // upward offset from the badge's bottom.
            let textPoint = CGPoint(
                x: badgeRect.minX + pad,
                y: badgeRect.minY + (badgeH - textSize.height) / 2
            )
            (labelText as NSString).draw(at: textPoint, withAttributes: attrs)
        }
        _ = viewport  // reserved for future viewport-clamp checks
        return result
    }

    /// PNG-encode an `NSImage` via the same TIFF→bitmap path the
    /// snapshot pipeline used before the marks split, so disk writes and
    /// in-memory marked copies share one encoding routine.
    nonisolated private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
