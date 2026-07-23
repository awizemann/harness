//
//  MacInputBackendTests.swift
//  HarnessTests
//
//  Pins the contained-input containment contract for macOS driving
//  (Phase H1). The live actuation itself needs Accessibility + Screen
//  Recording TCC grants and a running SUT — deferred to the O2 live
//  probe — so this suite pins the parts that are pure and decidable
//  without a machine at hand:
//
//    - backend selection from the environment flag,
//    - the per-tool actuation ladder (which is the single source the
//      driver's runtime walks), and
//    - the honest-failure error mapping.
//
//  The load-bearing invariant: in `.contained` mode NO tool's ladder
//  may contain a global-HID rung, and in `.hid` mode NO tool's ladder
//  may contain an AX rung. If either regresses, containment (or the
//  legacy escape hatch) is silently broken — these tests fail first.
//

import Testing
import Foundation
@testable import Harness

@Suite("MacInputBackend — selection + ladder + errors")
struct MacInputBackendTests {

    // MARK: - Backend selection from environment

    @Test("Unset HARNESS_MACOS_INPUT → contained (the default)")
    func defaultIsContained() {
        #expect(MacInputBackendKind.fromEnvironment([:]) == .contained)
    }

    @Test("HARNESS_MACOS_INPUT=hid → legacy HID backend")
    func hidSelectsLegacy() {
        #expect(MacInputBackendKind.fromEnvironment(["HARNESS_MACOS_INPUT": "hid"]) == .hid)
    }

    @Test("HARNESS_MACOS_INPUT is case-insensitive", arguments: ["HID", "Hid", "hId"])
    func hidCaseInsensitive(_ value: String) {
        #expect(MacInputBackendKind.fromEnvironment(["HARNESS_MACOS_INPUT": value]) == .hid)
    }

    @Test("Any non-'hid' value falls back to contained", arguments: ["", "contained", "ax", "1", "true"])
    func unknownValueIsContained(_ value: String) {
        #expect(MacInputBackendKind.fromEnvironment(["HARNESS_MACOS_INPUT": value]) == .contained)
    }

    @Test("Only legacy HID foregrounds / activates")
    func foregroundAndActivateGating() {
        #expect(MacInputBackendKind.contained.requiresForeground == false)
        #expect(MacInputBackendKind.contained.activatesOnLaunch == false)
        #expect(MacInputBackendKind.hid.requiresForeground == true)
        #expect(MacInputBackendKind.hid.activatesOnLaunch == true)
    }

    // MARK: - Ladder selection (contained)

    @Test("Contained single click / mark click: AX press first, targeted CGEvent fallback")
    func containedClickLadder() {
        let expected: [MacActuationStep] = [.axPress, .cgEventTargeted]
        #expect(MacActuationPlan.steps(for: .tap(x: 5, y: 5), backend: .contained) == expected)
        #expect(MacActuationPlan.steps(for: .tapMark(id: 3), backend: .contained) == expected)
    }

    @Test("Contained text entry: AX set-value first, targeted keystrokes fallback")
    func containedTypeLadder() {
        let expected: [MacActuationStep] = [.axSetValue, .cgEventTargeted]
        #expect(MacActuationPlan.steps(for: .type(text: "hello"), backend: .contained) == expected)
        #expect(MacActuationPlan.steps(for: .fillCredential(field: .username), backend: .contained) == expected)
    }

    @Test("Contained gestures with no single AX action: targeted CGEvent only")
    func containedGestureLadder() {
        let expected: [MacActuationStep] = [.cgEventTargeted]
        #expect(MacActuationPlan.steps(for: .doubleTap(x: 1, y: 1), backend: .contained) == expected)
        #expect(MacActuationPlan.steps(for: .rightClick(x: 1, y: 1), backend: .contained) == expected)
        #expect(MacActuationPlan.steps(for: .scroll(x: 1, y: 1, dx: 0, dy: 40), backend: .contained) == expected)
        #expect(MacActuationPlan.steps(for: .keyShortcut(keys: ["cmd", "s"]), backend: .contained) == expected)
    }

    // MARK: - Ladder selection (legacy HID)

    @Test("Legacy HID: every actuating tool is a single global-HID rung")
    func hidActuatingLadder() {
        let actuating: [ToolInput] = [
            .tap(x: 1, y: 1), .doubleTap(x: 1, y: 1), .rightClick(x: 1, y: 1),
            .tapMark(id: 1), .type(text: "x"), .fillCredential(field: .password),
            .scroll(x: 1, y: 1, dx: 0, dy: 10), .keyShortcut(keys: ["cmd", "c"])
        ]
        for input in actuating {
            #expect(MacActuationPlan.steps(for: input, backend: .hid) == [.cgEventGlobalHID],
                    "\(input) should be a single global-HID rung under legacy backend")
        }
    }

    // MARK: - Non-actuating tools produce no ladder (either backend)

    @Test("Non-actuating / non-macOS tools have an empty ladder", arguments: [MacInputBackendKind.contained, .hid])
    func nonActuatingHaveNoLadder(_ backend: MacInputBackendKind) {
        let none: [ToolInput] = [
            .wait(ms: 100), .readScreen,
            .noteFriction(kind: .deadEnd, detail: "x"),
            .markGoalDone(verdict: .success, summary: "s", frictionCount: 0, wouldRealUserSucceed: true),
            .swipe(x1: 0, y1: 0, x2: 1, y2: 1, durationMs: 10),
            .pressButton(button: .home),
            .navigate(url: "https://x"), .back, .forward, .refresh
        ]
        for input in none {
            #expect(MacActuationPlan.steps(for: input, backend: backend).isEmpty,
                    "\(input) should have no actuation ladder")
        }
    }

    // MARK: - Containment invariants (the load-bearing tests)

    /// Every ToolInput case, so the invariants below can't be dodged by a
    /// future variant that the point-sample tests forgot to cover.
    private static let allInputs: [ToolInput] = [
        .tap(x: 1, y: 1), .doubleTap(x: 1, y: 1), .rightClick(x: 1, y: 1),
        .tapMark(id: 1), .type(text: "x"), .fillCredential(field: .username),
        .scroll(x: 1, y: 1, dx: 0, dy: 1), .keyShortcut(keys: ["a"]),
        .swipe(x1: 0, y1: 0, x2: 1, y2: 1, durationMs: 1), .pressButton(button: .home),
        .wait(ms: 1), .readScreen,
        .noteFriction(kind: .deadEnd, detail: "x"),
        .markGoalDone(verdict: .success, summary: "s", frictionCount: 0, wouldRealUserSucceed: true),
        .navigate(url: "https://x"), .back, .forward, .refresh
    ]

    @Test("CONTAINMENT: no contained ladder ever contains a global-HID rung")
    func containedNeverUsesGlobalHID() {
        for input in Self.allInputs {
            let steps = MacActuationPlan.steps(for: input, backend: .contained)
            #expect(!steps.contains(.cgEventGlobalHID),
                    "contained ladder for \(input) leaked a global-HID rung: \(steps)")
        }
    }

    @Test("Legacy HID never uses AX rungs (verbatim pointer-driving path)")
    func hidNeverUsesAX() {
        for input in Self.allInputs {
            let steps = MacActuationPlan.steps(for: input, backend: .hid)
            #expect(!steps.contains(.axPress) && !steps.contains(.axSetValue),
                    "legacy HID ladder for \(input) unexpectedly used AX: \(steps)")
            #expect(!steps.contains(.cgEventTargeted),
                    "legacy HID ladder for \(input) unexpectedly used postToPid: \(steps)")
        }
    }

    @Test("AX-first: every contained ladder that touches AX leads with AX, ends with a CGEvent tail")
    func containedAXIsFirstWithCGEventTail() {
        for input in Self.allInputs {
            let steps = MacActuationPlan.steps(for: input, backend: .contained)
            let usesAX = steps.contains(.axPress) || steps.contains(.axSetValue)
            guard usesAX else { continue }
            #expect(steps.first == .axPress || steps.first == .axSetValue,
                    "\(input): AX rung must be attempted first, got \(steps)")
            #expect(steps.last == .cgEventTargeted,
                    "\(input): an AX ladder must have a targeted-CGEvent fallback tail, got \(steps)")
        }
    }

    // MARK: - Honest-failure error mapping

    @Test("unactuatable names the action, the attempts, and the no-HID stance")
    func unactuatableErrorMapping() {
        let error = MacDriverError.unactuatable(
            action: "click(button:0 count:1) at (10,20)",
            detail: "AX press: no actionable AX element at point; CGEvent→pid: CGEvent construction failed"
        )
        let text = error.errorDescription ?? ""
        #expect(text.contains("click(button:0 count:1) at (10,20)"))
        #expect(text.contains("no actionable AX element at point"))
        // The containment promise must be legible in the failure itself.
        #expect(text.contains("No global-HID fallback"))
        #expect(text.contains("HARNESS_MACOS_INPUT=hid"))
    }
}

// MARK: - Preflight-aware capture / window errors

/// The capture and window-not-found messages must not blame Screen Recording
/// permission when preflight says access IS granted — the incident that
/// motivated this: a terminated SUT surfaced a "grant permission" message and
/// cost a diagnostic round. Message selection is a pure function of the
/// preflight bool, so it is decidable here without any real TCC state.
@Suite("MacDriverError — preflight-aware capture / window messages")
struct MacDriverErrorPreflightTests {

    @Test("capture failure with access GRANTED does not blame permissions and suggests re-observing")
    func captureGrantedIsHonest() {
        let msg = MacDriverError.captureFailureMessage(screenAccessGranted: true)
        #expect(!msg.contains("Grant"))
        #expect(!msg.contains("Screen Recording permission"))
        #expect(msg.lowercased().contains("re-observe"))
        // The same message is what the enum surfaces.
        #expect(MacDriverError.captureFailed(screenAccessGranted: true).errorDescription == msg)
    }

    @Test("capture failure with access NOT granted keeps the grant instruction + responsible-process note")
    func captureNotGrantedNudgesGrant() {
        let msg = MacDriverError.captureFailureMessage(screenAccessGranted: false)
        #expect(msg.contains("Screen Recording"))
        #expect(msg.contains("Grant"))
        // TCC attaches to the responsible parent process.
        #expect(msg.contains("harness-mcp"))
        #expect(MacDriverError.captureFailed(screenAccessGranted: false).errorDescription == msg)
    }

    @Test("missing window with access GRANTED is framed as a window problem, not a permissions one")
    func windowGrantedIsWindowProblem() {
        let msg = MacDriverError.windowNotFoundMessage(bundleID: "com.example.App", screenAccessGranted: true)
        #expect(msg.contains("com.example.App"))
        #expect(!msg.contains("Grant"))
        #expect(msg.contains("miniaturized") || msg.contains("still launching") || msg.contains("closed"))
        #expect(MacDriverError.windowNotFound(bundleID: "com.example.App", screenAccessGranted: true).errorDescription == msg)
    }

    @Test("missing window with access NOT granted keeps the grant instruction")
    func windowNotGrantedNudgesGrant() {
        let msg = MacDriverError.windowNotFoundMessage(bundleID: "com.example.App", screenAccessGranted: false)
        #expect(msg.contains("com.example.App"))
        #expect(msg.contains("Grant"))
        #expect(msg.contains("harness-mcp"))
        #expect(MacDriverError.windowNotFound(bundleID: "com.example.App", screenAccessGranted: false).errorDescription == msg)
    }
}
