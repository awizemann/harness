//
//  RunHistoryView.swift
//

import SwiftUI

@MainActor final class RunHistoryViewModel: ObservableObject {
    @Published var groups: [(day: String, runs: [PreviewRun])]
    @Published var selectedID: PreviewRun.ID?
    init(history: [PreviewRun] = PreviewRun.mockHistory) {
        self.groups = [("Today, May 3", history)]
        self.selectedID = history.first?.id
    }
    var selected: PreviewRun? { groups.flatMap(\.runs).first { $0.id == selectedID } }
}

struct RunHistoryView: View {
    @StateObject var vm = RunHistoryViewModel()

    var body: some View {
        HStack(spacing: 0) {
            list
            detail
        }
        .background(Color.harnessBg)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.harnessText3)
                Text("Filter goals…").font(HFont.caption).foregroundStyle(Color.harnessText4)
                Spacer()
                Text("\(vm.groups.flatMap(\.runs).count) runs")
                    .font(HFont.micro)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.harnessPanel2))
            }
            .padding(.horizontal, 14).frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(vm.groups, id: \.day) { group in
                        Section {
                            ForEach(group.runs) { run in
                                Button { vm.selectedID = run.id } label: {
                                    SidebarRow(run: run, selected: run.id == vm.selectedID)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack { Text(group.day).metaKeyStyle(); Spacer() }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Color.harnessPanel)
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5) }
                        }
                    }
                }
            }
        }
        .frame(width: 360)
        .background(Color.harnessPanel)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.harnessLine).frame(width: 0.5) }
    }

    @ViewBuilder private var detail: some View {
        if let r = vm.selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VerdictPill(verdict: r.verdict)
                        HStack(spacing: 4) { Image(systemName: "folder.fill").font(.system(size: 9)); Text(r.project) }
                            .font(HFont.micro).foregroundStyle(Color.harnessText2)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(Color.harnessPanel2))
                        Spacer()
                        Button { } label: { Label("Replay", systemImage: "play.fill") }.buttonStyle(SecondaryButtonStyle())
                        Button { } label: { Label("Open Folder", systemImage: "folder") }.buttonStyle(SecondaryButtonStyle())
                        Button { } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(SecondaryButtonStyle())
                    }
                    Text(r.goal).font(HFont.h2).foregroundStyle(Color.harnessText)
                    Text("Persona · \(r.persona)").font(HFont.caption).foregroundStyle(Color.harnessText3)
                }
                .padding(22)
                .background(Color.harnessBg3)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryGrid(r)
                        PanelContainer(title: "Agent summary") {
                            Text("Goal completed in 8 steps. Found the add affordance immediately. Marking the row as done required identifying the unfilled circle as a checkbox. Suggest adding an accessibility label and visible affordance hint.")
                                .font(HFont.body).foregroundStyle(Color.harnessText2).lineSpacing(3)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        PanelContainer(title: "Path") {
                            FlowLayout(spacing: 6) {
                                ForEach(r.steps) { s in ToolCallChip(kind: s.action.kind, arg: s.action.arg) }
                            }
                            .padding(12)
                        }
                    }
                    .padding(22)
                }
            }
        } else {
            EmptyStateView(symbol: "tray", title: "No runs yet",
                           subtitle: "Hit ⌘N to start your first user test. Harness will boot a simulator and drive your app.",
                           ctaTitle: "New Run", onCta: {})
        }
    }

    private func summaryGrid(_ r: PreviewRun) -> some View {
        HStack(spacing: 0.5) {
            cell("Verdict", r.verdict.rawValue.capitalized, color: .harnessSuccess)
            cell("Steps", "\(r.steps.count) / \(r.stepBudget)")
            cell("Elapsed", r.elapsed)
            cell("Friction", "\(r.friction.count)", color: r.friction.isEmpty ? .harnessText : .harnessWarning)
        }
        .background(Color.harnessLine)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.harnessLine, lineWidth: 0.5))
    }
    private func cell(_ label: String, _ value: String, color: Color = .harnessText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).metaKeyStyle()
            Text(value).font(HFont.monoStat).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Color.harnessPanel)
    }
}

/// Minimal flow layout helper used for chip lists.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}

#Preview("RunHistory") { RunHistoryView().frame(width: 1180, height: 760).preferredColorScheme(.dark) }
