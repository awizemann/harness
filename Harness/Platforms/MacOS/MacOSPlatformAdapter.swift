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

    /// W26 — environment applied to the launched app, and the arguments it
    /// is launched with. Both go to `NSWorkspace.OpenConfiguration`, which
    /// hands them to the new process directly: there is no shell on this
    /// path, so nothing is expanded, word-split, or interpolated. They come
    /// from the session's caller (an MCP client's flow), and they apply to a
    /// LOCALLY BUILT app the same caller pointed us at — this widens what
    /// that app does with its own launch, and nothing else. The values may
    /// be secrets (a fixture-mode token), so nothing here logs them; the
    /// launch line records key NAMES only.
    let launchEnvironment: [String: String]
    let launchArguments: [String]

    init(
        services: PlatformAdapterServices,
        terminatesOnTeardown: Bool = false,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = []
    ) {
        self.services = services
        self.terminatesOnTeardown = terminatesOnTeardown
        self.launchEnvironment = launchEnvironment
        self.launchArguments = launchArguments
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
        let credential = await services.resolveCredentialBinding(for: request)

        func launch(freshInstance: Bool) async throws -> NSRunningApplication {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = backend.activatesOnLaunch
            cfg.addsToRecentItems = false
            // W26. Applied straight to the launch — no shell, no
            // interpolation: LaunchServices carries the pairs into the new
            // process's environment and argv verbatim.
            if !launchEnvironment.isEmpty { cfg.environment = launchEnvironment }
            if !launchArguments.isEmpty { cfg.arguments = launchArguments }
            cfg.createsNewApplicationInstance = freshInstance
            return try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
        }

        var driver: MacAppDriver?
        var pointSize = CGSize(width: 1280, height: 800) // safe default until first capture refines it
        var lastPID: pid_t = 0

        // WB-23 — one bounded retry around the whole launch.
        //
        // The failure this fixes: end a macOS session and immediately start
        // another on the same bundle id. The previous instance is still
        // winding down, LaunchServices hands back THAT dying process rather
        // than starting a new one, and the window we then wait for belongs to
        // a pid that is on its way out — reported as "launched but never
        // showed a visible window", which describes the symptom and none of
        // the cause. Attempt 2 waits for every same-bundle-id instance to
        // actually exit and then forces a genuinely new process.
        //
        // The wait is bounded and only happens on the failure path, so a
        // legitimately running copy of the app (a developer's own) costs a
        // normal start nothing.
        // WB-25 — which wait ran out, so the failure can name it.
        var lastPhase: MacLaunchSettle.Phase = .windowReady
        for attempt in 1...2 {
            if attempt == 2 {
                lastPhase = .previousInstanceExit
                let cleared = await MacLaunchSettle.awaitQuiet(
                    stillRunning: { !Self.livePIDs(bundleID: bundleID).isEmpty }
                )
                Self.logger.info("macOS start retry for \(bundleID, privacy: .public): previous instances cleared=\(cleared, privacy: .public)")
                if !cleared {
                    // The predecessor is still up. Relaunch anyway (it may be
                    // a stranger's copy, which is allowed to run forever) but
                    // remember that THIS is what ran out, so a subsequent
                    // window failure isn't blamed on the app's drawing.
                    Self.logger.info("macOS start retry for \(bundleID, privacy: .public): predecessor still live after \(MacLaunchSettle.maxWaitMs, privacy: .public)ms")
                } else {
                    lastPhase = .windowReady
                }
            }
            // The race shows up here as well as later: while the previous
            // instance is winding down, LaunchServices can refuse the open
            // outright ("a miscellaneous error occurred") rather than hand
            // back the dying process. Attempt 1 swallows that so attempt 2 —
            // which waits for the field to clear first — gets its turn;
            // attempt 2's failure is the caller's answer.
            let runningApp: NSRunningApplication
            do {
                // WB-25 — a genuinely new process from attempt 1, but ONLY
                // where this adapter owns the app's lifecycle.
                //
                // Attempt 1 used to launch with `createsNewApplicationInstance
                // = false` always, and under a back-to-back re-run
                // LaunchServices answered that by ACTIVATING the previous
                // instance and handing its `NSRunningApplication` back. The
                // start then "succeeded" — a window was found, because the
                // dying app still had one — and the session bound to a pid on
                // its way out, driving the predecessor's window with the
                // PREDECESSOR'S environment. A session's fixture-mode env was
                // silently the last run's, and the failure surfaced later and
                // somewhere else. `relaunchForNewLeg()` has forced a fresh
                // instance since WB-23 for exactly this reason.
                //
                // Scoped to `terminatesOnTeardown` because that flag is
                // precisely "this run quits the app when it ends". A GUI run
                // deliberately leaves the SUT up for the user to inspect, so
                // forcing a new process there would stack a fresh copy beside
                // every previous one with nothing ever reaping them — and
                // would take an app that is not multi-instance safe (a shared
                // store, a lock file) somewhere it never used to go on a first
                // attempt. GUI runs keep the reuse they had; the retry path
                // still forces a fresh instance for both.
                runningApp = try await launch(freshInstance: terminatesOnTeardown || attempt == 2)
            } catch {
                Self.logger.info("macOS launch attempt \(attempt, privacy: .public) for \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == 1 { continue }
                throw error
            }
            lastPID = runningApp.processIdentifier
            Self.logger.info("Launched macOS app pid=\(lastPID, privacy: .public) bundleID=\(bundleID, privacy: .public) backend=\(backend.rawValue, privacy: .public) activates=\(backend.activatesOnLaunch, privacy: .public) attempt=\(attempt, privacy: .public) env_keys=\(launchEnvironment.keys.sorted().joined(separator: ","), privacy: .public) args=\(launchArguments.count, privacy: .public)")

            // Bind the driver to the launched instance's pid — every SUT op
            // (terminate, foreground, window lookup, input) scopes to THIS
            // pid, never a bundle-id match, so a same-bundle-id stranger
            // (the dev's own copy) is never touched.
            let candidate = MacAppDriver(
                bundleIdentifier: bundleID,
                appBundleURL: bundleURL,
                credential: credential,
                backend: backend,
                processIdentifier: lastPID,
                launchEnvironment: launchEnvironment,
                launchArguments: launchArguments
            )
            // WB-25 — wait for a window that has APPEARED and STOPPED MOVING,
            // not merely for the first capture that succeeds. Under a rapid
            // re-run the first successful capture is routinely a window the
            // app has created but not laid out, and the session's opening
            // observation then reads a half-assembled screen.
            let settled = await MacLaunchSettle.awaitReadyWindow(
                alive: { !(NSRunningApplication(processIdentifier: lastPID)?.isTerminated ?? true) },
                reading: { await Self.probeWindowReading(driver: candidate) }
            )
            // The window wait reads the CG window list, which needs no Screen
            // Recording grant — so it would happily declare a window ready on
            // a machine that cannot capture it, and the failure would move to
            // the caller's first `observe_ui` with none of the launch-time
            // context. One real capture, once, keeps the grant check where it
            // has always been and where the error message still points.
            if let settled, await Self.canCapture(driver: candidate) {
                pointSize = settled.size
                driver = candidate
                break
            }
            // The app launched but never showed a window. A non-final
            // attempt's instance is ALWAYS quit — it showed no window, so
            // there is nothing in it for anyone to inspect, and leaving it
            // running would mean the retry launches a second copy beside a
            // wedged first one. Only the FINAL failure keeps the legacy GUI
            // behaviour of leaving the app up for the user.
            if attempt < 2 || terminatesOnTeardown { await candidate.terminateApp() }
        }

        guard let driver else {
            throw MacOSAdapterError.windowNeverAppeared(bundleID: bundleID, phase: lastPhase)
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

    /// The pids of every running instance of `bundleID`, terminated ones
    /// excluded. Used ONLY on the retry path, to tell "the previous instance
    /// is still quitting" from "the app is genuinely broken".
    static func livePIDs(bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
    }

    /// Can this driver actually CAPTURE the window it just found? Window
    /// enumeration works without the Screen Recording grant; capture does not.
    /// Run once, after the window has settled, so a start still fails at
    /// launch — with the message that names the grant — rather than succeeding
    /// into a session whose every observation will fail.
    static func canCapture(driver: MacAppDriver) async -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-mac-probe-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (try? await driver.screenshot(into: tmp)) != nil
    }

    /// One window reading for `MacLaunchSettle.awaitReadyWindow`: which CG
    /// window is front and how big it is. Deliberately does NOT capture an
    /// image — the launch wait polls this repeatedly and only needs geometry,
    /// so paying for a PNG encode per poll would be pure waste. nil means "no
    /// window yet" and is the wait's cue to keep polling.
    static func probeWindowReading(driver: MacAppDriver) async -> MacLaunchSettle.WindowReading? {
        guard let info = await driver.frontWindow() else { return nil }
        return MacLaunchSettle.WindowReading(
            windowNumber: info.windowNumber,
            size: CGSize(width: info.bounds.width, height: info.bounds.height)
        )
    }
}

/// The bounded settle that stands between a session ending and the next one
/// starting on the same app (WB-23, strengthened by WB-25).
///
/// Pure but for the closures it is handed, so the suite can pin the timing
/// contract — polls, gives up, reports honestly which and at WHICH phase —
/// without launching or killing anything.
enum MacLaunchSettle {
    /// Which of the two waits a start was in when it ran out of budget. The
    /// failure message names it: "still quitting" and "never drew a window"
    /// are different problems with different fixes, and a caller told only
    /// that the start failed has to guess which one they have.
    enum Phase: String, Sendable {
        case previousInstanceExit = "waiting for the previous instance to exit"
        case windowReady = "waiting for the new instance's window to appear and stop moving"
    }

    /// How long to wait for the previous instance(s) to actually exit.
    ///
    /// WB-23 set this to 4s, reasoning that `terminate()` → `forceTerminate()`
    /// takes at most ~2s in `MacAppDriver.terminateApp`. WB-25 measured
    /// back-to-back sessions on one bundle id breaking 2 runs in 5 anyway: a
    /// SwiftUI app's teardown (window server handoff, LaunchServices
    /// bookkeeping) routinely outlives the pid's own death rattle, and 4s
    /// landed right on top of the distribution's tail. 10s clears it with room
    /// to spare and costs a healthy start nothing — the wait ends the moment
    /// the field is clear.
    static let maxWaitMs = 10_000
    static let pollIntervalMs = 100

    /// Poll `stillRunning` until it answers false or the budget expires.
    ///
    /// Returns TRUE when the field cleared and FALSE when it timed out. The
    /// caller relaunches either way — a stranger's copy of the same app may
    /// legitimately be running forever, and refusing to start because of it
    /// would be worse than starting beside it — but the two are different
    /// facts and the log says which happened.
    static func awaitQuiet(
        maxWaitMs: Int = maxWaitMs,
        pollIntervalMs: Int = pollIntervalMs,
        stillRunning: () -> Bool,
        sleep: (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }
    ) async -> Bool {
        var waited = 0
        while true {
            if !stillRunning() { return true }
            if waited >= maxWaitMs { return false }
            await sleep(pollIntervalMs)
            waited += pollIntervalMs
        }
    }

    /// One reading of the launched app's front window: which CG window it is
    /// and how big. Equality is the whole point — two consecutive equal
    /// readings mean the window has appeared AND stopped moving.
    struct WindowReading: Equatable, Sendable {
        var windowNumber: Int
        var size: CGSize
    }

    /// Total budget for the window wait. The pre-WB-25 loop was 60 polls at
    /// 150ms (9s) and resolved on the FIRST successful capture — which, under
    /// a rapid re-run, is routinely a window that has been created but not yet
    /// laid out, so the session's opening observation caught the app
    /// mid-assembly. Requiring a second, identical reading costs one poll on a
    /// healthy launch and is the difference between "a window exists" and "the
    /// window is ready to be observed".
    static let windowReadyMaxWaitMs = 12_000
    static let windowReadyPollIntervalMs = 150

    /// Poll `reading` until two CONSECUTIVE polls return the same window and
    /// size, or the budget expires. Returns the settled reading, or nil on
    /// timeout / the app dying under us.
    ///
    /// `alive` is checked every poll so a process that has already exited ends
    /// the wait immediately: it will never show a window, and the seconds
    /// spent proving that are seconds the retry could be using.
    ///
    /// Cancellation ends the wait too. The default `sleep` is
    /// `Task.sleep`, which returns IMMEDIATELY once the task is cancelled — so
    /// without an explicit check a cancelled launch would spin the whole
    /// budget's worth of polls at full speed, each one a real window-list call.
    static func awaitReadyWindow(
        maxWaitMs: Int = windowReadyMaxWaitMs,
        pollIntervalMs: Int = windowReadyPollIntervalMs,
        alive: () -> Bool,
        reading: () async -> WindowReading?,
        sleep: (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }
    ) async -> WindowReading? {
        var waited = 0
        var previous: WindowReading?
        while waited < maxWaitMs {
            if Task.isCancelled { return nil }
            await sleep(pollIntervalMs)
            waited += pollIntervalMs
            let current = await reading()
            if let current, let previous, current == previous { return current }
            previous = current
            if current == nil, !alive() { return nil }
        }
        return nil
    }
}

enum MacOSAdapterError: Error, Sendable, LocalizedError {
    case bundleNotFound(path: String)
    case bundleIdentifierMissing(path: String)
    case windowNeverAppeared(bundleID: String, phase: MacLaunchSettle.Phase)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound(let path):
            return "macOS app bundle not found at \(path). Pick a valid .app or check the path in Application settings."
        case .bundleIdentifierMissing(let path):
            return "Couldn't read CFBundleIdentifier from \(path)/Contents/Info.plist."
        case .windowNeverAppeared(let bid, let phase):
            switch phase {
            case .previousInstanceExit:
                // The retry's quiet wait ALSO ran out: a same-bundle-id
                // process was still running after the full budget. That is a
                // real extra fact and worth naming — but it is not proof of
                // the cause, because a developer's own copy of the app is
                // allowed to run forever and would produce this every time.
                // So this message ADDS the still-running instance to the
                // window guidance; it must not replace it, or the one user who
                // always has their own copy open would never be told about the
                // grant that is actually the problem.
                return "macOS app '\(bid)' launched but never showed a visible window — twice. The retry also timed out \(phase.rawValue) (\(MacLaunchSettle.maxWaitMs)ms): another copy of '\(bid)' is still running, which may be the previous session's instance still quitting, or simply your own copy. Quit any other copy and try again. If that isn't it, make sure Harness has Screen Recording permission and the app opens a window on launch (and, if you passed launch_args or env, that they don't put it into a headless mode)."
            case .windowReady:
                return "macOS app '\(bid)' launched but never showed a visible window — twice: the second attempt waited for any previous instance to exit and forced a new process, so this is not a still-quitting predecessor. It timed out \(phase.rawValue) (\(MacLaunchSettle.windowReadyMaxWaitMs)ms). Make sure Harness has Screen Recording permission and the app opens a window on launch (and, if you passed launch_args or env, that they don't put it into a headless mode)."
            }
        }
    }
}
