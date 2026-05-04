//
//  Pricing.swift
//  Harness
//
//  Maps `(AgentModel, TokenUsage) -> Cost` using Anthropic's published
//  per-million-token rates. Pure value module — no I/O, no actor, no
//  network. Drives the per-run cost cell in RunHistoryDetailView and
//  the cost chip on the replay header.
//
//  Rates are USD per *million* tokens, captured here so the source of
//  truth for every cost label across the app is one switch statement.
//  When Anthropic changes pricing, edit this file and every surface
//  recomputes. We don't persist dollar amounts — only the four token
//  buckets — so historical runs can be re-priced if rates move (the
//  `cost(of:)` is a pure function of (model, usage)).
//

import Foundation

/// Per-model rate card, all USD per 1M tokens.
struct PricingRate: Sendable, Hashable {
    let inputPerMTok: Double
    let outputPerMTok: Double
    /// Cache read tokens are typically 0.1× the input rate (90% off).
    let cacheReadPerMTok: Double
    /// Cache creation (writes into the 5-min ephemeral cache) is 1.25× the
    /// input rate.
    let cacheCreationPerMTok: Double
}

extension AgentModel {
    /// Public Anthropic rates as of 2026-01. Update here when Anthropic
    /// announces a change; every surface that prices a run reads through
    /// this property.
    var pricing: PricingRate {
        switch self {
        case .opus47:
            // Opus 4.x — premium tier.
            return PricingRate(
                inputPerMTok: 15.00,
                outputPerMTok: 75.00,
                cacheReadPerMTok: 1.50,         // 0.1× input
                cacheCreationPerMTok: 18.75     // 1.25× input
            )
        case .sonnet46:
            // Sonnet 4.x — workhorse tier.
            return PricingRate(
                inputPerMTok: 3.00,
                outputPerMTok: 15.00,
                cacheReadPerMTok: 0.30,
                cacheCreationPerMTok: 3.75
            )
        }
    }
}

/// Itemized cost for a run. All values are USD; `total` is the rounded sum
/// the UI surfaces.
struct RunCost: Sendable, Hashable {
    let inputUSD: Double
    let outputUSD: Double
    let cacheReadUSD: Double
    let cacheCreationUSD: Double

    var total: Double {
        inputUSD + outputUSD + cacheReadUSD + cacheCreationUSD
    }

    static let zero = RunCost(
        inputUSD: 0,
        outputUSD: 0,
        cacheReadUSD: 0,
        cacheCreationUSD: 0
    )
}

enum Pricing {
    /// Compute a `RunCost` from a fully resolved (model, usage) pair.
    /// `model` is `nil` when a historical row's `modelRaw` doesn't match
    /// any current `AgentModel` case — we return `.zero` so the UI just
    /// hides the cell rather than crashing.
    static func cost(model: AgentModel?, usage: TokenUsage) -> RunCost {
        guard let model else { return .zero }
        let rate = model.pricing
        return RunCost(
            inputUSD:         usd(tokens: usage.inputTokens,            perMTok: rate.inputPerMTok),
            outputUSD:        usd(tokens: usage.outputTokens,           perMTok: rate.outputPerMTok),
            cacheReadUSD:     usd(tokens: usage.cacheReadInputTokens,   perMTok: rate.cacheReadPerMTok),
            cacheCreationUSD: usd(tokens: usage.cacheCreationInputTokens, perMTok: rate.cacheCreationPerMTok)
        )
    }

    /// Convenience for surfaces that already have the four token buckets
    /// flat on a value (e.g. `RunRecordSnapshot`) and don't need to
    /// reconstruct a `TokenUsage`.
    static func cost(
        modelRaw: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) -> RunCost {
        let model = AgentModel(rawValue: modelRaw)
        let usage = TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadTokens,
            cacheCreationInputTokens: cacheCreationTokens
        )
        return cost(model: model, usage: usage)
    }

    private static func usd(tokens: Int, perMTok: Double) -> Double {
        guard tokens > 0 else { return 0 }
        return Double(tokens) / 1_000_000.0 * perMTok
    }
}

extension RunCost {
    /// Format a USD value the way the run-report UI shows it. Sub-dollar
    /// amounts render with cent precision (`$0.42`); larger amounts get
    /// thousands separators (`$1.23`, `$12.34`, `$1,234.56`).
    static func format(_ usd: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = usd < 0.01 ? 4 : 2
        return formatter.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd)
    }

    /// Convenience for the inline display string.
    var formattedTotal: String { Self.format(total) }
}
