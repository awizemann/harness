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
