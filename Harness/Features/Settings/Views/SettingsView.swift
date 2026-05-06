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
    /// Last finite step budget the user picked, restored when they
    /// toggle Unlimited off again.
    @State private var lastFiniteStepBudget: Int = 40

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
                        // provider's first model. The follow-up persist
                        // hook below catches the resulting `defaultModel`
                        // change.
                        if state.defaultModel.provider != newProvider,
                           let first = AgentModel.allCases.first(where: { $0.provider == newProvider }) {
                            state.defaultModel = first
                        }
                        Task { await state.persistSettings() }
                    }
                    Picker("Model", selection: $state.defaultModel) {
                        ForEach(modelsForCurrentProvider(state.defaultProvider), id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .onChange(of: state.defaultModel) { _, _ in
                        Task { await state.persistSettings() }
                    }
                    Picker("Mode", selection: $state.defaultMode) {
                        Text("Step-by-step").tag(RunMode.stepByStep)
                        Text("Autonomous").tag(RunMode.autonomous)
                    }
                    .onChange(of: state.defaultMode) { _, _ in
                        Task { await state.persistSettings() }
                    }
                    Toggle("Unlimited steps", isOn: unlimitedStepsBinding(for: $state.defaultStepBudget))
                    if state.defaultStepBudget != RunRequest.unlimitedStepBudget {
                        Stepper(value: $state.defaultStepBudget, in: 5...200) {
                            Text("Step budget: \(state.defaultStepBudget)")
                        }
                    } else {
                        Text("Step budget: Unlimited — only the token budget caps the run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Override default token budget",
                           isOn: tokenBudgetOverrideBinding)
                    if let _ = state.defaultTokenBudget {
                        Stepper(
                            value: tokenBudgetStepperBinding,
                            in: 100_000...10_000_000,
                            step: 100_000
                        ) {
                            Text("Token budget: \(formatTokens(state.defaultTokenBudget ?? 0))")
                        }
                        Text("Applies to every run regardless of model. Compose Run can still override per-run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Each model uses its own default (Opus 4.7 = 250k input tokens; cheaper models = 1–2M).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Keep iOS Simulator window visible during runs",
                           isOn: $state.keepSimulatorVisible)
                        .onChange(of: state.keepSimulatorVisible) { _, _ in
                            Task { await state.persistSettings() }
                        }
                }
                // Catch step-budget changes from either the toggle or the
                // Stepper. Hooked outside the Section so both controls'
                // mutations land here.
                .onChange(of: state.defaultStepBudget) { _, _ in
                    Task { await state.persistSettings() }
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

    /// Bool binding that flips `state.defaultTokenBudget` between
    /// nil (each model uses its own default) and an explicit value.
    /// Defaults to 1M on first opt-in — a sensible middle ground
    /// across providers.
    private var tokenBudgetOverrideBinding: Binding<Bool> {
        @Bindable var state = state
        return Binding<Bool>(
            get: { state.defaultTokenBudget != nil },
            set: { newValue in
                if newValue {
                    if state.defaultTokenBudget == nil {
                        state.defaultTokenBudget = 1_000_000
                    }
                } else {
                    state.defaultTokenBudget = nil
                }
                Task { await state.persistSettings() }
            }
        )
    }

    /// Stepper-friendly Int binding over the optional `defaultTokenBudget`.
    /// Coerces nil → 1M while the toggle is on (the toggle hides the
    /// stepper when nil, so this branch is only hit during the brief
    /// re-render after toggling on).
    private var tokenBudgetStepperBinding: Binding<Int> {
        @Bindable var state = state
        return Binding<Int>(
            get: { state.defaultTokenBudget ?? 1_000_000 },
            set: { newValue in
                state.defaultTokenBudget = newValue
                Task { await state.persistSettings() }
            }
        )
    }

    /// Format a token count as "1.0M" / "250k" — same convention the
    /// run-detail UI uses.
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        }
        return "\(tokens / 1_000)k"
    }

    /// Build a Bool binding that flips `stepBudget` between
    /// `RunRequest.unlimitedStepBudget` (0) and the last finite value
    /// the user picked. Restores 40 on first use if they've never set
    /// a finite value yet.
    private func unlimitedStepsBinding(for budget: Binding<Int>) -> Binding<Bool> {
        Binding<Bool>(
            get: { budget.wrappedValue == RunRequest.unlimitedStepBudget },
            set: { newValue in
                if newValue {
                    if budget.wrappedValue > 0 { lastFiniteStepBudget = budget.wrappedValue }
                    budget.wrappedValue = RunRequest.unlimitedStepBudget
                } else {
                    budget.wrappedValue = max(5, lastFiniteStepBudget)
                }
            }
        )
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
