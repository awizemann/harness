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

        return ScreenshotMetadata(
            pixelSize: CGSize(width: pixelW, height: pixelH),
            pointSize: pointSize
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
        case .swipe, .pressButton, .navigate, .back, .forward, .refresh, .tapMark:
            // `tap_mark` ships on web only today; macOS gets it via a
            // follow-up that wires the AX tree as the probe — see wiki
            // Roadmap "Set-of-Mark targeting on iOS + macOS".
            throw UXDriverError.unsupportedTool(name: call.tool.rawValue, platform: .macosApp)
        }
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
}

enum MacDriverError: Error, Sendable, LocalizedError {
    case appNotRunning(bundleID: String)
    case windowNotFound(bundleID: String)
    case captureFailed
    case eventCreationFailed(action: String)
    case unknownKey(name: String)

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
