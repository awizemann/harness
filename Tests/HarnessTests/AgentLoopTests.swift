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
