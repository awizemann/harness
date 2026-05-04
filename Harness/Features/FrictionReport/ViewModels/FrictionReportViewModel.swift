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

    /// One leg of a chain run, in display order. Single-leg runs (or
    /// pre-Phase-E v1 logs) collapse to one section; the view hides
    /// section headers in that case so the report layout is unchanged.
    struct LegSection: Sendable, Hashable, Identifiable {
        let id: Int           // matches leg index
        let index: Int
        let title: String     // "Leg N · <actionName>" or "Leg N" when no name
        let stepStart: Int?
        let stepEnd: Int?
    }
    /// Sorted by leg index. Empty when no run is loaded.
    var legSections: [LegSection] = []

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
            legSections = []
            return
        }
        runMeta = parsed.meta
        entries = parsed.entries
        kindCounts = Self.tally(parsed.entries)
        legSections = parsed.legSections
    }

    var filteredEntries: [FrictionReportEntry] {
        entries.filter { filter.matches($0.kind) }
    }

    /// Total in-run count regardless of filter — drives the summary badge
    /// and the sidebar badge.
    var totalFriction: Int { entries.count }

    /// Filtered entries grouped by their owning leg. Returns one
    /// `(section, entries)` tuple per leg in display order. For
    /// single-leg runs (and v1 logs), there's exactly one tuple and
    /// the section's title is empty — the view treats that as "skip
    /// the section header" so the layout stays unchanged.
    func filteredEntriesByLeg() -> [(section: LegSection, entries: [FrictionReportEntry])] {
        let pool = filteredEntries
        guard legSections.count > 1 else {
            // Single-leg / v1 — just one bucket, no header.
            let title = legSections.first?.title ?? ""
            let placeholder = LegSection(
                id: legSections.first?.id ?? 0,
                index: legSections.first?.index ?? 0,
                title: title,
                stepStart: nil,
                stepEnd: nil
            )
            return [(placeholder, pool)]
        }
        // Bucket entries by which leg's step range owns them. Falls
        // back to the last leg for entries beyond all known step
        // ranges (defensive — should never happen on a well-formed
        // log).
        var buckets: [Int: [FrictionReportEntry]] = [:]
        for entry in pool {
            let leg = legSections.last(where: { ($0.stepStart ?? Int.max) <= entry.step }) ?? legSections[0]
            buckets[leg.index, default: []].append(entry)
        }
        return legSections.map { section in
            (section, (buckets[section.index] ?? []).sorted(by: { $0.step < $1.step }))
        }
    }

    // MARK: Decoding

    private struct ParsedFriction: Sendable {
        let meta: RunStartedPayload?
        let entries: [FrictionReportEntry]
        let legSections: [LegSection]
        let error: String?
    }

    nonisolated private static func decode(runID: UUID) -> ParsedFriction {
        let rows: [DecodedRow]
        do {
            rows = try RunLogParser.parse(runID: runID)
        } catch {
            return ParsedFriction(meta: nil, entries: [], legSections: [], error: error.localizedDescription)
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
        let parsedLegs = RunLogParser.legViews(from: rows)
        let sections: [LegSection] = parsedLegs.map { leg in
            let title: String
            if leg.actionName.isEmpty {
                title = "Leg \(leg.index + 1)"
            } else {
                title = "Leg \(leg.index + 1) · \(leg.actionName)"
            }
            return LegSection(
                id: leg.index,
                index: leg.index,
                title: title,
                stepStart: leg.stepStart,
                stepEnd: leg.stepEnd
            )
        }
        return ParsedFriction(meta: meta, entries: entries, legSections: sections, error: nil)
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
