//
//  WDAClientTests.swift
//  HarnessTests
//
//  URLProtocol-mocked tests for the WDAClient HTTP layer. We assert request
//  shapes (method, path, body keys/values) and response handling (session-id
//  parsing, retry behavior on 5xx / connection-refused).
//

import Testing
import Foundation
@testable import Harness

@Suite("WDAClient — request shapes and response handling")
struct WDAClientTests {

    // MARK: Helpers

    /// Stub returning a fresh session for `POST /session`, deferring all other
    /// requests to `inner`. Most tests need this exact pattern.
    private static func sessionPlus(_ inner: @escaping @Sendable (URLRequest) -> WDAStubProtocol.Response) -> WDAStubProtocol.Handler {
        return { request in
            if request.url?.path == "/session", request.httpMethod == "POST" {
                return WDAStubProtocol.Response(status: 200, body: #"{"value": {"sessionId": "S1"}}"#)
            }
            return inner(request)
        }
    }

    // MARK: Session lifecycle

    @Test("createSession parses sessionId from W3C-shaped response")
    func createSessionShape() async throws {
        let recorder = WDAStubProtocol.Recorder()
        let stub = WDAStubProtocol.install { request in
            recorder.record(request)
            return WDAStubProtocol.Response(
                status: 200,
                body: #"{"value": {"sessionId": "abc-123", "capabilities": {}}}"#
            )
        }
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        let handle = try await client.createSession()
        #expect(handle.id == "abc-123")
        #expect(handle.port == 8100)
        #expect(recorder.method() == "POST")
        #expect(recorder.path() == "/session")
        let caps = recorder.body()["capabilities"] as? [String: Any]
        let always = caps?["alwaysMatch"] as? [String: Any]
        #expect(always?["platformName"] as? String == "iOS")
    }

    @Test("createSession throws malformedResponse when sessionId is missing")
    func createSessionMissingID() async throws {
        let stub = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: #"{"value": {}}"#)
        }
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        do {
            _ = try await client.createSession()
            Issue.record("expected throw")
        } catch let error as WDAClientError {
            if case .malformedResponse = error { return }
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("endSession sends DELETE /session/<id>")
    func endSessionShape() async throws {
        let recorder = WDAStubProtocol.Recorder()
        let stub = WDAStubProtocol.install(Self.sessionPlus { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: "{}")
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        await client.endSession()

        #expect(recorder.method() == "DELETE")
        #expect(recorder.path() == "/session/S1")
    }

    // MARK: Tap

    @Test("tap POSTs /session/<id>/wda/tap with x and y")
    func tapShape() async throws {
        let recorder = WDAStubProtocol.Recorder()
        let stub = WDAStubProtocol.install(Self.sessionPlus { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: #"{"value": null}"#)
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        try await client.tap(at: CGPoint(x: 215, y: 432))

        #expect(recorder.path() == "/session/S1/wda/tap")
        let body = recorder.body()
        #expect((body["x"] as? Double) == 215)
        #expect((body["y"] as? Double) == 432)
    }

    // MARK: Swipe

    @Test("swipe POSTs dragfromtoforduration with from/to coords + duration in seconds")
    func swipeShape() async throws {
        let recorder = WDAStubProtocol.Recorder()
        let stub = WDAStubProtocol.install(Self.sessionPlus { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: "{}")
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        try await client.swipe(
            from: CGPoint(x: 100, y: 700),
            to: CGPoint(x: 100, y: 200),
            duration: .milliseconds(300)
        )

        #expect(recorder.path() == "/session/S1/wda/dragfromtoforduration")
        let body = recorder.body()
        #expect((body["fromX"] as? Double) == 100)
        #expect((body["fromY"] as? Double) == 700)
        #expect((body["toX"] as? Double) == 100)
        #expect((body["toY"] as? Double) == 200)
        if let d = body["duration"] as? Double {
            #expect(abs(d - 0.3) < 0.001)
        } else {
            Issue.record("duration missing or wrong type: \(String(describing: body["duration"]))")
        }
    }

    // MARK: Type

    @Test("type POSTs /wda/keys with value as per-character array")
    func typeShape() async throws {
        let recorder = WDAStubProtocol.Recorder()
        let stub = WDAStubProtocol.install(Self.sessionPlus { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: "{}")
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        try await client.type("milk")

        #expect(recorder.path() == "/session/S1/wda/keys")
        #expect((recorder.body()["value"] as? [String]) == ["m", "i", "l", "k"])
    }

    // MARK: Press button

    @Test("pressButton POSTs name in body")
    func pressButtonShape() async throws {
        let recorder = WDAStubProtocol.Recorder()
        let stub = WDAStubProtocol.install(Self.sessionPlus { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: "{}")
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        try await client.pressButton(.home)

        #expect((recorder.body()["name"] as? String) == "home")
    }

    // MARK: Retry behavior

    @Test("Retries on 5xx then succeeds")
    func retryOn500ThenSuccess() async throws {
        let counter = WDAStubProtocol.AtomicInt(0)
        let stub = WDAStubProtocol.install(Self.sessionPlus { request in
            if request.url?.path.contains("/wda/tap") == true {
                let n = counter.next()
                if n == 0 {
                    return WDAStubProtocol.Response(status: 500, body: "transient")
                }
                return WDAStubProtocol.Response(status: 200, body: "{}")
            }
            return WDAStubProtocol.Response(status: 404, body: "?")
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        try await client.tap(at: CGPoint(x: 1, y: 1))

        #expect(counter.value() == 2, "expected exactly one retry after the 500 (first call + one retry = 2)")
    }

    @Test("4xx client error fails fast — no retry")
    func noRetryOn400() async throws {
        let counter = WDAStubProtocol.AtomicInt(0)
        let stub = WDAStubProtocol.install(Self.sessionPlus { _ in
            counter.next()
            return WDAStubProtocol.Response(status: 400, body: "bad")
        })
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        _ = try await client.createSession()
        do {
            try await client.tap(at: .zero)
            Issue.record("expected 4xx to throw")
        } catch let error as WDAClientError {
            if case .httpError(let status, _) = error {
                #expect(status == 400)
            } else {
                Issue.record("wrong error: \(error)")
            }
        }
        #expect(counter.value() == 1, "must NOT retry on 4xx")
    }

    @Test("waitForReady polls /status and returns when 200")
    func waitForReadyPolls() async throws {
        let counter = WDAStubProtocol.AtomicInt(0)
        let stub = WDAStubProtocol.install { request in
            #expect(request.url?.path == "/status")
            let n = counter.next()
            if n < 2 {
                return WDAStubProtocol.Response(status: 502, body: "starting")
            }
            return WDAStubProtocol.Response(status: 200, body: #"{"value": {"ready": true}}"#)
        }
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        try await client.waitForReady(timeout: .seconds(5))
        #expect(counter.value() >= 3)
    }

    @Test("waitForReady throws notReady on timeout")
    func waitForReadyTimeout() async throws {
        let stub = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 503, body: "down")
        }
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        do {
            try await client.waitForReady(timeout: .milliseconds(700))
            Issue.record("expected timeout")
        } catch let error as WDAClientError {
            if case .notReady = error { return }
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Tap before session throws noSession")
    func tapWithoutSessionThrows() async throws {
        let stub = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: "{}")
        }
        defer { stub.uninstall() }

        let client = WDAClient(port: 8100, urlSession: WDAStubProtocol.session())
        do {
            try await client.tap(at: .zero)
            Issue.record("expected throw")
        } catch let error as WDAClientError {
            if case .noSession = error { return }
            Issue.record("wrong error: \(error)")
        }
    }
}
