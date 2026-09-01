//
//  MacInputBackend.swift
//  Harness
//
//  The input-synthesis seam for `MacAppDriver`. Two backends share the
//  driver's window-resolution + AX-probe scaffolding and differ only in
//  HOW a step is actuated:
//
//   - `.contained` (DEFAULT) — process-targeted, non-interfering. A
//     per-step ladder: AX action first where the target resolves to an
//     actionable element (`kAXPressAction`, or focus + `AXSetValue` for
//     text), then a `CGEvent` delivered to the SUT's own event queue via
//     `postToPid(_:)` for what AX can't express (scroll, shortcuts,
//     raw-coordinate clicks, double/right click). The real pointer never
//     moves; no app is ever activated; there is NO global-HID fallback —
//     when neither path can land, the driver throws
//     `MacDriverError.unactuatable` (honest failure).
//
//   - `.hid` (legacy, opt-in via `HARNESS_MACOS_INPUT=hid`) — the
//     pre-0.8 behavior, preserved verbatim: every event posts to
//     `.cghidEventTap` (the global HID stream — takes over the real
//     mouse/keyboard) and the SUT is foregrounded (`ensureFront()` +
//     launch `activates: true`) so events land on it.
//
//  The backend is chosen once, at driver/adapter construction, from the
//  environment. `MacActuationPlan.steps(for:backend:)` is the single
//  authoritative description of the ladder — the driver's runtime walks
//  exactly these steps, and the unit suite pins them, so the two can't
//  drift.
//

import Foundation

/// Which backend synthesises macOS input for this run. Resolved once, at
/// construction, from `HARNESS_MACOS_INPUT`.
enum MacInputBackendKind: String, Sendable, Equatable {
    /// AX-first + `postToPid`, no pointer movement, no app activation,
    /// no global HID. The default for all macOS driving.
    case contained
    /// Legacy global-HID synthesis + app foregrounding. Opt-in only.
    case hid

    /// `HARNESS_MACOS_INPUT=hid` (case-insensitive) selects the legacy
    /// backend; anything else — including unset — selects `.contained`.
    static func fromEnvironment(_ env: [String: String]) -> MacInputBackendKind {
        env["HARNESS_MACOS_INPUT"]?.lowercased() == "hid" ? .hid : .contained
    }

    /// Only the legacy backend foregrounds the SUT before capture/input.
    /// The contained backend captures background/occluded windows and
    /// posts input to the app's queue, so foregrounding is never needed.
    var requiresForeground: Bool { self == .hid }

    /// Only the legacy backend launches the SUT activated. The contained
    /// backend launches with `activates: false` so the run never steals
    /// the user's focus.
    var activatesOnLaunch: Bool { self == .hid }
}

/// One rung of the actuation ladder. The runtime attempts steps in order
/// and stops at the first that lands; if all are exhausted it throws
/// `MacDriverError.unactuatable`.
enum MacActuationStep: String, Sendable, Equatable {
    /// `AXUIElementPerformAction(element, kAXPressAction)` on the
    /// hit-tested (or mark-resolved) element. Contained only.
    case axPress
    /// Set `kAXFocusedAttribute` on the target text element, then
    /// `AXSetValue(kAXValueAttribute, …)` for whole-value entry.
    /// Contained only.
    case axSetValue
    /// A `CGEvent` posted to the SUT's queue via `postToPid(_:)`. The
    /// real pointer never moves. Contained only.
    case cgEventTargeted
    /// A `CGEvent` posted to `.cghidEventTap` — the global HID stream.
    /// Moves the real pointer / types into whatever is focused. Legacy
    /// (`.hid`) only.
    case cgEventGlobalHID

    /// Human-readable fragment used in the `unactuatable` error detail.
    var label: String {
        switch self {
        case .axPress:          return "AX press"
        case .axSetValue:       return "AX set-value"
        case .cgEventTargeted:  return "CGEvent→pid"
        case .cgEventGlobalHID: return "CGEvent→HID"
        }
    }
}

/// The authoritative ladder: for a given tool + backend, the ordered
/// steps the driver attempts. Pure — no I/O — so it is fully unit-tested
/// and the runtime consults exactly this to stay honest to the tests.
enum MacActuationPlan {
    static func steps(for input: ToolInput, backend: MacInputBackendKind) -> [MacActuationStep] {
        switch input {
        // Single-activation clicks: AX press if the point resolves to an
        // actionable element, else a targeted CGEvent click.
        case .tap, .tapMark:
            return backend == .hid ? [.cgEventGlobalHID] : [.axPress, .cgEventTargeted]

        // Text entry: whole-value AXSetValue on the focused/target field,
        // else targeted synthetic keystrokes.
        case .type, .fillCredential:
            return backend == .hid ? [.cgEventGlobalHID] : [.axSetValue, .cgEventTargeted]

        // Gestures AX has no single-action equivalent for → targeted
        // CGEvent only (contained) or global HID (legacy).
        case .doubleTap, .rightClick, .scroll, .keyShortcut:
            return backend == .hid ? [.cgEventGlobalHID] : [.cgEventTargeted]

        // Non-actuating tools (no input synthesis) and tools the macOS
        // adapter never advertises. No ladder.
        case .swipe, .pressButton, .navigate, .back, .forward, .refresh,
             .scrollIntoView, .wait, .readScreen, .noteFriction, .markGoalDone:
            return []
        }
    }
}
