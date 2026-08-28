//
//  WebSessionStateTests.swift
//  HarnessTests
//
//  The `session_state` value type: parsing the MCP argument, the
//  export/inject round-trip (an export must be re-injectable verbatim), the
//  cookie → `HTTPCookie` mapping, and — the point of the whole file — that
//  NO description, summary, or error message ever renders a cookie value.
//

import Testing
import Foundation
@testable import Harness

@Suite("WebSessionState — parsing")
struct WebSessionStateParsingTests {

    @Test("parses cookies with defaults for the optional fields")
    func minimalCookie() throws {
        let state = try WebSessionState.parse([
            "cookies": [["name": "sid", "value": "abc123", "domain": ".example.com"]]
        ])
        #expect(state.cookies.count == 1)
        let c = try #require(state.cookies.first)
        #expect(c.name == "sid")
        #expect(c.value == "abc123")
        #expect(c.domain == ".example.com")
        #expect(c.path == "/")
        #expect(c.expires == nil)
        #expect(!c.secure)
        #expect(!c.httpOnly)
    }

    @Test("parses every optional cookie field, expiry in epoch seconds")
    func fullCookie() throws {
        let state = try WebSessionState.parse([
            "cookies": [[
                "name": "sid", "value": "v", "domain": "example.com", "path": "/app",
                "expires": 1_800_000_000, "secure": true, "httpOnly": true
            ]]
        ])
        let c = try #require(state.cookies.first)
        #expect(c.path == "/app")
        #expect(c.expires == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(c.secure)
        #expect(c.httpOnly)
    }

    @Test("parses origins + localStorage")
    func origins() throws {
        let state = try WebSessionState.parse([
            "origins": [[
                "origin": "https://app.example.com",
                "localStorage": [["name": "token", "value": "t0k"], ["name": "theme", "value": "dark"]]
            ]]
        ])
        #expect(state.origins.count == 1)
        #expect(state.origins[0].origin == "https://app.example.com")
        #expect(state.origins[0].localStorage.map(\.name) == ["token", "theme"])
    }

    @Test("an empty object parses to an empty (no-op) state")
    func emptyState() throws {
        let state = try WebSessionState.parse([String: Any]())
        #expect(state.isEmpty)
    }

    @Test("a non-object, a bad cookie, and a bad storage item are all rejected")
    func rejections() {
        #expect(throws: WebSessionStateError.self) { try WebSessionState.parse("nope") }
        #expect(throws: WebSessionStateError.self) {
            try WebSessionState.parse(["cookies": [["value": "v", "domain": "d"]]])   // no name
        }
        #expect(throws: WebSessionStateError.self) {
            try WebSessionState.parse(["cookies": [["name": "n", "domain": "d"]]])    // no value
        }
        #expect(throws: WebSessionStateError.self) {
            try WebSessionState.parse(["cookies": [["name": "n", "value": "v"]]])     // no domain
        }
        #expect(throws: WebSessionStateError.self) {
            try WebSessionState.parse(["origins": [["localStorage": []]]])            // no origin
        }
        #expect(throws: WebSessionStateError.self) {
            try WebSessionState.parse([
                "origins": [["origin": "https://x", "localStorage": [["name": "k"]]]] // no value
            ])
        }
    }

    @Test("a numeric 'secure' is not read as a boolean (MCPArguments' rule)")
    func numberIsNotBool() throws {
        let state = try WebSessionState.parse([
            "cookies": [["name": "n", "value": "v", "domain": "d", "secure": 1]]
        ])
        #expect(state.cookies[0].secure == false)
    }

    @Test("a boolean 'expires' is ignored rather than read as 1970+1s")
    func boolIsNotExpiry() throws {
        let state = try WebSessionState.parse([
            "cookies": [["name": "n", "value": "v", "domain": "d", "expires": true]]
        ])
        #expect(state.cookies[0].expires == nil)
    }
}

@Suite("WebSessionState — secret handling")
struct WebSessionStateRedactionTests {

    private static let secret = "SUPER-SECRET-SESSION-TOKEN"

    private static func state() -> WebSessionState {
        WebSessionState(
            cookies: [WebSessionCookie(name: "sid", value: secret, domain: ".example.com")],
            origins: [WebSessionOriginState(
                origin: "https://example.com",
                localStorage: [WebSessionStorageItem(name: "auth", value: secret)]
            )]
        )
    }

    @Test("no description of any state type contains a value")
    func descriptionsAreRedacted() {
        let s = Self.state()
        #expect(!"\(s)".contains(Self.secret))
        #expect(!s.redactedSummary.contains(Self.secret))
        for c in s.cookies { #expect(!"\(c)".contains(Self.secret)) }
        for o in s.origins {
            #expect(!"\(o)".contains(Self.secret))
            for i in o.localStorage { #expect(!"\(i)".contains(Self.secret)) }
        }
    }

    @Test("the redacted summary reports counts, and names nothing sensitive")
    func summaryCounts() {
        let summary = Self.state().redactedSummary
        #expect(summary.contains("1 cookie(s)"))
        #expect(summary.contains("1 origin(s)"))
        #expect(summary.contains("redacted"))
    }

    @Test("parse errors name the field and index, never the value")
    func parseErrorsAreRedacted() {
        do {
            _ = try WebSessionState.parse(["cookies": [["name": "sid", "value": Self.secret]]])
            Issue.record("expected a throw")
        } catch {
            let message = error.localizedDescription
            #expect(!message.contains(Self.secret))
            #expect(message.contains("domain"))
            #expect(message.contains("[0]"))
        }
    }

    @Test("exportJSON is the ONE place values are rendered — and it round-trips")
    func exportRoundTrip() throws {
        let original = Self.state()
        let json = original.exportJSON()
        // It does carry the values (that is the tool's entire purpose)…
        #expect("\(json)".contains(Self.secret))
        // …and re-parses into exactly the same state, so an export can be
        // handed straight back as `session_state` with no transformation.
        let reparsed = try WebSessionState.parse(json)
        #expect(reparsed.cookies == original.cookies)
        #expect(reparsed.origins == original.origins)
    }

    @Test("exportJSON survives JSONSerialization (the MCP result path)")
    func exportIsSerializable() throws {
        var json = WebSessionState(
            cookies: [WebSessionCookie(name: "sid", value: "v", domain: "d",
                                       expires: Date(timeIntervalSince1970: 1_800_000_000),
                                       secure: true, httpOnly: true)]
        ).exportJSON()
        json["session_id"] = UUID().uuidString
        #expect(JSONSerialization.isValidJSONObject(json))
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reparsed = try WebSessionState.parse(back)
        #expect(reparsed.cookies.first?.expires == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(reparsed.cookies.first?.httpOnly == true)
    }
}

@Suite("WebSessionState — HTTPCookie mapping")
@MainActor
struct WebSessionCookieMappingTests {

    @Test("a full cookie maps onto HTTPCookie with every attribute preserved")
    func fullMapping() throws {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let cookie = WebSessionCookie(name: "sid", value: "v", domain: "example.com",
                                      path: "/app", expires: expires, secure: true, httpOnly: true)
        let http = try #require(WebSessionStateIO.httpCookie(from: cookie))
        #expect(http.name == "sid")
        #expect(http.value == "v")
        #expect(http.path == "/app")
        #expect(http.isSecure)
        #expect(http.isHTTPOnly)
        #expect(http.expiresDate == expires)
    }

    @Test("an empty path becomes \"/\" rather than an invalid cookie")
    func emptyPathDefaults() throws {
        let http = try #require(WebSessionStateIO.httpCookie(
            from: WebSessionCookie(name: "n", value: "v", domain: "example.com", path: "")
        ))
        #expect(http.path == "/")
    }

    @Test("a cookie the platform rejects maps to nil, not to a guess")
    func rejectedCookie() {
        #expect(WebSessionStateIO.httpCookie(
            from: WebSessionCookie(name: "n", value: "v", domain: "")
        ) == nil)
    }
}
