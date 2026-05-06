//
//  AppState.swift
//  Harness
//
//  App-level cross-section state. Per `standards/01-architecture.md §3`,
//  navigation lives on `AppCoordinator`; shared state across sections lives
//  here.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AppState {

    nonisolated private static let logger = Logger(subsystem: "com.harness.app", category: "AppState")

    // MARK: Auth

    /// Per-provider Keychain presence. Drives the per-provider API-key
    /// status indicator in Settings and the preflight gate on Compose Run.
    /// Keyed by `ModelProvider`; missing entries decode to `false`.
    var apiKeyPresenceByProvider: [ModelProvider: Bool] = [:]

    /// Convenience: whether *any* provider has a key. The legacy
    /// `apiKeyPresent` callers checked Anthropic specifically — keep that
    /// semantic, but the preflight gate now checks the active provider via
    /// `apiKeyPresent(for:)`.
    var apiKeyPresent: Bool {
        get { apiKeyPresenceByProvider[.anthropic] ?? false }
        set { apiKeyPresenceByProvider[.anthropic] = newValue }
    }

    /// Whether the API key for `provider` is present in the Keychain.
    func apiKeyPresent(for provider: ModelProvider) -> Bool {
        apiKeyPresenceByProvider[provider] ?? false
    }

    // MARK: Tooling health

    /// Most recent `ToolPaths` snapshot. Nil until `refreshTooling()` runs.
    var toolPaths: ToolPaths?

    /// True if a WebDriverAgent xctestrun has been built for the currently
    /// selected simulator's iOS version. Refreshed by `refreshWDA()`.
    var wdaReady: Bool = false

    /// True while `WDABuilder.ensureBuilt(...)` is running. The wizard / sidebar
    /// surface this so the user knows why a first run takes ~1–2 min.
    var wdaBuildInProgress: Bool = false

    var xcodebuildAvailable: Bool { toolPaths?.xcodebuild != nil }

    // MARK: Defaults

    /// Default provider the Settings + Compose Run pickers preselect.
    /// Drives the model picker's filter (only models from this provider show).
    var defaultProvider: ModelProvider = .anthropic

    /// Default model the goal-input form preselects.
    var defaultModel: AgentModel = .opus47

    /// Default step budget for new runs.
    var defaultStepBudget: Int = 40

    /// Optional global override for the per-run input-token budget.
    /// `nil` (the default) means each run inherits the per-model
    /// default from `AgentModel.defaultTokenBudget`. Setting a value
    /// applies it to every run regardless of model — useful when the
    /// user wants a tighter cost cap or more headroom across the
    /// board. Compose Run can still override this per-run.
    var defaultTokenBudget: Int?

    /// Default mode for new runs.
    var defaultMode: RunMode = .stepByStep

    /// Keep `Simulator.app`'s window visible while a run is in progress.
    /// Defaults to false (Harness's mirror is the source of truth). Toggle
    /// this if you're debugging WDA's behavior and need to peek at the live
    /// simulator window directly.
    var keepSimulatorVisible: Bool = false

    /// Discovered iPhone simulators. Refreshed via `refreshSimulators()`.
    var simulators: [SimulatorRef] = []

    /// UDID of the simulator the user last picked. Drives the picker default.
    var defaultSimulatorUDID: String?

    /// Persisted last-active Application id. Restored at launch via
    /// `restorePersistedSettings()`. Cleared if the application id no longer
    /// resolves in the store.
    var selectedApplicationID: UUID?

    // MARK: Dependencies

    private let keychain: any KeychainStoring
    private let toolLocator: any ToolLocating
    private let simulatorDriver: any SimulatorDriving
    private let wdaBuilder: any WDABuilding

    init(
        keychain: any KeychainStoring,
        toolLocator: any ToolLocating,
        simulatorDriver: any SimulatorDriving,
        wdaBuilder: any WDABuilding
    ) {
        self.keychain = keychain
        self.toolLocator = toolLocator
        self.simulatorDriver = simulatorDriver
        self.wdaBuilder = wdaBuilder
    }

    // MARK: Refresh

    /// Probe the Keychain for every provider's API key. Cheap; safe to
    /// call on app launch.
    func refreshAPIKeyPresence() async {
        var next: [ModelProvider: Bool] = [:]
        for provider in ModelProvider.allCases {
            do {
                let key = try keychain.readKey(for: provider)
                next[provider] = (key?.isEmpty == false)
            } catch {
                Self.logger.warning("API key read failed for \(provider.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                next[provider] = false
            }
        }
        self.apiKeyPresenceByProvider = next
    }

    /// Resolve external CLI paths.
    /// - Parameter forceFresh: bypass the in-memory cache and re-probe every
    ///   candidate. The "Re-check" / "Re-detect tools" buttons pass `true` so
    ///   the user sees up-to-date results after installing a missing tool.
    func refreshTooling(forceFresh: Bool = false) async {
        do {
            let paths = forceFresh
                ? try await toolLocator.forceRefresh()
                : try await toolLocator.locateAll()
            self.toolPaths = paths
        } catch {
            Self.logger.warning("Tool resolution failed: \(error.localizedDescription, privacy: .public)")
            self.toolPaths = nil
        }
    }

    /// Enumerate iOS simulators.
    func refreshSimulators() async {
        do {
            let sims = try await simulatorDriver.listDevices()
            self.simulators = sims
            // Pick a sensible default if the user hasn't set one yet.
            if defaultSimulatorUDID == nil, let first = sims.first {
                self.defaultSimulatorUDID = first.udid
            }
        } catch {
            Self.logger.warning("Simulator list failed: \(error.localizedDescription, privacy: .public)")
            self.simulators = []
        }
    }

    /// Save the Anthropic API key (legacy single-provider call site).
    func saveAPIKey(_ key: String) async throws {
        try await saveAPIKey(key, for: .anthropic)
    }

    /// Save an API key for the given provider and update presence.
    func saveAPIKey(_ key: String, for provider: ModelProvider) async throws {
        try keychain.writeKey(key, for: provider)
        await refreshAPIKeyPresence()
    }

    /// Delete the API key for `provider` and update presence.
    func deleteAPIKey(for provider: ModelProvider) async throws {
        try keychain.deleteKey(for: provider)
        await refreshAPIKeyPresence()
    }

    /// Refresh the WDA-readiness flag for the currently selected simulator.
    /// Cheap — checks for the existence of a cached xctestrun on disk.
    func refreshWDA() async {
        guard let udid = defaultSimulatorUDID,
              let sim = simulators.first(where: { $0.udid == udid }) else {
            wdaReady = false
            return
        }
        wdaReady = await wdaBuilder.isReady(forSimulator: sim)
    }

    /// Build WebDriverAgent for the currently selected simulator. Surfaces
    /// `wdaBuildInProgress` so the wizard / sidebar can render a spinner.
    /// First build is ~1–2 min; subsequent runs hit the cache.
    func buildWDA() async throws {
        guard let udid = defaultSimulatorUDID,
              let sim = simulators.first(where: { $0.udid == udid }) else {
            return
        }
        wdaBuildInProgress = true
        defer { wdaBuildInProgress = false }
        _ = try await wdaBuilder.ensureBuilt(forSimulator: sim)
        await refreshWDA()
    }

    /// Run all refreshes in parallel. Safe to call from app launch and from
    /// the first-run wizard.
    func refreshAll() async {
        async let api: Void = refreshAPIKeyPresence()
        async let tools: Void = refreshTooling()
        _ = await (api, tools)
        // Simulator listing depends on xcrun, so run after tooling resolves.
        await refreshSimulators()
        // WDA readiness depends on which simulator is selected.
        await refreshWDA()
    }

    // MARK: Settings persistence

    /// Read `settings.json` if present and restore persisted defaults.
    /// All fields except `selectedApplicationID` are optional in the
    /// Codable shape so files written before they were added decode
    /// cleanly. Disk I/O happens on a detached task — never on the
    /// actor — to honor the "no synchronous file I/O on `@MainActor`"
    /// rule.
    func restorePersistedSettings() async {
        let url = HarnessPaths.settingsFile
        let payload: PersistedSettings? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(PersistedSettings.self, from: data)
            } catch {
                AppState.logger.warning("settings.json decode failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
        guard let payload else { return }
        self.selectedApplicationID = payload.selectedApplicationID
        if let raw = payload.defaultModelRaw, let m = AgentModel(rawValue: raw) {
            self.defaultModel = m
        }
        if let raw = payload.defaultProviderRaw, let p = ModelProvider(rawValue: raw) {
            self.defaultProvider = p
        }
        if let raw = payload.defaultModeRaw, let m = RunMode(rawValue: raw) {
            self.defaultMode = m
        }
        if let s = payload.defaultStepBudget {
            self.defaultStepBudget = s
        }
        // Token budget override is genuinely optional — preserve nil if
        // absent in the file so the per-model default kicks in.
        self.defaultTokenBudget = payload.defaultTokenBudget
        if let v = payload.keepSimulatorVisible {
            self.keepSimulatorVisible = v
        }
    }

    /// Persist current settings to `settings.json`. Idempotent; safe to
    /// call from a SwiftUI `.onChange` handler — it serializes off the
    /// main actor and writes atomically.
    func persistSettings() async {
        let payload = PersistedSettings(
            selectedApplicationID: selectedApplicationID,
            defaultModelRaw: defaultModel.rawValue,
            defaultProviderRaw: defaultProvider.rawValue,
            defaultModeRaw: defaultMode.rawValue,
            defaultStepBudget: defaultStepBudget,
            defaultTokenBudget: defaultTokenBudget,
            keepSimulatorVisible: keepSimulatorVisible
        )
        let url = HarnessPaths.settingsFile
        await Task.detached(priority: .utility) {
            do {
                try HarnessPaths.ensureDirectory(HarnessPaths.appSupport)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)
                try data.write(to: url, options: [.atomic])
            } catch {
                AppState.logger.error("settings.json write failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }
}

// MARK: - Persistence payload

/// Shape on disk in `settings.json`. Versionless — every field beyond
/// `selectedApplicationID` is optional so a `settings.json` written by
/// an older Harness build still decodes (the missing fields fall back
/// to their @Observable property initializers in `AppState`). When
/// adding fields, keep them optional and back-fill from a sensible
/// default in `restorePersistedSettings()`.
struct PersistedSettings: Codable, Sendable {
    let selectedApplicationID: UUID?
    let defaultModelRaw: String?
    let defaultProviderRaw: String?
    let defaultModeRaw: String?
    let defaultStepBudget: Int?
    /// Optional global token-budget override. `nil` = inherit per-model
    /// default at run-build time. Distinguished from "0" because zero
    /// would mean "no tokens allowed", which is meaningless.
    let defaultTokenBudget: Int?
    let keepSimulatorVisible: Bool?

    init(
        selectedApplicationID: UUID?,
        defaultModelRaw: String? = nil,
        defaultProviderRaw: String? = nil,
        defaultModeRaw: String? = nil,
        defaultStepBudget: Int? = nil,
        defaultTokenBudget: Int? = nil,
        keepSimulatorVisible: Bool? = nil
    ) {
        self.selectedApplicationID = selectedApplicationID
        self.defaultModelRaw = defaultModelRaw
        self.defaultProviderRaw = defaultProviderRaw
        self.defaultModeRaw = defaultModeRaw
        self.defaultStepBudget = defaultStepBudget
        self.defaultTokenBudget = defaultTokenBudget
        self.keepSimulatorVisible = keepSimulatorVisible
    }
}
