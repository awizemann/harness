//
//  ChainCreateView.swift
//  Harness
//
//  Sheet for adding a new Action Chain. Two fields — name + notes — and
//  an initial step list. Ships with one empty step slot prefilled to
//  nudge the user toward picking actions immediately. Detailed step
//  editing (drag-to-reorder, broken-link visualization) lives in
//  `ChainDetailView` once the chain has been saved.
//

import SwiftUI

struct ChainCreateView: View {

    @Environment(\.dismiss) private var dismiss

    let viewModel: ActionsViewModel
    var onCreated: (ActionChainSnapshot) -> Void = { _ in }

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var steps: [ActionChainStepSnapshot] = []
    @State private var saveError: String?
    @State private var isSaving: Bool = false
    @State private var hydrated: Bool = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    private var availableActions: [ActionSnapshot] {
        viewModel.actions.filter { !$0.archived }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    namePanel
                    notesPanel
                    stepsPanel
                    if let saveError {
                        Text(saveError)
                            .font(HFont.caption)
                            .foregroundStyle(Color.harnessWarning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.spacing.l)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 520)
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            // Ship one empty step so the user has somewhere to start.
            steps = [
                ActionChainStepSnapshot(
                    id: UUID(),
                    index: 0,
                    actionID: availableActions.first?.id,
                    preservesState: true
                )
            ]
        }
    }

    // MARK: Sub-views

    private var header: some View {
        HStack {
            Text("New chain")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.spacing.l)
        .padding(.top, Theme.spacing.l)
        .padding(.bottom, Theme.spacing.s)
    }

    private var namePanel: some View {
        PanelContainer(title: "Name") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                TextField("e.g. onboarding → first list → share", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Shown in pickers and history.")
                    .font(HFont.caption).foregroundStyle(Color.harnessText3)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var notesPanel: some View {
        PanelContainer(title: "Notes") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                TextEditor(text: $notes)
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
            .padding(Theme.spacing.l)
        }
    }

    private var stepsPanel: some View {
        PanelContainer(title: "Steps") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                if availableActions.isEmpty {
                    HStack(spacing: Theme.spacing.s) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.harnessAccent)
                        Text("No actions saved yet. Add a few from the Actions tab, then come back to wire them into a chain.")
                            .font(HFont.caption)
                            .foregroundStyle(Color.harnessText2)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.spacing.s)
                }
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    stepRow(idx: idx, step: step)
                }
                HStack {
                    Button {
                        steps.append(
                            ActionChainStepSnapshot(
                                id: UUID(),
                                index: steps.count,
                                actionID: availableActions.first?.id,
                                preservesState: true
                            )
                        )
                    } label: {
                        Label("Add step", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
            .padding(Theme.spacing.l)
        }
    }

    @ViewBuilder
    private func stepRow(idx: Int, step: ActionChainStepSnapshot) -> some View {
        HStack(spacing: Theme.spacing.s) {
            Text("\(idx + 1)")
                .font(HFont.micro)
                .foregroundStyle(Color.harnessAccentForeground)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.harnessAccent))
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
                steps.removeAll(where: { $0.id == step.id })
                renumber()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.harnessText3)
            }
            .buttonStyle(.borderless)
            .help("Remove step")
        }
        .padding(Theme.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.input)
                .fill(Color.harnessBg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.input)
                .stroke(Color.harnessLine, lineWidth: 0.5)
        )
    }

    private func actionBinding(for step: ActionChainStepSnapshot) -> Binding<UUID?> {
        Binding(
            get: { step.actionID },
            set: { newID in
                guard let i = steps.firstIndex(where: { $0.id == step.id }) else { return }
                steps[i] = ActionChainStepSnapshot(
                    id: step.id,
                    index: steps[i].index,
                    actionID: newID,
                    preservesState: steps[i].preservesState
                )
            }
        )
    }

    private func preservesStateBinding(for step: ActionChainStepSnapshot) -> Binding<Bool> {
        Binding(
            get: { step.preservesState },
            set: { newValue in
                guard let i = steps.firstIndex(where: { $0.id == step.id }) else { return }
                steps[i] = ActionChainStepSnapshot(
                    id: step.id,
                    index: steps[i].index,
                    actionID: steps[i].actionID,
                    preservesState: newValue
                )
            }
        )
    }

    private func renumber() {
        steps = steps.enumerated().map { idx, step in
            ActionChainStepSnapshot(
                id: step.id,
                index: idx,
                actionID: step.actionID,
                preservesState: step.preservesState
            )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Add Chain") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(Theme.spacing.l)
    }

    // MARK: Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            // Drop the placeholder empty step if the user never picked an
            // action for it — otherwise it would persist as a broken step
            // pointing at nothing.
            let cleaned = steps.filter { $0.actionID != nil }
            let snapshot = try await viewModel.createChain(
                name: name,
                notes: notes,
                steps: cleaned
            )
            saveError = nil
            onCreated(snapshot)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
