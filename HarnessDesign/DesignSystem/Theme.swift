//
//  Theme.swift
//  Harness
//
//  Spacing, radii, and font tokens. Pure values; no SwiftUI views.
//

import SwiftUI

/// Single source of truth for non-color design tokens.
/// Use as `Theme.spacing.m`, `Theme.radius.panel`, `Theme.font.body`.
enum Theme {

    // MARK: Spacing — xs/s/m/l/xl
    enum spacing {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radii
    enum radius {
        static let chip:    CGFloat = 5
        static let pill:    CGFloat = 4
        static let button:  CGFloat = 6
        static let input:   CGFloat = 6
        static let panel:   CGFloat = 8
        static let card:    CGFloat = 10
        static let sheet:   CGFloat = 12
        static let window:  CGFloat = 12
    }

    // MARK: Stroke widths
    enum hairline {
        static let line:        CGFloat = 0.5
        static let lineStrong:  CGFloat = 1.0
    }

    // MARK: Animation curves & durations
    enum motion {
        static let micro:    Animation = .easeOut(duration: 0.12)
        static let standard: Animation = .easeInOut(duration: 0.22)
        static let approval: Animation = .spring(response: 0.32, dampingFraction: 0.84)
        static let tapDotFade: Animation = .easeOut(duration: 0.8)
    }

    // MARK: Fonts — see Typography.swift for the full token set
    enum font {
        static let title    = HFont.title
        static let headline = HFont.headline
        static let body     = HFont.body
        static let caption  = HFont.caption
        static let mono     = HFont.mono
    }
}
