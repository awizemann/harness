//
//  SidebarView.swift
//  Harness
//
//  Left-rail navigation. Reads coordinator state; mutates only via coordinator
//  methods (setting `selectedSection` directly is fine — it's the canonical
//  navigation surface).
//

import SwiftUI

struct SidebarView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var coord = coordinator
        List(selection: $coord.selectedSection) {
            Section {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }

            Section("Health") {
                healthRow(label: "API key", ok: state.apiKeyPresent)
                healthRow(label: "xcodebuild", ok: state.xcodebuildAvailable)
                healthRow(label: "idb", ok: state.idbHealthy)
                if !state.simulators.isEmpty {
                    Label("\(state.simulators.count) simulators", systemImage: "iphone.gen3")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.sidebar)
    }

    private func healthRow(label: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
