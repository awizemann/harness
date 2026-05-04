//
//  FrictionReportViewModel.swift
//  Harness
//
//  Drives `FrictionReportView`. Picks a run (caller-supplied id, fall back
//  to the most recent finished run) and builds a flat list of friction
//  cards joined to their per-step screenshot + agent observation.
//

import Foundation
import Observation

@Observable
@MainActor
final class FrictionReportViewModel {

    // MARK: Public state

    var runID: UUID?
    var runMeta: RunStartedPayload?
    var entries: [FrictionReportEntry] = []
    var kindCounts: [(kind: FrictionKind, count: Int)] = []
    var filter: FrictionKindFilter = .all
    var isLoading: Bool = false
    var loadError: String?
    /// Display label for the breadcrumb in the report toolbar
    /// (`run #ab12 · ListApp`). Empty when no run is loaded.
    var runDisplayLabel: String = ""

    // MARK: Dependencies

    private let store: any RunHistoryStoring

    init(store: any RunHistoryStoring) {
        self.store = store
    }

    // MARK: Loading

    /// Load the requested run, or fall back to the most recent run when
    /// `runID` is nil. Sets `loadError` and clears entries on failure.
    func load(preferredRunID: UUID?) async {
        loadError = nil
        isLoading = true
        defer { isLoading = false }

        // Resolve the run.
        let resolvedID: UUID?
        let runRecord: RunRecordSnapshot?
        if let preferredRunID {
            resolvedID = preferredRunID
            runRecord = (try? await store.fetch(id: preferredRunID))
        } else {
            let recent = (try? await store.fetchRecent(limit: 1)) ?? []
            runRecord = recent.first
            resolvedID = recent.first?.id
        }
        guard let id = resolvedID, let record = runRecord else {
            self.runID = nil
            self.runMeta = nil
            self.entries = []
            self.kindCounts = []
            self.runDisplayLabel = ""
            return
        }
        self.runID = id
        self.runDisplayLabel = "run #\(id.uuidString.prefix(4)) · \(record.displayName)"

        let parsed: ParsedFriction = await Task.detached(priority: .userInitiated) {
            Self.decode(runID: id)
        }.value

        if let err = parsed.error {
            loadError = err
            entries = []
            kindCounts = []
            runMeta = nil
            return
        }
        runMeta = parsed.meta
        entries = parsed.entries
        kindCounts = Self.tally(parsed.entries)
    }

    var filteredEntries: [FrictionReportEntry] {
        entries.filter { filter.matches($0.kind) }
    }

    /// Total in-run count regardless of filter — drives the summary badge
    /// and the sidebar badge.
    var totalFriction: Int { entries.count }

    // MARK: Decoding

    private struct ParsedFriction: Sendable {
        let meta: RunStartedPayload?
        let entries: [FrictionReportEntry]
        let error: String?
    }

    nonisolated private static func decode(runID: UUID) -> ParsedFriction {
        let rows: [DecodedRow]
        do {
            rows = try RunLogParser.parse(runID: runID)
        } catch {
            return ParsedFriction(meta: nil, entries: [], error: error.localizedDescription)
        }

        var meta: RunStartedPayload?
        var runStartTs: Date?
        var stepStartTs: [Int: Date] = [:]
        var stepObservation: [Int: String] = [:]
        var frictions: [(ts: Date, payload: FrictionPayload)] = []

        for row in rows {
            switch row {
            case .runStarted(let ts, let payload):
                meta = payload
                runStartTs = ts
            case .stepStarted(let ts, let payload):
                stepStartTs[payload.step] = ts
            case .toolCall(_, let payload):
                if !payload.observation.isEmpty {
                    stepObservation[payload.step] = payload.observation
                }
            case .friction(let ts, let payload):
                frictions.append((ts, payload))
            default:
                break
            }
        }

        let baseTs = runStartTs ?? frictions.first?.ts ?? Date()
        let entries: [FrictionReportEntry] = frictions.enumerated().map { idx, item in
            let kind = FrictionKind(rawValue: item.payload.frictionKind) ?? .unexpectedState
            let stepTs = stepStartTs[item.payload.step] ?? item.ts
            let elapsed = max(0, Int(stepTs.timeIntervalSince(baseTs)))
            let label = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
            return FrictionReportEntry(
                id: idx,
                step: item.payload.step,
                kind: kind,
                detail: item.payload.detail,
                agentObservation: stepObservation[item.payload.step] ?? "",
                timestampLabel: label,
                screenshotURL: HarnessPaths.screenshot(for: runID, step: item.payload.step)
            )
        }
        return ParsedFriction(meta: meta, entries: entries, error: nil)
    }

    nonisolated private static func tally(_ entries: [FrictionReportEntry]) -> [(kind: FrictionKind, count: Int)] {
        var bucket: [FrictionKind: Int] = [:]
        for entry in entries {
            bucket[entry.kind, default: 0] += 1
        }
        // Stable order: display in the canonical taxonomy order so the chip
        // row reads consistently across runs.
        let order: [FrictionKind] = [
            .deadEnd, .ambiguousLabel, .unresponsive,
            .confusingCopy, .unexpectedState, .agentBlocked
        ]
        return order.compactMap { kind in
            guard let count = bucket[kind] else { return nil }
            return (kind, count)
        }
    }
}
