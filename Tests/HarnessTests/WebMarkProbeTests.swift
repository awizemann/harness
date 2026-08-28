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
