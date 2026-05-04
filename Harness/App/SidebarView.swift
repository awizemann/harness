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
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var state
    @State private var selectedRunFrictionCount: Int = 0

    var body: some View {
        @Bindable var coord = coordinator
        List(selection: $coord.selectedSection) {
            Section {
                ForEach(SidebarSection.allCases) { section in
                    sidebarRow(section: section)
                        .tag(section)
                }
            }

            Section("Health") {
                healthRow(label: "API key", ok: state.apiKeyPresent)
                healthRow(label: "xcodebuild", ok: state.xcodebuildAvailable)
                healthRow(
                    label: state.wdaBuildInProgress ? "WebDriverAgent (building…)" : "WebDriverAgent",
                    ok: state.wdaReady
                )
                if !state.simulators.isEmpty {
                    Label("\(state.simulators.count) simulators", systemImage: "iphone.gen3")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !healthOK {
                    Button("Open setup…") {
                        coordinator.isFirstRunWizardOpen = true
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .task(id: coordinator.selectedHistoryRunID) {
            await refreshSelectedRunFriction()
        }
    }

    @ViewBuilder
    private func sidebarRow(section: SidebarSection) -> some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
            Spacer()
            if section == .friction, selectedRunFrictionCount > 0 {
                badge("\(selectedRunFrictionCount)", color: Color.harnessWarning)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(HFont.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 0.5))
    }

    /// Fetch the selected run's friction count out of band so the badge
    /// stays in sync without forcing the whole sidebar to depend on the
    /// run history list.
    @MainActor
    private func refreshSelectedRunFriction() async {
        guard let id = coordinator.selectedHistoryRunID else {
            selectedRunFrictionCount = 0
            return
        }
        let snapshot = try? await container.runHistory.fetch(id: id)
        selectedRunFrictionCount = snapshot?.frictionCount ?? 0
    }

    private var healthOK: Bool {
        state.apiKeyPresent && state.xcodebuildAvailable && state.wdaReady
    }

    private func healthRow(label: String, ok: Bool) -> some View {
        HStack(spacing: Theme.spacing.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ok ? Color.harnessSuccess : Color.harnessWarning)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
