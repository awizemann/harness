//
//  AgentLoopTests.swift
//  HarnessTests
//
//  Unit-level tests for AgentLoop's pieces (history compactor, cycle detector,
//  tool-call equivalence). The end-to-end behavior is covered by
//  RunCoordinatorReplayTests.
//

import Testing
import Foundation
@testable import Harness

@Suite("AgentLoop — history compactor")
struct HistoryCompactorTests {

    @Test("Short history is returned unchanged")
    func shortHistoryUnchanged() {
        let turns = (0..<3).map(Self.turn)
        let compacted = HistoryCompactor.compact(turns, keepFullTurns: 6)
        #expect(compacted.count == 3)
        #expect(compacted.last?.observation == turns.last?.observation)
        #expect(compacted.last?.screenshotJPEG != nil)
    }

    @Test("Older turns lose screenshots when over the keep window")
    func screenshotsDropped() {
        let turns = (0..<10).map(Self.turn)  // 10 turns; keep last 6
        let compacted = HistoryCompactor.compact(turns, keepFullTurns: 6)
        #expect(compacted.count == 10)
        // First 4 had screenshots dropped.
        for i in 0..<4 {
            #expect(compacted[i].screenshotJPEG == nil, "turn \(i) should have had screenshot dropped")
        }
        // Last 6 kept screenshots.
        for i in 4..<10 {
            #expect(compacted[i].screenshotJPEG != nil, "turn \(i) should have kept screenshot")
        }
    }

    @Test("Empty history stays empty")
    func emptyStaysEmpty() {
        #expect(HistoryCompactor.compact([], keepFullTurns: 6).isEmpty)
    }

    private static func turn(_ i: Int) -> LLMTurn {
        LLMTurn(
            observation: "obs-\(i)",
            intent: "intent-\(i)",
            toolName: "tap",
            toolInputJSON: Data("{\"x\":\(i),\"y\":\(i)}".utf8),
            screenshotJPEG: Data("img-\(i)".utf8),
            toolResultSummary: "ok"
        )
    }
}

@Suite("AgentLoop — tool-call equivalence")
struct ToolCallEquivalenceTests {

    @Test("Two taps within 8pt are equivalent")
    func tapsCloseAreEquivalent() {
        let a = ToolCall(tool: .tap, input: .tap(x: 100, y: 200), observation: "", intent: "")
        let b = ToolCall(tool: .tap, input: .tap(x: 105, y: 198), observation: "", intent: "")
        #expect(AgentLoop.toolCallsEquivalent(a, b))
    }

    @Test("Two taps further than 8pt apart are not equivalent")
    func tapsFarAreNotEquivalent() {
        let a = ToolCall(tool: .tap, input: .tap(x: 100, y: 200), observation: "", intent: "")
        let b = ToolCall(tool: .tap, input: .tap(x: 130, y: 200), observation: "", intent: "")
        #expect(!AgentLoop.toolCallsEquivalent(a, b))
    }

    @Test("Different tool kinds are never equivalent")
    func differentKinds() {
        let a = ToolCall(tool: .tap, input: .tap(x: 100, y: 200), observation: "", intent: "")
        let b = ToolCall(tool: .doubleTap, input: .doubleTap(x: 100, y: 200), observation: "", intent: "")
        #expect(!AgentLoop.toolCallsEquivalent(a, b))
    }

    @Test("Identical type calls are equivalent")
    func identicalType() {
        let a = ToolCall(tool: .type, input: .type(text: "milk"), observation: "", intent: "")
        let b = ToolCall(tool: .type, input: .type(text: "milk"), observation: "", intent: "")
        #expect(AgentLoop.toolCallsEquivalent(a, b))
    }

    @Test("Different typed text not equivalent")
    func differentType() {
        let a = ToolCall(tool: .type, input: .type(text: "milk"), observation: "", intent: "")
        let b = ToolCall(tool: .type, input: .type(text: "eggs"), observation: "", intent: "")
        #expect(!AgentLoop.toolCallsEquivalent(a, b))
    }
}

@Suite("AgentLoop — parse-retry hint propagation")
struct AgentLoopRetryHintTests {

    @Test("Retry passes the prior parse-failure detail back to the model")
    func retryHintCarriesPriorDetail() async throws {
        // Mock LLM: first call throws invalidToolCall; second call
        // returns a markGoalDone so the step succeeds.
        var calls: Int = 0
        let detail = "model emitted 2 tool calls (tap, wait); expected exactly one"
        let llm = MockLLMClient(mode: .lookup({ _ in
            // Lookup mode returns nil on first call to force the throw
            // path inside MockLLMClient. We need a different mock for this.
            // See below — we instead use a custom client.
            return nil
        }))
        _ = (calls, llm, detail)
        // Use a hand-rolled mock to control the throw/success sequence.
        let twoStepLLM = TwoCallLLM(firstError: detail)
        let loop = AgentLoop(llm: twoStepLLM, promptLibrary: StubPromptLibrary())

        let projectURL = URL(fileURLWithPath: "/tmp/x.xcodeproj")
        let request = RunRequest(
            goal: "test",
            persona: "tester",
            project: ProjectRequest(path: projectURL, scheme: "x", displayName: "x"),
            simulator: SimulatorRef(udid: "u", name: "n", runtime: "r",
                                    pointSize: CGSize(width: 100, height: 200), scaleFactor: 1)
        )
        let state = AgentLoopState(
            request: request,
            stepIndex: 1,
            history: [],
            currentScreenshotJPEG: Data([0xFF, 0xD8]),
            tokensUsedSoFar: .zero
        )
        let decision = try await loop.step(state: state)
        // Decision should be the markGoalDone the second call returned.
        #expect(decision.toolCall.tool == .markGoalDone)
        // The second request must have carried the retry hint.
        let observed = await twoStepLLM.observedRetryHints()
        #expect(observed.count == 2)
        #expect(observed[0] == nil, "first attempt should have no hint")
        #expect(observed[1] == detail, "second attempt's hint should equal the prior detail")
    }
}

/// Test-only LLM that throws once with a chosen detail, then returns a
/// `markGoalDone` response. Captures the `retryHint` field of every
/// inbound request so the test can assert propagation.
private actor TwoCallLLM: LLMClient {
    private(set) var tokensUsedThisRun: TokenUsage = .zero
    private var hints: [String?] = []
    private var calls: Int = 0
    private let firstError: String

    init(firstError: String) {
        self.firstError = firstError
    }

    func step(_ request: LLMStepRequest) async throws -> LLMStepResponse {
        hints.append(request.retryHint)
        calls += 1
        if calls == 1 {
            throw LLMError.invalidToolCall(detail: firstError)
        }
        return .makingMarkDone(verdict: .success, summary: "ok")
    }

    func reset() {
        tokensUsedThisRun = .zero
        hints = []
        calls = 0
    }

    func observedRetryHints() -> [String?] { hints }
}

@Suite("AgentLoop — screenshot dHash")
struct ScreenshotHasherTests {

    @Test("Identical bytes hash to the same value")
    func identicalHashesEqual() {
        let png = FakeSimulatorDriver.solidColorPNG(red: 50, green: 50, blue: 50, size: 64)
        let h1 = ScreenshotHasher.dHash(jpeg: png)
        let h2 = ScreenshotHasher.dHash(jpeg: png)
        #expect(h1 == h2)
        #expect(ScreenshotHasher.hammingDistance(h1, h2) == 0)
    }

    @Test("Hamming distance counts differing bits")
    func hammingDistanceCounts() {
        // 0x...01 vs 0x...02 differ in 2 bits.
        #expect(ScreenshotHasher.hammingDistance(0x01, 0x02) == 2)
        #expect(ScreenshotHasher.hammingDistance(0xFFFF_FFFF_FFFF_FFFF, 0) == 64)
        #expect(ScreenshotHasher.hammingDistance(0x1234, 0x1234) == 0)
    }
}
