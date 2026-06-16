//
//  MCPServer.swift
//  HarnessMCP
//
//  Hand-rolled MCP server: newline-delimited JSON-RPC 2.0 over stdio.
//  Reads one JSON object per line from stdin, dispatches `initialize` /
//  `tools/list` / `tools/call` / `ping`, and writes one JSON object per
//  line to stdout. All diagnostics go to stderr — stdout is reserved for
//  the protocol channel.
//
//  Everything runs inside this actor, so request handling is naturally
//  serialized and the non-`Sendable` `[String: Any]` JSON values never
//  cross an isolation boundary. Long-running work (`start_run`) is handed
//  to `RunSupervisor` and returns immediately, so the read loop never
//  blocks on a run.
//

import Foundation

actor MCPServer {

    private let serverName = "harness-mcp"
    private let serverVersion = "0.5.0"
    private let defaultProtocolVersion = "2025-06-18"

    /// Lazily-opened shared dependency graph. Cached as a `Result` so a
    /// store-open failure is reported once per call (as an `isError`
    /// tool result) without retrying on every request.
    private var containerResult: Result<MCPContainer, Error>?

    /// Guards the one-time, idempotent built-in persona seed (mirrors the
    /// GUI's `AppContainer.bootstrapPersonas()`) so a fresh store isn't
    /// empty the first time an agent lists or runs. Set once per process.
    var didSeedBuiltIns = false

    private let stdout = FileHandle.standardOutput

    // MARK: - Run loop

    func serve() async {
        log("ready — stdio JSON-RPC (store: \(HarnessPaths.appSupport.appendingPathComponent("history.store").path))")
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                await handleLine(line)
            }
        } catch {
            log("stdin read error: \(error.localizedDescription)")
        }
        log("stdin closed — exiting")
    }

    func container() throws -> MCPContainer {
        if let cached = containerResult { return try cached.get() }
        let result = Result { try MCPContainer.makeShared() }
        containerResult = result
        return try result.get()
    }

    // MARK: - Dispatch

    private func handleLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            writeError(id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = obj["id"]                       // absent → notification
        let isNotification = (id == nil)

        guard let method = obj["method"] as? String else {
            if !isNotification { writeError(id: id, code: -32600, message: "Invalid Request: missing 'method'") }
            return
        }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let clientVersion = params["protocolVersion"] as? String
            writeResult(id: id, result: [
                "protocolVersion": clientVersion ?? defaultProtocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion]
            ])

        case "notifications/initialized", "initialized", "notifications/cancelled":
            break   // notifications — no response

        case "ping":
            writeResult(id: id, result: [:])

        case "tools/list":
            writeResult(id: id, result: ["tools": ToolRegistry.definitions()])

        case "tools/call":
            await handleToolCall(id: id, params: params)

        default:
            if !isNotification {
                writeError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) async {
        guard let name = params["name"] as? String else {
            writeError(id: id, code: -32602, message: "tools/call missing 'name'")
            return
        }
        let args = MCPArguments(params["arguments"] as? [String: Any])

        let outcome: MCPToolOutcome
        do {
            outcome = try await dispatch(tool: name, args: args)
        } catch {
            // Tool failures are MCP results with isError, not protocol errors.
            outcome = .error(error.localizedDescription)
        }

        writeResult(id: id, result: [
            "content": outcome.content.map { $0.json },
            "isError": outcome.isError
        ])
    }

    // MARK: - Output

    func writeResult(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        msg["id"] = id ?? NSNull()
        writeMessage(msg)
    }

    func writeError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        msg["id"] = id ?? NSNull()
        writeMessage(msg)
    }

    private func writeMessage(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else {
            log("failed to serialize response")
            return
        }
        var line = data
        line.append(0x0A)   // newline-delimited framing
        stdout.write(line)
    }

    nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("[harness-mcp] \(message)\n".utf8))
    }
}
