//
//  WebSettleProfile.swift
//  Harness
//
//  The post-action "is the page done changing yet?" envelope, extracted from
//  `WebDriver.settle(afterTool:)` so the policy is a pure, unit-testable
//  value instead of a switch buried in an actor that needs WebKit to run.
//
//  ## The bug this extraction was made to fix (W3)
//
//  A tap that caused a SAME-URL React state swap (contact form → success
//  screen, the swap landing ~500ms later behind an `await fetch(...)`)
//  returned the PRE-action frame: settle finished at ~481ms, before the new
//  DOM existed. A tap that changed the route settled correctly at 6.5s.
//
//  Root cause, precisely: the MutationObserver gate was armed AFTER the click
//  had already been dispatched, and its only exit condition was "no mutations
//  for `idleMs`". A page that has not YET reacted is indistinguishable, by
//  that test, from a page that will never react — so the gate resolved at its
//  250ms floor and the capture beat the swap. The navigating case only looked
//  healthy because `requireChildListMutation` forced it to wait for evidence.
//
//  ## The fix
//
//  Non-navigating actions now use the ARMED profile: observation is installed
//  BEFORE the action is dispatched (so mutations produced inside the click
//  handler itself are counted, not missed), and the gate additionally waits
//  for the page's own pending async work — `setTimeout` callbacks scheduled
//  with a short delay, in-flight `fetch`, in-flight `XMLHttpRequest` — to
//  drain before it will accept quietness.
//
//  That keeps a genuinely idle page fast: a tap that schedules nothing and
//  fetches nothing has `pending == 0` immediately and still resolves at the
//  250ms idle floor — no regression. Only a page that actually has work in
//  flight waits for it, and never past `maxMs`.
//
//  We deliberately do NOT require a childList mutation here (the way the
//  navigation profile does): that would make every genuine no-op tap pay the
//  full ceiling, which is exactly the "don't slow down idle pages" line.
//

import Foundation

/// How the driver should wait after one tool call.
struct WebSettleProfile: Sendable, Hashable {

    /// Quiet period, in ms, the DOM must go without mutations.
    let idleMs: Int
    /// Floor on the total wait.
    let minMs: Int
    /// Ceiling on the total wait.
    let maxMs: Int
    /// Refuse to resolve until at least one structural (childList) mutation
    /// has been seen. The route-transition guard — see `WebDriver`.
    let requireChildListMutation: Bool
    /// Use the pre-armed observer (installed before dispatch) and additionally
    /// wait for the page's pending short timers / fetches / XHRs to drain.
    /// False → the legacy after-the-fact observer.
    let usesArmedObservation: Bool

    /// No wait at all (pure-read / state-emit tools).
    static let none = WebSettleProfile(idleMs: 0, minMs: 0, maxMs: 0,
                                       requireChildListMutation: false,
                                       usesArmedObservation: false)

    /// Full-page navigation class: `navigate` / `back` / `forward` / `refresh`,
    /// and click-family actions that changed `location.href`.
    static let navigation = WebSettleProfile(idleMs: 600, minMs: 600, maxMs: 8000,
                                             requireChildListMutation: true,
                                             usesArmedObservation: false)

    /// Non-navigating action class. Idle window unchanged from the historical
    /// 250ms; ceiling raised 2000 → 3000ms to leave room for a real async
    /// state swap to land, which only a page with work in flight ever uses.
    static let nonNavigatingAction = WebSettleProfile(idleMs: 250, minMs: 250, maxMs: 3000,
                                                      requireChildListMutation: false,
                                                      usesArmedObservation: true)

    /// Is this tool one whose effect can change the DOM without changing the
    /// URL? Those are the calls the driver arms observation for, BEFORE
    /// dispatch. (`wait` and the meta tools change nothing; navigations get
    /// the navigation profile, which brings its own observer.)
    static func armsObservation(for input: ToolInput) -> Bool {
        switch input {
        case .tap, .tapMark, .doubleTap, .rightClick,
             .scroll, .scrollIntoView, .type, .keyShortcut, .fillCredential:
            return true
        case .navigate, .back, .forward, .refresh,
             .wait, .readScreen, .noteFriction, .markGoalDone,
             .swipe, .pressButton:
            return false
        }
    }

    /// Pick the envelope for a tool call.
    ///
    /// - Parameter clickNavigated: the driver's `lastClickNavigated` flag — a
    ///   click that pushed a new `location.href` gets the navigation profile
    ///   (React Suspense keeps the OLD route's DOM mounted through a quiet
    ///   window, so only a structural mutation proves the new one mounted).
    static func profile(for input: ToolInput, clickNavigated: Bool) -> WebSettleProfile {
        switch input {
        case .navigate, .back, .forward, .refresh:
            return .navigation
        case .tap, .tapMark, .doubleTap, .rightClick,
             .scroll, .scrollIntoView, .type, .keyShortcut, .fillCredential:
            return clickNavigated ? .navigation : .nonNavigatingAction
        case .wait, .readScreen, .noteFriction, .markGoalDone,
             .swipe, .pressButton:
            return .none
        }
    }
}
