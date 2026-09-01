//
//  MCPServerIdentity.swift
//  Harness
//
//  Single source of truth for the MCP server's name + version and for the
//  binary's command-line flag handling (`--version` / `--help`). Lives in
//  the `Harness/` source root (shared by the app, CLI, and MCP targets) so
//  the flag parser is unit-testable via `@testable import Harness` — the
//  `HarnessMCP/` target itself is not in the test graph.
//
//  `HarnessMCP/MCPServer.swift` reports `name`/`version` in the JSON-RPC
//  `initialize` handshake; `HarnessMCP/Main.swift` prints the SAME values
//  for `--version`, so a consuming product sees one identity everywhere.
//

import Foundation

/// The MCP server's advertised identity. The `initialize` handshake's
/// `serverInfo` and the binary's `--version` output both read from here.
enum MCPServerIdentity {
    /// Reported as `serverInfo.name` and printed by `--version`.
    static let name = "harness-mcp"
    /// Reported as `serverInfo.version` and printed by `--version`. Bump in
    /// lockstep with a user-visible change to the MCP surface.
    static let version = "0.8.2"
    /// Default MCP protocol version when the client doesn't pin one.
    static let protocolVersion = "2025-06-18"

    /// The exact line `--version` prints (name + version), e.g.
    /// `harness-mcp 0.8.0`.
    static var versionLine: String { "\(name) \(version)" }
}

/// What the process should do based on its command-line arguments. Parsed
/// BEFORE any `NSApplication` bring-up so `--version` / `--help` never spin
/// the run loop.
enum MCPLaunchMode: Equatable {
    /// No recognized flag — run the stdio MCP server (the default).
    case serve
    /// `--version`: print `MCPServerIdentity.versionLine` and exit 0.
    case version
    /// `--help` / `-h`: print `MCPCommandLine.usage` and exit 0.
    case help
}

/// Pure command-line handling for the `harness-mcp` binary. No side effects
/// — `Main.swift` maps the returned `MCPLaunchMode` to stdout + `exit`.
enum MCPCommandLine {

    /// Decide the launch mode from a raw argument vector (`CommandLine.arguments`,
    /// including the executable path at index 0).
    ///
    /// Precedence: `--help`/`-h` wins over `--version`; any unrecognized
    /// argument is ignored so a client that passes an unexpected flag still
    /// gets a working stdio server rather than a refusal.
    static func mode(for arguments: [String]) -> MCPLaunchMode {
        let flags = Set(arguments.dropFirst().map { $0.lowercased() })
        if flags.contains("--help") || flags.contains("-h") { return .help }
        if flags.contains("--version") { return .version }
        return .serve
    }

    /// Two-line usage note printed for `--help`. Built from the identity so
    /// the version stays in sync.
    static var usage: String {
        """
        \(MCPServerIdentity.versionLine) — stdio MCP server driving web/iOS UI sessions (and Harness runs) for an external agent.
        Usage: harness-mcp [--version | --help]   ·   no arguments: serve MCP JSON-RPC over stdin/stdout.
        """
    }
}
