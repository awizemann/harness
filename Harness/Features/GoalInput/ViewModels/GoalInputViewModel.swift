//
//  GoalInputViewModel.swift
//  Harness
//
//  Drives the goal-input form. Project + scheme + destination probing is
//  delegated to a shared `ProjectPicker` (see
//  `Harness/Services/ProjectPicker.swift`) so this VM and the new
//  `ApplicationCreateViewModel` consume the exact same pipeline.
//
//  After the workspace rework: when an Application is selected,
//  `loadFromActiveApplication(_:)` populates the picker from the saved
//  Application and the form becomes a thin "type persona + goal" surface.
//

import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class GoalInputViewModel {

    // MARK: Form state — non-project

    var simulatorUDID: String = ""
    var personaText: String = ""
    var goalText: String = ""
    var mode: RunMode = .stepByStep
    var model: AgentModel = .opus47
    var stepBudget: Int = 40

    // MARK: Status

    var startError: String?

    // MARK: Project picker (shared helper)

    /// Owns project URL, schemes, destinations. Bind to `picker.*` from views.
    let picker: ProjectPicker

    // Convenience pass-throughs so existing call sites keep compiling.
    var projectURL: URL? { picker.projectURL }
    var projectDisplayName: String { picker.projectDisplayName }
    var availableSchemes: [String] { picker.availableSchemes }
    var selectedScheme: String {
        get { picker.selectedScheme }
        set { picker.selectedScheme = newValue }
    }
    var isResolvingSchemes: Bool { picker.isResolvingSchemes }
    var schemeError: String? { picker.schemeError }
    var schemeDestinations: [XcodeBuilder.Destination]? { picker.schemeDestinations }
    var isProbingDestinations: Bool { picker.isProbingDestinations }
    var schemeSupportsIOSSimulator: Bool { picker.schemeSupportsIOSSimulator }
    var schemeCompatibilitySummary: String? { picker.schemeCompatibilitySummary }

    var canStart: Bool {
        picker.projectURL != nil
            && !picker.selectedScheme.isEmpty
            && !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !simulatorUDID.isEmpty
            && picker.schemeSupportsIOSSimulator
    }

    // MARK: Init

    init(picker: ProjectPicker) {
        self.picker = picker
    }

    /// Convenience: build a fresh picker from raw services. Tests use the
    /// designated init above with a stub picker.
    convenience init(
        processRunner: any ProcessRunning,
        toolLocator: any ToolLocating,
        xcodeBuilder: any XcodeBuilding
    ) {
        self.init(picker: ProjectPicker(
            processRunner: processRunner,
            toolLocator: toolLocator,
            xcodeBuilder: xcodeBuilder
        ))
    }

    // MARK: Project picking — pass-through

    func pickProject() async {
        await picker.pickProject()
    }

    func load(projectURL: URL) async {
        await picker.load(projectURL: projectURL)
    }

    // MARK: Application hydration

    /// Pre-fill the form from an active `Application`. Doesn't re-probe
    /// schemes (they're saved on the Application); does probe destinations
    /// to refresh the iOS-simulator-compat banner.
    func loadFromActiveApplication(_ app: ApplicationSnapshot) async {
        picker.projectURL = app.projectURL
        picker.projectDisplayName = app.name
        picker.availableSchemes = [app.scheme]
        picker.selectedScheme = app.scheme
        if let udid = app.defaultSimulatorUDID, !udid.isEmpty {
            simulatorUDID = udid
        }
        if let m = app.defaultModel { model = m }
        if let m = app.defaultMode { mode = m }
        stepBudget = app.defaultStepBudget
        await picker.refreshSchemeDestinations()
    }

    // MARK: Build a GoalRequest

    func buildRequest(simulator: SimulatorRef) -> GoalRequest? {
        guard let projectURL = picker.projectURL else { return nil }
        return GoalRequest(
            id: UUID(),
            goal: goalText.trimmingCharacters(in: .whitespacesAndNewlines),
            persona: personaText.isEmpty
                ? "A curious first-time user who reads labels but doesn't have the manual."
                : personaText,
            project: ProjectRequest(
                path: projectURL,
                scheme: picker.selectedScheme,
                displayName: picker.projectDisplayName
            ),
            simulator: simulator,
            model: model,
            mode: mode,
            stepBudget: stepBudget,
            tokenBudget: model == .opus47 ? 250_000 : 1_000_000
        )
    }
}
