//
//  ApplicationCreateView.swift
//  Harness
//
//  Sheet for adding a new Application. Mirrors today's `GoalInputView`
//  Project + Simulator + Run-options sections, but instead of building a
//  `GoalRequest` it persists an `ApplicationSnapshot`.
//

import SwiftUI
import AppKit

struct ApplicationCreateView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    let applicationsVM: ApplicationsViewModel

    @State private var vm: ApplicationCreateViewModel?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
                    .onAppear { vm.seedFromAppState(state) }
            } else {
                Color.clear.onAppear {
                    let picker = ProjectPicker(
                        processRunner: container.processRunner,
                        toolLocator: container.toolLocator,
                        xcodeBuilder: container.xcodeBuilder
                    )
                    self.vm = ApplicationCreateViewModel(picker: picker)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: ApplicationCreateViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Application").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.spacing.l)
            .padding(.top, Theme.spacing.l)
            .padding(.bottom, Theme.spacing.s)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    NameSection(vm: vm)
                    PlatformSection()
                    ProjectSection(vm: vm)
                    SimulatorSection(vm: vm)
                    DefaultsSection(vm: vm)
                    if let err = vm.saveError {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(Color.harnessFailure)
                    }
                }
                .padding(Theme.spacing.l)
            }

            Divider()
            HStack {
                Spacer()
                Button("Add Application") {
                    Task { await save(vm: vm) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.spacing.l)
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 560)
    }

    private func save(vm: ApplicationCreateViewModel) async {
        guard let snapshot = vm.makeSnapshot(simulators: state.simulators) else {
            vm.saveError = "Form validation failed."
            return
        }
        let saved = await applicationsVM.save(snapshot)
        if saved {
            // Auto-pick the new Application as active if no scope is set yet.
            if coordinator.selectedApplicationID == nil {
                await applicationsVM.setActive(snapshot.id)
            }
            dismiss()
        }
    }
}

// MARK: - Sections

private struct NameSection: View {
    @Bindable var vm: ApplicationCreateViewModel
    var body: some View {
        PanelContainer(title: "Name") {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                TextField("e.g. ListApp", text: $vm.name)
                    .textFieldStyle(.roundedBorder)
                Text("Used in the sidebar and run history. You can rename later.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.l)
        }
    }
}

/// Phase-1 platform picker. iOS Simulator is the only working option today;
/// macOS / Web are visible but disabled with a "Coming soon" affordance,
/// which gives the user a preview of where the project is headed and lets
/// us validate the segmented-control layout before Phase 2/3 ship the
/// driver implementations.
///
/// The selection isn't bound to view-model state because nothing is
/// configurable yet — the create flow always saves `platformKindRaw =
/// "ios_simulator"`. When Phase 2 lands, this section gains a
/// `@Bindable var vm` and the disabled options become live.
private struct PlatformSection: View {
    var body: some View {
        PanelContainer(title: "Platform") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                HStack(spacing: Theme.spacing.s) {
                    ForEach(PlatformKind.allCases, id: \.self) { kind in
                        PlatformChip(kind: kind, isSelected: kind == .iosSimulator)
                    }
                }
                Text("iOS Simulator is the only working target today. macOS and Web land in Phase 2 and Phase 3 — see the public roadmap.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.l)
        }
    }
}

private struct PlatformChip: View {
    let kind: PlatformKind
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(kind.shortLabel)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            if let note = kind.availabilityNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(kind.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.button, style: .continuous)
                .fill(isSelected ? Color.harnessAccentSoft : Color.harnessPanel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.button, style: .continuous)
                .stroke(isSelected ? Color.harnessAccent : Color.harnessLineStrong, lineWidth: isSelected ? 1.4 : 1)
        )
        .opacity(kind.isAvailable ? 1.0 : 0.55)
    }
}

private struct ProjectSection: View {
    @Bindable var vm: ApplicationCreateViewModel

    var body: some View {
        // Bind to picker via @Bindable.
        let _ = vm.picker
        PanelContainer(title: "Project") {
            ProjectInner(vm: vm, picker: vm.picker)
                .padding(Theme.spacing.l)
        }
    }
}

private struct ProjectInner: View {
    @Bindable var vm: ApplicationCreateViewModel
    @Bindable var picker: ProjectPicker

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            HStack {
                if let url = picker.projectURL {
                    Image(systemName: "hammer.fill").foregroundStyle(Color.harnessAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(picker.projectDisplayName).font(.body)
                        Text(url.path).font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text("No project selected").foregroundStyle(.secondary)
                }
                Spacer()
                Button(picker.projectURL == nil ? "Choose…" : "Re-pick…") {
                    Task {
                        await picker.pickProject()
                        vm.adoptProjectName()
                    }
                }
            }
            if picker.projectURL != nil {
                HStack {
                    Text("Scheme").frame(width: 80, alignment: .leading)
                    if picker.availableSchemes.isEmpty {
                        TextField("e.g. MyApp", text: $picker.selectedScheme)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $picker.selectedScheme) {
                            ForEach(picker.availableSchemes, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    if picker.isResolvingSchemes || picker.isProbingDestinations {
                        ProgressView().controlSize(.small)
                    }
                }
                if let err = picker.schemeError {
                    Text(err).font(.caption).foregroundStyle(Color.harnessWarning)
                }
                if let summary = picker.schemeCompatibilitySummary {
                    HStack(spacing: Theme.spacing.s) {
                        Image(systemName: picker.schemeSupportsIOSSimulator
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(picker.schemeSupportsIOSSimulator
                                             ? Color.harnessSuccess : Color.harnessWarning)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(picker.schemeSupportsIOSSimulator
                                             ? .secondary : .primary)
                    }
                    .padding(.leading, 88)
                }
            }
        }
    }
}

private struct SimulatorSection: View {
    @Environment(AppState.self) private var state
    @Bindable var vm: ApplicationCreateViewModel

    var body: some View {
        PanelContainer(title: "Default simulator") {
            HStack {
                if state.simulators.isEmpty {
                    Text("No simulators discovered. Open Xcode, boot one, then refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "",
                        selection: Binding(
                            get: { vm.simulatorUDID ?? "" },
                            set: { vm.simulatorUDID = $0.isEmpty ? nil : $0 }
                        )
                    ) {
                        Text("Select…").tag("")
                        ForEach(state.simulators, id: \.udid) { sim in
                            Text("\(sim.name) · \(sim.runtime)").tag(sim.udid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Spacer()
                Button("Refresh") {
                    Task { await state.refreshSimulators() }
                }
                .buttonStyle(.borderless)
            }
            .padding(Theme.spacing.l)
        }
    }
}

private struct DefaultsSection: View {
    @Bindable var vm: ApplicationCreateViewModel
    var body: some View {
        PanelContainer(title: "Run defaults") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                HStack(spacing: Theme.spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text("Mode").font(.subheadline.weight(.medium))
                        Picker("", selection: $vm.defaultMode) {
                            Text("Step-by-step").tag(RunMode.stepByStep)
                            Text("Autonomous").tag(RunMode.autonomous)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text("Model").font(.subheadline.weight(.medium))
                        Picker("", selection: $vm.defaultModel) {
                            Text("Opus 4.7").tag(AgentModel.opus47)
                            Text("Sonnet 4.6").tag(AgentModel.sonnet46)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }
                HStack {
                    Text("Step budget").frame(width: 110, alignment: .leading)
                    Stepper(value: $vm.defaultStepBudget, in: 5...200) {
                        Text("\(vm.defaultStepBudget) steps")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 200, alignment: .leading)
                }
                Text("These override your global defaults when this Application is active.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.l)
        }
    }
}
