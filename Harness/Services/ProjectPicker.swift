//
//  ProjectPicker.swift
//  Harness
//
//  Shared helper for "let the user point at an Xcode project / workspace,
//  resolve its schemes, and probe iOS-Simulator compatibility." Used by:
//
//   • `GoalInputView` — to compose a one-shot run.
//   • `ApplicationCreateView` — to persist a saved Application.
//
//  Lifted out of `GoalInputViewModel.pickProject()` so both call sites share
//  the same NSOpenPanel + `xcodebuild -list -json` + `-showdestinations`
//  pipeline. Per `standards/03-subprocess-and-filesystem.md`, all process
//  invocation funnels through `ProcessRunner`; per `standards/01-architecture.md`,
//  this is a service helper, not an MVVM-F view-model.
//

import Foundation
import Observation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import os

@Observable
@MainActor
final class ProjectPicker {

    private static let logger = Logger(subsystem: "com.harness.app", category: "ProjectPicker")

    // MARK: Public state

    /// Absolute URL of the picked `.xcodeproj` or `.xcworkspace`. Nil = nothing
    /// selected yet.
    var projectURL: URL?

    /// Friendly project name derived from `projectURL.lastPathComponent`
    /// (without the extension). Editable separately if a caller wants a
    /// custom display name.
    var projectDisplayName: String = ""

    /// Schemes parsed from `xcodebuild -list -json`. Empty when resolution
    /// failed — callers fall back to a free-form scheme text field.
    var availableSchemes: [String] = []

    /// User-selected scheme. Re-running scheme resolution preserves the
    /// existing value if it's still in the resolved list. Setting this
    /// triggers an automatic destination probe.
    var selectedScheme: String = "" {
        didSet {
            if oldValue != selectedScheme {
                Task { await self.refreshSchemeDestinations() }
            }
        }
    }

    var isResolvingSchemes: Bool = false
    var isProbingDestinations: Bool = false
    var schemeError: String?

    /// Destinations supported by the currently-selected scheme (parsed from
    /// `xcodebuild -showdestinations`). Nil = haven't probed yet.
    var schemeDestinations: [XcodeBuilder.Destination]?

    var schemeSupportsIOSSimulator: Bool {
        guard let dests = schemeDestinations else { return false }
        return dests.contains(where: { $0.supportsIOSSimulator })
    }

    /// Human-readable summary for the UI: "iOS Simulator supported" or
    /// "Builds for macOS only — incompatible with Harness".
    var schemeCompatibilitySummary: String? {
        guard !selectedScheme.isEmpty else { return nil }
        guard let dests = schemeDestinations else {
            return isProbingDestinations ? "Checking compatibility…" : nil
        }
        if dests.isEmpty {
            return "No destinations reported by xcodebuild for this scheme."
        }
        if schemeSupportsIOSSimulator {
            return "iOS Simulator supported"
        }
        let platforms = dests.map { $0.platform }.sorted().joined(separator: ", ")
        return "Scheme builds for \(platforms) — Harness needs an iOS Simulator target."
    }

    // MARK: Dependencies

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating
    private let xcodeBuilder: any XcodeBuilding

    init(
        processRunner: any ProcessRunning,
        toolLocator: any ToolLocating,
        xcodeBuilder: any XcodeBuilding
    ) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
        self.xcodeBuilder = xcodeBuilder
    }

    // MARK: NSOpenPanel

    /// Open an `NSOpenPanel` for the user to pick a `.xcodeproj` or `.xcworkspace`.
    /// Cancelling leaves state untouched.
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

    /// Apply a freshly-picked project URL: set name, resolve schemes, probe
    /// destinations on the auto-selected scheme.
    func load(projectURL: URL) async {
        self.projectURL = projectURL
        self.projectDisplayName = projectURL.deletingPathExtension().lastPathComponent
        await resolveSchemes(for: projectURL)
    }

    // MARK: Scheme resolution

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
            // Default selection: first scheme — but preserve current pick
            // if it's still listed.
            if selectedScheme.isEmpty || !parsed.contains(selectedScheme) {
                self.selectedScheme = parsed.first ?? ""
            }
        } catch {
            Self.logger.warning("scheme resolve failed: \(error.localizedDescription, privacy: .public)")
            schemeError = "Couldn't list schemes — enter one manually."
            self.availableSchemes = []
        }
    }

    /// Probe `xcodebuild -showdestinations` for the currently-selected scheme.
    /// Updates `schemeDestinations`. Safe to call repeatedly; does nothing
    /// if no project is set or no scheme is selected.
    func refreshSchemeDestinations() async {
        guard let projectURL, !selectedScheme.isEmpty else {
            schemeDestinations = nil
            return
        }
        isProbingDestinations = true
        defer { isProbingDestinations = false }
        do {
            let dests = try await xcodeBuilder.destinations(project: projectURL, scheme: selectedScheme)
            self.schemeDestinations = dests
        } catch {
            Self.logger.warning("destinations probe failed: \(error.localizedDescription, privacy: .public)")
            self.schemeDestinations = []
        }
    }

    // MARK: Reset

    /// Clear all state. Called when `ApplicationCreateView` re-opens between
    /// uses.
    func reset() {
        projectURL = nil
        projectDisplayName = ""
        availableSchemes = []
        selectedScheme = ""
        isResolvingSchemes = false
        isProbingDestinations = false
        schemeError = nil
        schemeDestinations = nil
    }

    // MARK: Parsing

    /// Parse the schemes array out of `xcodebuild -list -json` stdout.
    /// Workspace shape: `{ "workspace": { "schemes": [...] } }`.
    /// Project shape:   `{ "project":   { "schemes": [...] } }`.
    static func parseSchemes(_ stdoutData: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            return []
        }
        if let ws = json["workspace"] as? [String: Any],
           let schemes = ws["schemes"] as? [String] {
            return schemes
        }
        if let proj = json["project"] as? [String: Any],
           let schemes = proj["schemes"] as? [String] {
            return schemes
        }
        return []
    }
}
