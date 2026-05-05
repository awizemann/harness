//
//  SimulatorDriver.swift
//  Harness
//
//  Wraps `xcrun simctl` (lifecycle) and a WebDriverAgent test runner (input).
//  The standard at `standards/12-simulator-control.md` is the invariants
//  reference. The per-method command mapping lives in
//  `https://github.com/awizemann/harness/wiki/Simulator-Driver`.
//
//  Coordinate-space rule (the #1 expected failure mode): screenshots from
//  `simctl io booted screenshot` are at PIXEL resolution. WDA's coordinate
//  endpoints take POINTS. `SimulatorDriver` divides any pixel-derived
//  coordinate by `SimulatorRef.scaleFactor` exactly once at the boundary
//  into `WDAClient`. Every other call site uses points. The conversion is
//  unit-tested.
//
//  WDA replaced idb in Phase 5 because idb's HID injection on iOS 26+
//  rendered the green tap dot but never reached the responder chain. WDA
//  goes through `XCUICoordinate.tap` etc., so taps fire UIKit events the
//  same way a real touch would.
//

import Foundation
import AppKit
import os

// MARK: - Errors

enum SimulatorError: Error, Sendable, LocalizedError {
    case wdaUnavailable
    case xcrunUnavailable
    case deviceNotFound(udid: String)
    case bootFailed(detail: String)
    case installFailed(detail: String)
    case launchFailed(bundleID: String, detail: String)
    case screenshotFailed(detail: String)
    case actionFailed(action: String, detail: String)
    case inputSessionNotStarted

    var errorDescription: String? {
        switch self {
        case .wdaUnavailable:
            return "WebDriverAgent isn't built yet for this iOS version. Open Settings → 'Build WebDriverAgent' to fix."
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
        case .inputSessionNotStarted:
            return "Input session was not started. Call `startInputSession(_:)` after `launch(_:)`."
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

    /// Build (if needed) and launch the WDA test runner, then open a session
    /// so the input methods can target it. Call after `launch(_:)`.
    func startInputSession(_ ref: SimulatorRef) async throws

    /// Tear down the active WDA session and runner. Idempotent — safe to call
    /// even if `startInputSession` was never called or already ended.
    func endInputSession() async

    /// Kill any orphan xcodebuild test runner attached to this UDID. Called
    /// at run start so a stale runner from a prior crash doesn't intercept
    /// our session.
    func cleanupWDA(udid: String) async
}

// MARK: - Implementation

actor SimulatorDriver: SimulatorDriving {

    private static let logger = Logger(subsystem: "com.harness.app", category: "SimulatorDriver")

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating
    private let wdaBuilder: any WDABuilding
    private let wdaRunner: any WDARunning
    private let wdaClient: any WDAClienting

    /// Active runner handle. Non-nil between `startInputSession` and
    /// `endInputSession`. Holds the xcodebuild test process Task.
    private var activeRunner: WDARunnerHandle?

    init(
        processRunner: any ProcessRunning,
        toolLocator: any ToolLocating,
        wdaBuilder: any WDABuilding,
        wdaRunner: any WDARunning,
        wdaClient: any WDAClienting
    ) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
        self.wdaBuilder = wdaBuilder
        self.wdaRunner = wdaRunner
        self.wdaClient = wdaClient
    }

    // MARK: Coordinate scaling — the unit-tested boundary

    /// Convert a pixel-space coordinate to point-space using the device scale factor.
    /// **This is the only place pixel→point conversion happens in Harness.**
    /// Tested by `SimulatorDriverCoordinateTests`.
    static func toPoints(_ pixel: CGPoint, scaleFactor: CGFloat) -> CGPoint {
        guard scaleFactor > 0 else { return pixel }
        return CGPoint(x: pixel.x / scaleFactor, y: pixel.y / scaleFactor)
    }

    // MARK: Lifecycle (simctl)

    nonisolated func listDevices() async throws -> [SimulatorRef] {
        try Task.checkCancellation()
        let xcrun = try await requireXcrun()
        let result = try await processRunner.run(ProcessSpec(
            executable: xcrun,
            arguments: ["simctl", "list", "devices", "--json"],
            timeout: .seconds(10)
        ))
        return try Self.parseSimctlList(result.stdout)
    }

    nonisolated func boot(_ ref: SimulatorRef) async throws {
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

    nonisolated func install(_ appBundle: URL, on ref: SimulatorRef) async throws {
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

    nonisolated func launch(bundleID: String, on ref: SimulatorRef) async throws {
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

    nonisolated func terminate(bundleID: String, on ref: SimulatorRef) async throws {
        let xcrun = try await requireXcrun()
        // simctl terminate returns non-zero if the app isn't running. Best-effort.
        _ = try? await processRunner.run(ProcessSpec(
            executable: xcrun,
            arguments: ["simctl", "terminate", ref.udid, bundleID],
            timeout: .seconds(15)
        ))
    }

    nonisolated func erase(_ ref: SimulatorRef) async throws {
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

    nonisolated func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL {
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

    nonisolated func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage {
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

    nonisolated func tap(at point: CGPoint, on ref: SimulatorRef) async throws {
        do {
            try await wdaClient.tap(at: point)
        } catch {
            throw SimulatorError.actionFailed(action: "tap", detail: error.localizedDescription)
        }
    }

    nonisolated func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws {
        do {
            try await wdaClient.doubleTap(at: point)
        } catch {
            throw SimulatorError.actionFailed(action: "doubleTap", detail: error.localizedDescription)
        }
    }

    nonisolated func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws {
        do {
            try await wdaClient.swipe(from: from, to: to, duration: duration)
        } catch {
            throw SimulatorError.actionFailed(action: "swipe", detail: error.localizedDescription)
        }
    }

    nonisolated func type(_ text: String, on ref: SimulatorRef) async throws {
        do {
            try await wdaClient.type(text)
        } catch {
            throw SimulatorError.actionFailed(action: "type", detail: error.localizedDescription)
        }
    }

    nonisolated func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws {
        do {
            try await wdaClient.pressButton(button)
        } catch {
            throw SimulatorError.actionFailed(action: "pressButton", detail: error.localizedDescription)
        }
    }

    // MARK: Input session

    func startInputSession(_ ref: SimulatorRef) async throws {
        try Task.checkCancellation()
        // Build (or pull from cache) the WDA xctestrun for this iOS version.
        let buildResult = try await wdaBuilder.ensureBuilt(forSimulator: ref)

        // Spawn the xcodebuild test runner. It comes up on port 8100 by default.
        let handle = try await wdaRunner.start(
            udid: ref.udid,
            xctestrun: buildResult.xctestrun,
            port: WDARunner.defaultPort
        )

        // Wait for /status before opening a session.
        do {
            try await wdaClient.waitForReady(timeout: .seconds(45))
            _ = try await wdaClient.createSession()
        } catch {
            // Don't leak the xcodebuild runner on session-open failure.
            await wdaRunner.stop(handle)
            throw error
        }
        activeRunner = handle
        Self.logger.info("WDA input session started for \(ref.udid, privacy: .public)")
    }

    func endInputSession() async {
        await wdaClient.endSession()
        if let handle = activeRunner {
            await wdaRunner.stop(handle)
        }
        activeRunner = nil
    }

    nonisolated func cleanupWDA(udid: String) async {
        await wdaRunner.cleanupOrphans(udid: udid)
    }

    // MARK: Tool resolution

    nonisolated private func requireXcrun() async throws -> URL {
        let tools = try await toolLocator.locateAll()
        guard let xcrun = tools.xcrun else {
            throw SimulatorError.xcrunUnavailable
        }
        return xcrun
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
