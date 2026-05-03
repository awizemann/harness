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

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear
                    .onAppear {
                        self.vm = GoalInputViewModel(
                            processRunner: container.processRunner,
                            toolLocator: container.toolLocator
                        )
                    }
            }
        }
    }

    @ViewBuilder
    private func content(vm: GoalInputViewModel) -> some View {
        @Bindable var vmBindable = vm

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ProjectSection(vm: vm)
                SimulatorSection(vm: vm)
                PersonaGoalSection(vm: vm)
                ModeAndModelSection(vm: vm)
                if let err = vm.startError {
                    Text(err).foregroundStyle(.red).font(.callout)
                }
                Button {
                    Task { await start(vm: vm) }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Run")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!vm.canStart || !state.apiKeyPresent)
                if !state.apiKeyPresent {
                    Text("Add your Anthropic API key in Settings before starting.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("New Run")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compose a user-test run")
                .font(.title2.weight(.semibold))
            Text("Pick the app under test, write a plain-language goal, choose a persona, and start.")
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
}

// MARK: - Sub-sections

private struct ProjectSection: View {
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        SectionPanel(title: "Project") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let url = vm.projectURL {
                        Image(systemName: "hammer.fill").foregroundStyle(Color.harnessAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.projectDisplayName).font(.body)
                            Text(url.path).font(.caption).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        Text("No project selected").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") {
                        Task { await vm.pickProject() }
                    }
                }
                if vm.projectURL != nil {
                    HStack {
                        Text("Scheme").frame(width: 80, alignment: .leading)
                        if vm.availableSchemes.isEmpty {
                            TextField("e.g. MyApp", text: $vm.selectedScheme)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $vm.selectedScheme) {
                                ForEach(vm.availableSchemes, id: \.self) { s in
                                    Text(s).tag(s)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        if vm.isResolvingSchemes {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let err = vm.schemeError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct SimulatorSection: View {
    @Environment(AppState.self) private var state
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        SectionPanel(title: "Simulator") {
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
        SectionPanel(title: "Persona & Goal") {
            VStack(alignment: .leading, spacing: 10) {
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
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if vm.goalText.isEmpty {
                            Text("Describe what you want the user to accomplish, in their words. Don't name buttons or screens.")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }
}

private struct ModeAndModelSection: View {
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        SectionPanel(title: "Run options") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode").font(.subheadline.weight(.medium))
                        Picker("", selection: $vm.mode) {
                            Text("Step-by-step").tag(RunMode.stepByStep)
                            Text("Autonomous").tag(RunMode.autonomous)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }
                    VStack(alignment: .leading, spacing: 4) {
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
        }
    }
}

private struct SectionPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
