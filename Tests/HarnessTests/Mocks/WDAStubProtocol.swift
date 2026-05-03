//
//  WDAStubProtocol.swift
//  HarnessTests
//
//  URLProtocol-based stub for unit-testing WDAClient against arbitrary HTTP
//  responses. Tests install a handler closure, build a `URLSession` whose
//  configuration uses this protocol class, and inspect `URLRequest`s as they
//  arrive.
//

import Foundation

final class WDAStubProtocol: URLProtocol, @unchecked Sendable {

    /// One stub response. Status and body — headers are added automatically.
    struct Response: Sendable {
        let status: Int
        let body: String

        init(status: Int, body: String = "{}") {
            self.status = status
            self.body = body
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Response

    /// Test-only counter used by retry-behavior tests. NSLock-backed for
    /// concurrent access from URLProtocol's loading thread + test thread.
    final class AtomicInt: @unchecked Sendable {
        private var v: Int
        private let lock = NSLock()
        init(_ v: Int) { self.v = v }
        @discardableResult
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let cur = v
            v += 1
            return cur
        }
        func value() -> Int {
            lock.lock(); defer { lock.unlock() }
            return v
        }
    }

    /// Stash the most recent observed request shape from the handler thread
    /// for assertions on the test thread. NSLock-backed for the same reason
    /// as `AtomicInt` — `[String: Any]` isn't Sendable, and the handler
    /// closure is `@Sendable`.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _path: String?
        private var _method: String?
        private var _body: [String: Any] = [:]

        init() {}

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            _path = request.url?.path
            _method = request.httpMethod
            _body = WDAStubProtocol.bodyJSON(of: request)
        }

        func path() -> String? { lock.lock(); defer { lock.unlock() }; return _path }
        func method() -> String? { lock.lock(); defer { lock.unlock() }; return _method }
        func body() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return _body }
    }

    // MARK: Installation

    final class Installation {
        fileprivate init() {}
        func uninstall() {
            WDAStubProtocol.lock.lock()
            defer { WDAStubProtocol.lock.unlock() }
            WDAStubProtocol.handler = nil
        }
    }

    static func install(_ handler: @escaping Handler) -> Installation {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        return Installation()
    }

    /// Build a URLSession whose only protocol is this stub. Use the returned
    /// session for the WDAClient under test.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WDAStubProtocol.self]
        return URLSession(configuration: config)
    }

    /// Convenience: deserialize a request's HTTP body as a JSON object.
    /// Returns `[:]` for empty / non-JSON bodies.
    static func bodyJSON(of request: URLRequest) -> [String: Any] {
        // URLProtocol drops the request body; URLSession forwards it via
        // `httpBodyStream` for streamed bodies. Both paths hand us Data here
        // because we set `httpBody` directly in WDAClient.
        let data = request.httpBody ?? readStream(request.httpBodyStream)
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: URLProtocol overrides

    private nonisolated(unsafe) static var handler: Handler?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let h: Handler? = {
            WDAStubProtocol.lock.lock()
            defer { WDAStubProtocol.lock.unlock() }
            return WDAStubProtocol.handler
        }()
        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = h(request)
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { /* no-op */ }
}
