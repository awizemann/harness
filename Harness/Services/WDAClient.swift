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
