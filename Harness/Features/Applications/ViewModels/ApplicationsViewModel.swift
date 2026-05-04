//
//  ApplicationsViewModel.swift
//  Harness
//
//  Drives the Applications library section. Loads the saved
//  `ApplicationSnapshot`s from `RunHistoryStoring`, owns search, and exposes
//  CRUD entry points for the views. Runs of an Application's "Recent runs"
//  panel are loaded lazily on demand.
//
//  Per `standards/01-architecture.md`, view-models are `@MainActor
//  @Observable`. Disk I/O happens via the actor; views only ever see Sendable
//  snapshot values.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class ApplicationsViewModel {

    private static let logger = Logger(subsystem: "com.harness.app", category: "ApplicationsViewModel")

    // MARK: State

    var applications: [ApplicationSnapshot] = []
    var isLoading: Bool = false
    var loadError: String?

    /// Up-to-10 most-recent runs for the application currently selected in
    /// the detail pane. Fetched lazily by `loadRecentRuns(for:)`.
    var recentRunsByApplication: [UUID: [RunRecordSnapshot]] = [:]

    // MARK: Dependencies

    private let store: any RunHistoryStoring
    private let coordinator: AppCoordinator
    private let appState: AppState

    init(
        store: any RunHistoryStoring,
        coordinator: AppCoordinator,
        appState: AppState
    ) {
        self.store = store
        self.coordinator = coordinator
        self.appState = appState
    }

    // MARK: Loading

    /// Reload the applications list. Call from `.task { ... }`.
    func reload(includeArchived: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            self.applications = try await store.applications(includeArchived: includeArchived)
            self.loadError = nil
        } catch {
            Self.logger.error("applications load failed: \(error.localizedDescription, privacy: .public)")
            self.loadError = error.localizedDescription
        }
    }

    /// Fetch the up-to-10 most recent runs for one Application. Cached on
    /// `recentRunsByApplication`. Defaults to 10.
    func loadRecentRuns(for applicationID: UUID, limit: Int = 10) async {
        do {
            // Pull a generous slice (history is small) and filter client-side.
            let all = try await store.fetchRecent(limit: 200)
            let filtered = all.filter { $0.applicationID == applicationID }
            self.recentRunsByApplication[applicationID] = Array(filtered.prefix(limit))
        } catch {
            Self.logger.warning("recent runs load failed for \(applicationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.recentRunsByApplication[applicationID] = []
        }
    }

    // MARK: CRUD

    /// Persist a new or updated Application. The caller hands us a complete
    /// `ApplicationSnapshot` — typically built by `ApplicationCreateViewModel`.
    @discardableResult
    func save(_ snapshot: ApplicationSnapshot) async -> Bool {
        do {
            try await store.upsert(snapshot)
            await reload()
            return true
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
            self.loadError = error.localizedDescription
            return false
        }
    }

    /// Update just the name of an existing Application. Re-fetches first to
    /// pick up any other changes from a concurrent edit.
    @discardableResult
    func rename(_ applicationID: UUID, to newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            guard var current = try await store.application(id: applicationID) else { return false }
            current = ApplicationSnapshot(
                id: current.id,
                name: trimmed,
                createdAt: current.createdAt,
                lastUsedAt: current.lastUsedAt,
                archivedAt: current.archivedAt,
                projectPath: current.projectPath,
                projectBookmark: current.projectBookmark,
                scheme: current.scheme,
                defaultSimulatorUDID: current.defaultSimulatorUDID,
                defaultSimulatorName: current.defaultSimulatorName,
                defaultSimulatorRuntime: current.defaultSimulatorRuntime,
                defaultModelRaw: current.defaultModelRaw,
                defaultModeRaw: current.defaultModeRaw,
                defaultStepBudget: current.defaultStepBudget
            )
            try await store.upsert(current)
            await reload()
            return true
        } catch {
            Self.logger.error("rename failed: \(error.localizedDescription, privacy: .public)")
            self.loadError = error.localizedDescription
            return false
        }
    }

    func archive(_ applicationID: UUID) async {
        do {
            try await store.archive(applicationID: applicationID)
            // Archiving the active app: clear the scope.
            if coordinator.selectedApplicationID == applicationID {
                coordinator.selectedApplicationID = nil
                appState.selectedApplicationID = nil
                await appState.persistSettings()
            }
            await reload()
        } catch {
            Self.logger.error("archive failed: \(error.localizedDescription, privacy: .public)")
            self.loadError = error.localizedDescription
        }
    }

    func delete(_ applicationID: UUID) async {
        do {
            try await store.deleteApplication(id: applicationID)
            if coordinator.selectedApplicationID == applicationID {
                coordinator.selectedApplicationID = nil
                appState.selectedApplicationID = nil
                await appState.persistSettings()
            }
            recentRunsByApplication[applicationID] = nil
            await reload()
        } catch {
            Self.logger.error("delete failed: \(error.localizedDescription, privacy: .public)")
            self.loadError = error.localizedDescription
        }
    }

    /// Set this Application as the active workspace scope.
    func setActive(_ applicationID: UUID) async {
        coordinator.selectedApplicationID = applicationID
        appState.selectedApplicationID = applicationID
        await appState.persistSettings()
    }

    // MARK: Search helpers

    /// Substring filter against the Application name. Empty needle = pass all.
    func filtered(search: String) -> [ApplicationSnapshot] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return applications }
        return applications.filter {
            $0.name.lowercased().contains(needle)
                || $0.scheme.lowercased().contains(needle)
                || $0.projectPath.lowercased().contains(needle)
        }
    }
}
