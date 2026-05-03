//
//  SegmentedToggle.swift
//

import SwiftUI

/// Modern segmented control replacement (Linear-style). Generic over `Hashable` value.
struct SegmentedToggle<T: Hashable>: View {
    struct Option: Identifiable {
        let id: T
        let label: String
        let symbol: String?
        init(_ value: T, _ label: String, symbol: String? = nil) {
            self.id = value; self.label = label; self.symbol = symbol
        }
    }
    let options: [Option]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options) { opt in
                Button { selection = opt.id } label: {
                    HStack(spacing: 5) {
                        if let s = opt.symbol { Image(systemName: s).font(.system(size: 10, weight: .semibold)) }
                        Text(opt.label).font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(selection == opt.id ? Color.harnessText : Color.harnessText3)
                    .padding(.horizontal, 12).frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selection == opt.id ? Color.harnessElevated : Color.clear)
                            .shadow(color: selection == opt.id ? .black.opacity(0.10) : .clear, radius: 1, y: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(selection == opt.id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.harnessPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.harnessLineStrong, lineWidth: 0.5))
        .animation(Theme.motion.micro, value: selection)
    }
}

#Preview {
    @Previewable @State var s = "1"
    return SegmentedToggle(options: [
        .init("1", "1×"), .init("2", "2×"), .init("4", "4×"),
    ], selection: $s)
    .padding().background(Color.harnessBg)
}
