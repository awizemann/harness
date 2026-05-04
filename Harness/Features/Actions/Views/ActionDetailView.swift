//
//  ActionDetailView.swift
//  Harness
//
//  Detail pane for one Action: name + prompt + notes editing, plus a
//  "Used in N chains" header chip and an overflow menu for Archive /
//  Delete. Deletion is confirmed via alert; the message warns when the
//  Action is referenced by chains.
//

import SwiftUI

struct ActionDetailView: View {

    let action: ActionSnapshot
    let referencingChains: [ActionChainSnapshot]
    let onSave: (ActionSnapshot) -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var nameDraft: String = ""
    @State private var promptDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var hydrated: Bool = false
    @State private var confirmDelete: Bool = false

    private var isDirty: Bool {
        nameDraft != action.name
            || promptDraft != action.promptText
            || notesDraft != action.notes
    }

    private var canSave: Bool {
        isDirty
            && !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.l) {
                headerBar
                fieldsPanel
                metaPanel
            }
            .padding(Theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.harnessBg)
        .navigationTitle(action.name)
        .onAppear { hydrate() }
        .onChange(of: action.id) { _, _ in hydrate(force: true) }
        .alert(
            "Delete action?",
            isPresented: $confirmDelete
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            if referencingChains.isEmpty {
                Text("This removes the saved action. Existing runs that used it stay in History but lose their action link.")
            } else {
                Text("This action is in \(referencingChains.count) \(referencingChains.count == 1 ? "chain" : "chains"). Deleting it will leave \(referencingChains.count) broken \(referencingChains.count == 1 ? "step" : "steps").")
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: Theme.spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.spacing.s) {
                    Text(action.name).font(.title2.weight(.semibold))
                    if !referencingChains.isEmpty {
                        chainCountChip
                    }
                    if action.archived {
                        archivedChip
                    }
                }
                Text("Last used \(formattedRelative(action.lastUsedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let snapshot = ActionSnapshot(
                    id: action.id,
                    name: nameDraft,
                    promptText: promptDraft,
                    notes: notesDraft,
                    createdAt: action.createdAt,
                    lastUsedAt: action.lastUsedAt,
                    archivedAt: action.archivedAt
                )
                onSave(snapshot)
            } label: {
                Label("Save changes", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)

            Menu {
                if !action.archived {
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

    private var chainCountChip: some View {
        Text("USED IN \(referencingChains.count) \(referencingChains.count == 1 ? "CHAIN" : "CHAINS")")
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

    // MARK: Fields

    private var fieldsPanel: some View {
        PanelContainer(title: "Action") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Name").font(HFont.caption).foregroundStyle(.secondary)
                    TextField("e.g. add 'milk' to my list", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    Text("Prompt").font(HFont.caption).foregroundStyle(.secondary)
                    TextEditor(text: $promptDraft)
                        .font(HFont.body)
                        .frame(minHeight: 200)
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
                    Text("Optional. A reminder of why this action exists.")
                        .font(HFont.caption).foregroundStyle(Color.harnessText3)
                }
            }
            .padding(Theme.spacing.l)
        }
    }

    private var metaPanel: some View {
        PanelContainer(title: "Metadata") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                metaRow(label: "Created", value: formattedAbsolute(action.createdAt))
                metaRow(label: "Last used", value: formattedAbsolute(action.lastUsedAt))
                if let archivedAt = action.archivedAt {
                    metaRow(label: "Archived", value: formattedAbsolute(archivedAt))
                }
                metaRow(
                    label: "In chains",
                    value: referencingChains.isEmpty
                        ? "—"
                        : referencingChains.map(\.name).joined(separator: ", ")
                )
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
            Text(value)
                .font(HFont.body)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
        }
    }

    // MARK: Helpers

    private func hydrate(force: Bool = false) {
        guard !hydrated || force else { return }
        nameDraft = action.name
        promptDraft = action.promptText
        notesDraft = action.notes
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
