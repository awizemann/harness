//
//  FrictionReportView.swift
//  Harness
//
//  Friction-only timeline view. One screenshot + one agent quote per
//  friction event in the selected run. Designed for sharing with
//  designers / attaching to bug reports.
//

import SwiftUI
import AppKit

struct FrictionReportView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator

    @State private var vm: FrictionReportViewModel?
    @State private var stubAlert: StubExportAction?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = FrictionReportViewModel(store: container.runHistory)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: FrictionReportViewModel) -> some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = vm.loadError {
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't load run",
                    subtitle: err
                )
            } else if vm.runID == nil {
                EmptyStateView(
                    symbol: "tray",
                    title: "No runs to inspect",
                    subtitle: "Compose your first run under New Run. Friction this agent flags will land here."
                )
            } else if vm.totalFriction == 0 {
                EmptyStateView(
                    symbol: "checkmark.seal",
                    title: "No friction in this run",
                    subtitle: "The agent reached the goal without flagging any UX problems."
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.spacing.l) {
                        summaryBand(vm: vm)
                        let groups = vm.filteredEntriesByLeg()
                        if groups.count > 1 {
                            // Chain run — render one section per leg.
                            ForEach(groups, id: \.section.id) { group in
                                if !group.entries.isEmpty {
                                    legSectionHeader(group.section)
                                    ForEach(group.entries) { entry in
                                        FrictionReportCard(entry: entry) {
                                            jumpToStep(entry.step, vm: vm)
                                        }
                                    }
                                }
                            }
                        } else {
                            // Single-leg / v1 — flat list, no headers.
                            ForEach(groups.first?.entries ?? []) { entry in
                                FrictionReportCard(entry: entry) {
                                    jumpToStep(entry.step, vm: vm)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.spacing.xxl)
                    .padding(.vertical, Theme.spacing.l)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.harnessBg)
            }
        }
        .navigationTitle("Friction Report")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !vm.runDisplayLabel.isEmpty {
                    Text(vm.runDisplayLabel)
                        .font(HFont.mono)
                        .foregroundStyle(Color.harnessText3)
                        .padding(.horizontal, Theme.spacing.s)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.harnessPanel2))
                }
            }
            ToolbarItem(placement: .principal) {
                SegmentedToggle(
                    options: FrictionKindFilter.allCases.map { .init($0, $0.label) },
                    selection: bindingForFilter(vm: vm)
                )
                .frame(maxWidth: 360)
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: Theme.spacing.s) {
                    Button {
                        stubAlert = .pdf
                    } label: {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                    }
                    .disabled(vm.totalFriction == 0)
                    Button {
                        stubAlert = .markdown
                    } label: {
                        Label("Markdown", systemImage: "doc.text")
                    }
                    .disabled(vm.totalFriction == 0)
                    Button {
                        stubAlert = .share
                    } label: {
                        Label("Share", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(vm.totalFriction == 0)
                }
            }
        }
        .task(id: coordinator.selectedHistoryRunID) {
            await vm.load(preferredRunID: coordinator.selectedHistoryRunID)
        }
        .alert(item: $stubAlert) { action in
            Alert(
                title: Text(action.title),
                message: Text("Coming soon — tracked in docs/DESIGN_BACKLOG.md."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: Summary band

    @ViewBuilder
    private func summaryBand(vm: FrictionReportViewModel) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing.l) {
            Text("\(vm.totalFriction)")
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.harnessWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineCopy(count: vm.totalFriction))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.harnessText)
                Text(detailCopy(kindCounts: vm.kindCounts))
                    .font(HFont.caption)
                    .foregroundStyle(Color.harnessText2)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(vm.kindCounts, id: \.kind) { tally in
                    summaryChip(kind: tally.kind, count: tally.count)
                }
            }
        }
        .padding(.horizontal, Theme.spacing.l)
        .padding(.vertical, Theme.spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Color.harnessWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5)
        )
    }

    private func summaryChip(kind: FrictionKind, count: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color.harnessWarning).frame(width: 6, height: 6)
            Text("\(count) \(kind.rawValue)")
                .font(HFont.micro)
        }
        .foregroundStyle(Color.harnessWarning)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(Color.harnessWarning.opacity(0.10)))
        .overlay(Capsule().stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5))
    }

    // MARK: Helpers

    private func headlineCopy(count: Int) -> String {
        count == 1
            ? "One friction event flagged in this run."
            : "\(numberWord(count)) friction events flagged in this run."
    }

    /// Spell out small counts to match the design's prose. Falls back to
    /// digits past 10 — by then the count itself communicates volume.
    private func numberWord(_ n: Int) -> String {
        switch n {
        case 1: return "One"
        case 2: return "Two"
        case 3: return "Three"
        case 4: return "Four"
        case 5: return "Five"
        case 6: return "Six"
        case 7: return "Seven"
        case 8: return "Eight"
        case 9: return "Nine"
        case 10: return "Ten"
        default: return "\(n)"
        }
    }

    private func detailCopy(kindCounts: [(kind: FrictionKind, count: Int)]) -> String {
        guard !kindCounts.isEmpty else { return "" }
        let phrases = kindCounts.map { "\($0.count) \($0.kind.rawValue.replacingOccurrences(of: "_", with: " "))" }
        return phrases.joined(separator: " · ")
    }

    private func bindingForFilter(vm: FrictionReportViewModel) -> Binding<FrictionKindFilter> {
        Binding(
            get: { vm.filter },
            set: { vm.filter = $0 }
        )
    }

    /// Inline section header for a leg group. Renders as a small caps
    /// label + thin divider so the page reads as visually distinct
    /// sections without competing with the friction cards' visual weight.
    private func legSectionHeader(_ section: FrictionReportViewModel.LegSection) -> some View {
        HStack(spacing: Theme.spacing.s) {
            Text(section.title)
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText3)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.harnessLineSoft)
                .frame(height: 0.5)
        }
        .padding(.top, Theme.spacing.s)
        .padding(.bottom, Theme.spacing.xs)
    }

    @MainActor
    private func jumpToStep(_ step: Int, vm: FrictionReportViewModel) {
        guard let runID = vm.runID else { return }
        coordinator.replayJumpToStep = step
        coordinator.openReplay(runID: runID)
    }
}

// MARK: - Stub export alert

private enum StubExportAction: String, Identifiable {
    case pdf, markdown, share
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: return "Export PDF"
        case .markdown: return "Copy as Markdown"
        case .share: return "Share"
        }
    }
}
