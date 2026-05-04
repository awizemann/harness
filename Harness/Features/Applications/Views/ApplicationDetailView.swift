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
                ProjectPanel(
                    application: application,
                    onRePickProject: onRePickProject
                )
                SimulatorPanel(
                    application: application,
                    onChange: { sim in
                        var updated = application
                        updated = ApplicationSnapshot(
                            id: updated.id,
                            name: updated.name,
                            createdAt: updated.createdAt,
                            lastUsedAt: Date(),
                            archivedAt: updated.archivedAt,
                            projectPath: updated.projectPath,
                            projectBookmark: updated.projectBookmark,
                            scheme: updated.scheme,
                            defaultSimulatorUDID: sim.udid,
                            defaultSimulatorName: sim.name,
                            defaultSimulatorRuntime: sim.runtime,
                            defaultModelRaw: updated.defaultModelRaw,
                            defaultModeRaw: updated.defaultModeRaw,
                            defaultStepBudget: updated.defaultStepBudget
                        )
                        onUpdateDefaults(updated)
                    }
                )
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

private struct DefaultsPanel: View {
    let application: ApplicationSnapshot
    let onUpdateDefaults: (ApplicationSnapshot) -> Void

    @State private var model: AgentModel = .opus47
    @State private var mode: RunMode = .stepByStep
    @State private var stepBudget: Int = 40
    @State private var hydrated: Bool = false

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
                    Stepper(value: $stepBudget, in: 5...200) {
                        Text("\(stepBudget) steps")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 200, alignment: .leading)
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
            projectPath: application.projectPath,
            projectBookmark: application.projectBookmark,
            scheme: application.scheme,
            defaultSimulatorUDID: application.defaultSimulatorUDID,
            defaultSimulatorName: application.defaultSimulatorName,
            defaultSimulatorRuntime: application.defaultSimulatorRuntime,
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
