//
//  RunLoggerTests.swift
//  HarnessTests
//
//  Round-trip and crash-tolerance tests for RunLogger + RunLogParser.
//  Per `standards/10-testing.md §6`, every change to the logger or schema
//  must keep these green.
//

import Testing
import Foundation
@testable import Harness

@Suite("RunLogger round-trip")
struct RunLoggerRoundTripTests {

    @Test("Full happy-path run round-trips through parser intact")
    func fullRoundTrip() async throws {
        let runID = UUID()
        let logger = try RunLogger.open(runID: runID)
        defer {
            Task { await logger.close() }
            try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID))
        }

        let request = Self.makeGoalRequest()
        try await logger.append(.runStarted(from: request))

        // Step 1 — tap with friction.
        let pngData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes; opaque to logger.
        _ = try await logger.writeScreenshot(pngData, step: 1)
        try await logger.append(.stepStarted(StepStartedPayload(
            step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
        )))
        try await logger.append(.toolCall(step: 1, call: ToolCall(
            tool: .tap,
            input: .tap(x: 200, y: 400),
            observation: "Empty list with a + button bottom-right.",
            intent: "Tap the + to add an item."
        )))
        try await logger.append(.toolResult(ToolResultPayload(
            step: 1, tool: "tap", success: true, durationMs: 47,
            error: nil, userDecision: nil, userNote: nil
        )))
        try await logger.append(.friction(FrictionPayload(
            step: 1, frictionKind: FrictionKind.ambiguousLabel.rawValue,
            detail: "Plus button has no visible label."
        )))
        try await logger.append(.stepCompleted(StepCompletedPayload(
            step: 1, durationMs: 4218, tokensInput: 4820, tokensOutput: 311
        )))

        // Step 2 — type "milk".
        _ = try await logger.writeScreenshot(pngData, step: 2)
        try await logger.append(.stepStarted(StepStartedPayload(
            step: 2, screenshot: "step-002.png", tokensUsedSoFar: 5131
        )))
        try await logger.append(.toolCall(step: 2, call: ToolCall(
            tool: .type,
            input: .type(text: "milk"),
            observation: "Text field is focused; keyboard up.",
            intent: "Type the item name."
        )))
        try await logger.append(.toolResult(ToolResultPayload(
            step: 2, tool: "type", success: true, durationMs: 102,
            error: nil, userDecision: "approved", userNote: nil
        )))
        try await logger.append(.stepCompleted(StepCompletedPayload(
            step: 2, durationMs: 3110, tokensInput: 5012, tokensOutput: 287
        )))

        let outcome = RunOutcome(
            verdict: .success,
            summary: "Added 'milk', marked done.",
            frictionCount: 1,
            wouldRealUserSucceed: true,
            stepCount: 2,
            tokensUsedInput: 9832,
            tokensUsedOutput: 598,
            completedAt: Date()
        )
        try await logger.append(.runCompleted(RunCompletedPayload(
            verdict: outcome.verdict.rawValue,
            summary: outcome.summary,
            frictionCount: outcome.frictionCount,
            wouldRealUserSucceed: outcome.wouldRealUserSucceed,
            stepCount: outcome.stepCount,
            tokensUsedInputTotal: outcome.tokensUsedInput,
            tokensUsedOutputTotal: outcome.tokensUsedOutput
        )))

        try await logger.writeMeta(outcome, request: request)
        await logger.close()

        // Parse back.
        let rows = try RunLogParser.parse(runID: runID)
        try RunLogParser.validateInvariants(rows)

        // Spot-check the structure.
        // 1 run_started + (step1: started/toolCall/toolResult/friction/completed = 5)
        // + (step2: started/toolCall/toolResult/completed = 4) + 1 run_completed = 11.
        #expect(rows.count == 11)
        if case .runStarted(_, let p) = rows[0] {
            #expect(p.goal == request.goal)
            #expect(p.persona == request.persona)
            #expect(p.simulator.udid == request.simulator.udid)
        } else {
            Issue.record("first row not run_started")
        }
        if case .runCompleted(_, let p) = rows.last! {
            #expect(p.verdict == "success")
            #expect(p.frictionCount == 1)
            #expect(p.wouldRealUserSucceed == true)
            #expect(p.stepCount == 2)
        } else {
            Issue.record("last row not run_completed")
        }

        // Tool-call input survived intact.
        if case .toolCall(_, let p) = rows[2] {
            #expect(p.tool == "tap")
            let dict = try JSONSerialization.jsonObject(with: Data(p.inputJSON.utf8)) as? [String: Any]
            #expect(dict?["x"] as? Int == 200)
            #expect(dict?["y"] as? Int == 400)
        }

        // Screenshots written.
        let s1 = HarnessPaths.screenshot(for: runID, step: 1)
        let s2 = HarnessPaths.screenshot(for: runID, step: 2)
        #expect(FileManager.default.fileExists(atPath: s1.path))
        #expect(FileManager.default.fileExists(atPath: s2.path))
        // meta.json written.
        #expect(FileManager.default.fileExists(atPath: HarnessPaths.metaFile(for: runID).path))
    }

    @Test("Truncated trailing line is tolerated by the parser")
    func partialTrailingLine() async throws {
        let runID = UUID()
        let logger = try RunLogger.open(runID: runID)
        defer {
            Task { await logger.close() }
            try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID))
        }

        try await logger.append(.runStarted(from: Self.makeGoalRequest()))
        try await logger.append(.stepStarted(StepStartedPayload(
            step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
        )))
        await logger.close()

        // Append a deliberately corrupt trailing line (no newline; not valid JSON).
        let url = HarnessPaths.eventsLog(for: runID)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("{\"sched".utf8))
            try? handle.close()
        }

        // Parser should give us the two valid rows and silently drop the partial.
        let rows = try RunLogParser.parse(runID: runID)
        #expect(rows.count == 2)
    }

    @Test("Append before run_started throws")
    func appendBeforeStart() async throws {
        let runID = UUID()
        let logger = try RunLogger.open(runID: runID)
        defer {
            Task { await logger.close() }
            try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID))
        }

        do {
            try await logger.append(.stepStarted(StepStartedPayload(
                step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
            )))
            Issue.record("expected throw")
        } catch let e as LogWriteFailure {
            if case .appendBeforeStart = e {} else { Issue.record("wrong failure: \(e)") }
        }
    }

    @Test("Duplicate run_started rejected")
    func duplicateStart() async throws {
        let runID = UUID()
        let logger = try RunLogger.open(runID: runID)
        defer {
            Task { await logger.close() }
            try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID))
        }

        try await logger.append(.runStarted(from: Self.makeGoalRequest()))
        do {
            try await logger.append(.runStarted(from: Self.makeGoalRequest()))
            Issue.record("expected throw")
        } catch let e as LogWriteFailure {
            if case .duplicateStart = e {} else { Issue.record("wrong failure: \(e)") }
        }
    }

    @Test("Append after run_completed rejected")
    func appendAfterCompletion() async throws {
        let runID = UUID()
        let logger = try RunLogger.open(runID: runID)
        defer {
            Task { await logger.close() }
            try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID))
        }

        try await logger.append(.runStarted(from: Self.makeGoalRequest()))
        try await logger.append(.runCompleted(RunCompletedPayload(
            verdict: "blocked", summary: "test", frictionCount: 0,
            wouldRealUserSucceed: false, stepCount: 0,
            tokensUsedInputTotal: 0, tokensUsedOutputTotal: 0
        )))

        do {
            try await logger.append(.stepStarted(StepStartedPayload(
                step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
            )))
            Issue.record("expected throw")
        } catch let e as LogWriteFailure {
            if case .appendAfterCompletion = e {} else { Issue.record("wrong failure: \(e)") }
        }
    }

    @Test("Parser detects step gap")
    func stepGapDetected() throws {
        let runID = UUID()
        let goalReq = Self.makeGoalRequest()
        var data = Data()
        let now = Date()
        // run_started
        let runStarted = try RunLogger.encode(.runStarted(from: goalReq), runID: runID, ts: now)
        data.append(runStarted); data.append(0x0A)
        // step 1
        let s1 = try RunLogger.encode(.stepStarted(StepStartedPayload(
            step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0
        )), runID: runID, ts: now)
        data.append(s1); data.append(0x0A)
        // step 3 (skipped 2!)
        let s3 = try RunLogger.encode(.stepStarted(StepStartedPayload(
            step: 3, screenshot: "step-003.png", tokensUsedSoFar: 0
        )), runID: runID, ts: now)
        data.append(s3); data.append(0x0A)

        let rows = try RunLogParser.parse(jsonlData: data)
        do {
            try RunLogParser.validateInvariants(rows)
            Issue.record("expected step-gap throw")
        } catch ParseError.stepGap(let expected, let got) {
            #expect(expected == 2)
            #expect(got == 3)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: Helpers

    private static func makeGoalRequest() -> GoalRequest {
        GoalRequest(
            id: UUID(),
            goal: "Add 'milk' to my list and mark it done.",
            persona: "first-time user, never seen this app",
            project: ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/SampleApp.xcodeproj"),
                scheme: "Sample",
                displayName: "Sample"
            ),
            simulator: SimulatorRef(
                udid: "B8C5A8F1-FAKE-FAKE-FAKE-AAAAAAAAAAAA",
                name: "iPhone 16 Pro",
                runtime: "iOS 18.4",
                pointSize: CGSize(width: 430, height: 932),
                scaleFactor: 3.0
            ),
            model: .opus47,
            mode: .stepByStep,
            stepBudget: 40,
            tokenBudget: 250_000
        )
    }
}
