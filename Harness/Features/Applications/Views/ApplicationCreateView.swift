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
import UniformTypeIdentifiers

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
                    PlatformSection(vm: vm)
                    if vm.platformKind == .iosSimulator {
                        ProjectSection(vm: vm)
                        SimulatorSection(vm: vm)
                    } else if vm.platformKind == .macosApp {
                        MacLaunchSourceSection(vm: vm)
                    } else if vm.platformKind == .web {
                        WebSection(vm: vm)
                    }
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

/// Phase 2 platform picker. iOS + macOS selectable; Web is "Coming soon".
/// Tapping a chip flips `vm.platformKind`, which re-shapes the form
/// (Simulator section vs Mac-bundle section).
private struct PlatformSection: View {
    @Bindable var vm: ApplicationCreateViewModel

    var body: some View {
        PanelContainer(title: "Platform") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                HStack(spacing: Theme.spacing.s) {
                    ForEach(PlatformKind.allCases, id: \.self) { kind in
                        Button {
                            guard kind.isAvailable else { return }
                            vm.platformKind = kind
                        } label: {
                            PlatformChip(kind: kind, isSelected: kind == vm.platformKind)
                        }
                        .buttonStyle(.plain)
                        .disabled(!kind.isAvailable)
                    }
                }
                Text(platformHelpText)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var platformHelpText: String {
        switch vm.platformKind {
        case .iosSimulator:
            return "iOS Simulator. Provide an Xcode project + scheme; Harness builds with `xcodebuild` and drives the simulator via WebDriverAgent."
        case .macosApp:
            return "macOS app. Pick a pre-built .app (e.g. /System/Applications/TextEdit.app) for the fastest path, or provide a project + scheme to build with `xcodebuild` first."
        case .web:
            return "Web — coming in Phase 3."
        }
    }
}

/// macOS-only "Launch source" section. Single panel with a segmented
/// control choosing between **Pre-built `.app`** and **Xcode project**.
/// The chosen sub-form is shown; the other is hidden — `canSave`
/// validates only the chosen branch, and `makeSnapshot` persists only
/// that branch's fields. Replaces the earlier two-stacked-panels layout
/// (MacAppSection + ProjectSection) which read as "fill in both."
private struct MacLaunchSourceSection: View {
    @Bindable var vm: ApplicationCreateViewModel

    var body: some View {
        PanelContainer(title: "Launch source") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                Picker("", selection: $vm.macLaunchSource) {
                    ForEach(MacLaunchSource.allCases, id: \.self) { src in
                        Text(src.label).tag(src)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(helpText)
                    .font(.caption).foregroundStyle(.tertiary)

                // Sub-form for the chosen source. The other branch's
                // fields stay untouched in the view-model so the user
                // can flip back without losing input — only `makeSnapshot`
                // clears them on save.
                Group {
                    switch vm.macLaunchSource {
                    case .prebuiltBundle:
                        MacBundlePicker(vm: vm)
                    case .xcodeProject:
                        ProjectInner(vm: vm, picker: vm.picker, platform: .macosApp)
                    }
                }
                .padding(.top, Theme.spacing.xs)
            }
            .padding(Theme.spacing.l)
        }
    }

    private var helpText: String {
        switch vm.macLaunchSource {
        case .prebuiltBundle:
            return "Pick a pre-built .app and Harness launches it via NSWorkspace — no build step. Fastest path."
        case .xcodeProject:
            return "Provide an Xcode project + scheme; Harness builds it for macOS first, then drives the resulting .app."
        }
    }
}

/// Sub-form for the pre-built `.app` launch source. Pure file picker —
/// no compatibility banner, no scheme picker. Lifted out of the old
/// `MacAppSection` so the new `MacLaunchSourceSection` can compose it.
private struct MacBundlePicker: View {
    @Bindable var vm: ApplicationCreateViewModel

    var body: some View {
        HStack(spacing: Theme.spacing.s) {
            if let path = vm.macAppBundlePath, !path.isEmpty {
                Image(systemName: "macwindow")
                    .foregroundStyle(Color.harnessAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent)
                        .font(.callout.weight(.medium))
                    Text(path)
                        .font(HFont.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
                Text("No bundle picked yet")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(vm.macAppBundlePath != nil ? "Change…" : "Pick…") {
                pickAppBundle()
            }
            if vm.macAppBundlePath != nil {
                Button("Clear") { vm.macAppBundlePath = nil }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func pickAppBundle() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.title = "Pick a macOS app bundle"
        panel.prompt = "Pick"
        if panel.runModal() == .OK, let url = panel.url {
            vm.macAppBundlePath = url.path
        }
    }
}

/// Web-only sub-form: URL + viewport. The agent loads `webStartURL` in
/// an embedded `WKWebView` sized to the requested CSS-pixel viewport.
private struct WebSection: View {
    @Bindable var vm: ApplicationCreateViewModel

    var body: some View {
        PanelContainer(title: "Web app") {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                VStack(alignment: .leading, spacing: Theme.spacing.s) {
                    Text("Start URL")
                        .font(.callout.weight(.medium))
                    TextField("https://example.com/login", text: $vm.webStartURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Text("The agent loads this URL on first step. Cookies persist across legs in the same run.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: Theme.spacing.l) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Viewport width (px)")
                            .font(.callout.weight(.medium))
                        TextField("1280", value: $vm.webViewportWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Viewport height (px)")
                            .font(.callout.weight(.medium))
                        TextField("800", value: $vm.webViewportHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    Spacer()
                }
                Text("Default 1280×800 (desktop). Try 375×812 to test a mobile-shaped viewport.")
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
            // ProjectSection is the iOS form's project picker today.
            // The macOS form embeds `ProjectInner` directly in the
            // launch-source section, passing `.macosApp` for the
            // banner context — see `MacLaunchSourceSection`.
            ProjectInner(vm: vm, picker: vm.picker, platform: .iosSimulator)
                .padding(Theme.spacing.l)
        }
    }
}

/// Project + scheme picker. Used by both the iOS form (top-level
/// `ProjectSection`) and the macOS form's "Xcode project" launch
/// source. The `platform` parameter drives the compatibility banner
/// — iOS reads from `picker.schemeCompatibilitySummary` for
/// back-compat; macOS computes its own copy from the raw destinations
/// array so the iOS-flavoured "Harness needs an iOS Simulator target"
/// language never leaks through.
private struct ProjectInner: View {
    @Bindable var vm: ApplicationCreateViewModel
    @Bindable var picker: ProjectPicker
    let platform: PlatformKind

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
                SchemeCompatibilityBanner(picker: picker, platform: platform)
                    .padding(.leading, 88)
            }
        }
    }
}

/// Per-platform banner that summarises whether the picked scheme has a
/// destination matching the active platform. iOS uses the picker's
/// existing `schemeCompatibilitySummary` + `schemeSupportsIOSSimulator`
/// (back-compat — same copy as before). macOS reads the raw
/// `schemeDestinations` array directly and emits its own copy. Web
/// renders nothing — web Applications don't take a project.
private struct SchemeCompatibilityBanner: View {
    @Bindable var picker: ProjectPicker
    let platform: PlatformKind

    var body: some View {
        switch platform {
        case .iosSimulator:
            if let summary = picker.schemeCompatibilitySummary {
                bannerRow(
                    ok: picker.schemeSupportsIOSSimulator,
                    text: summary
                )
            } else {
                EmptyView()
            }
        case .macosApp:
            if let dests = picker.schemeDestinations {
                let hasMac = dests.contains(where: { $0.supportsMacOS })
                bannerRow(
                    ok: hasMac,
                    text: hasMac
                        ? "Scheme has a macOS destination — Harness will build for macOS."
                        : "Scheme has no macOS destination. Pick a different scheme or use a pre-built .app instead."
                )
            } else {
                EmptyView()
            }
        case .web:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bannerRow(ok: Bool, text: String) -> some View {
        HStack(spacing: Theme.spacing.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.harnessSuccess : Color.harnessWarning)
            Text(text)
                .font(.caption)
                .foregroundStyle(ok ? .secondary : .primary)
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
