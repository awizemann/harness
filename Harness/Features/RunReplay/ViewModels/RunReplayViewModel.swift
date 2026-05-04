//
//  RunReplayViewModel.swift
//  Harness
//

import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

@Observable
@MainActor
final class RunReplayViewModel {

    struct StepView: Sendable, Identifiable, Equatable {
        let id: Int
        let n: Int
        let observation: String
        let intent: String
        let toolKind: String
        let toolArg: String?
        let success: Bool
        let frictionEvents: [FrictionEvent]
        let screenshotURL: URL
    }

    /// One leg as displayed in the replay timeline. Built from the
    /// parser's `ReplayLeg` (one per `leg_started`/`leg_completed` pair
    /// in v2 logs, or one synthetic leg around all steps for v1 logs).
    /// `firstStepIndex` is the 0-based offset into `steps` where the
    /// leg starts — the timeline scrubber consumes this to render leg
    /// boundary ticks.
    struct LegView: Sendable, Identifiable, Equatable {
        let id: Int
        let index: Int
        let actionName: String
        let goal: String
        let preservesState: Bool
        let verdict: Verdict?
        let summary: String
        /// 0-based offset into `RunReplayViewModel.steps`. Use as the
        /// leg-boundary tick on the scrubber.
        let firstStepIndex: Int
    }

    var meta: RunStartedPayload?
    var verdict: Verdict?
    var summary: String = ""
    var steps: [StepView] = []
    var currentStepIndex: Int = 0
    var loadError: String?
    /// Indices of steps in `steps` that carry at least one friction event.
    /// Computed once at parse time and consumed by the `TimelineScrubber`
    /// to render taller amber ticks at those positions.
    var frictionStepIndices: Set<Int> = []
    /// 0-based step indices into `steps` where each chain leg starts.
    /// Empty for v1 logs and single-leg v2 logs.
    var legBoundaryIndices: Set<Int> = []
    /// One per leg seen in the log. Always at least one entry — single-action
    /// runs synthesize one virtual leg. Sorted by leg `index` ascending.
    var legs: [LegView] = []
    /// True while the initial parse is in flight. The view distinguishes
    /// "still loading" from "loaded with zero steps" so the empty-state copy
    /// doesn't flash before parsing finishes.
    var isLoading: Bool = false

    var currentScreenshot: NSImage? {
        guard !steps.isEmpty,
              currentStepIndex >= 0,
              currentStepIndex < steps.count else { return nil }
        return NSImage(contentsOf: steps[currentStepIndex].screenshotURL)
    }

    var currentStep: StepView? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    /// Optional one-shot step anchor. When set before `load(_:)`, the view
    /// model seeks `currentStepIndex` to the step matching this value
    /// (1-based, clamped) and clears the anchor. Used by FrictionReport's
    /// "Jump to step" deep link.
    var anchorStep: Int?

    func load(runID: UUID) async {
        loadError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try RunLogParser.parse(runID: runID)
            try? RunLogParser.validateInvariants(rows)

            // Aggregate.
            for row in rows {
                if case .runStarted(_, let p) = row { self.meta = p }
                if case .runCompleted(_, let p) = row {
                    self.verdict = Verdict(rawValue: p.verdict)
                    self.summary = p.summary
                }
            }

            // Group by step.
            var byStep: [Int: (StepStartedPayload?, ToolCallPayload?, ToolResultPayload?, [FrictionEvent])] = [:]
            for row in rows {
                guard let step = row.step else { continue }
                var existing = byStep[step] ?? (nil, nil, nil, [])
                switch row {
                case .stepStarted(_, let p): existing.0 = p
                case .toolCall(_, let p): existing.1 = p
                case .toolResult(_, let p): existing.2 = p
                case .friction(_, let p):
                    let kind = FrictionKind(rawValue: p.frictionKind) ?? .unexpectedState
                    existing.3.append(FrictionEvent(step: step, kind: kind, detail: p.detail))
                default: break
                }
                byStep[step] = existing
            }

            self.steps = byStep.keys.sorted().compactMap { stepNumber in
                guard let entry = byStep[stepNumber] else { return nil }
                let started = entry.0
                let call = entry.1
                let result = entry.2
                let frictions = entry.3
                let screenshotURL = HarnessPaths.screenshot(for: runID, step: stepNumber)
                let toolKind = call?.tool ?? ""
                let toolArg = Self.argDisplay(forToolJSON: call?.inputJSON ?? "")
                return StepView(
                    id: stepNumber,
                    n: stepNumber,
                    observation: call?.observation ?? started?.screenshot ?? "",
                    intent: call?.intent ?? "",
                    toolKind: toolKind,
                    toolArg: toolArg,
                    success: result?.success ?? false,
                    frictionEvents: frictions,
                    screenshotURL: screenshotURL
                )
            }

            frictionStepIndices = Set(
                steps.enumerated()
                    .filter { !$0.element.frictionEvents.isEmpty }
                    .map { $0.offset }
            )

            // Compute legs + their boundaries. v1 logs synthesize one
            // virtual leg around all steps; v2 logs return one per
            // `leg_started`/`leg_completed` pair. Either way we end up
            // with ≥1 entry so view code never special-cases zero legs.
            let parsedLegs = RunLogParser.legViews(from: rows)
            var legViews: [LegView] = []
            var boundaryIndices: Set<Int> = []
            for replayLeg in parsedLegs {
                let firstIdx: Int
                if let stepNumber = replayLeg.stepStart,
                   let idx = steps.firstIndex(where: { $0.n == stepNumber }) {
                    firstIdx = idx
                } else {
                    firstIdx = 0
                }
                legViews.append(LegView(
                    id: replayLeg.index,
                    index: replayLeg.index,
                    actionName: replayLeg.actionName,
                    goal: replayLeg.goal,
                    preservesState: replayLeg.preservesState,
                    verdict: replayLeg.verdict,
                    summary: replayLeg.summary,
                    firstStepIndex: firstIdx
                ))
                // Don't render a "leg 0" boundary on the first step —
                // the timeline already shows step 0 implicitly. Only
                // boundaries for legs 1+ are useful as visual dividers.
                if replayLeg.index > 0, replayLeg.stepStart != nil {
                    boundaryIndices.insert(firstIdx)
                }
            }
            self.legs = legViews
            self.legBoundaryIndices = boundaryIndices

            if let anchor = anchorStep,
               let idx = steps.firstIndex(where: { $0.n == anchor }) {
                currentStepIndex = idx
            } else {
                currentStepIndex = 0
            }
            anchorStep = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func step(forward: Bool) {
        let next = currentStepIndex + (forward ? 1 : -1)
        currentStepIndex = max(0, min(steps.count - 1, next))
    }

    static func argDisplay(forToolJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let x = dict["x"], let y = dict["y"] { return "(\(x), \(y))" }
        if let text = dict["text"] as? String { return "\"\(text)\"" }
        if let ms = dict["ms"] { return "\(ms)ms" }
        if let button = dict["button"] as? String { return button }
        if let verdict = dict["verdict"] as? String { return verdict }
        return nil
    }
}
