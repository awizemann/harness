//
//  RunHistoryView.swift
//  Harness
//

import SwiftUI
import AppKit

struct RunHistoryView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @State private var vm: RunHistoryViewModel?
    @State private var searchText: String = ""
    @State private var verdictFilter: VerdictFilter = .all
    @State private var detail: RunDetail?
    @State private var detailRunID: UUID?
    @State private var detailLoading: Bool = false

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = RunHistoryViewModel(store: container.runHistory)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: RunHistoryViewModel) -> some View {
        let filtered = vm.filteredRuns(search: searchText, verdict: verdictFilter)
        let groups = vm.dayGroups(from: filtered)
        let selectedRun = filtered.first { $0.id == coordinator.selectedHistoryRunID }
            ?? filtered.first
        Group {
            if vm.isLoading && vm.runs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.runs.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "No runs yet",
                    subtitle: "Hit ⌘N to start your first user test. Harness will boot a simulator and drive your app.",
                    ctaTitle: "New Run",
                    onCta: { coordinator.selectedSection = .newRun }
                )
            } else {
                HSplitView {
                    listColumn(vm: vm, groups: groups, runCount: filtered.count)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                    detailColumn(vm: vm, run: selectedRun)
                        .frame(minWidth: 480)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedToggle(
                    options: VerdictFilter.allCases.map { .init($0, $0.label) },
                    selection: $verdictFilter
                )
                .frame(maxWidth: 360)
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
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { vm.exportError != nil },
                set: { if !$0 { vm.exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.exportError ?? "")
        }
        .task { await vm.reload() }
        .onChange(of: selectedRun?.id) { _, newID in
            Task { await loadDetail(for: newID, vm: vm) }
        }
        .task(id: selectedRun?.id) {
            await loadDetail(for: selectedRun?.id, vm: vm)
        }
    }

    // MARK: List column (left)

    @ViewBuilder
    private func listColumn(vm: RunHistoryViewModel, groups: [RunHistoryDayGroup], runCount: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.spacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.harnessText3)
                TextField("Filter goals…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(HFont.caption)
                Spacer()
                Text("\(runCount) runs")
                    .font(HFont.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.harnessPanel2))
            }
            .padding(.horizontal, Theme.spacing.m)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.harnessLine).frame(height: 0.5)
            }

            if groups.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching runs",
                    subtitle: "Try a different search or clear the verdict filter."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.runs, id: \.id) { run in
                                    rowButton(for: run, vm: vm)
                                }
                            } header: {
                                HStack {
                                    Text(group.label).metaKeyStyle()
                                    Spacer()
                                }
                                .padding(.horizontal, Theme.spacing.m)
                                .padding(.vertical, Theme.spacing.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.harnessPanel)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5)
                                }
                            }
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
    private func rowButton(for run: RunRecordSnapshot, vm: RunHistoryViewModel) -> some View {
        Button {
            coordinator.selectedHistoryRunID = run.id
        } label: {
            SidebarRow(
                run: PreviewRun(run),
                selected: run.id == coordinator.selectedHistoryRunID
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                coordinator.openReplay(runID: run.id)
            }
        )
        .contextMenu {
            Button("Open Replay") { coordinator.openReplay(runID: run.id) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([run.runDirectoryURL])
            }
            Button("Export Run…") {
                Task { await runExport(run, vm: vm) }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                Task { await vm.delete(id: run.id) }
            }
        }
    }

    // MARK: Detail column (right)

    @ViewBuilder
    private func detailColumn(vm: RunHistoryViewModel, run: RunRecordSnapshot?) -> some View {
        if let run {
            RunHistoryDetailView(
                run: run,
                detail: detailRunID == run.id ? detail : nil,
                isLoading: detailLoading && detailRunID == run.id,
                onReplay: { coordinator.openReplay(runID: run.id) },
                onOpenFolder: {
                    NSWorkspace.shared.activateFileViewerSelecting([run.runDirectoryURL])
                },
                onExport: {
                    Task { await runExport(run, vm: vm) }
                }
            )
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Select a run",
                subtitle: "Pick any row on the left to inspect its summary, friction events, and action path."
            )
        }
    }

    // MARK: Helpers

    @MainActor
    private func loadDetail(for runID: UUID?, vm: RunHistoryViewModel) async {
        guard let runID else {
            detail = nil
            detailRunID = nil
            return
        }
        detailRunID = runID
        detailLoading = true
        defer { detailLoading = false }
        let loaded = await vm.loadDetail(for: runID)
        // The user may have flipped to a different run while we were parsing —
        // discard if so.
        if detailRunID == runID {
            detail = loaded
        }
    }

    @MainActor
    private func runExport(_ run: RunRecordSnapshot, vm: RunHistoryViewModel) async {
        let panel = NSSavePanel()
        panel.title = "Export Run"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(run.id.uuidString.prefix(8))-\(Self.dateStamp(run.createdAt)).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await vm.exportRun(run, to: url)
    }

    private static func dateStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
