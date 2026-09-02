//
//  WebValueEntryTests.swift
//  HarnessTests
//
//  WB-27. Exercises the two JS builders the WebDriver evaluates for value
//  entry — `WebMarkProbe.setValueJS` and `WebMarkProbe.typeJS` — against
//  fixture pages in a live WKWebView, the SAME source the driver runs. The
//  point of the ticket was a field a synthetic-keystroke `type` cannot land
//  (a datetime-local with a controlled onChange); these tests replicate that
//  failure first, then prove `set_value` lands it and that `type` now flags
//  its own no-op instead of reporting a clean success.
//

import Testing
import Foundation
import WebKit
@testable import Harness

private enum ValueRunner {

    /// Load `html` into an offscreen WKWebView, settled for layout.
    @MainActor
    static func load(_ html: String) async throws -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                                configuration: WKWebViewConfiguration())
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://harness.test/"))
        try await delegate.wait()
        try await Task.sleep(nanoseconds: 120_000_000)
        return webView
    }

    /// Run the shipped mark probe so `window.__harnessMarkElements` is parked
    /// exactly as it is before a real capture, then run `set_value(id,value)`
    /// against it and return the JS result dictionary.
    @MainActor
    static func setValue(_ webView: WKWebView, id: Int, value: String) async throws -> [String: Any] {
        _ = try await webView.evaluateJavaScript(WebMarkProbe.js)
        let out = try await webView.evaluateJavaScript(WebMarkProbe.setValueJS(id: id, value: value))
        return (out as? [String: Any]) ?? [:]
    }

    /// Focus `elementID`, then run `type(text)` in the SAME evaluation so
    /// `document.activeElement` is guaranteed set, and return the result.
    @MainActor
    static func type(_ webView: WKWebView, focus elementID: String, text: String) async throws -> [String: Any] {
        let js = "document.getElementById('\(elementID)').focus();\n" + WebMarkProbe.typeJS(text: text)
        let out = try await webView.evaluateJavaScript(js)
        return (out as? [String: Any]) ?? [:]
    }

    /// Read an element's current `.value` (or textContent) for assertions.
    @MainActor
    static func value(_ webView: WKWebView, of elementID: String) async throws -> String {
        let out = try await webView.evaluateJavaScript(
            "(() => { const e = document.getElementById('\(elementID)'); return ('value' in e) ? e.value : e.textContent; })();"
        )
        return (out as? String) ?? ""
    }

    @MainActor
    final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        func wait() async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true; continuation?.resume(); continuation = nil
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
    }
}

// MARK: - set_value on native date/select fields

@Suite struct WebSetValueTests {

    @Test("set_value lands an ISO value on a datetime-local input and it sticks")
    @MainActor
    func datetimeLocalSticks() async throws {
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0">
        <input id="dt" type="datetime-local">
        </body></html>
        """)
        let r = try await ValueRunner.setValue(webView, id: 1, value: "2026-09-10T15:00")
        #expect(r["status"] as? String == "ok")
        #expect(r["stuck"] as? Bool == true)
        #expect(r["after"] as? String == "2026-09-10T15:00")
        // And the DOM really holds it (not just the read-back).
        #expect(try await ValueRunner.value(webView, of: "dt") == "2026-09-10T15:00")
    }

    @Test("set_value on a select matches by option value and by visible label")
    @MainActor
    func selectByValueAndLabel() async throws {
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0">
        <select id="sel"><option value="a">Apple</option><option value="b">Banana</option></select>
        </body></html>
        """)
        let byValue = try await ValueRunner.setValue(webView, id: 1, value: "b")
        #expect(byValue["status"] as? String == "ok")
        #expect(byValue["stuck"] as? Bool == true)
        #expect(try await ValueRunner.value(webView, of: "sel") == "b")

        let byLabel = try await ValueRunner.setValue(webView, id: 1, value: "Apple")
        #expect(byLabel["status"] as? String == "ok")
        #expect(byLabel["expected"] as? String == "a")   // resolved label → option value
        #expect(try await ValueRunner.value(webView, of: "sel") == "a")
    }

    @Test("set_value reports the value did not stick when the field rejects the format")
    @MainActor
    func rejectedFormatNotStuck() async throws {
        // A date input silently drops a value it can't parse; the read-back
        // is the only honest signal, and set_value surfaces it.
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0">
        <input id="d" type="date">
        </body></html>
        """)
        let r = try await ValueRunner.setValue(webView, id: 1, value: "not-a-date")
        #expect(r["status"] as? String == "ok")
        #expect(r["stuck"] as? Bool == false)
        #expect((r["after"] as? String)?.isEmpty == true)
    }

    @Test("set_value on a non-settable element (a link) is an honest failure, not a fake success")
    @MainActor
    func nonSettableElement() async throws {
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0">
        <a id="lnk" href="/next">Continue</a>
        </body></html>
        """)
        let r = try await ValueRunner.setValue(webView, id: 1, value: "x")
        #expect(r["status"] as? String == "not-settable")
    }

    @Test("set_value on a stale id (no registry) reports stale, never sets something else")
    @MainActor
    func staleWithoutRegistry() async throws {
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0"><input id="x" type="text"></body></html>
        """)
        // Do NOT run the mark probe first, so the registry is absent.
        let out = try await webView.evaluateJavaScript(WebMarkProbe.setValueJS(id: 1, value: "hi"))
        let r = (out as? [String: Any]) ?? [:]
        #expect(r["status"] as? String == "no-registry")
    }
}

// MARK: - set_value defeats a controlled (React value-tracker) revert

@Suite struct WebControlledInputTests {

    /// A faithful stand-in for a React-controlled input: an instance-level
    /// `value` setter that updates a "value tracker", plus an input listener
    /// that reverts to committed state whenever the tracker already matches
    /// the DOM (which is exactly what happens after a naive `el.value = …`),
    /// and commits when it does not (a native-prototype-setter change, the
    /// technique Playwright's fill and our set_value use).
    private static let controlledFixture = """
    <!doctype html><html><body style="margin:0">
    <input id="ct" type="text" value="">
    <script>
      (() => {
        const el = document.getElementById('ct');
        const proto = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        let tracked = proto.get.call(el);
        let state = proto.get.call(el);
        Object.defineProperty(el, 'value', {
          configurable: true,
          get() { return proto.get.call(this); },
          set(v) { tracked = v; proto.set.call(this, v); }
        });
        el.addEventListener('input', function () {
          const dom = proto.get.call(el);
          if (tracked === dom) { proto.set.call(el, state); tracked = state; }
          else { state = dom; tracked = dom; }
        });
      })();
    </script>
    </body></html>
    """

    @Test("a naive value assignment is reverted by the controlled input (the W36 failure)")
    @MainActor
    func naiveAssignmentReverts() async throws {
        let webView = try await ValueRunner.load(Self.controlledFixture)
        // The framework-naive fill: assign through the (overridden) instance
        // setter, then fire input. The listener reverts it.
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const el = document.getElementById('ct');
          el.value = 'hello';
          el.dispatchEvent(new Event('input', { bubbles: true }));
          return el.value;
        })();
        """)
        #expect(try await ValueRunner.value(webView, of: "ct") == "",
                "the controlled input must revert a naive assignment, or the fixture proves nothing")
    }

    @Test("set_value defeats the controlled revert and the value sticks")
    @MainActor
    func setValueSticks() async throws {
        let webView = try await ValueRunner.load(Self.controlledFixture)
        let r = try await ValueRunner.setValue(webView, id: 1, value: "hello")
        #expect(r["status"] as? String == "ok")
        #expect(r["stuck"] as? Bool == true)
        #expect(try await ValueRunner.value(webView, of: "ct") == "hello")
    }
}

// MARK: - type() no-op detection

@Suite struct WebTypeNoOpTests {

    @Test("type reports had:false when nothing is focused")
    @MainActor
    func noFocusedField() async throws {
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0"><p>nothing to type into</p></body></html>
        """)
        let out = try await webView.evaluateJavaScript(WebMarkProbe.typeJS(text: "hello"))
        let r = (out as? [String: Any]) ?? [:]
        #expect(r["had"] as? Bool == false)
    }

    @Test("type reports changed:false when the field reverts the insert synchronously")
    @MainActor
    func synchronousRevertFlagsNoOp() async throws {
        // A field that clears itself on every input — the deterministic
        // stand-in for a control that ignores synthetic keystrokes. type()
        // must NOT report this as a clean type.
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0">
        <input id="rev" type="text" oninput="this.value=''">
        </body></html>
        """)
        let r = try await ValueRunner.type(webView, focus: "rev", text: "hello")
        #expect(r["had"] as? Bool == true)
        #expect(r["changed"] as? Bool == false)
    }

    @Test("type still reports changed:true on an ordinary field, and no longer throws on a date input")
    @MainActor
    func ordinaryAndDateFields() async throws {
        // The date input is the regression guard: reading selectionStart on
        // it throws InvalidStateError, which used to abort the whole type.
        let webView = try await ValueRunner.load("""
        <!doctype html><html><body style="margin:0">
        <input id="txt" type="text">
        <input id="d" type="date">
        </body></html>
        """)
        let ordinary = try await ValueRunner.type(webView, focus: "txt", text: "Berlin")
        #expect(ordinary["had"] as? Bool == true)
        #expect(ordinary["changed"] as? Bool == true)
        #expect(try await ValueRunner.value(webView, of: "txt") == "Berlin")

        let date = try await ValueRunner.type(webView, focus: "d", text: "2026-09-10")
        #expect(date["had"] as? Bool == true)
        #expect(date["changed"] as? Bool == true)   // did not throw; value landed
        #expect(try await ValueRunner.value(webView, of: "d") == "2026-09-10")
    }
}
