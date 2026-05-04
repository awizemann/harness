//
//  PricingTests.swift
//  HarnessTests
//
//  Pure pricing math: per-bucket multiplication + total. The published
//  rates live in `AgentModel.pricing`; if Anthropic changes them, those
//  expectations move and these tests fail loudly so the UI labels can't
//  silently drift.
//

import Testing
import Foundation
@testable import Harness

@Suite("Pricing — model rates × token buckets")
struct PricingTests {

    @Test("Opus 4.7: 1M input + 1M output tokens lands at the published rate")
    func opusBaselineMillion() {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0
        )
        let cost = Pricing.cost(model: .opus47, usage: usage)
        // $15 input + $75 output for 1M each
        #expect(abs(cost.inputUSD - 15.00) < 1e-6)
        #expect(abs(cost.outputUSD - 75.00) < 1e-6)
        #expect(abs(cost.total - 90.00) < 1e-6)
    }

    @Test("Sonnet 4.6: 1M input + 1M output tokens lands at the published rate")
    func sonnetBaselineMillion() {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0
        )
        let cost = Pricing.cost(model: .sonnet46, usage: usage)
        #expect(abs(cost.inputUSD - 3.00) < 1e-6)
        #expect(abs(cost.outputUSD - 15.00) < 1e-6)
        #expect(abs(cost.total - 18.00) < 1e-6)
    }

    @Test("Cache reads price at 10% of the input rate (90% off)")
    func cacheReadDiscountOpus() {
        let usage = TokenUsage(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadInputTokens: 1_000_000,
            cacheCreationInputTokens: 0
        )
        let cost = Pricing.cost(model: .opus47, usage: usage)
        // Opus input is $15/Mtok; cache reads are $1.50/Mtok.
        #expect(abs(cost.cacheReadUSD - 1.50) < 1e-6)
        #expect(abs(cost.total - 1.50) < 1e-6)
    }

    @Test("Cache creation prices at 1.25× input rate")
    func cacheCreationPremiumOpus() {
        let usage = TokenUsage(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 1_000_000
        )
        let cost = Pricing.cost(model: .opus47, usage: usage)
        // Opus input is $15/Mtok; cache creation is $18.75/Mtok.
        #expect(abs(cost.cacheCreationUSD - 18.75) < 1e-6)
    }

    @Test("All four buckets sum into the total")
    func mixedBuckets() {
        let usage = TokenUsage(
            inputTokens: 100_000,           // $0.30 sonnet
            outputTokens: 50_000,           // $0.75 sonnet
            cacheReadInputTokens: 200_000,  // $0.06 sonnet
            cacheCreationInputTokens: 10_000 // $0.0375 sonnet
        )
        let cost = Pricing.cost(model: .sonnet46, usage: usage)
        let expected = 0.30 + 0.75 + 0.06 + 0.0375
        #expect(abs(cost.total - expected) < 1e-6)
    }

    @Test("Unknown model raw value yields zero cost (no crash)")
    func unknownModelRawZero() {
        let cost = Pricing.cost(
            modelRaw: "claude-haiku-4-99",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )
        #expect(cost.total == 0)
    }

    @Test("Zero usage round-trips to zero")
    func zeroUsage() {
        let cost = Pricing.cost(model: .opus47, usage: .zero)
        #expect(cost.total == 0)
    }

    @Test("Sub-cent format renders extra precision; dollar amounts get cents only")
    func formatPrecision() {
        #expect(RunCost.format(0.0042).contains("0.0042"))
        #expect(RunCost.format(0.42) == "$0.42")
        #expect(RunCost.format(1.234) == "$1.23")
    }
}
