//
//  MacAppDriver.swift
//  Harness
//
//  `UXDriving` for a macOS app. Uses `CGEvent` to synthesise mouse / keyboard
//  events and `CGWindowListCreateImage` to capture the app's frontmost window.
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
//  before constructing CGEvents.
//
//  Permissions: requires Screen Recording grant (Privacy & Security →
//  Screen & System Audio Recording) for window capture. The first
//  `screenshot(...)` call surfaces the system prompt; once the user has
//  granted permission, subsequent runs work silently.
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

    /// Set-of-Mark cache for the most recent screenshot's probe.
    /// `tap_mark(id)` resolves against this; refreshed on every
    /// `screenshot(into:)` call so marks reflect the same DOM state
    /// the snapshot captured. Same lifecycle as web's / iOS's.
    private var lastMarks: [InteractiveMark] = []

    init(bundleIdentifier: String, appBundleURL: URL?, credential: CredentialBinding? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appBundleURL = appBundleURL
        self.credential = credential
    }

    // MARK: - UXDriving

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        try ensureFront()
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
        try ensureFront()
        guard let info = try findFrontWindow() else {
            throw MacDriverError.windowNotFound(bundleID: bundleIdentifier)
        }

        switch call.input {
        case .tap(let x, let y):
            try await postClick(button: .left, count: 1, windowLocal: CGPoint(x: x, y: y), info: info)
        case .doubleTap(let x, let y):
            try await postClick(button: .left, count: 2, windowLocal: CGPoint(x: x, y: y), info: info)
        case .rightClick(let x, let y):
            try await postClick(button: .right, count: 1, windowLocal: CGPoint(x: x, y: y), info: info)
        case .scroll(let x, let y, let dx, let dy):
            try await postScroll(windowLocal: CGPoint(x: x, y: y), dx: dx, dy: dy, info: info)
        case .type(let text):
            try await postType(text)
        case .keyShortcut(let keys):
            try await postShortcut(keys)
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .readScreen, .noteFriction, .markGoalDone:
            return
        case .fillCredential(let field):
            // No staged credential → soft no-op; the agent should emit
            // `auth_required` friction. With a binding, route through
            // the same CGEvent unicode-string typing path as the
            // ordinary `type` tool — the macOS app sees a focused
            // text field receive characters, just like a human typing.
            guard let credential else { return }
            let text = field == .username ? credential.username : credential.password
            try await postType(text)
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

    /// Resolve `id` to a cached `InteractiveMark` and post a left-click
    /// at the center of its visible-in-window portion. Mirrors the
    /// web / iOS dispatchers: viewport-clip, then standard click path
    /// (in this case `postClick` with `button: .left, count: 1`).
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
        try await postClick(button: .left, count: 1, windowLocal: CGPoint(x: cx, y: cy), info: info)
    }

    func relaunchForNewLeg() async throws {
        // Quit the running app, then relaunch from the bundle URL (if we
        // have one). NSWorkspace handles "cold relaunch from .app".
        let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })
        if let app = running {
            app.terminate()
            // Give it ~2s to quit; force-terminate as a fallback so a
            // hung app doesn't block the next leg forever.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                    break
                }
            }
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                _ = app.forceTerminate()
            }
        }
        if let bundleURL = appBundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
        } else {
            // No bundle URL → user provided an already-running app via
            // bundle id. Best effort: ask LaunchServices to launch it
            // again by bundle id.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
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

    private func postClick(
        button: CGMouseButton,
        count: Int,
        windowLocal: CGPoint,
        info: WindowInfo
    ) async throws {
        let global = toGlobalPoint(windowLocal, info)
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:    downType = .leftMouseDown;   upType = .leftMouseUp
        case .right:   downType = .rightMouseDown;  upType = .rightMouseUp
        default:       downType = .otherMouseDown;  upType = .otherMouseUp
        }
        for i in 1...count {
            try postOne(type: downType, location: global, mouseButton: button, clickState: i)
            try postOne(type: upType,   location: global, mouseButton: button, clickState: i)
            // Tiny inter-click gap so double-clicks register as one gesture.
            if i < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
    }

    private func postScroll(
        windowLocal: CGPoint,
        dx: Int,
        dy: Int,
        info: WindowInfo
    ) async throws {
        let global = toGlobalPoint(windowLocal, info)
        // Move cursor over the target so the scroll event lands in the
        // intended view (apps that key off mouse-over scroll routing).
        try postOne(type: .mouseMoved, location: global, mouseButton: .left, clickState: 0)

        // Pixel-precise scroll. macOS CGEvent's natural scroll is
        // up-positive, but we expose a UI-style convention (positive =
        // down). Negate for the CGEvent. Using .pixel keeps the
        // tool's `dy` unit consistent across web + macOS — both
        // interpret it as pixels of intended scroll.
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

    private func postType(_ text: String) async throws {
        // CGEvent.keyboardSetUnicodeString lets us inject arbitrary text
        // without per-key translation. One key-down with the unicode
        // payload is enough for ASCII; preserves emoji and IME-friendly
        // multi-codepoint sequences.
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

    private func postShortcut(_ keys: [String]) async throws {
        guard !keys.isEmpty else { return }
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
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else {
            throw MacDriverError.eventCreationFailed(action: "key_shortcut")
        }
        down.flags = flags
        up.flags   = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postOne(
        type: CGEventType,
        location: CGPoint,
        mouseButton: CGMouseButton,
        clickState: Int
    ) throws {
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
