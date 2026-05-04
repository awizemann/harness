//
//  ActionCreateView.swift
//  Harness
//
//  Sheet for adding a new Action. Three fields — name, prompt, notes —
//  validated client-side: name + prompt required.
//

import SwiftUI

struct ActionCreateView: View {

    @Environment(\.dismiss) private var dismiss

    let viewModel: ActionsViewModel
    var onCreated: (ActionSnapshot) -> Void = { _ in }

    @State private var name: String = ""
    @State private var promptText: String = ""
    @State private var notes: String = ""
    @State private var saveError: String?
    @State private var isSaving: Bool = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    namePanel
                    promptPanel
                    notesPanel
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
    }

    // MARK: Sub-views

    private var header: some View {
        HStack {
            Text("New action")
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
                TextField("e.g. add 'milk' to my list", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Shown in pickers and chains.")
                    .font(HFont.caption).foregroundStyle(Color.harnessText3)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var promptPanel: some View {
        PanelContainer(title: "Prompt") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                TextEditor(text: $promptText)
                    .font(HFont.body)
                    .frame(minHeight: 160)
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
                Text("Substituted into the system prompt at the {{GOAL}} placeholder.")
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
                Text("Optional. A reminder of why this action exists.")
                    .font(HFont.caption).foregroundStyle(Color.harnessText3)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Add Action") {
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
            let snapshot = try await viewModel.createAction(
                name: name,
                promptText: promptText,
                notes: notes
            )
            saveError = nil
            onCreated(snapshot)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
