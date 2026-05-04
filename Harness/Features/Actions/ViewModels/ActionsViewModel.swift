//
//  ActionsViewModel.swift
//  Harness
//
//  Drives the Actions library section. Owns two collections — `actions`
//  and `chains` — sourced from `RunHistoryStoring`. Mirrors the shape of
//  `PersonasViewModel` so the library tabs stay consistent.
//
//  Phase D additions:
//  - `chainsReferencing(actionID:)` — used by `ActionDetailView`'s
//    "Used in N chains" header chip.
//  - `brokenStepCount(in:)` — used by `ChainDetailView` to render a
//    `FrictionTag(kind: .deadEnd)` row per step whose referenced Action
//    no longer exists. The store nullifies `ActionChainStep.action` on
//    Action delete (Phase A invariant); this VM just surfaces it.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class ActionsViewModel {

    private static let logger = Logger(subsystem: "com.harness.app", category: "ActionsViewModel")

    // MARK: State

    var actions: [ActionSnapshot] = []
    var chains: [ActionChainSnapshot] = []
    var isLoading: Bool = false
    var lastError: String?

    // MARK: Dependencies

    private let store: any RunHistoryStoring

    init(store: any RunHistoryStoring) {
        self.store = store
    }

    // MARK: Loading

    /// Reload both collections in one shot. Always pulls archived rows so the
    /// "Show archived" toggle is a client-side filter rather than a refetch.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let actionsTask = store.actions(includeArchived: true)
            async let chainsTask = store.actionChains(includeArchived: true)
            let (loadedActions, loadedChains) = try await (actionsTask, chainsTask)
            self.actions = loadedActions
            self.chains = loadedChains
            self.lastError = nil
        } catch {
            Self.logger.error("actions/chains load failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Actions CRUD

    @discardableResult
    func createAction(
        name: String,
        promptText: String,
        notes: String
    ) async throws -> ActionSnapshot {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else {
            throw ActionsError.validation("Name and prompt are required.")
        }
        let snapshot = ActionSnapshot(
            id: UUID(),
            name: trimmedName,
            promptText: trimmedPrompt,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil
        )
        try await store.upsert(snapshot)
        await reload()
        return snapshot
    }

    func updateAction(_ snapshot: ActionSnapshot) async throws {
        let trimmedName = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = snapshot.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else {
            throw ActionsError.validation("Name and prompt are required.")
        }
        let normalized = ActionSnapshot(
            id: snapshot.id,
            name: trimmedName,
            promptText: trimmedPrompt,
            notes: snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: snapshot.createdAt,
            lastUsedAt: Date(),
            archivedAt: snapshot.archivedAt
        )
        try await store.upsert(normalized)
        await reload()
    }

    func archiveAction(id: UUID) async {
        do {
            try await store.archive(actionID: id)
            await reload()
        } catch {
            Self.logger.error("archive action failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    func deleteAction(id: UUID) async {
        do {
            try await store.deleteAction(id: id)
            await reload()
        } catch {
            Self.logger.error("delete action failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Chains CRUD

    @discardableResult
    func createChain(
        name: String,
        notes: String,
        steps: [ActionChainStepSnapshot]
    ) async throws -> ActionChainSnapshot {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ActionsError.validation("Name is required.")
        }
        let normalizedSteps = Self.renumber(steps)
        let snapshot = ActionChainSnapshot(
            id: UUID(),
            name: trimmedName,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil,
            steps: normalizedSteps
        )
        try await store.upsert(snapshot)
        await reload()
        return snapshot
    }

    func updateChain(_ snapshot: ActionChainSnapshot) async throws {
        let trimmedName = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ActionsError.validation("Name is required.")
        }
        let normalized = ActionChainSnapshot(
            id: snapshot.id,
            name: trimmedName,
            notes: snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: snapshot.createdAt,
            lastUsedAt: Date(),
            archivedAt: snapshot.archivedAt,
            steps: Self.renumber(snapshot.steps)
        )
        try await store.upsert(normalized)
        await reload()
    }

    func archiveChain(id: UUID) async {
        do {
            try await store.archive(actionChainID: id)
            await reload()
        } catch {
            Self.logger.error("archive chain failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    func deleteChain(id: UUID) async {
        do {
            try await store.deleteActionChain(id: id)
            await reload()
        } catch {
            Self.logger.error("delete chain failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Filters / lookups

    func filteredActions(search: String, includeArchived: Bool) -> [ActionSnapshot] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = includeArchived ? actions : actions.filter { !$0.archived }
        guard !needle.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.lowercased().contains(needle)
                || $0.promptText.lowercased().contains(needle)
                || $0.notes.lowercased().contains(needle)
        }
    }

    func filteredChains(search: String, includeArchived: Bool) -> [ActionChainSnapshot] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = includeArchived ? chains : chains.filter { !$0.archived }
        guard !needle.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.lowercased().contains(needle)
                || $0.notes.lowercased().contains(needle)
        }
    }

    // MARK: Cross-references

    /// Every chain that references this Action via at least one step (any
    /// archive state). Drives the "Used in N chains" header chip on
    /// `ActionDetailView` and the deletion confirmation message.
    func chainsReferencing(actionID: UUID) -> [ActionChainSnapshot] {
        chains.filter { chain in
            chain.steps.contains(where: { $0.actionID == actionID })
        }
    }

    /// Number of steps whose `actionID` is non-nil but doesn't resolve to a
    /// non-archived Action in the current `actions` list. A step with
    /// `actionID == nil` is treated as "blank" rather than "broken" — the
    /// user just hasn't filled it in yet, which is a different UX state.
    func brokenStepCount(in chain: ActionChainSnapshot) -> Int {
        let liveActionIDs = Set(actions.filter { !$0.archived }.map(\.id))
        return chain.steps.reduce(into: 0) { acc, step in
            if let id = step.actionID, !liveActionIDs.contains(id) {
                acc += 1
            }
        }
    }

    // MARK: Helpers

    /// Re-stamp `index` on each step in array order so callers don't have to
    /// remember to renumber after a reorder/insert/delete.
    private static func renumber(_ steps: [ActionChainStepSnapshot]) -> [ActionChainStepSnapshot] {
        steps.enumerated().map { idx, step in
            ActionChainStepSnapshot(
                id: step.id,
                index: idx,
                actionID: step.actionID,
                preservesState: step.preservesState
            )
        }
    }
}

// MARK: - Errors

enum ActionsError: Error, LocalizedError, Sendable {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let m): return m
        }
    }
}
