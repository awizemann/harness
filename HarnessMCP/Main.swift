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

        // Tear the SUT down on SIGTERM/SIGINT too. `shutdownAll()` otherwise
        // runs only when stdin closes gracefully; a parent kill (SIGTERM) or
        // Ctrl-C (SIGINT) would abandon the read loop and orphan a macOS SUT
        // on the user's desktop. Idiomatic GCD shape: ignore the default
        // disposition, then observe via DispatchSource on the main queue so
        // the handler can hop onto the `MCPServer` actor for a clean teardown
        // before exiting. `shutdownIfNeeded()` is idempotent, so this and the
        // graceful stdin path can't double-quit the session.
        //
        // Residual: SIGKILL (`kill -9`) and hard crashes still can't run
        // cleanup and will leak the SUT — that's an accepted, documented gap
        // the consumer relies on graceful signals to avoid.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let onSignal: @Sendable () -> Void = {
            Task {
                await server.shutdownIfNeeded()
                exit(0)
            }
        }
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigtermSource.setEventHandler(handler: onSignal)
        sigintSource.setEventHandler(handler: onSignal)
        sigtermSource.resume()
        sigintSource.resume()

        Task {
            await server.serve()
            await MainActor.run { exit(0) }
        }

        // Hold the signal sources for the whole run loop — a deallocated
        // DispatchSource stops delivering. `app.run()` never returns.
        withExtendedLifetime((sigtermSource, sigintSource)) {
            app.run()
        }
    }
}
