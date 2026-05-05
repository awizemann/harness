//
//  ApplicationCreateViewModel.swift
//  Harness
//
//  Form-state for the Application creation sheet. Wraps a shared
//  `ProjectPicker` (project URL + scheme + destination probe) so the create
//  sheet and the goal-input view stay in sync. The sheet collects:
//
//   • Application name (defaults to project file's basename)
//   • Project URL + scheme (via picker)
//   • Default simulator (from `AppState.simulators`)
//   • Default run options (model / mode / step budget)
//
//  Persists via `ApplicationsViewModel.save(_:)` once `canSave` is true.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class ApplicationCreateViewModel {

    // MARK: Form state

    var name: String = ""
    var simulatorUDID: String?
    var defaultModel: AgentModel = .opus47
    var defaultMode: RunMode = .stepByStep
    var defaultStepBudget: Int = 40

    var saveError: String?

    // MARK: Picker (shared)

    let picker: ProjectPicker

    // MARK: Validation

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && picker.projectURL != nil
            && !picker.selectedScheme.isEmpty
            && (simulatorUDID?.isEmpty == false)
            && picker.schemeSupportsIOSSimulator
    }

    // MARK: Init

    init(picker: ProjectPicker) {
        self.picker = picker
    }

    /// Pre-fill the simulator + run defaults from `AppState`. Call this when
    /// the sheet opens so the user starts from sensible defaults.
    func seedFromAppState(_ state: AppState) {
        if simulatorUDID == nil {
            simulatorUDID = state.defaultSimulatorUDID
                ?? state.simulators.first?.udid
        }
        if defaultStepBudget == 40 { defaultStepBudget = state.defaultStepBudget }
        defaultModel = state.defaultModel
        defaultMode = state.defaultMode
    }

    /// Pre-fill the name from the project's file basename when the user
    /// picks a project. Lets the user override the auto-name in the field.
    func adoptProjectName() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = picker.projectDisplayName
        }
    }

    // MARK: Build snapshot

    /// Compose the final `ApplicationSnapshot`. Returns nil if validation
    /// fails. Looks up the picked simulator's display fields off `AppState`
    /// so the snapshot carries everything `ApplicationDetailView` needs to
    /// render without re-querying.
    func makeSnapshot(simulators: [SimulatorRef]) -> ApplicationSnapshot? {
        guard canSave,
              let projectURL = picker.projectURL,
              let udid = simulatorUDID else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sim = simulators.first(where: { $0.udid == udid })
        return ApplicationSnapshot(
            id: UUID(),
            name: trimmedName,
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil,
            // Phase 1 ships iOS as the only selectable platform; the
            // create form's segment is locked to iOS until Phase 2/3 land.
            platformKindRaw: PlatformKind.iosSimulator.rawValue,
            projectPath: projectURL.path,
            projectBookmark: nil,
            scheme: picker.selectedScheme,
            defaultSimulatorUDID: udid,
            defaultSimulatorName: sim?.name,
            defaultSimulatorRuntime: sim?.runtime,
            defaultModelRaw: defaultModel.rawValue,
            defaultModeRaw: defaultMode.rawValue,
            defaultStepBudget: defaultStepBudget
        )
    }

    /// Reset to default form state for a fresh sheet open.
    func reset() {
        name = ""
        simulatorUDID = nil
        defaultModel = .opus47
        defaultMode = .stepByStep
        defaultStepBudget = 40
        saveError = nil
        picker.reset()
    }
}
