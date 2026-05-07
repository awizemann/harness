//
//  IOSPlatformAdapter.swift
//  Harness
//
//  Wraps the existing `XcodeBuilder` + `SimulatorDriver` (+ WebDriverAgent)
//  pieces behind the platform-neutral `PlatformAdapter` protocol. Phase 1's
//  iOS path was the one true path; this is a structural move with no
//  behaviour change.
//
//  See `Harness/Services/SimulatorDriver.swift` for the iOS-specific
//  implementation details and `https://github.com/awizemann/harness/wiki/Simulator-Driver`
//  for the per-method command mapping.
//

import Foundation
import CoreGraphics
import AppKit

struct IOSPlatformAdapter: PlatformAdapter {

    let kind: PlatformKind = .iosSimulator
    let services: PlatformAdapterServices

    init(services: PlatformAdapterServices) {
        self.services = services
    }

    func prepare(
        _ request: RunRequest,
        runID: UUID,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws -> RunSession {
        // Build → boot → install → launch → start input session. Identical
        // to the pre-Phase-2 RunCoordinator sequence, just lifted here.
        continuation.yield(.buildStarted)
        let build = try await services.xcodeBuilder.build(
            project: request.project.path,
            scheme: request.project.scheme,
            runID: runID
        )
        continuation.yield(.buildCompleted(appBundle: build.appBundle, bundleID: build.bundleIdentifier))

        // WDA pkill defends against an orphan xcodebuild from a prior crash.
        await services.simulatorDriver.cleanupWDA(udid: request.simulator.udid)
        try await services.simulatorDriver.boot(request.simulator)
        try await services.simulatorDriver.install(build.appBundle, on: request.simulator)
        try await services.simulatorDriver.launch(bundleID: build.bundleIdentifier, on: request.simulator)
        try await services.simulatorDriver.startInputSession(request.simulator)
        continuation.yield(.simulatorReady(request.simulator))

        let credential = await services.resolveCredentialBinding(for: request)
        let driver = IOSSimDriver(
            ref: request.simulator,
            simulatorDriver: services.simulatorDriver,
            appBundle: build.appBundle,
            bundleIdentifier: build.bundleIdentifier,
            credential: credential
        )
        return RunSession(
            kind: .iosSimulator,
            driver: driver,
            pointSize: request.simulator.pointSize,
            bundleIdentifier: build.bundleIdentifier,
            appBundleURL: build.appBundle,
            displayLabel: "\(request.simulator.name) · \(request.simulator.runtime)",
            credentialLabel: credential?.label,
            credentialUsername: credential?.username
        )
    }

    func teardown(_ session: RunSession) async {
        await services.simulatorDriver.endInputSession()
    }

    func toolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        ToolSchema.iOSToolDefinitions(cacheControl: cacheControl)
    }

    func toolNames() -> [String] { ToolSchema.iOSToolNames }

    func systemPromptContext(deviceLabel: String) async throws -> String {
        // The existing system prompt is iOS-flavoured already. For iOS,
        // there's nothing extra to inject — return empty so the prompt
        // assembler skips the prefix. macOS / web adapters return real
        // override blocks.
        return ""
    }
}

/// `UXDriving` wrapper around the iOS `SimulatorDriving` actor. Carries the
/// per-run `SimulatorRef`, the build artifact, and a few derived values so
/// `RunCoordinator` doesn't have to thread the whole `RunRequest` into
/// every call.
struct IOSSimDriver: UXDriving {
    let ref: SimulatorRef
    let simulatorDriver: any SimulatorDriving
    let appBundle: URL
    let bundleIdentifier: String
    /// V5 — the run's pre-staged credential, resolved once at run start.
    /// `nil` means no credential is staged for this run; `fill_credential`
    /// is a soft no-op (the agent should emit `auth_required` instead).
    let credential: CredentialBinding?

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        _ = try await simulatorDriver.screenshot(ref, into: url)
        // PNG is at pixel resolution per the iOS coordinate-space rule
        // (see SimulatorDriver.swift header). Compute pixel size from
        // the pointSize × scaleFactor relationship.
        let pixel = ref.pixelSize
        return ScreenshotMetadata(pixelSize: pixel, pointSize: ref.pointSize)
    }

    func execute(_ call: ToolCall) async throws {
        switch call.input {
        case .tap(let x, let y):
            try await simulatorDriver.tap(at: CGPoint(x: x, y: y), on: ref)
        case .doubleTap(let x, let y):
            try await simulatorDriver.doubleTap(at: CGPoint(x: x, y: y), on: ref)
        case .swipe(let x1, let y1, let x2, let y2, let ms):
            try await simulatorDriver.swipe(
                from: CGPoint(x: x1, y: y1),
                to: CGPoint(x: x2, y: y2),
                duration: .milliseconds(ms),
                on: ref
            )
        case .type(let text):
            try await simulatorDriver.type(text, on: ref)
        case .pressButton(let button):
            try await simulatorDriver.pressButton(button, on: ref)
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .readScreen, .noteFriction, .markGoalDone:
            // Non-action tools — RunCoordinator handles them upstream.
            return
        case .fillCredential(let field):
            // No staged credential → soft no-op. The agent will see no
            // visible change in the next screenshot and is expected to
            // emit `auth_required` friction. We deliberately don't throw
            // here because the run might still be useful for the
            // pre-login surfaces.
            guard let credential else { return }
            let text = field == .username ? credential.username : credential.password
            try await simulatorDriver.type(text, on: ref)
        case .rightClick, .keyShortcut, .scroll, .navigate, .back, .forward, .refresh:
            // These tool variants belong to other platforms. The iOS
            // adapter never advertises them via toolDefinitions, so an
            // emission here is a contract bug — surface it loudly.
            throw UXDriverError.unsupportedTool(name: call.tool.rawValue, platform: .iosSimulator)
        }
    }

    func relaunchForNewLeg() async throws {
        try await simulatorDriver.terminate(bundleID: bundleIdentifier, on: ref)
        try await simulatorDriver.install(appBundle, on: ref)
        try await simulatorDriver.launch(bundleID: bundleIdentifier, on: ref)
    }
}
