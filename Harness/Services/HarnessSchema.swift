//
//  HarnessSchema.swift
//  Harness
//
//  SwiftData schema versions for Harness's history index.
//
//  Per `standards/02-swiftdata.md` SwiftData is the queryable index for
//  Runs and the small library entities (Applications / Personas / Actions /
//  Action Chains). The per-step event stream stays as JSONL on disk under
//  the run directory — that invariant does not change here.
//
//  V1 — original two-model shape: `RunRecord` + `ProjectRef`. Kept verbatim
//  so existing on-disk stores can be opened and migrated.
//
//  V2 — adds `Application`, `Persona`, `Action`, `ActionChain`,
//  `ActionChainStep` and grows `RunRecord` with optional refs to each.
//  `ProjectRef` is dropped: every project is folded into an `Application`
//  during the V1→V2 stage.
//

import Foundation
import SwiftData
import os

// MARK: - V1 (original shape)

/// V1 namespace for the original two-model schema. The classes are scoped
/// inside the enum so V2 can reuse the names `RunRecord` (with extra fields)
/// at file scope without clashing.
enum HarnessSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [RunRecord.self, ProjectRef.self]
    }

    /// V1 RunRecord — the original shape, before Applications/Personas/Actions
    /// were modeled as their own entities. The Swift type lives at
    /// `HarnessSchemaV1.RunRecord`; SwiftData uses the simple name
    /// `RunRecord` as the entity name, which matches V2's `RunRecord` so
    /// lightweight column-add migration applies cleanly.
    @Model
    final class RunRecord {

        @Attribute(.unique) var id: UUID

        var createdAt: Date
        var completedAt: Date?

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

        var verdictRaw: String?
        var summary: String?
        var stepCount: Int
        var frictionCount: Int
        var wouldRealUserSucceed: Bool
        var tokensUsedInput: Int
        var tokensUsedOutput: Int

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
    }

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
    }
}

// MARK: - V2 (active shape)

enum HarnessSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            RunRecord.self,
            Application.self,
            Persona.self,
            Action.self,
            ActionChain.self,
            ActionChainStep.self
        ]
    }
}

// MARK: - V2 @Model types (file-scope; production code uses these)

/// One row per finished or in-progress run. `runDirectoryURL` points at the
/// on-disk events.jsonl + screenshots; the SwiftData row is a small index.
@Model
final class RunRecord {

    // MARK: Identity
    @Attribute(.unique) var id: UUID

    // MARK: Run name (optional — auto-filled in Phase E)
    var name: String?

    // MARK: Lifecycle
    var createdAt: Date
    var completedAt: Date?

    // MARK: Goal context (denormalized — the durable snapshot)
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
    var runDirectoryPath: String

    // MARK: Optional refs to library entities
    /// Strong ref to the `Application` this run was launched against.
    /// Nullified on Application delete; the denormalized fields above survive.
    @Relationship(deleteRule: .nullify) var application: Application?
    @Relationship(deleteRule: .nullify) var persona_: Persona?
    @Relationship(deleteRule: .nullify) var action: Action?
    @Relationship(deleteRule: .nullify) var actionChain: ActionChain?

    /// Redundant lookup-IDs mirroring the relationships above. SwiftData's
    /// `.nullify` cascade can leave the in-memory relationship pointing at an
    /// invalidated backing record after the parent is deleted in the same
    /// context — touching `row.application?.id` then crashes with
    /// "model instance was invalidated." Snapshots therefore read from these
    /// stored UUIDs (always cleared explicitly in our delete methods so they
    /// never out-live the relationship).
    var applicationLookupID: UUID?
    var personaLookupID: UUID?
    var actionLookupID: UUID?
    var actionChainLookupID: UUID?

    /// Phase E: JSON-encoded `[LegRecord]` for chain runs. `nil` (the
    /// default) on single-action runs and on rows that pre-date the
    /// rework. Property is optional with a default value so SwiftData's
    /// lightweight migration adds the column to existing V2 stores
    /// without a manual stage. The field is never queried — only ever
    /// loaded alongside the parent run via the snapshot bridge.
    var legsJSON: String? = nil

    /// Cache-read tokens accumulated across the run (≈90% off the input
    /// rate). Optional with a default so existing stores migrate
    /// lightweight; nil for runs that completed before this column landed
    /// — the cost cell renders as `$0.00` for those, which matches the
    /// historical reality that we didn't measure cache hits for them.
    var tokensUsedCacheRead: Int? = nil
    /// Cache-creation tokens (≈1.25× input rate). Same migration shape.
    var tokensUsedCacheCreation: Int? = nil

    init(
        id: UUID,
        name: String? = nil,
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
        runDirectoryPath: String,
        application: Application? = nil,
        persona_: Persona? = nil,
        action: Action? = nil,
        actionChain: ActionChain? = nil
    ) {
        self.id = id
        self.name = name
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
        self.application = application
        self.persona_ = persona_
        self.action = action
        self.actionChain = actionChain
        self.applicationLookupID = application?.id
        self.personaLookupID = persona_?.id
        self.actionLookupID = action?.id
        self.actionChainLookupID = actionChain?.id
    }

    var runDirectoryURL: URL { URL(fileURLWithPath: runDirectoryPath) }
    var verdict: Verdict? { verdictRaw.flatMap(Verdict.init(rawValue:)) }
    var model: AgentModel? { AgentModel(rawValue: modelRaw) }
    var mode: RunMode? { RunMode(rawValue: modeRaw) }
}

@Model
final class Application {

    // `#Index` lives behind macOS 15. Until the deployment target moves
    // we lean on `lastUsedAt`'s SortDescriptor in queries — SwiftData still
    // serves them efficiently from the small store sizes we see in practice.

    @Attribute(.unique) var id: UUID

    var name: String
    var createdAt: Date
    var lastUsedAt: Date
    var archivedAt: Date?

    var projectPath: String
    var projectBookmark: Data?
    var scheme: String

    var defaultSimulatorUDID: String?
    var defaultSimulatorName: String?
    var defaultSimulatorRuntime: String?

    var defaultModelRaw: String
    var defaultModeRaw: String
    var defaultStepBudget: Int

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        archivedAt: Date? = nil,
        projectPath: String,
        projectBookmark: Data? = nil,
        scheme: String,
        defaultSimulatorUDID: String? = nil,
        defaultSimulatorName: String? = nil,
        defaultSimulatorRuntime: String? = nil,
        defaultModelRaw: String = AgentModel.opus47.rawValue,
        defaultModeRaw: String = RunMode.stepByStep.rawValue,
        defaultStepBudget: Int = 40
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
        self.projectPath = projectPath
        self.projectBookmark = projectBookmark
        self.scheme = scheme
        self.defaultSimulatorUDID = defaultSimulatorUDID
        self.defaultSimulatorName = defaultSimulatorName
        self.defaultSimulatorRuntime = defaultSimulatorRuntime
        self.defaultModelRaw = defaultModelRaw
        self.defaultModeRaw = defaultModeRaw
        self.defaultStepBudget = defaultStepBudget
    }
}

@Model
final class Persona {

    @Attribute(.unique) var id: UUID

    var name: String
    var blurb: String
    var promptText: String
    var isBuiltIn: Bool
    var createdAt: Date
    var lastUsedAt: Date
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        blurb: String,
        promptText: String,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.promptText = promptText
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
    }
}

@Model
final class Action {

    @Attribute(.unique) var id: UUID

    var name: String
    var promptText: String
    var notes: String
    var createdAt: Date
    var lastUsedAt: Date
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        promptText: String,
        notes: String = "",
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.promptText = promptText
        self.notes = notes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
    }
}

@Model
final class ActionChain {

    @Attribute(.unique) var id: UUID

    var name: String
    var notes: String
    var createdAt: Date
    var lastUsedAt: Date
    var archivedAt: Date?

    /// Ordered chain steps. Cascade-delete: deleting the chain deletes its
    /// steps. Steps point at `Action` with a nullify rule (Action delete
    /// leaves the step in place but with `action == nil`).
    @Relationship(deleteRule: .cascade) var steps: [ActionChainStep]

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        archivedAt: Date? = nil,
        steps: [ActionChainStep] = []
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
        self.steps = steps
    }
}

@Model
final class ActionChainStep {

    @Attribute(.unique) var id: UUID

    var index: Int
    @Relationship(deleteRule: .nullify) var action: Action?
    var preservesState: Bool

    init(
        id: UUID = UUID(),
        index: Int,
        action: Action? = nil,
        preservesState: Bool = false
    ) {
        self.id = id
        self.index = index
        self.action = action
        self.preservesState = preservesState
    }
}

// MARK: - Migration plan

/// V1 → V2: lightweight model addition (Application/Persona/Action/
/// ActionChain/ActionChainStep + new RunRecord ref columns) plus a custom
/// `didMigrate` step that emits one `Application` per distinct
/// `(projectPath, scheme)` tuple across surviving `RunRecord`s and
/// rebinds `RunRecord.application`. ProjectRef is dropped — its rows are
/// not in V2's models list, so SwiftData drops the table.
enum HarnessMigrationPlan: SchemaMigrationPlan {

    private static let logger = Logger(
        subsystem: "com.harness.app",
        category: "HarnessMigrationPlan"
    )

    static var schemas: [any VersionedSchema.Type] {
        [HarnessSchemaV1.self, HarnessSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [v1ToV2]
    }

    static let v1ToV2 = MigrationStage.custom(
        fromVersion: HarnessSchemaV1.self,
        toVersion: HarnessSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            try backfillApplications(context: context)
        }
    )

    /// Walk every `RunRecord` in the post-migration store, group by
    /// `(projectPath, scheme)`, and ensure one `Application` exists per
    /// tuple. Bind `runRecord.application` to the matching row. Idempotent —
    /// runs cleanly on a store that already has Applications.
    static func backfillApplications(context: ModelContext) throws {
        let runs = try context.fetch(FetchDescriptor<RunRecord>())
        guard !runs.isEmpty else { return }

        let existing = try context.fetch(FetchDescriptor<Application>())
        var byKey: [String: Application] = [:]
        for app in existing {
            byKey[Self.key(projectPath: app.projectPath, scheme: app.scheme)] = app
        }

        for run in runs {
            let key = Self.key(projectPath: run.projectPath, scheme: run.scheme)
            let app: Application
            if let existing = byKey[key] {
                app = existing
            } else {
                app = Application(
                    name: run.displayName,
                    createdAt: run.createdAt,
                    lastUsedAt: run.completedAt ?? run.createdAt,
                    projectPath: run.projectPath,
                    scheme: run.scheme,
                    defaultSimulatorUDID: run.simulatorUDID.isEmpty ? nil : run.simulatorUDID,
                    defaultSimulatorName: run.simulatorName.isEmpty ? nil : run.simulatorName,
                    defaultSimulatorRuntime: run.simulatorRuntime.isEmpty ? nil : run.simulatorRuntime,
                    defaultModelRaw: AgentModel.opus47.rawValue,
                    defaultModeRaw: RunMode.stepByStep.rawValue,
                    defaultStepBudget: 40
                )
                context.insert(app)
                byKey[key] = app
            }
            if run.application == nil {
                run.application = app
                run.applicationLookupID = app.id
            }
            // Bump lastUsedAt forward so most-recently-run apps sort first.
            if let completed = run.completedAt, completed > app.lastUsedAt {
                app.lastUsedAt = completed
            } else if run.createdAt > app.lastUsedAt {
                app.lastUsedAt = run.createdAt
            }
        }

        do {
            try context.save()
        } catch {
            Self.logger.error("v1ToV2 backfill save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func key(projectPath: String, scheme: String) -> String {
        "\(projectPath)\u{1F}\(scheme)"
    }
}
