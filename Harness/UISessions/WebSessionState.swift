//
//  WebSessionState.swift
//  Harness
//
//  Cookie + localStorage state for a **web** UI session: the value type
//  behind `start_ui_session(session_state:)` and `export_ui_session_state`.
//
//  WHY this exists. Web UI sessions run on a NON-PERSISTENT
//  `WKWebsiteDataStore` — every session is a fresh user (see the long
//  rationale in `WebViewWindowController`). That invariant is deliberate and
//  stays the default. But a QA client driving a real product hits a wall at
//  the login screen of an SSO-only app: there is no password to type, and no
//  persistent profile to inherit. The escape hatch is to let a HUMAN log in
//  once in a VISIBLE session, export the resulting cookies + localStorage,
//  and inject them into later headless sessions — into a data store that is
//  still non-persistent, so nothing is written to disk and nothing leaks into
//  the next session that didn't ask for it.
//
//  **SECRET HANDLING — the rule this file exists to enforce.** A session
//  cookie IS a credential: whoever holds it is logged in. So cookie and
//  localStorage VALUES:
//
//    - never appear in `os.Logger` output (only counts / names),
//    - never appear in `steps.jsonl` (the artifact writer records tool
//      names + inputs for `act_ui`; `session_state` rides on
//      `start_ui_session`, which writes no row at all),
//    - never appear in a tool RESULT except the single tool whose entire
//      job is to return them (`export_ui_session_state`),
//    - never reach disk.
//
//  The types below have no `CustomStringConvertible` that prints a value,
//  and `description` is deliberately overridden to a redacted form so an
//  accidental string interpolation in some future log line cannot leak one.
//  This mirrors the `fill_credential` precedent: the password exists in the
//  process, is used, and is never rendered.
//

import Foundation

// MARK: - Values

/// One cookie to inject into (or exported from) a web session's cookie store.
///
/// `value` is a SECRET. Never log or serialize it outside
/// `export_ui_session_state`'s result.
struct WebSessionCookie: Sendable, Hashable, CustomStringConvertible {
    let name: String
    let value: String
    let domain: String
    let path: String
    /// Absolute expiry. `nil` → a session cookie (cleared when the store dies,
    /// which for a non-persistent store is at session teardown).
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool

    init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date? = nil,
        secure: Bool = false,
        httpOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path.isEmpty ? "/" : path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }

    /// Redacted by construction — interpolating a cookie into a log line
    /// prints the NAME and the value's LENGTH, never the value.
    var description: String {
        "WebSessionCookie(name: \(name), domain: \(domain), value: <redacted \(value.count) chars>)"
    }
}

/// One `localStorage` entry for an origin. `value` is treated as a secret for
/// the same reason cookies are — SPAs routinely park bearer tokens here.
struct WebSessionStorageItem: Sendable, Hashable, CustomStringConvertible {
    let name: String
    let value: String

    var description: String {
        "WebSessionStorageItem(name: \(name), value: <redacted \(value.count) chars>)"
    }
}

/// The `localStorage` contents for one origin (scheme + host + port, no path).
struct WebSessionOriginState: Sendable, Hashable, CustomStringConvertible {
    let origin: String
    let localStorage: [WebSessionStorageItem]

    var description: String {
        "WebSessionOriginState(origin: \(origin), localStorage: \(localStorage.count) items <redacted>)"
    }
}

/// A whole web session's injectable / exportable state.
struct WebSessionState: Sendable, Hashable, CustomStringConvertible {
    var cookies: [WebSessionCookie]
    var origins: [WebSessionOriginState]

    init(cookies: [WebSessionCookie] = [], origins: [WebSessionOriginState] = []) {
        self.cookies = cookies
        self.origins = origins
    }

    var isEmpty: Bool { cookies.isEmpty && origins.isEmpty }

    /// The ONLY form of this value that is safe to log: counts, never content.
    /// Used verbatim by the supervisor / adapter log lines.
    var redactedSummary: String {
        let items = origins.reduce(0) { $0 + $1.localStorage.count }
        return "\(cookies.count) cookie(s), \(origins.count) origin(s) / \(items) localStorage item(s) — values redacted"
    }

    var description: String { "WebSessionState(\(redactedSummary))" }
}

// MARK: - Parsing (MCP `session_state` argument)

enum WebSessionStateError: Error, Sendable, LocalizedError {
    case notAnObject
    case cookieNotAnObject(Int)
    case cookieMissingField(Int, String)
    case originNotAnObject(Int)
    case originMissingField(Int, String)
    case storageItemInvalid(Int, Int)
    case unsupportedPlatform(String)

    var errorDescription: String? {
        switch self {
        case .notAnObject:
            return "session_state must be an object: { \"cookies\": [...], \"origins\": [...] }."
        case .cookieNotAnObject(let i):
            return "session_state.cookies[\(i)] must be an object with name, value, and domain."
        case .cookieMissingField(let i, let field):
            return "session_state.cookies[\(i)] is missing required field '\(field)'."
        case .originNotAnObject(let i):
            return "session_state.origins[\(i)] must be an object with origin and localStorage."
        case .originMissingField(let i, let field):
            return "session_state.origins[\(i)] is missing required field '\(field)'."
        case .storageItemInvalid(let o, let i):
            return "session_state.origins[\(o)].localStorage[\(i)] must be an object with string 'name' and 'value'."
        case .unsupportedPlatform(let platform):
            return "session_state / export_ui_session_state apply to web sessions only (this session is \(platform)). iOS and macOS sessions drive a real app, which has no cookie jar to seed."
        }
    }
}

extension WebSessionState {

    /// Parse the MCP `session_state` argument.
    ///
    /// Errors name the offending index and field — never the value, so a
    /// malformed cookie can't leak its secret through an error message that
    /// gets logged upstream.
    ///
    /// `expires` accepts seconds since epoch (the Playwright/CDP convention,
    /// which is what a client scraping a browser profile will already have).
    static func parse(_ any: Any) throws -> WebSessionState {
        guard let obj = any as? [String: Any] else { throw WebSessionStateError.notAnObject }

        var cookies: [WebSessionCookie] = []
        for (i, raw) in ((obj["cookies"] as? [Any]) ?? []).enumerated() {
            guard let c = raw as? [String: Any] else { throw WebSessionStateError.cookieNotAnObject(i) }
            guard let name = c["name"] as? String, !name.isEmpty else {
                throw WebSessionStateError.cookieMissingField(i, "name")
            }
            guard let value = c["value"] as? String else {
                throw WebSessionStateError.cookieMissingField(i, "value")
            }
            guard let domain = c["domain"] as? String, !domain.isEmpty else {
                throw WebSessionStateError.cookieMissingField(i, "domain")
            }
            let expires: Date? = {
                guard let n = c["expires"] as? NSNumber,
                      CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
                let seconds = n.doubleValue
                guard seconds > 0, seconds.isFinite else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }()
            cookies.append(WebSessionCookie(
                name: name,
                value: value,
                domain: domain,
                path: (c["path"] as? String) ?? "/",
                expires: expires,
                secure: boolValue(c["secure"]) ?? false,
                httpOnly: boolValue(c["httpOnly"]) ?? false
            ))
        }

        var origins: [WebSessionOriginState] = []
        for (i, raw) in ((obj["origins"] as? [Any]) ?? []).enumerated() {
            guard let o = raw as? [String: Any] else { throw WebSessionStateError.originNotAnObject(i) }
            guard let origin = o["origin"] as? String, !origin.isEmpty else {
                throw WebSessionStateError.originMissingField(i, "origin")
            }
            var items: [WebSessionStorageItem] = []
            for (j, rawItem) in ((o["localStorage"] as? [Any]) ?? []).enumerated() {
                guard let item = rawItem as? [String: Any],
                      let name = item["name"] as? String, !name.isEmpty,
                      let value = item["value"] as? String else {
                    throw WebSessionStateError.storageItemInvalid(i, j)
                }
                items.append(WebSessionStorageItem(name: name, value: value))
            }
            origins.append(WebSessionOriginState(origin: origin, localStorage: items))
        }

        return WebSessionState(cookies: cookies, origins: origins)
    }

    /// Only a genuine JSON boolean counts — a number must not be read as one
    /// (same rule `MCPArguments.bool` follows).
    private static func boolValue(_ any: Any?) -> Bool? {
        guard let n = any as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// The wire shape `export_ui_session_state` returns — the SAME shape
    /// `session_state` accepts, so an export round-trips into an injection
    /// with no client-side transformation.
    ///
    /// This is the one and only place cookie values are rendered. The result
    /// goes straight into the MCP tool result and is never logged or written.
    func exportJSON() -> [String: Any] {
        [
            "cookies": cookies.map { c -> [String: Any] in
                var out: [String: Any] = [
                    "name": c.name,
                    "value": c.value,
                    "domain": c.domain,
                    "path": c.path,
                    "secure": c.secure,
                    "httpOnly": c.httpOnly
                ]
                if let e = c.expires { out["expires"] = e.timeIntervalSince1970 }
                return out
            },
            "origins": origins.map { o -> [String: Any] in
                [
                    "origin": o.origin,
                    "localStorage": o.localStorage.map { ["name": $0.name, "value": $0.value] }
                ]
            }
        ]
    }
}
