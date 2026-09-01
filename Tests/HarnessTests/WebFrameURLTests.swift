//
//  WebFrameURLTests.swift
//  HarnessTests
//
//  `WebDriver.redactedFrameURL` — the single place a live frame's location
//  is reduced before it can reach an MCP result or a log line (WB-17).
//
//  The rule under test: keep scheme + host + port + path; DROP userinfo,
//  query and fragment, marking that a query/fragment existed. These tests
//  are written as leak checks — each one names a secret and asserts the
//  output cannot contain it — because that is the failure that matters. A
//  magic-link token in `?token=…` reaching a transcript is not a cosmetic
//  bug.
//

import Testing
import Foundation
@testable import Harness

@Suite("Web frame URL — redaction")
struct WebFrameURLRedactionTests {

    private static let secret = "TOKEN-THAT-MUST-NEVER-BE-ECHOED-8812"

    @Test("origin and path survive; the query is dropped and flagged")
    func queryDropped() {
        let out = WebDriver.redactedFrameURL(
            "https://drop-help.com/dashboard?token=\(Self.secret)&next=/sites"
        )
        #expect(out == "https://drop-help.com/dashboard?…")
        #expect(out?.contains(Self.secret) == false)
        #expect(out?.contains("next") == false)
    }

    @Test("a fragment is dropped and flagged separately from a query")
    func fragmentDropped() {
        #expect(WebDriver.redactedFrameURL("https://x.test/a#access_token=\(Self.secret)")
                == "https://x.test/a#…")
        #expect(WebDriver.redactedFrameURL("https://x.test/a?q=1#f") == "https://x.test/a?…#…")
        #expect(WebDriver.redactedFrameURL("https://x.test/a") == "https://x.test/a")
    }

    @Test("userinfo never survives — a password in the authority is still a password")
    func userinfoDropped() {
        let out = WebDriver.redactedFrameURL("https://alan:\(Self.secret)@intranet.test/reports")
        #expect(out == "https://intranet.test/reports")
        #expect(out?.contains(Self.secret) == false)
        #expect(out?.contains("alan") == false)
    }

    @Test("a non-default port is kept — it is part of the origin a guard compares")
    func portKept() {
        #expect(WebDriver.redactedFrameURL("http://127.0.0.1:8123/fixture.html")
                == "http://127.0.0.1:8123/fixture.html")
    }

    @Test("an IPv6 literal stays parseable — the port must not run into the address")
    func ipv6HostBracketed() {
        #expect(WebDriver.redactedFrameURL("http://[::1]:8080/app") == "http://[::1]:8080/app")
    }

    @Test("a scheme-relative or scheme-less string is not a location")
    func schemelessRejected() {
        #expect(WebDriver.redactedFrameURL("//evil.test/steal") == nil)
        #expect(WebDriver.redactedFrameURL("/just/a/path") == nil)
    }

    @Test("a javascript: URL never carries its source out")
    func javascriptSchemeCollapses() {
        let out = WebDriver.redactedFrameURL("javascript:alert(document.cookie)")
        #expect(out == "javascript:…")
        #expect(out?.contains("cookie") == false)
    }

    @Test("a document-bearing scheme collapses to its scheme")
    func opaqueSchemesCollapse() {
        #expect(WebDriver.redactedFrameURL("data:text/html,<h1>\(Self.secret)</h1>") == "data:…")
        #expect(WebDriver.redactedFrameURL("blob:https://x.test/9f2")?.hasPrefix("blob:") == true)
        #expect(WebDriver.redactedFrameURL("data:text/html,x")?.contains("<h1>") == false)
    }

    @Test("about:blank stays readable; file paths keep their path")
    func aboutAndFile() {
        #expect(WebDriver.redactedFrameURL("about:blank") == "about:blank")
        #expect(WebDriver.redactedFrameURL("file:///tmp/fixture.html") == "file:///tmp/fixture.html")
    }

    @Test("nothing in, nothing out — never an empty string masquerading as a URL")
    func emptyInputs() {
        #expect(WebDriver.redactedFrameURL(nil) == nil)
        #expect(WebDriver.redactedFrameURL("") == nil)
        #expect(WebDriver.redactedFrameURL("not a url at all") == nil)
    }
}
