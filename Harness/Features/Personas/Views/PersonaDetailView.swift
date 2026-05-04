//
//  PersonaDetailView.swift
//  Harness
//
//  Detail pane for one persona. Built-in personas render in a read-only
//  state with a "Duplicate to edit" prompt; custom personas expose
//  editable fields, Save, Archive, and Delete.
//

import SwiftUI

struct PersonaDetailView: View {

    let persona: PersonaSnapshot
    let onSave: (PersonaSnapshot) -> Void
    let onDuplicate: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var nameDraft: String = ""
    @State private var blurbDraft: String = ""
    @State private var promptDraft: String = ""
    @State private var hydrated: Bool = false
    @State private var confirmDelete: Bool = false

    private var isBuiltIn: Bool { persona.isBuiltIn }

    private var isDirty: Bool {
        guard !isBuiltIn else { return false }
        return nameDraft != persona.name
            || blurbDraft != persona.blurb
            || promptDraft != persona.promptText
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.l) {
                headerBar
                if isBuiltIn {
                    builtInCallout
                }
                fieldsPanel
                metaPanel
            }
            .padding(Theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.harnessBg)
        .navigationTitle(persona.name)
        .onAppear { hydrate() }
        .onChange(of: persona.id) { _, _ in hydrate(force: true) }
        .alert(
            "Delete persona?",
            isPresented: $confirmDelete
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the saved persona. Existing runs that used it stay in History but lose their persona link.")
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: Theme.spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.spacing.s) {
                    Text(persona.name).font(.title2.weight(.semibold))
                    if isBuiltIn {
                        builtInChip
                    }
                    if persona.archived {
                        archivedChip
                    }
                }
                Text("Last used \(formattedRelative(persona.lastUsedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            primaryButton
            Menu {
                Button("Archive") { onArchive() }
                if !isBuiltIn {
                    Divider()
                    Button("Delete…", role: .destructive) {
                        confirmDelete = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .frame(width: 32)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isBuiltIn {
            Button {
                onDuplicate()
            } label: {
                Label("Duplicate to edit", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                let snapshot = PersonaSnapshot(
                    id: persona.id,
                    name: nameDraft,
                    blurb: blurbDraft,
                    promptText: promptDraft,
                    isBuiltIn: false,
                    createdAt: persona.createdAt,
                    lastUsedAt: persona.lastUsedAt,
                    archivedAt: persona.archivedAt
                )
                onSave(snapshot)
            } label: {
                Label("Save changes", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty)
        }
    }

    private var builtInChip: some View {
        Text("BUILT-IN")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.harnessAccentSoft))
    }

    private var archivedChip: some View {
        Text("ARCHIVED")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessWarning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.harnessWarning.opacity(0.16)))
    }

    // MARK: Built-in callout

    private var builtInCallout: some View {
        HStack(spacing: Theme.spacing.s) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.harnessAccent)
            Text("Built-in personas can't be edited. Duplicate to make changes.")
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText2)
            Spacer()
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .fill(Color.harnessAccentSoft)
        )
    }

    // MARK: Fields

    private var fieldsPanel: some View {
        PanelContainer(title: "Persona") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Name").font(HFont.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBuiltIn)
                }
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Blurb").font(HFont.caption).foregroundStyle(.secondary)
                    TextField("One-line summary", text: $blurbDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBuiltIn)
                }
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Prompt").font(HFont.caption).foregroundStyle(.secondary)
                    TextEditor(text: $promptDraft)
                        .font(HFont.body)
                        .frame(minHeight: 220)
                        .disabled(isBuiltIn)
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
            }
            .padding(Theme.spacing.l)
        }
    }

    private var metaPanel: some View {
        PanelContainer(title: "Metadata") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                metaRow(label: "Created", value: formattedAbsolute(persona.createdAt))
                metaRow(label: "Last used", value: formattedAbsolute(persona.lastUsedAt))
                if let archivedAt = persona.archivedAt {
                    metaRow(label: "Archived", value: formattedAbsolute(archivedAt))
                }
                metaRow(label: "Source", value: isBuiltIn ? "Built-in (seeded)" : "Custom")
            }
            .padding(Theme.spacing.l)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
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
        nameDraft = persona.name
        blurbDraft = persona.blurb
        promptDraft = persona.promptText
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
