//
//  Pill.swift
//
//  Small status capsule with a colored dot + label. Distinct from
//  `StatusChip` (which carries the run-state lifecycle —
//  running/awaiting/paused/done — and pulses) and from `FrictionTag`
//  (which always renders the warning palette).
//
//  Used in chrome positions where we want a compact "X is OK" or
//  "X · 50 steps" badge: the New Run section header's preflight
//  indicator, the Advanced disclosure's collapsed-state model + budget
//  pills, and any other place a designer reaches for a tinted capsule.
//

import SwiftUI

struct Pill: View {

    enum Kind: Hashable {
        /// Mint-on-mint with a green dot. Use for "OK / valid / ready" copy.
        case success
        /// Amber tint with a warning dot. Use for "needs attention" copy
        /// (e.g. preflight failures the user must resolve before Start).
        case warning
        /// Neutral grey-on-panel — informational badges that aren't tied
        /// to a verdict (model name, step count).
        case neutral
    }

    let text: String
    var kind: Kind = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(HFont.uiSemibold(10.5))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(Text(text))
    }

    private var dotColor: Color {
        switch kind {
        case .success: return .harnessSuccess
        case .warning: return .harnessWarning
        case .neutral: return .harnessText3
        }
    }

    private var textColor: Color {
        switch kind {
        case .success: return .harnessSuccess
        case .warning: return .harnessWarning
        case .neutral: return .harnessText2
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .success: return .harnessSuccess.opacity(0.10)
        case .warning: return .harnessWarning.opacity(0.10)
        case .neutral: return .harnessPanel2
        }
    }

    private var borderColor: Color {
        switch kind {
        case .success: return .harnessSuccess.opacity(0.35)
        case .warning: return .harnessWarning.opacity(0.35)
        case .neutral: return .harnessLineStrong
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        Pill(text: "preflight ok", kind: .success)
        Pill(text: "API key missing", kind: .warning)
        Pill(text: "Opus 4.7", kind: .neutral)
        Pill(text: "50 steps", kind: .neutral)
    }
    .padding()
    .background(Color.harnessBg)
}
