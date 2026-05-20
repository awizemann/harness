//
//  Main.swift
//  HarnessCLI
//
//  Entry point for the development-time CLI that drives a single web
//  run end-to-end against the existing `WebPlatformAdapter` +
//  `RunCoordinator` pipeline. Designed for the inner dev loop —
//  `swift run / xcodebuild build → ./harness-cli --url ... → read PNGs +
//  events.jsonl from disk` — without rebuilding the full SwiftUI Mac app.
//
//  Why an NSApplication.run() pump?
//  --------------------------------
//  `WebPlatformAdapter` constructs a `WKWebView` hosted in an
//  off-screen `NSWindow`. WKWebView's WebKit delegate callbacks (load
//  start/finish, JS evaluation completion, screenshot snapshots) are
//  posted to the main run loop. Without a running NSApplication those
//  callbacks never fire and `awaitNextLoad(timeout:)` deadlocks.
//
//  We set `.prohibited` activation policy so the binary stays a true
//  background process — no Dock icon, no menu-bar takeover, no
//  Cmd-Q intercept — while still pumping the main run loop.
//

import AppKit
import Foundation

@main
struct HarnessCLIMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let argv = CommandLine.arguments
        let args: CLIArgs
        do {
            args = try CLIArgs.parse(argv)
        } catch let error as CLIArgsError {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n\nUsage:\n\(CLIArgs.usage)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("Unexpected error parsing arguments: \(error)\n".utf8))
            exit(2)
        }

        Task {
            let exitCode = await HarnessRunner.run(args)
            await MainActor.run {
                exit(exitCode)
            }
        }

        app.run()
    }
}
