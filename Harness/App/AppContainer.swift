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

@Observable
@MainActor
final class AppContainer {

    let processRunner: any ProcessRunning
    let toolLocator: any ToolLocating
    let keychain: any KeychainStoring
    let xcodeBuilder: any XcodeBuilding
    let simulatorDriver: any SimulatorDriving
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
        self.simulatorDriver = SimulatorDriver(processRunner: runner, toolLocator: toolLocator)
        self.claudeClient = ClaudeClient(keychain: keychain)
        self.promptLibrary = PromptLibrary()

        // History store — fall through to a fresh in-memory container if
        // the on-disk store can't be opened (rare; would be permission issues).
        if let store = try? RunHistoryStore() {
            self.runHistory = store
        } else if let memory = try? RunHistoryStore.inMemory() {
            self.runHistory = memory
        } else {
            // Should be unreachable. If it happens, the UI surfaces it via
            // a follow-up view.
            fatalError("Could not initialize RunHistoryStore")
        }

        self.appState = AppState(
            keychain: keychain,
            toolLocator: toolLocator,
            simulatorDriver: simulatorDriver
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
            history: runHistory
        )
    }

    // MARK: Goal-input → RunSession hand-off

    /// Pending `GoalRequest` set by `GoalInputView` when the user hits Start.
    /// `RunSessionView`'s view-model picks it up and clears it.
    private(set) var pendingRunRequest: GoalRequest?

    func stagePendingRun(_ request: GoalRequest) {
        pendingRunRequest = request
    }

    func consumePendingRun() -> GoalRequest? {
        let r = pendingRunRequest
        pendingRunRequest = nil
        return r
    }
}
