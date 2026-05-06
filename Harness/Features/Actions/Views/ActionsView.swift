//
//  ActionsView.swift
//  Harness
//
//  Library shell for the Actions section. Two tabs (`Actions` / `Chains`)
//  selected via `SegmentedToggle` in the toolbar's `.principal` placement,
//  mirroring `RunHistoryView`'s verdict filter. Each tab is its own
//  list/detail HSplitView; the toolbar Add button switches sheet between
//  `ActionCreateView` and `ChainCreateView` based on the active tab.
//

import SwiftUI
import AppKit

enum ActionsTab: String, Hashable, CaseIterable {
    case actions
    case chains

    var label: String {
        switch self {
        case .actions: return "Actions"
        case .chains:  return "Chains"
        }
    }
}

struct ActionsView: View {

    @Environment(AppContainer.self) private var container

    @State private var vm: ActionsViewModel?
    @State private var tab: ActionsTab = .actions
    @State private var searchText: String = ""
    @State private var selectedActionID: UUID?
    @State private var selectedChainID: UUID?
    @State private var showingArchived: Bool = false
    @State private var showingActionCreate: Bool = false
    @State private var showingChainCreate: Bool = false

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = ActionsViewModel(store: container.runHistory)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: ActionsViewModel) -> some View {
        Group {
            if vm.isLoading && vm.actions.isEmpty && vm.chains.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabContent(vm: vm)
            }
        }
        .navigationTitle("Actions")
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedToggle(
                    options: ActionsTab.allCases.map { .init($0, $0.label) },
                    selection: $tab
                )
                .frame(maxWidth: 220)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    switch tab {
                    case .actions: showingActionCreate = true
                    case .chains:  showingChainCreate = true
                    }
                } label: {
                    Label(tab == .actions ? "Add Action…" : "Add Chain…", systemImage: "plus")
                }
                .help(tab == .actions ? "Add an Action" : "Add an Action Chain")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Show archived", isOn: $showingArchived)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show archived rows")
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
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: tab == .actions ? "Filter actions" : "Filter chains"
        )
        .task { await vm.reload() }
        .onChange(of: tab) { _, _ in
            // Clear search/selection on tab swap so cross-tab carry-overs
            // don't strand the detail pane on an empty visible-list.
            searchText = ""
        }
        .sheet(isPresented: $showingActionCreate) {
            ActionCreateView(
                viewModel: vm,
                onCreated: { snapshot in
                    selectedActionID = snapshot.id
                }
            )
        }
        .sheet(isPresented: $showingChainCreate) {
            ChainCreateView(
                viewModel: vm,
                onCreated: { snapshot in
                    selectedChainID = snapshot.id
                    tab = .chains
                }
            )
        }
    }

    @ViewBuilder
    private func tabContent(vm: ActionsViewModel) -> some View {
        switch tab {
        case .actions: actionsTab(vm: vm)
        case .chains:  chainsTab(vm: vm)
        }
    }

    // MARK: Actions tab

    @ViewBuilder
    private func actionsTab(vm: ActionsViewModel) -> some View {
        let visible = vm.filteredActions(search: searchText, includeArchived: showingArchived)
        let selected = visible.first { $0.id == selectedActionID } ?? visible.first

        if vm.actions.isEmpty {
            EmptyStateView(
                symbol: "text.cursor",
                title: "No actions yet",
                subtitle: "Save reusable goals so you can pick them per run instead of retyping. Chain them together for multi-step user tests.",
                ctaTitle: "Add Action",
                onCta: { showingActionCreate = true }
            )
        } else {
            HSplitView {
                actionsListColumn(vm: vm, items: visible, selected: selected)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                actionsDetailColumn(vm: vm, item: selected)
                    .frame(minWidth: 480)
            }
            .onChange(of: selected?.id) { _, newID in
                selectedActionID = newID
            }
        }
    }

    @ViewBuilder
    private func actionsListColumn(
        vm: ActionsViewModel,
        items: [ActionSnapshot],
        selected: ActionSnapshot?
    ) -> some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching actions",
                    subtitle: "Try a different search or toggle archived rows."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.id) { item in
                            actionRowButton(
                                vm: vm,
                                item: item,
                                selected: item.id == selected?.id
                            )
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
    private func actionRowButton(
        vm: ActionsViewModel,
        item: ActionSnapshot,
        selected: Bool
    ) -> some View {
        let chainCount = vm.chainsReferencing(actionID: item.id).count
        Button {
            selectedActionID = item.id
        } label: {
            ActionRow(action: item, chainCount: chainCount, selected: selected)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            if !item.archived {
                Button("Archive") {
                    Task { await vm.archiveAction(id: item.id) }
                }
            }
            Button("Delete…", role: .destructive) {
                Task { await vm.deleteAction(id: item.id) }
            }
        }
    }

    @ViewBuilder
    private func actionsDetailColumn(vm: ActionsViewModel, item: ActionSnapshot?) -> some View {
        if let item {
            ActionDetailView(
                action: item,
                referencingChains: vm.chainsReferencing(actionID: item.id),
                onSave: { snapshot in
                    Task {
                        do {
                            try await vm.updateAction(snapshot)
                        } catch {
                            // lastError surfaces in the VM; the detail view
                            // can re-render against it on the next pass.
                        }
                    }
                },
                onArchive: {
                    Task { await vm.archiveAction(id: item.id) }
                },
                onDelete: {
                    Task { await vm.deleteAction(id: item.id) }
                }
            )
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Select an action",
                subtitle: "Pick any row on the left to inspect its prompt and metadata."
            )
        }
    }

    // MARK: Chains tab

    @ViewBuilder
    private func chainsTab(vm: ActionsViewModel) -> some View {
        let visible = vm.filteredChains(search: searchText, includeArchived: showingArchived)
        let selected = visible.first { $0.id == selectedChainID } ?? visible.first

        if vm.chains.isEmpty {
            EmptyStateView(
                symbol: "link",
                title: "No action chains yet",
                subtitle: "Combine actions into a sequence to test multi-step flows in one run.",
                ctaTitle: "Add Chain",
                onCta: { showingChainCreate = true }
            )
        } else {
            HSplitView {
                chainsListColumn(vm: vm, items: visible, selected: selected)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                chainsDetailColumn(vm: vm, item: selected)
                    .frame(minWidth: 480)
            }
            .onChange(of: selected?.id) { _, newID in
                selectedChainID = newID
            }
        }
    }

    @ViewBuilder
    private func chainsListColumn(
        vm: ActionsViewModel,
        items: [ActionChainSnapshot],
        selected: ActionChainSnapshot?
    ) -> some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching chains",
                    subtitle: "Try a different search or toggle archived rows."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.id) { item in
                            chainRowButton(
                                vm: vm,
                                item: item,
                                selected: item.id == selected?.id
                            )
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
    private func chainRowButton(
        vm: ActionsViewModel,
        item: ActionChainSnapshot,
        selected: Bool
    ) -> some View {
        let broken = vm.brokenStepCount(in: item)
        Button {
            selectedChainID = item.id
        } label: {
            ChainRow(chain: item, brokenStepCount: broken, selected: selected)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            if !item.archived {
                Button("Archive") {
                    Task { await vm.archiveChain(id: item.id) }
                }
            }
            Button("Delete…", role: .destructive) {
                Task { await vm.deleteChain(id: item.id) }
            }
        }
    }

    @ViewBuilder
    private func chainsDetailColumn(vm: ActionsViewModel, item: ActionChainSnapshot?) -> some View {
        if let item {
            ChainDetailView(
                chain: item,
                availableActions: vm.actions.filter { !$0.archived },
                brokenStepCount: vm.brokenStepCount(in: item),
                onSave: { snapshot in
                    Task {
                        do {
                            try await vm.updateChain(snapshot)
                        } catch {
                            // lastError handled by VM.
                        }
                    }
                },
                onArchive: {
                    Task { await vm.archiveChain(id: item.id) }
                },
                onDelete: {
                    Task { await vm.deleteChain(id: item.id) }
                }
            )
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Select a chain",
                subtitle: "Pick any row on the left to inspect its steps and metadata."
            )
        }
    }
}

// MARK: - Rows

/// Shared row background tint — selected wins, hover is the secondary
/// pull-in tint, idle rows are clear. Mirrors `ApplicationRow` /
/// `PersonaRow` so the three library lists feel identical.
private func rowBackground(selected: Bool, hovering: Bool) -> Color {
    if selected { return Color.harnessAccentSoft }
    if hovering { return Color.harnessAccent.opacity(0.06) }
    return .clear
}

private struct ActionRow: View {
    let action: ActionSnapshot
    let chainCount: Int
    let selected: Bool

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.spacing.s) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(Color.harnessAccent)
                Text(action.name)
                    .font(HFont.row)
                    .foregroundStyle(Color.harnessText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if action.archived {
                    archivedChip
                } else if chainCount > 0 {
                    chainCountChip
                }
            }
            if !action.promptText.isEmpty {
                Text(action.promptText)
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
        .background(rowBackground(selected: selected, hovering: isHovered))
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

    private var chainCountChip: some View {
        Text("IN \(chainCount)")
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

private struct ChainRow: View {
    let chain: ActionChainSnapshot
    let brokenStepCount: Int
    let selected: Bool

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.spacing.s) {
                Image(systemName: "link")
                    .foregroundStyle(Color.harnessAccent)
                Text(chain.name)
                    .font(HFont.row)
                    .foregroundStyle(Color.harnessText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if chain.archived {
                    archivedChip
                } else if brokenStepCount > 0 {
                    brokenChip
                } else if chain.steps.isEmpty {
                    draftChip
                }
            }
            Text(stepLabel)
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(selected: selected, hovering: isHovered))
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

    private var stepLabel: String {
        switch chain.steps.count {
        case 0: return "no steps"
        case 1: return "1 step"
        default: return "\(chain.steps.count) steps"
        }
    }

    private var draftChip: some View {
        Text("DRAFT")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessWarning)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.harnessWarning.opacity(0.16)))
    }

    private var brokenChip: some View {
        Text("BROKEN")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessFailure)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.harnessFailure.opacity(0.16)))
    }

    private var archivedChip: some View {
        Text("ARCHIVED")
            .font(HFont.micro)
            .foregroundStyle(Color.harnessWarning)
    }
}

// MARK: - Sheet identifier

extension ActionSnapshot: Identifiable {}
extension ActionChainSnapshot: Identifiable {}
