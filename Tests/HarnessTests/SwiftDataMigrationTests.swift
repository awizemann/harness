//
//  SwiftDataMigrationTests.swift
//  HarnessTests
//
//  V1 → V2 migration of the Harness history store.
//
//  Each test seeds a V1-only on-disk store, closes it, then opens the same
//  URL with the V2 schema + migration plan. After migration we verify:
//   - Applications are emitted, one per distinct (projectPath, scheme).
//   - RunRecord.application is rebound to the matching Application.
//   - ProjectRef rows are dropped (the table is not in V2).
//

import Testing
import Foundation
import SwiftData
@testable import Harness

@Suite("SwiftData V1→V2 migration")
struct SwiftDataMigrationTests {

    @Test("Two distinct projectPaths produce two Applications, each RunRecord rebound")
    func twoDistinctProjects() async throws {
        let storeURL = Self.makeStoreURL()
        defer { Self.removeStore(at: storeURL) }

        let runIDA = UUID()
        let runIDB = UUID()
        try Self.seedV1(at: storeURL) { context in
            context.insert(HarnessSchemaV1.RunRecord(
                id: runIDA,
                createdAt: Date(timeIntervalSince1970: 100),
                projectPath: "/tmp/A.xcodeproj",
                scheme: "ASchema",
                displayName: "A",
                simulatorUDID: "UDID-A",
                simulatorName: "iPhone A",
                simulatorRuntime: "iOS 18.4",
                goal: "ga",
                persona: "pa",
                modelRaw: AgentModel.opus47.rawValue,
                modeRaw: RunMode.stepByStep.rawValue,
                runDirectoryPath: "/tmp/runs/\(runIDA.uuidString)"
            ))
            context.insert(HarnessSchemaV1.RunRecord(
                id: runIDB,
                createdAt: Date(timeIntervalSince1970: 200),
                projectPath: "/tmp/B.xcodeproj",
                scheme: "BSchema",
                displayName: "B",
                simulatorUDID: "UDID-B",
                simulatorName: "iPhone B",
                simulatorRuntime: "iOS 18.4",
                goal: "gb",
                persona: "pb",
                modelRaw: AgentModel.opus47.rawValue,
                modeRaw: RunMode.stepByStep.rawValue,
                runDirectoryPath: "/tmp/runs/\(runIDB.uuidString)"
            ))
            context.insert(HarnessSchemaV1.ProjectRef(
                path: "/tmp/A.xcodeproj",
                displayName: "A"
            ))
        }

        let store = try RunHistoryStore(url: storeURL)
        let apps = try await store.applications(includeArchived: true)
        #expect(apps.count == 2)
        let appPaths = Set(apps.map(\.projectPath))
        #expect(appPaths == ["/tmp/A.xcodeproj", "/tmp/B.xcodeproj"])

        let recA = try await store.fetch(id: runIDA)
        let recB = try await store.fetch(id: runIDB)
        let appA = apps.first(where: { $0.projectPath == "/tmp/A.xcodeproj" })
        let appB = apps.first(where: { $0.projectPath == "/tmp/B.xcodeproj" })
        #expect(recA?.applicationID == appA?.id)
        #expect(recB?.applicationID == appB?.id)
        #expect(appA?.scheme == "ASchema")
        #expect(appA?.defaultSimulatorUDID == "UDID-A")
    }

    @Test("Three runs sharing the same project collapse to one Application")
    func sharedProjectCollapses() async throws {
        let storeURL = Self.makeStoreURL()
        defer { Self.removeStore(at: storeURL) }

        let ids = (0..<3).map { _ in UUID() }
        try Self.seedV1(at: storeURL) { context in
            for (i, id) in ids.enumerated() {
                context.insert(HarnessSchemaV1.RunRecord(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(100 + i)),
                    projectPath: "/tmp/Same.xcodeproj",
                    scheme: "SameScheme",
                    displayName: "Same",
                    simulatorUDID: "UDID-S",
                    simulatorName: "iPhone S",
                    simulatorRuntime: "iOS 18.4",
                    goal: "g\(i)",
                    persona: "p",
                    modelRaw: AgentModel.opus47.rawValue,
                    modeRaw: RunMode.stepByStep.rawValue,
                    runDirectoryPath: "/tmp/runs/\(id.uuidString)"
                ))
            }
        }

        let store = try RunHistoryStore(url: storeURL)
        let apps = try await store.applications(includeArchived: true)
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.scheme == "SameScheme")
        for id in ids {
            let rec = try await store.fetch(id: id)
            #expect(rec?.applicationID == app.id)
        }
    }

    @Test("Empty V1 store migrates to a V2 store with zero Applications")
    func emptyStoreMigrates() async throws {
        let storeURL = Self.makeStoreURL()
        defer { Self.removeStore(at: storeURL) }

        try Self.seedV1(at: storeURL) { _ in }

        let store = try RunHistoryStore(url: storeURL)
        let apps = try await store.applications(includeArchived: true)
        #expect(apps.isEmpty)
        let recs = try await store.fetchRecent(limit: 100)
        #expect(recs.isEmpty)
    }

    @Test("Completed RunRecord (verdict=success) still rebinds to its Application")
    func completedRunStillBinds() async throws {
        let storeURL = Self.makeStoreURL()
        defer { Self.removeStore(at: storeURL) }

        let id = UUID()
        try Self.seedV1(at: storeURL) { context in
            let row = HarnessSchemaV1.RunRecord(
                id: id,
                createdAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 500),
                projectPath: "/tmp/Old.xcodeproj",
                scheme: "OldScheme",
                displayName: "Old",
                simulatorUDID: "UDID-O",
                simulatorName: "iPhone O",
                simulatorRuntime: "iOS 18.4",
                goal: "do it",
                persona: "first-time user",
                modelRaw: AgentModel.opus47.rawValue,
                modeRaw: RunMode.stepByStep.rawValue,
                verdictRaw: Verdict.success.rawValue,
                summary: "done",
                stepCount: 10,
                frictionCount: 1,
                wouldRealUserSucceed: true,
                tokensUsedInput: 1000,
                tokensUsedOutput: 100,
                runDirectoryPath: "/tmp/runs/\(id.uuidString)"
            )
            context.insert(row)
        }

        let store = try RunHistoryStore(url: storeURL)
        let apps = try await store.applications(includeArchived: true)
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        let rec = try await store.fetch(id: id)
        #expect(rec?.applicationID == app.id)
        #expect(rec?.verdict == .success)
        #expect(rec?.summary == "done")
        // Application's lastUsedAt picks up the run's completedAt.
        #expect(app.lastUsedAt == Date(timeIntervalSince1970: 500))
    }

    // MARK: - Helpers

    /// Build a unique on-disk URL under the per-test temp directory. The
    /// directory is created lazily by SwiftData when it opens the file; we
    /// just make sure the parent exists.
    private static func makeStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.store")
    }

    private static func removeStore(at url: URL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
    }

    /// Open `storeURL` with V1 schema (and the full plan, so SwiftData
    /// stamps the store with V1's version identifier). The caller seeds the
    /// V1 rows; we save and drop the container so SwiftData closes the
    /// SQLite file before the V2 reopen below.
    private static func seedV1(at storeURL: URL, _ seed: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: HarnessSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: V1OnlyMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        try seed(context)
        if context.hasChanges {
            try context.save()
        }
        _ = container
    }
}

/// Minimal migration plan that only knows about V1 — used by the test
/// helper to stamp a fresh on-disk store with the V1 version identifier so
/// `HarnessMigrationPlan` can pick up from there on the V2 reopen.
private enum V1OnlyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HarnessSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
