//
//  SidebarRow.swift
//

import SwiftUI

/// Row used in `RunHistoryView` sidebar. Two-line goal + metadata footer with verdict pill.
struct SidebarRow: View {
    let run: PreviewRun
    var selected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VerdictPill(verdict: run.verdict)
                Spacer()
                Text(run.elapsed).font(HFont.mono).foregroundStyle(Color.harnessText3)
            }
            Text(run.goal)
                .font(HFont.row).foregroundStyle(Color.harnessText)
                .lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                Image(systemName: "person.fill").font(.system(size: 9))
                Text(run.persona).font(HFont.caption).foregroundStyle(Color.harnessText3)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Label(run.project, systemImage: "folder").labelStyle(.titleAndIcon)
                Text("·")
                Text("\(run.steps.count) steps")
                if !run.friction.isEmpty {
                    Text("·")
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(run.friction.count) friction")
                    }
                    .foregroundStyle(Color.harnessWarning)
                }
            }
            .font(HFont.mono).foregroundStyle(Color.harnessText3)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.harnessAccentSoft : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(run.verdict.rawValue), \(run.goal)"))
    }
}

#Preview {
    VStack(spacing: 0) {
        SidebarRow(run: PreviewRun.mock, selected: true)
        ForEach(PreviewRun.mockHistory.dropFirst()) { SidebarRow(run: $0) }
    }
    .frame(width: 360).background(Color.harnessPanel)
}
