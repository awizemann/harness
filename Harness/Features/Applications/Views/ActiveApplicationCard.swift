//
//  ActiveApplicationCard.swift
//  Harness
//
//  Sidebar header card shown between LIBRARY and WORKSPACE sections when an
//  Application is active. Surfaces the active app's name + a one-click
//  "Switch" menu, plus a quick "Edit application…" jump.
//

import SwiftUI

struct ActiveApplicationCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    let application: ApplicationSnapshot
    /// Other non-archived applications, sorted by `lastUsedAt`. The Switch
    /// menu lists these so the user can flip without leaving the sidebar.
    let allApplications: [ApplicationSnapshot]
    let onSwitch: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.spacing.s) {
                // Per-platform icon — surfaces what kind of app this is.
                // Phase 1 ships only iOS, so this is always `iphone.gen3`
                // today; Phase 2 / 3 light up `macwindow` and `globe`.
                Image(systemName: application.platformKind.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.harnessAccent)
                    .help(application.platformKind.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(HFont.row.weight(.medium))
                        .foregroundStyle(Color.harnessText)
                        .lineLimit(1)
                    Text(application.scheme.isEmpty
                         ? application.projectURL.lastPathComponent
                         : application.scheme)
                        .font(HFont.micro)
                        .foregroundStyle(Color.harnessText3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    if otherApps.isEmpty {
                        Text("No other applications")
                    } else {
                        ForEach(otherApps, id: \.id) { app in
                            Button(app.name) { onSwitch(app.id) }
                        }
                    }
                    Divider()
                    Button("Manage applications…") {
                        coordinator.selectedSection = .applications
                    }
                } label: {
                    Label("Switch", systemImage: "arrow.left.arrow.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Switch active application")
            }
            .padding(.horizontal, Theme.spacing.s)
            .padding(.vertical, Theme.spacing.s)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.panel, style: .continuous)
                .fill(Color.harnessAccentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel, style: .continuous)
                .stroke(Color.harnessLineSoft, lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.spacing.s)
        .padding(.vertical, Theme.spacing.xs)
    }

    private var otherApps: [ApplicationSnapshot] {
        allApplications.filter { $0.id != application.id && !$0.archived }
    }
}
