//
//  ApprovalCard.swift
//

import SwiftUI

/// Bottom-rising card shown in step-by-step mode while the agent waits for input.
struct ApprovalCard: View {
    let stepNumber: Int
    let actionDescription: String
    let toolCall: PreviewToolCall
    var onApprove: () -> Void = {}
    var onSkip: () -> Void = {}
    var onReject: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text("Awaiting approval · Step \(stepNumber)")
                    .font(HFont.micro)
                    .tracking(0.6)
                    .textCase(.uppercase)
                Spacer()
            }
            .foregroundStyle(Color.harnessAccent)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }

            VStack(alignment: .leading, spacing: 8) {
                Text(actionDescription)
                    .font(HFont.body).foregroundStyle(Color.harnessText)
                    .lineSpacing(2)
                ToolCallChip(kind: toolCall.kind, arg: toolCall.arg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)

            HStack(spacing: 8) {
                Button(action: onApprove) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        Text("Approve")
                        Text("Space").font(HFont.mono).opacity(0.7)
                    }
                }
                .buttonStyle(AccentButtonStyle(fullWidth: true))
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel("Approve action")
                .accessibilityHint("Press space to approve")

                Button(action: onSkip) {
                    HStack(spacing: 6) { Image(systemName: "forward.frame"); Text("Skip"); Text("S").font(HFont.mono).opacity(0.7) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("s", modifiers: [])

                Button(action: onReject) {
                    HStack(spacing: 6) { Image(systemName: "xmark"); Text("Reject"); Text("⇧Space").font(HFont.mono).opacity(0.7) }
                }
                .buttonStyle(SecondaryButtonStyle(tone: .danger))
                .keyboardShortcut(.space, modifiers: .shift)
            }
            .padding(12)
            .background(Color.harnessPanel2)
            .overlay(alignment: .top) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }
        }
        .background(LinearGradient(colors: [Color.harnessElevated, Color.harnessPanel], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .stroke(Color.harnessAccent.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ApprovalCard(stepNumber: 7,
                 actionDescription: "Tap the row body to dismiss the swipe and return to base list state.",
                 toolCall: .init(kind: .tap, arg: "(180, 218)"))
        .frame(width: 360).padding().background(Color.harnessPanel)
        .preferredColorScheme(.dark)
}
