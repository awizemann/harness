//
//  Typography.swift
//  Harness
//
//  Font tokens. SF Pro Text for UI, SF Mono for logs/coords/JSON.
//

import SwiftUI

enum HFont {
    /// 22pt semibold — used for compose-screen headlines.
    static let title     = Font.system(size: 22, weight: .semibold, design: .default)
    /// 15pt semibold — section detail headings.
    static let h2        = Font.system(size: 15, weight: .semibold, design: .default)
    /// 13pt semibold — panel headers, sidebar headings.
    static let headline  = Font.system(size: 13, weight: .semibold, design: .default)
    /// 12.5pt regular — primary body text.
    static let body      = Font.system(size: 12.5, weight: .regular, design: .default)
    /// 12pt regular — list rows.
    static let row       = Font.system(size: 12, weight: .regular, design: .default)
    /// 11.5pt regular — italic observation text in steps.
    static let observation = Font.system(size: 11.5, weight: .regular, design: .default).italic()
    /// 11pt regular — secondary copy.
    static let caption   = Font.system(size: 11, weight: .regular, design: .default)
    /// 10.5pt regular — pills, micro-labels.
    static let micro     = Font.system(size: 10.5, weight: .medium, design: .default)
    /// 10pt mono uppercased letterspaced — section keys, metadata labels.
    static let metaKey   = Font.system(size: 10, weight: .medium, design: .monospaced)

    // MARK: Mono variants
    /// SF Mono 11pt — chip text, JSON, coords.
    static let mono      = Font.system(size: 11, weight: .medium, design: .monospaced)
    /// SF Mono 12pt — input fields and stepper.
    static let monoLg    = Font.system(size: 12, weight: .regular, design: .monospaced)
    /// SF Mono 16pt tabular — stat values.
    static let monoStat  = Font.system(size: 16, weight: .medium, design: .monospaced)
        .monospacedDigit()

    // MARK: Variable-size helpers
    //
    // The fixed tokens above cover the standard scale. Designer mocks
    // sometimes pixel-tune individual elements (e.g. an inline label at
    // 11.5pt or a key cap at 10.5pt mono); these helpers let the
    // production view match the mock without inventing one-off `.system`
    // calls scattered across feature code. Prefer the fixed tokens when
    // the size matches; reach for these when it doesn't.

    /// SF Pro Text at the requested size + weight (regular by default).
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }

    /// Convenience for the common semibold pairing.
    static func uiSemibold(_ size: CGFloat) -> Font {
        Font.system(size: size, weight: .semibold, design: .default)
    }

    /// SF Mono at the requested size + weight (medium by default — mono
    /// reads thin at lower sizes so we match the fixed-token weight).
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Convenience for "uppercase + tracked" metadata labels.
    func metaKeyStyle(_ color: Color = .harnessText4) -> some View {
        self.font(HFont.metaKey)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
