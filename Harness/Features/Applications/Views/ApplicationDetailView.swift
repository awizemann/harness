//
//  ApplicationDetailView.swift
//  Harness
//
//  Detail pane for one Application: Project / Default simulator / Run
//  defaults / Recent runs panels, plus a header strip with name + active
//  toggle + overflow menu.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ApplicationDetailView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppState.self) private var state

    let application: ApplicationSnapshot
    let recentRuns: [RunRecordSnapshot]
    let onSetActive: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onUpdateDefaults: (ApplicationSnapshot) -> Void
    let onRePickProject: () -> Void

    @State private var nameDraft: String = ""
    @State private var isEditingName: Bool = false
    @State private var confirmDelete: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.l) {
                headerBar
                // Per-platform "where does this run?" section. iOS keeps
                // its Project + Default-simulator panels (existing).
                // macOS shows whichever launch source the user picked
                // at create time — pre-built bundle panel OR project +
                // scheme. Web shows URL + viewport. None of the three
                // shows the iOS simulator picker (was rendering a useless
                // 'No simulator picked' card for macOS / web Applications).
                switch application.platformKind {
                case .iosSimulator:
                    ProjectPanel(
                        application: application,
                        onRePickProject: onRePickProject
                    )
                    SimulatorPanel(
                        application: application,
                        onChange: { sim in
                            onUpdateDefaults(application.withSimulator(sim))
                        }
                    )
                case .macosApp:
                    if (application.macAppBundlePath ?? "").isEmpty {
                        // xcodebuild-from-project mode — same Project panel
                        // shape as iOS, sans the simulator step.
                        ProjectPanel(
                            application: application,
                            onRePickProject: onRePickProject
                        )
                    } else {
                        MacBundlePanel(
                            application: application,
                            onUpdateDefaults: onUpdateDefaults
                        )
                    }
                case .web:
                    WebPanel(
                        application: application,
                        onUpdateDefaults: onUpdateDefaults
                    )
                }
                DefaultsPanel(
                    application: application,
                    onUpdateDefaults: onUpdateDefaults
                )
                RecentRunsPanel(
                    application: application,
                    runs: recentRuns
                )
            }
            .padding(Theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.harnessBg)
        .navigationTitle(application.name)
        .alert(
            "Delete Application?",
            isPresented: $confirmDelete
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the saved Application. Existing runs stay in History but lose their Application link.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: Theme.spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditingName {
                    HStack(spacing: Theme.spacing.s) {
                        TextField("Application name", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .onSubmit { commitRename() }
                        Button("Save") { commitRename() }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { cancelRename() }
                    }
                } else {
                    HStack(spacing: Theme.spacing.s) {
                        Text(application.name).font(.title2.weight(.semibold))
                        Button {
                            beginRename()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename")
                    }
                }
                Text(application.archived ? "Archived" : "Active library entry")
                    .font(.caption)
                    .foregroundStyle(application.archived ? Color.harnessWarning : .secondary)
            }
            Spacer()
            if isActive {
                StatusChip(kind: .done)
                Text("Active scope")
                    .font(.callout)
                    .foregroundStyle(Color.harnessSuccess)
            } else {
                Button {
                    onSetActive()
                } label: {
                    Label("Set as active", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Archive") { onArchive() }
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .frame(width: 32)
        }
    }

    private var isActive: Bool {
        coordinator.selectedApplicationID == application.id
    }

    private func beginRename() {
        nameDraft = application.name
        isEditingName = true
    }

    private func cancelRename() {
        nameDraft = application.name
        isEditingName = false
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != application.name else {
            isEditingName = false
            return
        }
        onRename(trimmed)
        isEditingName = false
    }
}

// MARK: - Snapshot helpers

private extension ApplicationSnapshot {
    /// Return a copy with a different default simulator. Keeps every
    /// other field intact so callers don't have to write the long
    /// memberwise rebuild on every panel.
    func withSimulator(_ sim: SimulatorRef) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: id,
            name: name,
            createdAt: createdAt,
            lastUsedAt: Date(),
            archivedAt: archivedAt,
            platformKindRaw: platformKindRaw,
            projectPath: projectPath,
            projectBookmark: projectBookmark,
            scheme: scheme,
            defaultSimulatorUDID: sim.udid,
            defaultSimulatorName: sim.name,
            defaultSimulatorRuntime: sim.runtime,
            macAppBundlePath: macAppBundlePath,
            macAppBundleBookmark: macAppBundleBookmark,
            webStartURL: webStartURL,
            webViewportWidthPt: webViewportWidthPt,
            webViewportHeightPt: webViewportHeightPt,
            defaultModelRaw: defaultModelRaw,
            defaultModeRaw: defaultModeRaw,
            defaultStepBudget: defaultStepBudget
        )
    }

    /// Replace the macOS pre-built bundle path. Clears any project
    /// fields so the Application stays in a single launch-source state.
    func withMacBundlePath(_ path: String?) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: id,
            name: name,
            createdAt: createdAt,
            lastUsedAt: Date(),
            archivedAt: archivedAt,
            platformKindRaw: platformKindRaw,
            projectPath: "",
            projectBookmark: nil,
            scheme: "",
            defaultSimulatorUDID: nil,
            defaultSimulatorName: nil,
            defaultSimulatorRuntime: nil,
            macAppBundlePath: path,
            macAppBundleBookmark: nil,
            webStartURL: webStartURL,
            webViewportWidthPt: webViewportWidthPt,
            webViewportHeightPt: webViewportHeightPt,
            defaultModelRaw: defaultModelRaw,
            defaultModeRaw: defaultModeRaw,
            defaultStepBudget: defaultStepBudget
        )
    }

    /// Replace the web Application's start URL + viewport.
    func withWeb(url: String, width: Int, height: Int) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: id,
            name: name,
            createdAt: createdAt,
            lastUsedAt: Date(),
            archivedAt: archivedAt,
            platformKindRaw: platformKindRaw,
            projectPath: "",
            projectBookmark: nil,
            scheme: "",
            defaultSimulatorUDID: nil,
            defaultSimulatorName: nil,
            defaultSimulatorRuntime: nil,
            macAppBundlePath: nil,
            macAppBundleBookmark: nil,
            webStartURL: url,
            webViewportWidthPt: width,
            webViewportHeightPt: height,
            defaultModelRaw: defaultModelRaw,
            defaultModeRaw: defaultModeRaw,
            defaultStepBudget: defaultStepBudget
        )
    }
}

// MARK: - Panels

private struct ProjectPanel: View {
    let application: ApplicationSnapshot
    let onRePickProject: () -> Void

    var body: some View {
        PanelContainer(title: "Project") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                HStack(spacing: Theme.spacing.s) {
                    Image(systemName: "hammer.fill").foregroundStyle(Color.harnessAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(application.projectURL.lastPathComponent).font(.body)
                        Text(application.projectPath).font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Re-pick project…") {
                        onRePickProject()
                    }
                    .buttonStyle(.borderless)
                }
                HStack(spacing: Theme.spacing.s) {
                    Text("Scheme").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(application.scheme.isEmpty ? "—" : application.scheme)
                        .font(HFont.mono)
                }
            }
            .padding(Theme.spacing.l)
        }
    }
}

private struct SimulatorPanel: View {
    @Environment(AppState.self) private var state
    let application: ApplicationSnapshot
    let onChange: (SimulatorRef) -> Void

    var body: some View {
        PanelContainer(title: "Default simulator") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                HStack(spacing: Theme.spacing.s) {
                    Image(systemName: "iphone.gen3").foregroundStyle(Color.harnessAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(application.defaultSimulatorName ?? "No simulator picked")
                            .font(.body)
                        Text(application.defaultSimulatorRuntime ?? "")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Menu {
                        if state.simulators.isEmpty {
                            Text("No simulators")
                        } else {
                            ForEach(state.simulators, id: \.udid) { sim in
                                Button("\(sim.name) · \(sim.runtime)") {
                                    onChange(sim)
                                }
                            }
                        }
                        Divider()
                        Button("Refresh list") {
                            Task { await state.refreshSimulators() }
                        }
                    } label: {
                        Text("Change…")
                    }
                }
                if let udid = application.defaultSimulatorUDID, !udid.isEmpty {
                    Text(udid).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(Theme.spacing.l)
        }
    }
}

/// macOS pre-built `.app` panel — shown when the Application's launch
/// source is the bundle path (i.e. `macAppBundlePath` non-empty).
/// Mirrors `MacBundlePicker` from the create form: filename + path,
/// Change… / Clear buttons.
private struct MacBundlePanel: View {
    let application: ApplicationSnapshot
    let onUpdateDefaults: (ApplicationSnapshot) -> Void

    var body: some View {
        PanelContainer(title: "Launch source · pre-built .app") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                HStack(spacing: Theme.spacing.s) {
                    Image(systemName: "macwindow")
                        .foregroundStyle(Color.harnessAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((application.macAppBundlePath ?? "") .isEmpty
                             ? "—"
                             : ((application.macAppBundlePath ?? "") as NSString).lastPathComponent)
                            .font(.body)
                        Text(application.macAppBundlePath ?? "")
                            .font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") {
                        if let path = pickAppBundle() {
                            onUpdateDefaults(application.withMacBundlePath(path))
                        }
                    }
                }
                Text("Harness launches this bundle via NSWorkspace and skips xcodebuild.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.l)
        }
    }

    private func pickAppBundle() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.title = "Pick a macOS app bundle"
        panel.prompt = "Pick"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Web Application panel — shown for `.web` Applications. URL +
/// viewport editor; saves through `onUpdateDefaults` on commit.
private struct WebPanel: View {
    let application: ApplicationSnapshot
    let onUpdateDefaults: (ApplicationSnapshot) -> Void

    @State private var urlDraft: String = ""
    @State private var widthDraft: Int = 1280
    @State private var heightDraft: Int = 800
    @State private var hydrated: Bool = false

    var body: some View {
        PanelContainer(title: "Web target") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                VStack(alignment: .leading, spacing: Theme.spacing.s) {
                    Text("Start URL").font(.callout.weight(.medium))
                    TextField("https://example.com/login", text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(commitIfValid)
                    Text("The agent loads this URL on first step. Cookies persist across legs in the same run.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: Theme.spacing.l) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Viewport width (px)").font(.callout.weight(.medium))
                        TextField("1280", value: $widthDraft, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit(commitIfValid)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Viewport height (px)").font(.callout.weight(.medium))
                        TextField("800", value: $heightDraft, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit(commitIfValid)
                    }
                    Spacer()
                    Button("Save") { commitIfValid() }
                        .buttonStyle(.bordered)
                        .disabled(!hasUnsavedChanges)
                }
            }
            .padding(Theme.spacing.l)
        }
        .onAppear { hydrate() }
        .onChange(of: application.id) { _, _ in hydrate(force: true) }
    }

    private var hasUnsavedChanges: Bool {
        guard hydrated else { return false }
        return urlDraft != (application.webStartURL ?? "")
            || widthDraft != (application.webViewportWidthPt ?? 1280)
            || heightDraft != (application.webViewportHeightPt ?? 800)
    }

    private func hydrate(force: Bool = false) {
        guard !hydrated || force else { return }
        urlDraft = application.webStartURL ?? ""
        widthDraft = application.webViewportWidthPt ?? 1280
        heightDraft = application.webViewportHeightPt ?? 800
        hydrated = true
    }

    private func commitIfValid() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
        onUpdateDefaults(application.withWeb(url: trimmed, width: widthDraft, height: heightDraft))
    }
}

private struct DefaultsPanel: View {
    @Environment(AppState.self) private var state
    let application: ApplicationSnapshot
    let onUpdateDefaults: (ApplicationSnapshot) -> Void

    @State private var model: AgentModel = .opus47
    @State private var mode: RunMode = .stepByStep
    @State private var stepBudget: Int = 40
    @State private var hydrated: Bool = false
    /// Last finite step budget, restored when the user toggles
    /// "Unlimited" off again.
    @State private var lastFiniteStepBudget: Int = 40

    /// Providers whose model section should appear in the picker. See
    /// the matching computed in `ApplicationCreateView.DefaultsSection`
    /// for the rationale.
    private var providersToShow: [ModelProvider] {
        let configured = ModelProvider.allCases.filter { state.apiKeyPresent(for: $0) }
        if configured.isEmpty { return ModelProvider.allCases }
        if configured.contains(model.provider) { return configured }
        return ModelProvider.allCases.filter {
            configured.contains($0) || $0 == model.provider
        }
    }

    private var unlimitedBinding: Binding<Bool> {
        Binding<Bool>(
            get: { stepBudget == RunRequest.unlimitedStepBudget },
            set: { newValue in
                if newValue {
                    if stepBudget > 0 { lastFiniteStepBudget = stepBudget }
                    stepBudget = RunRequest.unlimitedStepBudget
                } else {
                    stepBudget = max(5, lastFiniteStepBudget)
                }
            }
        )
    }

    var body: some View {
        PanelContainer(title: "Run defaults") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                HStack(spacing: Theme.spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text("Mode").font(.subheadline.weight(.medium))
                        Picker("", selection: $mode) {
                            Text("Step-by-step").tag(RunMode.stepByStep)
                            Text("Autonomous").tag(RunMode.autonomous)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text("Model").font(.subheadline.weight(.medium))
                        Picker("", selection: $model) {
                            ForEach(providersToShow, id: \.self) { provider in
                                Section(provider.displayName) {
                                    ForEach(AgentModel.allCases.filter { $0.provider == provider }, id: \.self) { m in
                                        Text(m.displayName).tag(m)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                }
                HStack {
                    Text("Step budget").frame(width: 110, alignment: .leading)
                    Toggle("Unlimited", isOn: unlimitedBinding)
                        .toggleStyle(.checkbox)
                    if stepBudget != RunRequest.unlimitedStepBudget {
                        Stepper(value: $stepBudget, in: 5...200) {
                            Text("\(stepBudget) steps")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 200, alignment: .leading)
                    } else {
                        Text("∞ — only the token budget caps this run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Override the global defaults set in Settings.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.l)
        }
        .onAppear { hydrate() }
        .onChange(of: application.id) { _, _ in hydrate(force: true) }
        .onChange(of: model) { _, new in commitIfHydrated(model: new) }
        .onChange(of: mode) { _, new in commitIfHydrated(mode: new) }
        .onChange(of: stepBudget) { _, new in commitIfHydrated(stepBudget: new) }
    }

    private func hydrate(force: Bool = false) {
        guard !hydrated || force else { return }
        model = application.defaultModel ?? .opus47
        mode = application.defaultMode ?? .stepByStep
        stepBudget = application.defaultStepBudget
        hydrated = true
    }

    private func commitIfHydrated(
        model newModel: AgentModel? = nil,
        mode newMode: RunMode? = nil,
        stepBudget newStepBudget: Int? = nil
    ) {
        guard hydrated else { return }
        let m = newModel ?? model
        let md = newMode ?? mode
        let sb = newStepBudget ?? stepBudget
        // No-op if nothing actually changed.
        if m.rawValue == application.defaultModelRaw,
           md.rawValue == application.defaultModeRaw,
           sb == application.defaultStepBudget {
            return
        }
        let updated = ApplicationSnapshot(
            id: application.id,
            name: application.name,
            createdAt: application.createdAt,
            lastUsedAt: application.lastUsedAt,
            archivedAt: application.archivedAt,
            platformKindRaw: application.platformKindRaw,
            projectPath: application.projectPath,
            projectBookmark: application.projectBookmark,
            scheme: application.scheme,
            defaultSimulatorUDID: application.defaultSimulatorUDID,
            defaultSimulatorName: application.defaultSimulatorName,
            defaultSimulatorRuntime: application.defaultSimulatorRuntime,
            macAppBundlePath: application.macAppBundlePath,
            macAppBundleBookmark: application.macAppBundleBookmark,
            webStartURL: application.webStartURL,
            webViewportWidthPt: application.webViewportWidthPt,
            webViewportHeightPt: application.webViewportHeightPt,
            defaultModelRaw: m.rawValue,
            defaultModeRaw: md.rawValue,
            defaultStepBudget: sb
        )
        onUpdateDefaults(updated)
    }
}

private struct RecentRunsPanel: View {
    @Environment(AppCoordinator.self) private var coordinator
    let application: ApplicationSnapshot
    let runs: [RunRecordSnapshot]

    var body: some View {
        PanelContainer(title: "Recent runs") {
            VStack(alignment: .leading, spacing: 0) {
                if runs.isEmpty {
                    HStack {
                        Text("No runs yet for this Application.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(Theme.spacing.l)
                } else {
                    ForEach(runs, id: \.id) { run in
                        Button {
                            coordinator.openReplay(runID: run.id)
                        } label: {
                            HStack(spacing: Theme.spacing.s) {
                                VerdictPill(verdict: PreviewVerdict(verdictOrBlocked(run)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.name ?? run.goal)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(formatted(run.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("\(run.stepCount) steps")
                                    .font(HFont.mono)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.spacing.l)
                            .padding(.vertical, Theme.spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func verdictOrBlocked(_ run: RunRecordSnapshot) -> Verdict {
        run.verdict ?? .blocked
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formatted(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }
}
