//
//  GoalInputView.swift  (Phase E — "Compose Run" form)
//  Harness
//
//  Replaces the pre-rework free-form persona/goal text fields with a
//  curated picker over the Personas / Actions / Chains library, scoped
//  to the active Application. Project + scheme + simulator come from
//  the active Application's saved fields.
//
//  Renders three blocks beneath the active-application recap:
//    - Persona picker (always shown).
//    - Source toggle + matching Action / Chain picker, with an inline
//      preview (the action's prompt text, or the chain's ordered
//      steps with `preservesState` indicators).
//    - "Override defaults" disclosure that exposes model/mode/budget
//      controls. Collapsed by default — defaults inherit from the
//      active Application.
//

import SwiftUI

struct GoalInputView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    @State private var vm: GoalInputViewModel?
    @State private var activeApplication: ApplicationSnapshot?
    @State private var hydratedAppID: UUID?

    var body: some View {
        Group {
            if coordinator.selectedApplicationID == nil {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: "Pick an Application first",
                    subtitle: "New runs are scoped to a saved Application. Select one in the Library, or add a new Application.",
                    ctaTitle: "Open Applications",
                    onCta: { coordinator.selectedSection = .applications }
                )
            } else if let vm {
                content(vm: vm)
                    .task(id: coordinator.selectedApplicationID) {
                        await hydrate(vm: vm)
                    }
                    .task {
                        await vm.loadLibraries(store: container.runHistory)
                    }
            } else {
                Color.clear
                    .onAppear {
                        self.vm = GoalInputViewModel(
                            processRunner: container.processRunner,
                            toolLocator: container.toolLocator,
                            xcodeBuilder: container.xcodeBuilder
                        )
                    }
            }
        }
    }

    @ViewBuilder
    private func content(vm: GoalInputViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.l) {
                header
                if let app = activeApplication {
                    ActiveApplicationRecap(application: app)
                }
                RunNameSection(vm: vm)
                SimulatorSection(vm: vm)
                PersonaSection(vm: vm)
                SourceSection(vm: vm)
                OverrideDefaultsSection(vm: vm)
                if let err = vm.startError {
                    Text(err).foregroundStyle(Color.harnessFailure).font(.callout)
                }
                Button {
                    Task { await start(vm: vm) }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Run")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!vm.canStart || !state.apiKeyPresent)
                if !state.apiKeyPresent {
                    Text("Add your Anthropic API key in Settings before starting.")
                        .font(.callout).foregroundStyle(Color.harnessWarning)
                }
            }
            .padding(Theme.spacing.xl)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("New Run")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compose a user-test run")
                .font(.title2.weight(.semibold))
            Text("Pick a persona, then an action or a chain. Run defaults inherit from the active Application.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func start(vm: GoalInputViewModel) async {
        guard let sim = state.simulators.first(where: { $0.udid == vm.simulatorUDID }) else {
            vm.startError = "Selected simulator not found. Refresh the list."
            return
        }
        guard var request = vm.buildRequest(simulator: sim) else {
            vm.startError = "Couldn't compose the run. Make sure a persona and an action / chain are picked."
            return
        }
        // Stamp the active Application id onto the request so the
        // history index can scope by it. RunRequest is a value type;
        // we re-init with the additional field here rather than push
        // application ownership into the VM.
        if let appID = coordinator.selectedApplicationID {
            request = RunRequest(
                id: request.id,
                name: request.name,
                goal: request.goal,
                persona: request.persona,
                applicationID: appID,
                personaID: request.personaID,
                payload: request.payload,
                project: request.project,
                simulator: request.simulator,
                model: request.model,
                mode: request.mode,
                stepBudget: request.stepBudget,
                tokenBudget: request.tokenBudget
            )
        }
        coordinator.startedRun(id: request.id)
        await container.stagePendingRun(request)
    }

    /// Fetch the active Application snapshot off the actor and hydrate the
    /// VM from it. Re-runs whenever `selectedApplicationID` flips so the
    /// preview banner stays current.
    @MainActor
    private func hydrate(vm: GoalInputViewModel) async {
        guard let id = coordinator.selectedApplicationID else {
            activeApplication = nil
            hydratedAppID = nil
            return
        }
        let snapshot = try? await container.runHistory.application(id: id)
        activeApplication = snapshot
        if let snapshot, hydratedAppID != snapshot.id {
            await vm.loadFromActiveApplication(snapshot)
            hydratedAppID = snapshot.id
        }
    }
}

// MARK: - Sub-sections

/// Slim recap card showing the active Application's project + scheme. The
/// user can no longer re-pick the project from this view — that lives on
/// the Applications detail page now.
private struct ActiveApplicationRecap: View {
    let application: ApplicationSnapshot
    var body: some View {
        PanelContainer(title: "Application") {
            HStack(spacing: Theme.spacing.m) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.harnessAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name).font(.body.weight(.medium))
                    Text("\(application.scheme) · \(application.projectPath)")
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(Theme.spacing.l)
        }
    }
}

private struct RunNameSection: View {
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "Run name (optional)") {
            TextField(placeholder, text: $vm.runName)
                .textFieldStyle(.roundedBorder)
                .padding(Theme.spacing.l)
        }
    }

    /// Live preview of the auto-generated name when the user leaves the
    /// field blank. Mirrors the build-time fallback in
    /// `GoalInputViewModel.buildRequest`.
    private var placeholder: String {
        let primary: String
        switch vm.source {
        case .action:
            primary = vm.actions.first(where: { $0.id == vm.selectedActionID })?.name ?? "action"
        case .chain:
            primary = vm.chains.first(where: { $0.id == vm.selectedChainID })?.name ?? "chain"
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(primary) · \(f.string(from: Date()))"
    }
}

private struct SimulatorSection: View {
    @Environment(AppState.self) private var state
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "Simulator") {
            HStack {
                if state.simulators.isEmpty {
                    Text("No simulators discovered. Open Xcode, boot one, then refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $vm.simulatorUDID) {
                        ForEach(state.simulators, id: \.udid) { sim in
                            Text("\(sim.name) · \(sim.runtime)").tag(sim.udid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Spacer()
                Button("Refresh") {
                    Task { await state.refreshSimulators() }
                }
                .buttonStyle(.borderless)
            }
            .padding(Theme.spacing.l)
            .onAppear {
                if vm.simulatorUDID.isEmpty,
                   let initial = state.defaultSimulatorUDID ?? state.simulators.first?.udid {
                    vm.simulatorUDID = initial
                }
            }
        }
    }
}

/// Persona picker. Shows name + blurb for each persona; offers a quick
/// shortcut to the Personas page when none exist yet.
private struct PersonaSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "Persona") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                if vm.personas.isEmpty {
                    Text("No personas found. Open the Personas library to create one.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Personas") {
                        coordinator.selectedSection = .personas
                    }
                    .buttonStyle(.borderless)
                } else {
                    Picker("", selection: $vm.selectedPersonaID) {
                        Text("Pick a persona…").tag(UUID?.none)
                        ForEach(vm.personas, id: \.id) { p in
                            Text(p.name).tag(UUID?.some(p.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    if let id = vm.selectedPersonaID,
                       let persona = vm.personas.first(where: { $0.id == id }) {
                        Text(persona.blurb)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.spacing.l)
        }
    }
}

/// Source toggle + Action / Chain picker.
private struct SourceSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "What should the agent do?") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                SegmentedToggle(
                    options: RunSource.allCases.map { .init($0, $0.label) },
                    selection: $vm.source
                )
                .frame(maxWidth: 320)
                Divider()
                switch vm.source {
                case .action:
                    actionPicker
                case .chain:
                    chainPicker
                }
            }
            .padding(Theme.spacing.l)
        }
    }

    @ViewBuilder
    private var actionPicker: some View {
        if vm.actions.isEmpty {
            Text("No actions yet. Create one in the Actions library.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Actions") {
                coordinator.selectedSection = .actions
            }
            .buttonStyle(.borderless)
        } else {
            Picker("", selection: $vm.selectedActionID) {
                Text("Pick an action…").tag(UUID?.none)
                ForEach(vm.actions, id: \.id) { a in
                    Text(a.name).tag(UUID?.some(a.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if let id = vm.selectedActionID,
               let action = vm.actions.first(where: { $0.id == id }) {
                Text(action.promptText)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, Theme.spacing.xs)
                    .lineLimit(4)
            }
        }
    }

    @ViewBuilder
    private var chainPicker: some View {
        if vm.chains.isEmpty {
            Text("No chains yet. Create one in the Actions library under the Chains tab.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Actions") {
                coordinator.selectedSection = .actions
            }
            .buttonStyle(.borderless)
        } else {
            Picker("", selection: $vm.selectedChainID) {
                Text("Pick a chain…").tag(UUID?.none)
                ForEach(vm.chains, id: \.id) { c in
                    Text(c.name).tag(UUID?.some(c.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if let id = vm.selectedChainID,
               let chain = vm.chains.first(where: { $0.id == id }) {
                ChainPreview(chain: chain, actions: vm.actions)
                    .padding(.top, Theme.spacing.xs)
            }
        }
    }
}

/// Inline ordered-list preview of a chain's steps. Each step shows
/// `1. <action name>` plus a small "keeps state" tag when
/// `preservesState == true`. Steps with broken Action refs render a
/// FrictionTag(.deadEnd) — matches the warning a chain row shows in
/// the Actions library.
private struct ChainPreview: View {
    let chain: ActionChainSnapshot
    let actions: [ActionSnapshot]
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            ForEach(chain.steps.sorted(by: { $0.index < $1.index }), id: \.id) { step in
                HStack(spacing: Theme.spacing.s) {
                    Text("\(step.index + 1).")
                        .font(HFont.mono)
                        .foregroundStyle(Color.harnessText3)
                        .frame(width: 24, alignment: .leading)
                    if let actionID = step.actionID,
                       let action = actions.first(where: { $0.id == actionID }) {
                        Text(action.name)
                            .font(.caption)
                    } else {
                        FrictionTag(kind: .deadEnd)
                        Text("Missing action")
                            .font(.caption).foregroundStyle(Color.harnessWarning)
                    }
                    if step.preservesState {
                        Text("keeps state")
                            .font(HFont.micro)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.harnessPanel2))
                            .foregroundStyle(Color.harnessText2)
                    }
                }
            }
        }
    }
}

/// Run-options disclosure. Collapsed by default — Application defaults
/// apply. When expanded, the model/mode/budget controls take effect.
private struct OverrideDefaultsSection: View {
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "Run options") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                Toggle("Override Application defaults", isOn: $vm.overrideDefaults)
                    .toggleStyle(.switch)
                if vm.overrideDefaults {
                    Divider()
                    HStack(spacing: Theme.spacing.xl) {
                        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                            Text("Mode").font(.subheadline.weight(.medium))
                            Picker("", selection: $vm.mode) {
                                Text("Step-by-step").tag(RunMode.stepByStep)
                                Text("Autonomous").tag(RunMode.autonomous)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }
                        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                            Text("Model").font(.subheadline.weight(.medium))
                            Picker("", selection: $vm.model) {
                                Text("Opus 4.7").tag(AgentModel.opus47)
                                Text("Sonnet 4.6").tag(AgentModel.sonnet46)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
                    HStack {
                        Text("Step budget").frame(width: 110, alignment: .leading)
                        Stepper(value: $vm.stepBudget, in: 5...200) {
                            Text("\(vm.stepBudget) steps")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 200, alignment: .leading)
                    }
                } else {
                    Text("Inheriting defaults from the active Application.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.spacing.l)
        }
    }
}
