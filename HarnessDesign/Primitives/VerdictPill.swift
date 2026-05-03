//
//  VerdictPill.swift
//

import SwiftUI

/// Color-coded pill: Success / Blocked / Failed.
struct VerdictPill: View {
    let verdict: Verdict

    private var color: Color {
        switch verdict {
        case .success: return .harnessSuccess
        case .failure: return .harnessFailure
        case .blocked: return .harnessBlocked
        }
    }
    private var label: String {
        switch verdict {
        case .success: return "Success"
        case .failure: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(HFont.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.pill)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.pill)
                .stroke(color.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityLabel(Text("Verdict \(label)"))
    }
}

#Preview {
    HStack { VerdictPill(verdict: .success); VerdictPill(verdict: .blocked); VerdictPill(verdict: .failure) }
        .padding()
        .background(Color.harnessBg)
}
