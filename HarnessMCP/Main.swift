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
