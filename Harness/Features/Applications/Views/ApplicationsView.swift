//
//  ApplicationsView.swift
//  Harness
//
//  Library/detail HSplitView for the Applications section. Mirrors the
//  shape of `RunHistoryView` so the layout language is consistent across the
//  library tabs.
//

import SwiftUI
import AppKit

struct ApplicationsView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppState.self) private var state

    @State private var vm: ApplicationsViewModel?
    @State private var searchText: String = ""
    @State private var selectedID: UUID?
    @State private var showingCreateSheet: Bool = false
    @State private var showingArchived: Bool = false
    @State private var rePickPicker: ProjectPicker?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = ApplicationsViewModel(
                        store: container.runHistory,
                        coordinator: coordinator,
                        appState: state
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: ApplicationsViewModel) -> some View {
        let filtered = vm.filtered(search: searchText)
        let visible = showingArchived ? filtered : filtered.filter { !$0.archived }
        let selected = visible.first { $0.id == selectedID } ?? visible.first

        Group {
            if vm.isLoading && vm.applications.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.applications.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: "No applications yet",
                    subtitle: "Save your iOS project so you can run user tests against it without re-picking each time.",
                    ctaTitle: "Add Application",
                    onCta: { showingCreateSheet = true }
                )
            } else {
                HSplitView {
                    listColumn(vm: vm, applications: visible, selected: selected)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                    detailColumn(vm: vm, application: selected)
                        .frame(minWidth: 480)
                }
            }
        }
        .navigationTitle("Applications")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("Add Application", systemImage: "plus")
                }
                .help("Add an Application")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.reload(includeArchived: showingArchived) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
            }
        }
        .task { await vm.reload(includeArchived: showingArchived) }
        .onChange(of: showingArchived) { _, _ in
            Task { await vm.reload(includeArchived: showingArchived) }
        }
        .onChange(of: selected?.id) { _, newID in
            selectedID = newID
            if let id = newID {
                Task { await vm.loadRecentRuns(for: id) }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            ApplicationCreateView(applicationsVM: vm)
        }
        .sheet(item: Binding<RePickContext?>(
            get: { rePickPicker.flatMap { _ in selected.map { RePickContext(application: $0) } } },
            set: { _ in rePickPicker = nil }
        )) { ctx in
            if let picker = rePickPicker {
                RePickProjectSheet(
                    picker: picker,
                    application: ctx.application,
                    onSave: { newPath, newScheme in
                        Task {
                            let updated = ApplicationSnapshot(
                                id: ctx.application.id,
                                name: ctx.application.name,
                                createdAt: ctx.application.createdAt,
                                lastUsedAt: Date(),
                                archivedAt: ctx.application.archivedAt,
                                projectPath: newPath,
                                projectBookmark: nil,
                                scheme: newScheme,
                                defaultSimulatorUDID: ctx.application.defaultSimulatorUDID,
                                defaultSimulatorName: ctx.application.defaultSimulatorName,
                                defaultSimulatorRuntime: ctx.application.defaultSimulatorRuntime,
                                defaultModelRaw: ctx.application.defaultModelRaw,
                                defaultModeRaw: ctx.application.defaultModeRaw,
                                defaultStepBudget: ctx.application.defaultStepBudget
                            )
                            await vm.save(updated)
                            rePickPicker = nil
                        }
                    },
                    onCancel: { rePickPicker = nil }
                )
            }
        }
    }

    // MARK: List column

    @ViewBuilder
    private func listColumn(
        vm: ApplicationsViewModel,
        applications: [ApplicationSnapshot],
        selected: ApplicationSnapshot?
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.spacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.harnessText3)
                TextField("Filter applications…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(HFont.caption)
                Spacer()
                Toggle("Archived", isOn: $showingArchived)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show archived applications")
            }
            .padding(.horizontal, Theme.spacing.m)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.harnessLine).frame(height: 0.5)
            }

            if applications.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching applications",
                    subtitle: "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(applications, id: \.id) { app in
                            rowButton(app: app, selected: app.id == selected?.id)
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
    private func rowButton(app: ApplicationSnapshot, selected: Bool) -> some View {
        Button {
            selectedID = app.id
        } label: {
            ApplicationRow(
                application: app,
                selected: selected,
                isActive: coordinator.selectedApplicationID == app.id
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Set as active") {
                Task { await vm?.setActive(app.id) }
            }
            Divider()
            Button("Archive") {
                Task { await vm?.archive(app.id) }
            }
            Button("Delete…", role: .destructive) {
                Task { await vm?.delete(app.id) }
            }
        }
    }

    // MARK: Detail column

    @ViewBuilder
    private func detailColumn(vm: ApplicationsViewModel, application: ApplicationSnapshot?) -> some View {
        if let application {
            ApplicationDetailView(
                application: application,
                recentRuns: vm.recentRunsByApplication[application.id] ?? [],
                onSetActive: {
                    Task { await vm.setActive(application.id) }
                },
                onArchive: {
                    Task { await vm.archive(application.id) }
                },
                onDelete: {
                    Task { await vm.delete(application.id) }
                },
                onRename: { newName in
                    Task { await vm.rename(application.id, to: newName) }
                },
                onUpdateDefaults: { snapshot in
                    Task { await vm.save(snapshot) }
                },
                onRePickProject: {
                    rePickPicker = ProjectPicker(
                        processRunner: container.processRunner,
                        toolLocator: container.toolLocator,
                        xcodeBuilder: container.xcodeBuilder
                    )
                }
            )
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Select an Application",
                subtitle: "Pick any row on the left to inspect its project, simulator, and recent runs."
            )
        }
    }
}

// MARK: - Row

private struct ApplicationRow: View {
    let application: ApplicationSnapshot
    let selected: Bool
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.spacing.s) {
                // Per-platform icon. Phase 1 only iOS today; Phase 2 / 3
                // light up macOS / web variants.
                Image(systemName: application.platformKind.symbolName)
                    .foregroundStyle(Color.harnessAccent)
                    .help(application.platformKind.displayName)
                Text(application.name)
                    .font(HFont.row)
                    .foregroundStyle(Color.harnessText)
                if isActive {
                    Spacer()
                    Text("ACTIVE")
                        .font(HFont.micro)
                        .foregroundStyle(Color.harnessSuccess)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.harnessSuccess.opacity(0.16)))
                } else if application.archived {
                    Spacer()
                    Text("ARCHIVED")
                        .font(HFont.micro)
                        .foregroundStyle(Color.harnessWarning)
                } else {
                    Spacer()
                }
            }
            Text(application.scheme.isEmpty ? application.projectPath : "\(application.scheme) · \(application.projectURL.lastPathComponent)")
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.harnessAccentSoft : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5)
        }
    }
}

// MARK: - Re-pick project sheet

private struct RePickContext: Identifiable {
    let application: ApplicationSnapshot
    var id: UUID { application.id }
}

private struct RePickProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var picker: ProjectPicker
    let application: ApplicationSnapshot
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var hydrated: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Re-pick project").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.spacing.l)
            .padding(.top, Theme.spacing.l)
            .padding(.bottom, Theme.spacing.s)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    PanelContainer(title: "Project") {
                        VStack(alignment: .leading, spacing: Theme.spacing.s) {
                            HStack {
                                if let url = picker.projectURL {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(picker.projectDisplayName).font(.body)
                                        Text(url.path).font(.caption).foregroundStyle(.tertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                } else {
                                    Text("No project picked yet").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(picker.projectURL == nil ? "Choose…" : "Re-pick…") {
                                    Task { await picker.pickProject() }
                                }
                            }
                            if picker.projectURL != nil {
                                HStack {
                                    Text("Scheme").frame(width: 80, alignment: .leading)
                                    if picker.availableSchemes.isEmpty {
                                        TextField("e.g. MyApp", text: $picker.selectedScheme)
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        Picker("", selection: $picker.selectedScheme) {
                                            ForEach(picker.availableSchemes, id: \.self) { s in
                                                Text(s).tag(s)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                    }
                                    if picker.isResolvingSchemes || picker.isProbingDestinations {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                if let summary = picker.schemeCompatibilitySummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(picker.schemeSupportsIOSSimulator ? .secondary : .primary)
                                }
                            }
                        }
                        .padding(Theme.spacing.l)
                    }
                }
                .padding(Theme.spacing.l)
            }
            Divider()
            HStack {
                Spacer()
                Button("Save") {
                    guard let url = picker.projectURL,
                          !picker.selectedScheme.isEmpty else { return }
                    onSave(url.path, picker.selectedScheme)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(picker.projectURL == nil
                          || picker.selectedScheme.isEmpty
                          || !picker.schemeSupportsIOSSimulator)
            }
            .padding(Theme.spacing.l)
        }
        .frame(minWidth: 540, minHeight: 380)
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            Task {
                await picker.load(projectURL: application.projectURL)
                if !application.scheme.isEmpty {
                    picker.selectedScheme = application.scheme
                }
            }
        }
    }
}
