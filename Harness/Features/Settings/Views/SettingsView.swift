//
//  SettingsView.swift
//  Harness
//
//  Minimal settings sheet: API key, default model, default step budget, default mode.
//

import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    @State private var apiKey: String = ""
    @State private var saveError: String?

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.spacing.l)
            .padding(.top, Theme.spacing.l)
            .padding(.bottom, Theme.spacing.s)
            Divider()
            Form {
                Section("Anthropic API key") {
                    if state.apiKeyPresent {
                        HStack(spacing: Theme.spacing.s) {
                            StatusChip(kind: .done)
                            Text("Stored in Keychain.")
                            Spacer()
                            Button("Replace…") { state.apiKeyPresent = false }
                        }
                    } else {
                        SecureField("sk-ant-…", text: $apiKey)
                        if let err = saveError {
                            Text(err).foregroundStyle(Color.harnessFailure).font(.callout)
                        }
                        HStack {
                            Spacer()
                            Button("Save") {
                                Task { await save() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Section("Defaults") {
                    Picker("Model", selection: $state.defaultModel) {
                        ForEach(AgentModel.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    Picker("Mode", selection: $state.defaultMode) {
                        Text("Step-by-step").tag(RunMode.stepByStep)
                        Text("Autonomous").tag(RunMode.autonomous)
                    }
                    Stepper(value: $state.defaultStepBudget, in: 5...200) {
                        Text("Step budget: \(state.defaultStepBudget)")
                    }
                    Toggle("Keep iOS Simulator window visible during runs",
                           isOn: $state.keepSimulatorVisible)
                }
                Section("Tooling") {
                    HStack(spacing: Theme.spacing.s) {
                        StatusChip(kind: state.xcodebuildAvailable ? .done : .awaiting)
                        Text("xcodebuild")
                        Spacer()
                        Text(state.toolPaths?.xcodebuild?.path ?? "—")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: Theme.spacing.s) {
                        StatusChip(kind: wdaStatusKind)
                        Text(state.wdaBuildInProgress ? "WebDriverAgent (building…)" : "WebDriverAgent")
                        Spacer()
                        Text(state.wdaReady ? "ready" : "not built for selected simulator")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Button("Re-detect tools") {
                        Task {
                            await state.refreshTooling(forceFresh: true)
                            await state.refreshSimulators()
                            await state.refreshWDA()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var wdaStatusKind: StatusKind {
        if state.wdaReady { return .done }
        if state.wdaBuildInProgress { return .running }
        return .awaiting
    }

    private func save() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await state.saveAPIKey(trimmed)
            apiKey = ""
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
