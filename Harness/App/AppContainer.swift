//
//  AppContainer.swift
//  Harness
//
//  Composition root. Builds the dependency graph once at app launch and
//  hands the shared instances to the SwiftUI environment. No singletons —
//  the container is what you'd singleton if you were going to.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AppContainer {

    let processRunner: any ProcessRunning
    let toolLocator: any ToolLocating
    let keychain: any KeychainStoring
    let xcodeBuilder: any XcodeBuilding
    let wdaBuilder: any WDABuilding
    let wdaRunner: any WDARunning
    let wdaClient: any WDAClienting
    let simulatorDriver: any SimulatorDriving
    let simulatorWindowController: any SimulatorWindowControlling
    let claudeClient: any LLMClient
    let runHistory: any RunHistoryStoring
    let promptLibrary: any PromptLoading

    let appState: AppState
    let appCoordinator: AppCoordinator

    init() {
        self.processRunner = ProcessRunner()
        let runner = self.processRunner
        self.toolLocator = ToolLocator(processRunner: runner)
        self.keychain = KeychainStore()
        self.xcodeBuilder = XcodeBuilder(processRunner: runner, toolLocator: toolLocator)

        // WebDriverAgent stack — replaces idb in Phase 5.
        // Discovery: HarnessPaths.wdaSourceURL is baked into Info.plist via
        // INFOPLIST_KEY_HarnessRepoRoot=$(SRCROOT). For the (rare) case where
        // it's not set — running a binary built outside xcodegen — fall back
        // to a path relative to the launched bundle, which is enough for
        // dev-mode runs from Xcode where the .app sits inside DerivedData.
        let wdaSource = HarnessPaths.wdaSourceURL
            ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("vendor/WebDriverAgent")
        self.wdaBuilder = WDABuilder(processRunner: runner, toolLocator: toolLocator, sourceURL: wdaSource)
        self.wdaRunner = WDARunner(processRunner: runner, toolLocator: toolLocator)
        self.wdaClient = WDAClient()

        self.simulatorDriver = SimulatorDriver(
            processRunner: runner,
            toolLocator: toolLocator,
            wdaBuilder: wdaBuilder,
            wdaRunner: wdaRunner,
            wdaClient: wdaClient
        )
        self.simulatorWindowController = SimulatorWindowController()
        self.claudeClient = ClaudeClient(keychain: keychain)
        self.promptLibrary = PromptLibrary()

        // History store — open the on-disk store. RunHistoryStore's init
        // handles SwiftData migration failures internally by deleting the
        // corrupt file and retrying (pre-release policy; data loss is
        // acceptable while we iterate). If even the retry fails, that's a
        // real environmental problem (permissions, disk full) and we let
        // it propagate so the diagnostic isn't hidden behind a silent
        // in-memory fallback.
        do {
            self.runHistory = try RunHistoryStore.openDefault()
        } catch {
            fatalError("Could not initialize RunHistoryStore: \(error.localizedDescription)")
        }

        self.appState = AppState(
            keychain: keychain,
            toolLocator: toolLocator,
            simulatorDriver: simulatorDriver,
            wdaBuilder: wdaBuilder
        )
        self.appCoordinator = AppCoordinator()
    }

    /// Build a `RunCoordinator` for one run. New `AgentLoop` per run so its
    /// cycle-detector window resets.
    func makeRunCoordinator() -> RunCoordinator {
        let agent = AgentLoop(llm: claudeClient, promptLibrary: promptLibrary)
        return RunCoordinator(
            builder: xcodeBuilder,
            driver: simulatorDriver,
            agent: agent,
            llm: claudeClient,
            history: runHistory,
            windowController: simulatorWindowController,
            hideSimulator: !appState.keepSimulatorVisible
        )
    }

    // MARK: Compose-Run → RunSession hand-off

    /// Pending `RunRequest` set by `GoalInputView` when the user hits Start.
    /// `RunSessionView`'s view-model picks it up and clears it.
    private(set) var pendingRunRequest: RunRequest?

    func stagePendingRun(_ request: RunRequest) {
        pendingRunRequest = request
    }

    func consumePendingRun() -> RunRequest? {
        let r = pendingRunRequest
        pendingRunRequest = nil
        return r
    }

    // MARK: Persona seeding

    /// Idempotent: parse `docs/PROMPTS/persona-defaults.md` from the bundled
    /// resources and upsert any built-in personas not already present in the
    /// store. Called from `HarnessApp.bootstrapPersistedScope()` on every
    /// launch so new built-ins added in future updates surface automatically.
    /// Failures are logged but do not block app startup — a missing seed
    /// leaves the user with an empty Personas section, not a crash.
    func bootstrapPersonas() async {
        let logger = Logger(subsystem: "com.harness.app", category: "AppContainer")
        do {
            let markdown = try promptLibrary.personaDefaults()
            try await runHistory.seedBuiltInPersonasIfNeeded(from: markdown)
        } catch {
            logger.error("persona seeding failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
