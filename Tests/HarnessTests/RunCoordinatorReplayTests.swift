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
import AppKit
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
        // 1 run_started + 1 leg_started (Phase E synthesizes one for ad-hoc /
        // single-action runs so chains and singles share a JSONL shape)
        // + 3 step_started + 3 tool_call + 3 tool_result + 3 step_completed
        // + 1 leg_completed + 1 run_completed = 16
        #expect(rows.count == 16)

        // Verify the synthesized leg sandwiches the step rows.
        if case .legStarted(_, let p) = rows[1] {
            #expect(p.leg == 0, "synthesized leg index is 0-based")
        } else {
            Issue.record("expected leg_started as second row")
        }
        if case .legCompleted(_, let p) = rows[rows.count - 2] {
            #expect(p.verdict == "success")
        } else {
            Issue.record("expected leg_completed before run_completed")
        }
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

    @Test("Lifecycle: cleanupWDA → boot → install → launch → startInputSession → … → endInputSession")
    func wdaSessionLifecycle() async throws {
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

        let cleanupCalls = await driver.cleanupWDACalls
        let lifecycle = await driver.lifecycleEvents
        #expect(cleanupCalls == [request.simulator.udid],
                "Coordinator must call cleanupWDA exactly once with the run's UDID. Got: \(cleanupCalls)")
        let expected = ["cleanup", "boot", "install", "launch", "startInputSession", "endInputSession"]
        #expect(lifecycle == expected,
                "Lifecycle order must be \(expected). Got: \(lifecycle)")

        let starts = await driver.startInputSessionCalls
        let ends = await driver.endInputSessionCalls
        #expect(starts == 1)
        #expect(ends == 1)
    }

    @Test("endInputSession runs even when the loop throws")
    func endInputSessionRunsOnThrow() async throws {
        // Force the screenshot path to throw by giving the fake zero PNGs;
        // the coordinator's `try await driver.screenshot(...)` will fail.
        let driver = ThrowingScreenshotDriver()
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingMarkDone(verdict: .success, summary: "x", frictionCount: 0)
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        let request = Self.makeRequest(mode: .autonomous)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        var threw = false
        do {
            for try await _ in coordinator.run(request) { }
        } catch {
            threw = true
        }
        #expect(threw == true, "screenshot failure should propagate")
        let ended = await driver.endInputSessionCalls
        #expect(ended == 1, "endInputSession must run on the failure path")
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

    @Test("Unlimited step budget (0) skips the short-circuit")
    func unlimitedStepBudgetSkipsShortCircuit() async throws {
        // Distinct screenshots so the cycle detector won't fire. Run
        // well past the historical 40-step default to confirm the
        // unlimited-budget path doesn't gate on step count.
        var pngs: [Data] = []
        for i in 0..<60 {
            let r = UInt8(i % 255)
            let g = UInt8((i + 17) % 255)
            let b = UInt8((i + 113) % 255)
            pngs.append(FakeSimulatorDriver.solidColorPNG(red: r, green: g, blue: b))
        }
        let driver = FakeSimulatorDriver(pngs: pngs)
        let builder = FakeXcodeBuilder()
        // 49 taps + a markGoalDone — comfortably above the legacy 40 cap.
        // Space taps by 20pt per step so the cycle detector's 8pt
        // coordinate threshold doesn't classify successive taps as
        // equivalent (solid-color PNGs all dHash to 0, so the only
        // remaining defense against false-positive cycles is keeping
        // tool inputs visibly different).
        var scripted: [LLMStepResponse] = []
        for i in 0..<49 {
            scripted.append(LLMStepResponse.makingTap(x: 10 + i * 20, y: 10 + i * 20))
        }
        scripted.append(LLMStepResponse.makingMarkDone(verdict: .success, summary: "done"))
        let llm = MockLLMClient(mode: .sequence(scripted))
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
            stepBudget: RunRequest.unlimitedStepBudget,
            tokenBudget: request.tokenBudget
        )
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        var outcome: RunOutcome?
        for try await event in coordinator.run(request) {
            if case .runCompleted(let o) = event { outcome = o }
        }
        #expect(outcome?.verdict == .success)
        #expect(outcome?.stepCount == 50)
        #expect(outcome?.summary == "done")
    }

    // MARK: Test-only fake — succeeds at lifecycle methods but fails screenshots.

    private actor ThrowingScreenshotDriver: SimulatorDriving {
        private(set) var endInputSessionCalls = 0
        struct Boom: Error {}
        func listDevices() async throws -> [SimulatorRef] { [] }
        func boot(_ ref: SimulatorRef) async throws {}
        func install(_ appBundle: URL, on ref: SimulatorRef) async throws {}
        func launch(bundleID: String, on ref: SimulatorRef) async throws {}
        func terminate(bundleID: String, on ref: SimulatorRef) async throws {}
        func erase(_ ref: SimulatorRef) async throws {}
        func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL { throw Boom() }
        func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage { throw Boom() }
        func tap(at point: CGPoint, on ref: SimulatorRef) async throws {}
        func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws {}
        func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws {}
        func type(_ text: String, on ref: SimulatorRef) async throws {}
        func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws {}
        func startInputSession(_ ref: SimulatorRef) async throws {}
        func endInputSession() async { endInputSessionCalls += 1 }
        func cleanupWDA(udid: String) async {}
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
