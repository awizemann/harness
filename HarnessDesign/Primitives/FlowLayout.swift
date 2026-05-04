//
//  FlowLayout.swift
//

import SwiftUI

/// Minimal flow layout: lays out subviews left-to-right and wraps when the
/// proposed width is exceeded. Useful for chip lists where the count is
/// data-driven and a fixed-column grid would clip or waste space.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

#Preview {
    FlowLayout(spacing: 6) {
        ToolCallChip(kind: .tap, arg: "(338, 92)")
        ToolCallChip(kind: .type, arg: "\"milk\"")
        ToolCallChip(kind: .tap, arg: "(338, 716)")
        ToolCallChip(kind: .wait, arg: "300ms")
        ToolCallChip(kind: .tap, arg: "(48, 218)")
        ToolCallChip(kind: .swipe, arg: "← (180, 218)")
        ToolCallChip(kind: .complete, arg: nil)
    }
    .padding().frame(width: 480).background(Color.harnessBg)
}
