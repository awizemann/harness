//
//  FrictionTag.swift
//

import SwiftUI

struct FrictionTag: View {
    let kind: FrictionKind
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(kind.rawValue)
                .font(HFont.micro)
        }
        .foregroundStyle(Color.harnessWarning)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: Theme.radius.pill).fill(Color.harnessWarning.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.pill).stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5))
        .accessibilityLabel(Text("Friction: \(kind.rawValue)"))
    }
}

#Preview {
    VStack { FrictionTag(kind: .ambiguousAffordance); FrictionTag(kind: .missingUndo) }
        .padding().background(Color.harnessBg)
}
