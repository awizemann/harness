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
    /// W3 — true between `armActionObservation()` (called by `execute` BEFORE
    /// dispatching a DOM-affecting, non-navigating action) and the settle that
    /// consumes it. See `WebSettleProfile` for why arming has to happen before
    /// the action rather than after it.
    private var actionObservationArmed: Bool = false
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

    /// Read this session's cookies + the current origin's `localStorage`.
    ///
    /// **The result is a bag of credentials.** It exists to serve exactly one
    /// caller — the `export_ui_session_state` MCP tool — whose whole job is to
    /// hand that state back to a client that will store it securely. It is
    /// never logged, never written to `steps.jsonl`, and never persisted here.
    func exportSessionState() async -> WebSessionState {
        await WebSessionStateIO.export(from: controller)
    }

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
        // Visible page text, read in the SAME pre-snapshot window as the
        // marks so the text, the rects, and the pixels all describe one DOM
        // state. (Reading it after the snapshot would let a late render land
        // between the two and hand a caller text its frame doesn't show.)
        // Best-effort and bounded — never fails the screenshot.
        let pageText = await probeVisibleText()
        // The frame's location, redacted before it can be returned or
        // logged (see `redactedFrameURL`). Read in the same pre-snapshot
        // window as the marks and the text so all three describe one state.
        let frameURL = Self.redactedFrameURL(await currentURL())
        Self.logger.info("screenshot probed \(marks.count, privacy: .public) interactive marks (viewport=\(Int(self.viewport.width), privacy: .public)×\(Int(self.viewport.height), privacy: .public))")

        let raw = try await captureSnapshot()
        // Save the **unmarked** snapshot to disk. Replay, friction
        // reports, and exported screenshots all read this PNG — keeping
        // it clean means the green numbered overlay (which is agent
        // scaffolding, not part of the page) never leaks into surfaces
        // a human reviewer sees.
        guard let rawPNG = MarkRenderer.pngData(from: raw) else {
            throw WebDriverError.captureFailed
        }
        try rawPNG.write(to: url, options: .atomic)

        // Render the marked copy in-memory only when there's something
        // to draw. The agent loop receives these bytes via
        // `ScreenshotMetadata.markedImageData`; everything else (disk,
        // replay, friction report) keeps using the unmarked PNG.
        let markedImage: NSImage? = marks.isEmpty
            ? nil
            : MarkRenderer.draw(on: raw, marks: marks, markSpaceSize: viewport)
        let markedData: Data? = markedImage.flatMap { MarkRenderer.pngData(from: $0) }

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
            : MarkRenderer.describe(marks)

        return ScreenshotMetadata(
            pixelSize: raw.size,
            pointSize: viewport,
            markedImageData: markedData,
            markedAnnotationText: annotationText,
            marks: marks,
            pageText: pageText,
            frameURL: frameURL
        )
    }

    // MARK: - Frame URL (WB-17)

    /// Reduce a live frame URL to the part a consumer needs and nothing
    /// more: **scheme, host, port and path**.
    ///
    /// A URL is not safe to echo wholesale. Magic-link tokens, password
    /// reset nonces, OAuth `code`/`state`, session ids and analytics
    /// identifiers all ride in the query string or the fragment, and
    /// `https://user:secret@host/` puts a password in the authority. This
    /// result is returned to an MCP client, written to no artifact, and
    /// logged only in this reduced form — so the reduction happens HERE,
    /// once, at the only place the raw string is read, rather than being
    /// left to each consumer to remember.
    ///
    /// What is kept is exactly what the motivating use answers: *did the
    /// origin change under me?* Query and fragment are DROPPED, not
    /// truncated — a prefix of a token is still token material — and their
    /// former presence is reported honestly by a trailing marker: `?…` for
    /// a dropped query, `#…` for a dropped fragment. A consumer can see
    /// that parameters existed without ever seeing one.
    ///
    /// The path is kept whole: it is the half a client needs to tell
    /// `/dashboard` from `/login`, and path-embedded secrets are the rarer
    /// case. That trade is stated in the tool's own schema so nobody has to
    /// infer it. Anything unparseable, or any scheme other than
    /// http/https/file/about, collapses to `scheme:…` — a `data:` or
    /// `blob:` URL is a document body, not a location.
    static func redactedFrameURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased() else {
            return nil
        }
        let hadQuery = !(comps.percentEncodedQuery ?? "").isEmpty
        let hadFragment = !(comps.percentEncodedFragment ?? "").isEmpty
        let marker = (hadQuery ? "?…" : "") + (hadFragment ? "#…" : "")

        switch scheme {
        case "http", "https", "file":
            var out = scheme + "://"
            var host = comps.percentEncodedHost ?? ""
            // Foundation hands an IPv6 literal back unbracketed; re-bracket
            // it so the result is a URL a client can parse rather than a
            // string where the port runs into the address.
            if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
            out += host
            if let port = comps.port { out += ":\(port)" }
            out += comps.percentEncodedPath
            return out + marker
        case "about":
            // `about:blank` carries nothing; keep it readable.
            return "about:" + comps.percentEncodedPath + marker
        default:
            return scheme + ":…"
        }
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

        // W3 — arm DOM + async-work observation BEFORE dispatching an action
        // that can change the page without changing the URL. Arming after the
        // fact (the historical behaviour) misses every mutation the action's
        // own handler makes and cannot tell "hasn't reacted yet" from "will
        // never react". Navigations bring their own gate and skip this.
        if WebSettleProfile.armsObservation(for: call.input) {
            await armActionObservation()
        }

        // A dispatch that THROWS never reaches `settle`, so the armed
        // observer would otherwise sit installed (with the page's
        // `setTimeout` / `fetch` still wrapped) until the next arm disposed
        // it. Tear it down on the way out instead.
        do {
            try await dispatch(call)
        } catch {
            await disarmActionObservation()
            throw error
        }
    }

    /// The per-tool dispatch switch. Split out of `execute` so the armed
    /// observer can be disposed on a throwing path.
    private func dispatch(_ call: ToolCall) async throws {
        switch call.input {
        case .tap(let x, let y):
            try await dispatchClick(x: x, y: y, button: 0, count: 1)
        case .tapMark(let id):
            try await dispatchMarkClick(id: id)
        case .scrollIntoView(let id):
            try await dispatchScrollIntoView(id: id)
        case .doubleTap(let x, let y):
            try await dispatchClick(x: x, y: y, button: 0, count: 2)
        case .rightClick(let x, let y):
            try await dispatchClick(x: x, y: y, button: 2, count: 1)
        case .scroll(let x, let y, let dx, let dy):
            try await dispatchScroll(x: x, y: y, dx: dx, dy: dy)
        case .type(let text):
            try await dispatchType(text)
        case .setValue(let id, let value):
            try await dispatchSetValue(id: id, value: value)
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
            // No staged credential → THROW (never a silent no-op: the
            // caller would see an unchanged screen and no reason why).
            // With a binding, route through the same JS `dispatchType`
            // path as the ordinary `type` tool: set `value` on the focused
            // input (or `execCommand('insertText', …)` for contenteditable),
            // then dispatch input/change events so React-style listeners
            // see the change. WKWebView's `<input type="password">` renders
            // bullets natively, so screenshots stay masked.
            guard let credential else {
                throw UXDriverError.credentialUnavailable(field: field)
            }
            do {
                try await dispatchType(credential.value(for: field), passwordSafe: true)
            } catch {
                // A WebKit JS-evaluation error can echo page/script text;
                // scrub the credential out of it before it reaches the
                // tool result and steps.jsonl.
                throw UXDriverError.credentialFillFailed(
                    field: field,
                    detail: credential.redacting(error.localizedDescription)
                )
            }
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
    /// **Non-navigating actions (W3)**: the envelope alone was not enough.
    /// A same-URL React state swap that lands behind an `await fetch(...)`
    /// or a short `setTimeout` used to be missed entirely — the observer was
    /// armed AFTER dispatch and its only exit test was "quiet for `idleMs`",
    /// which a page that has not reacted YET passes just as well as a page
    /// that never will. Those actions now use `armActionObservation()`
    /// (installed BEFORE dispatch, in `execute`) plus a pending-async-work
    /// gate; see `WebSettleProfile` for the full rationale.
    func settle(afterTool call: ToolCall) async {
        let profile = WebSettleProfile.profile(for: call.input, clickNavigated: lastClickNavigated)
        // Reset the navigation flag for the next tool — it only applies to
        // the immediately-following settle.
        lastClickNavigated = false

        // Nothing to wait for, but an observer armed for this action must
        // never outlive it (a stale one would be disposed by the next arm
        // anyway; this keeps the page clean in the meantime).
        guard profile != .none else {
            await disarmActionObservation()
            return
        }

        if profile.usesArmedObservation && actionObservationArmed {
            actionObservationArmed = false
            let waited = await awaitArmedDOMSettled(profile)
            if waited >= 0 {
                Self.logger.info("armed settle waited \(waited, privacy: .public)ms (idle=\(profile.idleMs, privacy: .public), max=\(profile.maxMs, privacy: .public))")
                return
            }
            // The armed state was gone by the time we looked: a hard
            // navigation tore down the JS context, or arming silently
            // failed. Fall through to the legacy post-hoc gate rather than
            // skipping the wait entirely.
            Self.logger.info("armed settle state absent; falling back to post-hoc DOM settle")
        } else {
            await disarmActionObservation()
        }

        _ = await awaitDOMSettled(
            idleMs: profile.idleMs,
            minMs: profile.minMs,
            maxMs: profile.maxMs,
            requireChildListMutation: profile.requireChildListMutation
        )
    }

    // MARK: - Pre-armed action observation (W3)

    /// JS global the armed observer parks its state on. One per page context;
    /// arming disposes any previous instance first, so a driver that armed but
    /// never awaited (an `execute` that threw) cannot leak a live observer or
    /// leave the page's `setTimeout` / `fetch` permanently wrapped.
    private static let armedStateKey = "__harnessSettleState"

    /// Install DOM observation + pending-async-work accounting BEFORE an
    /// action is dispatched.
    ///
    /// Tracks, from this moment on:
    ///   - every DOM mutation (childList / attributes / characterData, subtree),
    ///   - `setTimeout` callbacks scheduled with a delay ≤ 2000ms,
    ///   - in-flight `fetch` calls,
    ///   - in-flight `XMLHttpRequest` sends.
    ///
    /// `setInterval` and `requestAnimationFrame` are deliberately NOT tracked:
    /// a polling interval or an animation loop never drains, and gating on
    /// them would pin every settle to its ceiling. Long timers (> 2000ms)
    /// are excluded for the same reason — they cannot finish inside the
    /// action's own ceiling, so waiting on them only wastes it.
    ///
    /// Best-effort: a failure here leaves `actionObservationArmed == false`
    /// and `settle` falls back to the historical post-hoc gate.
    private func armActionObservation() async {
        let js = """
        (() => {
          const KEY = '\(Self.armedStateKey)';
          try { if (window[KEY] && window[KEY].dispose) window[KEY].dispose(); } catch (e) {}
          const target = document.documentElement || document.body;
          if (!target) return false;
          const now = performance.now();
          const st = {
            startedAt: now,
            lastMut: now,
            mutations: 0,
            pending: 0,
            rawTimeout: window.setTimeout.bind(window),
            disposed: false
          };
          const obs = new MutationObserver(() => {
            st.lastMut = performance.now();
            st.mutations++;
          });
          obs.observe(target, { childList: true, subtree: true, attributes: true, characterData: true });

          const origTimeout = window.setTimeout;
          const origFetch = window.fetch;
          const origSend = window.XMLHttpRequest && window.XMLHttpRequest.prototype
            ? window.XMLHttpRequest.prototype.send : null;

          // Short timers: the classic "swap the view in 500ms" shape.
          try {
            window.setTimeout = function (fn, delay) {
              const d = Number(delay) || 0;
              if (typeof fn === 'function' && d <= 2000 && !st.disposed) {
                st.pending++;
                let settled = false;
                const rest = Array.prototype.slice.call(arguments, 2);
                return origTimeout.call(window, function () {
                  if (!settled) { settled = true; st.pending--; }
                  try { fn.apply(this, rest); } finally { st.lastMut = performance.now(); }
                }, d);
              }
              return origTimeout.apply(window, arguments);
            };
          } catch (e) {}

          try {
            if (typeof origFetch === 'function') {
              window.fetch = function () {
                if (st.disposed) return origFetch.apply(this, arguments);
                st.pending++;
                let p;
                try { p = origFetch.apply(this, arguments); }
                catch (e) { st.pending--; throw e; }
                return p.then(
                  (r) => { st.pending--; st.lastMut = performance.now(); return r; },
                  (e) => { st.pending--; st.lastMut = performance.now(); throw e; }
                );
              };
            }
          } catch (e) {}

          try {
            if (origSend) {
              window.XMLHttpRequest.prototype.send = function () {
                if (!st.disposed) {
                  st.pending++;
                  let settled = false;
                  this.addEventListener('loadend', function () {
                    if (!settled) { settled = true; st.pending--; st.lastMut = performance.now(); }
                  });
                }
                return origSend.apply(this, arguments);
              };
            }
          } catch (e) {}

          st.dispose = function () {
            if (st.disposed) return;
            st.disposed = true;
            try { obs.disconnect(); } catch (e) {}
            try { window.setTimeout = origTimeout; } catch (e) {}
            try { if (typeof origFetch === 'function') window.fetch = origFetch; } catch (e) {}
            try { if (origSend) window.XMLHttpRequest.prototype.send = origSend; } catch (e) {}
            try { delete window[KEY]; } catch (e) { window[KEY] = null; }
          };
          window[KEY] = st;
          return true;
        })();
        """
        let armed: Bool? = await Self.raceAgainstTimeout(.seconds(2)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    controller.webView.evaluateJavaScript(js) { value, error in
                        if error != nil { cont.resume(returning: false); return }
                        cont.resume(returning: (value as? NSNumber)?.boolValue ?? false)
                    }
                }
            }
        }
        actionObservationArmed = (armed ?? false)
        if !actionObservationArmed {
            Self.logger.info("armActionObservation did not arm; settle will use the post-hoc gate")
        }
    }

    /// Dispose an armed observer without waiting on it (restores the page's
    /// original `setTimeout` / `fetch` / `XHR.send`). Idempotent and silent.
    private func disarmActionObservation() async {
        guard actionObservationArmed else { return }
        actionObservationArmed = false
        let js = """
        (() => {
          const st = window['\(Self.armedStateKey)'];
          if (st && st.dispose) { try { st.dispose(); } catch (e) {} }
          return true;
        })();
        """
        _ = await Self.raceAgainstTimeout(.seconds(2)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    controller.webView.evaluateJavaScript(js) { _, _ in cont.resume(returning: true) }
                }
            }
        }
    }

    /// Wait on the pre-armed observer. Resolves once the DOM has been quiet
    /// for `idleMs` AND the page has no tracked async work in flight, with
    /// `minMs` as a floor and `maxMs` as a ceiling.
    ///
    /// Returns the wall-clock ms waited, or `-1` when the armed state was not
    /// found (page navigated away / arming failed) so the caller can fall back.
    private func awaitArmedDOMSettled(_ profile: WebSettleProfile) async -> Int {
        let js = """
        return await new Promise((resolve) => {
          const st = window['\(Self.armedStateKey)'];
          if (!st || st.disposed) { resolve(-1); return; }
          const startedAt = performance.now();
          // Use the ORIGINAL setTimeout captured at arm time — polling through
          // the wrapped one would count our own ticks as pending page work.
          const schedule = st.rawTimeout || setTimeout;
          const tick = () => {
            const now = performance.now();
            const elapsed = now - startedAt;
            const sinceMut = now - st.lastMut;
            const quiet = elapsed >= minMs && sinceMut >= idleMs && st.pending <= 0;
            if (elapsed >= maxMs || quiet) {
              try { st.dispose(); } catch (e) {}
              resolve(Math.round(elapsed));
              return;
            }
            schedule(tick, 50);
          };
          tick();
        });
        """
        let hardCapMs = profile.maxMs + 4000
        let outcome: Int? = await Self.raceAgainstTimeout(.milliseconds(hardCapMs)) { [controller] in
            await Task { @MainActor in
                do {
                    let value = try await controller.webView.callAsyncJavaScript(
                        js,
                        arguments: [
                            "idleMs": profile.idleMs,
                            "minMs": profile.minMs,
                            "maxMs": profile.maxMs
                        ],
                        in: nil,
                        contentWorld: .page
                    )
                    if let i = value as? Int { return i }
                    if let d = value as? Double { return Int(d) }
                    return -1
                } catch {
                    Self.logger.warning("awaitArmedDOMSettled JS bridge failed: \(error.localizedDescription, privacy: .public)")
                    return -1
                }
            }.value
        }
        guard let waitedMs = outcome else {
            Self.logger.warning("awaitArmedDOMSettled hard-timed-out after ~\(hardCapMs)ms; proceeding to capture")
            return profile.maxMs
        }
        return waitedMs
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
        // Swift-side hard backstop OVER the JS self-cap. The JS body caps
        // itself at `maxMs`, but only once it actually runs. When a click
        // triggered a full-page navigation to a slow/hung URL,
        // `callAsyncJavaScript` blocks until the NEW document's JS context
        // is ready — which never happens for a stuck load, so the JS cap
        // never engages and the whole step (and the run) freezes. Race the
        // call against a hard timeout; on timeout we abandon the wedged JS
        // call and proceed so the next screenshot captures whatever's on
        // screen instead of hanging forever.
        let hardCapMs = maxMs + 4000
        let outcome: Int? = await Self.raceAgainstTimeout(.milliseconds(hardCapMs)) { [controller] in
            await Task { @MainActor in
                do {
                    // WKWebView's async `callAsyncJavaScript` returns `Any?`
                    // — a Promise resolution from the JS body: an Int via
                    // `Math.round` (bridges to NSNumber → Int, occasionally
                    // Double depending on platform — handle both).
                    let value = try await controller.webView.callAsyncJavaScript(
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
        }
        guard let waitedMs = outcome else {
            Self.logger.warning("awaitDOMSettled hard-timed-out after ~\(hardCapMs)ms — page likely stuck loading after a navigation; proceeding to capture")
            return hardCapMs
        }
        if waitedMs < 0 {
            try? await Task.sleep(for: .milliseconds(minMs))
            return minMs
        }
        return waitedMs
    }

    /// Await `operation`, returning `nil` if it doesn't finish within
    /// `timeout`. The operation runs in its own unstructured task; on
    /// timeout it is ABANDONED (left to finish on its own) rather than
    /// awaited — so a wedged, non-cancellation-aware call (e.g.
    /// `callAsyncJavaScript` / `takeSnapshot` blocked on a navigation that
    /// never finishes loading) cannot stall the caller. A structured
    /// `withTaskGroup` would NOT work here: it awaits all children before
    /// returning, so a wedged child would re-introduce the hang. The
    /// continuation is resumed exactly once, guarded by `RaceBox`.
    nonisolated static func raceAgainstTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = RaceBox<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task {
                let value = await operation()
                await box.settle(.some(value), into: cont)
            }
            Task {
                try? await Task.sleep(for: timeout)
                await box.settle(nil, into: cont)
            }
        }
    }

    /// One-shot resume guard for `raceAgainstTimeout` — whichever of the
    /// operation / timeout tasks finishes first resumes the continuation;
    /// the loser is a no-op.
    private actor RaceBox<T: Sendable> {
        private var resumed = false
        func settle(_ value: T?, into cont: CheckedContinuation<T?, Never>) {
            guard !resumed else { return }
            resumed = true
            cont.resume(returning: value)
        }
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
        // Hard timeout (see raceAgainstTimeout): a wedged WebKit after a hung
        // navigation can leave takeSnapshot's completion uncalled, which would
        // freeze the next-step capture the same way an unbounded settle did.
        // We ferry a CGImage + the image's POINT size (both Sendable) across
        // the race rather than the non-Sendable NSImage, then rebuild with the
        // exact size — preserving the point/pixel geometry the Set-of-Mark
        // overlay depends on. (A TIFF round-trip can silently hand back the
        // image at PIXEL size, which would misplace every badge.)
        let raced: WebSnapshot?? = await Self.raceAgainstTimeout(.seconds(15)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<WebSnapshot?, Never>) in
                Task { @MainActor in
                    let cfg = WKSnapshotConfiguration()
                    cfg.afterScreenUpdates = true
                    controller.webView.takeSnapshot(with: cfg) { image, _ in
                        guard let image else { cont.resume(returning: nil); return }
                        var rect = NSRect(origin: .zero, size: image.size)
                        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                            cont.resume(returning: WebSnapshot(cgImage: cg, pointSize: image.size))
                        } else {
                            cont.resume(returning: nil)
                        }
                    }
                }
            }
        }
        guard let inner = raced else { throw WebDriverError.captureTimedOut }
        guard let snap = inner else { throw WebDriverError.captureFailed }
        return NSImage(cgImage: snap.cgImage, size: snap.pointSize)
    }

    /// Sendable carrier for a snapshot across the timeout race. `CGImage` is
    /// immutable / thread-safe; `pointSize` is the original NSImage point size,
    /// reapplied on reconstruction so downstream point/pixel math and the
    /// Set-of-Mark overlay geometry stay identical to the pre-timeout behavior.
    private struct WebSnapshot: @unchecked Sendable {
        let cgImage: CGImage
        let pointSize: CGSize
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

            // The post-click `location.href` goes through the SAME reduction
            // the returned `frame_url` does. The unified log is readable by any
            // process running as this user and is swept into a sysdiagnose, so
            // an OAuth callback's `?code=…` had no business being written there
            // at `.public` — which is exactly what this line used to do.
            let loggedURL = Self.redactedFrameURL(url) ?? "(unparseable)"
            Self.logger.info("click (\(x, privacy: .public), \(y, privacy: .public)) → element=\(element, privacy: .public) interactive=\(interactive, privacy: .public) url=\(loggedURL, privacy: .public) urlChanged=\(urlChanged, privacy: .public)")
            if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
                let nav = urlChanged ? " [NAV]" : ""
                let line = "[WebDriver]   → element=\(element) interactive=\(interactive) url=\(loggedURL)\(nav)\n"
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

    /// Type `text` into the focused field. The JS (in `WebMarkProbe.typeJS`,
    /// so the test suite runs the identical source) drives the value through
    /// the native prototype setter + input/change events — the React-tracker-
    /// correct path — and reports whether the field's value actually moved.
    ///
    /// **The no-op guard (WB-27, from W36).** A synthetic-keystroke `type`
    /// can land nothing — no field is focused, or the field is controlled /
    /// readonly and reverts the insert on the same tick — and the old code
    /// returned success regardless, so the caller saw a clean "typed" step
    /// and an unchanged screen with no reason why. Now the JS returns
    /// `{ had, changed }` and a no-op sets `lastDriverDetail` to say so and
    /// point at `set_value`. The mechanism is unchanged; it just stops
    /// lying. It stays best-effort: a controlled component that reverts on a
    /// LATER render (not synchronously) can still read as changed here — for
    /// that class `set_value` is the reliable tool, which the warning names.
    ///
    /// `passwordSafe` = this is the `fill_credential` path. The JS never
    /// returns the field's value (only booleans), so nothing leaks either
    /// way, but the warning copy is kept generic on this path so a run
    /// transcript never even implies the credential's shape.
    @discardableResult
    private func dispatchType(_ text: String, passwordSafe: Bool = false) async throws -> Bool {
        let js = WebMarkProbe.typeJS(text: text)
        let result = try await runJSAndReturn(js)
        guard let dict = result as? [String: Any] else {
            // Timed out (navigation in flight) or a genuinely opaque return.
            // The insert was already dispatched; don't invent a warning.
            return true
        }
        let had = (dict["had"] as? Bool) ?? false
        let changed = (dict["changed"] as? Bool) ?? false
        if !had {
            lastDriverDetail = passwordSafe
                ? "fill_credential — no editable field was focused, so nothing was entered. Tap the field first (tap_mark), then fill."
                : "type — no editable field was focused, so nothing was typed. Tap the field first (tap_mark), or use set_value(id) to address a marked field directly."
            return false
        }
        if !changed && !text.isEmpty {
            lastDriverDetail = passwordSafe
                ? "fill_credential — the focused field did not change; it may be a controlled or read-only input that ignores synthetic keystrokes."
                : "type — the focused field's value did not change; it may be a controlled or read-only input (a date/number/datetime-local picker, or a framework-controlled field) that ignores synthetic keystrokes. Use set_value(id, value) on its mark instead."
            return false
        }
        return true
    }

    /// `set_value(id, value)` — WB-27. Set the input/textarea/select behind
    /// mark `id` to `value` the controlled-component way, then read the value
    /// back and report whether it stuck.
    ///
    /// **Why a distinct act rather than a `value` arg on `type`.** `type`
    /// sends its text to whatever `document.activeElement` happens to be and
    /// leaves the value's fate to the field; `set_value` addresses the mark's
    /// element directly (via the same parked registry `scroll_into_view`
    /// uses), focuses it itself, drives the native setter, and VERIFIES the
    /// read-back. The two have different contracts — one keystroke-shaped and
    /// caret-relative, one whole-value and verified — so they read cleaner as
    /// two tools than as one overloaded switch on which arg was passed. It is
    /// web-only for the same reason `scroll_into_view` is: the AX value-set on
    /// macOS/iOS needs per-role verification this ticket didn't buy, and a
    /// value-set that silently no-ops while reporting success is the exact
    /// dishonesty W36 was about.
    private func dispatchSetValue(id: Int, value: String) async throws {
        guard lastMarks.contains(where: { $0.id == id }) else {
            throw WebDriverError.unknownMark(id: id)
        }
        let js = WebMarkProbe.setValueJS(id: id, value: value)
        let result = try await runJSAndReturn(js)
        guard let dict = result as? [String: Any],
              let status = dict["status"] as? String else {
            lastDriverDetail = "set_value(\(id)) — the page returned nothing; it may have navigated mid-action."
            return
        }
        let label = lastMarks.first(where: { $0.id == id })?.label ?? ""
        switch status {
        case "no-registry", "stale":
            throw WebDriverError.markElementGone(id: id, reason: status == "no-registry" ? "no-registry" : "stale")
        case "not-settable":
            let tag = (dict["tag"] as? String) ?? "element"
            throw WebDriverError.valueNotSettable(id: id, tag: tag)
        case "ok":
            let stuck = (dict["stuck"] as? Bool) ?? false
            let after = (dict["after"] as? String) ?? ""
            if stuck {
                lastDriverDetail = "set_value(\(id)) — set \"\(label)\" to \"\(after)\"; the field holds the value."
            } else {
                let expected = (dict["expected"] as? String) ?? value
                lastDriverDetail = "set_value(\(id)) — set \"\(label)\", but the field now reads \"\(after)\" (expected \"\(expected)\"); the value did not stick. Check the format — a datetime-local wants yyyy-MM-ddThh:mm, a date yyyy-MM-dd, a select an existing option value or label."
            }
        default:
            lastDriverDetail = "set_value(\(id)) — unexpected status \"\(status)\"."
        }
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
        // Bound the eval: a side-effecting JS that triggers a navigation can
        // leave WKWebView's callback uncalled while the page tears down. Time
        // out and proceed (the side effect was already dispatched; the settle
        // / probe / capture timeouts bound the rest). A genuine JS error still
        // throws so real failures aren't masked.
        let outcome: String?? = await Self.raceAgainstTimeout(.seconds(8)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                Task { @MainActor in
                    controller.webView.evaluateJavaScript(js) { _, error in
                        cont.resume(returning: error?.localizedDescription)
                    }
                }
            }
        }
        guard let jsError = outcome else {
            Self.logger.warning("runJS timed out after 8s (navigation in flight?); proceeding")
            return
        }
        if let jsError {
            throw WebDriverError.jsEvaluationFailed(jsError)
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
        // Diagnostics-only (which element clicked, post-click URL). Bound it:
        // a click that navigates can leave the callback uncalled as the page
        // tears down — return no diagnostics rather than hanging the click.
        let result: JSReturn? = await Self.raceAgainstTimeout(.seconds(8)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<JSReturn, Never>) in
                Task { @MainActor in
                    controller.webView.evaluateJavaScript(js) { value, _ in
                        cont.resume(returning: JSReturn(value: value))
                    }
                }
            }
        }
        if result == nil {
            Self.logger.warning("runJSAndReturn timed out after 8s (navigation in flight?); no diagnostics")
        }
        return result?.value
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
        // Probe source lives in `WebMarkProbe` so the test suite can run the
        // SAME JavaScript against fixture pages in a real WKWebView.
        let js = WebMarkProbe.js
        // Need a return value from JS — switch off the side-effect-only
        // `runJS` path here. Convert the non-Sendable `[[String: Any]]`
        // dict array into our Sendable `InteractiveMark` shape **inside
        // the @MainActor closure** so the boundary crossing carries
        // only Sendable values.
        // Bound the probe's eval: this runs BEFORE the snapshot every step, and
        // a stuck navigation can leave `evaluateJavaScript` uncalled until the
        // new document's JS context is ready (never, for a hung load) — the same
        // hang class the settle fix addresses. Time out to an empty mark set;
        // the agent can still tap by coordinate.
        let marks: [InteractiveMark]? = await Self.raceAgainstTimeout(.seconds(8)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<[InteractiveMark], Never>) in
                Task { @MainActor in
                    controller.webView.evaluateJavaScript(js) { value, error in
                        if error != nil { cont.resume(returning: []); return }
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
                                label: (dict["label"] as? String) ?? "",
                                labelSource: dict["label_source"] as? String
                            )
                        }
                        cont.resume(returning: marks)
                    }
                }
            }
        }
        if marks == nil {
            Self.logger.warning("probeInteractiveElements timed out after 8s (page stuck loading?); returning no marks")
        }
        return marks ?? []
    }

    // MARK: - Visible page text

    /// Longest `page_text` the driver will hand back, in Characters. A
    /// content-heavy documentation page can run well past this; 20k keeps
    /// the MCP result a sane size while comfortably covering the text a
    /// downstream assertion would look for. Truncation is marked with a
    /// trailing ellipsis so a consumer can tell a capped read from a
    /// complete one.
    static let pageTextCap = 20_000

    /// Read the frame's visible text (an `innerText` read, which respects
    /// CSS visibility the way `textContent` does not), collapse its
    /// whitespace, and cap it.
    ///
    /// The ROOT of that read is `WebMarkProbe.pageTextJS`'s decision, not
    /// `document.body`: while a modal or overlay dialog is open it is the
    /// dialog's subtree plus whatever paints above it — the same scoping the
    /// mark table gets, from the same shared prelude, so the text and the
    /// marks always describe one frame (W31a).
    ///
    /// Best-effort by construction: a JS error, an absent body, or a stuck
    /// page load all return `nil` rather than failing the screenshot.
    ///
    /// Bounded at **2s**, deliberately tighter than the mark probe's 8s: this
    /// runs on EVERY web capture, including the autonomous run loop's, and
    /// page text is a convenience for downstream text assertions — never
    /// worth adding a second 8s stall to a step that is already waiting out
    /// a hung page.
    ///
    /// Note what that budget now covers. Since W31a this is no longer a
    /// one-line `innerText` read: the shared prelude runs the whole modal
    /// decision first, including a bounded candidate scan. The scan is
    /// capped (a rect test rejects almost everything before any style read,
    /// and the budget counts survivors) and still resolves in single-digit
    /// milliseconds on a heavy page — but it is real work, and it is the
    /// SECOND time this step does it, the mark probe being the first. If a
    /// future change makes either side more expensive, merge the two
    /// evaluations rather than raising this timeout: computing the modal
    /// once would also close the small window in which the marks and the
    /// text could disagree about it.
    private func probeVisibleText() async -> String? {
        // W31a — scoped by the SAME modal rule the mark table uses (the
        // shared prelude in `WebMarkProbe`). With a modal open this reads
        // the modal's own text plus whatever paints above it, NOT the whole
        // dimmed document, so `page_text` can no longer satisfy a text
        // assertion with copy the agent cannot see.
        let js = WebMarkProbe.pageTextJS
        let result: String? = await Self.raceAgainstTimeout(.seconds(2)) { [controller] in
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                Task { @MainActor in
                    controller.webView.evaluateJavaScript(js) { value, error in
                        if error != nil { cont.resume(returning: ""); return }
                        cont.resume(returning: (value as? String) ?? "")
                    }
                }
            }
        }
        guard let raw = result else {
            Self.logger.warning("probeVisibleText timed out after 2s; omitting page_text")
            return nil
        }
        return Self.normalizePageText(raw, cap: Self.pageTextCap)
    }

    /// Normalize + cap extracted page text. Trims each line, collapses runs
    /// of blank lines down to a single separator (browsers emit long blank
    /// runs from layout gaps), and drops leading/trailing blanks — while
    /// KEEPING the newlines that carry the page's reading structure.
    /// Returns `nil` for text that is empty after trimming.
    /// `internal` so the test suite can pin the capping contract without a
    /// live WKWebView.
    static func normalizePageText(_ raw: String, cap: Int) -> String? {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var normalized: [String] = []
        normalized.reserveCapacity(lines.count)
        for line in lines {
            if line.isEmpty, normalized.last?.isEmpty ?? true { continue }   // collapse blank runs / leading blanks
            normalized.append(line)
        }
        while normalized.last?.isEmpty == true { normalized.removeLast() }

        let text = normalized.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "…"
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

    // MARK: - scroll_into_view (WB-17, W7/W34)

    /// Scroll mark `id`'s element into view and report the movement.
    ///
    /// **Why a new act rather than a wider mark table.** The probe's
    /// contract is that a mark is something the agent can act on *now*:
    /// every mark intersects the viewport, because a badge is drawn on it
    /// and a click is dispatched at its rect. Reporting off-viewport
    /// elements would break that in both directions — a badge with nowhere
    /// to draw, and a `tap_mark` that lands on whatever happens to occupy
    /// those coordinates instead. So the table keeps its contract and the
    /// gap is closed the other way: a partially-visible mark (the row
    /// clipped by the fold, the button under a sticky footer) is brought
    /// fully into view, and the auto-observe that follows re-probes — which
    /// is what surfaces the elements that were previously off-screen
    /// entirely, now as ordinary marks.
    ///
    /// The element is addressed through `window.__harnessMarkElements`,
    /// which the mark walk parks alongside the marks it returned: index
    /// `id - 1`. No attribute is written into the page (a React tree is
    /// not ours to mutate) and no second DOM walk is needed. A document
    /// navigation clears the global, and an id from the old frame then
    /// fails honestly instead of scrolling to whatever now sits at that
    /// index.
    ///
    /// **An SPA re-render is not covered by that**, and neither is the
    /// `lastMarks` guard: React can keep a DOM node mounted and swap the
    /// data inside it, so `isConnected` stays true and mark 3 can now be a
    /// different row than the one the caller saw. The blast radius is
    /// small — this tool only moves the viewport, so the worst case is
    /// scrolling to the wrong row, which the returned observation shows —
    /// but it is not a guarantee, and a caller must read the marks it gets
    /// back rather than assume the ones it sent.
    private func dispatchScrollIntoView(id: Int) async throws {
        guard lastMarks.contains(where: { $0.id == id }) else {
            throw WebDriverError.unknownMark(id: id)
        }
        let js = """
        (() => {
          const reg = window['\(WebMarkProbe.elementRegistryKey)'];
          if (!reg || !reg.length) return { status: "no-registry" };
          const el = reg[\(id) - 1];
          if (!el || !el.isConnected) return { status: "stale" };
          const before = el.getBoundingClientRect();
          try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); }
          catch (e) { el.scrollIntoView(true); }
          const after = el.getBoundingClientRect();
          const vh = window.innerHeight, vw = window.innerWidth;
          return {
            status: "ok",
            beforeY: Math.round(before.top),
            afterY: Math.round(after.top),
            beforeX: Math.round(before.left),
            afterX: Math.round(after.left),
            fully: after.top >= 0 && after.left >= 0 && after.bottom <= vh && after.right <= vw
          };
        })();
        """
        let result = try await runJSAndReturn(js)
        guard let dict = result as? [String: Any],
              let status = dict["status"] as? String else {
            lastDriverDetail = "scroll_into_view(\(id)) — the page returned nothing; it may have navigated mid-action."
            return
        }
        // The id WAS in the latest mark set (the guard above), so this is
        // not "unknown mark" — the frame those ids belong to is gone, or
        // the element was unmounted under us. Say that, rather than telling
        // the agent to re-screenshot for a refresh that won't help.
        guard status == "ok" else {
            throw WebDriverError.markElementGone(id: id, reason: status)
        }
        let beforeY = (dict["beforeY"] as? Double) ?? Double((dict["beforeY"] as? Int) ?? 0)
        let afterY = (dict["afterY"] as? Double) ?? Double((dict["afterY"] as? Int) ?? 0)
        let beforeX = (dict["beforeX"] as? Double) ?? Double((dict["beforeX"] as? Int) ?? 0)
        let afterX = (dict["afterX"] as? Double) ?? Double((dict["afterX"] as? Int) ?? 0)
        let fully = (dict["fully"] as? Bool) ?? false
        let dy = Int((afterY - beforeY).rounded())
        let dx = Int((afterX - beforeX).rounded())
        let label = lastMarks.first(where: { $0.id == id })?.label ?? ""
        if dy == 0 && dx == 0 {
            lastDriverDetail = "scroll_into_view(\(id)) — \"\(label)\" was already in view; nothing scrolled"
                + (fully ? "." : " and it is still clipped by the viewport (a sticky header or an inner scroller may be holding it).")
        } else {
            lastDriverDetail = "scroll_into_view(\(id)) — \"\(label)\" moved by (\(dx), \(dy)) to y=\(Int(afterY)); "
                + (fully ? "now fully in view." : "still not fully in view.")
                + " The marks in this observation were re-probed after the scroll, so ids have changed."
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
    case captureTimedOut
    case jsEvaluationFailed(String)
    case invalidURL(String)
    /// V6 — agent emitted `tap_mark(id:)` with an id that wasn't in the
    /// most recent screenshot's mark cache. Surfaces back through the
    /// run as a tool failure so the next iteration's screenshot can
    /// re-establish marks.
    case unknownMark(id: Int)
    /// WB-17 — `scroll_into_view(id)` named a mark that IS in the current
    /// mark set, but the element list the probe parked is gone (a
    /// navigation wiped the window global) or the element has been
    /// unmounted. Distinct from `unknownMark` because the advice differs:
    /// re-observing does help here, and only here.
    case markElementGone(id: Int, reason: String)
    /// WB-27 — `set_value(id)` resolved to an element that is neither a
    /// value-bearing control (input/textarea/select) nor contenteditable, so
    /// there is nothing to set. An honest failure beats writing a value the
    /// element can't hold and reporting success.
    case valueNotSettable(id: Int, tag: String)

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "WKWebView snapshot failed."
        case .captureTimedOut: return "WKWebView snapshot timed out — the page is likely wedged after a navigation that never finished loading."
        case .jsEvaluationFailed(let m): return "JavaScript evaluation failed: \(m)"
        case .invalidURL(let s): return "Invalid URL: '\(s)'."
        case .unknownMark(let id):
            return "tap_mark(id: \(id)) — that id wasn't in the latest screenshot's mark set. The page may have changed; the next screenshot will refresh the marks."
        case .markElementGone(let id, let reason):
            let why = reason == "stale"
                ? "the element behind it has been removed from the page"
                : "the frame it was probed in is gone (a navigation cleared it)"
            return "scroll_into_view(id: \(id)) — \(why). Observe again and use an id from the new mark set."
        case .valueNotSettable(let id, let tag):
            return "set_value(id: \(id)) — the marked element (<\(tag.lowercased())>) is not an input, textarea, select, or editable field, so it has no value to set. Pick the mark on the actual form control."
        }
    }
}

