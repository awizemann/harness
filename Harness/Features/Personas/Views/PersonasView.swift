//
//  PersonasView.swift
//  Harness
//
//  Library/detail HSplitView for the Personas section. Mirrors the shape
//  of `ApplicationsView` so the layout language is consistent across the
//  library tabs.
//

import SwiftUI
import AppKit

struct PersonasView: View {

    @Environment(AppContainer.self) private var container

    @State private var vm: PersonasViewModel?
    @State private var searchText: String = ""
    @State private var selectedID: UUID?
    @State private var showingCreateSheet: Bool = false
    @State private var showingArchived: Bool = false
    @State private var duplicateStarter: PersonaSnapshot?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = PersonasViewModel(store: container.runHistory)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: PersonasViewModel) -> some View {
        let visible = vm.filtered(search: searchText, includeArchived: showingArchived)
        let selected = visible.first { $0.id == selectedID } ?? visible.first

        Group {
            if vm.isLoading && vm.personas.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.personas.isEmpty {
                EmptyStateView(
                    symbol: "person.2",
                    title: "No personas yet",
                    subtitle: "Built-in personas seed automatically. Add custom personas for the user types you care about most.",
                    ctaTitle: "Add Persona",
                    onCta: { showingCreateSheet = true }
                )
            } else {
                HSplitView {
                    listColumn(vm: vm, personas: visible, selected: selected)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                    detailColumn(vm: vm, persona: selected)
                        .frame(minWidth: 480)
                }
            }
        }
        .navigationTitle("Personas")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter personas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("Add Persona…", systemImage: "plus")
                }
                .help("Add a Persona")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Show archived", isOn: $showingArchived)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show archived personas")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
            }
        }
        .task { await vm.reload() }
        .onChange(of: selected?.id) { _, newID in
            selectedID = newID
        }
        .sheet(isPresented: $showingCreateSheet) {
            PersonaCreateView(
                viewModel: vm,
                starter: nil,
                onCreated: { snapshot in
                    selectedID = snapshot.id
                }
            )
        }
        .sheet(item: $duplicateStarter) { source in
            PersonaCreateView(
                viewModel: vm,
                starter: source,
                onCreated: { snapshot in
                    selectedID = snapshot.id
                    duplicateStarter = nil
                }
            )
        }
    }

    // MARK: List column

    @ViewBuilder
    private func listColumn(
        vm: PersonasViewModel,
        personas: [PersonaSnapshot],
        selected: PersonaSnapshot?
    ) -> some View {
        VStack(spacing: 0) {
            if personas.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching personas",
                    subtitle: "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(personas, id: \.id) { p in
                            rowButton(vm: vm, persona: p, selected: p.id == selected?.id)
                        }
                    }
                }
            }
        }
        .background(Color.harnessPanel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.harnessLine).frame(width: 0.5)
        }
    }

    @ViewBuilder
    private func rowButton(vm: PersonasViewModel, persona: PersonaSnapshot, selected: Bool) -> some View {
        Button {
            selectedID = persona.id
        } label: {
            PersonaRow(persona: persona, selected: selected)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Duplicate") {
                duplicateStarter = persona
            }
            if !persona.isBuiltIn && persona.archivedAt == nil {
                Divider()
                Button("Archive") {
                    Task { await vm.archive(id: persona.id) }
                }
                Button("Delete…", role: .destructive) {
                    Task { await vm.delete(id: persona.id) }
                }
            } else if persona.isBuiltIn {
                Divider()
                Button("Archive") {
                    Task { await vm.archive(id: persona.id) }
                }
            }
        }
    }

    // MARK: Detail column

    @ViewBuilder
    private func detailColumn(vm: PersonasViewModel, persona: PersonaSnapshot?) -> some View {
        if let persona {
            PersonaDetailView(
                persona: persona,
                onSave: { snapshot in
                    Task {
                        do {
                            try await vm.update(snapshot)
                        } catch {
                            // Validation failure surfaces in lastError; the
                            // detail view can read it on the next render.
                        }
                    }
                },
                onDuplicate: {
                    duplicateStarter = persona
                },
                onArchive: {
                    Task { await vm.archive(id: persona.id) }
                },
                onDelete: {
                    Task { await vm.delete(id: persona.id) }
                }
            )
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Select a persona",
                subtitle: "Pick any row on the left to inspect its prompt and metadata."
            )
        }
    }
}

// MARK: - Row

private struct PersonaRow: View {
    let persona: PersonaSnapshot
    let selected: Bool

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.spacing.s) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(Color.harnessAccent)
                Text(persona.name)
                    .font(HFont.row)
                    .foregroundStyle(Color.harnessText)
                Spacer(minLength: 0)
                if persona.isBuiltIn {
                    builtInChip
                } else if persona.archived {
                    archivedChip
                }
            }
            if !persona.blurb.isEmpty {
                Text(persona.blurb)
                    .font(HFont.caption)
                    .foregroundStyle(Color.harnessText3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        // Hit-test the row's whole frame edge-to-edge; selected state
        // wins over hover; matches `ApplicationRow`'s pattern so the
        // three library lists feel identical to interact with.
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5)
        }
        .animation(Theme.motion.micro, value: isHovered)
        .animation(Theme.motion.micro, value: selected)
    }

    private var rowBackground: Color {
        if selected { return Color.harnessAccentSoft }
        if isHovered { return Color.harnessAccent.opacity(0.06) }
        return .clear
    }

    private var builtInChip: some View {
        Text("BUILT-IN")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.harnessAccentSoft))
    }

    private var archivedChip: some View {
        Text("ARCHIVED")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessWarning)
    }
}

// MARK: - Sheet identifier

extension PersonaSnapshot: Identifiable {}
