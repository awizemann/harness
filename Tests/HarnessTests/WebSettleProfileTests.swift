//
//  WebSettleProfileTests.swift
//  HarnessTests
//
//  Pins the post-action settle policy (W3). The JS gate itself needs a live
//  WKWebView and is covered by the live smoke (`ui-session-smoke.py`, the
//  async-swap fixture); what's unit-testable — and what actually regressed —
//  is the ENVELOPE CHOICE: which tools arm observation before dispatch, and
//  which window each tool class gets.
//

import Testing
import Foundation
@testable import Harness

@Suite("WebSettleProfile — post-action settle policy")
struct WebSettleProfileTests {

    @Test("navigation tools always take the navigation envelope")
    func navigationTools() {
        for input in [ToolInput.navigate(url: "https://example.com"), .back, .forward, .refresh] {
            let p = WebSettleProfile.profile(for: input, clickNavigated: false)
            #expect(p == .navigation)
            #expect(p.requireChildListMutation)
            #expect(!p.usesArmedObservation, "navigations bring their own post-hoc gate")
        }
    }

    @Test("a non-navigating click uses the ARMED envelope, not the post-hoc one")
    func nonNavigatingClick() {
        let p = WebSettleProfile.profile(for: .tapMark(id: 3), clickNavigated: false)
        #expect(p == .nonNavigatingAction)
        #expect(p.usesArmedObservation)
        // The regression this exists to prevent: a same-URL swap that lands
        // ~500ms later must be inside the ceiling, and the idle floor must
        // stay at 250ms so a genuinely idle page is not slowed down.
        #expect(p.idleMs == 250)
        #expect(p.minMs == 250)
        #expect(p.maxMs == 3000)
        #expect(!p.requireChildListMutation,
                "requiring a mutation would pin every genuine no-op tap to the ceiling")
    }

    @Test("a click that changed location.href escalates to the navigation envelope")
    func navigatingClickEscalates() {
        let p = WebSettleProfile.profile(for: .tap(x: 10, y: 10), clickNavigated: true)
        #expect(p == .navigation)
        #expect(p.requireChildListMutation)
    }

    @Test("pure-read / off-platform tools get no settle at all")
    func noSettleTools() {
        for input in [ToolInput.wait(ms: 100), .readScreen,
                      .noteFriction(kind: .deadEnd, detail: "x"),
                      .markGoalDone(verdict: .success, summary: "s", frictionCount: 0, wouldRealUserSucceed: true),
                      .pressButton(button: .home)] {
            #expect(WebSettleProfile.profile(for: input, clickNavigated: false) == .none)
        }
    }

    @Test("exactly the DOM-affecting non-navigating tools arm observation")
    func armingSet() {
        let arming: [ToolInput] = [
            .tap(x: 1, y: 1), .tapMark(id: 1), .doubleTap(x: 1, y: 1), .rightClick(x: 1, y: 1),
            .scroll(x: 1, y: 1, dx: 0, dy: 100), .type(text: "hi"),
            .keyShortcut(keys: ["cmd", "a"]), .fillCredential(field: .username)
        ]
        for input in arming {
            #expect(WebSettleProfile.armsObservation(for: input), "\(input) should arm")
        }
        let notArming: [ToolInput] = [
            .navigate(url: "https://example.com"), .back, .forward, .refresh,
            .wait(ms: 10), .readScreen,
            .noteFriction(kind: .deadEnd, detail: "x"),
            .markGoalDone(verdict: .success, summary: "s", frictionCount: 0, wouldRealUserSucceed: true)
        ]
        for input in notArming {
            #expect(!WebSettleProfile.armsObservation(for: input), "\(input) should not arm")
        }
    }

    @Test("every armed tool's profile actually uses armed observation when it didn't navigate")
    func armingAgreesWithProfile() {
        let inputs: [ToolInput] = [
            .tap(x: 1, y: 1), .tapMark(id: 1), .doubleTap(x: 1, y: 1), .rightClick(x: 1, y: 1),
            .scroll(x: 1, y: 1, dx: 0, dy: 10), .type(text: "x"),
            .keyShortcut(keys: ["enter"]), .fillCredential(field: .password)
        ]
        for input in inputs {
            let armed = WebSettleProfile.armsObservation(for: input)
            let uses = WebSettleProfile.profile(for: input, clickNavigated: false).usesArmedObservation
            #expect(armed == uses, "arming and the settle envelope must agree for \(input)")
        }
    }

    @Test("the non-navigating ceiling never exceeds the navigation ceiling")
    func ceilingOrdering() {
        #expect(WebSettleProfile.nonNavigatingAction.maxMs < WebSettleProfile.navigation.maxMs)
        #expect(WebSettleProfile.nonNavigatingAction.idleMs < WebSettleProfile.navigation.idleMs)
    }
}
