//
//  RunLogParser.swift
//  Harness
//
//  Reads a finished (or partial) run's `events.jsonl` back into typed values.
//  Idempotent and side-effect-free per `standards/08-run-log-integrity.md §6`.
//
//  Tolerates trailing partial rows (a crashed Harness leaves a valid prefix).
//  Verifies replay invariants on demand: run_started first, run_completed
//  last (when present), step numbers monotonic + gap-free.
//

import Foundation

// MARK: - Decoded row union

/// What the parser hands back. Mirrors `LogRow` but carries the timestamp +
/// runId so consumers can validate cross-row invariants.
///
/// `legStarted` / `legCompleted` are v2 additions. v1 logs (pre-Phase-E)
/// don't carry leg rows; consumers that need a leg view should call
/// `RunLogParser.legViews(from:)` which synthesizes one virtual leg
/// around the entire row sequence in that case.
enum DecodedRow: Sendable {
    case runStarted(ts: Date, payload: RunStartedPayload)
    case legStarted(ts: Date, payload: LegStartedPayload)
    case stepStarted(ts: Date, payload: StepStartedPayload)
    case toolCall(ts: Date, payload: ToolCallPayload)
    case toolResult(ts: Date, payload: ToolResultPayload)
    case friction(ts: Date, payload: FrictionPayload)
    case stepCompleted(ts: Date, payload: StepCompletedPayload)
    case legCompleted(ts: Date, payload: LegCompletedPayload)
    case runCompleted(ts: Date, payload: RunCompletedPayload)

    var step: Int? {
        switch self {
        case .stepStarted(_, let p): return p.step
        case .toolCall(_, let p): return p.step
        case .toolResult(_, let p): return p.step
        case .friction(_, let p): return p.step
        case .stepCompleted(_, let p): return p.step
        case .runStarted, .runCompleted, .legStarted, .legCompleted: return nil
        }
    }
}

/// One leg as seen by the replay layer. Synthesized by
/// `RunLogParser.legViews(from:)` from either v2 leg rows (one per leg)
/// or v1 fallback (one virtual leg covering all step rows).
struct ReplayLeg: Sendable, Hashable, Identifiable {
    let id: Int            // matches the leg's index
    let index: Int         // 0-based
    let actionName: String
    let goal: String
    let preservesState: Bool
    let verdict: Verdict?  // nil while running; nil for skipped (use `summary == "skipped"`).
    let summary: String
    /// Inclusive step range belonging to this leg, expressed as the
    /// 1-based step numbers seen in `step_started` rows. For an empty
    /// leg (chain leg that fired but never reached step 1 — rare;
    /// can happen on an immediate failure), both bounds are nil.
    let stepStart: Int?
    let stepEnd: Int?
}

enum ParseError: Error, Sendable, LocalizedError {
    case fileUnreadable(URL)
    case schemaVersionUnsupported(Int)
    case missingRunStarted
    case unexpectedRowAfterCompletion
    case stepGap(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable(let u): return "Cannot read run log at \(u.path)."
        case .schemaVersionUnsupported(let v): return "This run uses an unsupported log schema (v\(v))."
        case .missingRunStarted: return "Run log is malformed: the first row is not run_started."
        case .unexpectedRowAfterCompletion: return "Run log is malformed: a row appears after run_completed."
        case .stepGap(let e, let g): return "Run log step numbers have a gap: expected \(e), got \(g)."
        }
    }
}

// MARK: - Parser

enum RunLogParser {

    /// Parse a run directory into ordered `DecodedRow`s. Returns the rows
    /// successfully decoded; trailing partial lines are silently truncated.
    /// Doesn't validate invariants — call `validateInvariants(_:)` for that.
    static func parse(runID: UUID) throws -> [DecodedRow] {
        let url = HarnessPaths.eventsLog(for: runID)
        guard let data = try? Data(contentsOf: url) else {
            throw ParseError.fileUnreadable(url)
        }
        return try parse(jsonlData: data)
    }

    /// Parse a jsonl blob (test entry point).
    static func parse(jsonlData data: Data) throws -> [DecodedRow] {
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var out: [DecodedRow] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Defend against truncated tail: try to decode; on failure for the
            // final non-empty line, treat as partial-write and stop.
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                let isLastNonEmpty = idx >= lines.count - 1 || lines[(idx + 1)...]
                    .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if isLastNonEmpty { return out }
                continue
            }

            // Schema check. Both v1 (pre-Phase-E) and v2 (Phase E+) parse;
            // unknown versions throw so a future v3 reader doesn't silently
            // misinterpret the row shape.
            if let v = obj["schemaVersion"] as? Int, v != 1 && v != 2 {
                throw ParseError.schemaVersionUnsupported(v)
            }

            guard let kind = obj["kind"] as? String,
                  let tsString = obj["ts"] as? String,
                  let ts = Self.makeIsoFormatter().date(from: tsString) else {
                continue
            }

            if let row = try decodeRow(kind: kind, ts: ts, obj: obj) {
                out.append(row)
            }
        }

        return out
    }

    /// Validate replay invariants. Throws on first violation; otherwise returns.
    static func validateInvariants(_ rows: [DecodedRow]) throws {
        // run_started must be first.
        guard let first = rows.first, case .runStarted = first else {
            if !rows.isEmpty { throw ParseError.missingRunStarted }
            return
        }

        var sawCompleted = false
        var expectedNextStep = 1

        for (idx, row) in rows.enumerated() {
            // run_completed (if present) must be last.
            if sawCompleted && idx < rows.count {
                throw ParseError.unexpectedRowAfterCompletion
            }
            if case .runCompleted = row {
                sawCompleted = true
                continue
            }

            // step_started must come in order, gap-free.
            if case .stepStarted(_, let p) = row {
                if p.step != expectedNextStep {
                    throw ParseError.stepGap(expected: expectedNextStep, got: p.step)
                }
                expectedNextStep += 1
            }
        }
    }

    // MARK: Private decoders

    /// `ISO8601DateFormatter` is not `Sendable`. Build a fresh instance per
    /// parse — cheap (microseconds), keeps Swift 6 strict concurrency happy.
    private static func makeIsoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func decodeRow(kind: String, ts: Date, obj: [String: Any]) throws -> DecodedRow? {
        switch kind {
        case "run_started":
            guard let project = obj["project"] as? [String: Any],
                  let sim = obj["simulator"] as? [String: Any] else { return nil }
            let payload = RunStartedPayload(
                goal: (obj["goal"] as? String) ?? "",
                persona: (obj["persona"] as? String) ?? "",
                model: (obj["model"] as? String) ?? "",
                mode: (obj["mode"] as? String) ?? "",
                stepBudget: (obj["stepBudget"] as? Int) ?? 0,
                tokenBudget: (obj["tokenBudget"] as? Int) ?? 0,
                project: .init(
                    path: (project["path"] as? String) ?? "",
                    scheme: (project["scheme"] as? String) ?? "",
                    displayName: (project["displayName"] as? String) ?? ""
                ),
                simulator: .init(
                    udid: (sim["udid"] as? String) ?? "",
                    name: (sim["name"] as? String) ?? "",
                    runtime: (sim["runtime"] as? String) ?? "",
                    pointWidth: (sim["pointWidth"] as? Int) ?? 0,
                    pointHeight: (sim["pointHeight"] as? Int) ?? 0,
                    scaleFactor: (sim["scaleFactor"] as? Double) ?? 1.0
                )
            )
            return .runStarted(ts: ts, payload: payload)

        case "step_started":
            return .stepStarted(ts: ts, payload: StepStartedPayload(
                step: (obj["step"] as? Int) ?? 0,
                screenshot: (obj["screenshot"] as? String) ?? "",
                tokensUsedSoFar: (obj["tokensUsedSoFar"] as? Int) ?? 0
            ))

        case "tool_call":
            let inputObj = obj["input"] ?? [:]
            let inputData = (try? JSONSerialization.data(withJSONObject: inputObj)) ?? Data("{}".utf8)
            let inputString = String(data: inputData, encoding: .utf8) ?? "{}"
            return .toolCall(ts: ts, payload: ToolCallPayload(
                step: (obj["step"] as? Int) ?? 0,
                tool: (obj["tool"] as? String) ?? "",
                observation: (obj["observation"] as? String) ?? "",
                intent: (obj["intent"] as? String) ?? "",
                inputJSON: inputString
            ))

        case "tool_result":
            return .toolResult(ts: ts, payload: ToolResultPayload(
                step: (obj["step"] as? Int) ?? 0,
                tool: (obj["tool"] as? String) ?? "",
                success: (obj["success"] as? Bool) ?? false,
                durationMs: (obj["durationMs"] as? Int) ?? 0,
                error: obj["error"] as? String,
                userDecision: obj["userDecision"] as? String,
                userNote: obj["userNote"] as? String
            ))

        case "friction":
            return .friction(ts: ts, payload: FrictionPayload(
                step: (obj["step"] as? Int) ?? 0,
                frictionKind: (obj["frictionKind"] as? String) ?? "",
                detail: (obj["detail"] as? String) ?? ""
            ))

        case "step_completed":
            let tokens = obj["tokensThisStep"] as? [String: Any] ?? [:]
            return .stepCompleted(ts: ts, payload: StepCompletedPayload(
                step: (obj["step"] as? Int) ?? 0,
                durationMs: (obj["durationMs"] as? Int) ?? 0,
                tokensInput: (tokens["input"] as? Int) ?? 0,
                tokensOutput: (tokens["output"] as? Int) ?? 0
            ))

        case "run_completed":
            let totals = obj["tokensUsedTotal"] as? [String: Any] ?? [:]
            return .runCompleted(ts: ts, payload: RunCompletedPayload(
                verdict: (obj["verdict"] as? String) ?? "",
                summary: (obj["summary"] as? String) ?? "",
                frictionCount: (obj["frictionCount"] as? Int) ?? 0,
                wouldRealUserSucceed: (obj["wouldRealUserSucceed"] as? Bool) ?? false,
                stepCount: (obj["stepCount"] as? Int) ?? 0,
                tokensUsedInputTotal: (totals["input"] as? Int) ?? 0,
                tokensUsedOutputTotal: (totals["output"] as? Int) ?? 0,
                tokensUsedCacheReadTotal: (totals["cacheRead"] as? Int) ?? 0,
                tokensUsedCacheCreationTotal: (totals["cacheCreation"] as? Int) ?? 0
            ))

        case "leg_started":
            return .legStarted(ts: ts, payload: LegStartedPayload(
                leg: (obj["leg"] as? Int) ?? 0,
                actionName: (obj["actionName"] as? String) ?? "",
                goal: (obj["goal"] as? String) ?? "",
                preservesState: (obj["preservesState"] as? Bool) ?? false
            ))

        case "leg_completed":
            return .legCompleted(ts: ts, payload: LegCompletedPayload(
                leg: (obj["leg"] as? Int) ?? 0,
                verdict: (obj["verdict"] as? String) ?? "",
                summary: (obj["summary"] as? String) ?? ""
            ))

        default:
            // Unknown kind: tolerate silently (forward-compat per standard 08).
            return nil
        }
    }

    // MARK: - Leg synthesis

    /// Group decoded rows into one or more `ReplayLeg`s. v2 logs carry
    /// `leg_started`/`leg_completed` rows directly; v1 logs (pre-Phase-E)
    /// have neither, so we synthesize a single virtual leg whose step
    /// range spans all step rows. This lets every replay-time consumer
    /// treat a run as having ≥1 leg without conditional branches.
    static func legViews(from rows: [DecodedRow]) -> [ReplayLeg] {
        // Walk the rows once. Track which leg we're currently inside
        // (for v2) and the min/max step number seen between legStarted
        // and legCompleted boundaries.
        struct InProgress {
            var index: Int
            var actionName: String
            var goal: String
            var preservesState: Bool
            var verdict: Verdict?
            var summary: String
            var stepStart: Int?
            var stepEnd: Int?
        }
        var legs: [ReplayLeg] = []
        var current: InProgress?
        var anyLegRow = false

        for row in rows {
            switch row {
            case .legStarted(_, let p):
                anyLegRow = true
                // Close out any unclosed prior leg (shouldn't happen on a
                // well-formed log; defensive only).
                if let cur = current {
                    legs.append(ReplayLeg(
                        id: cur.index,
                        index: cur.index,
                        actionName: cur.actionName,
                        goal: cur.goal,
                        preservesState: cur.preservesState,
                        verdict: cur.verdict,
                        summary: cur.summary,
                        stepStart: cur.stepStart,
                        stepEnd: cur.stepEnd
                    ))
                }
                current = InProgress(
                    index: p.leg,
                    actionName: p.actionName,
                    goal: p.goal,
                    preservesState: p.preservesState,
                    verdict: nil,
                    summary: "",
                    stepStart: nil,
                    stepEnd: nil
                )
            case .legCompleted(_, let p):
                anyLegRow = true
                guard var cur = current else { continue }
                cur.verdict = Verdict(rawValue: p.verdict)
                cur.summary = p.summary.isEmpty ? p.verdict : p.summary
                legs.append(ReplayLeg(
                    id: cur.index,
                    index: cur.index,
                    actionName: cur.actionName,
                    goal: cur.goal,
                    preservesState: cur.preservesState,
                    verdict: cur.verdict,
                    summary: cur.summary,
                    stepStart: cur.stepStart,
                    stepEnd: cur.stepEnd
                ))
                current = nil
            case .stepStarted(_, let p):
                if current != nil {
                    if current!.stepStart == nil { current!.stepStart = p.step }
                    current!.stepEnd = p.step
                }
            default:
                continue
            }
        }
        // Close any still-open in-progress leg (run crashed mid-leg).
        if let cur = current {
            legs.append(ReplayLeg(
                id: cur.index,
                index: cur.index,
                actionName: cur.actionName,
                goal: cur.goal,
                preservesState: cur.preservesState,
                verdict: cur.verdict,
                summary: cur.summary,
                stepStart: cur.stepStart,
                stepEnd: cur.stepEnd
            ))
        }

        // v1 fallback — no leg rows seen. Synthesize one virtual leg
        // around every step. Pull goal + verdict from the runStarted /
        // runCompleted rows so the replay UI has something to render.
        if !anyLegRow {
            var goal = ""
            var verdict: Verdict?
            var summary = ""
            var stepStart: Int?
            var stepEnd: Int?
            for row in rows {
                switch row {
                case .runStarted(_, let p):
                    goal = p.goal
                case .runCompleted(_, let p):
                    verdict = Verdict(rawValue: p.verdict)
                    summary = p.summary
                case .stepStarted(_, let p):
                    if stepStart == nil { stepStart = p.step }
                    stepEnd = p.step
                default:
                    continue
                }
            }
            return [ReplayLeg(
                id: 0,
                index: 0,
                actionName: "",
                goal: goal,
                preservesState: false,
                verdict: verdict,
                summary: summary,
                stepStart: stepStart,
                stepEnd: stepEnd
            )]
        }

        return legs.sorted(by: { $0.index < $1.index })
    }
}
