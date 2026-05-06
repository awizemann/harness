//
//  SettingsView.swift
//  Harness
//
//  Multi-provider settings: per-provider API keys, default provider →
//  model two-step picker, default mode, default step budget.
//

import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    /// Per-provider in-progress key entry. Keyed by `ModelProvider.rawValue`
    /// so the dictionary survives the Picker's identity changes.
    @State private var draftKeys: [String: String] = [:]
    @State private var saveError: String?
    @State private var savingProvider: ModelProvider?

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
                Section("API keys") {
                    ForEach(ModelProvider.allCases, id: \.self) { provider in
                        apiKeyRow(provider: provider)
                    }
                    if let err = saveError {
                        Text(err)
                            .foregroundStyle(Color.harnessFailure)
                            .font(.callout)
                    }
                }
                Section("Defaults") {
                    Picker("Provider", selection: $state.defaultProvider) {
                        ForEach(ModelProvider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .onChange(of: state.defaultProvider) { _, newProvider in
                        // If the previously-selected default model isn't
                        // from the newly-selected provider, snap to that
                        // provider's first model.
                        if state.defaultModel.provider != newProvider,
                           let first = AgentModel.allCases.first(where: { $0.provider == newProvider }) {
                            state.defaultModel = first
                        }
                    }
                    Picker("Model", selection: $state.defaultModel) {
                        ForEach(modelsForCurrentProvider(state.defaultProvider), id: \.self) { m in
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

    // MARK: API key row

    @ViewBuilder
    private func apiKeyRow(provider: ModelProvider) -> some View {
        let present = state.apiKeyPresent(for: provider)
        let draftBinding = Binding<String>(
            get: { draftKeys[provider.rawValue] ?? "" },
            set: { draftKeys[provider.rawValue] = $0 }
        )
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            HStack(spacing: Theme.spacing.s) {
                StatusChip(kind: present ? .done : .awaiting)
                Text(provider.displayName)
                    .frame(width: 84, alignment: .leading)
                if present {
                    Text("Stored in Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace…") {
                        draftKeys[provider.rawValue] = ""
                        // Clear presence locally so the SecureField reveals;
                        // a successful save re-asserts it via refresh.
                        state.apiKeyPresenceByProvider[provider] = false
                    }
                } else {
                    SecureField(placeholder(for: provider), text: draftBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Task { await save(for: provider) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        savingProvider == provider ||
                        draftBinding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
        }
    }

    private func placeholder(for provider: ModelProvider) -> String {
        switch provider {
        case .anthropic: return "sk-ant-…"
        case .openai:    return "sk-…"
        case .google:    return "AIza…"
        }
    }

    private var wdaStatusKind: StatusKind {
        if state.wdaReady { return .done }
        if state.wdaBuildInProgress { return .running }
        return .awaiting
    }

    private func modelsForCurrentProvider(_ provider: ModelProvider) -> [AgentModel] {
        AgentModel.allCases.filter { $0.provider == provider }
    }

    private func save(for provider: ModelProvider) async {
        let key = (draftKeys[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        savingProvider = provider
        defer { savingProvider = nil }
        do {
            try await state.saveAPIKey(key, for: provider)
            draftKeys[provider.rawValue] = ""
            saveError = nil
        } catch {
            saveError = "\(provider.displayName): \(error.localizedDescription)"
        }
    }
}
