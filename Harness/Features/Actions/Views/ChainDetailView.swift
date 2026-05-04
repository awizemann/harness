//
//  ChainDetailView.swift
//  Harness
//
//  Detail pane for one Action Chain. Renders an editable ordered list of
//  steps with:
//  - drag-to-reorder via SwiftUI's `.onMove(perform:)`,
//  - per-step Action picker,
//  - per-step `preservesState` toggle,
//  - per-step delete button,
//  - "Add step" affordance at the bottom.
//
//  Validation surfaces inline:
//  - draft banner when the chain has zero steps,
//  - per-step broken-link warning (`FrictionTag(kind: .deadEnd)` styled
//    row) when `step.actionID` no longer resolves to a non-archived
//    Action.
//
//  Save is gated on the chain being dirty + having a non-empty name.
//  Future "Run" affordance is disabled when `brokenStepCount > 0` or
//  `steps.isEmpty`; Phase D doesn't ship that button yet, but the same
//  validation surface is the gate the New-Run flow will read.
//

import SwiftUI

struct ChainDetailView: View {

    let chain: ActionChainSnapshot
    let availableActions: [ActionSnapshot]
    let brokenStepCount: Int
    let onSave: (ActionChainSnapshot) -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var nameDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var stepsDraft: [ActionChainStepSnapshot] = []
    @State private var hydrated: Bool = false
    @State private var confirmDelete: Bool = false

    private var isDirty: Bool {
        nameDraft != chain.name
            || notesDraft != chain.notes
            || stepsDraft != chain.steps
    }

    private var canSave: Bool {
        isDirty && !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableActionsByID: [UUID: ActionSnapshot] {
        Dictionary(uniqueKeysWithValues: availableActions.map { ($0.id, $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.l) {
                headerBar
                if stepsDraft.isEmpty {
                    draftBanner
                }
                fieldsPanel
                stepsPanel
                metaPanel
            }
            .padding(Theme.spacing.xl)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.harnessBg)
        .navigationTitle(chain.name)
        .onAppear { hydrate() }
        .onChange(of: chain.id) { _, _ in hydrate(force: true) }
        .alert(
            "Delete chain?",
            isPresented: $confirmDelete
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the saved chain. Existing runs that used it stay in History but lose their chain link.")
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: Theme.spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.spacing.s) {
                    Text(chain.name).font(.title2.weight(.semibold))
                    if chain.archived {
                        archivedChip
                    }
                    if brokenStepCount > 0 {
                        brokenChip
                    }
                }
                Text("Last used \(formattedRelative(chain.lastUsedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let snapshot = ActionChainSnapshot(
                    id: chain.id,
                    name: nameDraft,
                    notes: notesDraft,
                    createdAt: chain.createdAt,
                    lastUsedAt: chain.lastUsedAt,
                    archivedAt: chain.archivedAt,
                    steps: stepsDraft
                )
                onSave(snapshot)
            } label: {
                Label("Save changes", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)

            Menu {
                if !chain.archived {
                    Button("Archive") { onArchive() }
                    Divider()
                }
                Button("Delete…", role: .destructive) {
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .frame(width: 32)
        }
    }

    private var archivedChip: some View {
        Text("ARCHIVED")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessWarning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.harnessWarning.opacity(0.16)))
    }

    private var brokenChip: some View {
        Text("\(brokenStepCount) BROKEN")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessFailure)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.harnessFailure.opacity(0.16)))
    }

    // MARK: Draft banner

    private var draftBanner: some View {
        HStack(spacing: Theme.spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harnessWarning)
            Text("This chain has no steps yet. Add at least one to make it runnable.")
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText2)
            Spacer()
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .fill(Color.harnessWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: Fields

    private var fieldsPanel: some View {
        PanelContainer(title: "Chain") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Name").font(HFont.caption).foregroundStyle(.secondary)
                    TextField("e.g. onboarding → first list → share", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Notes").font(HFont.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notesDraft)
                        .font(HFont.body)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.input)
                                .fill(Color.harnessBg2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.input)
                                .stroke(Color.harnessLine, lineWidth: 0.5)
                        )
                    Text("Optional. A reminder of what this chain tests.")
                        .font(HFont.caption).foregroundStyle(Color.harnessText3)
                }
            }
            .padding(Theme.spacing.l)
        }
    }

    // MARK: Steps

    private var stepsPanel: some View {
        PanelContainer(title: "Steps") {
            VStack(alignment: .leading, spacing: 0) {
                if stepsDraft.isEmpty {
                    HStack {
                        Text("Add the first step to start building this chain.")
                            .font(HFont.caption)
                            .foregroundStyle(Color.harnessText3)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.spacing.l)
                    .padding(.top, Theme.spacing.l)
                } else {
                    List {
                        ForEach(Array(stepsDraft.enumerated()), id: \.element.id) { idx, step in
                            stepRow(idx: idx, step: step)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(
                                    top: Theme.spacing.xs,
                                    leading: Theme.spacing.s,
                                    bottom: Theme.spacing.xs,
                                    trailing: Theme.spacing.s
                                ))
                        }
                        .onMove(perform: moveSteps)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: CGFloat(stepsDraft.count) * 96)
                }
                HStack {
                    Button {
                        addStep()
                    } label: {
                        Label("Add step", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(availableActions.isEmpty && stepsDraft.isEmpty == false)
                    Spacer()
                }
                .padding(Theme.spacing.l)
            }
        }
    }

    @ViewBuilder
    private func stepRow(idx: Int, step: ActionChainStepSnapshot) -> some View {
        let isBroken = step.actionID != nil && availableActionsByID[step.actionID!] == nil

        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            HStack(spacing: Theme.spacing.s) {
                stepIndexBadge(idx + 1)
                Picker("Action", selection: actionBinding(for: step)) {
                    Text("—").tag(UUID?.none)
                    ForEach(availableActions, id: \.id) { a in
                        Text(a.name).tag(UUID?.some(a.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(
                    "Preserve state",
                    isOn: preservesStateBinding(for: step)
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("If on, the simulator stays running between this step and the previous; otherwise the app reinstalls between steps.")
                Button(role: .destructive) {
                    removeStep(id: step.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.harnessText3)
                }
                .buttonStyle(.borderless)
                .help("Remove step")
            }
            if isBroken {
                HStack(spacing: Theme.spacing.s) {
                    FrictionTag(kind: .deadEnd)
                    Text("Action no longer exists. Replace or remove this step.")
                        .font(HFont.caption)
                        .foregroundStyle(Color.harnessText2)
                }
            }
        }
        .padding(Theme.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.input)
                .fill(Color.harnessBg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.input)
                .stroke(
                    isBroken ? Color.harnessFailure.opacity(0.40) : Color.harnessLine,
                    lineWidth: 0.5
                )
        )
    }

    private func stepIndexBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessAccentForeground)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.harnessAccent))
    }

    // MARK: Step bindings

    private func actionBinding(for step: ActionChainStepSnapshot) -> Binding<UUID?> {
        Binding(
            get: { step.actionID },
            set: { newID in
                guard let i = stepsDraft.firstIndex(where: { $0.id == step.id }) else { return }
                stepsDraft[i] = ActionChainStepSnapshot(
                    id: step.id,
                    index: stepsDraft[i].index,
                    actionID: newID,
                    preservesState: stepsDraft[i].preservesState
                )
            }
        )
    }

    private func preservesStateBinding(for step: ActionChainStepSnapshot) -> Binding<Bool> {
        Binding(
            get: { step.preservesState },
            set: { newValue in
                guard let i = stepsDraft.firstIndex(where: { $0.id == step.id }) else { return }
                stepsDraft[i] = ActionChainStepSnapshot(
                    id: step.id,
                    index: stepsDraft[i].index,
                    actionID: stepsDraft[i].actionID,
                    preservesState: newValue
                )
            }
        )
    }

    // MARK: Step mutations

    private func addStep() {
        let newStep = ActionChainStepSnapshot(
            id: UUID(),
            index: stepsDraft.count,
            actionID: availableActions.first?.id,
            preservesState: true
        )
        stepsDraft.append(newStep)
    }

    private func removeStep(id: UUID) {
        stepsDraft.removeAll(where: { $0.id == id })
        renumberSteps()
    }

    private func moveSteps(from source: IndexSet, to destination: Int) {
        stepsDraft.move(fromOffsets: source, toOffset: destination)
        renumberSteps()
    }

    private func renumberSteps() {
        stepsDraft = stepsDraft.enumerated().map { idx, step in
            ActionChainStepSnapshot(
                id: step.id,
                index: idx,
                actionID: step.actionID,
                preservesState: step.preservesState
            )
        }
    }

    // MARK: Meta panel

    private var metaPanel: some View {
        PanelContainer(title: "Metadata") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                metaRow(label: "Created", value: formattedAbsolute(chain.createdAt))
                metaRow(label: "Last used", value: formattedAbsolute(chain.lastUsedAt))
                if let archivedAt = chain.archivedAt {
                    metaRow(label: "Archived", value: formattedAbsolute(archivedAt))
                }
                metaRow(label: "Steps", value: "\(stepsDraft.count)")
                if brokenStepCount > 0 {
                    metaRow(label: "Broken steps", value: "\(brokenStepCount)")
                }
            }
            .padding(Theme.spacing.l)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(HFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value).font(HFont.body)
            Spacer()
        }
    }

    // MARK: Helpers

    private func hydrate(force: Bool = false) {
        guard !hydrated || force else { return }
        nameDraft = chain.name
        notesDraft = chain.notes
        stepsDraft = chain.steps
        hydrated = true
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func formattedAbsolute(_ date: Date) -> String {
        Self.absoluteFormatter.string(from: date)
    }

    private func formattedRelative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: .now)
    }
}
