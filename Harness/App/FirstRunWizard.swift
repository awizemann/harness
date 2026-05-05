//
//  FirstRunWizard.swift
//  Harness
//
//  Two-screen sheet shown on first launch (or when the API key is missing /
//  external tooling isn't healthy). Surfaces actionable copy-paste install
//  commands per `https://github.com/awizemann/harness/wiki/Build-and-Run`.
//

import SwiftUI

struct FirstRunWizard: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    @State private var apiKey: String = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var wdaBuildError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { contentBody.padding(Theme.spacing.xl) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color.harnessBg)
        .task { await state.refreshAll() }
    }

    private var header: some View {
        HStack(spacing: Theme.spacing.m) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.harnessAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Harness").font(.title3.weight(.semibold))
                Text("A minute of setup before your first user-test run.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.spacing.xl)
        .padding(.vertical, Theme.spacing.l)
    }

    @ViewBuilder
    private var contentBody: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.l) {
            apiKeySection
            toolingSection
            simulatorSection
        }
    }

    // MARK: API key

    private var apiKeySection: some View {
        WizardCard(
            title: "Anthropic API key",
            subtitle: "Stored in your macOS Keychain (service \"com.harness.anthropic\"). Never written to disk or logs."
        ) {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                if state.apiKeyPresent {
                    StatusLine(ok: true, label: "API key present")
                } else {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    if let err = saveError {
                        Text(err).font(.callout).foregroundStyle(Color.harnessFailure)
                    }
                    HStack {
                        Button("Save key") {
                            Task { await save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

                        Button("Get a key…") {
                            if let url = URL(string: "https://console.anthropic.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: Tooling

    private var toolingSection: some View {
        WizardCard(
            title: "External tools",
            subtitle: "Harness drives your iOS Simulator via xcodebuild + WebDriverAgent (vendored as a submodule)."
        ) {
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                StatusLine(ok: state.xcodebuildAvailable,
                           label: state.xcodebuildAvailable ? "xcodebuild available" : "xcodebuild not found")
                if !state.xcodebuildAvailable {
                    InstallHint(text: "Install Xcode from the App Store, then run:",
                                command: "xcode-select --install")
                }

                StatusLine(
                    ok: state.wdaReady,
                    label: wdaStatusLabel
                )
                if !state.wdaReady, !state.wdaBuildInProgress {
                    Text("Harness builds WebDriverAgent in-process — no shell command needed. First build takes 1–2 minutes; cached per iOS version after that.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Build WebDriverAgent for this simulator") {
                        Task { await buildWDA() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.defaultSimulatorUDID == nil)
                }
                if state.wdaBuildInProgress {
                    HStack(spacing: Theme.spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Running `xcodebuild build-for-testing` against vendor/WebDriverAgent…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let err = wdaBuildError {
                    Text(err).font(.callout).foregroundStyle(Color.harnessFailure)
                }

                Button("Re-check") {
                    Task {
                        await state.refreshTooling(forceFresh: true)
                        await state.refreshSimulators()
                        await state.refreshWDA()
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, Theme.spacing.xs)
            }
        }
    }

    private var wdaStatusLabel: String {
        if state.wdaBuildInProgress { return "Building WebDriverAgent… (~1–2 min first run)" }
        if state.wdaReady { return "WebDriverAgent ready" }
        return "WebDriverAgent not built for this simulator"
    }

    private func buildWDA() async {
        wdaBuildError = nil
        do {
            try await state.buildWDA()
        } catch {
            wdaBuildError = "Build failed: \(error.localizedDescription)"
        }
    }

    // MARK: Simulators

    private var simulatorSection: some View {
        WizardCard(
            title: "iOS Simulators",
            subtitle: "These are the devices Harness can drive. Boot one in Xcode if the list is empty."
        ) {
            if state.simulators.isEmpty {
                StatusLine(ok: false, label: "No simulators found")
            } else {
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    ForEach(state.simulators.prefix(8), id: \.udid) { sim in
                        Text("• \(sim.name) · \(sim.runtime)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if state.simulators.count > 8 {
                        Text("…and \(state.simulators.count - 8) more")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.spacing.l)
    }

    private func save() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await state.saveAPIKey(trimmed)
            apiKey = ""
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Helpers

/// Wizard-specific card: title + subtitle on top, content below. Visually
/// related to `PanelContainer` but the wizard's title block is two lines
/// (heading + descriptive subtitle) where `PanelContainer`'s title is one
/// line of chrome.
private struct WizardCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .fill(Color.harnessPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .stroke(Color.harnessLine, lineWidth: 0.5)
        )
    }
}

private struct StatusLine: View {
    let ok: Bool
    let label: String
    var body: some View {
        HStack(spacing: Theme.spacing.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.harnessSuccess : Color.harnessWarning)
            Text(label).font(.callout)
        }
    }
}

private struct InstallHint: View {
    let text: String
    let command: String
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, Theme.spacing.s)
                    .padding(.vertical, Theme.spacing.xs)
                    .background(RoundedRectangle(cornerRadius: Theme.radius.button).fill(Color(nsColor: .textBackgroundColor)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}
