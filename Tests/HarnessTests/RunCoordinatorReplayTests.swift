//
//  RunCoordinatorReplayTests.swift
//  HarnessTests
//
//  End-to-end agent-loop test using fakes for builder/driver and a scripted
//  MockLLMClient. Verifies a happy-path "tap → type → mark_done" run produces
//  the expected JSONL row sequence and the expected RunRecord update.
//

import Testing
import Foundation
@testable import Harness

@Suite("RunCoordinator end-to-end replay")
struct RunCoordinatorReplayTests {

    @Test("Happy path: tap → type → mark_goal_done(success)")
    func happyPathReplay() async throws {
        // Three distinct screenshots so the cycle detector doesn't trip.
        let png1 = FakeSimulatorDriver.solidColorPNG(red: 255, green: 0, blue: 0)
        let png2 = FakeSimulatorDriver.solidColorPNG(red: 0, green: 255, blue: 0)
        let png3 = FakeSimulatorDriver.solidColorPNG(red: 0, green: 0, blue: 255)

        let driver = FakeSimulatorDriver(pngs: [png1, png2, png3])
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingTap(x: 200, y: 400, observation: "see + button", intent: "tap to add"),
            LLMStepResponse(
                toolCall: ToolCall(
                    tool: .type,
                    input: .type(text: "milk"),
                    observation: "field focused",
                    intent: "type milk"
                ),
                usage: TokenUsage(inputTokens: 120, outputTokens: 35, cacheReadInputTokens: 0, cacheCreationInputTokens: 0)
            ),
            .makingMarkDone(
                verdict: .success,
                summary: "Added milk and saved.",
                frictionCount: 0,
                wouldRealUserSucceed: true
            )
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()

        let coordinator = RunCoordinator(
            builder: builder,
            driver: driver,
            agent: agent,
            llm: llm,
            history: history
        )

        let request = Self.makeRequest(mode: .autonomous)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        // Drive the run and collect events.
        var events: [RunEvent] = []
        for try await event in coordinator.run(request) {
            events.append(event)
        }

        // Assertions on event ordering.
        guard case .runStarted = events.first else {
            Issue.record("first event was not runStarted")
            return
        }
        guard case .runCompleted(let outcome) = events.last else {
            Issue.record("last event was not runCompleted")
            return
        }
        #expect(outcome.verdict == .success)
        #expect(outcome.stepCount == 3)
        #expect(outcome.tokensUsedInput == 320)  // 100 + 120 + 100
        #expect(outcome.wouldRealUserSucceed == true)
        #expect(outcome.frictionCount == 0)

        // Driver was actually exercised.
        let tapCount = await driver.taps.count
        let typedTexts = await driver.typed
        #expect(tapCount == 1)
        #expect(typedTexts == ["milk"])

        // SwiftData record reflects the outcome.
        let record = try await history.fetch(id: request.id)
        #expect(record?.verdict == .success)
        #expect(record?.stepCount == 3)
        #expect(record?.frictionCount == 0)

        // JSONL parses cleanly and satisfies replay invariants.
        let rows = try RunLogParser.parse(runID: request.id)
        try RunLogParser.validateInvariants(rows)
        // 1 run_started + 3 step_started + 3 tool_call + 3 tool_result
        // + 3 step_completed + 1 run_completed = 14
        #expect(rows.count == 14)
    }

    @Test("Cycle detector trips → run blocked + agent_blocked friction")
    func cycleDetectorTrips() async throws {
        // Same screenshot 4 times → cycle detector should trip after 3.
        let png = FakeSimulatorDriver.solidColorPNG(red: 128, green: 128, blue: 128)
        let driver = FakeSimulatorDriver(pngs: [png, png, png, png])
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingTap(x: 100, y: 100),
            .makingTap(x: 100, y: 100),
            .makingTap(x: 100, y: 100),
            .makingTap(x: 100, y: 100)
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        let request = Self.makeRequest(mode: .autonomous)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        var events: [RunEvent] = []
        for try await event in coordinator.run(request) {
            events.append(event)
        }

        guard case .runCompleted(let outcome) = events.last else {
            Issue.record("expected runCompleted at end")
            return
        }
        #expect(outcome.verdict == .blocked)
        #expect(outcome.frictionCount == 1)

        // The friction event should be agent_blocked.
        let frictions = events.compactMap { e -> FrictionEvent? in
            if case .frictionEmitted(let f) = e { return f }
            return nil
        }
        #expect(frictions.first?.kind == .agentBlocked)
    }

    @Test("Coordinator cleans up orphan idb_companion BEFORE boot")
    func cleanupBeforeBoot() async throws {
        // Single screenshot is fine — we're not exercising the agent loop here.
        let png = FakeSimulatorDriver.solidColorPNG(red: 50, green: 50, blue: 50)
        let driver = FakeSimulatorDriver(pngs: [png])
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingMarkDone(verdict: .success, summary: "no-op", frictionCount: 0)
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        let request = Self.makeRequest(mode: .autonomous)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        for try await _ in coordinator.run(request) { }

        let cleanupCalls = await driver.cleanupCompanionCalls
        let lifecycle = await driver.lifecycleEvents
        #expect(cleanupCalls == [request.simulator.udid],
                "Coordinator must call cleanupCompanion exactly once with the run's UDID. Got: \(cleanupCalls)")
        #expect(lifecycle.first == "cleanup",
                "Cleanup must come before any other lifecycle call. Order was: \(lifecycle)")
        #expect(lifecycle.contains("boot"),
                "Boot must still be called.")
        if let cleanupIdx = lifecycle.firstIndex(of: "cleanup"),
           let bootIdx = lifecycle.firstIndex(of: "boot") {
            #expect(cleanupIdx < bootIdx,
                    "cleanup must precede boot in the lifecycle order. Got: \(lifecycle)")
        }
    }

    @Test("Step budget short-circuits with blocked verdict")
    func stepBudgetShortCircuit() async throws {
        // 3 distinct screenshots so cycle detector doesn't fire — but budget = 2.
        let pngs = [
            FakeSimulatorDriver.solidColorPNG(red: 10, green: 0, blue: 0),
            FakeSimulatorDriver.solidColorPNG(red: 0, green: 10, blue: 0),
            FakeSimulatorDriver.solidColorPNG(red: 0, green: 0, blue: 10)
        ]
        let driver = FakeSimulatorDriver(pngs: pngs)
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingTap(x: 100, y: 100),
            .makingTap(x: 200, y: 200)
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        var request = Self.makeRequest(mode: .autonomous)
        request = GoalRequest(
            id: request.id,
            goal: request.goal,
            persona: request.persona,
            project: request.project,
            simulator: request.simulator,
            model: request.model,
            mode: request.mode,
            stepBudget: 2,
            tokenBudget: request.tokenBudget
        )
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        var outcome: RunOutcome?
        for try await event in coordinator.run(request) {
            if case .runCompleted(let o) = event { outcome = o }
        }
        #expect(outcome?.verdict == .blocked)
        #expect(outcome?.summary.contains("step budget") == true)
    }

    // MARK: Helper

    private static func makeRequest(mode: RunMode) -> GoalRequest {
        GoalRequest(
            id: UUID(),
            goal: "Add 'milk' to my list and mark it done.",
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
            mode: mode,
            stepBudget: 40,
            tokenBudget: 250_000
        )
    }
}
