//
//  ButtonStyles.swift
//  Harness
//
//  Primary/secondary button styles matching the macOS Linear/Cursor aesthetic.
//

import SwiftUI

// MARK: - AccentButtonStyle (filled, tinted, used for "Start Run" / "Approve")
struct AccentButtonStyle: ButtonStyle {
    enum Size { case regular, large }
    var size: Size = .regular
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let h: CGFloat = (size == .large) ? 32 : 26
        let pad: CGFloat = (size == .large) ? 16 : 12
        let font: Font = (size == .large) ? .system(size: 13, weight: .medium) : .system(size: 12, weight: .medium)

        configuration.label
            .font(font)
            .foregroundStyle(Color.harnessAccentForeground)
            .padding(.horizontal, pad)
            .frame(height: h)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.button)
                    .fill(Color.harnessAccent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.button)
                    .stroke(Color.harnessAccent.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: Color.harnessAccent.opacity(0.30), radius: 4, y: 2)
            .opacity(configuration.isPressed ? 0.86 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(Theme.motion.micro, value: configuration.isPressed)
    }
}

// MARK: - SecondaryButtonStyle (panel surface, used for everything else)
struct SecondaryButtonStyle: ButtonStyle {
    enum Tone { case neutral, danger }
    var tone: Tone = .neutral
    var fullWidth: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = {
            switch tone {
            case .neutral: return .harnessText
            case .danger:  return .harnessFailure
            }
        }()
        let h: CGFloat = compact ? 22 : 26
        let font: Font = compact ? .system(size: 11, weight: .medium) : .system(size: 12, weight: .medium)

        configuration.label
            .font(font)
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: h)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.button)
                    .fill(configuration.isPressed ? Color.harnessElevated : Color.harnessPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.button)
                    .stroke(Color.harnessLineStrong, lineWidth: 0.5)
            )
            .animation(Theme.motion.micro, value: configuration.isPressed)
    }
}

// MARK: - GhostButtonStyle (no chrome, used in toolbars)
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.harnessText2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.harnessLine : Color.clear)
            )
            .animation(Theme.motion.micro, value: configuration.isPressed)
    }
}
