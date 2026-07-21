//
//  MacAppDriver.swift
//  Harness
//
//  `UXDriving` for a macOS app. Captures the app's window with
//  `CGWindowListCreateImage` and synthesises input through a pluggable
//  backend (see `MacInputBackend.swift`).
//
//  The driver targets a specific window owned by `bundleIdentifier`. On
//  every screenshot we re-resolve the front window's CG window-id and
//  bounds — apps move and resize during a run, and we want to follow,
//  not chase a stale frame.
//
//  Coordinate space: screenshots are at point resolution
//  (`CGWindowListCreateImage` returns the visible window content in logical
//  points on the main display unless the user is on a custom Retina mode;
//  see `pointSize` resolution). The agent emits coordinates in those same
//  points; the driver translates window-local point → screen-global point
//  before actuating (both `AXUIElementCopyElementAtPosition` and `CGEvent`
//  use that same global, top-left-origin space).
//
//  Input backend (chosen once, from `HARNESS_MACOS_INPUT`):
//   - `.contained` (DEFAULT) — never touches the real pointer, focus, or
//     any app other than the SUT. Per-step ladder: AX action first
//     (`kAXPressAction`; focus + `AXSetValue` for text), then a `CGEvent`
//     delivered to the SUT's own queue via `postToPid(_:)` (scroll,
//     shortcuts, raw-coordinate / double / right clicks). No global HID,
//     no `ensureFront()`; when neither path can land it throws
//     `MacDriverError.unactuatable`. `kAXRaiseAction` on the SUT's own
//     window would be a within-app raise (permitted) — not used today.
//   - `.hid` (`HARNESS_MACOS_INPUT=hid`) — legacy, preserved verbatim:
//     global-HID `CGEvent`s (`.cghidEventTap`, which takes over the real
//     mouse/keyboard) plus `ensureFront()` foregrounding.
//
//  Permissions (contained mode): Screen Recording (Privacy & Security →
//  Screen & System Audio Recording) for window capture — captures
//  background/occluded windows, so no foregrounding is needed — and
//  Accessibility for the AX actions and `postToPid` event delivery. The
//  first capture / AX call surfaces the respective system prompt; once
//  granted, subsequent runs work silently. TCC grants attach to the
//  responsible parent process, not this binary. (Legacy `.hid` mode
//  needs the same two grants but additionally moves the real pointer and
//  foregrounds the SUT.)
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os

actor MacAppDriver: UXDriving {

    private static let logger = Logger(subsystem: "com.harness.app", category: "MacAppDriver")

    let bundleIdentifier: String
    /// Optional `.app` bundle URL — used by `relaunchForNewLeg()` to
    /// terminate + relaunch the app between chain legs that don't
    /// preserve state.
    let appBundleURL: URL?
    /// V5 — pre-staged credential for this run, or nil. Same lifecycle as
    /// the iOS driver's: resolved once at run start, dropped at teardown.
    let credential: CredentialBinding?

    /// Which input-synthesis backend this run uses. Resolved once, at
    /// construction, from `HARNESS_MACOS_INPUT` (default `.contained`).
    /// Governs the actuation ladder AND whether the SUT is foregrounded
    /// before capture/input.
    let backend: MacInputBackendKind

    /// Set-of-Mark cache for the most recent screenshot's probe.
    /// `tap_mark(id)` resolves against this; refreshed on every
    /// `screenshot(into:)` call so marks reflect the same DOM state
    /// the snapshot captured. Same lifecycle as web's / iOS's.
    private var lastMarks: [InteractiveMark] = []

    init(
        bundleIdentifier: String,
        appBundleURL: URL?,
        credential: CredentialBinding? = nil,
        backend: MacInputBackendKind? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appBundleURL = appBundleURL
        self.credential = credential
        self.backend = backend ?? .fromEnvironment(ProcessInfo.processInfo.environment)
    }

    // MARK: - UXDriving

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        // Contained backend never foregrounds — CGWindowListCreateImage
        // captures background/occluded windows fine. Only legacy HID
        // needs the SUT frontmost so global-HID events land on it.
        if backend.requiresForeground { try ensureFront() }
        guard let info = try findFrontWindow() else {
            throw MacDriverError.windowNotFound(bundleID: bundleIdentifier)
        }

        // Probe AX tree BEFORE capture so marks reflect the same
        // state the snapshot captures. Same invariant the iOS / web
        // drivers enforce. Probe failure is non-fatal — agent can
        // still call coordinate-based tools with no scaffolding.
        let marks = probeInteractiveElements(
            pid: info.ownerPID,
            windowOrigin: info.bounds.origin,
            windowSize: info.bounds.size
        )
        lastMarks = marks
        Self.logger.info("AX probe yielded \(marks.count, privacy: .public) marks for \(self.bundleIdentifier, privacy: .public)")

        guard let cgImage = CGWindowListCreateImage(
            CGRectNull,                              // CGRectNull → use the window's full rect
            .optionIncludingWindow,
            CGWindowID(info.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            throw MacDriverError.captureFailed
        }
        let pixelW = cgImage.width
        let pixelH = cgImage.height
        let pointSize = CGSize(width: info.bounds.width, height: info.bounds.height)

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MacDriverError.captureFailed
        }
        try png.write(to: url, options: .atomic)

        // No marks → no scaffolding to compose. Return the bare
        // disk PNG via the standard metadata shape.
        guard !marks.isEmpty,
              let raw = NSImage(data: png) else {
            return ScreenshotMetadata(pixelSize: CGSize(width: pixelW, height: pixelH), pointSize: pointSize)
        }

        // Render badges. `markSpaceSize` = window point size; the
        // CGImage is at the window's pixel resolution, which on
        // retina displays differs from the point size — MarkRenderer
        // scales mark rects from point space to pixel space.
        let marked = MarkRenderer.draw(on: raw, marks: marks, markSpaceSize: pointSize)
        let markedData = MarkRenderer.pngData(from: marked)

        if let markedData,
           ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let markedURL = url
                .deletingPathExtension()
                .appendingPathExtension("marked.png")
            try? markedData.write(to: markedURL, options: .atomic)
        }

        let annotation = MarkRenderer.describe(marks)
        return ScreenshotMetadata(
            pixelSize: CGSize(width: pixelW, height: pixelH),
            pointSize: pointSize,
            markedImageData: markedData,
            markedAnnotationText: annotation
        )
    }

    func execute(_ call: ToolCall) async throws {
        // Contained backend never foregrounds the SUT; only legacy HID
        // needs it frontmost so global-HID events reach it.
        if backend.requiresForeground { try ensureFront() }
        guard let info = try findFrontWindow() else {
            throw MacDriverError.windowNotFound(bundleID: bundleIdentifier)
        }

        switch call.input {
        case .tap(let x, let y):
            try await actuateClick(button: .left, count: 1, windowLocal: CGPoint(x: x, y: y), info: info, planInput: call.input)
        case .doubleTap(let x, let y):
            try await actuateClick(button: .left, count: 2, windowLocal: CGPoint(x: x, y: y), info: info, planInput: call.input)
        case .rightClick(let x, let y):
            try await actuateClick(button: .right, count: 1, windowLocal: CGPoint(x: x, y: y), info: info, planInput: call.input)
        case .scroll(let x, let y, let dx, let dy):
            try await actuateScroll(windowLocal: CGPoint(x: x, y: y), dx: dx, dy: dy, info: info, planInput: call.input)
        case .type(let text):
            try await actuateType(text, info: info, planInput: call.input)
        case .keyShortcut(let keys):
            try await actuateShortcut(keys, info: info, planInput: call.input)
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .readScreen, .noteFriction, .markGoalDone:
            return
        case .fillCredential(let field):
            // No staged credential → soft no-op; the agent should emit
            // `auth_required` friction. With a binding, route through the
            // same text-entry ladder as the ordinary `type` tool — the
            // macOS app sees a focused text field receive the value,
            // just like a human typing.
            guard let credential else { return }
            let text = field == .username ? credential.username : credential.password
            try await actuateType(text, info: info, planInput: call.input)
        case .tapMark(let id):
            try await dispatchMarkClick(id: id, info: info)
        case .swipe, .pressButton, .navigate, .back, .forward, .refresh:
            throw UXDriverError.unsupportedTool(name: call.tool.rawValue, platform: .macosApp)
        }
    }

    // MARK: - Settle

    /// Post-action settle. macOS has no DOM mutation observer; we use
    /// the same screenshot-stability approach as iOS: capture at a
    /// fixed cadence, dHash each frame, resolve when two consecutive
    /// frames are visually equivalent OR `maxMs` elapses. Profiles
    /// tuned for typical Mac-app paint cycles (NSAnimation sheet/
    /// modal transitions ~300ms, scroll inertia ~600ms).
    func settle(afterTool call: ToolCall) async {
        let idleMs: Int
        let minMs: Int
        let maxMs: Int
        switch call.input {
        case .tap, .doubleTap, .tapMark, .rightClick, .fillCredential:
            idleMs = 250
            minMs = 250
            maxMs = 2000
        case .scroll:
            idleMs = 400
            minMs = 400
            maxMs = 3000
        case .keyShortcut:
            // Shortcuts can trigger sheet/menu presentations — give
            // a bit more rope than a plain click.
            idleMs = 350
            minMs = 350
            maxMs = 2500
        case .type, .wait, .readScreen, .noteFriction, .markGoalDone,
             .swipe, .pressButton, .navigate, .back, .forward, .refresh:
            return
        }
        await awaitWindowStable(idleMs: idleMs, minMs: minMs, maxMs: maxMs)
    }

    private func awaitWindowStable(idleMs: Int, minMs: Int, maxMs: Int) async {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(maxMs))
        let floor = start.advanced(by: .milliseconds(minMs))
        let pollInterval: Duration = .milliseconds(150)

        var lastHash: UInt64?
        while clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            guard let info = (try? findFrontWindow()) ?? nil else { continue }
            guard let cgImage = CGWindowListCreateImage(
                CGRectNull,
                .optionIncludingWindow,
                CGWindowID(info.windowNumber),
                [.boundsIgnoreFraming, .nominalResolution]
            ) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let hash = ScreenshotHasher.dHash(jpeg: png)
            if let prev = lastHash,
               ScreenshotHasher.hammingDistance(hash, prev) <= AgentLoop.cycleHashThreshold,
               clock.now >= floor {
                return
            }
            lastHash = hash
        }
    }

    // MARK: - Set-of-Mark dispatch

    /// Resolve `id` to a cached `InteractiveMark` and click the center of
    /// its visible-in-window portion. Mirrors the web / iOS dispatchers:
    /// viewport-clip, then the standard single-left-click ladder
    /// (`actuateClick` with `planInput: .tapMark`) — AX-press-first in
    /// contained mode, global HID under the legacy backend.
    private func dispatchMarkClick(id: Int, info: WindowInfo) async throws {
        guard let mark = lastMarks.first(where: { $0.id == id }) else {
            throw MacDriverError.unknownMark(id: id)
        }
        let inset: CGFloat = 4
        let winW = info.bounds.width
        let winH = info.bounds.height
        let visibleMinX = max(mark.rect.minX, 0) + inset
        let visibleMinY = max(mark.rect.minY, 0) + inset
        let visibleMaxX = min(mark.rect.maxX, winW) - inset
        let visibleMaxY = min(mark.rect.maxY, winH) - inset
        let cx: CGFloat
        let cy: CGFloat
        if visibleMaxX > visibleMinX && visibleMaxY > visibleMinY {
            cx = (visibleMinX + visibleMaxX) / 2
            cy = (visibleMinY + visibleMaxY) / 2
        } else {
            cx = mark.rect.midX
            cy = mark.rect.midY
        }
        Self.logger.info("tap_mark(\(id, privacy: .public)) → label=\"\(mark.label, privacy: .public)\" role=\(mark.role, privacy: .public) rect=(\(Int(mark.rect.minX), privacy: .public),\(Int(mark.rect.minY), privacy: .public),\(Int(mark.rect.width), privacy: .public),\(Int(mark.rect.height), privacy: .public)) → click(\(Int(cx), privacy: .public),\(Int(cy), privacy: .public))")
        if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let line = "[MacAX] tap_mark(\(id)) label=\"\(mark.label)\" role=\(mark.role) rect=(\(Int(mark.rect.minX)),\(Int(mark.rect.minY)),\(Int(mark.rect.width)),\(Int(mark.rect.height))) → click(\(Int(cx)),\(Int(cy)))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        try await actuateClick(button: .left, count: 1, windowLocal: CGPoint(x: cx, y: cy), info: info, planInput: .tapMark(id: id))
    }

    /// Quit the running SUT: ask it to `terminate()`, wait ~2s, then
    /// `forceTerminate()` as a fallback so a hung app never blocks the
    /// caller. Idempotent — a no-op when the app isn't running (already
    /// quit / never launched). Shared by `relaunchForNewLeg()` (which then
    /// relaunches) and the ui-session teardown path (which does not), so
    /// the two can't diverge on how the SUT is killed.
    func terminateApp() async {
        let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })
        guard let app = running else { return }
        app.terminate()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return
            }
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            _ = app.forceTerminate()
        }
    }

    func relaunchForNewLeg() async throws {
        // Quit the running app, then relaunch from the bundle URL (if we
        // have one). NSWorkspace handles "cold relaunch from .app".
        await terminateApp()
        if let bundleURL = appBundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            // Contained backend must not steal focus on reopen; only
            // legacy HID relaunches activated.
            cfg.activates = backend.activatesOnLaunch
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
        } else {
            // No bundle URL → user provided an already-running app via
            // bundle id. Best effort: ask LaunchServices to launch it
            // again by bundle id.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = backend.activatesOnLaunch
            if let runningURL = appBundleURLByLookup() {
                _ = try await NSWorkspace.shared.openApplication(at: runningURL, configuration: cfg)
            }
        }
        // Wait briefly for the app's main window to come back. If it
        // doesn't, the next screenshot() will throw `windowNotFound`
        // and surface a clean error.
        for _ in 0..<30 {
            if (try? findFrontWindow()) ?? nil != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Internals

    /// Bring the SUT to the front so screenshots and CGEvents target it.
    /// Idempotent — safe to call before every step.
    private func ensureFront() throws {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            throw MacDriverError.appNotRunning(bundleID: bundleIdentifier)
        }
        if !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Resolve the SUT's frontmost on-screen window from the CG window list.
    /// Returns nil when nothing matches (app is hidden, mid-launch, etc.).
    private struct WindowInfo {
        let windowNumber: Int
        let bounds: CGRect      // global screen coordinates, top-left origin in macOS-y space
        let ownerPID: Int
    }

    private func findFrontWindow() throws -> WindowInfo? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            throw MacDriverError.appNotRunning(bundleID: bundleIdentifier)
        }
        let pid = app.processIdentifier
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Pick the topmost on-screen window owned by this PID with non-trivial size.
        for entry in raw {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid),
                  let windowNumber = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 50, rect.height > 50
            else { continue }
            return WindowInfo(windowNumber: windowNumber, bounds: rect, ownerPID: ownerPID)
        }
        return nil
    }

    /// Last-ditch lookup for the running app's bundle URL — used when the
    /// caller never gave us one (raw bundle-id run mode).
    private func appBundleURLByLookup() -> URL? {
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })?
            .bundleURL
    }

    // MARK: - CGEvent helpers

    /// Convert window-local point → global screen point (where CGEvent
    /// expects its coordinates). macOS's CGEvent uses top-left origin
    /// global, which matches `kCGWindowBounds` directly.
    private func toGlobalPoint(_ windowLocal: CGPoint, _ info: WindowInfo) -> CGPoint {
        CGPoint(x: info.bounds.minX + windowLocal.x,
                y: info.bounds.minY + windowLocal.y)
    }

    // MARK: - Actuation ladder

    /// Outcome of one ladder rung. `.landed` stops the ladder;
    /// `.notApplicable` records why and moves to the next rung.
    private enum StepResult {
        case landed
        case notApplicable(String)
    }

    /// Walk `steps` in order, stopping at the first that lands. If every
    /// rung is `.notApplicable`, throw `unactuatable` naming what was
    /// attempted — the honest failure mode. Never falls back to global
    /// HID. (In `.hid` mode the single global-HID rung throws
    /// `eventCreationFailed` on construction failure, verbatim to the
    /// pre-0.8 behavior, and so never reaches the `unactuatable` throw.)
    private func runLadder(
        action: String,
        steps: [MacActuationStep],
        axPress: () -> StepResult = { .notApplicable("no AX-press path for this tool") },
        axSetValue: () -> StepResult = { .notApplicable("no AX-value path for this tool") },
        cgTargeted: () -> StepResult = { .notApplicable("no targeted-CGEvent path for this tool") },
        cgGlobalHID: () async throws -> StepResult = { .notApplicable("no HID path for this tool") }
    ) async throws {
        var reasons: [String] = []
        for step in steps {
            let result: StepResult
            switch step {
            case .axPress:          result = axPress()
            case .axSetValue:       result = axSetValue()
            case .cgEventTargeted:  result = cgTargeted()
            case .cgEventGlobalHID: result = try await cgGlobalHID()
            }
            if case .landed = result { return }
            if case .notApplicable(let why) = result { reasons.append("\(step.label): \(why)") }
        }
        throw MacDriverError.unactuatable(
            action: action,
            detail: reasons.isEmpty ? "no actuation path available" : reasons.joined(separator: "; ")
        )
    }

    private func actuateClick(
        button: CGMouseButton,
        count: Int,
        windowLocal: CGPoint,
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        let global = toGlobalPoint(windowLocal, info)
        let pid = info.ownerPID
        try await runLadder(
            action: "click(button:\(button.rawValue) count:\(count)) at (\(Int(windowLocal.x)),\(Int(windowLocal.y)))",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            axPress: {
                // AXPress models a single activation only; double / right
                // click have no single-action equivalent → fall through.
                guard button == .left, count == 1 else {
                    return .notApplicable("AX press applies only to a single left click")
                }
                guard let element = Self.axPressableElement(pid: pid, atGlobal: global) else {
                    return .notApplicable("no actionable AX element at point")
                }
                return Self.axPerformPress(element)
                    ? .landed
                    : .notApplicable("AXPress returned an error")
            },
            cgTargeted: {
                self.postClickToPid(button: button, count: count, global: global, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try await self.postClickHID(button: button, count: count, global: global)
                return .landed
            }
        )
    }

    private func actuateScroll(
        windowLocal: CGPoint,
        dx: Int,
        dy: Int,
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        let global = toGlobalPoint(windowLocal, info)
        let pid = info.ownerPID
        try await runLadder(
            action: "scroll(dx:\(dx) dy:\(dy)) at (\(Int(windowLocal.x)),\(Int(windowLocal.y)))",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            cgTargeted: {
                self.postScrollToPid(global: global, dx: dx, dy: dy, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try self.postScrollHID(global: global, dx: dx, dy: dy)
                return .landed
            }
        )
    }

    private func actuateType(
        _ text: String,
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        let pid = info.ownerPID
        try await runLadder(
            action: "type(\(text.count) chars)",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            axSetValue: {
                // Whole-value entry into the app's focused text element.
                // NOTE: this replaces the field's value rather than
                // appending keystrokes — it does not fire per-keystroke
                // handlers. When the focused element rejects AXSetValue
                // (not settable / no focus) we fall through to synthetic
                // keystrokes, which do.
                guard let element = Self.axFocusedElement(pid: pid) else {
                    return .notApplicable("no focused AX element to receive text")
                }
                return Self.axSetValue(element, text: text)
                    ? .landed
                    : .notApplicable("focused element did not accept AXSetValue")
            },
            cgTargeted: {
                self.postTypeToPid(text, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try self.postTypeHID(text)
                return .landed
            }
        )
    }

    private func actuateShortcut(
        _ keys: [String],
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        // Resolve the key combo up front — `unknownKey` is a bad-input
        // error, independent of backend, and empty keys are a no-op.
        guard let resolved = try Self.resolveShortcut(keys) else { return }
        let pid = info.ownerPID
        try await runLadder(
            action: "key_shortcut(\(keys.joined(separator: "+")))",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            cgTargeted: {
                self.postShortcutToPid(vk: resolved.vk, flags: resolved.flags, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try self.postShortcutHID(vk: resolved.vk, flags: resolved.flags)
                return .landed
            }
        )
    }

    // MARK: - Contained synthesis (postToPid — pointer never moves)

    /// Post a click to the SUT's own event queue. Returns false only if
    /// a `CGEvent` couldn't be constructed. `postToPid` delivers to the
    /// app's queue without moving the real cursor, so no inter-click
    /// sleep is needed — the `clickState` field is what marks a
    /// double-click.
    private func postClickToPid(button: CGMouseButton, count: Int, global: CGPoint, pid: Int) -> Bool {
        let (downType, upType) = Self.mouseTypes(for: button)
        for i in 1...count {
            guard postMouseToPid(type: downType, location: global, mouseButton: button, clickState: i, pid: pid),
                  postMouseToPid(type: upType,   location: global, mouseButton: button, clickState: i, pid: pid)
            else { return false }
        }
        return true
    }

    private func postMouseToPid(type: CGEventType, location: CGPoint, mouseButton: CGMouseButton, clickState: Int, pid: Int) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        ) else { return false }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.postToPid(pid_t(pid))
        return true
    }

    private func postScrollToPid(global: CGPoint, dx: Int, dy: Int, pid: Int) -> Bool {
        // A synthetic mouse-moved so the app's own hover / scroll routing
        // targets the right view. Delivered to the app queue only — the
        // real system cursor does NOT move.
        _ = postMouseToPid(type: .mouseMoved, location: global, mouseButton: .left, clickState: 0, pid: pid)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-dy),   // UI convention (positive = down) → CGEvent up-positive
            wheel2: Int32(dx),
            wheel3: 0
        ) else { return false }
        event.postToPid(pid_t(pid))
        return true
    }

    private func postTypeToPid(_ text: String, pid: Int) -> Bool {
        let chars = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        down.postToPid(pid_t(pid))
        up.postToPid(pid_t(pid))
        return true
    }

    private func postShortcutToPid(vk: CGKeyCode, flags: CGEventFlags, pid: Int) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags   = flags
        down.postToPid(pid_t(pid))
        up.postToPid(pid_t(pid))
        return true
    }

    // MARK: - Legacy HID synthesis (global .cghidEventTap — verbatim pre-0.8)

    private func postClickHID(button: CGMouseButton, count: Int, global: CGPoint) async throws {
        let (downType, upType) = Self.mouseTypes(for: button)
        for i in 1...count {
            try postMouseHID(type: downType, location: global, mouseButton: button, clickState: i)
            try postMouseHID(type: upType,   location: global, mouseButton: button, clickState: i)
            // Tiny inter-click gap so double-clicks register as one gesture.
            if i < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
    }

    private func postMouseHID(type: CGEventType, location: CGPoint, mouseButton: CGMouseButton, clickState: Int) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        ) else {
            throw MacDriverError.eventCreationFailed(action: "mouse:\(type.rawValue)")
        }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postScrollHID(global: CGPoint, dx: Int, dy: Int) throws {
        try postMouseHID(type: .mouseMoved, location: global, mouseButton: .left, clickState: 0)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else {
            throw MacDriverError.eventCreationFailed(action: "scroll")
        }
        event.post(tap: .cghidEventTap)
    }

    private func postTypeHID(_ text: String) throws {
        let chars = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            throw MacDriverError.eventCreationFailed(action: "type")
        }
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw MacDriverError.eventCreationFailed(action: "type")
        }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postShortcutHID(vk: CGKeyCode, flags: CGEventFlags) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else {
            throw MacDriverError.eventCreationFailed(action: "key_shortcut")
        }
        down.flags = flags
        up.flags   = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Input primitives shared by both backends

    private static func mouseTypes(for button: CGMouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left:  return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        default:     return (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Parse a shortcut key list into `(modifier flags, final virtual
    /// key)`. Returns nil for an empty list (a no-op). Throws
    /// `unknownKey` for an unrecognised final key. Backend-independent —
    /// bad input fails the same way in both modes.
    private static func resolveShortcut(_ keys: [String]) throws -> (flags: CGEventFlags, vk: CGKeyCode)? {
        guard !keys.isEmpty else { return nil }
        let lowered = keys.map { $0.lowercased() }
        let modifierNames: Set<String> = ["cmd", "command", "shift", "option", "alt", "ctrl", "control", "fn"]
        let modifiers = lowered.filter { modifierNames.contains($0) }
        let finalKey = lowered.last(where: { !modifierNames.contains($0) })

        var flags: CGEventFlags = []
        for m in modifiers {
            switch m {
            case "cmd", "command":  flags.insert(.maskCommand)
            case "shift":           flags.insert(.maskShift)
            case "option", "alt":   flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn":              flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        guard let key = finalKey, let vk = MacKeyCodes.virtualKey(for: key) else {
            throw MacDriverError.unknownKey(name: finalKey ?? "<empty>")
        }
        return (flags, vk)
    }

    // MARK: - AX actuation (contained clicks / text entry)

    /// Hit-test the SUT at a global point and climb up to a few ancestors
    /// looking for an element that advertises `kAXPressAction` — the deep
    /// hit is often a static label inside the actual button. Returns nil
    /// when nothing pressable is under the point (raw-coordinate click on
    /// non-AX content) so the caller falls through to a CGEvent. Requires
    /// Accessibility; on denial the copy fails and we return nil.
    nonisolated private static func axPressableElement(pid: Int, atGlobal p: CGPoint) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success,
              var element = hit else {
            return nil
        }
        for _ in 0..<5 {
            if axSupportsPress(element) { return element }
            guard let parent = axAttribute(element, attribute: kAXParentAttribute) else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    nonisolated private static func axSupportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    nonisolated private static func axPerformPress(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// The app's currently focused UI element (where typed text would
    /// land), or nil if nothing is focused / Accessibility is denied.
    nonisolated private static func axFocusedElement(pid: Int) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        guard let focused = axAttribute(app, attribute: kAXFocusedUIElementAttribute) else { return nil }
        return (focused as! AXUIElement)
    }

    /// Focus the element, then set its whole value via `AXSetValue`.
    /// Returns false when the element's value isn't settable or the set
    /// fails, so the caller falls through to synthetic keystrokes.
    nonisolated private static func axSetValue(_ element: AXUIElement, text: String) -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    // MARK: - AX (Set-of-Mark probe)

    /// Roles we treat as actionable tap targets on macOS. Sourced
    /// from the AX constants in HIServices — same vocabulary AppKit
    /// uses to describe controls. Categories: standard buttons +
    /// menu controls, text input, selection controls, indicators,
    /// list rows.
    /// AX roles we treat as actionable tap targets. The set is a
    /// mix of `kAX...Role` constants from HIServices and string
    /// literals for roles HIServices doesn't ship a constant for
    /// (e.g. `AXLink` — defined by AppKit at runtime). Either form
    /// matches against `AXUIElementCopyAttributeValue`'s string
    /// result equally.
    private static let actionableAXRoles: Set<String> = [
        kAXButtonRole as String,
        kAXMenuButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuItemRole as String,
        kAXMenuBarItemRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXSliderRole as String,
        kAXIncrementorRole as String,
        kAXDisclosureTriangleRole as String,
        kAXColorWellRole as String,
        kAXImageRole as String,
        kAXRowRole as String,
        kAXCellRole as String,
        kAXTabGroupRole as String,
        "AXLink",
        "AXSecureTextField",
        "AXSearchField",
        "AXStepper",
        "AXSwitch"
    ]

    /// Container roles whose children we descend into (instead of
    /// marking the container itself). A toolbar mark is useless if
    /// the agent really wanted to click one of the buttons inside.
    private static let containerAXRoles: Set<String> = [
        kAXWindowRole as String,
        kAXGroupRole as String,
        kAXSplitGroupRole as String,
        kAXScrollAreaRole as String,
        kAXToolbarRole as String,
        kAXLayoutAreaRole as String,
        kAXListRole as String,
        kAXOutlineRole as String,
        kAXTableRole as String,
        kAXSheetRole as String,
        kAXDrawerRole as String,
        kAXMenuRole as String,
        kAXMenuBarRole as String
    ]

    /// Walk the focused window's AX tree and return actionable
    /// elements as `InteractiveMark`s in window-local point space
    /// (top-left origin). Mark rects intersect the window's bounds;
    /// elements entirely off-window (overflowing scroll-area
    /// children) are dropped. Cap at 80 marks — same as web / iOS.
    ///
    /// Requires the Accessibility permission. On first run macOS
    /// surfaces a system prompt; once granted, subsequent runs
    /// silently succeed. Without the grant, every attribute pull
    /// returns `.cannotComplete` and we return an empty list.
    nonisolated private func probeInteractiveElements(
        pid: Int,
        windowOrigin: CGPoint,
        windowSize: CGSize
    ) -> [InteractiveMark] {
        let appElem = AXUIElementCreateApplication(pid_t(pid))
        // Prefer the focused window; fall back to the main window
        // (e.g., the app just launched and nothing has focus yet).
        let windowElem = Self.axAttribute(appElem, attribute: kAXFocusedWindowAttribute)
            ?? Self.axAttribute(appElem, attribute: kAXMainWindowAttribute)
        guard let root = windowElem as! AXUIElement? else { return [] }

        var collected: [(rect: CGRect, role: String, label: String)] = []
        Self.axWalk(
            element: root,
            windowOrigin: windowOrigin,
            windowSize: windowSize,
            depth: 0,
            into: &collected
        )

        // Reading order: top-to-bottom then left-to-right.
        collected.sort { (a, b) in
            if abs(a.rect.minY - b.rect.minY) < 1 {
                return a.rect.minX < b.rect.minX
            }
            return a.rect.minY < b.rect.minY
        }
        // Cap to keep badge density manageable.
        let capped = collected.prefix(80)
        return capped.enumerated().map { (i, entry) in
            InteractiveMark(
                id: i + 1,
                rect: entry.rect,
                role: Self.shortAXRole(entry.role),
                inputType: nil,
                label: entry.label
            )
        }
    }

    /// Pull a single AX attribute. Returns nil on any error (missing
    /// attribute, permission denied, etc.) so the caller can keep
    /// walking instead of throwing.
    nonisolated private static func axAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    /// Try to read a CGRect from an element's position + size AX
    /// attributes. Returns nil when either is missing. Coordinates
    /// come back in global screen space (top-left origin) per
    /// AppKit's AX convention.
    nonisolated private static func axRect(_ element: AXUIElement) -> CGRect? {
        guard let posRef = axAttribute(element, attribute: kAXPositionAttribute),
              let sizeRef = axAttribute(element, attribute: kAXSizeAttribute) else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Resolve a human-readable label from the standard AX
    /// title-like attributes. AXTitle is the most-used; AXValue
    /// gives current text-field content; AXDescription / AXHelp
    /// catch tooltip-style labels on icon buttons; AXIdentifier is
    /// a last-resort developer-supplied id.
    nonisolated private static func axLabel(_ element: AXUIElement) -> String {
        let candidates: [String] = [
            kAXTitleAttribute as String,
            kAXValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXIdentifierAttribute as String
        ]
        for attr in candidates {
            if let raw = axAttribute(element, attribute: attr) as? String,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 80 ? String(trimmed.prefix(77)) + "…" : trimmed
            }
        }
        return ""
    }

    /// Recursive walker. Bounded depth (24) + max-visited (1500)
    /// keep pathological apps with deep / wide trees from blowing
    /// the time budget for a single probe.
    nonisolated private static func axWalk(
        element: AXUIElement,
        windowOrigin: CGPoint,
        windowSize: CGSize,
        depth: Int,
        into out: inout [(rect: CGRect, role: String, label: String)]
    ) {
        if depth > 24 { return }
        if out.count >= 200 { return }  // hard local cap before final 80-mark prefix

        let role = (axAttribute(element, attribute: kAXRoleAttribute) as? String) ?? ""
        let enabled = (axAttribute(element, attribute: kAXEnabledAttribute) as? Bool) ?? true

        let isActionable = actionableAXRoles.contains(role)
        let isContainer = containerAXRoles.contains(role)

        if isActionable, enabled, let globalRect = axRect(element) {
            // Convert global screen rect → window-local point rect.
            let local = CGRect(
                x: globalRect.minX - windowOrigin.x,
                y: globalRect.minY - windowOrigin.y,
                width: globalRect.width,
                height: globalRect.height
            )
            // Clip to window bounds; reject elements with no
            // visible intersection or sub-16pt tap targets.
            let windowBounds = CGRect(origin: .zero, size: windowSize)
            let visible = local.intersection(windowBounds)
            if !visible.isNull && visible.width >= 16 && visible.height >= 16 {
                let label = axLabel(element)
                out.append((local, role, label))
                // Don't recurse — avoids double-marking a Row that
                // contains a Button (the Row mark covers the whole
                // visible interaction; the agent doesn't need both).
                return
            }
            // Element rejected by size filter — fall through to
            // recurse in case useful descendants live underneath.
        }
        // Containers (and rejected actionables) descend into
        // children. Read AXChildren; if nil, try AXVisibleChildren
        // (e.g., for tables that only expose currently-rendered rows).
        _ = isContainer
        let childrenAny = axAttribute(element, attribute: kAXChildrenAttribute)
                       ?? axAttribute(element, attribute: kAXVisibleChildrenAttribute)
        guard let children = childrenAny as? [AXUIElement] else { return }
        for child in children {
            axWalk(
                element: child,
                windowOrigin: windowOrigin,
                windowSize: windowSize,
                depth: depth + 1,
                into: &out
            )
            if out.count >= 200 { return }
        }
    }

    /// Strip the `AX` prefix from a role name for the annotation
    /// (`AXButton` → `button`). Lowercase-first to match the iOS /
    /// web role formatting.
    nonisolated private static func shortAXRole(_ raw: String) -> String {
        let body: String
        if raw.hasPrefix("AX") {
            body = String(raw.dropFirst(2))
        } else {
            body = raw
        }
        guard let first = body.first else { return body }
        return first.lowercased() + body.dropFirst()
    }
}

enum MacDriverError: Error, Sendable, LocalizedError {
    case appNotRunning(bundleID: String)
    case windowNotFound(bundleID: String)
    case captureFailed
    case eventCreationFailed(action: String)
    case unknownKey(name: String)
    case unknownMark(id: Int)
    /// Contained backend exhausted its ladder without landing the action.
    /// `detail` names each rung attempted and why it didn't apply. There
    /// is deliberately no global-HID fallback — this is honest failure.
    case unactuatable(action: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let id):
            return "macOS app '\(id)' isn't running. Launch failed or it quit unexpectedly."
        case .windowNotFound(let id):
            return "Couldn't find a frontmost window for '\(id)'. Make sure it has at least one visible window and Harness has Screen Recording permission."
        case .captureFailed:
            return "Screen capture failed. Grant Screen Recording permission to Harness in Privacy & Security settings."
        case .eventCreationFailed(let action):
            return "Failed to synthesise input event '\(action)'. Make sure Harness has Accessibility permission if needed."
        case .unknownKey(let name):
            return "Unknown key shortcut: '\(name)'. Use names like 'a'…'z', '0'…'9', 'return', 'escape', 'tab', 'space', 'delete', 'left'/'right'/'up'/'down', 'f1'…'f12'."
        case .unknownMark(let id):
            return "tap_mark(id: \(id)) — that id wasn't in the latest screenshot's mark set. The window may have changed; the next screenshot will refresh the marks."
        case .unactuatable(let action, let detail):
            return "Couldn't actuate '\(action)' in contained mode: \(detail). No global-HID fallback is used — this control could not be reached process-locally. Grant Accessibility to the responsible process, or set HARNESS_MACOS_INPUT=hid to opt into legacy pointer-driving input."
        }
    }
}

// MARK: - Virtual key code map

/// Minimal name → CGKeyCode map. Covers letters, digits, common control
/// keys, and arrows — sufficient for the macOS shortcuts the agent emits
/// in practice. Extend on demand.
enum MacKeyCodes {
    static func virtualKey(for name: String) -> CGKeyCode? {
        switch name {
        // Letters
        case "a": return 0x00; case "b": return 0x0B; case "c": return 0x08
        case "d": return 0x02; case "e": return 0x0E; case "f": return 0x03
        case "g": return 0x05; case "h": return 0x04; case "i": return 0x22
        case "j": return 0x26; case "k": return 0x28; case "l": return 0x25
        case "m": return 0x2E; case "n": return 0x2D; case "o": return 0x1F
        case "p": return 0x23; case "q": return 0x0C; case "r": return 0x0F
        case "s": return 0x01; case "t": return 0x11; case "u": return 0x20
        case "v": return 0x09; case "w": return 0x0D; case "x": return 0x07
        case "y": return 0x10; case "z": return 0x06
        // Digits
        case "0": return 0x1D; case "1": return 0x12; case "2": return 0x13
        case "3": return 0x14; case "4": return 0x15; case "5": return 0x17
        case "6": return 0x16; case "7": return 0x1A; case "8": return 0x1C
        case "9": return 0x19
        // Whitespace / control
        case "return", "enter": return 0x24
        case "tab":              return 0x30
        case "space":            return 0x31
        case "delete", "backspace": return 0x33
        case "escape":           return 0x35
        // Arrows
        case "left":  return 0x7B
        case "right": return 0x7C
        case "up":    return 0x7E
        case "down":  return 0x7D
        // Function row
        case "f1":  return 0x7A; case "f2":  return 0x78; case "f3":  return 0x63
        case "f4":  return 0x76; case "f5":  return 0x60; case "f6":  return 0x61
        case "f7":  return 0x62; case "f8":  return 0x64; case "f9":  return 0x65
        case "f10": return 0x6D; case "f11": return 0x67; case "f12": return 0x6F
        default: return nil
        }
    }
}
