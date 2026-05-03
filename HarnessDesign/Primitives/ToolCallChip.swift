//
//  ToolCallChip.swift
//

import SwiftUI

/// Small monospaced pill rendering a tool call: `tap (124, 480)`, `type "milk"`, `swipe ↑`.
/// Color-coded by action kind.
struct ToolCallChip: View {
    let kind: PreviewToolKind
    let arg: String?

    private var color: Color {
        switch kind {
        case .tap:      return .harnessToolTap
        case .type:     return .harnessToolType
        case .swipe:    return .harnessToolSwipe
        case .scroll:   return .harnessToolScroll
        case .wait:     return .harnessToolWait
        case .complete: return .harnessSuccess
        }
    }

    private var symbol: String {
        switch kind {
        case .tap:      return "hand.point.up.left"
        case .type:     return "character.cursor.ibeam"
        case .swipe:    return "hand.draw"
        case .scroll:   return "arrow.up.arrow.down"
        case .wait:     return "hourglass"
        case .complete: return "checkmark.circle.fill"
        }
    }

    private var verb: String {
        switch kind {
        case .tap:      return "tap"
        case .type:     return "type"
        case .swipe:    return "swipe"
        case .scroll:   return "scroll"
        case .wait:     return "wait"
        case .complete: return "complete"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(verb)
                .font(HFont.mono)
            if let arg {
                Text(arg)
                    .font(HFont.mono)
                    .foregroundStyle(color.opacity(0.75))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.chip)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.chip)
                .stroke(color.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityLabel(Text("\(verb) \(arg ?? "")"))
    }
}

#Preview {
    VStack(spacing: 8) {
        ToolCallChip(kind: .tap,    arg: "(124, 480)")
        ToolCallChip(kind: .type,   arg: "\"milk\"")
        ToolCallChip(kind: .swipe,  arg: "← (180, 218)")
        ToolCallChip(kind: .scroll, arg: "↓ 240")
        ToolCallChip(kind: .wait,   arg: "300ms")
        ToolCallChip(kind: .complete, arg: nil)
    }
    .padding()
    .background(Color.harnessBg)
}
