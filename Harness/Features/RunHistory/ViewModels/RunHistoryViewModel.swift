//
//  RunHistoryViewModel.swift
//  Harness
//

import Foundation
import Observation

/// Verdict filter applied on top of the substring search in `RunHistoryView`.
enum VerdictFilter: String, Hashable, CaseIterable, Identifiable {
    case all
    case success
    case blocked
    case failure
    case running

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return "All"
        case .success: return "Success"
        case .blocked: return "Blocked"
        case .failure: return "Failed"
        case .running: return "In progress"
        }
    }
}

/// One day's worth of runs, grouped for the left rail's section headers.
struct RunHistoryDayGroup: Identifiable, Hashable {
    let id: Date
    let label: String
    let runs: [RunRecordSnapshot]
}

/// Decoded detail for a single run, parsed from `events.jsonl` on demand and
/// cached so flipping back and forth between selections is instant.
struct RunDetail: Sendable, Hashable {
    /// Steps in declared order. We carry the production `ToolCall` so the
    /// detail view can map to `ToolCallChip` via the existing mapper.
    let steps: [Step]
    let frictionEvents: [FrictionEvent]
    let elapsedSeconds: Int

    struct Step: Sendable, Hashable, Identifiable {
        let id: Int
        let n: Int
        let toolCall: ToolCall?
    }
}

@Observable
@MainActor
final class RunHistoryViewModel {

    var runs: [RunRecordSnapshot] = []
    var isLoading = false
    var exportError: String?

    /// Cache of decoded run details keyed by run id. Populated lazily by
    /// `loadDetail(for:)`; never invalidated within a single view-model
    /// lifetime since `events.jsonl` is append-only.
    private var detailCache: [UUID: RunDetail] = [:]

    private let store: any RunHistoryStoring

    init(store: any RunHistoryStoring) {
        self.store = store
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        runs = (try? await store.fetchRecent(limit: 100)) ?? []
        detailCache.removeAll(keepingCapacity: true)
    }

    func delete(id: UUID) async {
        try? await store.delete(id: id)
        detailCache[id] = nil
        await reload()
    }

    /// Apply substring search across goal/persona/displayName/simulatorName,
    /// AND a verdict filter when not `.all`. Empty search → no substring filter.
    /// When `applicationID` is non-nil, only runs scoped to that Application
    /// pass — the workspace rework defaults to scoping by the active Application
    /// so history feels app-scoped without an explicit filter chip.
    func filteredRuns(
        search: String,
        verdict: VerdictFilter,
        applicationID: UUID? = nil
    ) -> [RunRecordSnapshot] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return runs.filter { run in
            if let applicationID, run.applicationID != applicationID {
                return false
            }
            if !needle.isEmpty {
                let haystack = [run.goal, run.persona, run.displayName, run.simulatorName]
                    .joined(separator: "\n")
                    .lowercased()
                if !haystack.contains(needle) { return false }
            }
            switch verdict {
            case .all:     return true
            case .success: return run.verdict == .success
            case .blocked: return run.verdict == .blocked
            case .failure: return run.verdict == .failure
            case .running: return run.verdict == nil
            }
        }
    }

    /// Group runs by `Calendar.startOfDay`, labeled "Today" / "Yesterday" /
    /// explicit date for older sections. Order is most recent day first;
    /// within a day, runs are most recent first.
    func dayGroups(from runs: [RunRecordSnapshot]) -> [RunHistoryDayGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"

        var bucket: [Date: [RunRecordSnapshot]] = [:]
        for run in runs {
            let day = calendar.startOfDay(for: run.createdAt)
            bucket[day, default: []].append(run)
        }
        return bucket.keys.sorted(by: >).map { day in
            let label: String
            if day == today { label = "Today, \(formatter.string(from: day))" }
            else if let yesterday, day == yesterday { label = "Yesterday, \(formatter.string(from: day))" }
            else { label = formatter.string(from: day) }
            let dayRuns = (bucket[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            return RunHistoryDayGroup(id: day, label: label, runs: dayRuns)
        }
    }

    /// Parse the run's `events.jsonl` once and cache the decoded detail.
    /// Returns the cached value on subsequent calls.
    func loadDetail(for runID: UUID) async -> RunDetail? {
        if let cached = detailCache[runID] { return cached }
        let detail: RunDetail? = await Task.detached(priority: .userInitiated) {
            guard let rows = try? RunLogParser.parse(runID: runID) else { return nil }
            return Self.decodeDetail(rows: rows)
        }.value
        if let detail { detailCache[runID] = detail }
        return detail
    }

    /// Pure transform from parser rows → display-ready detail. Lives on the
    /// type so `loadDetail(for:)` can call it from a detached task without
    /// capturing actor state.
    nonisolated private static func decodeDetail(rows: [DecodedRow]) -> RunDetail {
        var byStep: [Int: ToolCall] = [:]
        var frictions: [FrictionEvent] = []
        var startedAt: Date?
        var completedAt: Date?
        for row in rows {
            switch row {
            case .runStarted(let ts, _):
                startedAt = ts
            case .runCompleted(let ts, _):
                completedAt = ts
            case .toolCall(_, let payload):
                if let call = decodeToolCall(payload) {
                    byStep[payload.step] = call
                }
            case .friction(_, let payload):
                let kind = FrictionKind(rawValue: payload.frictionKind) ?? .unexpectedState
                frictions.append(FrictionEvent(step: payload.step, kind: kind, detail: payload.detail))
            default:
                break
            }
        }
        let steps = byStep.keys.sorted().map { n in
            RunDetail.Step(id: n, n: n, toolCall: byStep[n])
        }
        let elapsed: Int = {
            guard let startedAt, let completedAt else { return 0 }
            return max(0, Int(completedAt.timeIntervalSince(startedAt)))
        }()
        return RunDetail(steps: steps, frictionEvents: frictions, elapsedSeconds: elapsed)
    }

    /// Best-effort decode of a `tool_call` row's inputJSON into a real
    /// `ToolCall`. Falls back to a synthetic `read_screen` call when the
    /// model emitted a tool we can't reconstruct (e.g. a newer agent
    /// schema). The detail view only renders the chip, so a coarse mapping
    /// is fine.
    nonisolated private static func decodeToolCall(_ payload: ToolCallPayload) -> ToolCall? {
        guard let kind = ToolKind(rawValue: payload.tool) else { return nil }
        let data = Data(payload.inputJSON.utf8)
        let dict = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let input: ToolInput
        switch kind {
        case .tap, .doubleTap:
            let x = (dict["x"] as? Int) ?? 0
            let y = (dict["y"] as? Int) ?? 0
            input = kind == .tap ? .tap(x: x, y: y) : .doubleTap(x: x, y: y)
        case .swipe:
            let x1 = (dict["x1"] as? Int) ?? 0
            let y1 = (dict["y1"] as? Int) ?? 0
            let x2 = (dict["x2"] as? Int) ?? 0
            let y2 = (dict["y2"] as? Int) ?? 0
            let ms = (dict["duration_ms"] as? Int) ?? 200
            input = .swipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: ms)
        case .type:
            input = .type(text: (dict["text"] as? String) ?? "")
        case .pressButton:
            let raw = (dict["button"] as? String) ?? "home"
            let button = SimulatorButton(rawValue: raw) ?? .home
            input = .pressButton(button: button)
        case .wait:
            input = .wait(ms: (dict["ms"] as? Int) ?? 0)
        case .readScreen:
            input = .readScreen
        case .noteFriction:
            let kindRaw = (dict["kind"] as? String) ?? FrictionKind.unexpectedState.rawValue
            let frictionKind = FrictionKind(rawValue: kindRaw) ?? .unexpectedState
            input = .noteFriction(kind: frictionKind, detail: (dict["detail"] as? String) ?? "")
        case .markGoalDone:
            let verdictRaw = (dict["verdict"] as? String) ?? Verdict.blocked.rawValue
            let verdict = Verdict(rawValue: verdictRaw) ?? .blocked
            input = .markGoalDone(
                verdict: verdict,
                summary: (dict["summary"] as? String) ?? "",
                frictionCount: (dict["friction_count"] as? Int) ?? 0,
                wouldRealUserSucceed: (dict["would_real_user_succeed"] as? Bool) ?? false
            )
        // Phase 2 — macOS extensions:
        case .rightClick:
            input = .rightClick(x: (dict["x"] as? Int) ?? 0, y: (dict["y"] as? Int) ?? 0)
        case .keyShortcut:
            input = .keyShortcut(keys: (dict["keys"] as? [String]) ?? [])
        case .scroll:
            input = .scroll(
                x: (dict["x"] as? Int) ?? 0,
                y: (dict["y"] as? Int) ?? 0,
                dx: (dict["dx"] as? Int) ?? 0,
                dy: (dict["dy"] as? Int) ?? 0
            )
        // Phase 3 — web extensions:
        case .navigate:
            input = .navigate(url: (dict["url"] as? String) ?? "")
        case .back: input = .back
        case .forward: input = .forward
        case .refresh: input = .refresh
        }
        return ToolCall(
            tool: kind,
            input: input,
            observation: payload.observation,
            intent: payload.intent
        )
    }

    /// Zip the run directory at `runID` to `destination`. Uses /usr/bin/zip
    /// because it's always present on macOS and produces a vanilla archive
    /// suitable for sharing repro bundles.
    func exportRun(_ run: RunRecordSnapshot, to destination: URL) async {
        exportError = nil
        let source = run.runDirectoryURL
        let process = Process()
        process.launchPath = "/usr/bin/zip"
        process.currentDirectoryURL = source.deletingLastPathComponent()
        process.arguments = ["-r", "-q", destination.path, source.lastPathComponent]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        defer { try? stderrPipe.fileHandleForReading.close() }
        do {
            try process.run()
            await Task.detached { process.waitUntilExit() }.value
            if process.terminationStatus != 0 {
                let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let message = String(data: data, encoding: .utf8) ?? "zip failed (\(process.terminationStatus))"
                exportError = message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }
}
