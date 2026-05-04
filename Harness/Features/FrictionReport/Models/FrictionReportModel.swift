//
//  FrictionReportModel.swift
//  Harness
//
//  Per-card data shown in `FrictionReportView`. Built by joining each
//  `friction` row with its same-step `tool_call` (for the agent quote)
//  and `step_started` row (for the elapsed timestamp).
//

import Foundation

struct FrictionReportEntry: Sendable, Hashable, Identifiable {
    let id: Int
    let step: Int
    let kind: FrictionKind
    let detail: String
    /// Agent's `observation` field on the `tool_call` row that emitted this
    /// friction. Empty when the row was decoded from a partial run that
    /// didn't capture a tool call alongside the friction.
    let agentObservation: String
    /// Elapsed-since-start label like `"00:14"`.
    let timestampLabel: String
    /// Path to the per-step PNG. May not exist on disk for partial runs;
    /// the card falls back to a placeholder.
    let screenshotURL: URL
}

/// Filter buckets shown in the toolbar. Maps onto the production
/// `FrictionKind` taxonomy via `matches(_:)`.
enum FrictionKindFilter: String, Hashable, CaseIterable, Identifiable {
    case all
    case ambiguous
    case missing
    case deadEnds

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:       return "All"
        case .ambiguous: return "Ambiguous"
        case .missing:   return "Missing"
        case .deadEnds:  return "Dead-ends"
        }
    }

    func matches(_ kind: FrictionKind) -> Bool {
        switch self {
        case .all:
            return true
        case .ambiguous:
            // The design's "Ambiguous" bucket folds in label/copy ambiguity.
            return kind == .ambiguousLabel || kind == .confusingCopy
        case .missing:
            // "Missing" pairs with affordances/state surprises — the agent
            // expected a control or transition that wasn't there.
            return kind == .unresponsive || kind == .unexpectedState
        case .deadEnds:
            return kind == .deadEnd || kind == .agentBlocked
        }
    }
}
