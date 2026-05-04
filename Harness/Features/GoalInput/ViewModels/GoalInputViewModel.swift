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

    /// Phase E start gate: project URL + scheme set, simulator picked,
    /// scheme actually targets iOS Simulator, persona picked, and a
    /// matching Action / Chain selected for the chosen source.
    var canStart: Bool {
        guard picker.projectURL != nil,
              !picker.selectedScheme.isEmpty,
              !simulatorUDID.isEmpty,
              picker.schemeSupportsIOSSimulator,
              selectedPersonaID != nil
        else { return false }
        switch source {
        case .action:
            // Picked action exists and isn't archived.
            guard let id = selectedActionID,
                  let action = actions.first(where: { $0.id == id }),
                  !action.archived else { return false }
            return true
        case .chain:
            // Picked chain exists, isn't archived, has at least one
            // step, and every step has a backing Action (no broken-link
            // chain steps from a deleted Action).
            guard let id = selectedChainID,
                  let chain = chains.first(where: { $0.id == id }),
                  !chain.archived,
                  !chain.steps.isEmpty,
                  chain.steps.allSatisfy({ $0.actionID != nil })
            else { return false }
            return true
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
    func buildRequest(simulator: SimulatorRef) -> RunRequest? {
        guard let projectURL = picker.projectURL,
              let personaID = selectedPersonaID,
              let persona = personas.first(where: { $0.id == personaID })
        else { return nil }

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

        return RunRequest(
            id: UUID(),
            name: resolvedName,
            goal: goalSnapshot,
            persona: persona.promptText,
            applicationID: nil,           // hydrated by the view layer
            personaID: persona.id,
            payload: payload,
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
