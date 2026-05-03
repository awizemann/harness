//
//  Colors.swift
//  Harness
//
//  Semantic color tokens with explicit light/dark variants.
//  Built from the mint-accent palette defined in the design HTML.
//

import SwiftUI
import AppKit

extension Color {
    /// Build a Color that switches based on the current appearance.
    /// Wrapping NSColor lets us avoid Asset catalogs while staying appearance-aware.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
    }
}

extension Color {

    // MARK: Backgrounds
    static let harnessBg        = Color(light: Color(hex: 0xF4F4F5), dark: Color(hex: 0x0E0F12))
    static let harnessBg2       = Color(light: Color(hex: 0xECECEE), dark: Color(hex: 0x16181C))
    static let harnessBg3       = Color(light: Color(hex: 0xFAFAFA), dark: Color(hex: 0x1C1E23))
    static let harnessPanel     = Color(light: Color.white,           dark: Color(hex: 0x16181C))
    static let harnessPanel2    = Color(light: Color(hex: 0xF7F7F8), dark: Color(hex: 0x1B1E24))
    static let harnessElevated  = Color(light: Color.white,           dark: Color(hex: 0x21242B))
    static let harnessWindow    = Color(light: Color(hex: 0xECECEE), dark: Color(hex: 0x1A1C20))

    // MARK: Lines
    static let harnessLine       = Color(light: .black.opacity(0.07), dark: .white.opacity(0.06))
    static let harnessLineStrong = Color(light: .black.opacity(0.12), dark: .white.opacity(0.10))
    static let harnessLineSoft   = Color(light: .black.opacity(0.04), dark: .white.opacity(0.04))

    // MARK: Text
    static let harnessText      = Color(light: Color(hex: 0x18181B), dark: Color(hex: 0xE8E8EA))
    static let harnessText2     = Color(light: Color(hex: 0x404045), dark: Color(hex: 0xB6B8BD))
    static let harnessText3     = Color(light: Color(hex: 0x6A6B70), dark: Color(hex: 0x8A8B90))
    static let harnessText4     = Color(light: Color(hex: 0x98999E), dark: Color(hex: 0x5F6168))

    // MARK: Accent — mint
    static let harnessAccent          = Color(light: Color(hex: 0x12936A), dark: Color(hex: 0x3DDC97))
    static let harnessAccentSecondary = Color(light: Color(hex: 0x0E7B5A), dark: Color(hex: 0x6BE5B0))
    static let harnessAccentForeground = Color(light: .white, dark: Color(hex: 0x06140E))
    static let harnessAccentSoft     = Color(light: Color(hex: 0x12936A).opacity(0.10),
                                              dark: Color(hex: 0x3DDC97).opacity(0.14))

    // MARK: Verdict semantics
    static let harnessSuccess = Color(light: Color(hex: 0x167A4F), dark: Color(hex: 0x4DD493))
    static let harnessWarning = Color(light: Color(hex: 0xB57014), dark: Color(hex: 0xF5A524))   // friction
    static let harnessFailure = Color(light: Color(hex: 0xC2362B), dark: Color(hex: 0xF06A5E))
    static let harnessBlocked = Color(light: Color(hex: 0xA0741D), dark: Color(hex: 0xD9B26A))

    // MARK: Tool-call kinds (chip color coding)
    static let harnessToolTap    = Color(light: Color(hex: 0x2E5BFF), dark: Color(hex: 0x6C9BFF))
    static let harnessToolType   = Color(light: Color(hex: 0x1E8A50), dark: Color(hex: 0x55D599))
    static let harnessToolSwipe  = Color(light: Color(hex: 0x6E3DC8), dark: Color(hex: 0xB497FF))
    static let harnessToolScroll = Color(light: Color(hex: 0xB04079), dark: Color(hex: 0xE99FC2))
    static let harnessToolWait   = Color(light: Color(hex: 0x6A6B70), dark: Color(hex: 0x8A8B90))
}

// MARK: - hex init
private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
