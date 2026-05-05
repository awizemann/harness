//
//  GoalInputViewModel.swift
//  Harness
//
//  Drives the Phase E "Compose Run" form. Replaces the pre-rework
//  free-form persona/goal text fields with a curated picker over the
//  Personas / Actions / ActionChains library, scoped to the active
//  Application. Project + scheme + simulator come from the active
//  Application's saved fields — the form no longer lets the user
//  re-pick those (that lives on the Applications page now).
//
//  Build flow:
//    1. `loadFromActiveApplication(_:)` populates project/scheme/sim
//       from the saved Application + applies its run defaults.
//    2. `loadLibraries(store:)` fetches Personas / Actions / Chains
//       from the SwiftData store on the actor and stages them as
//       Sendable snapshots.
//    3. The user picks a Persona + a Source (Single Action vs Chain)
//       + a Source-specific entity. Optionally types a run name.
//       Optionally toggles the "override defaults" disclosure.
//    4. `buildRequest(simulator:)` synthesizes a `RunRequest` carrying
//       the right `RunPayload` plus snapshot data ferried into the
//       JSONL `run_started` row.
//

import Foundation
import Observation
import SwiftUI

/// What the user is composing on the Source toggle.
enum RunSource: String, Hashable, CaseIterable, Identifiable {
    case action
    case chain

    var id: String { rawValue }
    var label: String {
        switch self {
        case .action: return "Single action"
        case .chain:  return "Action chain"
        }
    }
}

@Observable
@MainActor
final class GoalInputViewModel {

    // MARK: Form state — non-project

    var simulatorUDID: String = ""
    /// Phase 2: which kind of platform the active Application targets.
    /// Drives form section visibility (Simulator vs Mac-target vs Web-
    /// target) and per-platform `canStart` validation. Set by
    /// `loadFromActiveApplication`.
    var platformKind: PlatformKind = .iosSimulator
    /// macOS pre-built `.app` path mirrored from the Application snapshot.
    /// Used for the macOS target's read-only summary block.
    var macAppBundlePath: String?
    /// Web start URL + viewport mirrored from the Application snapshot.
    var webStartURL: String = ""
    var webViewportWidthPt: Int = 1280
    var webViewportHeightPt: Int = 800
    /// Optional user-supplied run name. Empty falls back to a
    /// placeholder synthesized from the chosen action / chain + date.
    var runName: String = ""
    /// Toggle between single-action and chain composition.
    var source: RunSource = .action
    /// Selected persona id (nil = nothing picked yet → start disabled).
    var selectedPersonaID: UUID?
    var selectedActionID: UUID?
    var selectedChainID: UUID?
    /// When true, the "Override defaults" disclosure is open and the
    /// model/mode/budget controls take effect. When false, the active
    /// Application's saved defaults apply.
    var overrideDefaults: Bool = false
    var mode: RunMode = .stepByStep
    var model: AgentModel = .opus47
    var stepBudget: Int = 40

    // MARK: Library snapshots (loaded async from RunHistoryStore)

    var personas: [PersonaSnapshot] = []
    var actions: [ActionSnapshot] = []
    var chains: [ActionChainSnapshot] = []

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

    /// Phase 2: per-platform start gate.
    ///
    /// All platforms require: a persona is picked, and the chosen
    /// source (action / chain) is valid + non-archived + non-broken.
    ///
    /// iOS additionally requires: project URL + scheme, the scheme
    /// supports the iOS Simulator, and a simulator is picked.
    ///
    /// macOS additionally requires: either a project URL + scheme
    /// (build mode) OR a pre-built `.app` path.
    ///
    /// Web additionally requires: a non-empty start URL.
    var canStart: Bool {
        guard selectedPersonaID != nil else { return false }
        switch source {
        case .action:
            guard let id = selectedActionID,
                  let action = actions.first(where: { $0.id == id }),
                  !action.archived else { return false }
        case .chain:
            guard let id = selectedChainID,
                  let chain = chains.first(where: { $0.id == id }),
                  !chain.archived,
                  !chain.steps.isEmpty,
                  chain.steps.allSatisfy({ $0.actionID != nil })
            else { return false }
        }
        // Per-platform target gate.
        switch platformKind {
        case .iosSimulator:
            return picker.projectURL != nil
                && !picker.selectedScheme.isEmpty
                && !simulatorUDID.isEmpty
                && picker.schemeSupportsIOSSimulator
        case .macosApp:
            if let path = macAppBundlePath, !path.isEmpty { return true }
            return picker.projectURL != nil && !picker.selectedScheme.isEmpty
        case .web:
            let trimmed = webStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && URL(string: trimmed) != nil
        }
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

    /// Pre-fill the form from an active `Application`. Per-platform:
    ///
    ///   - iOS: project URL + scheme, simulator UDID, and probe
    ///     destinations to refresh the iOS-simulator-compat banner.
    ///   - macOS: project + scheme (if set, for the build path) and the
    ///     pre-built `.app` path (if set, for the fast launch path).
    ///     Skip the destination probe — `xcodebuild -showdestinations`
    ///     for a macOS-only scheme returns mac destinations and our
    ///     iOS-compat banner would render misleadingly.
    ///   - Web: start URL + viewport. No project at all.
    func loadFromActiveApplication(_ app: ApplicationSnapshot) async {
        platformKind = app.platformKind
        // Run defaults are platform-neutral.
        if let m = app.defaultModel { model = m }
        if let m = app.defaultMode { mode = m }
        stepBudget = app.defaultStepBudget

        switch app.platformKind {
        case .iosSimulator:
            picker.projectURL = app.projectURL
            picker.projectDisplayName = app.name
            picker.availableSchemes = [app.scheme]
            picker.selectedScheme = app.scheme
            if let udid = app.defaultSimulatorUDID, !udid.isEmpty {
                simulatorUDID = udid
            }
            macAppBundlePath = nil
            webStartURL = ""
            await picker.refreshSchemeDestinations()
        case .macosApp:
            if !app.projectPath.isEmpty {
                picker.projectURL = app.projectURL
                picker.projectDisplayName = app.name
                picker.availableSchemes = [app.scheme]
                picker.selectedScheme = app.scheme
            } else {
                picker.projectURL = nil
                picker.projectDisplayName = app.name
                picker.availableSchemes = []
                picker.selectedScheme = ""
            }
            macAppBundlePath = app.macAppBundlePath
            simulatorUDID = ""
            webStartURL = ""
            // Skip the destination probe — irrelevant for the macOS path.
        case .web:
            picker.projectURL = nil
            picker.projectDisplayName = app.name
            picker.availableSchemes = []
            picker.selectedScheme = ""
            simulatorUDID = ""
            macAppBundlePath = nil
            webStartURL = app.webStartURL ?? ""
            webViewportWidthPt = app.webViewportWidthPt ?? 1280
            webViewportHeightPt = app.webViewportHeightPt ?? 800
        }
    }

    // MARK: Library hydration

    /// Pull live persona / action / chain snapshots off the store.
    /// Idempotent — call this whenever the form appears or after
    /// returning from one of the create sheets.
    func loadLibraries(store: any RunHistoryStoring) async {
        async let personasLoad = (try? store.personas()) ?? []
        async let actionsLoad = (try? store.actions()) ?? []
        async let chainsLoad = (try? store.actionChains()) ?? []
        let (p, a, c) = await (personasLoad, actionsLoad, chainsLoad)
        self.personas = p
        self.actions = a
        self.chains = c

        // Auto-select the most-recently-used entity when nothing is
        // picked yet so the form lands in a startable state for the
        // user's last session.
        if selectedPersonaID == nil { selectedPersonaID = p.first?.id }
        if selectedActionID == nil { selectedActionID = a.first?.id }
        if selectedChainID == nil { selectedChainID = c.first?.id }
    }

    // MARK: Build a RunRequest

    /// Compose the request to hand to `AppContainer.stagePendingRun(_:)`.
    /// Returns nil when the form's gate isn't satisfied — the view
    /// should gate the Start button on `canStart` so this rarely
    /// returns nil in practice; the nil path covers race conditions
    /// where library snapshots refresh out from under the form.
    ///
    /// The `simulator` argument is meaningful for iOS runs only. macOS
    /// and web pass a synthetic `SimulatorRef` derived from the active
    /// Application — `RunRequest.simulator` is still a stored field for
    /// back-compat, but `MacOSPlatformAdapter` / `WebPlatformAdapter`
    /// ignore its UDID and use their own launch path.
    func buildRequest(simulator: SimulatorRef) -> RunRequest? {
        guard let personaID = selectedPersonaID,
              let persona = personas.first(where: { $0.id == personaID })
        else { return nil }
        // iOS requires a real project URL; macOS / web don't.
        if platformKind == .iosSimulator, picker.projectURL == nil {
            return nil
        }

        // Decide the payload + denormalized goal/name fields.
        let payload: RunPayload
        let goalSnapshot: String
        let primaryName: String
        switch source {
        case .action:
            guard let actionID = selectedActionID,
                  let action = actions.first(where: { $0.id == actionID })
            else { return nil }
            payload = .singleAction(actionID: action.id, goal: action.promptText)
            goalSnapshot = action.promptText
            primaryName = action.name
        case .chain:
            guard let chainID = selectedChainID,
                  let chain = chains.first(where: { $0.id == chainID })
            else { return nil }
            // Materialize legs from the chain's ordered steps.
            var legs: [ChainLeg] = []
            for step in chain.steps.sorted(by: { $0.index < $1.index }) {
                guard let actionID = step.actionID,
                      let action = actions.first(where: { $0.id == actionID })
                else { return nil }   // broken link — gated above, defensive here
                legs.append(ChainLeg(
                    id: UUID(),
                    index: step.index,
                    actionID: action.id,
                    actionName: action.name,
                    goal: action.promptText,
                    preservesState: step.preservesState
                ))
            }
            payload = .chain(chainID: chain.id, legs: legs)
            goalSnapshot = legs.first?.goal ?? ""
            primaryName = chain.name
        }

        // Auto-name when the user left the field blank: "<source> · <date>"
        // mirrors the placeholder that the view renders.
        let resolvedName: String = {
            let trimmed = runName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return "\(primaryName) · \(f.string(from: Date()))"
        }()

        // Build the ProjectRequest. iOS / macOS-build-mode use the picker;
        // macOS-bundle-mode and web pass a placeholder URL that the
        // adapter ignores.
        let projectRequest: ProjectRequest = {
            if let projectURL = picker.projectURL {
                return ProjectRequest(
                    path: projectURL,
                    scheme: picker.selectedScheme,
                    displayName: picker.projectDisplayName
                )
            } else {
                // Non-iOS platforms with no Xcode project (web; macOS
                // pre-built .app). The adapter's launch path doesn't
                // touch this field. Use a stable placeholder URL so
                // round-trip Codable stays sane.
                return ProjectRequest(
                    path: URL(fileURLWithPath: "/dev/null"),
                    scheme: "",
                    displayName: picker.projectDisplayName
                )
            }
        }()

        return RunRequest(
            id: UUID(),
            name: resolvedName,
            goal: goalSnapshot,
            persona: persona.promptText,
            applicationID: nil,           // hydrated by the view layer
            personaID: persona.id,
            payload: payload,
            project: projectRequest,
            simulator: simulator,
            model: model,
            mode: mode,
            stepBudget: stepBudget,
            tokenBudget: model == .opus47 ? 250_000 : 1_000_000,
            platformKindRaw: platformKind.rawValue,
            macAppBundlePath: macAppBundlePath,
            webStartURL: platformKind == .web ? webStartURL : nil,
            webViewportWidthPt: platformKind == .web ? webViewportWidthPt : nil,
            webViewportHeightPt: platformKind == .web ? webViewportHeightPt : nil
        )
    }
}
