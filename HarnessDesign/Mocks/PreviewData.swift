//
//  PreviewData.swift
//  Harness — Mocks
//

import SwiftUI
import AppKit

// MARK: - Models (preview-only placeholders)
//
// These are scoped to HarnessDesign #Preview blocks. The application layer's
// real types live in `Harness/Core/Models.swift` (Verdict, ToolKind, FrictionKind).
// We prefix these `Preview*` to avoid type-name collisions with the app target.
enum PreviewVerdict: String, Hashable { case success, failure, blocked }

enum PreviewToolKind: String { case tap, type, swipe, scroll, wait, complete }

struct PreviewToolCall: Hashable {
    let kind: PreviewToolKind
    /// Free-form arg string: `"(124, 480)"`, `"\"milk\""`, `"300ms"`.
    let arg: String?
}

enum PreviewFrictionKind: String, Hashable {
    case ambiguousAffordance = "ambiguous-affordance"
    case missingUndo         = "missing-undo"
    case ambiguousLabel      = "ambiguous-label"
    case deadEnd             = "dead-end"
    case unresponsive        = "unresponsive-control"
}

struct PreviewFriction: Hashable {
    let kind: PreviewFrictionKind
    /// One-line summary the agent supplied for the row.
    let note: String
}

struct PreviewStep: Identifiable, Hashable {
    let id = UUID()
    let n: Int
    let observation: String
    let intent: String
    let action: PreviewToolCall
    let thumbnail: NSImage?
    let friction: PreviewFriction?
}

struct PreviewFrictionEvent: Identifiable, Hashable {
    let id = UUID()
    let timestamp: String   // "00:14"
    let stepN: Int
    let kind: PreviewFrictionKind
    let title: String
    let detail: String
    let agentQuote: String
}

struct PreviewRun: Identifiable, Hashable {
    let id = UUID()
    let goal: String
    let persona: String
    let model: String
    let mode: String        // "Step-by-step" | "Autonomous"
    let project: String
    let scheme: String
    let device: String
    let startedAt: String
    let elapsed: String
    let stepBudget: Int
    let verdict: PreviewVerdict
    var steps: [PreviewStep]
    var friction: [PreviewFrictionEvent]
}

// MARK: - Mock data
extension PreviewStep {
    static let mocks: [PreviewStep] = [
        .init(n: 1, observation: "Empty list with a faint plus glyph in the top-right corner. No visible label.",
              intent: "Tap the plus to add an item.",
              action: .init(kind: .tap, arg: "(338, 92)"),
              thumbnail: nil, friction: nil),
        .init(n: 2, observation: "A modal sheet appeared with a single text field and the title \"New Item\".",
              intent: "Enter \"milk\" in the input field.",
              action: .init(kind: .type, arg: "\"milk\""),
              thumbnail: nil, friction: nil),
        .init(n: 3, observation: "Save button is at the bottom-right of the keyboard accessory bar.",
              intent: "Tap Save to commit.",
              action: .init(kind: .tap, arg: "(338, 716)"),
              thumbnail: nil, friction: nil),
        .init(n: 4, observation: "Modal is dismissing with a slide-down animation.",
              intent: "Wait for the list to re-appear.",
              action: .init(kind: .wait, arg: "300ms"),
              thumbnail: nil, friction: nil),
        .init(n: 5, observation: "List now shows \"milk\" as the only row, with an unfilled circle on the left.",
              intent: "Tap the circle to mark complete.",
              action: .init(kind: .tap, arg: "(48, 218)"),
              thumbnail: nil,
              friction: .init(kind: .ambiguousAffordance,
                              note: "Circle has no visible label or hint copy. Took 2 candidate actions to identify it as a checkbox.")),
        .init(n: 6, observation: "Item appears marked. Strikethrough applied. No confirmation toast.",
              intent: "Swipe left on the row to expose actions.",
              action: .init(kind: .swipe, arg: "← (180, 218)"),
              thumbnail: nil, friction: nil),
        .init(n: 7, observation: "Swipe revealed a Delete action only. No \"unmark\" affordance.",
              intent: "Tap the row body to dismiss the swipe.",
              action: .init(kind: .tap, arg: "(180, 218)"),
              thumbnail: nil, friction: nil),
        .init(n: 8, observation: "Returned to base list state.",
              intent: "Goal complete. Reporting success.",
              action: .init(kind: .complete, arg: nil),
              thumbnail: nil, friction: nil),
    ]
}

extension PreviewFrictionEvent {
    static let mocks: [PreviewFrictionEvent] = [
        .init(timestamp: "00:14", stepN: 5, kind: .ambiguousAffordance,
              title: "Empty checkbox has no label or hint",
              detail: "The circle on the left of each list row functions as a tap-to-complete checkbox, but it has no accessible label, no surrounding text, and no contrasting fill. The agent considered three candidate actions before identifying its purpose.",
              agentQuote: "I see a 22pt unfilled circle to the left of the row text. It could be a bullet, a thumbnail placeholder, or a tap target. Trying tap and observing."),
        .init(timestamp: "00:42", stepN: 7, kind: .missingUndo,
              title: "No way to unmark a completed item",
              detail: "Once an item is marked done, swipe-left only reveals Delete. There is no Unmark action and tapping the filled circle does not toggle.",
              agentQuote: "Swiping the completed row exposed a single red Delete action. I expected an Unmark or Undo. Re-tapping the filled circle has no effect."),
        .init(timestamp: "01:08", stepN: 11, kind: .ambiguousLabel,
              title: "\"More\" overflow menu hides the only path forward",
              detail: "The Save action is not on the visible chrome — it lives behind a three-dot button at the top-right.",
              agentQuote: "Top-right ellipsis appears decorative. I tried Done, Back, swipe-down, and tapping the title. Only the ellipsis advances the flow."),
    ]
}

extension PreviewRun {
    static let mock = PreviewRun(
        goal: "I'm a first-time user. Try to add 'milk' to my list and mark it done.",
        persona: "First-time user, never seen this app",
        model: "Claude Opus 4.7",
        mode: "Step-by-step",
        project: "ListApp",
        scheme: "Debug",
        device: "iPhone 16 Pro · iOS 18.4",
        startedAt: "today, 14:22",
        elapsed: "01:42",
        stepBudget: 40,
        verdict: .success,
        steps: PreviewStep.mocks,
        friction: PreviewFrictionEvent.mocks
    )

    static let mockHistory: [PreviewRun] = [
        .mock,
        .init(goal: "I just got a 2FA code by SMS. Get into my account.",
              persona: "Returning user, locked out",
              model: "Sonnet 4.6", mode: "Autonomous",
              project: "MerchOS", scheme: "Debug", device: "iPhone 16 · iOS 18.4",
              startedAt: "today, 11:03", elapsed: "04:08", stepBudget: 40, verdict: .blocked,
              steps: [], friction: []),
        .init(goal: "Find the export-to-CSV option for my last 30 days of activity.",
              persona: "Power user, frustrated",
              model: "Opus 4.7", mode: "Autonomous",
              project: "MerchOS", scheme: "Debug", device: "iPhone 16 Pro · iOS 18.4",
              startedAt: "today, 09:21", elapsed: "06:55", stepBudget: 40, verdict: .failure,
              steps: [], friction: []),
    ]
}
