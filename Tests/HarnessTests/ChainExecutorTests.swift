//
//  ChainExecutorTests.swift
//  HarnessTests
//
//  End-to-end chain-run tests targeting `RunCoordinator` against the
//  same fakes used by `RunCoordinatorReplayTests` (FakeXcodeBuilder +
//  FakeSimulatorDriver + MockLLMClient + StubPromptLibrary). Validates
//  the chain-executor invariants from the Phase E spec:
//
//    - Two legs both succeed → aggregate verdict success, JSONL has
//      two `leg_started`/`leg_completed` pairs.
//    - Leg 1 fails → aggregate verdict failure; remaining legs are
//      written as `skipped`.
//    - `preservesState=false` between legs invokes
//      `FakeSimulatorDriver.install` an extra time.
//    - `preservesState=true` does not.
//
//  Per `standards/13-agent-loop.md` (leg semantics) and
//  `standards/14-run-logging-format.md` (v2 row schema).
//

import Testing
import Foundation
import AppKit
@testable import Harness

@Suite("ChainExecutor — chain runs")
struct ChainExecutorTests {

    // MARK: Helpers

    /// Build a 2-leg chain payload. Leg 0 is "tap then mark done".
    /// Leg 1 is the same. Adjust `preservesState` to test reinstalls.
    private static func twoLegRequest(
        legOnePreservesState preservesA: Bool = false,
        legTwoPreservesState preservesB: Bool = false
    ) -> RunRequest {
        let chainID = UUID()
        let legs = [
            ChainLeg(
                id: UUID(),
                index: 0,
                actionID: UUID(),
                actionName: "Add 'milk'",
                goal: "Add 'milk' to the list.",
                preservesState: preservesA
            ),
            ChainLeg(
                id: UUID(),
                index: 1,
                actionID: UUID(),
                actionName: "Mark 'milk' done",
                goal: "Mark 'milk' done.",
                preservesState: preservesB
            )
        ]
        return RunRequest(
            id: UUID(),
            name: "two-leg-chain",
            goal: legs[0].goal,
            persona: "first-time user",
            applicationID: nil,
            personaID: nil,
            payload: .chain(chainID: chainID, legs: legs),
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
            mode: .autonomous,
            stepBudget: 40,
            tokenBudget: 250_000
        )
    }

    /// Two PNGs per leg (one for the tap, one for the mark_done). Four
    /// distinct screenshots so the cycle detector never trips.
    private static func makeFourPNGs() -> [Data] {
        [
            FakeSimulatorDriver.solidColorPNG(red: 255, green: 0, blue: 0),
            FakeSimulatorDriver.solidColorPNG(red: 0, green: 255, blue: 0),
            FakeSimulatorDriver.solidColorPNG(red: 0, green: 0, blue: 255),
            FakeSimulatorDriver.solidColorPNG(red: 255, green: 255, blue: 0)
        ]
    }

    // MARK: Tests

    @Test("Two legs both succeed → run verdict success, 2 leg pairs in JSONL")
    func twoLegHappyPath() async throws {
        let driver = FakeSimulatorDriver(pngs: Self.makeFourPNGs())
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingTap(x: 200, y: 400),
            .makingMarkDone(verdict: .success, summary: "Leg 1 done"),
            .makingTap(x: 250, y: 450),
            .makingMarkDone(verdict: .success, summary: "Leg 2 done")
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        let request = Self.twoLegRequest()
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        var outcome: RunOutcome?
        var legCompletedEvents: [(Int, Verdict?)] = []
        for try await event in coordinator.run(request) {
            if case .runCompleted(let o) = event { outcome = o }
            if case .legCompleted(let i, let v, _) = event { legCompletedEvents.append((i, v)) }
        }

        #expect(outcome?.verdict == .success)
        #expect(legCompletedEvents.map(\.0) == [0, 1])
        #expect(legCompletedEvents.allSatisfy { $0.1 == .success })

        let rows = try RunLogParser.parse(runID: request.id)
        try RunLogParser.validateInvariants(rows)

        let legStartedCount = rows.filter { if case .legStarted = $0 { return true }; return false }.count
        let legCompletedCount = rows.filter { if case .legCompleted = $0 { return true }; return false }.count
        #expect(legStartedCount == 2, "two legs → two leg_started rows")
        #expect(legCompletedCount == 2, "two legs → two leg_completed rows")

        // Aggregate verdict aggregator returns success for [success, success].
        let agg = ChainExecutor.aggregateVerdict([.success, .success])
        #expect(agg == .success)
    }

    @Test("Leg 1 fails → run verdict failure, leg 2 marked skipped")
    func twoLegFirstFailsAbortsSecond() async throws {
        let driver = FakeSimulatorDriver(pngs: Self.makeFourPNGs())
        let builder = FakeXcodeBuilder()
        // Leg 1 returns failure verdict → second leg should be skipped.
        let llm = MockLLMClient(mode: .sequence([
            .makingMarkDone(verdict: .failure, summary: "Couldn't add the item")
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        let request = Self.twoLegRequest()
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }

        var outcome: RunOutcome?
        var legCompletedSummaries: [(Int, String)] = []
        for try await event in coordinator.run(request) {
            if case .runCompleted(let o) = event { outcome = o }
            if case .legCompleted(let i, _, let s) = event {
                legCompletedSummaries.append((i, s))
            }
        }

        #expect(outcome?.verdict == .failure)
        #expect(legCompletedSummaries.count == 2, "both legs report a leg_completed (one real, one skipped)")
        #expect(legCompletedSummaries[0].1 == "Couldn't add the item")
        #expect(legCompletedSummaries[1].1 == "skipped")

        let rows = try RunLogParser.parse(runID: request.id)
        let legCompletedRows = rows.compactMap { row -> LegCompletedPayload? in
            if case .legCompleted(_, let p) = row { return p }
            return nil
        }
        #expect(legCompletedRows.count == 2)
        #expect(legCompletedRows[0].verdict == "failure")
        #expect(legCompletedRows[1].verdict == "skipped")
    }

    @Test("preservesState=false reinstalls between legs")
    func reinstallsBetweenLegs() async throws {
        let driver = FakeSimulatorDriver(pngs: Self.makeFourPNGs())
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingMarkDone(verdict: .success, summary: "leg 1"),
            .makingMarkDone(verdict: .success, summary: "leg 2")
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        let request = Self.twoLegRequest(legOnePreservesState: false, legTwoPreservesState: false)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }
        for try await _ in coordinator.run(request) { }

        // installCalls counts: 1 (initial) + 1 (between legs) = 2.
        let installCalls = await driver.installCalls
        #expect(installCalls == 2, "expected one initial install plus one reinstall between legs; got \(installCalls)")
    }

    @Test("preservesState=true keeps the simulator state between legs")
    func preservesStateBetweenLegs() async throws {
        let driver = FakeSimulatorDriver(pngs: Self.makeFourPNGs())
        let builder = FakeXcodeBuilder()
        let llm = MockLLMClient(mode: .sequence([
            .makingMarkDone(verdict: .success, summary: "leg 1"),
            .makingMarkDone(verdict: .success, summary: "leg 2")
        ]))
        let agent = AgentLoop(llm: llm, promptLibrary: StubPromptLibrary())
        let history = try RunHistoryStore.inMemory()
        let coordinator = RunCoordinator(
            builder: builder, driver: driver, agent: agent, llm: llm, history: history
        )

        // Leg 2 preservesState=true → no reinstall before it.
        let request = Self.twoLegRequest(legOnePreservesState: false, legTwoPreservesState: true)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: request.id)) }
        for try await _ in coordinator.run(request) { }

        let installCalls = await driver.installCalls
        #expect(installCalls == 1, "preservesState=true on leg 2 → only the initial install; got \(installCalls)")
    }

    // MARK: Pure ChainExecutor helpers

    @Test("ChainExecutor.aggregateVerdict — failure dominates")
    func aggregateVerdictFailure() {
        #expect(ChainExecutor.aggregateVerdict([.success, .failure, .success]) == .failure)
    }

    @Test("ChainExecutor.aggregateVerdict — blocked when no failure but a blocked or nil")
    func aggregateVerdictBlocked() {
        #expect(ChainExecutor.aggregateVerdict([.success, .blocked]) == .blocked)
        #expect(ChainExecutor.aggregateVerdict([.success, nil]) == .blocked)
    }

    @Test("ChainExecutor.aggregateVerdict — success only when all success")
    func aggregateVerdictSuccess() {
        #expect(ChainExecutor.aggregateVerdict([.success, .success, .success]) == .success)
    }

    @Test("ChainExecutor.shouldShortCircuit — only success continues")
    func shortCircuitRules() {
        #expect(ChainExecutor.shouldShortCircuit(after: .success) == false)
        #expect(ChainExecutor.shouldShortCircuit(after: .failure) == true)
        #expect(ChainExecutor.shouldShortCircuit(after: .blocked) == true)
        #expect(ChainExecutor.shouldShortCircuit(after: nil) == true)
    }

    @Test("ChainExecutor.expandedLegs — single-action gets one synthesized leg")
    func expandedLegsForSingleAction() {
        let request = RunRequest(
            id: UUID(),
            name: "",
            goal: "do the thing",
            persona: "first-time user",
            payload: .singleAction(actionID: UUID(), goal: "do the thing"),
            project: ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/X.xcodeproj"),
                scheme: "X",
                displayName: "X"
            ),
            simulator: SimulatorRef(
                udid: "FAKE", name: "iPhone 16 Pro", runtime: "iOS 18.4",
                pointSize: CGSize(width: 430, height: 932), scaleFactor: 3.0
            )
        )
        let legs = ChainExecutor.expandedLegs(for: request)
        #expect(legs.count == 1)
        #expect(legs[0].index == 0)
        #expect(legs[0].goal == "do the thing")
    }
}
