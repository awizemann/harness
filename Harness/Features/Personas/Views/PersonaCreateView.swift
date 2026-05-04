//
//  PersonaCreateView.swift
//  Harness
//
//  Sheet for adding a new persona. Supports prefilling from any existing
//  persona (typically a built-in) so the user can clone a starting point
//  before editing.
//

import SwiftUI

struct PersonaCreateView: View {

    @Environment(\.dismiss) private var dismiss

    let viewModel: PersonasViewModel
    /// Optional starter — when non-nil, the form's name/blurb/prompt fields
    /// prefill from this persona. Useful when "Duplicate to edit" routes
    /// through the create sheet rather than calling `duplicate(_:)` directly.
    var starter: PersonaSnapshot?
    var onCreated: (PersonaSnapshot) -> Void = { _ in }

    @State private var name: String = ""
    @State private var blurb: String = ""
    @State private var promptText: String = ""
    @State private var saveError: String?
    @State private var isSaving: Bool = false
    @State private var hydrated: Bool = false

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
                    starterPanel
                    namePanel
                    blurbPanel
                    promptPanel
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
            if let starter {
                name = "\(starter.name) (copy)"
                blurb = starter.blurb
                promptText = starter.promptText
            }
        }
    }

    // MARK: Sub-views

    private var header: some View {
        HStack {
            Text(starter == nil ? "New persona" : "Duplicate persona")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.spacing.l)
        .padding(.top, Theme.spacing.l)
        .padding(.bottom, Theme.spacing.s)
    }

    @ViewBuilder
    private var starterPanel: some View {
        if starter == nil {
            PanelContainer(title: "Start from a built-in") {
                VStack(alignment: .leading, spacing: Theme.spacing.s) {
                    Text("Pick any persona as a starting point. You can edit every field afterwards.")
                        .font(HFont.caption)
                        .foregroundStyle(Color.harnessText3)
                    Picker("", selection: starterBinding) {
                        Text("Blank").tag(UUID?.none)
                        ForEach(viewModel.personas.filter { !$0.archived }, id: \.id) { p in
                            Text(p.isBuiltIn ? "\(p.name) (built-in)" : p.name)
                                .tag(UUID?.some(p.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(Theme.spacing.l)
            }
        }
    }

    private var starterBinding: Binding<UUID?> {
        Binding(
            get: { nil },
            set: { newID in
                guard let id = newID,
                      let p = viewModel.personas.first(where: { $0.id == id }) else { return }
                name = p.name
                blurb = p.blurb
                promptText = p.promptText
            }
        )
    }

    private var namePanel: some View {
        PanelContainer(title: "Name") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                TextField("e.g. cautious shopper", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Shown in pickers and the runs sidebar.")
                    .font(HFont.caption).foregroundStyle(Color.harnessText3)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var blurbPanel: some View {
        PanelContainer(title: "Blurb") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                TextField("One-liner that summarizes this persona", text: $blurb)
                    .textFieldStyle(.roundedBorder)
                Text("Optional. Shown under the name in the persona list.")
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
                    .frame(minHeight: 140)
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
                Text("Substituted into the system prompt at the {{PERSONA}} placeholder.")
                    .font(HFont.caption).foregroundStyle(Color.harnessText3)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Add Persona") {
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
            let snapshot = try await viewModel.create(
                name: name,
                blurb: blurb,
                promptText: promptText
            )
            saveError = nil
            onCreated(snapshot)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
