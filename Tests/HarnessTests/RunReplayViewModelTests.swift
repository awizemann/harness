//
//  RunReplayViewModelTests.swift
//  HarnessTests
//
//  Regression tests for RunReplayViewModel — particularly the empty-steps
//  case that crashed the app pre-fix. The crash was in `RunReplayView.scrubber`
//  rendering `Slider(in: 0...0, step: 1)`, which SwiftUI rejects with a
//  precondition. The viewmodel can't directly trigger a SwiftUI assertion in
//  unit tests, but we can verify it lands in a sane state when given inputs
//  the view's empty-state branch handles correctly.
//

import Testing
import Foundation
@testable import Harness

@Suite("RunReplayViewModel — empty / partial run loads")
struct RunReplayViewModelTests {

    @Test("Run with only a runStarted row: loads, exposes meta, zero steps")
    @MainActor
    func runStartedOnly() async throws {
        let runID = UUID()
        try Self.write(rows: [.runStarted(from: Self.makeGoalRequest(id: runID))], runID: runID)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        let vm = RunReplayViewModel()
        await vm.load(runID: runID)

        #expect(vm.loadError == nil)
        #expect(vm.steps.isEmpty)
        #expect(vm.meta != nil)
        #expect(vm.currentStepIndex == 0)
        #expect(vm.currentStep == nil)
        #expect(vm.currentScreenshot == nil)
        #expect(vm.isLoading == false)
    }

    @Test("Run with one full step: loads, currentStep returns it, no out-of-bounds")
    @MainActor
    func singleStepRun() async throws {
        let runID = UUID()
        let req = Self.makeGoalRequest(id: runID)
        try Self.write(rows: [
            .runStarted(from: req),
            .stepStarted(StepStartedPayload(step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0)),
            .toolCall(step: 1, call: ToolCall(
                tool: .tap, input: .tap(x: 100, y: 200),
                observation: "obs", intent: "intent")),
            .toolResult(ToolResultPayload(
                step: 1, tool: "tap", success: true, durationMs: 10,
                error: nil, userDecision: nil, userNote: nil)),
            .stepCompleted(StepCompletedPayload(step: 1, durationMs: 100, tokensInput: 1, tokensOutput: 1)),
            .runCompleted(RunCompletedPayload(
                verdict: "success", summary: "Did it.", frictionCount: 0,
                wouldRealUserSucceed: true, stepCount: 1,
                tokensUsedInputTotal: 1, tokensUsedOutputTotal: 1))
        ], runID: runID)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        let vm = RunReplayViewModel()
        await vm.load(runID: runID)

        #expect(vm.loadError == nil)
        #expect(vm.steps.count == 1)
        #expect(vm.currentStep?.n == 1)
        #expect(vm.verdict == .success)
        // Stepping past the bounds clamps; should never set out-of-range.
        vm.step(forward: true)
        #expect(vm.currentStepIndex == 0)
        vm.step(forward: false)
        #expect(vm.currentStepIndex == 0)
    }

    @Test("Step navigation clamps bounds for multi-step runs")
    @MainActor
    func stepNavigationClamps() async throws {
        let runID = UUID()
        let req = Self.makeGoalRequest(id: runID)
        var rows: [LogRow] = [.runStarted(from: req)]
        for n in 1...3 {
            rows.append(.stepStarted(StepStartedPayload(
                step: n, screenshot: "step-\(String(format: "%03d", n)).png", tokensUsedSoFar: 0)))
            rows.append(.toolCall(step: n, call: ToolCall(
                tool: .tap, input: .tap(x: n, y: n),
                observation: "obs-\(n)", intent: "intent-\(n)")))
            rows.append(.toolResult(ToolResultPayload(
                step: n, tool: "tap", success: true, durationMs: 10,
                error: nil, userDecision: nil, userNote: nil)))
            rows.append(.stepCompleted(StepCompletedPayload(
                step: n, durationMs: 100, tokensInput: 1, tokensOutput: 1)))
        }
        rows.append(.runCompleted(RunCompletedPayload(
            verdict: "success", summary: "", frictionCount: 0,
            wouldRealUserSucceed: true, stepCount: 3,
            tokensUsedInputTotal: 3, tokensUsedOutputTotal: 3)))
        try Self.write(rows: rows, runID: runID)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        let vm = RunReplayViewModel()
        await vm.load(runID: runID)
        #expect(vm.steps.count == 3)
        vm.step(forward: true); vm.step(forward: true); vm.step(forward: true); vm.step(forward: true)
        #expect(vm.currentStepIndex == 2, "should clamp to last index")
        vm.step(forward: false); vm.step(forward: false); vm.step(forward: false)
        #expect(vm.currentStepIndex == 0, "should clamp to first index")
    }

    @Test("Non-existent run yields a load error, not a crash")
    @MainActor
    func nonexistentRunFailsCleanly() async {
        let vm = RunReplayViewModel()
        await vm.load(runID: UUID())  // never written
        #expect(vm.loadError != nil)
        #expect(vm.steps.isEmpty)
        #expect(vm.isLoading == false)
    }

    // MARK: Helpers

    private static func makeGoalRequest(id: UUID) -> GoalRequest {
        GoalRequest(
            id: id,
            goal: "test goal",
            persona: "first-time user",
            project: ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/X.xcodeproj"),
                scheme: "X",
                displayName: "X"),
            simulator: SimulatorRef(
                udid: "FAKE", name: "iPhone 16 Pro", runtime: "iOS 18.4",
                pointSize: CGSize(width: 430, height: 932), scaleFactor: 3.0),
            model: .opus47,
            mode: .stepByStep
        )
    }

    /// Synchronously stamp a JSONL run dir for a test fixture. Goes through
    /// `RunLogger.encode(_:runID:ts:)` so the on-disk format matches production.
    private static func write(rows: [LogRow], runID: UUID) throws {
        try HarnessPaths.prepareRunDirectory(for: runID)
        let url = HarnessPaths.eventsLog(for: runID)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for row in rows {
            let data = try RunLogger.encode(row, runID: runID, ts: Date())
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }
}
