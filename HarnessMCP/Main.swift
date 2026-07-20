//
//  Main.swift
//  HarnessMCP
//
//  Entry point for the MCP server that lets agents drive Harness over
//  stdio. Like `HarnessCLI/Main.swift`, it pumps an `NSApplication.run()`
//  main loop: `WebPlatformAdapter` hosts a `WKWebView` whose WebKit
//  delegate callbacks (load finished, JS eval, screenshot snapshots) post
//  to the main run loop, so without a running NSApplication a web run's
//  `awaitNextLoad(timeout:)` would deadlock.
//
//  `.prohibited` activation policy keeps this a true background process —
//  no Dock icon, no menu bar — while the JSON-RPC read loop runs off the
//  main thread inside the `MCPServer` actor and exits the process when
//  stdin closes.
//

import AppKit
import Foundation

@main
struct HarnessMCPMain {
    static func main() {
        // Handle `--version` / `--help` BEFORE touching NSApplication so
        // these flags print + exit without ever spinning the run loop
        // (a consuming product probes `--version` to sanity-check the
        // bundled binary; it must not launch a background app).
        switch MCPCommandLine.mode(for: CommandLine.arguments) {
        case .version:
            print(MCPServerIdentity.versionLine)
            exit(0)
        case .help:
            print(MCPCommandLine.usage)
            exit(0)
        case .serve:
            break
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let server = MCPServer()
        Task {
            await server.serve()
            await MainActor.run { exit(0) }
        }

        app.run()
    }
}
