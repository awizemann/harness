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

    /// V0.3.2 — probe the AX tree for actionable elements and return
    /// them as 1-indexed `InteractiveMark`s in reading order. Used by
    /// the iOS `screenshot(into:)` pipeline to build the Set-of-Mark
    /// scaffolding the LLM sees. Empty on probe failure / no session.
    func probeInteractiveElements(_ ref: SimulatorRef) async -> [InteractiveMark]

    /// V0.3.2 — dispatch a tap to the **center of the visible portion**
    /// of the mark with `id`'s bounding rect, after clipping the rect
    /// to the simulator's viewport so a partly-off-screen mark still
    /// clicks the right element. Throws when `id` isn't in the most
    /// recent probe's cache (stale-id case the model should recover
    /// from on the next turn's fresh probe).
    func tapMark(id: Int, on ref: SimulatorRef) async throws
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
        let spec = ProcessSpec(
            executable: xcrun,
            arguments: ["simctl", "io", ref.udid, "screenshot", url.path],
            timeout: .seconds(15)
        )
        // simctl's behavior on Xcode 17 / iOS 26 reliably writes the
        // PNG and prints "Detected file type 'PNG' from extension" +
        // "Wrote screenshot to: …" but the exit code can flake to
        // non-zero on rapid back-to-back invocations (settle gate
        // polls + per-step capture). Strategy:
        //
        //   1. Run simctl. If it exits 0 → success.
        //   2. If it exits non-zero BUT the file exists on disk AND
        //      is non-empty → success. simctl's stderr warning is
        //      not a real failure; the PNG is valid.
        //   3. If the file is missing / empty, retry once after
        //      200ms. A second failure propagates.
        do {
            _ = try await processRunner.run(spec)
            return url
        } catch ProcessFailure.nonZeroExit {
            if Self.fileLooksLikePNG(at: url) {
                return url
            }
            // No file on disk → retry once.
            try? await Task.sleep(for: .milliseconds(200))
            do {
                _ = try await processRunner.run(spec)
                return url
            } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
                if Self.fileLooksLikePNG(at: url) {
                    return url
                }
                throw SimulatorError.screenshotFailed(detail: (so + se).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// True when `url` exists on disk and is at least ~256 bytes (a
    /// valid PNG header + a non-empty payload). Used by the
    /// screenshot path to tolerate simctl's non-zero exits on
    /// runs where the file did actually get written.
    nonisolated private static func fileLooksLikePNG(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size >= 256 else {
            return false
        }
        // Could verify the 8-byte PNG signature but the size check
        // is sufficient — simctl never writes a partial file.
        return true
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
            // 45s was the previous default; bumped to 120s after
            // CLI iOS runs on iOS 26.2 hit timeouts during the
            // initial xcodebuild-test-without-building → WDA boot
            // window on warm-but-not-recently-used simulators.
            // Cost: idle waits at most this long if WDA truly never
            // comes up. Worth the extra runway on cold-ish caches.
            try await wdaClient.waitForReady(timeout: .seconds(120))
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

    // MARK: Set-of-Mark

    /// Per-UDID cache of the most recent probe's marks. Refreshed on
    /// each `probeInteractiveElements(_:)` call so the next `tapMark`
    /// resolves against the same DOM state the model just saw.
    /// Keyed by UDID so a multi-sim run keeps each device's marks
    /// straight; in practice we run one simulator per coordinator.
    private var lastMarks: [String: [InteractiveMark]] = [:]

    func probeInteractiveElements(_ ref: SimulatorRef) async -> [InteractiveMark] {
        do {
            let marks = try await wdaClient.probeInteractiveElements()
            lastMarks[ref.udid] = marks
            return marks
        } catch {
            // Probe failure isn't run-fatal — the agent can still call
            // `tap(x, y)` with no scaffolding. Log + fall through with
            // empty marks.
            Self.logger.warning("WDA SoM probe failed: \(error.localizedDescription, privacy: .public)")
            lastMarks[ref.udid] = []
            return []
        }
    }

    func tapMark(id: Int, on ref: SimulatorRef) async throws {
        guard let mark = (lastMarks[ref.udid] ?? []).first(where: { $0.id == id }) else {
            throw SimulatorError.actionFailed(
                action: "tapMark",
                detail: "id \(id) wasn't in the latest screenshot's mark set. The page may have changed; the next screenshot will refresh the marks."
            )
        }
        // Clip the mark rect to the visible viewport (same logic as
        // the web driver — see `WebDriver.dispatchMarkClick`). The
        // clamp guarantees the tap coordinate sits on a hit-testable
        // pixel even when the element extends past the screen.
        let inset: CGFloat = 4
        let viewportW = ref.pointSize.width
        let viewportH = ref.pointSize.height
        let visibleMinX = max(mark.rect.minX, 0) + inset
        let visibleMinY = max(mark.rect.minY, 0) + inset
        let visibleMaxX = min(mark.rect.maxX, viewportW) - inset
        let visibleMaxY = min(mark.rect.maxY, viewportH) - inset
        let cx: CGFloat
        let cy: CGFloat
        if visibleMaxX > visibleMinX && visibleMaxY > visibleMinY {
            cx = (visibleMinX + visibleMaxX) / 2
            cy = (visibleMinY + visibleMaxY) / 2
        } else {
            cx = mark.rect.midX
            cy = mark.rect.midY
        }
        Self.logger.info("tap_mark(\(id, privacy: .public)) → label=\"\(mark.label, privacy: .public)\" role=\(mark.role, privacy: .public) rect=(\(Int(mark.rect.minX), privacy: .public),\(Int(mark.rect.minY), privacy: .public),\(Int(mark.rect.width), privacy: .public),\(Int(mark.rect.height), privacy: .public)) → tap(\(Int(cx), privacy: .public),\(Int(cy), privacy: .public))")
        if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let line = "[WDA] tap_mark(\(id)) label=\"\(mark.label)\" role=\(mark.role) rect=(\(Int(mark.rect.minX)),\(Int(mark.rect.minY)),\(Int(mark.rect.width)),\(Int(mark.rect.height))) → tap(\(Int(cx)),\(Int(cy)))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        try await wdaClient.tap(at: CGPoint(x: cx, y: cy))
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
