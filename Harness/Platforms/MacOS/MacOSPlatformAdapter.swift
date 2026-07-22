//
//  MacOSPlatformAdapter.swift
//  Harness
//
//  Drives the macOS run path: locate / build the .app, launch it via
//  NSWorkspace, hand RunCoordinator a `MacAppDriver`-backed session.
//
//  Two run modes:
//    - **Pre-built .app**: `Application.macAppBundlePath` points at an
//      existing bundle (e.g. `/System/Applications/TextEdit.app`). No
//      build step; we just launch it.
//    - **Project + scheme**: standard Xcode macOS build via `xcodebuild`
//      with `-destination "platform=macOS"`. Same `XcodeBuilder` actor
//      as the iOS path; the destination flag is what differs.
//

import Foundation
import AppKit
import os

struct MacOSPlatformAdapter: PlatformAdapter {

    static let logger = Logger(subsystem: "com.harness.app", category: "MacOSPlatformAdapter")

    let kind: PlatformKind = .macosApp
    let services: PlatformAdapterServices
    /// When true, `teardown` (and a failed/leaked start) QUITS the SUT.
    /// GUI runs leave this false — the user may want the app open for
    /// inspection after a run. The ui-session preparer sets it true so an
    /// autonomous QA session (end_ui_session, idle sweep, shutdownAll, or a
    /// failed/timed-out start) never litters the desktop with running apps.
    let terminatesOnTeardown: Bool

    init(services: PlatformAdapterServices, terminatesOnTeardown: Bool = false) {
        self.services = services
        self.terminatesOnTeardown = terminatesOnTeardown
    }

    func prepare(
        _ request: RunRequest,
        runID: UUID,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws -> RunSession {
        // Resolve the app bundle URL: pre-built path wins; project+scheme
        // builds otherwise.
        let bundleURL: URL
        let bundleID: String
        let displayLabel: String

        if let prebuiltPath = request.macAppBundlePath, !prebuiltPath.isEmpty {
            // Pre-built mode — skip xcodebuild entirely.
            let url = URL(fileURLWithPath: prebuiltPath)
            guard FileManager.default.fileExists(atPath: prebuiltPath) else {
                throw MacOSAdapterError.bundleNotFound(path: prebuiltPath)
            }
            guard let resolvedID = Self.bundleIdentifier(at: url) else {
                throw MacOSAdapterError.bundleIdentifierMissing(path: prebuiltPath)
            }
            bundleURL = url
            bundleID = resolvedID
            displayLabel = url.deletingPathExtension().lastPathComponent
        } else {
            // Project + scheme mode — build for macOS.
            continuation.yield(.buildStarted)
            let result = try await services.xcodeBuilder.build(
                project: request.project.path,
                scheme: request.project.scheme,
                runID: runID
            )
            continuation.yield(.buildCompleted(appBundle: result.appBundle, bundleID: result.bundleIdentifier))
            bundleURL = result.appBundle
            bundleID = result.bundleIdentifier
            displayLabel = request.project.displayName
        }

        // Launch via NSWorkspace. The contained backend (default) launches
        // WITHOUT activation so the run never steals the user's focus;
        // only legacy HID needs the SUT foregrounded so global-HID events
        // land on it. Backend is resolved once, from HARNESS_MACOS_INPUT.
        let backend = MacInputBackendKind.fromEnvironment(ProcessInfo.processInfo.environment)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = backend.activatesOnLaunch
        cfg.addsToRecentItems = false
        let runningApp = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
        Self.logger.info("Launched macOS app pid=\(runningApp.processIdentifier, privacy: .public) bundleID=\(bundleID, privacy: .public) backend=\(backend.rawValue, privacy: .public) activates=\(backend.activatesOnLaunch, privacy: .public)")

        // Wait for the SUT to expose a frontmost window. Bail with a clear
        // error if it never does — the run can't proceed without one.
        let credential = await services.resolveCredentialBinding(for: request)
        // Bind the driver to the launched instance's pid — every SUT op
        // (terminate, foreground, window lookup, input) scopes to THIS pid,
        // never a bundle-id match, so a same-bundle-id stranger (the dev's
        // own copy) is never touched.
        let driver = MacAppDriver(bundleIdentifier: bundleID, appBundleURL: bundleURL, credential: credential, backend: backend, processIdentifier: runningApp.processIdentifier)
        var pointSize = CGSize(width: 1280, height: 800) // safe default until first capture refines it
        var ready = false
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(150))
            let probe = try? await Self.probeWindowSize(driver: driver)
            if let p = probe {
                pointSize = p
                ready = true
                break
            }
        }
        if !ready {
            // The app launched but never showed a window. For a ui-session
            // this is a failed start — quit the SUT before throwing so a
            // headless / broken app doesn't leak onto the desktop. GUI runs
            // (terminatesOnTeardown == false) keep the legacy behavior of
            // leaving it for the user to inspect.
            if terminatesOnTeardown { await driver.terminateApp() }
            throw MacOSAdapterError.windowNeverAppeared(bundleID: bundleID)
        }

        // Borrow the iOS RunEvent.simulatorReady to mean "target is ready
        // to drive" — RunSessionView reads it as the cue to start the
        // mirror polling. Phase 2.5 can introduce a platform-neutral
        // `targetReady` event; for now we synthesise a SimulatorRef so
        // the existing UI path keeps working.
        let pseudoSim = SimulatorRef(
            udid: "macos-\(bundleID)",
            name: displayLabel,
            runtime: "macOS",
            pointSize: pointSize,
            scaleFactor: 1.0
        )
        continuation.yield(.simulatorReady(pseudoSim))

        return RunSession(
            kind: .macosApp,
            driver: driver,
            pointSize: pointSize,
            bundleIdentifier: bundleID,
            appBundleURL: bundleURL,
            displayLabel: displayLabel,
            credentialLabel: credential?.label,
            credentialUsername: credential?.username
        )
    }

    func teardown(_ session: RunSession) async {
        // GUI runs deliberately do NOT terminate the SUT — for pre-built
        // apps the user might want to keep the app open for inspection, and
        // the driver's `relaunchForNewLeg()` handles the "start clean" path
        // between chain legs. A ui-session sets `terminatesOnTeardown` so
        // that ending it (end_ui_session, idle sweep, shutdownAll) quits the
        // crew-built app and never litters the desktop. Reuses the driver's
        // own terminate → force-terminate machinery; idempotent, so a
        // double teardown or an already-quit app is a safe no-op.
        guard terminatesOnTeardown else { return }
        guard let driver = session.driver as? MacAppDriver else { return }
        await driver.terminateApp()
    }

    func toolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        ToolSchema.macOSToolDefinitions(cacheControl: cacheControl)
    }

    func toolNames() -> [String] { ToolSchema.macOSToolNames }

    func systemPromptContext(deviceLabel: String) async throws -> String {
        // Loaded from `docs/PROMPTS/platforms/macos.md` as a bundle resource.
        // Falls back to an inline string if the resource is missing —
        // we'd rather degrade than crash the run.
        if let library = services.promptLibrary as? PromptLibrary {
            if let bundleURL = library.bundle.url(forResource: "macos", withExtension: "md", subdirectory: "PROMPTS/platforms"),
               let text = try? String(contentsOf: bundleURL, encoding: .utf8) {
                return text
            }
        }
        return Self.fallbackContext
    }

    private static let fallbackContext = """
    OVERRIDE — PLATFORM CONTEXT.

    You are testing a macOS app, not iOS. The screenshots show the contents of one window. You can:
    - Click (tap) at any point to operate buttons, fields, menu items, links, list rows.
    - Double-click to open files, expand folders, or trigger default actions.
    - Right-click to open contextual menus.
    - Type text into focused fields.
    - Use keyboard shortcuts via key_shortcut — most macOS UX leans on Cmd+keys.
    - Scroll lists, panes, and document content.

    There is no Home button, no Tab Bar, no swipe-from-edge gesture. Coordinates are window-local in points (top-left origin within the captured window).
    """

    /// Best-effort resolution of an `.app`'s `CFBundleIdentifier`. Reads
    /// `Contents/Info.plist` directly so we don't need NSWorkspace.
    static func bundleIdentifier(at url: URL) -> String? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    /// Quick probe — capture once and discard the PNG; we just want the
    /// resolved point size. Times out via the surrounding loop in
    /// `prepare(...)`.
    static func probeWindowSize(driver: MacAppDriver) async throws -> CGSize? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-mac-probe-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let meta = try await driver.screenshot(into: tmp)
        return meta.pointSize
    }
}

enum MacOSAdapterError: Error, Sendable, LocalizedError {
    case bundleNotFound(path: String)
    case bundleIdentifierMissing(path: String)
    case windowNeverAppeared(bundleID: String)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound(let path):
            return "macOS app bundle not found at \(path). Pick a valid .app or check the path in Application settings."
        case .bundleIdentifierMissing(let path):
            return "Couldn't read CFBundleIdentifier from \(path)/Contents/Info.plist."
        case .windowNeverAppeared(let bid):
            return "macOS app '\(bid)' launched but never showed a visible window. Make sure Harness has Screen Recording permission and the app opens a window on launch."
        }
    }
}
