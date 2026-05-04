//
//  PersonasViewModel.swift
//  Harness
//
//  Drives the Personas library section. Loads `PersonaSnapshot`s from
//  `RunHistoryStoring`, owns the search/archive toggle UI state, and exposes
//  CRUD entry points for the views.
//
//  Mirrors the shape of `ApplicationsViewModel`. Built-in personas
//  (`isBuiltIn = true`) are read-only via UI, but `delete(id:)` is
//  defensive: it logs and no-ops on built-ins instead of throwing, since the
//  call shouldn't be reachable from the UI in the first place.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class PersonasViewModel {

    private static let logger = Logger(subsystem: "com.harness.app", category: "PersonasViewModel")

    // MARK: State

    var personas: [PersonaSnapshot] = []
    var isLoading: Bool = false
    var lastError: String?

    // MARK: Dependencies

    private let store: any RunHistoryStoring

    init(store: any RunHistoryStoring) {
        self.store = store
    }

    // MARK: Loading

    /// Reload the personas list. Default fetch excludes archived rows.
    func reload(includeArchived: Bool = true) async {
        // Always fetch the full set (built-ins + archived) so the toggle can
        // filter client-side without re-hitting the store.
        isLoading = true
        defer { isLoading = false }
        do {
            self.personas = try await store.personas(includeArchived: includeArchived)
            self.lastError = nil
        } catch {
            Self.logger.error("personas load failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    // MARK: CRUD

    /// Create a new editable persona. Returns the persisted snapshot so the
    /// caller can select it in the list.
    @discardableResult
    func create(name: String, blurb: String, promptText: String) async throws -> PersonaSnapshot {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else {
            throw PersonasError.validation("Name and prompt are required.")
        }
        let snapshot = PersonaSnapshot(
            id: UUID(),
            name: trimmedName,
            blurb: blurb.trimmingCharacters(in: .whitespacesAndNewlines),
            promptText: trimmedPrompt,
            isBuiltIn: false,
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil
        )
        try await store.upsert(snapshot)
        await reload()
        return snapshot
    }

    /// Clone any persona (typically a built-in) into a new editable copy.
    /// The new persona always has `isBuiltIn = false`, a fresh UUID, and a
    /// `"<name> (copy)"` suffix on the original name.
    @discardableResult
    func duplicate(_ source: PersonaSnapshot) async throws -> PersonaSnapshot {
        let copy = PersonaSnapshot(
            id: UUID(),
            name: "\(source.name) (copy)",
            blurb: source.blurb,
            promptText: source.promptText,
            isBuiltIn: false,
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil
        )
        try await store.upsert(copy)
        await reload()
        return copy
    }

    /// Persist edits to an existing persona. Built-ins are guarded server-
    /// side: an attempt to mutate one fails with `validation`. The view-layer
    /// shouldn't enable the Save path on built-ins, but this is the durable
    /// invariant.
    func update(_ snapshot: PersonaSnapshot) async throws {
        guard !snapshot.isBuiltIn else {
            throw PersonasError.validation("Built-in personas can't be edited. Duplicate to make changes.")
        }
        let trimmedName = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = snapshot.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else {
            throw PersonasError.validation("Name and prompt are required.")
        }
        let normalized = PersonaSnapshot(
            id: snapshot.id,
            name: trimmedName,
            blurb: snapshot.blurb.trimmingCharacters(in: .whitespacesAndNewlines),
            promptText: trimmedPrompt,
            isBuiltIn: false,
            createdAt: snapshot.createdAt,
            lastUsedAt: Date(),
            archivedAt: snapshot.archivedAt
        )
        try await store.upsert(normalized)
        await reload()
    }

    /// Archive a persona. Allowed for both built-ins and custom personas —
    /// archive is non-destructive and can be undone via "Show archived" +
    /// unarchive. Hidden behind UI gating until needed.
    func archive(id: UUID) async {
        do {
            try await store.archive(personaID: id)
            await reload()
        } catch {
            Self.logger.error("archive failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    /// Hard-delete a persona. **No-op for built-ins** — the UI should never
    /// expose this path on a built-in row, but if it does (or a future
    /// caller invokes it directly), we log and bail rather than wipe a
    /// seeded entry. Custom personas are deleted; bound RunRecord refs
    /// nullify per the store's delete-rule.
    func delete(id: UUID) async {
        do {
            // Defensive guard: re-fetch and verify built-in flag.
            if let existing = try await store.persona(id: id), existing.isBuiltIn {
                Self.logger.warning("delete(id:) called on built-in persona \(existing.name, privacy: .public) — ignoring")
                return
            }
            try await store.deletePersona(id: id)
            await reload()
        } catch {
            Self.logger.error("delete failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Filtering

    /// Substring filter against name/blurb/promptText. Empty needle = pass
    /// all. The `includeArchived` flag drives whether archived rows render.
    func filtered(search: String, includeArchived: Bool) -> [PersonaSnapshot] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = includeArchived ? personas : personas.filter { !$0.archived }
        guard !needle.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.lowercased().contains(needle)
                || $0.blurb.lowercased().contains(needle)
                || $0.promptText.lowercased().contains(needle)
        }
    }
}

// MARK: - Errors

enum PersonasError: Error, LocalizedError, Sendable {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let m): return m
        }
    }
}
