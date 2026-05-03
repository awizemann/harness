//
//  SimulatorDriver.swift
//  Harness
//
//  Wraps `xcrun simctl` (lifecycle) and `idb` (input). The standard at
//  `standards/12-simulator-control.md` is the invariants reference. The
//  per-method command mapping lives in `wiki/Simulator-Driver.md`.
//
//  Coordinate-space rule (the #1 expected failure mode): screenshots from
//  `simctl io booted screenshot` are at PIXEL resolution. `idb tap` takes
//  POINTS. `SimulatorDriver` divides any pixel-derived coordinate by
//  `SimulatorRef.scaleFactor` exactly once at the boundary into idb. Every
//  other call site uses points. The conversion is unit-tested.
//

import Foundation
import AppKit
import os

// MARK: - Errors

enum SimulatorError: Error, Sendable, LocalizedError {
    case idbUnavailable
    case xcrunUnavailable
    case deviceNotFound(udid: String)
    case bootFailed(detail: String)
    case installFailed(detail: String)
    case launchFailed(bundleID: String, detail: String)
    case screenshotFailed(detail: String)
    case actionFailed(action: String, detail: String)
    case daemonUnreachable(detail: String)

    var errorDescription: String? {
        switch self {
        case .idbUnavailable:
            return "idb is not installed. Run: brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb"
        case .xcrunUnavailable:
            return "xcrun is not available. Install Xcode and run `xcode-select --install`."
        case .deviceNotFound(let udid):
            return "Simulator not found: \(udid). Refresh the simulator list."
        case .bootFailed(let detail):
            return "Failed to boot simulator. \(detail)"
        case .installFailed(let detail):
            return "Failed to install app on simulator. \(detail)"
        case .launchFailed(let bid, let detail):
            return "Failed to launch \(bid). \(detail)"
        case .screenshotFailed(let detail):
            return "Screenshot capture failed. \(detail)"
        case .actionFailed(let action, let detail):
            return "Simulator action '\(action)' failed. \(detail)"
        case .daemonUnreachable(let detail):
            return "idb_companion is unreachable. \(detail)"
        }
    }
}

// MARK: - Protocol

protocol SimulatorDriving: Sendable {
    func listDevices() async throws -> [SimulatorRef]
    func boot(_ ref: SimulatorRef) async throws
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws
    func launch(bundleID: String, on ref: SimulatorRef) async throws
    func terminate(bundleID: String, on ref: SimulatorRef) async throws
    func erase(_ ref: SimulatorRef) async throws

    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL
    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage

    func tap(at point: CGPoint, on ref: SimulatorRef) async throws
    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws
    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws
    func type(_ text: String, on ref: SimulatorRef) async throws
    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws

    /// Daemon-health probe. Returns true if `idb_companion` answers within `timeout`.
    func probeIDB(_ ref: SimulatorRef, timeout: Duration) async -> Bool

    /// Kill any `idb_companion` process attached to the given UDID. Called at
    /// run start so a stale companion from a prior run (perhaps one whose
    /// simulator was shut down or whose Mac was rebooted) doesn't intercept
    /// taps and silently route them into the void.
    func cleanupCompanion(udid: String) async
}

// MARK: - Implementation

struct SimulatorDriver: SimulatorDriving {

    private static let logger = Logger(subsystem: "com.harness.app", category: "SimulatorDriver")

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating

    init(processRunner: any ProcessRunning, toolLocator: any ToolLocating) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
    }

    // MARK: Coordinate scaling — the unit-tested boundary

    /// Convert a pixel-space coordinate to point-space using the device scale factor.
    /// **This is the only place pixel→point conversion happens in Harness.**
    /// Tested by `SimulatorDriverCoordinateTests`.
    static func toPoints(_ pixel: CGPoint, scaleFactor: CGFloat) -> CGPoint {
        guard scaleFactor > 0 else { return pixel }
        return CGPoint(x: pixel.x / scaleFactor, y: pixel.y / scaleFactor)
    }

    // MARK: Lifecycle

    func listDevices() async throws -> [SimulatorRef] {
        try Task.checkCancellation()
        let xcrun = try await requireXcrun()
        let result = try await processRunner.run(ProcessSpec(
            executable: xcrun,
            arguments: ["simctl", "list", "devices", "--json"],
            timeout: .seconds(10)
        ))
        return try Self.parseSimctlList(result.stdout)
    }

    func boot(_ ref: SimulatorRef) async throws {
        let xcrun = try await requireXcrun()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: xcrun,
                arguments: ["simctl", "boot", ref.udid],
                timeout: .seconds(60)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            // simctl returns non-zero when already booted; treat as success.
            let combined = so + " " + se
            if combined.contains("Unable to boot device in current state: Booted") {
                Self.logger.info("Simulator already booted: \(ref.udid, privacy: .public)")
                return
            }
            throw SimulatorError.bootFailed(detail: combined)
        }
    }

    func install(_ appBundle: URL, on ref: SimulatorRef) async throws {
        let xcrun = try await requireXcrun()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: xcrun,
                arguments: ["simctl", "install", ref.udid, appBundle.path],
                timeout: .seconds(120)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.installFailed(detail: so + se)
        }
    }

    func launch(bundleID: String, on ref: SimulatorRef) async throws {
        let xcrun = try await requireXcrun()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: xcrun,
                arguments: ["simctl", "launch", ref.udid, bundleID],
                timeout: .seconds(30)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.launchFailed(bundleID: bundleID, detail: so + se)
        }
    }

    func terminate(bundleID: String, on ref: SimulatorRef) async throws {
        let xcrun = try await requireXcrun()
        // simctl terminate returns non-zero if the app isn't running. Best-effort.
        _ = try? await processRunner.run(ProcessSpec(
            executable: xcrun,
            arguments: ["simctl", "terminate", ref.udid, bundleID],
            timeout: .seconds(15)
        ))
    }

    func erase(_ ref: SimulatorRef) async throws {
        let xcrun = try await requireXcrun()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: xcrun,
                arguments: ["simctl", "erase", ref.udid],
                timeout: .seconds(60)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.actionFailed(action: "erase", detail: so + se)
        }
    }

    // MARK: Screenshot

    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL {
        let xcrun = try await requireXcrun()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: xcrun,
                arguments: ["simctl", "io", ref.udid, "screenshot", url.path],
                timeout: .seconds(15)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.screenshotFailed(detail: so + se)
        }
        return url
    }

    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage {
        // Write to a temp file under app support; caller can choose their own
        // location via `screenshot(_:into:)` if they want durability.
        try HarnessPaths.ensureDirectory(HarnessPaths.appSupport)
        let tmp = HarnessPaths.appSupport.appendingPathComponent("tmp-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await screenshot(ref, into: tmp)
        guard let data = try? Data(contentsOf: tmp), let image = NSImage(data: data) else {
            throw SimulatorError.screenshotFailed(detail: "decode failed")
        }
        return image
    }

    // MARK: Input — coords are POINTS at this boundary

    func tap(at point: CGPoint, on ref: SimulatorRef) async throws {
        let idb = try await requireIDB()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: idb,
                arguments: ["ui", "tap", "\(Int(point.x))", "\(Int(point.y))", "--udid", ref.udid],
                timeout: .seconds(10)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.actionFailed(action: "tap", detail: so + se)
        }
    }

    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws {
        try await tap(at: point, on: ref)
        try? await Task.sleep(for: .milliseconds(80))
        try await tap(at: point, on: ref)
    }

    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws {
        let idb = try await requireIDB()
        let durationSeconds = Self.seconds(of: duration)
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: idb,
                arguments: [
                    "ui", "swipe",
                    "\(Int(from.x))", "\(Int(from.y))",
                    "\(Int(to.x))", "\(Int(to.y))",
                    "--udid", ref.udid,
                    "--duration", String(format: "%.2f", durationSeconds)
                ],
                timeout: .seconds(15)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.actionFailed(action: "swipe", detail: so + se)
        }
    }

    func type(_ text: String, on ref: SimulatorRef) async throws {
        let idb = try await requireIDB()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: idb,
                arguments: ["ui", "text", text, "--udid", ref.udid],
                timeout: .seconds(15)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.actionFailed(action: "type", detail: so + se)
        }
    }

    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws {
        let idb = try await requireIDB()
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: idb,
                arguments: ["ui", "button", button.rawValue, "--udid", ref.udid],
                timeout: .seconds(10)
            ))
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            throw SimulatorError.actionFailed(action: "pressButton", detail: so + se)
        }
    }

    // MARK: Companion cleanup

    /// pkill any `idb_companion` matching the supplied UDID AND remove the
    /// stale gRPC socket file at `/tmp/idb/<udid>_companion.sock`. Without
    /// the socket cleanup, killing the process alone leaves the socket file
    /// behind; the next idb invocation finds the dead socket, tries to
    /// connect to it (`[Errno 61] Connection refused`), and never falls
    /// through to spawning a fresh companion — every tap fails until the
    /// file is gone.
    ///
    /// Tolerates "no processes matched" silently (the success case on a
    /// fresh machine).
    func cleanupCompanion(udid: String) async {
        // 1. Kill any companion process attached to this UDID.
        let pkill = URL(fileURLWithPath: "/usr/bin/pkill")
        // -f matches against the full command line; idb_companion is started
        // with `--udid <UDID>` so this pattern is unambiguous.
        let pattern = "idb_companion.*\(udid)"
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: pkill,
                arguments: ["-f", pattern],
                timeout: .seconds(5)
            ))
            // Give the daemon a moment to release its grpc socket.
            try? await Task.sleep(for: .milliseconds(250))
            Self.logger.info("Killed orphan idb_companion for \(udid, privacy: .public)")
        } catch ProcessFailure.nonZeroExit(let code, _, _, _) where code == 1 {
            // pkill exit-1 = no processes matched. Normal case; fine.
        } catch {
            Self.logger.warning("cleanupCompanion (pkill) failed: \(error.localizedDescription, privacy: .public)")
        }

        // 2. Remove the stale unix-domain socket file. idb tries to connect
        // before considering a fresh spawn; an orphaned socket file makes
        // every tap fail with ECONNREFUSED.
        let socketPath = "/tmp/idb/\(udid)_companion.sock"
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                try FileManager.default.removeItem(atPath: socketPath)
                Self.logger.info("Removed stale companion socket \(socketPath, privacy: .public)")
            } catch {
                Self.logger.warning("cleanupCompanion (socket rm) failed at \(socketPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Health probe

    func probeIDB(_ ref: SimulatorRef, timeout: Duration) async -> Bool {
        guard let idb = try? await requireIDB() else { return false }
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: idb,
                arguments: ["list-targets", "--udid", ref.udid],
                timeout: timeout
            ))
            return true
        } catch {
            return false
        }
    }

    // MARK: Tool resolution

    private func requireXcrun() async throws -> URL {
        let tools = try await toolLocator.locateAll()
        guard let xcrun = tools.xcrun else {
            throw SimulatorError.xcrunUnavailable
        }
        return xcrun
    }

    private func requireIDB() async throws -> URL {
        let tools = try await toolLocator.locateAll()
        guard let idb = tools.idb else {
            throw SimulatorError.idbUnavailable
        }
        return idb
    }

    // MARK: Duration helpers

    private static func seconds(of duration: Duration) -> Double {
        // Duration → Double seconds. `Duration` is `(seconds, attoseconds)`.
        let comps = duration.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1_000_000_000_000_000_000.0
    }
}

// MARK: - simctl JSON parsing

extension SimulatorDriver {

    /// Parse `xcrun simctl list devices --json` output into typed `SimulatorRef` rows.
    /// Excludes shutdown / unavailable devices? No — we include all bootable iOS devices
    /// so the picker shows them; the boot path handles the "shutdown → boot" transition.
    static func parseSimctlList(_ data: Data) throws -> [SimulatorRef] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: Any] else {
            return []
        }

        var refs: [SimulatorRef] = []
        for (runtimeKey, value) in devicesByRuntime {
            guard runtimeKey.contains("iOS"),
                  let arr = value as? [[String: Any]] else { continue }

            let runtimeLabel = humanize(runtime: runtimeKey)

            for raw in arr {
                guard let udid = raw["udid"] as? String,
                      let name = raw["name"] as? String,
                      let isAvailable = raw["isAvailable"] as? Bool, isAvailable else {
                    continue
                }

                // Resolve point size + scale factor from the device name.
                // simctl unfortunately doesn't return them in the JSON, so we
                // map by name. Unknown devices fall back to a sensible default.
                let (pointSize, scale) = devicePointMetrics(forName: name)
                refs.append(SimulatorRef(
                    udid: udid,
                    name: name,
                    runtime: runtimeLabel,
                    pointSize: pointSize,
                    scaleFactor: scale
                ))
            }
        }
        return refs.sorted { $0.name < $1.name }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-4` → `iOS 18.4`.
    private static func humanize(runtime: String) -> String {
        guard let lastDot = runtime.lastIndex(of: ".") else { return runtime }
        let suffix = runtime[runtime.index(after: lastDot)...]
        return suffix.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "iOS ", with: "iOS ")
    }

    /// Hard-coded metrics for current iPhone simulators. Anything not in the table
    /// falls back to iPhone 16 Pro dimensions (430×932, scale 3). Future iPhones can
    /// be added here; sourced from Apple's Human Interface Guidelines.
    static func devicePointMetrics(forName name: String) -> (CGSize, CGFloat) {
        let n = name.lowercased()

        // Pro Max line — 6.7" / 6.9"
        if n.contains("pro max") {
            if n.contains("16") || n.contains("17") {
                return (CGSize(width: 440, height: 956), 3.0)
            }
            // 14/15 Pro Max
            return (CGSize(width: 430, height: 932), 3.0)
        }
        // Plus / Max line — 6.7"
        if n.contains("plus") || (n.contains("max") && !n.contains("pro")) {
            return (CGSize(width: 428, height: 926), 3.0)
        }
        // Pro line — 6.1" / 6.3"
        if n.contains("pro") {
            if n.contains("16") || n.contains("17") {
                return (CGSize(width: 402, height: 874), 3.0)
            }
            return (CGSize(width: 393, height: 852), 3.0)
        }
        // Mini
        if n.contains("mini") {
            return (CGSize(width: 375, height: 812), 3.0)
        }
        // SE / 8 / vintage
        if n.contains("se") || n.contains("8") {
            return (CGSize(width: 375, height: 667), 2.0)
        }
        // Default — modern non-Pro iPhone
        if n.contains("iphone 16") || n.contains("iphone 17") {
            return (CGSize(width: 393, height: 852), 3.0)
        }
        if n.contains("iphone 15") || n.contains("iphone 14") {
            return (CGSize(width: 390, height: 844), 3.0)
        }
        // Conservative fallback.
        return (CGSize(width: 393, height: 852), 3.0)
    }
}
