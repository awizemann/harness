//
//  RunHistoryStore.swift
//  Harness
//
//  SwiftData container for the Run history index. Per
//  `standards/02-swiftdata.md`, SwiftData is used **only** for the small,
//  queryable record of past runs and the recents list of Xcode projects.
//  Per-step events live in JSONL on disk.
//

import Foundation
import SwiftData
import os

// MARK: - SwiftData @Model types

/// One row per finished or in-progress run. `runDirectoryURL` points at the
/// on-disk events.jsonl + screenshots; the SwiftData row is a small index.
@Model
final class RunRecord {

    // MARK: Identity
    @Attribute(.unique) var id: UUID

    // MARK: Lifecycle
    var createdAt: Date
    var completedAt: Date?

    // MARK: Goal context
    var projectPath: String
    var scheme: String
    var displayName: String
    var simulatorUDID: String
    var simulatorName: String
    var simulatorRuntime: String
    var goal: String
    var persona: String
    var modelRaw: String
    var modeRaw: String

    // MARK: Outcome (nil while running)
    var verdictRaw: String?
    var summary: String?
    var stepCount: Int
    var frictionCount: Int
    var wouldRealUserSucceed: Bool
    var tokensUsedInput: Int
    var tokensUsedOutput: Int

    // MARK: On-disk pointer
    /// String form of the run-directory URL (NOT a security-scoped bookmark —
    /// Harness is non-sandboxed).
    var runDirectoryPath: String

    init(
        id: UUID,
        createdAt: Date,
        completedAt: Date? = nil,
        projectPath: String,
        scheme: String,
        displayName: String,
        simulatorUDID: String,
        simulatorName: String,
        simulatorRuntime: String,
        goal: String,
        persona: String,
        modelRaw: String,
        modeRaw: String,
        verdictRaw: String? = nil,
        summary: String? = nil,
        stepCount: Int = 0,
        frictionCount: Int = 0,
        wouldRealUserSucceed: Bool = false,
        tokensUsedInput: Int = 0,
        tokensUsedOutput: Int = 0,
        runDirectoryPath: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.projectPath = projectPath
        self.scheme = scheme
        self.displayName = displayName
        self.simulatorUDID = simulatorUDID
        self.simulatorName = simulatorName
        self.simulatorRuntime = simulatorRuntime
        self.goal = goal
        self.persona = persona
        self.modelRaw = modelRaw
        self.modeRaw = modeRaw
        self.verdictRaw = verdictRaw
        self.summary = summary
        self.stepCount = stepCount
        self.frictionCount = frictionCount
        self.wouldRealUserSucceed = wouldRealUserSucceed
        self.tokensUsedInput = tokensUsedInput
        self.tokensUsedOutput = tokensUsedOutput
        self.runDirectoryPath = runDirectoryPath
    }

    var runDirectoryURL: URL { URL(fileURLWithPath: runDirectoryPath) }
    var verdict: Verdict? { verdictRaw.flatMap(Verdict.init(rawValue:)) }
    var model: AgentModel? { AgentModel(rawValue: modelRaw) }
    var mode: RunMode? { RunMode(rawValue: modeRaw) }
}

/// Cached reference to an Xcode project Harness has been pointed at. Powers
/// the recents picker on the goal-input screen.
@Model
final class ProjectRef {
    @Attribute(.unique) var id: UUID
    var path: String
    var displayName: String
    var defaultScheme: String?
    var defaultSimulatorUDID: String?
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        defaultScheme: String? = nil,
        defaultSimulatorUDID: String? = nil,
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.defaultScheme = defaultScheme
        self.defaultSimulatorUDID = defaultSimulatorUDID
        self.lastUsedAt = lastUsedAt
    }

    var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Schema versioning (single version today)

enum HarnessSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [RunRecord.self, ProjectRef.self] }
}

enum HarnessMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HarnessSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Protocol

protocol RunHistoryStoring: Sendable {
    /// Insert or update a run record (Skeleton-First pattern from `02-swiftdata.md §2`:
    /// the row is created at `runStarted` and updated at `runCompleted`).
    func upsert(_ record: RunRecordSnapshot) async throws

    /// Mark a run as completed by patching outcome fields.
    func markCompleted(id: UUID, outcome: RunOutcome) async throws

    /// Recent runs, newest first.
    func fetchRecent(limit: Int) async throws -> [RunRecordSnapshot]

    /// Look up by id.
    func fetch(id: UUID) async throws -> RunRecordSnapshot?

    /// Hard-delete a run row AND its on-disk directory.
    func delete(id: UUID) async throws

    // Recents-projects helpers.
    func touchProject(_ ref: ProjectRefSnapshot) async throws
    func recentProjects(limit: Int) async throws -> [ProjectRefSnapshot]
}

/// Sendable snapshot of a `RunRecord`. Used to ferry data across the actor
/// boundary; the `@Model` itself isn't `Sendable`.
struct RunRecordSnapshot: Sendable, Hashable {
    let id: UUID
    let createdAt: Date
    let completedAt: Date?
    let projectPath: String
    let scheme: String
    let displayName: String
    let simulatorUDID: String
    let simulatorName: String
    let simulatorRuntime: String
    let goal: String
    let persona: String
    let modelRaw: String
    let modeRaw: String
    let verdictRaw: String?
    let summary: String?
    let stepCount: Int
    let frictionCount: Int
    let wouldRealUserSucceed: Bool
    let tokensUsedInput: Int
    let tokensUsedOutput: Int
    let runDirectoryPath: String

    var verdict: Verdict? { verdictRaw.flatMap(Verdict.init(rawValue:)) }
    var runDirectoryURL: URL { URL(fileURLWithPath: runDirectoryPath) }
}

struct ProjectRefSnapshot: Sendable, Hashable {
    let id: UUID
    let path: String
    let displayName: String
    let defaultScheme: String?
    let defaultSimulatorUDID: String?
    let lastUsedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Default actor implementation

actor RunHistoryStore: RunHistoryStoring {

    private static let logger = Logger(subsystem: "com.harness.app", category: "RunHistoryStore")

    private let modelContainer: ModelContainer
    private var modelContext: ModelContext

    /// Production initializer using the default app-support store.
    /// In-memory variant exists for tests; see `inMemory()`.
    init(url: URL? = nil) throws {
        let schema = Schema(versionedSchema: HarnessSchemaV1.self)
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            try HarnessPaths.ensureDirectory(HarnessPaths.appSupport)
            let storeURL = HarnessPaths.appSupport.appendingPathComponent("history.store")
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        let container = try ModelContainer(
            for: schema,
            migrationPlan: HarnessMigrationPlan.self,
            configurations: [configuration]
        )
        self.modelContainer = container
        self.modelContext = ModelContext(container)
    }

    static func inMemory() throws -> RunHistoryStore {
        let schema = Schema(versionedSchema: HarnessSchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: HarnessMigrationPlan.self,
            configurations: [configuration]
        )
        return try RunHistoryStore(prebuiltContainer: container)
    }

    private init(prebuiltContainer container: ModelContainer) throws {
        self.modelContainer = container
        self.modelContext = ModelContext(container)
    }

    // MARK: Upsert / mark completed

    func upsert(_ snapshot: RunRecordSnapshot) async throws {
        let id = snapshot.id
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        let existing = try modelContext.fetch(descriptor).first

        if let row = existing {
            row.completedAt = snapshot.completedAt
            row.verdictRaw = snapshot.verdictRaw
            row.summary = snapshot.summary
            row.stepCount = snapshot.stepCount
            row.frictionCount = snapshot.frictionCount
            row.wouldRealUserSucceed = snapshot.wouldRealUserSucceed
            row.tokensUsedInput = snapshot.tokensUsedInput
            row.tokensUsedOutput = snapshot.tokensUsedOutput
        } else {
            let row = RunRecord(
                id: snapshot.id,
                createdAt: snapshot.createdAt,
                completedAt: snapshot.completedAt,
                projectPath: snapshot.projectPath,
                scheme: snapshot.scheme,
                displayName: snapshot.displayName,
                simulatorUDID: snapshot.simulatorUDID,
                simulatorName: snapshot.simulatorName,
                simulatorRuntime: snapshot.simulatorRuntime,
                goal: snapshot.goal,
                persona: snapshot.persona,
                modelRaw: snapshot.modelRaw,
                modeRaw: snapshot.modeRaw,
                verdictRaw: snapshot.verdictRaw,
                summary: snapshot.summary,
                stepCount: snapshot.stepCount,
                frictionCount: snapshot.frictionCount,
                wouldRealUserSucceed: snapshot.wouldRealUserSucceed,
                tokensUsedInput: snapshot.tokensUsedInput,
                tokensUsedOutput: snapshot.tokensUsedOutput,
                runDirectoryPath: snapshot.runDirectoryPath
            )
            modelContext.insert(row)
        }

        do {
            try modelContext.save()
        } catch {
            Self.logger.error("upsert save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func markCompleted(id: UUID, outcome: RunOutcome) async throws {
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.completedAt = outcome.completedAt
        row.verdictRaw = outcome.verdict.rawValue
        row.summary = outcome.summary
        row.stepCount = outcome.stepCount
        row.frictionCount = outcome.frictionCount
        row.wouldRealUserSucceed = outcome.wouldRealUserSucceed
        row.tokensUsedInput = outcome.tokensUsedInput
        row.tokensUsedOutput = outcome.tokensUsedOutput
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("markCompleted save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: Fetch

    func fetchRecent(limit: Int) async throws -> [RunRecordSnapshot] {
        var descriptor = FetchDescriptor<RunRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let rows = try modelContext.fetch(descriptor)
        return rows.map(Self.snapshot(of:))
    }

    func fetch(id: UUID) async throws -> RunRecordSnapshot? {
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first.map(Self.snapshot(of:))
    }

    func delete(id: UUID) async throws {
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        if let row = try modelContext.fetch(descriptor).first {
            // On-disk run directory removal first; SwiftData row second.
            try? FileManager.default.removeItem(at: row.runDirectoryURL)
            modelContext.delete(row)
            try modelContext.save()
        }
    }

    // MARK: Recents-projects

    func touchProject(_ snapshot: ProjectRefSnapshot) async throws {
        let path = snapshot.path
        let descriptor = FetchDescriptor<ProjectRef>(predicate: #Predicate { $0.path == path })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.lastUsedAt = snapshot.lastUsedAt
            existing.displayName = snapshot.displayName
            if let s = snapshot.defaultScheme { existing.defaultScheme = s }
            if let u = snapshot.defaultSimulatorUDID { existing.defaultSimulatorUDID = u }
        } else {
            modelContext.insert(ProjectRef(
                id: snapshot.id,
                path: snapshot.path,
                displayName: snapshot.displayName,
                defaultScheme: snapshot.defaultScheme,
                defaultSimulatorUDID: snapshot.defaultSimulatorUDID,
                lastUsedAt: snapshot.lastUsedAt
            ))
        }
        try modelContext.save()
    }

    func recentProjects(limit: Int) async throws -> [ProjectRefSnapshot] {
        var descriptor = FetchDescriptor<ProjectRef>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let rows = try modelContext.fetch(descriptor)
        return rows.map { row in
            ProjectRefSnapshot(
                id: row.id,
                path: row.path,
                displayName: row.displayName,
                defaultScheme: row.defaultScheme,
                defaultSimulatorUDID: row.defaultSimulatorUDID,
                lastUsedAt: row.lastUsedAt
            )
        }
    }

    // MARK: Snapshot helper

    nonisolated private static func snapshot(of row: RunRecord) -> RunRecordSnapshot {
        RunRecordSnapshot(
            id: row.id,
            createdAt: row.createdAt,
            completedAt: row.completedAt,
            projectPath: row.projectPath,
            scheme: row.scheme,
            displayName: row.displayName,
            simulatorUDID: row.simulatorUDID,
            simulatorName: row.simulatorName,
            simulatorRuntime: row.simulatorRuntime,
            goal: row.goal,
            persona: row.persona,
            modelRaw: row.modelRaw,
            modeRaw: row.modeRaw,
            verdictRaw: row.verdictRaw,
            summary: row.summary,
            stepCount: row.stepCount,
            frictionCount: row.frictionCount,
            wouldRealUserSucceed: row.wouldRealUserSucceed,
            tokensUsedInput: row.tokensUsedInput,
            tokensUsedOutput: row.tokensUsedOutput,
            runDirectoryPath: row.runDirectoryPath
        )
    }
}

// MARK: - Convenience builder

extension RunRecordSnapshot {
    /// Build a "skeleton" snapshot from a freshly-started request — outcome
    /// fields default to "still running."
    static func skeleton(from request: GoalRequest) -> RunRecordSnapshot {
        let runDir = HarnessPaths.runDir(for: request.id).path
        return RunRecordSnapshot(
            id: request.id,
            createdAt: Date(),
            completedAt: nil,
            projectPath: request.project.path.path,
            scheme: request.project.scheme,
            displayName: request.project.displayName,
            simulatorUDID: request.simulator.udid,
            simulatorName: request.simulator.name,
            simulatorRuntime: request.simulator.runtime,
            goal: request.goal,
            persona: request.persona,
            modelRaw: request.model.rawValue,
            modeRaw: request.mode.rawValue,
            verdictRaw: nil,
            summary: nil,
            stepCount: 0,
            frictionCount: 0,
            wouldRealUserSucceed: false,
            tokensUsedInput: 0,
            tokensUsedOutput: 0,
            runDirectoryPath: runDir
        )
    }
}
