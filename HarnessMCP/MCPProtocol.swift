//
//  MCPProtocol.swift
//  HarnessMCP
//
//  Small value types for the hand-rolled MCP (JSON-RPC 2.0) layer:
//  typed access to a tool call's `arguments`, the error vocabulary, and
//  the `tools/call` content/result shapes. No third-party MCP SDK — the
//  project deliberately ships zero SPM dependencies, so the protocol is
//  implemented directly over `JSONSerialization` (see `MCPServer`).
//
//  These types are only ever touched inside the `MCPServer` actor, so
//  they don't need to be `Sendable` (and `MCPArguments` deliberately
//  wraps a non-Sendable `[String: Any]`).
//

import Foundation

/// Typed accessor over a JSON-RPC `params.arguments` object.
struct MCPArguments {
    let raw: [String: Any]

    init(_ raw: [String: Any]?) { self.raw = raw ?? [:] }

    func string(_ key: String) -> String? {
        guard let s = raw[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    func int(_ key: String) -> Int? {
        let v = raw[key]
        // JSONSerialization bridges JSON numbers AND booleans to NSNumber;
        // reject genuine booleans so `step_budget: true` isn't read as 1.
        if let n = v as? NSNumber, !Self.isJSONBool(n) { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        // Accept only genuine JSON booleans — reject numbers so
        // `include_archived: 5` isn't silently read as `true`.
        if let n = raw[key] as? NSNumber, Self.isJSONBool(n) { return n.boolValue }
        return nil
    }

    /// True only for a genuine JSON boolean. Both JSON numbers and booleans
    /// bridge to `NSNumber`; only a boolean carries the CFBoolean type id.
    private static func isJSONBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    func uuid(_ key: String) -> UUID? {
        guard let s = raw[key] as? String else { return nil }
        return UUID(uuidString: s)
    }

    func objectArray(_ key: String) -> [[String: Any]] {
        raw[key] as? [[String: Any]] ?? []
    }

    func requireString(_ key: String) throws -> String {
        guard let v = string(key) else { throw MCPToolError.missingArgument(key) }
        return v
    }

    func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw MCPToolError.invalidArgument(key, "expected an integer") }
        return v
    }

    func requireUUID(_ key: String) throws -> UUID {
        guard let v = uuid(key) else { throw MCPToolError.invalidArgument(key, "expected a UUID string") }
        return v
    }
}

/// Error vocabulary surfaced to the agent as a `tools/call` result with
/// `isError: true` (per the MCP spec, tool failures are results, not
/// JSON-RPC protocol errors).
enum MCPToolError: Error, LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, String)
    case notFound(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let k):
            return "Missing required argument: '\(k)'."
        case .invalidArgument(let k, let why):
            return "Invalid argument '\(k)': \(why)."
        case .notFound(let what):
            return "Not found: \(what)."
        case .message(let m):
            return m
        }
    }
}

/// One content item in a `tools/call` result.
enum MCPContent {
    case text(String)
    case image(base64: String, mimeType: String)

    var json: [String: Any] {
        switch self {
        case .text(let t):
            return ["type": "text", "text": t]
        case .image(let b64, let mime):
            return ["type": "image", "data": b64, "mimeType": mime]
        }
    }
}

/// A tool handler's result — content items plus the MCP `isError` flag.
struct MCPToolOutcome {
    var content: [MCPContent]
    var isError: Bool

    init(_ content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    static func text(_ s: String) -> MCPToolOutcome { MCPToolOutcome([.text(s)]) }
    static func error(_ s: String) -> MCPToolOutcome { MCPToolOutcome([.text(s)], isError: true) }
}
