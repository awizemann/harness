//
//  RunHistoryDetailView.swift
//  Harness
//
//  Right-pane view of `RunHistoryView`. Shows everything you'd want before
//  deciding whether to scrub a full replay: verdict + project, full goal +
//  persona, a 4-cell summary grid, the agent's run summary, friction events
//  with timestamps, and the action path rendered as `ToolCallChip` flow.
//

import SwiftUI
import AppKit

struct RunHistoryDetailView: View {

    let run: RunRecordSnapshot
    let detail: RunDetail?
    let isLoading: Bool
    let onReplay: () -> Void
    let onOpenFolder: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    summaryGrid
                    summaryPanel
                    if !(detail?.frictionEvents.isEmpty ?? true) {
                        frictionPanel
                    }
                    if !(detail?.steps.isEmpty ?? true) {
                        pathPanel
                    } else if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.spacing.l)
                    }
                }
                .padding(Theme.spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.harnessBg)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            HStack(spacing: Theme.spacing.s) {
                if let v = run.verdict {
                    VerdictPill(verdict: PreviewVerdict(v))
                } else {
                    StatusChip(kind: .running)
                }
                projectChip
                Spacer()
                Button(action: onReplay) { Label("Replay", systemImage: "play.fill") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(action: onOpenFolder) { Label("Open Folder", systemImage: "folder") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(action: onExport) { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text(run.goal)
                .font(HFont.h2)
                .foregroundStyle(Color.harnessText)
            Text("Persona · \(run.persona)")
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText3)
        }
        .padding(Theme.spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.harnessBg3)
    }

    private var projectChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 9))
            Text(run.displayName)
        }
        .font(HFont.micro)
        .foregroundStyle(Color.harnessText2)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(Color.harnessPanel2))
    }

    // MARK: Summary grid (4 or 5 cells — 5th cell is "Legs" for chain runs)

    private var summaryGrid: some View {
        HStack(spacing: 0.5) {
            cell("Verdict", verdictLabel, color: verdictColor)
            cell("Steps", "\(run.stepCount)")
            cell("Elapsed", elapsedLabel)
            cell(
                "Friction",
                "\(run.frictionCount)",
                color: run.frictionCount == 0 ? .harnessText : .harnessWarning
            )
            // Phase E: chain runs grow a "Legs" cell. Single-action /
            // ad-hoc / pre-rework runs keep the 4-cell grid.
            if run.legs.count > 1 {
                cell("Legs", "\(run.legs.count)")
            }
        }
        .background(Color.harnessLine)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .stroke(Color.harnessLine, lineWidth: 0.5)
        )
    }

    private func cell(_ label: String, _ value: String, color: Color = .harnessText) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text(label).metaKeyStyle()
            Text(value).font(HFont.monoStat).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.m)
        .background(Color.harnessPanel)
    }

    // MARK: Panels

    private var summaryPanel: some View {
        PanelContainer(title: "Agent summary") {
            Group {
                if let text = run.summary, !text.isEmpty {
                    Text(text)
                        .font(HFont.body)
                        .foregroundStyle(Color.harnessText2)
                        .lineSpacing(3)
                } else {
                    Text(run.verdict == nil
                         ? "Run is still in progress."
                         : "No summary recorded for this run.")
                        .font(HFont.body)
                        .foregroundStyle(Color.harnessText3)
                }
            }
            .padding(Theme.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var frictionPanel: some View {
        PanelContainer(title: "Friction events") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(detail?.frictionEvents ?? []) { event in
                    HStack(alignment: .top, spacing: Theme.spacing.s) {
                        Text(String(format: "Step %d", event.step))
                            .font(HFont.mono)
                            .foregroundStyle(Color.harnessText3)
                            .frame(width: 64, alignment: .leading)
                        FrictionTag(kind: PreviewFrictionKind(event.kind))
                        Text(event.detail)
                            .font(HFont.caption)
                            .foregroundStyle(Color.harnessText2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Theme.spacing.m)
                    .padding(.vertical, Theme.spacing.s)
                    .overlay(alignment: .bottom) {
                        if event.id != detail?.frictionEvents.last?.id {
                            Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private var pathPanel: some View {
        PanelContainer(title: "Path") {
            FlowLayout(spacing: 6) {
                ForEach(detail?.steps ?? []) { step in
                    if let call = step.toolCall {
                        let preview = PreviewToolCall(call)
                        ToolCallChip(kind: preview.kind, arg: preview.arg)
                    }
                }
            }
            .padding(Theme.spacing.m)
        }
    }

    // MARK: Computed labels

    private var verdictLabel: String {
        switch run.verdict {
        case .success: return "Success"
        case .blocked: return "Blocked"
        case .failure: return "Failed"
        case .none:    return "Running"
        }
    }

    private var verdictColor: Color {
        switch run.verdict {
        case .success: return .harnessSuccess
        case .blocked: return .harnessBlocked
        case .failure: return .harnessFailure
        case .none:    return .harnessAccent
        }
    }

    private var elapsedLabel: String {
        if let completedAt = run.completedAt {
            let s = max(0, Int(completedAt.timeIntervalSince(run.createdAt)))
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
        return "—"
    }
}
