//
//  MockLLMClient.swift
//  HarnessTests
//
//  Test double for `LLMClient`. Returns scripted responses in order.
//  Used by replay-based agent tests per `standards/10-testing.md §8`.
//
//  Two modes today:
//    - Scripted: hand-crafted sequence of (toolCall, usage) pairs.
//    - Lookup: a closure that maps the in-flight request to a response
//      (lets a fixture drive different replies based on, e.g., the screenshot
//      hash).
//

import Foundation
@testable import Harness

actor MockLLMClient: LLMClient {

    enum Scripted: Sendable {
        case sequence([LLMStepResponse])
        case lookup(@Sendable (LLMStepRequest) -> LLMStepResponse?)
    }

    private let mode: Scripted
    private var index: Int = 0
    private(set) var seenRequests: [LLMStepRequest] = []
    private(set) var tokensUsedThisRun: TokenUsage = .zero

    init(mode: Scripted) {
        self.mode = mode
    }

    func step(_ request: LLMStepRequest) async throws -> LLMStepResponse {
        seenRequests.append(request)

        let response: LLMStepResponse
        switch mode {
        case .sequence(let arr):
            guard index < arr.count else {
                throw ClaudeError.serverError(status: 599)
            }
            response = arr[index]
            index += 1
        case .lookup(let fn):
            guard let r = fn(request) else {
                throw ClaudeError.serverError(status: 599)
            }
            response = r
        }

        tokensUsedThisRun = TokenUsage(
            inputTokens: tokensUsedThisRun.inputTokens + response.usage.inputTokens,
            outputTokens: tokensUsedThisRun.outputTokens + response.usage.outputTokens,
            cacheReadInputTokens: tokensUsedThisRun.cacheReadInputTokens + response.usage.cacheReadInputTokens,
            cacheCreationInputTokens: tokensUsedThisRun.cacheCreationInputTokens + response.usage.cacheCreationInputTokens
        )
        return response
    }

    func reset() {
        index = 0
        seenRequests = []
        tokensUsedThisRun = .zero
    }
}

// MARK: - Tiny prompt library that returns a fixed string

struct StubPromptLibrary: PromptLoading {
    let system: String
    let persona: String
    let friction: String
    let personaDefaultsRaw: String

    init(
        system: String = "You are a tester. {{POINT_WIDTH}}×{{POINT_HEIGHT}} {{PERSONA}} {{GOAL}}.",
        persona: String = "first-time user",
        friction: String = "(vocab)",
        personaDefaultsRaw: String = ""
    ) {
        self.system = system
        self.persona = persona
        self.friction = friction
        self.personaDefaultsRaw = personaDefaultsRaw
    }

    func systemPrompt() throws -> String { system }
    func defaultPersona() throws -> String { persona }
    func frictionVocab() throws -> String { friction }
    func personaDefaults() throws -> String { personaDefaultsRaw }
}

// MARK: - LLMStepResponse builder

extension LLMStepResponse {
    static func makingTap(x: Int, y: Int, observation: String = "obs", intent: String = "intent", inputTokens: Int = 100, outputTokens: Int = 30) -> LLMStepResponse {
        LLMStepResponse(
            toolCall: ToolCall(
                tool: .tap,
                input: .tap(x: x, y: y),
                observation: observation,
                intent: intent
            ),
            usage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0
            )
        )
    }

    static func makingMarkDone(verdict: Verdict, summary: String, frictionCount: Int = 0, wouldRealUserSucceed: Bool = true, inputTokens: Int = 100, outputTokens: Int = 50) -> LLMStepResponse {
        LLMStepResponse(
            toolCall: ToolCall(
                tool: .markGoalDone,
                input: .markGoalDone(verdict: verdict, summary: summary, frictionCount: frictionCount, wouldRealUserSucceed: wouldRealUserSucceed),
                observation: "done",
                intent: "wrapping up"
            ),
            usage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0
            )
        )
    }
}
