//
//  GoalInputView.swift  (production — replaces the HarnessDesign mock)
//  Harness
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
                SimulatorSection(vm: vm)
                PersonaGoalSection(vm: vm)
                ModeAndModelSection(vm: vm)
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
            Text("Pick a persona, write a plain-language goal, and start. The Application's project + scheme are already wired up.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func start(vm: GoalInputViewModel) async {
        guard let sim = state.simulators.first(where: { $0.udid == vm.simulatorUDID }) else {
            vm.startError = "Selected simulator not found. Refresh the list."
            return
        }
        guard let request = vm.buildRequest(simulator: sim) else {
            vm.startError = "Project URL missing."
            return
        }
        // Hand the request to RunSession via the coordinator.
        coordinator.startedRun(id: request.id)
        // Stash the pending request on a window-scoped @State that RunSessionViewModel
        // observes. Simplest hand-off: RunSessionView reads a static "pending request"
        // staged on the AppContainer.
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

private struct PersonaGoalSection: View {
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "Persona & Goal") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                Text("Persona — who you're playing").font(.subheadline.weight(.medium))
                TextField("e.g. first-time user, never seen this app",
                          text: $vm.personaText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
                Text("Goal — what you're trying to do").font(.subheadline.weight(.medium))
                TextEditor(text: $vm.goalText)
                    .font(.body)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.input)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.input)
                            .stroke(Color.harnessLine, lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if vm.goalText.isEmpty {
                            Text("Describe what you want the user to accomplish, in their words. Don't name buttons or screens.")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Theme.spacing.s)
                                .padding(.vertical, Theme.spacing.s)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(Theme.spacing.l)
        }
    }
}

private struct ModeAndModelSection: View {
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: "Run options") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
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
            }
            .padding(Theme.spacing.l)
        }
    }
}
