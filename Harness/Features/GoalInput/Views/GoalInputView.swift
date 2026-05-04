//
//  GoalInputView.swift  ("Compose Run" form, redesigned)
//  Harness
//
//  Goal-led composer:
//    Section header bar (preflight pill + app breadcrumb)
//    Run name row (auto-named hint)
//    Hero heading
//    Goal card (segmented action/chain header + textarea + TRY chips)
//    Context strip (Application · Simulator · Persona — read-only)
//    Persona preview (avatar + voice quote)
//    Source picker (Action or Chain) with inline preview
//    Persona picker
//    Run mode strip (two equal cells: Step-by-step / Autonomous)
//    Advanced disclosure (Model + Step budget, with INHERITS APP badges)
//    Sticky footer (preflight + Save as Action + Start Run)
//
//  Data flow is unchanged from the previous shape: hydrate from the
//  active Application, load Personas / Actions / Chains snapshots from
//  the store, build a `RunRequest` and stage it via AppContainer.
//

import SwiftUI

// Three pre-canned example prompts surfaced as `ExampleChip`s in the
// goal card footer. Tapping one prefills `goalDraft`. Hardcoded for v1;
// future work could read from the active persona or a "starter pack."
private let exampleGoals: [String] = [
    "I'm a first-time user. Try to add 'milk' to my list and mark it done.",
    "Create a new account with my email. I've never used this app.",
    "Cancel my subscription. I want out today."
]

private let exampleChipLabels: [String] = [
    "Add an item to a list",
    "Sign up with email",
    "Cancel a subscription"
]

struct GoalInputView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    @State private var vm: GoalInputViewModel?
    @State private var activeApplication: ApplicationSnapshot?
    @State private var hydratedAppID: UUID?

    /// Free-form goal text. Auto-fills from the picked action's
    /// promptText; the user can override it before starting. For chain
    /// runs the textarea is informational (the chain's per-step prompts
    /// drive the legs), so we hide it.
    @State private var goalDraft: String = ""
    @State private var advancedExpanded: Bool = false
    @State private var saveActionState: SaveActionState = .idle

    private enum SaveActionState: Equatable {
        case idle
        case saving
        case saved
        case error(String)
    }

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
                    .onChange(of: vm.selectedActionID) { _, _ in
                        syncGoalDraftWithSelectedAction(vm: vm)
                    }
                    .onChange(of: vm.source) { _, _ in
                        syncGoalDraftWithSelectedAction(vm: vm)
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
                    goalCard(vm: vm)
                    contextStrip(vm: vm)
                    if let persona = pickedPersona(vm: vm) {
                        personaPreview(persona: persona)
                    }
                    SourcePickerPanel(vm: vm)
                    PersonaPickerPanel(vm: vm)
                    runModeStrip(vm: vm)
                    advancedSection(vm: vm)
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
                Text("/ \(app.name)")
                    .font(HFont.mono(11))
                    .foregroundStyle(Color.harnessText4)
            }
            Spacer()
            preflightPill(vm: vm)
            Button {
                coordinator.openSettings()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.harnessText2)
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
        HStack(alignment: .firstTextBaseline) {
            Text("What should the agent try to do?")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Color.harnessText)
            Spacer()
            Text("Describe the outcome, the way a real user would.")
                .font(HFont.ui(12.5))
                .foregroundStyle(Color.harnessText3)
        }
    }

    // MARK: Goal card

    private func goalCard(vm: GoalInputViewModel) -> some View {
        @Bindable var bvm = vm
        return VStack(spacing: 0) {
            // Header — Goal label + source SegmentedToggle + ⌘↵ hint.
            HStack(spacing: Theme.spacing.m) {
                Text("Goal")
                    .font(HFont.uiSemibold(11.5))
                    .foregroundStyle(Color.harnessText)
                SegmentedToggle(
                    options: RunSource.allCases.map { src in
                        .init(src, src.label, symbol: src.symbol)
                    },
                    selection: $bvm.source
                )
                Spacer()
                Text("⌘↵ to start")
                    .font(HFont.mono(10.5))
                    .foregroundStyle(Color.harnessText4)
            }
            .padding(.horizontal, Theme.spacing.m)
            .padding(.vertical, 10)
            .background(Color.harnessBg3)
            .overlay(
                Rectangle().fill(Color.harnessLine).frame(height: 0.5),
                alignment: .bottom
            )

            // Middle — textarea or chain notice.
            switch vm.source {
            case .action:
                TextEditor(text: $goalDraft)
                    .font(HFont.ui(14))
                    .scrollContentBackground(.hidden)
                    .background(Color.harnessPanel)
                    .frame(minHeight: 96)
                    .padding(.horizontal, Theme.spacing.m)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.harnessText)
            case .chain:
                chainNotice(vm: vm)
                    .padding(.horizontal, Theme.spacing.m)
                    .padding(.vertical, 10)
            }

            // Footer — TRY chips.
            HStack(spacing: 6) {
                Text("TRY")
                    .font(HFont.mono(10.5))
                    .tracking(0.8)
                    .foregroundStyle(Color.harnessText4)
                ForEach(Array(exampleGoals.enumerated()), id: \.offset) { idx, prompt in
                    ExampleChip(text: exampleChipLabels[idx]) {
                        goalDraft = prompt
                        vm.source = .action
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.spacing.m)
            .padding(.vertical, 10)
            .background(Color.harnessBg3)
            .overlay(
                Rectangle().fill(Color.harnessLine).frame(height: 0.5),
                alignment: .top
            )
        }
        .background(Color.harnessPanel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .strokeBorder(Color.harnessLine, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
    }

    @ViewBuilder
    private func chainNotice(vm: GoalInputViewModel) -> some View {
        if let chain = pickedChain(vm: vm) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chain runs execute each leg's saved prompt. Pick the chain below — its goals drive the legs.")
                    .font(HFont.ui(12.5))
                    .foregroundStyle(Color.harnessText3)
                Text("\(chain.steps.count) leg\(chain.steps.count == 1 ? "" : "s") · first goal: \(firstChainGoal(chain: chain, vm: vm))")
                    .font(HFont.caption)
                    .foregroundStyle(Color.harnessText4)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 96, alignment: .topLeading)
        } else {
            Text("Pick a chain below to see its first leg's goal.")
                .font(HFont.ui(12.5))
                .foregroundStyle(Color.harnessText3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 96, alignment: .topLeading)
        }
    }

    // MARK: Context strip

    private func contextStrip(vm: GoalInputViewModel) -> some View {
        let appName = activeApplication?.name ?? "—"
        let simName = state.simulators.first(where: { $0.udid == vm.simulatorUDID })
            .map { "\($0.name) · \($0.runtime)" } ?? "Pick a simulator"
        let personaName = pickedPersona(vm: vm)?.name ?? "Pick a persona"
        return HStack(spacing: 4) {
            ContextCell(label: "APPLICATION", value: appName, icon: "folder.fill")
            ContextCell(label: "SIMULATOR", value: simName, icon: "iphone")
            ContextCell(label: "PERSONA", value: personaName, icon: "person.fill")
        }
        .padding(4)
        .background(Color.harnessPanel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .strokeBorder(Color.harnessLine, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
    }

    // MARK: Persona preview

    private func personaPreview(persona: PersonaSnapshot) -> some View {
        HStack(spacing: Theme.spacing.m) {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color.harnessAccent.opacity(0.30), Color.harnessAccent.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                Text(personaInitials(persona.name))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.harnessAccent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(persona.name)
                        .font(HFont.uiSemibold(12.5))
                        .foregroundStyle(Color.harnessText)
                    Text("VOICE")
                        .font(HFont.mono(9))
                        .tracking(0.8)
                        .foregroundStyle(Color.harnessText4)
                }
                Text("\u{201C}\(persona.blurb.isEmpty ? persona.promptText : persona.blurb)\u{201D}")
                    .font(HFont.ui(11.5).italic())
                    .foregroundStyle(Color.harnessText3)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, 10)
        .background(Color.harnessPanel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .strokeBorder(Color.harnessLine, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
    }

    // MARK: Run mode strip

    private func runModeStrip(vm: GoalInputViewModel) -> some View {
        @Bindable var bvm = vm
        return VStack(alignment: .leading, spacing: 8) {
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
                        // Picking a mode counts as an override of the
                        // Application's saved default.
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
            }
            Spacer()
            saveAsActionButton(vm: vm)
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

    @ViewBuilder
    private func saveAsActionButton(vm: GoalInputViewModel) -> some View {
        let trimmed = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSave = !trimmed.isEmpty && vm.source == .action
        Button {
            Task { await saveAsAction(vm: vm) }
        } label: {
            switch saveActionState {
            case .idle:
                Text("Save as Action")
            case .saving:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            case .saved:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.harnessSuccess)
                    Text("Saved to Actions")
                }
            case .error(let message):
                Text(message).lineLimit(1).truncationMode(.tail)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!canSave || saveActionState == .saving)
        .help("Save the current goal as an Action you can re-run later.")
    }

    // MARK: Helpers

    private func pickedPersona(vm: GoalInputViewModel) -> PersonaSnapshot? {
        guard let id = vm.selectedPersonaID else { return nil }
        return vm.personas.first(where: { $0.id == id })
    }

    private func pickedChain(vm: GoalInputViewModel) -> ActionChainSnapshot? {
        guard let id = vm.selectedChainID else { return nil }
        return vm.chains.first(where: { $0.id == id })
    }

    private func firstChainGoal(chain: ActionChainSnapshot, vm: GoalInputViewModel) -> String {
        guard let firstStep = chain.steps.sorted(by: { $0.index < $1.index }).first,
              let actionID = firstStep.actionID,
              let action = vm.actions.first(where: { $0.id == actionID })
        else { return "—" }
        return action.promptText
    }

    private func personaInitials(_ name: String) -> String {
        let parts = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .compactMap { $0.first.map(String.init) }
        let joined = parts.prefix(2).joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

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

    /// Mirror the goalDraft to whatever action is currently picked, but
    /// only when the user hasn't typed something different yet — picking
    /// a new action shouldn't blow away an in-progress edit.
    private func syncGoalDraftWithSelectedAction(vm: GoalInputViewModel) {
        guard vm.source == .action,
              let id = vm.selectedActionID,
              let action = vm.actions.first(where: { $0.id == id })
        else { return }
        let draftTrimmed = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownPromptTrimmeds = vm.actions.map {
            $0.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if draftTrimmed.isEmpty || knownPromptTrimmeds.contains(draftTrimmed) {
            goalDraft = action.promptText
        }
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
        // For action runs, override the action's saved goal with whatever
        // the user typed in the goal card. Chain runs use per-leg goals,
        // unchanged.
        if case .singleAction(let actionID, _) = request.payload,
           !goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request = RunRequest(
                id: request.id,
                name: request.name,
                goal: goalDraft,
                persona: request.persona,
                applicationID: request.applicationID,
                personaID: request.personaID,
                payload: .singleAction(actionID: actionID, goal: goalDraft),
                project: request.project,
                simulator: request.simulator,
                model: request.model,
                mode: request.mode,
                stepBudget: request.stepBudget,
                tokenBudget: request.tokenBudget
            )
        }
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

    private func saveAsAction(vm: GoalInputViewModel) async {
        let trimmedGoal = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        let trimmedName = vm.runName.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredName: String = {
            if !trimmedName.isEmpty { return trimmedName }
            // First sentence (or first 60 chars) of the goal.
            let firstChunk = trimmedGoal
                .split(whereSeparator: { ".!?\n".contains($0) })
                .first.map(String.init) ?? trimmedGoal
            let cleaned = firstChunk.trimmingCharacters(in: .whitespaces)
            return cleaned.count <= 60 ? cleaned : String(cleaned.prefix(57)) + "…"
        }()

        saveActionState = .saving
        do {
            let snapshot = ActionSnapshot(
                id: UUID(),
                name: inferredName,
                promptText: trimmedGoal,
                notes: "",
                createdAt: .now,
                lastUsedAt: .now,
                archivedAt: nil
            )
            try await container.runHistory.upsert(snapshot)
            await vm.loadLibraries(store: container.runHistory)
            saveActionState = .saved
            // Snap back to idle after a short while so the button is
            // reusable. The user stays on the form — we don't navigate
            // away because they're still composing the run.
            try? await Task.sleep(for: .milliseconds(1500))
            if saveActionState == .saved {
                saveActionState = .idle
            }
        } catch {
            saveActionState = .error("Couldn't save")
            try? await Task.sleep(for: .milliseconds(2000))
            if case .error = saveActionState {
                saveActionState = .idle
            }
        }
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

// MARK: - RunSource label/symbol

private extension RunSource {
    var symbol: String {
        switch self {
        case .action: return "bolt.fill"
        case .chain:  return "arrow.right.to.line"
        }
    }
}

// MARK: - Source picker (Action or Chain)

private struct SourcePickerPanel: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var vm: GoalInputViewModel
    var body: some View {
        PanelContainer(title: vm.source == .action ? "Action" : "Chain") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                switch vm.source {
                case .action: actionPicker
                case .chain:  chainPicker
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

// MARK: - Persona picker

private struct PersonaPickerPanel: View {
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
                }
            }
            .padding(Theme.spacing.l)
        }
    }
}

// MARK: - Inline chain preview (ordered step list with broken-link warning)

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

// MARK: - Private NewRun-specific subviews

/// One read-only context cell — Application / Simulator / Persona.
private struct ContextCell: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.harnessAccentSoft)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.harnessAccent)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(HFont.mono(9))
                    .tracking(0.8)
                    .foregroundStyle(Color.harnessText4)
                Text(value)
                    .font(HFont.uiSemibold(12))
                    .foregroundStyle(Color.harnessText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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

/// Sparkles + label ghost button. Tapping prefills the goal textarea.
private struct ExampleChip: View {
    let text: String
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.harnessText4)
                Text(text)
                    .font(HFont.ui(11))
                    .foregroundStyle(Color.harnessText2)
            }
            .padding(.horizontal, Theme.spacing.s)
            .frame(height: 22)
            .background(Color.harnessPanel2)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.harnessLineStrong, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
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
