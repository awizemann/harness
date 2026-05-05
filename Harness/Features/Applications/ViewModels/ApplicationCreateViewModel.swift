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
    /// Phase 2: which platform the user is creating an app for. iOS today,
    /// macOS in Phase 2, web in Phase 3. The form re-shapes (Simulator
    /// section vs Mac-bundle section) based on this.
    var platformKind: PlatformKind = .iosSimulator
    var simulatorUDID: String?
    /// Phase 2 — macOS pre-built `.app` path. When set, the run launches
    /// this bundle via NSWorkspace and skips xcodebuild entirely. When
    /// nil, the form expects a normal Project + scheme (xcodebuild
    /// macOS build).
    var macAppBundlePath: String?
    var defaultModel: AgentModel = .opus47
    var defaultMode: RunMode = .stepByStep
    var defaultStepBudget: Int = 40

    var saveError: String?

    // MARK: Picker (shared)

    let picker: ProjectPicker

    // MARK: Validation

    var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch platformKind {
        case .iosSimulator:
            return picker.projectURL != nil
                && !picker.selectedScheme.isEmpty
                && (simulatorUDID?.isEmpty == false)
                && picker.schemeSupportsIOSSimulator
        case .macosApp:
            // Either pre-built .app path OR project + scheme.
            if let path = macAppBundlePath, !path.isEmpty { return true }
            return picker.projectURL != nil && !picker.selectedScheme.isEmpty
        case .web:
            // Phase 3 lights this up.
            return false
        }
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
        guard canSave else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        switch platformKind {
        case .iosSimulator:
            guard let projectURL = picker.projectURL,
                  let udid = simulatorUDID else { return nil }
            let sim = simulators.first(where: { $0.udid == udid })
            return ApplicationSnapshot(
                id: UUID(),
                name: trimmedName,
                createdAt: Date(),
                lastUsedAt: Date(),
                archivedAt: nil,
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

        case .macosApp:
            // Two valid configs: pre-built .app path OR project + scheme.
            // Mirror both into the snapshot so RunCoordinator's adapter
            // can choose the right launch path.
            let projectURL = picker.projectURL
            return ApplicationSnapshot(
                id: UUID(),
                name: trimmedName,
                createdAt: Date(),
                lastUsedAt: Date(),
                archivedAt: nil,
                platformKindRaw: PlatformKind.macosApp.rawValue,
                projectPath: projectURL?.path ?? "",
                projectBookmark: nil,
                scheme: picker.selectedScheme,
                defaultSimulatorUDID: nil,
                defaultSimulatorName: nil,
                defaultSimulatorRuntime: nil,
                macAppBundlePath: macAppBundlePath,
                macAppBundleBookmark: nil,
                defaultModelRaw: defaultModel.rawValue,
                defaultModeRaw: defaultMode.rawValue,
                defaultStepBudget: defaultStepBudget
            )

        case .web:
            return nil
        }
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
