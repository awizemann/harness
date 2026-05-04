//
//  ApplicationsViewModelTests.swift
//  HarnessTests
//
//  Round-trips for the Applications library section's view-model: create,
//  rename, archive, set-as-active, and delete-active-resets-scope. Uses
//  `RunHistoryStore.inMemory()` so the SwiftData container vanishes with
//  the test.
//

import Testing
import Foundation
import AppKit
@testable import Harness

@MainActor
@Suite("ApplicationsViewModel")
struct ApplicationsViewModelTests {

    // MARK: Create

    @Test("Save inserts a new Application and reloads")
    func createApplication() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = Harness.makeSnapshot(name: "ListApp")
        let saved = await h.vm.save(snapshot)
        #expect(saved == true)
        #expect(h.vm.applications.contains(where: { $0.id == snapshot.id }))
        #expect(h.vm.applications.first(where: { $0.id == snapshot.id })?.name == "ListApp")
    }

    // MARK: Rename

    @Test("Rename round-trips through the store")
    func renameRoundTrips() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = Harness.makeSnapshot(name: "ListApp")
        _ = await h.vm.save(snapshot)
        let renamed = await h.vm.rename(snapshot.id, to: "GroceriesPro")
        #expect(renamed == true)
        let stored = h.vm.applications.first(where: { $0.id == snapshot.id })
        #expect(stored?.name == "GroceriesPro")
    }

    // MARK: Archive

    @Test("Archive disappears from default fetch but reappears with includeArchived")
    func archiveBehavior() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = Harness.makeSnapshot(name: "Vault")
        _ = await h.vm.save(snapshot)

        await h.vm.archive(snapshot.id)
        await h.vm.reload(includeArchived: false)
        #expect(h.vm.applications.contains(where: { $0.id == snapshot.id }) == false)

        await h.vm.reload(includeArchived: true)
        #expect(h.vm.applications.contains(where: { $0.id == snapshot.id }))
        #expect(h.vm.applications.first(where: { $0.id == snapshot.id })?.archivedAt != nil)
    }

    // MARK: Set as active

    @Test("Set-as-active mirrors into coordinator + AppState")
    func setActiveMirrors() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = Harness.makeSnapshot(name: "Active")
        _ = await h.vm.save(snapshot)

        await h.vm.setActive(snapshot.id)
        #expect(h.coordinator.selectedApplicationID == snapshot.id)
        #expect(h.state.selectedApplicationID == snapshot.id)
    }

    // MARK: Delete clears active

    @Test("Deleting the active Application resets selectedApplicationID to nil")
    func deleteActiveClearsScope() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = Harness.makeSnapshot(name: "ToBeDeleted")
        _ = await h.vm.save(snapshot)

        await h.vm.setActive(snapshot.id)
        #expect(h.coordinator.selectedApplicationID == snapshot.id)

        await h.vm.delete(snapshot.id)
        #expect(h.coordinator.selectedApplicationID == nil)
        #expect(h.state.selectedApplicationID == nil)
        #expect(h.vm.applications.contains(where: { $0.id == snapshot.id }) == false)
    }

    // MARK: - Test harness helpers
}

// MARK: - Test harness wiring

/// Bundles a viewmodel + its dependencies so each test can ask for a fresh,
/// isolated graph. Lives at file scope so the helpers can return a value type.
@MainActor
private struct Harness {
    let store: any RunHistoryStoring
    let coordinator: AppCoordinator
    let state: AppState
    let vm: ApplicationsViewModel

    static func makeHarness() async throws -> Harness {
        let store = try RunHistoryStore.inMemory()
        let coordinator = AppCoordinator()
        let state = AppState(
            keychain: NoopKeychain(),
            toolLocator: NoopToolLocator(),
            simulatorDriver: NoopSimulatorDriver(),
            wdaBuilder: NoopWDABuilder()
        )
        let vm = ApplicationsViewModel(
            store: store,
            coordinator: coordinator,
            appState: state
        )
        return Harness(
            store: store,
            coordinator: coordinator,
            state: state,
            vm: vm
        )
    }

    static func makeSnapshot(name: String) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: UUID(),
            name: name,
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil,
            projectPath: "/tmp/\(name).xcodeproj",
            projectBookmark: nil,
            scheme: name,
            defaultSimulatorUDID: "UDID-\(name)",
            defaultSimulatorName: "iPhone Test",
            defaultSimulatorRuntime: "iOS 18.4",
            defaultModelRaw: AgentModel.opus47.rawValue,
            defaultModeRaw: RunMode.stepByStep.rawValue,
            defaultStepBudget: 40
        )
    }
}

// MARK: - Lightweight stubs for AppState dependencies
//
// AppState's protocol surface is overkill for these tests — we just need
// enough to construct the value type. None of these stubs touch disk or
// the Keychain.

private struct NoopKeychain: KeychainStoring {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private actor NoopToolLocator: ToolLocating {
    func locateAll() async throws -> ToolPaths { ToolPaths(xcrun: nil, xcodebuild: nil, brew: nil) }
    func forceRefresh() async throws -> ToolPaths { ToolPaths(xcrun: nil, xcodebuild: nil, brew: nil) }
    func resolved() async -> ToolPaths? { nil }
}

private actor NoopSimulatorDriver: SimulatorDriving {
    func listDevices() async throws -> [SimulatorRef] { [] }
    func boot(_ ref: SimulatorRef) async throws {}
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws {}
    func launch(bundleID: String, on ref: SimulatorRef) async throws {}
    func terminate(bundleID: String, on ref: SimulatorRef) async throws {}
    func erase(_ ref: SimulatorRef) async throws {}
    func cleanupWDA(udid: String) async {}
    func startInputSession(_ ref: SimulatorRef) async throws {}
    func endInputSession() async {}
    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL { url }
    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage { NSImage() }
    func tap(at point: CGPoint, on ref: SimulatorRef) async throws {}
    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws {}
    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws {}
    func type(_ text: String, on ref: SimulatorRef) async throws {}
    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws {}
}

private actor NoopWDABuilder: WDABuilding {
    func ensureBuilt(forSimulator ref: SimulatorRef) async throws -> WDABuildResult {
        WDABuildResult(
            xctestrun: URL(fileURLWithPath: "/dev/null"),
            derivedData: URL(fileURLWithPath: "/dev/null"),
            iosVersionKey: "18.4"
        )
    }
    func isReady(forSimulator ref: SimulatorRef) async -> Bool { false }
}
