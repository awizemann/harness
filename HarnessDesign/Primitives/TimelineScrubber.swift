//
//  TimelineScrubber.swift
//

import SwiftUI

/// Horizontal scrubber with one tick per step. Friction events render as taller amber ticks.
///
/// Phase E added optional `legBoundaries`: 0-based step indices that
/// start a chain leg. They render as accent-colored, slightly thicker
/// ticks behind the friction overlay so a chain replay reads as a few
/// distinct sections at a glance. Default empty set keeps existing
/// call sites behaving identically.
struct TimelineScrubber: View {
    let stepCount: Int
    /// Indices (0-based) that should render as friction ticks.
    let frictionIndices: Set<Int>
    /// Indices (0-based) that mark the first step of a chain leg.
    /// Optional — pass `[]` (default) for non-chain runs to render the
    /// pre-Phase-E look.
    let legBoundaries: Set<Int>
    @Binding var current: Int

    init(
        stepCount: Int,
        frictionIndices: Set<Int>,
        legBoundaries: Set<Int> = [],
        current: Binding<Int>
    ) {
        self.stepCount = stepCount
        self.frictionIndices = frictionIndices
        self.legBoundaries = legBoundaries
        self._current = current
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(1, stepCount - 1)
            ZStack(alignment: .leading) {
                // track
                Capsule().fill(Color.harnessLineStrong).frame(height: 4).offset(y: 0)
                // fill
                Capsule()
                    .fill(Color.harnessAccent)
                    .frame(width: max(0, CGFloat(current) / CGFloat(span) * w), height: 4)
                // ticks
                ForEach(0..<stepCount, id: \.self) { i in
                    let x = CGFloat(i) / CGFloat(span) * w
                    let f = frictionIndices.contains(i)
                    let leg = legBoundaries.contains(i)
                    Rectangle()
                        .fill(tickColor(friction: f, leg: leg))
                        .frame(width: leg ? 3 : 2, height: tickHeight(friction: f, leg: leg))
                        .position(x: x, y: geo.size.height / 2)
                }
                // thumb
                Circle()
                    .fill(Color.harnessAccent)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.harnessPanel, lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .position(x: CGFloat(current) / CGFloat(span) * w, y: geo.size.height / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let x = max(0, min(w, v.location.x))
                let n = Int((x / w) * CGFloat(span) + 0.5)
                if n != current { current = n }
            })
        }
        .frame(height: 28)
        .accessibilityValue(Text("Step \(current + 1) of \(stepCount)"))
    }

    /// Friction takes precedence (warning amber). Otherwise leg
    /// boundaries are accent. Default ticks are the pre-Phase-E
    /// muted color.
    private func tickColor(friction: Bool, leg: Bool) -> Color {
        if friction { return Color.harnessWarning }
        if leg { return Color.harnessAccent }
        return Color.harnessText4
    }

    /// Friction is tallest (14pt). Leg boundaries are slightly taller
    /// than default (12pt) so they read as section dividers without
    /// fighting friction emphasis.
    private func tickHeight(friction: Bool, leg: Bool) -> CGFloat {
        if friction { return 14 }
        if leg { return 12 }
        return 8
    }
}

#Preview {
    @Previewable @State var i = 4
    return TimelineScrubber(
        stepCount: 8,
        frictionIndices: [4],
        legBoundaries: [3],
        current: $i
    )
    .padding().frame(width: 480).background(Color.harnessBg)
}
