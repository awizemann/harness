//
//  FirstRunWizard.swift
//  Harness
//
//  Two-screen sheet shown on first launch (or when the API key is missing /
//  external tooling isn't healthy). Surfaces actionable copy-paste install
//  commands per `wiki/Build-and-Run.md`.
//

import SwiftUI

struct FirstRunWizard: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    @State private var apiKey: String = ""
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { contentBody.padding(24) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await state.refreshAll() }
    }

    private var header: some View {
        HStack(spacing: 14) {
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
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    @ViewBuilder
    private var contentBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            apiKeySection
            toolingSection
            simulatorSection
        }
    }

    // MARK: API key

    private var apiKeySection: some View {
        SectionCard(
            title: "Anthropic API key",
            subtitle: "Stored in your macOS Keychain (service \"com.harness.anthropic\"). Never written to disk or logs."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if state.apiKeyPresent {
                    StatusLine(ok: true, label: "API key present")
                } else {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    if let err = saveError {
                        Text(err).font(.callout).foregroundStyle(.red)
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
        SectionCard(
            title: "External tools",
            subtitle: "Harness drives your iOS Simulator via xcodebuild + idb. Both must be installed."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(ok: state.xcodebuildAvailable,
                           label: state.xcodebuildAvailable ? "xcodebuild available" : "xcodebuild not found")
                if !state.xcodebuildAvailable {
                    InstallHint(text: "Install Xcode from the App Store, then run:",
                                command: "xcode-select --install")
                }
                StatusLine(ok: state.idbHealthy,
                           label: state.idbHealthy ? "idb installed" : "idb / idb_companion not found")
                if !state.idbHealthy {
                    InstallHint(text: "Install via Homebrew + pip:",
                                command: "brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb")
                }
                Button("Re-check") { Task { await state.refreshTooling(); await state.refreshSimulators() } }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Simulators

    private var simulatorSection: some View {
        SectionCard(
            title: "iOS Simulators",
            subtitle: "These are the devices Harness can drive. Boot one in Xcode if the list is empty."
        ) {
            if state.simulators.isEmpty {
                StatusLine(ok: false, label: "No simulators found")
            } else {
                VStack(alignment: .leading, spacing: 4) {
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
        .padding(16)
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

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private struct StatusLine: View {
    let ok: Bool
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label).font(.callout)
        }
    }
}

private struct InstallHint: View {
    let text: String
    let command: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
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
