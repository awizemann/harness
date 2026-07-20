//
//  MCPServerIdentityTests.swift
//  HarnessTests
//
//  Pins the single-source-of-truth server identity and the pure command-line
//  flag parser used by the `harness-mcp` binary's `--version` / `--help`
//  handling. `HarnessMCP/Main.swift` maps the parsed `MCPLaunchMode` to stdout
//  + exit BEFORE any NSApplication bring-up, and `HarnessMCP/MCPServer.swift`
//  reports the SAME `name`/`version` in the JSON-RPC handshake — so a consuming
//  product (Orchestric) sees one identity whether it probes `--version` or
//  reads `serverInfo`. Both live in the `Harness/` module so they're testable
//  here (the `HarnessMCP` target isn't in the test graph).
//

import Testing
import Foundation
@testable import Harness

@Suite("MCPServerIdentity — identity")
struct MCPServerIdentityTests {

    @Test("name is the wire/handshake server name")
    func name() {
        #expect(MCPServerIdentity.name == "harness-mcp")
    }

    @Test("version + protocolVersion are non-empty")
    func versionsPresent() {
        #expect(!MCPServerIdentity.version.isEmpty)
        #expect(!MCPServerIdentity.protocolVersion.isEmpty)
    }

    @Test("versionLine is 'name version' — the exact --version output")
    func versionLine() {
        #expect(MCPServerIdentity.versionLine == "\(MCPServerIdentity.name) \(MCPServerIdentity.version)")
        // Single space, no trailing whitespace: this is parsed by a consuming
        // product to sanity-check the bundled binary.
        #expect(!MCPServerIdentity.versionLine.hasSuffix(" "))
        #expect(MCPServerIdentity.versionLine.split(separator: " ").count == 2)
    }
}

@Suite("MCPCommandLine — flag parsing")
struct MCPCommandLineTests {

    // arg0 is always the executable path (as CommandLine.arguments delivers it).
    private let exe = "/some/path/harness-mcp"

    @Test("no flags → serve (the default stdio server)")
    func noFlags() {
        #expect(MCPCommandLine.mode(for: [exe]) == .serve)
    }

    @Test("--version → version")
    func version() {
        #expect(MCPCommandLine.mode(for: [exe, "--version"]) == .version)
    }

    @Test("--help and -h → help")
    func help() {
        #expect(MCPCommandLine.mode(for: [exe, "--help"]) == .help)
        #expect(MCPCommandLine.mode(for: [exe, "-h"]) == .help)
    }

    @Test("--help wins over --version when both are present")
    func helpBeatsVersion() {
        #expect(MCPCommandLine.mode(for: [exe, "--version", "--help"]) == .help)
        #expect(MCPCommandLine.mode(for: [exe, "--help", "--version"]) == .help)
    }

    @Test("an unrecognized flag still serves (never a refusal)")
    func unknownFlagServes() {
        // A client that passes an unexpected flag should still get a working
        // stdio server rather than an error — the flag is ignored.
        #expect(MCPCommandLine.mode(for: [exe, "--frobnicate"]) == .serve)
        #expect(MCPCommandLine.mode(for: [exe, "serve"]) == .serve)
    }

    @Test("flag matching is case-insensitive")
    func caseInsensitive() {
        #expect(MCPCommandLine.mode(for: [exe, "--Version"]) == .version)
        #expect(MCPCommandLine.mode(for: [exe, "--HELP"]) == .help)
    }

    @Test("arg0 alone is never treated as a flag")
    func arg0Ignored() {
        // Even if the binary were named literally "--version", arg0 is dropped.
        #expect(MCPCommandLine.mode(for: ["--version"]) == .serve)
    }

    @Test("usage note carries the version line and names both flags")
    func usageContent() {
        let usage = MCPCommandLine.usage
        #expect(usage.contains(MCPServerIdentity.versionLine))
        #expect(usage.contains("--version"))
        #expect(usage.contains("--help"))
    }
}
