//
//  PlaceholderLibraryView.swift
//  Harness
//
//  Placeholder destinations for sidebar sections that ship in upcoming
//  phases. Phase C replaces `.personas`, Phase D replaces `.actions`.
//

import SwiftUI

enum PlaceholderLibraryKind {
    case personas
    case actions

    var title: String {
        switch self {
        case .personas: return "Personas"
        case .actions:  return "Actions"
        }
    }

    var subtitle: String {
        switch self {
        case .personas:
            return "A library of reusable persona prompts is in flight (Phase C). Personas you save here will replace the free-form Persona text field on every run."
        case .actions:
            return "An action + chain library is in flight (Phase D). Save common goals once, run them by name."
        }
    }
}

struct PlaceholderLibraryView: View {
    let kind: PlaceholderLibraryKind

    var body: some View {
        EmptyStateView(
            symbol: "hammer",
            title: "Coming soon",
            subtitle: kind.subtitle
        )
        .navigationTitle(kind.title)
    }
}
