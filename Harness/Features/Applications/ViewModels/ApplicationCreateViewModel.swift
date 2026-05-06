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

/// Where a macOS Application's launch artefact comes from. The user
/// picks one of these in the create form's "Launch source" segment;
/// the snapshot preserves only the chosen branch's fields and clears
/// the other so the runtime adapter sees a single, unambiguous launch
/// path. Pre-built bundles are the default — most macOS targets are
/// apps the user already has built somewhere.
enum MacLaunchSource: String, CaseIterable, Hashable, Sendable {
    /// Launch a pre-built `.app` directly via NSWorkspace. No build step.
    case prebuiltBundle
    /// Build the app with `xcodebuild` from a project + scheme, then
    /// launch the resulting `.app`.
    case xcodeProject

    var label: String {
        switch self {
        case .prebuiltBundle: "Pre-built .app"
        case .xcodeProject:   "Xcode project"
        }
    }
}

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
    /// Which macOS launch source the user is configuring. Only meaningful
    /// when `platformKind == .macosApp`. Defaults to `.prebuiltBundle` —
    /// the create form's segment is bound to this and re-shapes its
    /// sub-form when flipped.
    var macLaunchSource: MacLaunchSource = .prebuiltBundle
    /// macOS pre-built `.app` path. Only stored when
    /// `macLaunchSource == .prebuiltBundle`; cleared otherwise.
    var macAppBundlePath: String?
    /// Phase 3 — web form fields.
    var webStartURL: String = ""
    var webViewportWidth: Int = 1280
    var webViewportHeight: Int = 800
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
            // The launch-source segment is the discriminator — exactly
            // one branch's fields need to be valid, never both.
            switch macLaunchSource {
            case .prebuiltBundle:
                return !(macAppBundlePath ?? "").isEmpty
            case .xcodeProject:
                guard picker.projectURL != nil,
                      !picker.selectedScheme.isEmpty else { return false }
                // Block save when the chosen scheme has no macOS destination —
                // xcodebuild would refuse the build at run time anyway. The
                // banner (in the view) communicates this; canSave enforces it.
                if let dests = picker.schemeDestinations,
                   !dests.contains(where: { $0.supportsMacOS }) {
                    return false
                }
                return true
            }
        case .web:
            // Phase 3 — only require a non-empty URL that parses.
            let trimmed = webStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && URL(string: trimmed) != nil
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
            // Persist exactly one launch path. The other branch's fields
            // are cleared so MacOSPlatformAdapter sees an unambiguous
            // signal at run time (and so the detail/edit view can't
            // accidentally surface stale data from the unchosen mode).
            switch macLaunchSource {
            case .prebuiltBundle:
                guard let path = macAppBundlePath, !path.isEmpty else { return nil }
                return ApplicationSnapshot(
                    id: UUID(),
                    name: trimmedName,
                    createdAt: Date(),
                    lastUsedAt: Date(),
                    archivedAt: nil,
                    platformKindRaw: PlatformKind.macosApp.rawValue,
                    projectPath: "",
                    projectBookmark: nil,
                    scheme: "",
                    defaultSimulatorUDID: nil,
                    defaultSimulatorName: nil,
                    defaultSimulatorRuntime: nil,
                    macAppBundlePath: path,
                    macAppBundleBookmark: nil,
                    defaultModelRaw: defaultModel.rawValue,
                    defaultModeRaw: defaultMode.rawValue,
                    defaultStepBudget: defaultStepBudget
                )
            case .xcodeProject:
                guard let projectURL = picker.projectURL,
                      !picker.selectedScheme.isEmpty else { return nil }
                return ApplicationSnapshot(
                    id: UUID(),
                    name: trimmedName,
                    createdAt: Date(),
                    lastUsedAt: Date(),
                    archivedAt: nil,
                    platformKindRaw: PlatformKind.macosApp.rawValue,
                    projectPath: projectURL.path,
                    projectBookmark: nil,
                    scheme: picker.selectedScheme,
                    defaultSimulatorUDID: nil,
                    defaultSimulatorName: nil,
                    defaultSimulatorRuntime: nil,
                    macAppBundlePath: nil,
                    macAppBundleBookmark: nil,
                    defaultModelRaw: defaultModel.rawValue,
                    defaultModeRaw: defaultMode.rawValue,
                    defaultStepBudget: defaultStepBudget
                )
            }

        case .web:
            let trimmed = webStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return ApplicationSnapshot(
                id: UUID(),
                name: trimmedName,
                createdAt: Date(),
                lastUsedAt: Date(),
                archivedAt: nil,
                platformKindRaw: PlatformKind.web.rawValue,
                projectPath: "",
                projectBookmark: nil,
                scheme: "",
                defaultSimulatorUDID: nil,
                defaultSimulatorName: nil,
                defaultSimulatorRuntime: nil,
                webStartURL: trimmed,
                webViewportWidthPt: webViewportWidth,
                webViewportHeightPt: webViewportHeight,
                defaultModelRaw: defaultModel.rawValue,
                defaultModeRaw: defaultMode.rawValue,
                defaultStepBudget: defaultStepBudget
            )
        }
    }

    /// Reset to default form state for a fresh sheet open.
    func reset() {
        name = ""
        simulatorUDID = nil
        macLaunchSource = .prebuiltBundle
        macAppBundlePath = nil
        webStartURL = ""
        webViewportWidth = 1280
        webViewportHeight = 800
        defaultModel = .opus47
        defaultMode = .stepByStep
        defaultStepBudget = 40
        saveError = nil
        picker.reset()
    }
}
