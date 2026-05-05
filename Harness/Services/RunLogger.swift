//
//  RunLogger.swift
//  Harness
//
//  Append-only JSONL writer for one run, plus screenshot dump. One actor per
//  active run; the actor owns the FileHandle and serializes every write.
//
//  Schema is documented in `standards/14-run-logging-format.md` and
//  `https://github.com/awizemann/harness/wiki/Run-Replay-Format`. Invariants (one writer, fsync per row,
//  screenshot-before-event, schema-version tag) are tested by the round-trip
//  suite.
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Row schema (encodable)

/// Tagged union of every JSONL row kind. Phase E adds `legStarted` and
/// `legCompleted`; the schema version bumps to v2 so downstream parsers
/// can switch decoder paths. Older v1 logs (pre-rework) stay readable
/// — see `RunLogParser` for the v1 → v2 reader migration semantics.
enum LogRow: Sendable {
    case runStarted(RunStartedPayload)
    case legStarted(LegStartedPayload)
    case stepStarted(StepStartedPayload)
    case toolCall(ToolCallPayload)
    case toolResult(ToolResultPayload)
    case friction(FrictionPayload)
    case stepCompleted(StepCompletedPayload)
    case legCompleted(LegCompletedPayload)
    case runCompleted(RunCompletedPayload)

    var kind: String {
        switch self {
        case .runStarted: return "run_started"
        case .legStarted: return "leg_started"
        case .stepStarted: return "step_started"
        case .toolCall: return "tool_call"
        case .toolResult: return "tool_result"
        case .friction: return "friction"
        case .stepCompleted: return "step_completed"
        case .legCompleted: return "leg_completed"
        case .runCompleted: return "run_completed"
        }
    }
}

struct RunStartedPayload: Sendable, Codable {
    let goal: String
    let persona: String
    let model: String
    let mode: String
    let stepBudget: Int
    let tokenBudget: Int
    let project: ProjectInfo
    let simulator: SimulatorInfo

    struct ProjectInfo: Sendable, Codable {
        let path: String
        let scheme: String
        let displayName: String
    }
    struct SimulatorInfo: Sendable, Codable {
        let udid: String
        let name: String
        let runtime: String
        let pointWidth: Int
        let pointHeight: Int
        let scaleFactor: Double
    }
}

struct StepStartedPayload: Sendable, Codable {
    let step: Int
    let screenshot: String  // relative path
    let tokensUsedSoFar: Int
}

struct ToolCallPayload: Sendable, Codable {
    let step: Int
    let tool: String
    let observation: String
    let intent: String
    /// Raw input dict, encoded as Data; LogRow encoder splices it into the row.
    /// Carried as a JSON string here to keep the type Codable.
    let inputJSON: String
}

struct ToolResultPayload: Sendable, Codable {
    let step: Int
    let tool: String
    let success: Bool
    let durationMs: Int
    let error: String?
    let userDecision: String?
    let userNote: String?
}

struct FrictionPayload: Sendable, Codable {
    let step: Int
    let frictionKind: String
    let detail: String
}

struct StepCompletedPayload: Sendable, Codable {
    let step: Int
    let durationMs: Int
    let tokensInput: Int
    let tokensOutput: Int
}

struct RunCompletedPayload: Sendable, Codable {
    let verdict: String
    let summary: String
    let frictionCount: Int
    let wouldRealUserSucceed: Bool
    let stepCount: Int
    let tokensUsedInputTotal: Int
    let tokensUsedOutputTotal: Int
    /// Cache-read tokens accumulated across the run. Optional so logs from
    /// before this field landed parse cleanly as 0.
    let tokensUsedCacheReadTotal: Int
    /// Cache-creation tokens accumulated across the run. Same backwards-
    /// compat shape.
    let tokensUsedCacheCreationTotal: Int

    init(
        verdict: String,
        summary: String,
        frictionCount: Int,
        wouldRealUserSucceed: Bool,
        stepCount: Int,
        tokensUsedInputTotal: Int,
        tokensUsedOutputTotal: Int,
        tokensUsedCacheReadTotal: Int = 0,
        tokensUsedCacheCreationTotal: Int = 0
    ) {
        self.verdict = verdict
        self.summary = summary
        self.frictionCount = frictionCount
        self.wouldRealUserSucceed = wouldRealUserSucceed
        self.stepCount = stepCount
        self.tokensUsedInputTotal = tokensUsedInputTotal
        self.tokensUsedOutputTotal = tokensUsedOutputTotal
        self.tokensUsedCacheReadTotal = tokensUsedCacheReadTotal
        self.tokensUsedCacheCreationTotal = tokensUsedCacheCreationTotal
    }

    enum CodingKeys: String, CodingKey {
        case verdict, summary, frictionCount, wouldRealUserSucceed
        case stepCount, tokensUsedInputTotal, tokensUsedOutputTotal
        case tokensUsedCacheReadTotal, tokensUsedCacheCreationTotal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.verdict = try c.decode(String.self, forKey: .verdict)
        self.summary = try c.decode(String.self, forKey: .summary)
        self.frictionCount = try c.decode(Int.self, forKey: .frictionCount)
        self.wouldRealUserSucceed = try c.decode(Bool.self, forKey: .wouldRealUserSucceed)
        self.stepCount = try c.decode(Int.self, forKey: .stepCount)
        self.tokensUsedInputTotal = try c.decode(Int.self, forKey: .tokensUsedInputTotal)
        self.tokensUsedOutputTotal = try c.decode(Int.self, forKey: .tokensUsedOutputTotal)
        self.tokensUsedCacheReadTotal = try c.decodeIfPresent(Int.self, forKey: .tokensUsedCacheReadTotal) ?? 0
        self.tokensUsedCacheCreationTotal = try c.decodeIfPresent(Int.self, forKey: .tokensUsedCacheCreationTotal) ?? 0
    }
}

/// New in v2 — emitted at the top of each leg of a chain run. For
/// single-action runs the coordinator still emits one `legStarted` so
/// the log has at least one leg around its step rows. `index` is 0-based.
struct LegStartedPayload: Sendable, Codable {
    let leg: Int
    let actionName: String
    let goal: String
    let preservesState: Bool
}

/// New in v2 — emitted when a leg ends. `verdict` is `"success" |
/// "failure" | "blocked"` for executed legs, or `"skipped"` when the
/// chain executor short-circuited remaining legs after an earlier
/// leg's failure/blocked verdict.
struct LegCompletedPayload: Sendable, Codable {
    let leg: Int
    let verdict: String
    let summary: String
}

// MARK: - Errors

enum LogWriteFailure: Error, Sendable, LocalizedError {
    case diskFull
    case permissionDenied(path: String)
    case screenshotWriteFailed(step: Int, underlying: String)
    case appendAfterCompletion
    case appendBeforeStart
    case duplicateStart
    case encodingFailed(kind: String, underlying: String)
    case fileHandleOpen(path: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .diskFull: return "Disk full while writing the run log."
        case .permissionDenied(let p): return "Permission denied writing run log at \(p)."
        case .screenshotWriteFailed(let s, let u): return "Screenshot write failed at step \(s). \(u)"
        case .appendAfterCompletion: return "Internal error: tried to append a row after run_completed."
        case .appendBeforeStart: return "Internal error: tried to append a row before run_started."
        case .duplicateStart: return "Internal error: run_started written twice."
        case .encodingFailed(let k, let u): return "Failed to encode '\(k)' row. \(u)"
        case .fileHandleOpen(let p, let u): return "Could not open run log at \(p). \(u)"
        }
    }
}

// MARK: - Protocol

protocol RunLogging: Sendable {
    func append(_ row: LogRow) async throws
    func writeScreenshot(_ data: Data, step: Int) async throws -> URL
    func writeMeta(_ outcome: RunOutcome, request: RunRequest) async throws
    func close() async
}

// MARK: - Implementation

actor RunLogger: RunLogging {

    private static let logger = Logger(subsystem: "com.harness.app", category: "RunLogger")

    /// Schema version stamped on every row. Bumped to **v2** in Phase E
    /// to add `leg_started` / `leg_completed`. v1 logs (pre-rework) stay
    /// readable via the parser's tolerant fallback path.
    static let schemaVersion = 2

    let runID: UUID
    private let runDir: URL
    private let eventsURL: URL

    private var fileHandle: FileHandle?
    private var hasStarted = false
    private var hasCompleted = false

    /// Open a logger for the given run. Creates the run directory tree and
    /// installs the file handle synchronously inside the actor — no deferred
    /// Task, no installation race.
    static func open(runID: UUID) async throws -> RunLogger {
        try HarnessPaths.prepareRunDirectory(for: runID)
        let logger = RunLogger(runID: runID)
        try await logger.installInitialHandle()
        return logger
    }

    private init(runID: UUID) {
        self.runID = runID
        self.runDir = HarnessPaths.runDir(for: runID)
        self.eventsURL = HarnessPaths.eventsLog(for: runID)
    }

    private func installInitialHandle() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: eventsURL.path) {
            fm.createFile(atPath: eventsURL.path, contents: Data(), attributes: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: eventsURL)
            try handle.seekToEnd()
            self.fileHandle = handle
        } catch {
            throw LogWriteFailure.fileHandleOpen(path: eventsURL.path, underlying: error.localizedDescription)
        }
    }

    // MARK: Append

    func append(_ row: LogRow) async throws {
        guard let handle = fileHandle else {
            // Defensive: re-open if it was closed.
            try installInitialHandle()
            try await append(row)
            return
        }

        // Order invariants.
        switch row {
        case .runStarted:
            if hasStarted { throw LogWriteFailure.duplicateStart }
            hasStarted = true
        case .runCompleted:
            if !hasStarted { throw LogWriteFailure.appendBeforeStart }
            if hasCompleted { throw LogWriteFailure.appendAfterCompletion }
            hasCompleted = true
        default:
            if !hasStarted { throw LogWriteFailure.appendBeforeStart }
            if hasCompleted { throw LogWriteFailure.appendAfterCompletion }
        }

        let data: Data
        do {
            data = try Self.encode(row, runID: runID, ts: Date())
        } catch {
            throw LogWriteFailure.encodingFailed(kind: row.kind, underlying: error.localizedDescription)
        }

        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.synchronize()
        } catch {
            // Best-effort classification of the underlying NSError code.
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain && ns.code == ENOSPC {
                throw LogWriteFailure.diskFull
            }
            if ns.domain == NSPOSIXErrorDomain && ns.code == EACCES {
                throw LogWriteFailure.permissionDenied(path: eventsURL.path)
            }
            throw LogWriteFailure.encodingFailed(kind: row.kind, underlying: error.localizedDescription)
        }
    }

    // MARK: Screenshots

    /// Write a PNG to `step-NNN.png`. Per `standards/08-run-log-integrity.md §4`,
    /// the PNG is written *before* the corresponding step_started row.
    func writeScreenshot(_ data: Data, step: Int) async throws -> URL {
        let url = HarnessPaths.screenshot(for: runID, step: step)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LogWriteFailure.screenshotWriteFailed(step: step, underlying: error.localizedDescription)
        }
        return url
    }

    // MARK: Meta

    func writeMeta(_ outcome: RunOutcome, request: RunRequest) async throws {
        let meta: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "id": runID.uuidString,
            "createdAt": Self.iso8601(Date()),
            "completedAt": Self.iso8601(outcome.completedAt),
            "verdict": outcome.verdict.rawValue,
            "frictionCount": outcome.frictionCount,
            "stepCount": outcome.stepCount,
            "tokensUsedInput": outcome.tokensUsedInput,
            "tokensUsedOutput": outcome.tokensUsedOutput,
            "tokensUsedCacheRead": outcome.tokensUsedCacheRead,
            "tokensUsedCacheCreation": outcome.tokensUsedCacheCreation,
            "model": request.model.rawValue,
            "mode": request.mode.rawValue,
            "goal": request.goal,
            "persona": request.persona,
            "projectPath": request.project.path.path,
            "scheme": request.project.scheme,
            "simulator": [
                "udid": request.simulator.udid,
                "name": request.simulator.name,
                "runtime": request.simulator.runtime
            ] as [String: Any]
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: HarnessPaths.metaFile(for: runID), options: [.atomic])
        } catch {
            throw LogWriteFailure.encodingFailed(kind: "meta", underlying: error.localizedDescription)
        }
    }

    // MARK: Close

    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Encoding

    /// `ISO8601DateFormatter` isn't `Sendable`. Build a fresh instance per call
    /// (cheap; microseconds) to keep Swift 6 strict concurrency happy.
    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Encode one row into a single line of JSON (no trailing newline).
    static func encode(_ row: LogRow, runID: UUID, ts: Date) throws -> Data {
        var dict: [String: Any] = [
            "schemaVersion": schemaVersion,
            "runId": runID.uuidString,
            "ts": iso8601(ts),
            "kind": row.kind
        ]

        switch row {
        case .runStarted(let p):
            dict["goal"] = p.goal
            dict["persona"] = p.persona
            dict["model"] = p.model
            dict["mode"] = p.mode
            dict["stepBudget"] = p.stepBudget
            dict["tokenBudget"] = p.tokenBudget
            dict["project"] = [
                "path": p.project.path,
                "scheme": p.project.scheme,
                "displayName": p.project.displayName
            ] as [String: Any]
            dict["simulator"] = [
                "udid": p.simulator.udid,
                "name": p.simulator.name,
                "runtime": p.simulator.runtime,
                "pointWidth": p.simulator.pointWidth,
                "pointHeight": p.simulator.pointHeight,
                "scaleFactor": p.simulator.scaleFactor
            ] as [String: Any]

        case .stepStarted(let p):
            dict["step"] = p.step
            dict["screenshot"] = p.screenshot
            dict["tokensUsedSoFar"] = p.tokensUsedSoFar

        case .toolCall(let p):
            dict["step"] = p.step
            dict["tool"] = p.tool
            dict["observation"] = p.observation
            dict["intent"] = p.intent
            // Splice the input dict so the row carries a real JSON object,
            // not a string blob.
            if let inputData = p.inputJSON.data(using: .utf8),
               let inputObj = try? JSONSerialization.jsonObject(with: inputData) {
                dict["input"] = inputObj
            } else {
                dict["input"] = [:] as [String: Any]
            }

        case .toolResult(let p):
            dict["step"] = p.step
            dict["tool"] = p.tool
            dict["success"] = p.success
            dict["durationMs"] = p.durationMs
            dict["error"] = p.error as Any? ?? NSNull()
            if let userDecision = p.userDecision { dict["userDecision"] = userDecision }
            if let userNote = p.userNote { dict["userNote"] = userNote }

        case .friction(let p):
            dict["step"] = p.step
            dict["frictionKind"] = p.frictionKind
            dict["detail"] = p.detail

        case .stepCompleted(let p):
            dict["step"] = p.step
            dict["durationMs"] = p.durationMs
            dict["tokensThisStep"] = [
                "input": p.tokensInput,
                "output": p.tokensOutput
            ] as [String: Any]

        case .legStarted(let p):
            dict["leg"] = p.leg
            dict["actionName"] = p.actionName
            dict["goal"] = p.goal
            dict["preservesState"] = p.preservesState

        case .legCompleted(let p):
            dict["leg"] = p.leg
            dict["verdict"] = p.verdict
            dict["summary"] = p.summary

        case .runCompleted(let p):
            dict["verdict"] = p.verdict
            dict["summary"] = p.summary
            dict["frictionCount"] = p.frictionCount
            dict["wouldRealUserSucceed"] = p.wouldRealUserSucceed
            dict["stepCount"] = p.stepCount
            dict["tokensUsedTotal"] = [
                "input": p.tokensUsedInputTotal,
                "output": p.tokensUsedOutputTotal,
                "cacheRead": p.tokensUsedCacheReadTotal,
                "cacheCreation": p.tokensUsedCacheCreationTotal
            ] as [String: Any]
        }

        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
}

// MARK: - Convenience builders

extension LogRow {
    /// Build a `runStarted` row from a `RunRequest`.
    static func runStarted(from request: RunRequest) -> LogRow {
        let sim = request.simulator
        return .runStarted(RunStartedPayload(
            goal: request.goal,
            persona: request.persona,
            model: request.model.rawValue,
            mode: request.mode.rawValue,
            stepBudget: request.stepBudget,
            tokenBudget: request.tokenBudget,
            project: .init(
                path: request.project.path.path,
                scheme: request.project.scheme,
                displayName: request.project.displayName
            ),
            simulator: .init(
                udid: sim.udid,
                name: sim.name,
                runtime: sim.runtime,
                pointWidth: Int(sim.pointSize.width),
                pointHeight: Int(sim.pointSize.height),
                scaleFactor: Double(sim.scaleFactor)
            )
        ))
    }

    /// Build a `toolCall` row from a `ToolCall`. Encodes the tagged-union input
    /// to its canonical JSON shape.
    static func toolCall(step: Int, call: ToolCall) -> LogRow {
        let inputJSON = (try? Self.toolInputJSONString(call.input)) ?? "{}"
        return .toolCall(ToolCallPayload(
            step: step,
            tool: call.tool.rawValue,
            observation: call.observation,
            intent: call.intent,
            inputJSON: inputJSON
        ))
    }

    /// Encode a `ToolInput` to its wire-shape JSON string.
    static func toolInputJSONString(_ input: ToolInput) throws -> String {
        let dict: [String: Any]
        switch input {
        case .tap(let x, let y):
            dict = ["x": x, "y": y]
        case .doubleTap(let x, let y):
            dict = ["x": x, "y": y]
        case .swipe(let x1, let y1, let x2, let y2, let ms):
            dict = ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration_ms": ms]
        case .type(let text):
            dict = ["text": text]
        case .pressButton(let button):
            dict = ["button": button.rawValue]
        case .wait(let ms):
            dict = ["ms": ms]
        case .readScreen:
            dict = [:]
        case .noteFriction(let kind, let detail):
            dict = ["kind": kind.rawValue, "detail": detail]
        case .markGoalDone(let verdict, let summary, let count, let wrus):
            dict = [
                "verdict": verdict.rawValue,
                "summary": summary,
                "friction_count": count,
                "would_real_user_succeed": wrus
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
