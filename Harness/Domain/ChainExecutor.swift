//
//  ChainExecutor.swift
//  Harness
//
//  Multi-leg run aggregation. Phase E.
//
//  A chain run is one `RunRecord` with multiple **legs**. Each leg has
//  its own `goal` (the leg's `Action.promptText`) and ends when the
//  agent emits `mark_goal_done(...)` for that leg. The Run's overall
//  verdict aggregates legs:
//
//    - All legs `success` → Run verdict `success`.
//    - Any leg `failure` → Run verdict `failure`, abort remaining legs.
//    - Any leg `blocked` → Run verdict `blocked`, abort remaining legs.
//
//  This file owns the **pure** parts of that aggregation — leg
//  expansion, verdict roll-up, skip-synth — so they can be unit-tested
//  in isolation. The actor-isolated parts (reinstalling the simulator,
//  driving the LLM loop, writing the JSONL log) stay in
//  `RunCoordinator`, which calls these helpers from inside its leg
//  loop. Splitting them this way:
//
//    - keeps RunCoordinator's runAllLegs readable;
//    - lets ChainExecutorTests assert on aggregation rules without
//      booting a fake simulator + fake LLM stack;
//    - leaves a single file for future chain-feature work to land in
//      (parallel legs, conditional legs, retry policy) without
//      sprawling into other files.
//

import Foundation

/// Helpers for the chain executor's bookkeeping. Stateless; every method
/// is `static`. The coordinator keeps the leg loop in its actor.
enum ChainExecutor {

    // MARK: Leg expansion

    /// Materialize the leg list for a request. `.singleAction` and
    /// `.ad_hoc` produce one synthetic leg (so every run shares the
    /// same JSONL shape). `.chain` returns its declared legs verbatim.
    static func expandedLegs(for request: RunRequest) -> [ChainLeg] {
        switch request.payload {
        case .chain(_, let legs):
            return legs
        case .singleAction(let actionID, let goal):
            return [ChainLeg(
                id: UUID(),
                index: 0,
                actionID: actionID,
                actionName: "",
                goal: goal,
                preservesState: false
            )]
        case .ad_hoc:
            return [ChainLeg(
                id: UUID(),
                index: 0,
                actionID: nil,
                actionName: "",
                goal: request.goal,
                preservesState: false
            )]
        }
    }

    // MARK: Verdict aggregation

    /// Aggregate a list of leg verdicts into a run-level verdict.
    /// `nil` entries are treated as `.blocked`. Returns `.success` only
    /// when every leg succeeded.
    static func aggregateVerdict(_ legVerdicts: [Verdict?]) -> Verdict {
        guard !legVerdicts.isEmpty else { return .blocked }
        // Any failure → failure.
        if legVerdicts.contains(where: { $0 == .failure }) { return .failure }
        // Any blocked or nil → blocked.
        if legVerdicts.contains(where: { $0 == .blocked || $0 == nil }) { return .blocked }
        // All success.
        return .success
    }

    /// Decide whether the executor should short-circuit subsequent legs
    /// after this leg's verdict. `success` continues; everything else
    /// (failure, blocked, missing) stops the chain.
    static func shouldShortCircuit(after verdict: Verdict?) -> Bool {
        switch verdict {
        case .some(.success): return false
        default: return true
        }
    }

    // MARK: Leg-record blob

    /// Encode a list of `LegRecord`s to the JSON-string form persisted
    /// on `RunRecord.legsJSON`. Returns `nil` if encoding fails (we
    /// never want a chain executor failure here to abort the run —
    /// callers fall through to leaving `legsJSON` untouched).
    static func encodeLegs(_ records: [LegRecord]) -> String? {
        guard let data = try? JSONEncoder().encode(records) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
