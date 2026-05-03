//
//  PanelContainer.swift
//

import SwiftUI

/// Rounded-rectangle container with subtle border + material background.
/// Optional title slot; content is placed under it with `Theme.spacing.m` padding.
struct PanelContainer<Content: View>: View {
    var title: String? = nil
    var trailing: (() -> AnyView)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(HFont.headline)
                        .foregroundStyle(Color.harnessText)
                    Spacer()
                    trailing?()
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.harnessLine)
                        .frame(height: 0.5)
                }
            }
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .fill(Color.harnessPanel)
        )
        .harnessHairlineBorder()
    }
}

#Preview("PanelContainer") {
    HStack(spacing: 24) {
        PanelContainer(title: "Agent summary") {
            Text("Goal completed in 8 steps. Found the add affordance immediately.")
                .font(HFont.body)
                .foregroundStyle(Color.harnessText2)
                .padding(14)
        }
        .frame(width: 320)
        .preferredColorScheme(.dark)

        PanelContainer(title: "Agent summary") {
            Text("Goal completed in 8 steps. Found the add affordance immediately.")
                .font(HFont.body)
                .foregroundStyle(Color.harnessText2)
                .padding(14)
        }
        .frame(width: 320)
        .preferredColorScheme(.light)
    }
    .padding()
    .background(Color.harnessBg)
}
