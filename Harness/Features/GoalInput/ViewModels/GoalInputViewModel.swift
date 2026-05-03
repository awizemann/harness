//
//  GoalInputViewModel.swift
//  Harness
//
//  Drives the goal-input form. Resolves the project's available schemes via
//  `xcodebuild -list -json` (best effort — falls through to a free-form
//  text field if the parse fails).
//

import Foundation
import Observation
import SwiftUI
import os

@Observable
@MainActor
final class GoalInputViewModel {

    private static let logger = Logger(subsystem: "com.harness.app", category: "GoalInputViewModel")

    // MARK: Form state

    var projectURL: URL?
    var projectDisplayName: String = ""
    var availableSchemes: [String] = []
    var selectedScheme: String = ""

    var simulatorUDID: String = ""
    var personaText: String = ""
    var goalText: String = ""
    var mode: RunMode = .stepByStep
    var model: AgentModel = .opus47
    var stepBudget: Int = 40

    // MARK: Status

    var isResolvingSchemes: Bool = false
    var schemeError: String?
    var startError: String?
    var canStart: Bool {
        projectURL != nil
            && !selectedScheme.isEmpty
            && !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !simulatorUDID.isEmpty
    }

    // MARK: Dependencies

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating

    init(processRunner: any ProcessRunning, toolLocator: any ToolLocating) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
    }

    // MARK: Project picker

    /// Open an `NSOpenPanel` for the user to pick a `.xcodeproj` or `.xcworkspace`.
    func pickProject() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.allowedFileTypes = ["xcodeproj", "xcworkspace"]
        panel.message = "Choose an Xcode project or workspace"
        panel.prompt = "Choose"

        let response = await MainActor.run { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        await load(projectURL: url)
    }

    /// Apply a freshly-picked project URL: set name, resolve schemes.
    func load(projectURL: URL) async {
        self.projectURL = projectURL
        self.projectDisplayName = projectURL.deletingPathExtension().lastPathComponent
        await resolveSchemes(for: projectURL)
    }

    /// Run `xcodebuild -list -json` and populate `availableSchemes`. Best
    /// effort — failure leaves the user with a free-form text field.
    func resolveSchemes(for url: URL) async {
        isResolvingSchemes = true
        schemeError = nil
        defer { isResolvingSchemes = false }

        guard let xcodebuild = (try? await toolLocator.locateAll())?.xcodebuild else {
            schemeError = "xcodebuild not found"
            return
        }

        let flag: [String]
        switch url.pathExtension {
        case "xcworkspace": flag = ["-workspace", url.path]
        case "xcodeproj":   flag = ["-project", url.path]
        default:
            schemeError = "Not an .xcodeproj or .xcworkspace"
            return
        }

        let spec = ProcessSpec(
            executable: xcodebuild,
            arguments: flag + ["-list", "-json"],
            workingDirectory: url.deletingLastPathComponent(),
            timeout: .seconds(20)
        )
        do {
            let result = try await processRunner.run(spec)
            let parsed = Self.parseSchemes(result.stdout)
            self.availableSchemes = parsed
            // Default selection: first scheme.
            if selectedScheme.isEmpty || !parsed.contains(selectedScheme) {
                self.selectedScheme = parsed.first ?? ""
            }
        } catch {
            Self.logger.warning("scheme resolve failed: \(error.localizedDescription, privacy: .public)")
            schemeError = "Couldn't list schemes — enter one manually."
            self.availableSchemes = []
        }
    }

    static func parseSchemes(_ stdoutData: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            return []
        }
        // Workspace shape: { "workspace": { "schemes": [...] } }
        if let ws = json["workspace"] as? [String: Any],
           let schemes = ws["schemes"] as? [String] {
            return schemes
        }
        // Project shape: { "project": { "schemes": [...] } }
        if let proj = json["project"] as? [String: Any],
           let schemes = proj["schemes"] as? [String] {
            return schemes
        }
        return []
    }

    // MARK: Build a GoalRequest

    func buildRequest(simulator: SimulatorRef) -> GoalRequest? {
        guard let projectURL else { return nil }
        return GoalRequest(
            id: UUID(),
            goal: goalText.trimmingCharacters(in: .whitespacesAndNewlines),
            persona: personaText.isEmpty
                ? "A curious first-time user who reads labels but doesn't have the manual."
                : personaText,
            project: ProjectRequest(
                path: projectURL,
                scheme: selectedScheme,
                displayName: projectDisplayName
            ),
            simulator: simulator,
            model: model,
            mode: mode,
            stepBudget: stepBudget,
            tokenBudget: model == .opus47 ? 250_000 : 1_000_000
        )
    }
}
