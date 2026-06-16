//
//  AgentSessionsView.swift
//  Harness
//
//  Library-section dashboard for agent-driven runs. Two stacked sections:
//  (a) LIVE — in-flight agent sessions from `AgentSessionsMonitor`, each with
//  a pulsing StatusChip + live step counter; (b) RECENT AGENT RUNS — completed
//  `.mcp` runs from the history store, reusing the `SidebarRow` styling. A
//  finishing session bumps the monitor's `endedGeneration`, which reloads the
//  recent list so the run drops in without a manual refresh.
//

import SwiftUI
import AppKit

struct AgentSessionsView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppState.self) private var state

    @State private var vm: AgentSessionsViewModel?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = AgentSessionsViewModel(store: container.runHistory)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: AgentSessionsViewModel) -> some View {
        let live = container.agentSessionsMonitor.activeSessions
        Group {
            if live.isEmpty && vm.pastRuns.isEmpty && !vm.isLoading {
                EmptyStateView(
                    symbol: "sparkles",
                    title: "No agent sessions yet",
                    subtitle: "When an agent drives Harness through the MCP server, its live session shows here — and lands in History when it finishes."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing.xl) {
                        if !live.isEmpty {
                            liveSection(live)
                        }
                        recentSection(vm: vm)
                    }
                    .padding(Theme.spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Agent Sessions")
        .background(Color.harnessBg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
            }
        }
        .task { await vm.reload() }
        .onChange(of: container.agentSessionsMonitor.endedGeneration) { _, _ in
            Task { await vm.reload() }
        }
    }

    // MARK: Live sessions

    @ViewBuilder
    private func liveSection(_ live: [AgentSessionMarker]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.m) {
            sectionHeader("LIVE", count: live.count, accent: true)
            ForEach(live) { marker in
                LiveSessionCard(marker: marker)
            }
        }
    }

    // MARK: Recent agent runs

    @ViewBuilder
    private func recentSection(vm: AgentSessionsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            sectionHeader("RECENT AGENT RUNS", count: vm.pastRuns.count, accent: false)
            if vm.pastRuns.isEmpty {
                Text(vm.isLoading ? "Loading…" : "No completed agent runs yet.")
                    .font(HFont.caption)
                    .foregroundStyle(Color.harnessText3)
                    .padding(.vertical, Theme.spacing.s)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(vm.pastRuns, id: \.id) { run in
                        pastRunRow(run)
                    }
                }
                .background(Color.harnessPanel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Color.harnessLine, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func pastRunRow(_ run: RunRecordSnapshot) -> some View {
        Button {
            openInHistory(run)
        } label: {
            SidebarRow(
                run: PreviewRun(run),
                selected: run.id == coordinator.selectedHistoryRunID
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { coordinator.openReplay(runID: run.id) }
        )
        .contextMenu {
            Button("Open in History") { openInHistory(run) }
            Button("Open Replay") { coordinator.openReplay(runID: run.id) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([run.runDirectoryURL])
            }
        }
    }

    /// Jump to this run inside its Application's History — the unified home
    /// for every run, agent or user. Threads the Agent Sessions feed into the
    /// main app-centric flow rather than leaving it a dead-end island.
    /// App-less legacy runs (no Application) fall back to the replay sheet,
    /// since there's no per-app History to land in.
    private func openInHistory(_ run: RunRecordSnapshot) {
        guard let appID = run.applicationID else {
            coordinator.openReplay(runID: run.id)
            return
        }
        Task {
            // Only land in History if the Application is live + unarchived.
            // The sidebar and active-app card are built from non-archived
            // apps, so navigating to an archived/deleted app would strand the
            // user on a headerless workspace with no way back. Fall back to
            // the replay sheet (same as app-less runs) otherwise.
            guard let app = try? await container.runHistory.application(id: appID),
                  !app.archived else {
                coordinator.openReplay(runID: run.id)
                return
            }
            coordinator.selectedApplicationID = appID
            state.selectedApplicationID = appID
            await state.persistSettings()
            coordinator.selectedHistoryRunID = run.id
            coordinator.selectedSection = .history
        }
    }

    // MARK: Header

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int, accent: Bool) -> some View {
        HStack(spacing: Theme.spacing.s) {
            Text(title).metaKeyStyle(accent ? Color.harnessAccent : Color.harnessText4)
            Text("\(count)")
                .font(HFont.micro)
                .foregroundStyle(Color.harnessText3)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.harnessPanel2))
            Spacer()
        }
    }
}

/// One in-flight agent session — pulsing status, live step counter, and the
/// goal + platform/model/phase footer. Accent border to read as "alive".
private struct LiveSessionCard: View {
    let marker: AgentSessionMarker

    private var modelLabel: String {
        AgentModel(rawValue: marker.modelRaw)?.displayName ?? marker.modelRaw
    }
    private var phaseLabel: String {
        marker.phase.replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            HStack(spacing: Theme.spacing.s) {
                StatusChip(kind: .running)
                OriginBadge(label: marker.source.displayName, systemImage: marker.source.systemImage)
                Spacer(minLength: 0)
                Text("step \(marker.currentStep)")
                    .font(HFont.mono)
                    .foregroundStyle(Color.harnessText2)
            }
            Text(marker.goal)
                .font(HFont.body)
                .foregroundStyle(Color.harnessText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Label(marker.platformKind.shortLabel, systemImage: marker.platformKind.symbolName)
                    .labelStyle(.titleAndIcon)
                Text("·")
                Text(modelLabel)
                Text("·")
                Text(phaseLabel)
            }
            .font(HFont.caption)
            .foregroundStyle(Color.harnessText3)
            .lineLimit(1)
        }
        .padding(Theme.spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.harnessPanel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .strokeBorder(Color.harnessAccent.opacity(0.30), lineWidth: 1)
        )
        // Read the whole live card as one VoiceOver element rather than five
        // disjoint fragments (status, origin, step, goal, footer).
        .accessibilityElement(children: .combine)
    }
}
