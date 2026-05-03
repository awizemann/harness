//
//  EmptyStateView.swift
//

import SwiftUI

/// Icon + headline + subtext + optional CTA. Used for "no runs yet", "no friction", etc.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let subtitle: String
    var ctaTitle: String? = nil
    var onCta: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.harnessAccentSoft)
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Color.harnessAccent)
            }
            .frame(width: 56, height: 56)
            VStack(spacing: 6) {
                Text(title).font(HFont.h2).foregroundStyle(Color.harnessText)
                Text(subtitle).font(HFont.caption).foregroundStyle(Color.harnessText3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let ctaTitle, let onCta {
                Button(action: onCta) { Text(ctaTitle) }.buttonStyle(AccentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview {
    EmptyStateView(symbol: "tray", title: "No runs yet", subtitle: "Hit ⌘N to start your first user test. Harness will boot a simulator and drive your app.", ctaTitle: "New Run", onCta: {})
        .frame(width: 540, height: 380)
        .background(Color.harnessBg)
}
