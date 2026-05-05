//
//  PlatformKind.swift
//  Harness
//
//  Discriminator for what kind of application Harness is driving. Stored on
//  `Application.platformKindRaw`, surfaced in the run-history index, and
//  read by views to pick the right per-platform icon.
//
//  Phase 1 ships only `.iosSimulator` as a working option. `.macosApp` and
//  `.web` are reserved for Phase 2 and Phase 3 respectively — the cases
//  exist today so the storage shape is forward-compatible (no future
//  schema bump for the discriminator itself).
//
//  See `https://github.com/awizemann/harness/wiki/Architecture-Overview`
//  for the full per-platform breakdown.
//

import Foundation

/// What kind of application a Harness `Application` describes.
///
/// Raw values are stored on disk via `Application.platformKindRaw` — never
/// rename them without a SwiftData migration that rewrites existing rows.
enum PlatformKind: String, Codable, CaseIterable, Sendable, Hashable {
    case iosSimulator = "ios_simulator"
    case macosApp     = "macos_app"
    case web          = "web"

    /// Default for Applications that pre-date the discriminator (V3→V4
    /// migration uses this) and for any code path that omits the field.
    static let `default`: PlatformKind = .iosSimulator

    /// Lenient decoder for the raw string. Unknown strings fall back to the
    /// default rather than throwing — the field appeared mid-V3 stores via
    /// optional fallback before V4 made it real, and we want crashing on
    /// "unknown_kind" to never be a possibility on user upgrade.
    static func from(rawValue: String?) -> PlatformKind {
        guard let raw = rawValue, let kind = PlatformKind(rawValue: raw) else {
            return .default
        }
        return kind
    }

    /// Short label for navigation chrome (sidebar rows, breadcrumbs).
    var shortLabel: String {
        switch self {
        case .iosSimulator: "iOS"
        case .macosApp:     "macOS"
        case .web:          "Web"
        }
    }

    /// Long label for forms and detail screens.
    var displayName: String {
        switch self {
        case .iosSimulator: "iOS Simulator"
        case .macosApp:     "macOS App"
        case .web:          "Web App"
        }
    }

    /// One-line subtitle the create/detail UI uses next to the segment label.
    var subtitle: String {
        switch self {
        case .iosSimulator: "Drive the iOS Simulator with WebDriverAgent."
        case .macosApp:     "Drive a macOS app via CGEvent + window capture."
        case .web:          "Drive a URL in an embedded WebKit browser."
        }
    }

    /// SF Symbol name for the platform icon. Used in the sidebar, the
    /// platform segmented control, and per-row chrome.
    var symbolName: String {
        switch self {
        case .iosSimulator: "iphone.gen3"
        case .macosApp:     "macwindow"
        case .web:          "globe"
        }
    }

    /// Whether the platform is selectable in the create-Application UI today.
    /// Phase 1 ships only iOS as user-selectable; the other two are visible
    /// but locked with a "Coming soon" affordance until Phase 2 / 3 land.
    var isAvailable: Bool {
        switch self {
        case .iosSimulator: true
        case .macosApp:     false
        case .web:          false
        }
    }

    /// User-facing copy for the "Coming soon" disabled state.
    var availabilityNote: String? {
        switch self {
        case .iosSimulator: nil
        case .macosApp:     "Coming soon — Phase 2"
        case .web:          "Coming soon — Phase 3"
        }
    }
}
