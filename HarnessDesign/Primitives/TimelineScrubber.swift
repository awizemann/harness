//
//  TimelineScrubber.swift
//

import SwiftUI

/// Horizontal scrubber with one tick per step. Friction events render as taller amber ticks.
struct TimelineScrubber: View {
    let stepCount: Int
    /// Indices (0-based) that should render as friction ticks.
    let frictionIndices: Set<Int>
    @Binding var current: Int

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
                    Rectangle()
                        .fill(f ? Color.harnessWarning : Color.harnessText4)
                        .frame(width: 2, height: f ? 14 : 8)
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
}

#Preview {
    @Previewable @State var i = 4
    return TimelineScrubber(stepCount: 8, frictionIndices: [4], current: $i)
        .padding().frame(width: 480).background(Color.harnessBg)
}
