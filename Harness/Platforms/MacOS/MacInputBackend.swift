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

/// What `tap_mark` MEANS for the element under the badge (WB-23).
///
/// Before this, every `tap_mark` was a press, and on the two roles a form
/// flow actually needs — a text field and a table row — `kAXPressAction`
/// either isn't advertised or does nothing, so the engine reported a step
/// that never happened and the next `type` landed wherever focus already
/// was. The intent is a pure function of the mark's ROLE so it is
/// predictable from the mark table alone: a client can read the row and know
/// what the tap will do before it calls.
enum MacMarkIntent: String, Sendable, Equatable {
    /// Activate the control (`kAXPressAction`, else a targeted click).
    /// Buttons, menu items, checkboxes, links — everything not below.
    case press
    /// Give the control keyboard focus WITHOUT activating it. Text-entry
    /// roles: the caller's next step is almost always `type`, and focus is
    /// exactly what makes that land in the field they addressed.
    case focus
    /// SELECT the row — not open it. A single click selects in every
    /// standard AppKit / SwiftUI list; opening is a double click, and it is
    /// reachable as `double_tap`, which already exists in the vocabulary.
    /// Keeping the two apart is what makes `tap_mark` on a row safe to call
    /// on a list whose activation navigates away.
    case select
}

/// Which mark roles get which `tap_mark` semantics. Roles are the SHORT
/// form the mark table publishes (`MacMarkProbe.shortRole`), so this reads
/// against exactly what a client sees.
enum MacMarkActuationPolicy {
    /// Text-entry roles → focus. Matches `MacMarkProbe.textEntryRoles`, in
    /// short form.
    static let focusRoles: Set<String> = [
        "textField", "textArea", "comboBox", "searchField", "secureTextField"
    ]

    /// Row-ish roles → select. A cell is included because a click lands on a
    /// cell far more often than on the row that owns it, and the driver
    /// climbs to the owning row before selecting.
    static let selectRoles: Set<String> = ["row", "cell"]

    static func intent(forRole role: String) -> MacMarkIntent {
        if focusRoles.contains(role) { return .focus }
        if selectRoles.contains(role) { return .select }
        return .press
    }
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
    /// Set `kAXFocusedAttribute` on the mark's own element, verified by
    /// read-back. What `tap_mark` on a TEXT FIELD means (WB-23): AXPress on
    /// a field is a no-op, so pressing it reported a step that never
    /// happened. Contained only.
    case axFocus
    /// Select the mark's row — `kAXSelectedAttribute` on the row, else
    /// `kAXSelectedRowsAttribute` on its table / outline — verified by
    /// read-back. What `tap_mark` on a ROW means (WB-23). Contained only.
    case axSelect
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
        case .axFocus:          return "AX focus"
        case .axSelect:         return "AX select"
        case .cgEventTargeted:  return "CGEvent→pid"
        case .cgEventGlobalHID: return "CGEvent→HID"
        }
    }
}

/// The authoritative ladder: for a given tool + backend, the ordered
/// steps the driver attempts. Pure — no I/O — so it is fully unit-tested
/// and the runtime consults exactly this to stay honest to the tests.
enum MacActuationPlan {
    static func steps(
        for input: ToolInput,
        backend: MacInputBackendKind,
        markIntent: MacMarkIntent = .press
    ) -> [MacActuationStep] {
        switch input {
        // Single-activation clicks: AX press if the point resolves to an
        // actionable element, else a targeted CGEvent click. `tap_mark`
        // additionally reads its intent from the MARK'S ROLE (WB-23) — a
        // field wants focus and a row wants selection, and pressing either
        // is the no-op that made them unaddressable.
        case .tapMark:
            if backend == .hid { return [.cgEventGlobalHID] }
            switch markIntent {
            case .press:  return [.axPress, .cgEventTargeted]
            case .focus:  return [.axFocus, .cgEventTargeted]
            case .select: return [.axSelect, .cgEventTargeted]
            }
        case .tap:
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
