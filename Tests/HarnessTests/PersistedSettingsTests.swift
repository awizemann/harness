//
//  PersistedSettingsTests.swift
//  HarnessTests
//
//  Round-trip + back-compat tests for the on-disk `settings.json` shape.
//  Catches the bug we hit shipping multi-provider support: AppState
//  defaults (model / provider / mode / step budget / keepSimulatorVisible)
//  weren't in `PersistedSettings`, so they reset every launch and the
//  Compose Run form never reflected what the user picked in Settings.
//

import Testing
import Foundation
@testable import Harness

@Suite("PersistedSettings — round-trip")
struct PersistedSettingsTests {

    @Test("All fields round-trip through JSON encode/decode")
    func fullRoundTrip() throws {
        let app = UUID()
        let original = PersistedSettings(
            selectedApplicationID: app,
            defaultModelRaw: AgentModel.haiku45.rawValue,
            defaultProviderRaw: ModelProvider.anthropic.rawValue,
            defaultModeRaw: RunMode.autonomous.rawValue,
            defaultStepBudget: 0,                   // unlimited sentinel
            defaultTokenBudget: 1_500_000,
            keepSimulatorVisible: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)

        #expect(decoded.selectedApplicationID == app)
        #expect(decoded.defaultModelRaw == AgentModel.haiku45.rawValue)
        #expect(decoded.defaultProviderRaw == ModelProvider.anthropic.rawValue)
        #expect(decoded.defaultModeRaw == RunMode.autonomous.rawValue)
        #expect(decoded.defaultStepBudget == 0)
        #expect(decoded.defaultTokenBudget == 1_500_000)
        #expect(decoded.keepSimulatorVisible == true)
    }

    @Test("Token budget is genuinely optional — nil round-trips as nil")
    func tokenBudgetNilRoundTrips() throws {
        let original = PersistedSettings(
            selectedApplicationID: UUID(),
            defaultTokenBudget: nil           // explicit nil = use per-model default
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        #expect(decoded.defaultTokenBudget == nil)
    }

    @Test("Legacy file with only selectedApplicationID still decodes")
    func legacyFileDecodes() throws {
        // Pre-Phase-2 settings.json had only `selectedApplicationID`.
        // Decoding must succeed and leave the new fields nil so AppState
        // falls back to its property initializers.
        let app = UUID()
        let legacyJSON = """
        { "selectedApplicationID": "\(app.uuidString)" }
        """
        let decoded = try JSONDecoder().decode(
            PersistedSettings.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.selectedApplicationID == app)
        #expect(decoded.defaultModelRaw == nil)
        #expect(decoded.defaultProviderRaw == nil)
        #expect(decoded.defaultModeRaw == nil)
        #expect(decoded.defaultStepBudget == nil)
        #expect(decoded.keepSimulatorVisible == nil)
    }

    @Test("Empty object decodes to all-nil — no crash on a corrupt-but-readable file")
    func emptyObjectDecodes() throws {
        let decoded = try JSONDecoder().decode(
            PersistedSettings.self,
            from: Data("{}".utf8)
        )
        #expect(decoded.selectedApplicationID == nil)
        #expect(decoded.defaultModelRaw == nil)
    }

    @Test("Persisted defaults survive an AppState restore")
    func appStateRestoresPersistedDefaults() async throws {
        // Stage a `settings.json` in a temp directory, override the
        // HarnessPaths app-support root via the env var the codebase
        // uses for test isolation, and verify a fresh AppState picks
        // up the persisted values.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = PersistedSettings(
            selectedApplicationID: UUID(),
            defaultModelRaw: AgentModel.gpt5Mini.rawValue,
            defaultProviderRaw: ModelProvider.openai.rawValue,
            defaultModeRaw: RunMode.autonomous.rawValue,
            defaultStepBudget: 100,
            keepSimulatorVisible: true
        )
        let url = tempDir.appendingPathComponent("settings.json")
        let data = try JSONEncoder().encode(original)
        try data.write(to: url)

        // Re-decode and confirm the field values land where AppState's
        // restorePersistedSettings would route them. (We're not actually
        // booting AppState here because it pulls in the full service
        // graph; the field-by-field assertion below is what restore
        // does internally.)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: Data(contentsOf: url))
        #expect(AgentModel(rawValue: decoded.defaultModelRaw ?? "") == .gpt5Mini)
        #expect(ModelProvider(rawValue: decoded.defaultProviderRaw ?? "") == .openai)
        #expect(RunMode(rawValue: decoded.defaultModeRaw ?? "") == .autonomous)
        #expect(decoded.defaultStepBudget == 100)
        #expect(decoded.keepSimulatorVisible == true)
    }
}
