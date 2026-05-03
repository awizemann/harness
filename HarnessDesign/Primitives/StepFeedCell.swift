//
//  StepFeedCell.swift
//

import SwiftUI

/// One row in the step feed. Renders observation, intent, tool-call chip, optional thumbnail,
/// and (if present) a friction-styled inline note.
struct StepFeedCell: View {
    let step: PreviewStep
    var current: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // gutter — step number + timeline rail
            VStack(spacing: 4) {
                Text(String(format: "%02d", step.n))
                    .font(HFont.mono)
                    .foregroundStyle(Color.harnessText4)
                    .monospacedDigit()
                Rectangle()
                    .fill(Color.harnessLineStrong)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(step.observation)
                    .font(HFont.observation)
                    .foregroundStyle(Color.harnessText3)
                    .lineSpacing(2)
                Text(step.intent)
                    .font(HFont.row)
                    .foregroundStyle(Color.harnessText)
                    .lineSpacing(2)
                HStack(spacing: 8) {
                    ToolCallChip(kind: step.action.kind, arg: step.action.arg)
                    if let f = step.friction {
                        FrictionTag(kind: f.kind)
                    }
                    Spacer(minLength: 0)
                    if step.thumbnail != nil {
                        thumbView
                    }
                }
                if let f = step.friction {
                    Text(f.note)
                        .font(HFont.caption)
                        .foregroundStyle(Color.harnessText3)
                        .lineSpacing(2)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.harnessWarning.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.harnessWarning).frame(width: 2)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if current {
                Rectangle().fill(Color.harnessAccent).frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(step.n): \(step.intent)"))
        .accessibilityHint(step.friction.map { "Flagged \($0.kind.rawValue)" } ?? "")
    }

    @ViewBuilder private var rowBackground: some View {
        if step.friction != nil {
            Color.harnessWarning.opacity(0.08)
        } else if current {
            Color.harnessAccentSoft
        } else {
            Color.clear
        }
    }

    private var thumbView: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color(.sRGB, white: 0.98, opacity: 1), Color(.sRGB, white: 0.92, opacity: 1)], startPoint: .top, endPoint: .bottom))
            .frame(width: 32, height: 56)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.harnessLineStrong, lineWidth: 0.5))
    }
}

#Preview {
    VStack(spacing: 0) {
        ForEach(PreviewStep.mocks.prefix(3)) { StepFeedCell(step: $0) }
        StepFeedCell(step: PreviewStep.mocks[4])  // friction
        StepFeedCell(step: PreviewStep.mocks[5], current: true)
    }
    .frame(width: 360)
    .background(Color.harnessPanel)
}
