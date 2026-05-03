//
//  StatusChip.swift
//

import SwiftUI

enum StatusKind { case running, awaiting, paused, done }

struct StatusChip: View {
    let kind: StatusKind
    @State private var pulsing = false

    private var color: Color {
        switch kind {
        case .running:  return .harnessAccent
        case .awaiting: return .harnessWarning
        case .paused:   return .harnessText3
        case .done:     return .harnessSuccess
        }
    }
    private var label: String {
        switch kind {
        case .running:  return "Running"
        case .awaiting: return "Awaiting approval"
        case .paused:   return "Paused"
        case .done:     return "Done"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if kind == .running {
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 1)
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulsing ? 1.3 : 0.6)
                        .opacity(pulsing ? 0 : 1)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulsing)
                }
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Capsule().fill(color.opacity(0.14))
        )
        .overlay(
            Capsule().stroke(color.opacity(0.30), lineWidth: 0.5)
        )
        .onAppear { pulsing = true }
        .accessibilityLabel(Text("Status \(label)"))
    }
}

#Preview {
    VStack {
        StatusChip(kind: .running)
        StatusChip(kind: .awaiting)
        StatusChip(kind: .paused)
        StatusChip(kind: .done)
    }
    .padding().background(Color.harnessBg)
}
