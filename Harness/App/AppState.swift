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

    private static let logger = Logger(subsystem: "com.harness.app", category: "AppState")

    // MARK: Auth

    /// Whether an Anthropic API key is present in the Keychain.
    var apiKeyPresent: Bool = false

    // MARK: Tooling health

    /// Most recent `ToolPaths` snapshot. Nil until `refreshTooling()` runs.
    var toolPaths: ToolPaths?

    var idbHealthy: Bool { toolPaths?.idb != nil && toolPaths?.idbCompanion != nil }
    var xcodebuildAvailable: Bool { toolPaths?.xcodebuild != nil }

    // MARK: Defaults

    /// Default model the goal-input form preselects.
    var defaultModel: AgentModel = .opus47

    /// Default step budget for new runs.
    var defaultStepBudget: Int = 40

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

    // MARK: Dependencies

    private let keychain: any KeychainStoring
    private let toolLocator: any ToolLocating
    private let simulatorDriver: any SimulatorDriving

    init(
        keychain: any KeychainStoring,
        toolLocator: any ToolLocating,
        simulatorDriver: any SimulatorDriving
    ) {
        self.keychain = keychain
        self.toolLocator = toolLocator
        self.simulatorDriver = simulatorDriver
    }

    // MARK: Refresh

    /// Probe the Keychain for the API key. Cheap; safe to call on app launch.
    func refreshAPIKeyPresence() async {
        do {
            let key = try keychain.readAnthropicAPIKey()
            self.apiKeyPresent = (key?.isEmpty == false)
        } catch {
            Self.logger.warning("API key read failed: \(error.localizedDescription, privacy: .public)")
            self.apiKeyPresent = false
        }
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

    /// Save the API key to the Keychain and update presence.
    func saveAPIKey(_ key: String) async throws {
        try keychain.writeAnthropicAPIKey(key)
        await refreshAPIKeyPresence()
    }

    /// Run all refreshes in parallel. Safe to call from app launch and from
    /// the first-run wizard.
    func refreshAll() async {
        async let api: Void = refreshAPIKeyPresence()
        async let tools: Void = refreshTooling()
        _ = await (api, tools)
        // Simulator listing depends on xcrun, so run after tooling resolves.
        await refreshSimulators()
    }
}
