//
//  SidebarView.swift
//  Harness
//
//  Left-rail navigation. Reads coordinator state; mutates only via coordinator
//  methods (setting `selectedSection` directly is fine — it's the canonical
//  navigation surface).
//
//  Layout:
//
//   LIBRARY      Applications / Personas / Actions  (always visible)
//   [Active card] header chip when an Application is selected
//   WORKSPACE    New Run / Active Run / History / Friction  (visible iff active app)
//   HEALTH       tooling badges (always)
//

import SwiftUI

struct SidebarView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var state

    @State private var selectedRunFrictionCount: Int = 0
    @State private var applications: [ApplicationSnapshot] = []
    @State private var activeApplication: ApplicationSnapshot?

    var body: some View {
        @Bindable var coord = coordinator
        List(selection: $coord.selectedSection) {
            librarySection

            if activeApplication != nil {
                Section {
                    activeCard
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if coordinator.selectedApplicationID != nil {
                workspaceSection
            }

            healthSection
        }
        .listStyle(.sidebar)
        .task(id: coordinator.selectedHistoryRunID) {
            await refreshSelectedRunFriction()
        }
        .task(id: coordinator.selectedApplicationID) {
            await refreshApplications()
        }
        .task {
            await refreshApplications()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var librarySection: some View {
        Section("Library") {
            ForEach(librarySections) { section in
                sidebarRow(section: section)
                    .tag(section)
            }
        }
    }

    @ViewBuilder
    private var activeCard: some View {
        if let app = activeApplication {
            ActiveApplicationCard(
                application: app,
                allApplications: applications,
                onSwitch: { newID in
                    coordinator.selectedApplicationID = newID
                    state.selectedApplicationID = newID
                    Task { await state.persistSettings() }
                }
            )
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        Section("Workspace") {
            ForEach(workspaceSections) { section in
                sidebarRow(section: section)
                    .tag(section)
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
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

    // MARK: Section content

    private var librarySections: [SidebarSection] {
        [.applications, .personas, .actions]
    }

    private var workspaceSections: [SidebarSection] {
        var out: [SidebarSection] = [.newRun]
        if coordinator.activeRunID != nil {
            out.append(.activeRun)
        }
        out.append(contentsOf: [.history, .friction])
        return out
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

    /// Refresh the cached Applications list and resolve the active card.
    @MainActor
    private func refreshApplications() async {
        let all = (try? await container.runHistory.applications(includeArchived: false)) ?? []
        self.applications = all
        if let id = coordinator.selectedApplicationID {
            self.activeApplication = all.first { $0.id == id }
        } else {
            self.activeApplication = nil
        }
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
