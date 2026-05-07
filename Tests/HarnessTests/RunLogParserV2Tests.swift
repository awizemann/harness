//
//  RunLogParserV2Tests.swift
//  HarnessTests
//
//  Coverage for the JSONL v1 → v2 migration semantics. Per
//  `standards/14-run-logging-format.md §5`:
//
//    - v2 parser accepts both `schemaVersion: 1` and `2` rows.
//    - v1 logs (no leg rows) read back as one virtual leg around all
//      step rows so downstream views can treat every run as having
//      ≥1 leg.
//    - v2 logs with explicit `leg_started`/`leg_completed` rows return
//      one ReplayLeg per leg, with step ranges populated.
//    - schemaVersion: 3 (or any other unknown version) throws so a
//      future v3 reader doesn't silently misinterpret the row shape.
//

import Testing
import Foundation
@testable import Harness

@Suite("RunLogParser — v2 schema and v1 fallback")
struct RunLogParserV2Tests {

    // MARK: Helpers

    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func writeJSON(_ rows: [[String: Any]]) -> Data {
        var out = Data()
        for dict in rows {
            let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            out.append(data)
            out.append(0x0A)
        }
        return out
    }

    private static func makeRunStarted(version: Int, runID: UUID, ts: String) -> [String: Any] {
        [
            "schemaVersion": version,
            "runId": runID.uuidString,
            "ts": ts,
            "kind": "run_started",
            "goal": "test goal",
            "persona": "tester",
            "model": "claude-opus-4-7",
            "mode": "stepByStep",
            "stepBudget": 40,
            "tokenBudget": 250000,
            "project": [
                "path": "/tmp/X.xcodeproj",
                "scheme": "X",
                "displayName": "X"
            ] as [String: Any],
            "simulator": [
                "udid": "FAKE", "name": "iPhone", "runtime": "iOS 18.4",
                "pointWidth": 430, "pointHeight": 932, "scaleFactor": 3.0
            ] as [String: Any]
        ]
    }

    private static func makeStepStarted(version: Int, runID: UUID, ts: String, step: Int) -> [String: Any] {
        [
            "schemaVersion": version,
            "runId": runID.uuidString,
            "ts": ts,
            "kind": "step_started",
            "step": step,
            "screenshot": "step-\(String(format: "%03d", step)).png",
            "tokensUsedSoFar": 0
        ]
    }

    private static func makeRunCompleted(version: Int, runID: UUID, ts: String) -> [String: Any] {
        [
            "schemaVersion": version,
            "runId": runID.uuidString,
            "ts": ts,
            "kind": "run_completed",
            "verdict": "success",
            "summary": "did it",
            "frictionCount": 0,
            "wouldRealUserSucceed": true,
            "stepCount": 2,
            "tokensUsedTotal": ["input": 100, "output": 50] as [String: Any]
        ]
    }

    // MARK: v1 fixture

    @Test("v1 fixture (no leg rows) parses cleanly under v2 reader")
    func parsesV1Fixture() throws {
        let runID = UUID()
        let ts = Self.makeFormatter().string(from: Date())
        let data = Self.writeJSON([
            Self.makeRunStarted(version: 1, runID: runID, ts: ts),
            Self.makeStepStarted(version: 1, runID: runID, ts: ts, step: 1),
            Self.makeStepStarted(version: 1, runID: runID, ts: ts, step: 2),
            Self.makeRunCompleted(version: 1, runID: runID, ts: ts)
        ])
        let rows = try RunLogParser.parse(jsonlData: data)
        #expect(rows.count == 4)
        // None of them are leg rows — that's the whole point.
        let anyLegRow = rows.contains { row in
            if case .legStarted = row { return true }
            if case .legCompleted = row { return true }
            return false
        }
        #expect(anyLegRow == false)
    }

    @Test("v1 fixture → legViews synthesizes one virtual leg around all steps")
    func v1LegSynthesis() throws {
        let runID = UUID()
        let ts = Self.makeFormatter().string(from: Date())
        let data = Self.writeJSON([
            Self.makeRunStarted(version: 1, runID: runID, ts: ts),
            Self.makeStepStarted(version: 1, runID: runID, ts: ts, step: 1),
            Self.makeStepStarted(version: 1, runID: runID, ts: ts, step: 2),
            Self.makeStepStarted(version: 1, runID: runID, ts: ts, step: 3),
            Self.makeRunCompleted(version: 1, runID: runID, ts: ts)
        ])
        let rows = try RunLogParser.parse(jsonlData: data)
        let legs = RunLogParser.legViews(from: rows)

        #expect(legs.count == 1, "v1 logs always synthesize exactly one virtual leg")
        let leg = legs[0]
        #expect(leg.index == 0)
        #expect(leg.stepStart == 1)
        #expect(leg.stepEnd == 3)
        #expect(leg.verdict == .success)
        #expect(leg.goal == "test goal")
    }

    // MARK: v2 fixture

    @Test("v2 fixture with two legs returns two ReplayLegs with correct step ranges")
    func parsesV2TwoLegFixture() throws {
        let runID = UUID()
        let ts = Self.makeFormatter().string(from: Date())
        let data = Self.writeJSON([
            Self.makeRunStarted(version: 2, runID: runID, ts: ts),
            // Leg 0
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_started",
             "leg": 0, "actionName": "Add milk", "goal": "add milk", "preservesState": false],
            Self.makeStepStarted(version: 2, runID: runID, ts: ts, step: 1),
            Self.makeStepStarted(version: 2, runID: runID, ts: ts, step: 2),
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_completed",
             "leg": 0, "verdict": "success", "summary": "added"],
            // Leg 1
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_started",
             "leg": 1, "actionName": "Mark done", "goal": "mark done", "preservesState": true],
            Self.makeStepStarted(version: 2, runID: runID, ts: ts, step: 3),
            Self.makeStepStarted(version: 2, runID: runID, ts: ts, step: 4),
            Self.makeStepStarted(version: 2, runID: runID, ts: ts, step: 5),
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_completed",
             "leg": 1, "verdict": "success", "summary": "marked done"],
            Self.makeRunCompleted(version: 2, runID: runID, ts: ts)
        ])
        let rows = try RunLogParser.parse(jsonlData: data)
        let legs = RunLogParser.legViews(from: rows)

        #expect(legs.count == 2)
        #expect(legs[0].index == 0)
        #expect(legs[0].stepStart == 1)
        #expect(legs[0].stepEnd == 2)
        #expect(legs[0].verdict == .success)
        #expect(legs[0].preservesState == false)
        #expect(legs[0].actionName == "Add milk")

        #expect(legs[1].index == 1)
        #expect(legs[1].stepStart == 3)
        #expect(legs[1].stepEnd == 5)
        #expect(legs[1].verdict == .success)
        #expect(legs[1].preservesState == true)
        #expect(legs[1].actionName == "Mark done")
    }

    @Test("v2 fixture with skipped second leg parses verdict as skipped")
    func parsesSkippedLeg() throws {
        let runID = UUID()
        let ts = Self.makeFormatter().string(from: Date())
        let data = Self.writeJSON([
            Self.makeRunStarted(version: 2, runID: runID, ts: ts),
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_started",
             "leg": 0, "actionName": "First", "goal": "first", "preservesState": false],
            Self.makeStepStarted(version: 2, runID: runID, ts: ts, step: 1),
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_completed",
             "leg": 0, "verdict": "failure", "summary": "broke"],
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_started",
             "leg": 1, "actionName": "Second", "goal": "second", "preservesState": false],
            ["schemaVersion": 2, "runId": runID.uuidString, "ts": ts, "kind": "leg_completed",
             "leg": 1, "verdict": "skipped", "summary": "skipped — earlier leg ended the run"],
            Self.makeRunCompleted(version: 2, runID: runID, ts: ts)
        ])
        let rows = try RunLogParser.parse(jsonlData: data)
        let legs = RunLogParser.legViews(from: rows)

        #expect(legs.count == 2)
        #expect(legs[0].verdict == .failure)
        // Skipped legs encode as verdictRaw == "skipped". `Verdict.init` returns nil.
        #expect(legs[1].verdict == nil)
        #expect(legs[1].summary.contains("skipped"))
    }

    // MARK: Schema-version guard

    @Test("Unknown schema version (v4) throws schemaVersionUnsupported")
    func unknownVersionThrows() {
        // v3 is now valid (V5 ships with schemaVersion=3 — credential
        // metadata on run_started + fill_credential tool input shape).
        // Probe with v4 instead so the guard still fires until a future
        // bump catches up.
        let runID = UUID()
        let ts = Self.makeFormatter().string(from: Date())
        let data = Self.writeJSON([
            ["schemaVersion": 4, "runId": runID.uuidString, "ts": ts,
             "kind": "run_started", "goal": "x", "persona": "y",
             "model": "claude-opus-4-7", "mode": "autonomous",
             "stepBudget": 1, "tokenBudget": 1,
             "project": ["path": "x", "scheme": "y", "displayName": "z"] as [String: Any],
             "simulator": ["udid": "x", "name": "y", "runtime": "z",
                           "pointWidth": 1, "pointHeight": 1, "scaleFactor": 1.0] as [String: Any]]
        ])
        do {
            _ = try RunLogParser.parse(jsonlData: data)
            Issue.record("expected schemaVersionUnsupported throw")
        } catch ParseError.schemaVersionUnsupported(let v) {
            #expect(v == 4)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
