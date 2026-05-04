//
//  CrashResilienceTests.swift
//  HarnessTests
//
//  When Harness is force-quit (or crashes) mid-run, the JSONL events log
//  ends in a state somewhere between "valid prefix only" and "valid prefix
//  plus a half-flushed tail row." The replay path must load whatever did
//  flush, never crash on partial state, and never lose the rows that
//  reached disk.
//
//  These tests exercise three flavors of mid-run kill:
//    1. Kill mid-row (a row's bytes were partially flushed).
//    2. Kill mid-step (clean prefix that's missing tool_result + step_completed).
//    3. Garbage trailing bytes appended after a clean run (e.g. a spinner-progress
//       dump or unrelated tool's stdout).
//
//  Pairs with `RunLoggerTests.partialTrailingLine()` (single-row truncation
//  case) and `RunReplayViewModelTests.runStartedOnly()` (zero-step case).
//

import Testing
import Foundation
@testable import Harness

@Suite("Crash resilience — partial run logs replay safely")
struct CrashResilienceTests {

    @Test("Mid-row truncation: parser returns the valid prefix, no throw")
    func midRowTruncation() async throws {
        let runID = UUID()
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        // Write a clean run_started + step_started, then close the handle and
        // append a half-encoded JSON row (no closing brace, no newline).
        let logger = try await RunLogger.open(runID: runID)
        try await logger.append(.runStarted(from: Self.makeRequest(id: runID)))
        try await logger.append(.stepStarted(StepStartedPayload(
            step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
        )))
        await logger.close()

        let url = HarnessPaths.eventsLog(for: runID)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Half-flushed row: opening JSON brace + a few keys, no closing brace.
        try handle.write(contentsOf: Data(#"{"schemaVersion":1,"kind":"tool_call","step":1,"to"#.utf8))
        try handle.close()

        let rows = try RunLogParser.parse(runID: runID)
        #expect(rows.count == 2, "valid prefix should survive — partial last line dropped")
        if case .runStarted = rows[0] {} else { Issue.record("first row should be runStarted") }
        if case .stepStarted = rows[1] {} else { Issue.record("second row should be stepStarted") }
    }

    @Test("Mid-step truncation: replay loads without crash, exposes the partial step")
    @MainActor
    func midStepTruncation() async throws {
        let runID = UUID()
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        // Clean prefix that ends after `tool_call` — no `tool_result`, no
        // `step_completed`, no `run_completed`. Models a force-quit between
        // the model's tool decision and idb dispatching it.
        let req = Self.makeRequest(id: runID)
        try Self.writeRows([
            .runStarted(from: req),
            .stepStarted(StepStartedPayload(
                step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
            )),
            .toolCall(step: 1, call: ToolCall(
                tool: .tap, input: .tap(x: 100, y: 200),
                observation: "I see a + button.",
                intent: "Tap the + to add an item."
            )),
        ], runID: runID)

        let vm = RunReplayViewModel()
        await vm.load(runID: runID)

        #expect(vm.loadError == nil, "partial run should load, not error")
        #expect(vm.meta != nil)
        #expect(vm.steps.count == 1, "the partial step should still be exposed")
        #expect(vm.currentStep?.toolKind == "tap")
        #expect(vm.currentStep?.success == false, "missing tool_result → success defaults to false")
        #expect(vm.verdict == nil, "no run_completed → no verdict")

        // Bounds-step navigation must not crash on a single partial step.
        vm.step(forward: true)
        #expect(vm.currentStepIndex == 0)
        vm.step(forward: false)
        #expect(vm.currentStepIndex == 0)
    }

    @Test("Trailing garbage after a complete run is ignored")
    func trailingGarbageIgnored() async throws {
        let runID = UUID()
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        // A complete run, then a chunk of unrelated bytes (e.g., a tail of
        // build progress that got merged into the file by a runaway Process
        // pipe). Parser should surface every legitimate row and drop the rest.
        let logger = try await RunLogger.open(runID: runID)
        try await logger.append(.runStarted(from: Self.makeRequest(id: runID)))
        try await logger.append(.stepStarted(StepStartedPayload(
            step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
        )))
        try await logger.append(.toolCall(step: 1, call: ToolCall(
            tool: .tap, input: .tap(x: 50, y: 60),
            observation: "obs", intent: "intent"
        )))
        try await logger.append(.toolResult(ToolResultPayload(
            step: 1, tool: "tap", success: true, durationMs: 12,
            error: nil, userDecision: nil, userNote: nil
        )))
        try await logger.append(.stepCompleted(StepCompletedPayload(
            step: 1, durationMs: 80, tokensInput: 100, tokensOutput: 20
        )))
        try await logger.append(.runCompleted(RunCompletedPayload(
            verdict: "success", summary: "ok", frictionCount: 0,
            wouldRealUserSucceed: true, stepCount: 1,
            tokensUsedInputTotal: 100, tokensUsedOutputTotal: 20
        )))
        await logger.close()

        let url = HarnessPaths.eventsLog(for: runID)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("xcodebuild: progress 18%\nLD /Path/Some.dylib\n".utf8))
        try handle.close()

        let rows = try RunLogParser.parse(runID: runID)
        #expect(rows.count == 6, "every legitimate row survives; non-JSON tail is silently skipped")
        if case .runCompleted = rows.last! {
            // ok
        } else {
            Issue.record("last decoded row should still be run_completed")
        }
    }

    // MARK: Helpers

    private static func makeRequest(id: UUID) -> GoalRequest {
        GoalRequest(
            id: id,
            goal: "Add 'milk' and mark it done.",
            persona: "first-time user",
            project: ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/Sample.xcodeproj"),
                scheme: "Sample",
                displayName: "Sample"
            ),
            simulator: SimulatorRef(
                udid: "FAKE-UDID",
                name: "iPhone 16 Pro",
                runtime: "iOS 18.4",
                pointSize: CGSize(width: 430, height: 932),
                scaleFactor: 3.0
            ),
            model: .opus47,
            mode: .stepByStep
        )
    }

    /// Writes rows directly via the production encoder so the on-disk format
    /// matches what RunLogger would have produced. Skips actor lifecycle so
    /// fixtures can be assembled synchronously inside a test.
    private static func writeRows(_ rows: [LogRow], runID: UUID) throws {
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
