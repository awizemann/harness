//
//  OriginBadge.swift
//
//  Compact icon + label capsule marking a run's origin (e.g. "Agent",
//  "CLI") in lists where the default user origin is left unbadged. Mirrors
//  `Pill`'s tinted-capsule styling but carries an SF Symbol.
//
//  Takes plain `String`s (label + symbol) rather than an app enum so it
//  stays inside HarnessDesign's preview-able vocabulary — the production
//  app maps its `RunOrigin` → these strings at the call site (see
//  `Mappers.swift` / `PreviewRun`).
//

import SwiftUI

struct OriginBadge: View {
    let label: String
    let systemImage: String
    /// Tint for icon, text, and border. Defaults to the brand accent so
    /// agent-driven rows read as "machine, not you".
    var tint: Color = .harnessAccent

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .semibold))
            Text(label)
                .font(HFont.uiSemibold(10.5))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.pill)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.pill))
        .accessibilityLabel(Text("\(label) run"))
    }
}

#Preview {
    HStack(spacing: 8) {
        OriginBadge(label: "Agent", systemImage: "sparkles")
        OriginBadge(label: "CLI", systemImage: "terminal", tint: .harnessText3)
    }
    .padding()
    .background(Color.harnessBg)
}
