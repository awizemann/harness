//
//  Materials.swift
//  Harness
//
//  Helpers for system materials & ultra-thin chrome (toolbars, sidebars, sheets).
//  Wraps SwiftUI's Material so we can swap in custom blurs later if needed.
//

import SwiftUI

enum HarnessMaterial {
    /// Sidebars and toolbar surfaces — closest to Linear/Cursor chrome.
    static var chrome: Material  { .regularMaterial }
    /// Floating sheets and approval cards.
    static var floating: Material { .thinMaterial }
    /// Status bar and live overlays inside the simulator mirror.
    static var overlay: Material  { .ultraThinMaterial }
}

extension View {
    /// Subtle inset highlight + 0.5pt border used by panels.
    func harnessHairlineBorder(_ color: Color = .harnessLine, radius: CGFloat = Theme.radius.panel) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(color, lineWidth: 0.5)
        )
    }
}
