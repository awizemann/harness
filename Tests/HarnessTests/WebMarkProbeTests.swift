//
//  WebMarkProbeTests.swift
//  HarnessTests
//
//  Runs the REAL Set-of-Mark probe source (`WebMarkProbe.js`, the same
//  string `WebDriver` evaluates before every snapshot) against fixture
//  pages in a live WKWebView. Nothing here re-implements the probe: a
//  failure means the shipped JavaScript is wrong.
//
//  Coverage:
//    * W14 — a modal dialog's dimmed background is filtered out, including
//      a background button whose label collides with the modal's own; an
//      element painted ABOVE the modal (a toast) survives; `inert` and
//      `pointer-events: none` subtrees are dropped; a NON-modal
//      `<dialog open>` leaves the page alone; a partially-covered control
//      (sticky header) and a partially-offscreen one are NOT false-dropped.
//    * W15 — the accessible-name chain never yields an empty label: img
//      alt, inline-SVG <title>, an icon-only close glyph, a test hook, and
//      the last-resort synthesized placeholder, each with its provenance.
//

import Testing
import Foundation
import WebKit
@testable import Harness

// MARK: - Harness

/// One probed mark, flattened to Sendable values on the main actor.
private struct ProbedMark: Sendable {
    let label: String
    let source: String
    let role: String
    let x: Double
    let y: Double
}

private enum ProbeRunner {

    /// Load `html` into an offscreen 900×700 WKWebView and return what the
    /// shipped probe makes of it.
    @MainActor
    static func run(_ html: String) async throws -> [ProbedMark] {
        let (webView, _) = try await load(html)
        let value = try await webView.evaluateJavaScript(WebMarkProbe.js)
        let array = (value as? [[String: Any]]) ?? []
        return array.map { dict in
            ProbedMark(
                label: (dict["label"] as? String) ?? "",
                source: (dict["label_source"] as? String) ?? "",
                role: (dict["role"] as? String) ?? "",
                x: (dict["x"] as? Double) ?? Double((dict["x"] as? Int) ?? 0),
                y: (dict["y"] as? Double) ?? Double((dict["y"] as? Int) ?? 0)
            )
        }
    }

    /// Load `html` into an offscreen 900×700 WKWebView, settled enough for
    /// layout and hit-testing to be meaningful.
    @MainActor
    private static func load(_ html: String) async throws -> (WKWebView, LoadWaiter) {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                                configuration: config)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://harness.test/"))
        try await delegate.wait()
        // One turn of the runloop so layout/style resolution has happened
        // before the probe hit-tests anything.
        try await Task.sleep(nanoseconds: 120_000_000)
        return (webView, delegate)
    }

    /// Load `html` and return what the shipped PAGE-TEXT probe makes of
    /// it — the same source `WebDriver.probeVisibleText` evaluates.
    @MainActor
    static func pageText(_ html: String) async throws -> String {
        let (webView, _) = try await load(html)
        let value = try await webView.evaluateJavaScript(WebMarkProbe.pageTextJS)
        return (value as? String) ?? ""
    }

    /// Load `html`, run the mark probe, and report how many elements it
    /// parked on `window.__harnessMarkElements` beside the marks it
    /// returned — the registry `scroll_into_view(id)` resolves against.
    @MainActor
    static func registryCount(_ html: String) async throws -> (marks: Int, registry: Int) {
        let (webView, _) = try await load(html)
        let value = try await webView.evaluateJavaScript(WebMarkProbe.js)
        let marks = ((value as? [[String: Any]]) ?? []).count
        let count = try await webView.evaluateJavaScript(
            "(() => (window['\(WebMarkProbe.elementRegistryKey)'] || []).length)();"
        )
        return (marks, (count as? Int) ?? -1)
    }

    /// `loadHTMLString` completion, as an awaitable. WebKit's own
    /// `navigationDelegate` is the only honest "the DOM is up" signal.
    @MainActor
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        private var failure: Error?

        func wait() async throws {
            if finished { return }
            if let failure { throw failure }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failure = error
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            failure = error
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

private extension Array where Element == ProbedMark {
    func labels() -> [String] { map(\.label) }
    func count(labelled label: String) -> Int { filter { $0.label == label }.count }
    func first(labelled label: String) -> ProbedMark? { first { $0.label == label } }
}

/// Page chrome shared by the modal fixtures: a dashboard with its own
/// "Add Site" button, which is exactly the collision that made a
/// drop-help flow born-broken (W12, caused by W14).
private let dashboardBackground = """
<h1>Dashboard</h1>
<button id="bg-add">Add Site</button>
<button id="bg-refresh">Refresh</button>
"""

// MARK: - W14: interactability

@Suite("Web mark probe — interactability (W14)", .serialized)
struct WebMarkProbeInteractabilityTests {

    @Test("an open modal removes the dimmed background, colliding labels included")
    @MainActor
    func modalFiltersBackground() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <div id="scrim" style="position:fixed;inset:0;background:rgba(0,0,0,.5)"></div>
        <div role="dialog" aria-modal="true"
             style="position:fixed;top:120px;left:120px;width:400px;height:300px;background:#fff">
          <h2>New site</h2>
          <input id="site" aria-label="Site Name *">
          <button id="modal-add">Add Site</button>
        </div>
        </body></html>
        """)
        // Exactly ONE "Add Site" survives — the modal's.
        #expect(marks.count(labelled: "Add Site") == 1)
        #expect(marks.first(labelled: "Site Name *") != nil)
        // The background is gone entirely.
        #expect(marks.first(labelled: "Refresh") == nil)
    }

    @Test("a <dialog> opened modally filters the background; a non-modal one does not")
    @MainActor
    func dialogModality() async throws {
        let page = """
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <dialog id="d"><button id="modal-add">Add Site</button></dialog>
        <script>document.getElementById('d').%@();</script>
        </body></html>
        """
        let modal = try await ProbeRunner.run(page.replacingOccurrences(of: "%@", with: "showModal"))
        #expect(modal.count(labelled: "Add Site") == 1)
        #expect(modal.first(labelled: "Refresh") == nil)

        let nonModal = try await ProbeRunner.run(page.replacingOccurrences(of: "%@", with: "show"))
        // `.show()` leaves the page live — both buttons are genuinely usable,
        // so the table must still carry both.
        #expect(nonModal.count(labelled: "Add Site") == 2)
        #expect(nonModal.first(labelled: "Refresh") != nil)
    }

    @Test("an element painted above the modal (a toast) stays in the table")
    @MainActor
    func toastAboveModalSurvives() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <div id="scrim" style="position:fixed;inset:0;z-index:10;background:rgba(0,0,0,.5)"></div>
        <div role="dialog" aria-modal="true"
             style="position:fixed;z-index:20;top:120px;left:120px;width:400px;height:300px;background:#fff">
          <button id="modal-add">Add Site</button>
        </div>
        <div style="position:fixed;z-index:50;top:8px;right:8px;background:#222;padding:8px">
          <button id="toast-undo">Undo</button>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Undo") != nil)
        #expect(marks.first(labelled: "Refresh") == nil)
    }

    @Test("a scrim wrapper enclosing BOTH the modal and the page still filters the background")
    @MainActor
    func portalWrapperDoesNotRescueBackground() async throws {
        // The adversarial shape for the hit-test: the topmost element at the
        // background button's point is an ANCESTOR of it (the wrapper), which
        // the generous "ancestor counts" rule would otherwise wave through.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div id="wrapper" style="position:relative">
          \(dashboardBackground)
          <div style="position:fixed;inset:0;background:rgba(0,0,0,.5);pointer-events:none"></div>
          <div role="dialog" aria-modal="true"
               style="position:fixed;top:120px;left:120px;width:400px;height:300px;background:#fff">
            <button id="modal-add">Add Site</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.count(labelled: "Add Site") == 1)
        #expect(marks.first(labelled: "Refresh") == nil)
    }

    @Test("an overlay occludes background controls even with no modal semantics")
    @MainActor
    func plainOverlayOccludes() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button id="under" style="position:absolute;top:40px;left:40px;width:120px;height:32px">Buried</button>
        <button id="over" style="position:absolute;top:200px;left:40px;width:120px;height:32px">Visible</button>
        <div style="position:fixed;top:0;left:0;width:300px;height:120px;background:#fff"></div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Buried") == nil)
        #expect(marks.first(labelled: "Visible") != nil)
    }

    @Test("inert and pointer-events:none subtrees are not marked")
    @MainActor
    func inertAndPointerEventsFiltered() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div inert><button>Inert Button</button></div>
        <div style="pointer-events:none"><button>Scenery Button</button></div>
        <div style="pointer-events:none"><button style="pointer-events:auto">Re-enabled Button</button></div>
        <button>Live Button</button>
        </body></html>
        """)
        #expect(marks.first(labelled: "Inert Button") == nil)
        #expect(marks.first(labelled: "Scenery Button") == nil)
        // `pointer-events` is inherited, so a subtree can opt back IN.
        #expect(marks.first(labelled: "Re-enabled Button") != nil)
        #expect(marks.first(labelled: "Live Button") != nil)
    }

    @Test("a control half-covered by a sticky header is kept, not false-dropped")
    @MainActor
    func stickyHeaderDoesNotFalseDrop() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button id="half" style="position:absolute;top:30px;left:20px;width:200px;height:60px">Half Covered</button>
        <div style="position:fixed;top:0;left:0;right:0;height:56px;background:#eee"></div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Half Covered") != nil)
    }

    @Test("a partially-offscreen control is probed where it is visible")
    @MainActor
    func partiallyOffscreenKept() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button style="position:absolute;top:-20px;left:-60px;width:200px;height:60px">Bleeding Top Left</button>
        <button style="position:absolute;top:600px;left:820px;width:200px;height:60px">Bleeding Bottom Right</button>
        </body></html>
        """)
        #expect(marks.first(labelled: "Bleeding Top Left") != nil)
        #expect(marks.first(labelled: "Bleeding Bottom Right") != nil)
    }

    @Test("a control inside a modal is kept even when its own child paints over it")
    @MainActor
    func modalChildOverlayKept() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <div role="dialog" aria-modal="true"
             style="position:fixed;top:60px;left:60px;width:500px;height:400px;background:#fff">
          <button style="position:relative">Save<span style="position:absolute;inset:0"></span></button>
          <input aria-label="Notes">
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Save") != nil)
        #expect(marks.first(labelled: "Notes") != nil)
    }

    @Test("no modal, no overlay: the ordinary page is unchanged")
    @MainActor
    func ordinaryPageUnaffected() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <a href="/pricing">Pricing</a>
        <label for="email">Your Email *</label>
        <input id="email" placeholder="john@example.com">
        <button>Sign in</button>
        </body></html>
        """)
        #expect(marks.first(labelled: "Pricing") != nil)
        #expect(marks.first(labelled: "Sign in") != nil)
        #expect(marks.first(labelled: "Your Email *")?.source == "label")
    }
}

// MARK: - W15: naming

@Suite("Web mark probe — accessible names (W15)", .serialized)
struct WebMarkProbeLabelTests {

    @Test("no mark ever carries an empty label")
    @MainActor
    func neverEmpty() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button id="a" style="width:24px;height:24px"></button>
        <button id="b" style="width:24px;height:24px"><svg width="12" height="12"></svg></button>
        <a href="/x" style="display:inline-block;width:24px;height:24px"></a>
        <input type="checkbox">
        </body></html>
        """)
        #expect(!marks.isEmpty)
        #expect(marks.labels().allSatisfy { !$0.isEmpty })
    }

    @Test("an icon-only close button gets a real label with glyph provenance")
    @MainActor
    func closeGlyphSynthesized() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div role="dialog" aria-modal="true" style="position:fixed;inset:40px;background:#fff">
          <button id="x" style="width:32px;height:32px">✕</button>
          <button id="save">Save</button>
        </div>
        </body></html>
        """)
        let close = try #require(marks.first { $0.source == "glyph" })
        #expect(close.label == "Close")
        #expect(marks.first(labelled: "Save")?.source == "text")
    }

    @Test("icon-only controls take their name from img alt / svg <title>")
    @MainActor
    func iconNames() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button id="img" style="width:32px;height:32px">
          <img alt="Delete site" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="16" height="16">
        </button>
        <button id="svg" style="width:32px;height:32px">
          <svg width="16" height="16"><title>Settings</title><rect width="16" height="16"></rect></svg>
        </button>
        <button id="svglabel" style="width:32px;height:32px">
          <svg width="16" height="16" aria-label="Notifications"><rect width="16" height="16"></rect></svg>
        </button>
        </body></html>
        """)
        #expect(marks.first(labelled: "Delete site")?.source == "img-alt")
        #expect(marks.first(labelled: "Settings")?.source == "svg-title")
        #expect(marks.first(labelled: "Notifications")?.source == "svg-title")
    }

    @Test("a test hook names a control the page otherwise leaves anonymous")
    @MainActor
    func testIDFallback() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button data-testid="site-menu-toggle" style="width:32px;height:32px"></button>
        </body></html>
        """)
        let mark = try #require(marks.first)
        #expect(mark.label == "site-menu-toggle")
        #expect(mark.source == "testid")
    }

    @Test("a genuinely nameless control gets an explicit synthesized placeholder")
    @MainActor
    func synthesizedPlaceholder() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button style="width:28px;height:28px"></button>
        </body></html>
        """)
        let mark = try #require(marks.first)
        #expect(mark.source == "synthesized")
        #expect(mark.label == "unlabelled button")
        #expect(mark.label.hasPrefix(WebMarkProbe.synthesizedLabelPrefix))
    }

    @Test("a big nameless container is still dropped, synthesized label notwithstanding")
    @MainActor
    func bigNamelessContainerStillDropped() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div role="button" style="width:400px;height:200px"></div>
        <button style="width:28px;height:28px"></button>
        </body></html>
        """)
        #expect(marks.count == 1)
        #expect(marks.first?.role == "button")
    }

    @Test("every emitted label_source is one the outputSchema declares")
    @MainActor
    func sourcesAreSchemaLegal() async throws {
        let properties = try #require(UIObservationPayload.outputSchema()["properties"] as? [String: Any])
        let items = try #require((properties["marks"] as? [String: Any])?["items"] as? [String: Any])
        let itemProps = try #require(items["properties"] as? [String: Any])
        let allowed = Set(try #require((itemProps["label_source"] as? [String: Any])?["enum"] as? [String]))

        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button aria-label="Aria">a</button>
        <span id="lb">Labelled By</span><button aria-labelledby="lb">b</button>
        <label for="e">Your Email *</label><input id="e" placeholder="john@example.com">
        <input placeholder="Search sites">
        <button title="Titled" style="width:24px;height:24px"></button>
        <input type="submit" value="Submit">
        <button>Plain text</button>
        <button style="width:24px;height:24px"><img alt="Alt name" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="8" height="8"></button>
        <button style="width:24px;height:24px"><svg width="8" height="8"><title>Svg name</title></svg></button>
        <button style="width:24px;height:24px">✕</button>
        <button data-testid="hook" style="width:24px;height:24px"></button>
        <input name="nameattr" type="checkbox">
        <button style="width:24px;height:24px"></button>
        </body></html>
        """)
        #expect(!marks.isEmpty)
        for mark in marks {
            #expect(allowed.contains(mark.source), "'\(mark.source)' is not in the declared label_source enum")
            #expect(!mark.label.isEmpty)
        }
        // The chain's stable head still wins where it applies.
        #expect(marks.first(labelled: "Aria")?.source == "aria-label")
        #expect(marks.first(labelled: "Labelled By")?.source == "labelledby")
        #expect(marks.first(labelled: "Your Email *")?.source == "label")
        #expect(marks.first(labelled: "Search sites")?.source == "placeholder")
    }
}

// MARK: - Secret fields (WB-14)

@Suite("Web mark probe — password fields never leak their value", .serialized)
struct WebMarkProbeSecretFieldTests {

    private static let secret = "PASSWORD-THAT-MUST-NEVER-BE-A-LABEL-3311"

    @Test("an unlabelled password field is named from its type, never from its value")
    @MainActor
    func unlabelledPasswordNeverLeaksValue() async throws {
        // No aria-label, no <label>, no placeholder, no title — the exact
        // shape that used to fall through to the `value` fallback. WebKit
        // renders bullets but `el.value` is the PLAINTEXT.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <input id="pw" type="password" value="\(Self.secret)">
        </body></html>
        """)
        let mark = try #require(marks.first { $0.source == "secure-field" })
        #expect(mark.label == "Password")
        #expect(marks.labels().allSatisfy { !$0.contains(Self.secret) },
                "a password's value must never reach the mark table")
    }

    @Test("a password field labelled by autocomplete alone is still not value-labelled")
    @MainActor
    func autocompletePasswordIsSecret() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <input id="pw" type="text" autocomplete="current-password" value="\(Self.secret)">
        </body></html>
        """)
        #expect(marks.labels().allSatisfy { !$0.contains(Self.secret) })
        #expect(marks.first { $0.source == "secure-field" } != nil)
    }

    @Test("a properly labelled password field keeps its real label")
    @MainActor
    func labelledPasswordKeepsItsLabel() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <input id="pw" type="password" aria-label="Password field" value="\(Self.secret)">
        </body></html>
        """)
        #expect(marks.first(labelled: "Password field")?.source == "aria-label")
        #expect(marks.labels().allSatisfy { !$0.contains(Self.secret) })
    }

    @Test("an ordinary text field still labels from its value (the fallback is intact)")
    @MainActor
    func ordinaryValueFallbackIntact() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <input id="q" type="text" value="Berlin">
        </body></html>
        """)
        #expect(marks.first(labelled: "Berlin")?.source == "value")
    }
}

// MARK: - W31b: modals nobody declared

/// The drop-help re-shakedown found the W14 filter half-effective: the
/// "Add New Site" dialog carried `aria-modal`, so its background was
/// filtered — while the DELETE-CONFIRM dialog, a plain portal of
/// `<div class="fixed inset-0 z-50 bg-black/50 …">` around a card, carried
/// no dialog semantics at all and kept every background mark.
///
/// These fixtures are deliberately SEMANTICS-FREE — no `role`, no
/// `aria-modal`, no `<dialog>` — because that is the shape that escaped.
/// Half of them assert the heuristic FIRES and half assert it does NOT:
/// a rule that swallows ordinary page content is worse than the bug it
/// fixes, since a dropped control is unaddressable.
private let confirmDialogPage = """
<!doctype html><html><body style="margin:0">
<h1>Dashboard</h1>
<button id="bg-add">Add Site</button>
<button id="bg-refresh">Refresh</button>
<p>Background copy nobody can read right now.</p>
<div id="overlay" style="position:fixed;inset:0;z-index:50;background:rgba(0,0,0,.5)">
  <div style="position:absolute;top:180px;left:250px;width:400px;height:220px;background:#ffffff">
    <h2>Delete this site?</h2>
    <p>This cannot be undone.</p>
    <button id="confirm">Delete</button>
    <button id="cancel">Cancel</button>
  </div>
</div>
</body></html>
"""

@Suite("Web mark probe — undeclared modals (W31b)", .serialized)
struct WebMarkProbeOverlayModalTests {

    @Test("a semantics-free confirm dialog filters the page behind it")
    @MainActor
    func confirmDialogFiltersBackground() async throws {
        let marks = try await ProbeRunner.run(confirmDialogPage)
        #expect(marks.first(labelled: "Delete") != nil)
        #expect(marks.first(labelled: "Cancel") != nil)
        #expect(marks.first(labelled: "Add Site") == nil)
        #expect(marks.first(labelled: "Refresh") == nil)
    }

    @Test("an OPAQUE full-screen shell is not a modal — its content is not swallowed")
    @MainActor
    func opaqueShellIsNotAModal() async throws {
        // The obvious false positive: an app shell pinned to the viewport
        // with a lifted z-index and a card inside it. It is opaque, so it
        // is not a scrim — and nothing behind it needs filtering, because
        // the occlusion hit-test already covers that case.
        let page = """
        <!doctype html><html><body style="margin:0">
        <div id="shell" style="position:fixed;inset:0;z-index:10;background:#ffffff">
          <h1>Dashboard</h1>
          <div style="position:absolute;top:40px;left:40px;width:300px;height:150px;background:#eeeeee">
            <button id="add">Add Site</button>
            <button id="refresh">Refresh</button>
          </div>
        </div>
        <footer>Footer note</footer>
        </body></html>
        """
        let marks = try await ProbeRunner.run(page)
        #expect(marks.first(labelled: "Add Site") != nil)
        #expect(marks.first(labelled: "Refresh") != nil)
        // The tell that the heuristic did NOT fire: page text is still the
        // whole document, not one subtree's.
        let text = try await ProbeRunner.pageText(page)
        #expect(text.contains("Footer note"))
    }

    @Test("a decorative translucent veil that blocks nothing is not a modal")
    @MainActor
    func decorativeVeilIsNotAModal() async throws {
        // Translucent and full-viewport, but `pointer-events: none` — it
        // is scenery, and the page under it is genuinely usable.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button id="add">Add Site</button>
        <button id="refresh">Refresh</button>
        <div style="position:fixed;inset:0;z-index:40;background:rgba(0,0,0,.25);pointer-events:none">
          <div style="position:absolute;top:100px;left:100px;width:300px;height:200px;background:#fff">
            <button>Decoration</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Add Site") != nil)
        #expect(marks.first(labelled: "Refresh") != nil)
        // The veil's own "control" inherits `pointer-events: none`, so it
        // is scenery in both directions: not a live control, not marked.
        #expect(marks.first(labelled: "Decoration") == nil)
    }

    @Test("the portal shape that CAUSED the bug: a click-through wrapper with a live card")
    @MainActor
    func clickThroughPortalWrapperIsAModal() async throws {
        // Radix / Headless UI render a dialog as a full-viewport wrapper
        // that lets clicks through (`pointer-events: none`) with a
        // `pointer-events: auto` card inside. Because the wrapper passes
        // clicks, the occlusion hit-test REACHES the page behind it — which
        // is precisely why drop-help's delete-confirm kept its background
        // marks while its aria-modal "Add New Site" dialog did not.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <p>Background copy nobody can read right now.</p>
        <div style="position:fixed;inset:0;z-index:50;background:rgba(0,0,0,.5);pointer-events:none">
          <div style="position:absolute;top:180px;left:250px;width:400px;height:220px;background:#fff;pointer-events:auto">
            <h2>Delete this site?</h2>
            <button>Delete site</button>
            <button>Keep site</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Delete site") != nil)
        #expect(marks.first(labelled: "Keep site") != nil)
        #expect(marks.first(labelled: "Add Site") == nil)
        #expect(marks.first(labelled: "Refresh") == nil)
    }

    @Test("a full-viewport busy-veil with no dialog card in it is not a modal")
    @MainActor
    func scrimWithoutContentBoxIsNotAModal() async throws {
        // A translucent, pointer-blocking veil — but with a bare inline
        // link and NO card. Nothing here is a dialog, and treating it as
        // one would throw away the whole page's text: `page_text` is where
        // this clause actually bites, since a full-viewport veil already
        // occludes the background out of the mark table either way.
        let page = """
        <!doctype html><html><body style="margin:0">
        <h1>Dashboard</h1>
        <p>Sites you have not published yet appear here.</p>
        <button id="add" style="position:relative;z-index:60">Add Site</button>
        <div style="position:fixed;inset:0;z-index:40;background:rgba(0,0,0,.25)">
          <a href="/cancel">Cancel loading</a>
        </div>
        </body></html>
        """
        let text = try await ProbeRunner.pageText(page)
        #expect(text.contains("Sites you have not published yet appear here."),
                "a tinted page is not a dialog; its text must survive")
        let marks = try await ProbeRunner.run(page)
        #expect(marks.first(labelled: "Add Site") != nil)
    }

    @Test("a toast and a sticky header are still not modals")
    @MainActor
    func toastAndStickyHeaderAreNotModals() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button id="add" style="position:absolute;top:200px;left:20px">Add Site</button>
        <div style="position:fixed;top:0;left:0;right:0;height:56px;z-index:30;background:rgba(255,255,255,.8)">
          <button id="nav">Menu</button>
        </div>
        <div style="position:fixed;bottom:16px;right:16px;z-index:90;background:rgba(20,20,20,.9)">
          <button id="undo">Undo</button>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Add Site") != nil)
        #expect(marks.first(labelled: "Menu") != nil)
        #expect(marks.first(labelled: "Undo") != nil)
    }

    @Test("a page that DECLARES its modal is still taken at its word")
    @MainActor
    func declaredModalWinsOverTheHeuristic() async throws {
        // An overlay-shaped wrapper enclosing BOTH the declared dialog and
        // the page. The heuristic must never get a vote here: picking the
        // wrapper would make the background part of "the modal" and undo
        // the W14 fix.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div style="position:fixed;inset:0;z-index:50;background:rgba(0,0,0,.5)">
          \(dashboardBackground)
          <div role="dialog" aria-modal="true"
               style="position:absolute;top:120px;left:120px;width:400px;height:300px;background:#fff">
            <button id="modal-add">Add Site</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.count(labelled: "Add Site") == 1)
        #expect(marks.first(labelled: "Refresh") == nil)
    }
}

// MARK: - W31a: page_text follows the same overlay rule

@Suite("Web mark probe — page_text scoping (W31a)", .serialized)
struct WebMarkProbePageTextTests {

    @Test("with no modal, page_text is the whole document")
    @MainActor
    func ordinaryPageText() async throws {
        let text = try await ProbeRunner.pageText("""
        <!doctype html><html><body style="margin:0">
        <h1>Dashboard</h1><p>Sites you have not published yet appear here.</p>
        <button>Add Site</button>
        </body></html>
        """)
        #expect(text.contains("Dashboard"))
        #expect(text.contains("Sites you have not published yet appear here."))
    }

    @Test("a declared modal scopes page_text to the dialog")
    @MainActor
    func declaredModalScopesText() async throws {
        // The W31 bug in one assertion: `expect{text_visible: "Background
        // copy"}` used to pass while a dialog covered it.
        let text = try await ProbeRunner.pageText("""
        <!doctype html><html><body style="margin:0">
        <h1>Dashboard</h1><p>Background copy nobody can read right now.</p>
        <div role="dialog" aria-modal="true"
             style="position:fixed;top:100px;left:100px;width:400px;height:300px;background:#fff">
          <h2>New site</h2><p>Name your site to continue.</p>
        </div>
        </body></html>
        """)
        #expect(text.contains("Name your site to continue."))
        #expect(!text.contains("Background copy nobody can read right now."))
        #expect(!text.contains("Dashboard"))
    }

    @Test("an undeclared confirm dialog scopes page_text too")
    @MainActor
    func overlayModalScopesText() async throws {
        let text = try await ProbeRunner.pageText(confirmDialogPage)
        #expect(text.contains("Delete this site?"))
        #expect(text.contains("This cannot be undone."))
        #expect(!text.contains("Background copy nobody can read right now."))
    }

    @Test("text painting ABOVE the modal is kept, exactly as its marks are")
    @MainActor
    func toastTextSurvives() async throws {
        let text = try await ProbeRunner.pageText("""
        <!doctype html><html><body style="margin:0">
        <h1>Dashboard</h1><p>Background copy.</p>
        <div role="dialog" aria-modal="true"
             style="position:fixed;top:100px;left:100px;width:400px;height:300px;z-index:10;background:#fff">
          <p>Dialog copy.</p>
        </div>
        <div style="position:fixed;top:8px;left:8px;z-index:99;background:#333">
          <p>Site deleted.</p>
        </div>
        </body></html>
        """)
        #expect(text.contains("Dialog copy."))
        #expect(text.contains("Site deleted."))
        #expect(!text.contains("Background copy."))
    }
}

// MARK: - W15: telling two nameless controls apart

@Suite("Web mark probe — synthesized label discriminators (W15)", .serialized)
struct WebMarkProbeSynthesizedDiscriminatorTests {

    @Test("two nameless controls of the same role get distinct labels")
    @MainActor
    func namelessControlsDoNotCollide() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button style="position:absolute;top:10px;left:10px;width:28px;height:28px"></button>
        <button style="position:absolute;top:80px;left:10px;width:28px;height:28px"></button>
        <button style="position:absolute;top:150px;left:10px;width:28px;height:28px"></button>
        </body></html>
        """)
        let synthesized = marks.filter { $0.source == "synthesized" }
        #expect(synthesized.count == 3)
        #expect(Set(synthesized.map(\.label)).count == 3, "two unlabelled buttons must not answer to one string")
        // The discriminator is the position in READING ORDER, so it reads
        // the way the table does.
        #expect(synthesized.map(\.label) == ["unlabelled button 1",
                                             "unlabelled button 2",
                                             "unlabelled button 3"])
    }

    @Test("a lone nameless control keeps the plain placeholder")
    @MainActor
    func loneNamelessControlIsNotNumbered() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <button style="width:28px;height:28px"></button>
        <button>Save</button>
        </body></html>
        """)
        #expect(marks.first { $0.source == "synthesized" }?.label == "unlabelled button")
    }

    @Test("a deliberate name on an ancestor becomes the discriminator")
    @MainActor
    func ancestorContextNamesTheControl() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div aria-label="alanwizemann.com row">
          <button style="width:28px;height:28px"></button>
        </div>
        <div data-testid="second-site-row">
          <button style="width:28px;height:28px"></button>
        </div>
        </body></html>
        """)
        let synthesized = marks.filter { $0.source == "synthesized" }
        #expect(synthesized.count == 2)
        #expect(synthesized.contains { $0.label == "unlabelled button (alanwizemann.com row)" })
        #expect(synthesized.contains { $0.label == "unlabelled button (second-site-row)" })
    }

    @Test("the discriminator never upgrades the provenance")
    @MainActor
    func provenanceStaysSynthesized() async throws {
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div aria-label="Toolbar">
          <button style="width:28px;height:28px"></button>
          <button style="width:28px;height:28px"></button>
        </div>
        </body></html>
        """)
        let synthesized = marks.filter { $0.label.hasPrefix(WebMarkProbe.synthesizedLabelPrefix) }
        #expect(synthesized.count == 2)
        #expect(synthesized.allSatisfy { $0.source == "synthesized" })
        // Same context AND same role: the ordinal is what separates them.
        #expect(Set(synthesized.map(\.label)).count == 2)
    }

    @Test("the same page produces the same labels twice — ids and names are stable")
    @MainActor
    func discriminatorIsDeterministic() async throws {
        let page = """
        <!doctype html><html><body style="margin:0">
        <div aria-label="Row A"><button style="width:28px;height:28px"></button></div>
        <button style="width:28px;height:28px"></button>
        <button style="width:28px;height:28px"></button>
        </body></html>
        """
        let first = try await ProbeRunner.run(page).labels()
        let second = try await ProbeRunner.run(page).labels()
        #expect(first == second)
    }
}

// MARK: - scroll_into_view's element registry

@Suite("Web mark probe — element registry", .serialized)
struct WebMarkProbeRegistryTests {

    @Test("the parked element list matches the returned marks one-for-one")
    @MainActor
    func registryMatchesMarks() async throws {
        let (marks, registry) = try await ProbeRunner.registryCount("""
        <!doctype html><html><body style="margin:0">
        <a href="/pricing">Pricing</a>
        <button>Sign in</button>
        <input aria-label="Email">
        <div inert><button>Never marked</button></div>
        </body></html>
        """)
        #expect(marks == 3)
        #expect(registry == marks, "scroll_into_view(id) resolves id → registry[id - 1]; the two must not drift")
    }
}

// MARK: - W31b: the shapes an audit said no fixture reached

/// Every fixture above writes its scrim as a literal `rgba()` with an
/// explicit positive `z-index` and a handful of nodes — which is to say,
/// none of them would have caught the ways this rule can quietly stop
/// working on a real page. These do.
@Suite("Web mark probe — undeclared modals, the awkward cases", .serialized)
struct WebMarkProbeOverlayModalEdgeTests {

    @Test("a scrim written in a CSS Color 4 space is still a scrim",
          arguments: ["color-mix(in oklab, #000 50%, transparent)",
                      "oklch(0 0 0 / 0.5)",
                      "color(srgb 0 0 0 / 0.5)",
                      "rgb(0 0 0 / 50%)"])
    @MainActor
    func modernColorNotationsDim(_ background: String) async throws {
        // Tailwind v4 compiles `bg-black/50` — the exact class in the rule's
        // own design note — to `color-mix(in oklab, …)`. A dimming test that
        // only understood `rgba()` would read every one of these as fully
        // transparent and turn the whole rule off on the stack that
        // motivated it, with no test the wiser.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <div style="position:fixed;inset:0;z-index:50;background:\(background);pointer-events:none">
          <div style="position:absolute;top:180px;left:250px;width:400px;height:220px;background:#fff;pointer-events:auto">
            <button>Delete site</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Delete site") != nil,
                "the dialog's own control must survive for \(background)")
        #expect(marks.first(labelled: "Add Site") == nil,
                "\(background) is a scrim; the page behind it is not actionable")
    }

    @Test("a hand-rolled modal with no z-index at all is still a modal")
    @MainActor
    func zIndexAutoOverlayIsAModal() async throws {
        // `position: fixed; inset: 0; background: rgba(0,0,0,.5)` stacked by
        // document order alone — the plainest modal in the wild, and one an
        // earlier draft of this rule rejected for not lifting itself.
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <div style="position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.5)">
          <div style="position:absolute;top:200px;left:250px;width:400px;height:200px;background:#fff">
            <button>Delete site</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Delete site") != nil)
        #expect(marks.first(labelled: "Add Site") == nil)
    }

    @Test("a decorative backdrop-filter layer is not a modal")
    @MainActor
    func backdropFilterAloneIsNotAModal() async throws {
        // Glassmorphism: a full-viewport blur behind a scrolling article,
        // with a fixed table-of-contents card in it. It blurs; it does not
        // block. Treating it as a modal would delete the article.
        let page = """
        <!doctype html><html><body style="margin:0">
        <h1>An article</h1>
        <p>Sites you have not published yet appear here.</p>
        <div style="position:fixed;inset:0;z-index:1;backdrop-filter:blur(12px);pointer-events:none">
          <div style="position:absolute;top:220px;left:340px;width:220px;height:260px;background:#fff;pointer-events:auto">
            <a href="/section-1">Section one</a>
          </div>
        </div>
        </body></html>
        """
        let text = try await ProbeRunner.pageText(page)
        #expect(text.contains("Sites you have not published yet appear here."))
        #expect(text.contains("An article"))
    }

    @Test("an edge-pinned card in a tinted layer is not a dialog")
    @MainActor
    func edgePinnedCardIsNotADialog() async throws {
        // Same translucent full-viewport shape, but the card is a rail down
        // the left edge — a table of contents, a cookie bar, a hero CTA.
        // A dialog sits in the middle of the frame; these do not.
        let page = """
        <!doctype html><html><body style="margin:0">
        <h1>An article</h1>
        <p>Sites you have not published yet appear here.</p>
        <div style="position:fixed;inset:0;z-index:5;background:rgba(0,0,0,.3);pointer-events:none">
          <div style="position:absolute;top:8px;left:4px;width:140px;height:600px;background:#fff;pointer-events:auto">
            <a href="/section-1">Section one</a>
          </div>
        </div>
        </body></html>
        """
        let text = try await ProbeRunner.pageText(page)
        #expect(text.contains("Sites you have not published yet appear here."))
    }

    @Test("a portal at the end of a large document is still found")
    @MainActor
    func largeDocumentDoesNotExhaustTheScan() async throws {
        // React portals mount at the END of <body>. A scan budget that
        // counted every node would run out partway through a long table and
        // never reach the dialog — turning the rule off on exactly the pages
        // where a wrong page_text costs the most.
        let filler = (0..<4000).map { "<span>row \($0)</span>" }.joined()
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        \(dashboardBackground)
        <div style="height:40px;overflow:hidden">\(filler)</div>
        <div style="position:fixed;inset:0;z-index:50;background:rgba(0,0,0,.5);pointer-events:none">
          <div style="position:absolute;top:180px;left:250px;width:400px;height:220px;background:#fff;pointer-events:auto">
            <button>Delete site</button>
          </div>
        </div>
        </body></html>
        """)
        #expect(marks.first(labelled: "Delete site") != nil)
        #expect(marks.first(labelled: "Add Site") == nil,
                "the portal is the LAST thing in the document; the scan has to reach it")
    }
}

// MARK: - W15: the discriminator and the length cap

@Suite("Web mark probe — synthesized labels stay within the cap", .serialized)
struct WebMarkProbeSynthesizedCapTests {

    @Test("an ordinal never lands after a truncating ellipsis")
    @MainActor
    func ordinalAppliedBeforeTheCap() async throws {
        let context = String(repeating: "long-row-context-", count: 8)
        let marks = try await ProbeRunner.run("""
        <!doctype html><html><body style="margin:0">
        <div aria-label="\(context)">
          <button style="width:28px;height:28px"></button>
          <button style="width:28px;height:28px"></button>
        </div>
        </body></html>
        """)
        let synthesized = marks.filter { $0.source == "synthesized" }
        #expect(synthesized.count == 2)
        #expect(Set(synthesized.map(\.label)).count == 2)
        for mark in synthesized {
            #expect(mark.label.count <= 80, "label ran past the cap: \(mark.label)")
            #expect(!mark.label.hasSuffix("…") || mark.label.count <= 80)
            // The ordinal is what disambiguates; it must not be the thing
            // truncation eats.
            #expect(mark.label.last?.isNumber == true, "the ordinal was truncated away: \(mark.label)")
        }
    }
}
