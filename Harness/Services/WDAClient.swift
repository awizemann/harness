//
//  WDAClient.swift
//  Harness
//
//  Pure-URLSession HTTP client for WebDriverAgent's W3C / WDA-native
//  endpoints. Coordinates are device points (the same space `idb tap` used);
//  the on-screen overlay and the responder chain agree because WDA goes
//  through `XCUICoordinate.tap` etc., not raw HID injection.
//
//  Phase D of the idb→WDA migration. Pairs with WDARunner (which keeps the
//  WDA xctest process alive on the simulator) and SimulatorDriver (which
//  routes `tap`/`swipe`/`type`/`pressButton` calls through this client).
//

import Foundation
import os

// MARK: - Errors

enum WDAClientError: Error, Sendable, LocalizedError {
    case noSession
    case notReady(timeout: Duration)
    case malformedResponse(detail: String)
    case httpError(status: Int, body: String)
    case retryExhausted(detail: String)

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "WDA session has not been opened. Call `createSession()` first."
        case .notReady(let timeout):
            return "WebDriverAgent did not become ready within \(timeout)."
        case .malformedResponse(let detail):
            return "WDA returned an unexpected response: \(detail)"
        case .httpError(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "WDA HTTP \(status)."
                : "WDA HTTP \(status): \(trimmed)"
        case .retryExhausted(let detail):
            return "WDA request retries exhausted: \(detail)"
        }
    }
}

// MARK: - Session handle

struct WDASessionHandle: Sendable, Hashable {
    let id: String
    let port: Int
}

// MARK: - Protocol

protocol WDAClienting: Sendable {
    /// Poll `GET /status` until WDA returns 200 or `timeout` elapses.
    /// Throws `WDAClientError.notReady` on timeout.
    func waitForReady(timeout: Duration) async throws

    /// Open a session via `POST /session`. Stores the session id internally so
    /// subsequent input methods can target it.
    @discardableResult
    func createSession() async throws -> WDASessionHandle

    /// Close the currently-open session, if any. Idempotent.
    func endSession() async

    func tap(at point: CGPoint) async throws
    func doubleTap(at point: CGPoint) async throws
    func swipe(from: CGPoint, to: CGPoint, duration: Duration) async throws
    func type(_ text: String) async throws
    func pressButton(_ button: SimulatorButton) async throws

    /// Probe the AX tree for visible, enabled, actionable elements
    /// and return them as a numbered list of `InteractiveMark`s in
    /// reading order (top-to-bottom, then left-to-right). The 1-based
    /// `id` matches the badge text rendered onto the screenshot by
    /// `MarkRenderer.draw(...)`. Capped at 80 to keep the prompt
    /// scaffolding under control on dense screens.
    func probeInteractiveElements() async throws -> [InteractiveMark]
}

// MARK: - Implementation

actor WDAClient: WDAClienting {

    private static let logger = Logger(subsystem: "com.harness.app", category: "WDAClient")

    /// Default port WDA listens on inside the simulator.
    static let defaultPort: Int = 8100

    /// Connection-refused / dropped-connection retries during state transitions.
    private static let maxRetries = 3
    private static let backoff: Duration = .milliseconds(100)

    /// Per-request timeout. Anything that takes longer than 10s is broken,
    /// not slow.
    private static let requestTimeout: TimeInterval = 10

    /// Status-poll cadence.
    private static let statusPollInterval: Duration = .milliseconds(250)

    private let urlSession: URLSession
    private let port: Int
    private var sessionID: String?

    init(port: Int = WDAClient.defaultPort, urlSession: URLSession = .shared) {
        self.port = port
        self.urlSession = urlSession
    }

    // MARK: Lifecycle

    func waitForReady(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                _ = try await requestRaw(method: "GET", path: "/status", body: nil)
                return
            } catch {
                try? await Task.sleep(for: Self.statusPollInterval)
            }
        }
        throw WDAClientError.notReady(timeout: timeout)
    }

    @discardableResult
    func createSession() async throws -> WDASessionHandle {
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": [
                    "platformName": "iOS",
                    "appium:automationName": "XCUITest"
                ]
            ]
        ]
        let json = try await requestJSON(method: "POST", path: "/session", body: body)

        // WDA replies with `{ "value": { "sessionId": "...", ... } }`.
        // Accept the W3C shape (nested) and tolerate a flat response too.
        let sid: String? = {
            if let value = json["value"] as? [String: Any], let id = value["sessionId"] as? String {
                return id
            }
            return json["sessionId"] as? String
        }()
        guard let sid, !sid.isEmpty else {
            throw WDAClientError.malformedResponse(detail: "missing sessionId in createSession response")
        }
        sessionID = sid
        Self.logger.info("WDA session opened: \(sid, privacy: .public)")
        return WDASessionHandle(id: sid, port: port)
    }

    func endSession() async {
        guard let sid = sessionID else { return }
        sessionID = nil
        // Best-effort — if WDA already tore down, we don't care.
        _ = try? await requestJSON(method: "DELETE", path: "/session/\(sid)", body: nil)
        Self.logger.info("WDA session closed: \(sid, privacy: .public)")
    }

    // MARK: Input methods

    func tap(at point: CGPoint) async throws {
        let sid = try requireSessionID()
        _ = try await requestJSON(
            method: "POST",
            path: "/session/\(sid)/wda/tap",
            body: ["x": Double(point.x), "y": Double(point.y)]
        )
    }

    func doubleTap(at point: CGPoint) async throws {
        // WDA exposes `tapWithNumberOfTaps` on elements but not at coordinate
        // level. Emulate with two taps separated by ~80ms — same approach the
        // idb backend used.
        try await tap(at: point)
        try? await Task.sleep(for: .milliseconds(80))
        try await tap(at: point)
    }

    func swipe(from: CGPoint, to: CGPoint, duration: Duration) async throws {
        let sid = try requireSessionID()
        _ = try await requestJSON(
            method: "POST",
            path: "/session/\(sid)/wda/dragfromtoforduration",
            body: [
                "fromX": Double(from.x),
                "fromY": Double(from.y),
                "toX": Double(to.x),
                "toY": Double(to.y),
                "duration": Self.seconds(of: duration)
            ]
        )
    }

    func type(_ text: String) async throws {
        let sid = try requireSessionID()
        // WDA's /wda/keys takes `value: [String]` (one entry per character).
        // 60 chars/sec is the default typing cadence.
        _ = try await requestJSON(
            method: "POST",
            path: "/session/\(sid)/wda/keys",
            body: [
                "value": text.map { String($0) },
                "frequency": 60
            ]
        )
    }

    func pressButton(_ button: SimulatorButton) async throws {
        let sid = try requireSessionID()
        _ = try await requestJSON(
            method: "POST",
            path: "/session/\(sid)/wda/pressButton",
            body: ["name": button.rawValue]
        )
    }

    // MARK: Set-of-Mark probe

    /// WDA's `/source?format=json` returns the entire app's AX tree.
    /// The session-scoped path is preferred (returns the live tree
    /// for the running app), but if no session is open we fall back
    /// to the global `/source` which uses WDA's default session.
    ///
    /// Returns the parsed root JSON object (already unwrapped from
    /// the `{"value": ...}` envelope WDA wraps everything in).
    private func source() async throws -> [String: Any] {
        let path: String
        if let sid = sessionID {
            path = "/session/\(sid)/source?format=json"
        } else {
            path = "/source?format=json"
        }
        let json = try await requestJSON(method: "GET", path: path, body: nil)
        if let value = json["value"] as? [String: Any] {
            return value
        }
        return json
    }

    /// AX element types we treat as actionable. WDA 12.x's
    /// `/source?format=json` returns SHORT names (`Button`, `Cell`,
    /// `NavigationBar`, ...) — not the full `XCUIElementTypeButton`
    /// strings the headerdoc and online docs show. We accept BOTH
    /// forms to be forwards/backwards compatible across WDA versions.
    ///
    /// Subset of XCUI's full type vocabulary — picked for iOS UIs
    /// that real users navigate. Static text + plain Image are
    /// intentionally excluded (too many; mostly decorative) unless
    /// they're nested inside a Cell or Button, in which case the
    /// cell/button is what gets the mark.
    ///
    /// `NavigationBar` / `TabBar` / `Toolbar` are containers — when
    /// we hit one we recurse to mark its children (the actual
    /// back-button, tab-item, etc.) rather than marking the bar
    /// itself.
    private static let actionableIOSRolesShort: Set<String> = [
        "Button",
        "Link",
        "TextField",
        "SecureTextField",
        "SearchField",
        "TextView",
        "Switch",
        "Slider",
        "Stepper",
        "Cell",
        "MenuItem",
        "MenuButton",
        "SegmentedControl",
        "Tab",
        "Picker",
        "PickerWheel",
        "CheckBox",
        "RadioButton",
        "DatePicker",
        "Key"
    ]
    private static let actionableIOSRolesLong: Set<String> = Set(
        actionableIOSRolesShort.map { "XCUIElementType\($0)" }
    )

    private static let iosContainerRolesShort: Set<String> = [
        "NavigationBar",
        "TabBar",
        "Toolbar"
    ]
    private static let iosContainerRolesLong: Set<String> = Set(
        iosContainerRolesShort.map { "XCUIElementType\($0)" }
    )

    /// Maximum marks to render per screenshot. Mirrors the web probe's
    /// cap so badge density stays manageable on dense screens (e.g.,
    /// settings tables, mail inboxes).
    private static let maxMarks = 80

    /// Hard floor — sub-this elements are filtered as decorative.
    private static let minTapSizePt: CGFloat = 16

    func probeInteractiveElements() async throws -> [InteractiveMark] {
        let root = try await source()
        var candidates: [(rect: CGRect, role: String, label: String)] = []
        Self.walk(node: root, into: &candidates)
        // Reading order: top-to-bottom, then left-to-right.
        candidates.sort { (a, b) in
            if abs(a.rect.minY - b.rect.minY) < 1 {
                return a.rect.minX < b.rect.minX
            }
            return a.rect.minY < b.rect.minY
        }
        // Cap at maxMarks. Elements past the cap stay un-badged; the
        // agent can scroll to bring more into view (the next probe
        // will pick up newly-visible ones).
        let capped = candidates.prefix(Self.maxMarks)
        var marks: [InteractiveMark] = []
        marks.reserveCapacity(capped.count)
        for (i, entry) in capped.enumerated() {
            marks.append(InteractiveMark(
                id: i + 1,
                rect: entry.rect,
                role: Self.shortRole(entry.role),
                inputType: nil,
                label: entry.label
            ))
        }
        return marks
    }

    /// Recursively walk an AX node and collect actionable descendants.
    /// Nested actionable elements (cell containing a button) collapse
    /// to the outermost actionable ancestor — the cell — to avoid
    /// double-marking. Visibility, enabled state, and minimum size are
    /// gated here.
    nonisolated private static func walk(
        node: [String: Any],
        into out: inout [(rect: CGRect, role: String, label: String)]
    ) {
        // Defensively pull fields; WDA's JSON shapes have shifted
        // between versions but the field names are stable.
        let typeRaw = (node["type"] as? String) ?? ""
        // Visibility/enabled flags are advisory — WDA omits them on
        // many nodes. Default to true so a missing flag doesn't drop
        // an element that's genuinely on-screen.
        let isVisible = (node["visible"] as? Bool) ?? true
        let isEnabled = (node["enabled"] as? Bool) ?? true

        let isActionable = actionableIOSRolesShort.contains(typeRaw) ||
                           actionableIOSRolesLong.contains(typeRaw)
        let isContainer = iosContainerRolesShort.contains(typeRaw) ||
                          iosContainerRolesLong.contains(typeRaw)

        if isActionable, isVisible, isEnabled, let rect = parseRect(node["rect"]) {
            let bigEnough = rect.width >= minTapSizePt && rect.height >= minTapSizePt
            if bigEnough {
                let label = resolveLabel(node)
                out.append((rect, typeRaw, label))
                // Don't recurse further — avoids double-marking a
                // Cell that contains a Button (both would otherwise
                // produce overlapping badges).
                return
            }
        }
        // Containers (NavigationBar, TabBar, Toolbar) get descended
        // so their children (back buttons, tab items, etc.) end up
        // marked individually rather than the bar itself.
        _ = isContainer  // suppress unused warning; behaviour falls through to recursion

        // Recurse into children.
        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            walk(node: child, into: &out)
        }
    }

    nonisolated private static func parseRect(_ raw: Any?) -> CGRect? {
        guard let dict = raw as? [String: Any] else { return nil }
        // WDA returns `{x, y, width, height}` with values that may be
        // Int, Double, or NSNumber depending on the JSON parser.
        let x = numericValue(dict["x"])
        let y = numericValue(dict["y"])
        let w = numericValue(dict["width"])
        let h = numericValue(dict["height"])
        guard let x, let y, let w, let h else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    nonisolated private static func numericValue(_ any: Any?) -> CGFloat? {
        if let d = any as? Double { return CGFloat(d) }
        if let i = any as? Int { return CGFloat(i) }
        if let n = any as? NSNumber { return CGFloat(truncating: n) }
        if let s = any as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }

    /// Resolve a human-readable label from an AX node. Tries `label`
    /// first (most user-visible), falls back to `name` (the AX
    /// identifier or accessibility label), then `value` (current
    /// content of text fields, etc.). When none of the node's own
    /// attributes carry a label — common for `Cell` wrappers whose
    /// visible text lives in child `StaticText` nodes — recursively
    /// collects StaticText labels from descendants and joins them
    /// with " — ". This makes table-view rows like a contact list,
    /// settings list, or server list resolvable to their visible
    /// text (e.g. "127.0.0.1 — alanwizemann@127.0.0.1") instead of
    /// the unhelpful empty string.
    nonisolated private static func resolveLabel(_ node: [String: Any]) -> String {
        let candidates = [
            node["label"] as? String,
            node["name"] as? String,
            node["value"] as? String
        ]
        for c in candidates {
            if let s = c?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return clipLabel(s)
            }
        }
        // No direct label — try rolling up visible text from
        // descendant StaticText / Image (with alt-text) nodes.
        let rolled = collectChildText(node, limit: 3)
        if !rolled.isEmpty {
            return clipLabel(rolled.joined(separator: " — "))
        }
        return ""
    }

    /// Walk descendants and collect up to `limit` non-empty text
    /// labels from `StaticText` / `XCUIElementTypeStaticText` /
    /// `Image` nodes (image alt text). Used by `resolveLabel` to
    /// roll up the visible text of a Cell or similar container that
    /// itself has no label attribute. Stops descending once `limit`
    /// snippets are collected to keep label generation O(visible
    /// children) rather than O(whole tree).
    nonisolated private static func collectChildText(_ node: [String: Any], limit: Int) -> [String] {
        var out: [String] = []
        var visited = 0
        func recurse(_ n: [String: Any]) {
            if out.count >= limit { return }
            visited += 1
            // Bound the recursion in case of a deep tree.
            if visited > 64 { return }
            let type = (n["type"] as? String) ?? ""
            let isTextLike = type == "StaticText" || type == "XCUIElementTypeStaticText"
                          || type == "Image" || type == "XCUIElementTypeImage"
            if isTextLike {
                let candidates = [
                    n["label"] as? String,
                    n["value"] as? String,
                    n["name"] as? String
                ]
                for c in candidates {
                    if let s = c?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty {
                        out.append(s)
                        break
                    }
                }
            }
            if let kids = n["children"] as? [[String: Any]] {
                for k in kids { recurse(k); if out.count >= limit { break } }
            }
        }
        if let kids = node["children"] as? [[String: Any]] {
            for k in kids { recurse(k); if out.count >= limit { break } }
        }
        return out
    }

    nonisolated private static func clipLabel(_ s: String) -> String {
        s.count > 80 ? String(s.prefix(77)) + "…" : s
    }

    /// Short, agent-friendly role name. Maps `XCUIElementTypeButton`
    /// → `button`, `Button` → `button`, etc. WDA 12.x returns the
    /// short form by default; older / configured-differently builds
    /// may return the long form. Both normalise to lowercase-first
    /// for readability in the annotation.
    nonisolated private static func shortRole(_ raw: String) -> String {
        let prefix = "XCUIElementType"
        let body: String
        if raw.hasPrefix(prefix) {
            body = String(raw.dropFirst(prefix.count))
        } else {
            body = raw
        }
        guard let first = body.first else { return body }
        return first.lowercased() + body.dropFirst()
    }

    // MARK: Internals

    private func requireSessionID() throws -> String {
        guard let sid = sessionID else { throw WDAClientError.noSession }
        return sid
    }

    /// Build a request, send it, and return the parsed JSON object. Retries
    /// connection-refused / dropped-connection / 5xx up to `maxRetries`.
    @discardableResult
    private func requestJSON(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } else {
            bodyData = nil
        }
        var lastError: any Error = WDAClientError.retryExhausted(detail: "no attempts")
        for attempt in 0..<Self.maxRetries {
            try Task.checkCancellation()
            do {
                let data = try await requestRaw(method: method, path: path, body: bodyData)
                return Self.parseJSON(data)
            } catch let error as WDAClientError {
                if case .httpError(let status, _) = error, status < 500 {
                    throw error  // 4xx is the caller's fault — don't retry.
                }
                lastError = error
            } catch let error as URLError where Self.isRetryable(error) {
                lastError = error
            } catch {
                throw error
            }
            if attempt < Self.maxRetries - 1 {
                try? await Task.sleep(for: Self.backoff)
            }
        }
        Self.logger.warning("WDA request retries exhausted: \(method, privacy: .public) \(path, privacy: .public) — \(lastError.localizedDescription, privacy: .public)")
        throw WDAClientError.retryExhausted(detail: lastError.localizedDescription)
    }

    /// Single attempt — no retries. Used by `waitForReady` (which loops on its
    /// own cadence) and as the inner of `requestJSON`'s retry loop.
    private func requestRaw(method: String, path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: makeURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WDAClientError.malformedResponse(detail: "non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw WDAClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    nonisolated private func makeURL(path: String) -> URL {
        // 127.0.0.1 (not localhost) — avoids rare DNS-resolution stalls.
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    nonisolated private static func parseJSON(_ data: Data) -> [String: Any] {
        if data.isEmpty { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// Network-layer errors worth retrying. 5xx is handled at the response level.
    nonisolated static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost,
             .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    nonisolated private static func seconds(of duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1_000_000_000_000_000_000.0
    }
}
