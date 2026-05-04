//
//  GoalInputView.swift  ("Compose Run" form)
//  Harness
//
//  Goal-led composer that sits on top of the workspace rework: the run's
//  goal comes from a saved Action (or each leg of an Action Chain) the
//  user picks from the Library, never free-form. Project + scheme +
//  simulator come from the active Application's saved fields.
//
//  Visual design lifted from `HarnessDesign/Screens/NewRunView.swift`
//  (since deleted): section header bar with preflight `Pill`, run-name
//  pill row with `RUN` label + auto badge, two-equal-cell run-mode strip
//  with keyboard hints, Advanced disclosure with `INHERITS APP` badges
//  while defaults are unmodified, sticky footer pinning preflight status
//  + Start Run (⌘↵). Free-form goal textarea / example chips / context
//  strip / persona preview avatar were dropped — they duplicated content
//  the Action / Persona / Application library surfaces already own.
//

import SwiftUI

struct GoalInputView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    @State private var vm: GoalInputViewModel?
    @State private var activeApplication: ApplicationSnapshot?
    @State private var hydratedAppID: UUID?
    @State private var advancedExpanded: Bool = false

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

    // MARK: Content

    @ViewBuilder
    private func content(vm: GoalInputViewModel) -> some View {
        VStack(spacing: 0) {
            sectionHeader(vm: vm)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    runNameRow(vm: vm)
                    heroHeading
                    SimulatorSection(vm: vm)
                    PersonaSection(vm: vm)
                    SourceSection(vm: vm)
                    runModeStrip(vm: vm)
                    advancedSection(vm: vm)
                    if let err = vm.startError {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(Color.harnessFailure)
                    }
                }
                .padding(.horizontal, Theme.spacing.xl)
                .padding(.top, Theme.spacing.xl)
                .padding(.bottom, Theme.spacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer(vm: vm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.harnessBg)
        .navigationTitle("")
    }

    // MARK: Section header

    private func sectionHeader(vm: GoalInputViewModel) -> some View {
        HStack(spacing: 10) {
            Text("New Run")
                .font(HFont.uiSemibold(13))
                .foregroundStyle(Color.harnessText)
            if let app = activeApplication {
                Text("/ \(app.name) · \(app.scheme)")
                    .font(HFont.mono(11))
                    .foregroundStyle(Color.harnessText4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            preflightPill(vm: vm)
        }
        .padding(.horizontal, Theme.spacing.l)
        .frame(height: 42)
        .background(Color.harnessBg3)
        .overlay(
            Rectangle().fill(Color.harnessLine).frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func preflightPill(vm: GoalInputViewModel) -> some View {
        let preflight = preflightStatus(vm: vm)
        return Pill(
            text: preflight.label,
            kind: preflight.allOK ? .success : .warning
        )
    }

    // MARK: Run name row

    private func runNameRow(vm: GoalInputViewModel) -> some View {
        @Bindable var bvm = vm
        return HStack(spacing: 10) {
            Text("RUN")
                .font(HFont.mono(9.5))
                .tracking(0.8)
                .foregroundStyle(Color.harnessText4)
            TextField(autoNamePlaceholder(vm: vm), text: $bvm.runName)
                .textFieldStyle(.plain)
                .font(HFont.ui(12.5))
                .foregroundStyle(Color.harnessText)
            if vm.runName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("auto")
                    .font(HFont.mono(10))
                    .foregroundStyle(Color.harnessText4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.harnessPanel2, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.harnessLineStrong, lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, Theme.spacing.m)
        .frame(height: 38)
        .background(Color.harnessPanel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .strokeBorder(Color.harnessLine, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
    }

    // MARK: Hero heading

    private var heroHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compose a user-test run")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.harnessText)
            Text("Pick a persona, then an action or a chain. Run defaults inherit from the active Application.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Run mode strip

    private func runModeStrip(vm: GoalInputViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Run mode")
                    .font(HFont.uiSemibold(11.5))
                    .foregroundStyle(Color.harnessText)
                Text("How much you stay in the loop.")
                    .font(HFont.ui(11))
                    .foregroundStyle(Color.harnessText3)
                Spacer()
                if !vm.overrideDefaults {
                    InheritsBadge()
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 0) {
                ForEach(RunMode.allCases, id: \.self) { m in
                    ModeCell(mode: m, selected: vm.mode == m) {
                        vm.mode = m
                        if vm.mode != activeApplication?.defaultMode {
                            vm.overrideDefaults = true
                        }
                    }
                    if m != RunMode.allCases.last {
                        Rectangle().fill(Color.harnessLine).frame(width: 0.5)
                    }
                }
            }
            .background(Color.harnessPanel)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.panel)
                    .strokeBorder(Color.harnessLine, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
        }
    }

    // MARK: Advanced

    private func advancedSection(vm: GoalInputViewModel) -> some View {
        @Bindable var bvm = vm
        return VStack(spacing: 0) {
            Button { advancedExpanded.toggle() } label: {
                HStack(spacing: Theme.spacing.s) {
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.harnessText3)
                    Text("Advanced")
                        .font(HFont.uiSemibold(11.5))
                        .foregroundStyle(Color.harnessText)
                    Spacer()
                    Pill(text: vm.model.displayName, kind: .neutral)
                    Pill(text: "\(vm.stepBudget) steps", kind: .neutral)
                }
                .padding(.horizontal, Theme.spacing.m)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
            .overlay(
                Rectangle().fill(Color.harnessLine).frame(height: 0.5).opacity(advancedExpanded ? 1 : 0),
                alignment: .bottom
            )

            if advancedExpanded {
                VStack(spacing: 0) {
                    AdvancedRow(
                        label: "Model",
                        sublabel: "Override the workspace default.",
                        showsInherits: !vm.overrideDefaults
                    ) {
                        SegmentedToggle(
                            options: AgentModel.allCases.map { .init($0, $0.displayName) },
                            selection: $bvm.model
                        )
                        .onChange(of: vm.model) { _, _ in vm.overrideDefaults = true }
                    }
                    Divider().background(Color.harnessLineSoft)

                    AdvancedRow(
                        label: "Step budget",
                        sublabel: "Hard cap before the agent reports failure. 5–200.",
                        showsInherits: !vm.overrideDefaults
                    ) {
                        HStack(spacing: 10) {
                            Stepper("", value: $bvm.stepBudget, in: 5...200, step: 5)
                                .labelsHidden()
                                .onChange(of: vm.stepBudget) { _, _ in vm.overrideDefaults = true }
                            Text("\(vm.stepBudget) steps")
                                .font(HFont.mono)
                                .foregroundStyle(Color.harnessText2)
                        }
                    }
                }
            }
        }
        .background(Color.harnessPanel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .strokeBorder(Color.harnessLine, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
    }

    // MARK: Footer

    private func footer(vm: GoalInputViewModel) -> some View {
        let preflight = preflightStatus(vm: vm)
        return HStack(spacing: Theme.spacing.m) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(preflight.allOK ? Color.harnessSuccess : Color.harnessWarning)
                        .frame(width: 14, height: 14)
                    Image(systemName: preflight.allOK ? "checkmark" : "exclamationmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(preflight.fullCopy)
                    .font(HFont.ui(11.5))
                    .foregroundStyle(preflight.allOK ? Color.harnessText3 : Color.harnessText)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                Task { await start(vm: vm) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Text("Start Run")
                    Text("⌘↵").font(HFont.mono(10)).opacity(0.8)
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!vm.canStart || !state.apiKeyPresent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, Theme.spacing.l)
        .padding(.vertical, Theme.spacing.m)
        .background(Color.harnessBg3)
        .overlay(
            Rectangle().fill(Color.harnessLine).frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: Helpers

    /// Live preview of the auto-generated name when the user leaves the
    /// runName field blank. Mirrors the build-time fallback in the VM.
    private func autoNamePlaceholder(vm: GoalInputViewModel) -> String {
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

    // MARK: Preflight aggregation

    private struct Preflight: Equatable {
        var apiKey: Bool
        var simulator: Bool
        var tooling: Bool
        var allOK: Bool { apiKey && simulator && tooling }

        var label: String {
            if allOK { return "preflight ok" }
            if !apiKey { return "API key missing" }
            if !tooling { return "xcodebuild missing" }
            if !simulator { return "no simulator" }
            return "preflight"
        }

        var fullCopy: String {
            if allOK { return "Build is fresh · Simulator booted · API key valid" }
            var problems: [String] = []
            if !apiKey { problems.append("Add Anthropic API key in Settings") }
            if !tooling { problems.append("xcodebuild not found") }
            if !simulator { problems.append("no simulator selected") }
            return problems.joined(separator: " · ")
        }
    }

    private func preflightStatus(vm: GoalInputViewModel) -> Preflight {
        Preflight(
            apiKey: state.apiKeyPresent,
            simulator: state.simulators.contains(where: { $0.udid == vm.simulatorUDID }),
            tooling: state.xcodebuildAvailable
        )
    }

    // MARK: Actions

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
        // history index can scope by it.
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
            // Reset overrideDefaults since the active application changed.
            vm.overrideDefaults = false
        }
    }
}

// MARK: - Sub-sections (production data flow — pre-redesign shape)

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

/// Source toggle + Action / Chain picker — the goal source for the run.
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
/// `FrictionTag(.deadEnd)` — matches the warning a chain row shows in
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

// MARK: - NewRun-specific subviews (private design components)

/// Equal-width cell in the Run-Mode strip.
private struct ModeCell: View {
    let mode: RunMode
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? Color.harnessAccent : Color.harnessLineStrong, lineWidth: 1)
                            .background(Circle().fill(selected ? Color.harnessAccent : Color.harnessPanel2))
                        if selected {
                            Circle().fill(Color.harnessPanel).padding(3)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(mode.displayLabel)
                        .font(HFont.uiSemibold(12.5))
                        .foregroundStyle(Color.harnessText)
                }
                Text(mode.subtitle)
                    .font(HFont.ui(11))
                    .foregroundStyle(Color.harnessText3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(Array(mode.shortcuts.enumerated()), id: \.offset) { _, sc in
                        HStack(spacing: 4) {
                            KbdKey(sc.key)
                            Text(sc.label)
                                .font(HFont.mono(10))
                                .foregroundStyle(Color.harnessText4)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(Theme.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.harnessAccentSoft : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Color.harnessAccent).frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private extension RunMode {
    var displayLabel: String {
        switch self {
        case .stepByStep: return "Step-by-step"
        case .autonomous: return "Autonomous"
        }
    }
    var subtitle: String {
        switch self {
        case .stepByStep: return "Approve each action before it runs. Best for first runs and high-risk flows."
        case .autonomous: return "Let the agent run end-to-end. Pause or stop at any point."
        }
    }
    var shortcuts: [(label: String, key: String)] {
        switch self {
        case .stepByStep: return [("approve", "Space"), ("reject", "⇧Space")]
        case .autonomous: return [("stop", "⌘.")]
        }
    }
}

private struct AdvancedRow<Content: View>: View {
    let label: String
    let sublabel: String
    var showsInherits: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(HFont.ui(12)).foregroundStyle(Color.harnessText2)
                Text(sublabel).font(HFont.ui(10.5)).foregroundStyle(Color.harnessText4)
            }
            .frame(width: 200, alignment: .leading)

            HStack(spacing: 10) {
                content()
                if showsInherits { InheritsBadge() }
                Spacer()
            }
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, 9)
    }
}

/// Dashed-outline mono micro label `INHERITS APP`.
private struct InheritsBadge: View {
    var body: some View {
        Text("INHERITS APP")
            .font(HFont.mono(9.5))
            .tracking(0.4)
            .foregroundStyle(Color.harnessText4)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        Color.harnessLineStrong,
                        style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                    )
            )
    }
}

/// Small monospaced key cap. Used inside ModeCell shortcut hints.
private struct KbdKey: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(HFont.mono(10.5))
            .foregroundStyle(Color.harnessText2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.harnessPanel2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.harnessLineStrong, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
