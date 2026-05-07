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

// MARK: - V2 (originally shipped: no legsJSON, no cost columns)
//
// V2's @Model types are nested in this enum so they remain a *distinct*
// class identity from V3's file-scope types. SwiftData computes a per-
// `VersionedSchema` checksum from each schema's `models` array — if two
// schemas list the same Swift types it rejects the migration plan with
// `Duplicate version checksums across stages detected`. Each version
// must have its own typed namespace.
//
// CoreData entity names default to the simple class name, so
// `HarnessSchemaV2.RunRecord` and the file-scope `RunRecord` both map
// to the entity literally named `"RunRecord"` — the same SQLite table
// continues across the version, and additive lightweight migration
// applies the column delta automatically.
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

    @Model
    final class RunRecord {
        @Attribute(.unique) var id: UUID
        var name: String?
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
        @Relationship(deleteRule: .nullify) var application: HarnessSchemaV2.Application?
        @Relationship(deleteRule: .nullify) var persona_: HarnessSchemaV2.Persona?
        @Relationship(deleteRule: .nullify) var action: HarnessSchemaV2.Action?
        @Relationship(deleteRule: .nullify) var actionChain: HarnessSchemaV2.ActionChain?
        var applicationLookupID: UUID?
        var personaLookupID: UUID?
        var actionLookupID: UUID?
        var actionChainLookupID: UUID?

        init(
            id: UUID,
            createdAt: Date,
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
            runDirectoryPath: String
        ) {
            self.id = id
            self.createdAt = createdAt
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
            self.runDirectoryPath = runDirectoryPath
            self.stepCount = 0
            self.frictionCount = 0
            self.wouldRealUserSucceed = false
            self.tokensUsedInput = 0
            self.tokensUsedOutput = 0
        }
    }

    @Model
    final class Application {
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
            createdAt: Date,
            lastUsedAt: Date,
            archivedAt: Date? = nil,
            projectPath: String,
            projectBookmark: Data? = nil,
            scheme: String,
            defaultSimulatorUDID: String? = nil,
            defaultSimulatorName: String? = nil,
            defaultSimulatorRuntime: String? = nil,
            defaultModelRaw: String,
            defaultModeRaw: String,
            defaultStepBudget: Int
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

        init(id: UUID = UUID(), name: String, blurb: String, promptText: String, isBuiltIn: Bool, createdAt: Date, lastUsedAt: Date, archivedAt: Date? = nil) {
            self.id = id; self.name = name; self.blurb = blurb
            self.promptText = promptText; self.isBuiltIn = isBuiltIn
            self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
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

        init(id: UUID = UUID(), name: String, promptText: String, notes: String, createdAt: Date, lastUsedAt: Date, archivedAt: Date? = nil) {
            self.id = id; self.name = name; self.promptText = promptText
            self.notes = notes; self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt; self.archivedAt = archivedAt
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
        @Relationship(deleteRule: .cascade) var steps: [HarnessSchemaV2.ActionChainStep] = []

        init(id: UUID = UUID(), name: String, notes: String, createdAt: Date, lastUsedAt: Date, archivedAt: Date? = nil) {
            self.id = id; self.name = name; self.notes = notes
            self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class ActionChainStep {
        @Attribute(.unique) var id: UUID
        var index: Int
        @Relationship(deleteRule: .nullify) var action: HarnessSchemaV2.Action?
        var preservesState: Bool

        init(id: UUID = UUID(), index: Int, action: HarnessSchemaV2.Action? = nil, preservesState: Bool) {
            self.id = id; self.index = index; self.action = action
            self.preservesState = preservesState
        }
    }
}

// MARK: - V3 (frozen shape — was the "active" schema before V4 added
//                              the platform discriminator)
//
// V3 is the shape that shipped with `legsJSON` + `tokensUsedCacheRead` +
// `tokensUsedCacheCreation` on RunRecord but BEFORE the platform
// discriminator landed on Application. We freeze the V3 model types
// inside this enum so V4 can introduce a new file-scope Application
// shape with different stored properties without colliding with V3's
// Swift class identity.
//
// CoreData entity names default to the simple class name, so
// `HarnessSchemaV3.RunRecord` and the V4 file-scope `RunRecord` both map
// to the entity literally named `"RunRecord"` — same SQLite table
// continues across the version, lightweight migration applies the
// column delta automatically. Same trick V2 used.
enum HarnessSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
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

    @Model
    final class RunRecord {
        @Attribute(.unique) var id: UUID
        var name: String?
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
        @Relationship(deleteRule: .nullify) var application: HarnessSchemaV3.Application?
        @Relationship(deleteRule: .nullify) var persona_: HarnessSchemaV3.Persona?
        @Relationship(deleteRule: .nullify) var action: HarnessSchemaV3.Action?
        @Relationship(deleteRule: .nullify) var actionChain: HarnessSchemaV3.ActionChain?
        var applicationLookupID: UUID?
        var personaLookupID: UUID?
        var actionLookupID: UUID?
        var actionChainLookupID: UUID?
        var legsJSON: String? = nil
        var tokensUsedCacheRead: Int? = nil
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
            runDirectoryPath: String
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
            self.runDirectoryPath = runDirectoryPath
            self.stepCount = 0
            self.frictionCount = 0
            self.wouldRealUserSucceed = false
            self.tokensUsedInput = 0
            self.tokensUsedOutput = 0
        }
    }

    @Model
    final class Application {
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
            createdAt: Date,
            lastUsedAt: Date,
            archivedAt: Date? = nil,
            projectPath: String,
            projectBookmark: Data? = nil,
            scheme: String,
            defaultSimulatorUDID: String? = nil,
            defaultSimulatorName: String? = nil,
            defaultSimulatorRuntime: String? = nil,
            defaultModelRaw: String,
            defaultModeRaw: String,
            defaultStepBudget: Int
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

        init(id: UUID = UUID(), name: String, blurb: String, promptText: String, isBuiltIn: Bool, createdAt: Date, lastUsedAt: Date, archivedAt: Date? = nil) {
            self.id = id; self.name = name; self.blurb = blurb
            self.promptText = promptText; self.isBuiltIn = isBuiltIn
            self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
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

        init(id: UUID = UUID(), name: String, promptText: String, notes: String, createdAt: Date, lastUsedAt: Date, archivedAt: Date? = nil) {
            self.id = id; self.name = name; self.promptText = promptText
            self.notes = notes; self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt; self.archivedAt = archivedAt
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
        @Relationship(deleteRule: .cascade) var steps: [HarnessSchemaV3.ActionChainStep] = []

        init(id: UUID = UUID(), name: String, notes: String, createdAt: Date, lastUsedAt: Date, archivedAt: Date? = nil) {
            self.id = id; self.name = name; self.notes = notes
            self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class ActionChainStep {
        @Attribute(.unique) var id: UUID
        var index: Int
        @Relationship(deleteRule: .nullify) var action: HarnessSchemaV3.Action?
        var preservesState: Bool

        init(id: UUID = UUID(), index: Int, action: HarnessSchemaV3.Action? = nil, preservesState: Bool) {
            self.id = id; self.index = index; self.action = action
            self.preservesState = preservesState
        }
    }
}

// MARK: - V4 (active shape — adds `Application.platformKindRaw` + macOS/web fields)
//
// V4 introduces the platform discriminator on `Application`. Each Application
// now declares whether it's an iOS Simulator app (today's only working option),
// a macOS app (Phase 2), or a web app (Phase 3). Per-platform fields land
// alongside as optionals so the schema doesn't need to grow again when those
// phases ship.
//
// V4's `@Model` types live at file scope. Production code references
// `RunRecord` / `Application` / etc. without a namespace. The migration from
// V3 is **lightweight** because all V4 additions are optional / defaulted —
// `platformKindRaw` defaults to `"ios_simulator"` so existing rows resolve
// to the iOS path with no behavioural change.
// V4 is now frozen — the nested types below are an exact copy of the
// V4 file-scope shape captured before V5 added per-Application
// credentials. Production code keeps using the file-scope `Application`,
// `RunRecord`, etc. (which evolved to V5); the migration plan uses
// `HarnessSchemaV4.X` for V3→V4 lightweight inference and as the
// fromVersion of the v4ToV5 stage.
enum HarnessSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(4, 0, 0) }
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

    @Model
    final class RunRecord {
        @Attribute(.unique) var id: UUID
        var name: String?
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
        @Relationship(deleteRule: .nullify) var application: HarnessSchemaV4.Application?
        @Relationship(deleteRule: .nullify) var persona_: HarnessSchemaV4.Persona?
        @Relationship(deleteRule: .nullify) var action: HarnessSchemaV4.Action?
        @Relationship(deleteRule: .nullify) var actionChain: HarnessSchemaV4.ActionChain?
        var applicationLookupID: UUID?
        var personaLookupID: UUID?
        var actionLookupID: UUID?
        var actionChainLookupID: UUID?
        var legsJSON: String? = nil
        var tokensUsedCacheRead: Int? = nil
        var tokensUsedCacheCreation: Int? = nil
        var platformKindRaw: String? = nil

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
            runDirectoryPath: String
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
            self.runDirectoryPath = runDirectoryPath
            self.stepCount = 0
            self.frictionCount = 0
            self.wouldRealUserSucceed = false
            self.tokensUsedInput = 0
            self.tokensUsedOutput = 0
        }
    }

    @Model
    final class Application {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var lastUsedAt: Date
        var archivedAt: Date?
        var platformKindRaw: String? = nil
        var projectPath: String
        var projectBookmark: Data?
        var scheme: String
        var defaultSimulatorUDID: String?
        var defaultSimulatorName: String?
        var defaultSimulatorRuntime: String?
        var macAppBundlePath: String? = nil
        var macAppBundleBookmark: Data? = nil
        var webStartURL: String? = nil
        var webViewportWidthPt: Int? = nil
        var webViewportHeightPt: Int? = nil
        var defaultModelRaw: String
        var defaultModeRaw: String
        var defaultStepBudget: Int

        init(
            id: UUID = UUID(),
            name: String,
            createdAt: Date = Date(),
            lastUsedAt: Date = Date(),
            archivedAt: Date? = nil,
            platformKindRaw: String? = nil,
            projectPath: String,
            projectBookmark: Data? = nil,
            scheme: String,
            defaultSimulatorUDID: String? = nil,
            defaultSimulatorName: String? = nil,
            defaultSimulatorRuntime: String? = nil,
            macAppBundlePath: String? = nil,
            macAppBundleBookmark: Data? = nil,
            webStartURL: String? = nil,
            webViewportWidthPt: Int? = nil,
            webViewportHeightPt: Int? = nil,
            defaultModelRaw: String,
            defaultModeRaw: String,
            defaultStepBudget: Int
        ) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.archivedAt = archivedAt
            self.platformKindRaw = platformKindRaw
            self.projectPath = projectPath
            self.projectBookmark = projectBookmark
            self.scheme = scheme
            self.defaultSimulatorUDID = defaultSimulatorUDID
            self.defaultSimulatorName = defaultSimulatorName
            self.defaultSimulatorRuntime = defaultSimulatorRuntime
            self.macAppBundlePath = macAppBundlePath
            self.macAppBundleBookmark = macAppBundleBookmark
            self.webStartURL = webStartURL
            self.webViewportWidthPt = webViewportWidthPt
            self.webViewportHeightPt = webViewportHeightPt
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
        @Relationship(deleteRule: .cascade) var steps: [HarnessSchemaV4.ActionChainStep]

        init(
            id: UUID = UUID(),
            name: String,
            notes: String = "",
            createdAt: Date = Date(),
            lastUsedAt: Date = Date(),
            archivedAt: Date? = nil,
            steps: [HarnessSchemaV4.ActionChainStep] = []
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
        @Relationship(deleteRule: .nullify) var action: HarnessSchemaV4.Action?
        var preservesState: Bool

        init(
            id: UUID = UUID(),
            index: Int,
            action: HarnessSchemaV4.Action? = nil,
            preservesState: Bool = false
        ) {
            self.id = id
            self.index = index
            self.action = action
            self.preservesState = preservesState
        }
    }
}

// V5 introduces per-Application credentials. The user can store any number
// of (label, username, password) triples per Application; each Run binds
// to at most one of them via `RunRequest.credentialID`. Password bytes
// live in Keychain via `CredentialStore`; the SwiftData row only carries
// the label + username + parent-Application reference.
//
// V5's `@Model` types continue to live at file scope (the same convention
// V4 used before being frozen above). Production code references
// `Application`, `Credential`, etc. without a namespace.
//
// Migration from V4 is **lightweight**: `Credential` is a brand-new model;
// `Application` only gains a new `credentials` relationship (defaults to
// empty). Existing V4 rows decode cleanly with `credentials == []`.
enum HarnessSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            RunRecord.self,
            Application.self,
            Persona.self,
            Action.self,
            ActionChain.self,
            ActionChainStep.self,
            Credential.self
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

    /// V4: which kind of platform this run targeted. Optional with a default
    /// so V3→V4 lightweight migration adds the column to existing stores
    /// without a custom backfill — historical rows decode as
    /// `.iosSimulator` (V3 was iOS-only). New runs get the value from
    /// `RunRequest.platformKindRaw` at creation time.
    var platformKindRaw: String? = nil

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
        platformKindRaw: String? = nil,
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
        self.platformKindRaw = platformKindRaw
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
    /// Resolved platform kind. Reads `platformKindRaw` (V4 column) and
    /// defaults to iOS for legacy rows / nil values.
    var platformKind: PlatformKind { PlatformKind.from(rawValue: platformKindRaw) }
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

    /// V4: platform discriminator. Optional with `"ios_simulator"` default
    /// at the use site so V3→V4 lightweight migration leaves existing rows
    /// resolving to iOS — see `PlatformKind.from(rawValue:)`. New rows
    /// always set this explicitly.
    var platformKindRaw: String? = nil

    // MARK: iOS Simulator fields (interpreted only when platformKind == .iosSimulator)

    var projectPath: String
    var projectBookmark: Data?
    var scheme: String

    var defaultSimulatorUDID: String?
    var defaultSimulatorName: String?
    var defaultSimulatorRuntime: String?

    // MARK: macOS app fields (V4 — interpreted only when platformKind == .macosApp;
    // Phase 2 wires the rest of the macOS path).

    /// Path to a pre-built `.app` bundle (e.g. `/System/Applications/TextEdit.app`).
    /// Optional alternative to building from a project + scheme.
    var macAppBundlePath: String? = nil
    /// Security-scoped bookmark for the bundle path; same shape as
    /// `projectBookmark` but for the .app outside the app container.
    var macAppBundleBookmark: Data? = nil

    // MARK: Web app fields (V4 — interpreted only when platformKind == .web;
    // Phase 3 wires the embedded WebKit driver).

    /// Initial URL the agent loads on first step.
    var webStartURL: String? = nil
    /// CSS-pixel viewport dimensions for the embedded WebView. Defaults to
    /// 1280×1600 at the snapshot layer when nil.
    var webViewportWidthPt: Int? = nil
    var webViewportHeightPt: Int? = nil

    // MARK: Run defaults (platform-neutral)

    var defaultModelRaw: String
    var defaultModeRaw: String
    var defaultStepBudget: Int

    // MARK: V5 — credentials

    /// V5: zero or more stored credentials the user can pre-stage for runs
    /// against this Application. Cascade delete: removing the Application
    /// removes its credential rows. Password bytes don't live here — they
    /// sit in Keychain via `CredentialStore`. Defaults to `[]`; existing
    /// V4 rows lightweight-migrate to V5 with no credentials.
    @Relationship(deleteRule: .cascade) var credentials: [Credential] = []

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        archivedAt: Date? = nil,
        platformKindRaw: String? = PlatformKind.iosSimulator.rawValue,
        projectPath: String,
        projectBookmark: Data? = nil,
        scheme: String,
        defaultSimulatorUDID: String? = nil,
        defaultSimulatorName: String? = nil,
        defaultSimulatorRuntime: String? = nil,
        macAppBundlePath: String? = nil,
        macAppBundleBookmark: Data? = nil,
        webStartURL: String? = nil,
        webViewportWidthPt: Int? = nil,
        webViewportHeightPt: Int? = nil,
        defaultModelRaw: String = AgentModel.opus47.rawValue,
        defaultModeRaw: String = RunMode.stepByStep.rawValue,
        defaultStepBudget: Int = 40
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
        self.platformKindRaw = platformKindRaw
        self.projectPath = projectPath
        self.projectBookmark = projectBookmark
        self.scheme = scheme
        self.defaultSimulatorUDID = defaultSimulatorUDID
        self.defaultSimulatorName = defaultSimulatorName
        self.defaultSimulatorRuntime = defaultSimulatorRuntime
        self.macAppBundlePath = macAppBundlePath
        self.macAppBundleBookmark = macAppBundleBookmark
        self.webStartURL = webStartURL
        self.webViewportWidthPt = webViewportWidthPt
        self.webViewportHeightPt = webViewportHeightPt
        self.defaultModelRaw = defaultModelRaw
        self.defaultModeRaw = defaultModeRaw
        self.defaultStepBudget = defaultStepBudget
    }

    /// Resolved platform kind. Reads `platformKindRaw` and falls back to
    /// `.iosSimulator` for legacy rows / nil values.
    var platformKind: PlatformKind { PlatformKind.from(rawValue: platformKindRaw) }
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

/// V5 — one stored login per Application. Many credentials per Application
/// is supported (e.g. "free user" + "paid user" personas); each Run binds
/// to at most one via `RunRequest.credentialID`.
///
/// **Password bytes do not live in this model.** The SwiftData row only
/// carries identifying metadata (label, username) and a parent-Application
/// reference. The password sits in Keychain under
/// `service: "com.harness.credentials"`, `account: "<applicationID>:<credentialID>"`,
/// managed by `CredentialStore`. That separation keeps the on-disk
/// SwiftData store free of password bytes — even an unencrypted backup of
/// `history.store` carries no secret material.
@Model
final class Credential {

    @Attribute(.unique) var id: UUID

    /// Short user-facing label, e.g. "free user", "admin", "test-account-3".
    /// Must be unique-per-Application at the application layer (not enforced
    /// by SwiftData — the CRUD path checks).
    var label: String

    /// The username/email the agent will type into the login form when the
    /// run dispatches `fill_credential(field: "username")`.
    var username: String

    var createdAt: Date

    /// Backreference to the owning Application. Nullified at the DB level
    /// when the Application deletes (cascade deletes the Credential row),
    /// so this is `nil` only briefly during teardown.
    @Relationship(inverse: \Application.credentials) var application: Application?

    init(
        id: UUID = UUID(),
        label: String,
        username: String,
        createdAt: Date = Date(),
        application: Application? = nil
    ) {
        self.id = id
        self.label = label
        self.username = username
        self.createdAt = createdAt
        self.application = application
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
        [HarnessSchemaV1.self, HarnessSchemaV2.self, HarnessSchemaV3.self, HarnessSchemaV4.self, HarnessSchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [v1ToV2, v2ToV3, v3ToV4, v4ToV5]
    }

    static let v1ToV2 = MigrationStage.custom(
        fromVersion: HarnessSchemaV1.self,
        toVersion: HarnessSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            try backfillApplications(context: context)
        }
    )

    /// Lightweight: adds `RunRecord.legsJSON`, `tokensUsedCacheRead`,
    /// `tokensUsedCacheCreation` (all optional with nil defaults).
    /// SwiftData fills NULL on existing rows; nothing to backfill.
    static let v2ToV3 = MigrationStage.lightweight(
        fromVersion: HarnessSchemaV2.self,
        toVersion: HarnessSchemaV3.self
    )

    /// Lightweight: adds the platform discriminator on `Application`
    /// (`platformKindRaw`) plus the macOS / web optional fields, and
    /// `RunRecord.platformKindRaw`. All new columns are optional with
    /// `nil` defaults; `PlatformKind.from(rawValue:)` resolves nil to
    /// `.iosSimulator`, so historical rows behave exactly as before.
    /// Nothing to backfill — the resolution at read time is enough.
    static let v3ToV4 = MigrationStage.lightweight(
        fromVersion: HarnessSchemaV3.self,
        toVersion: HarnessSchemaV4.self
    )

    /// Lightweight: adds the new `Credential` entity and an optional
    /// `Application.credentials` cascade relationship (defaults to
    /// empty `[]`). Existing V4 stores reopen with no credentials staged
    /// against any Application; nothing to backfill. Password bytes are
    /// kept entirely out of the SwiftData store — see `CredentialStore`
    /// for the Keychain side.
    static let v4ToV5 = MigrationStage.lightweight(
        fromVersion: HarnessSchemaV4.self,
        toVersion: HarnessSchemaV5.self
    )

    /// Walk every `RunRecord` in the post-migration store, group by
    /// `(projectPath, scheme)`, and ensure one `Application` exists per
    /// tuple. Bind `runRecord.application` to the matching row. Idempotent —
    /// runs cleanly on a store that already has Applications.
    ///
    /// Reads through V2's nested model types (`HarnessSchemaV2.RunRecord` /
    /// `HarnessSchemaV2.Application`) because this stage finishes the V1→V2
    /// transition — the context is bound to V2's class identities here.
    /// V2→V3 is lightweight and runs after this with no custom code.
    static func backfillApplications(context: ModelContext) throws {
        let runs = try context.fetch(FetchDescriptor<HarnessSchemaV2.RunRecord>())
        guard !runs.isEmpty else { return }

        let existing = try context.fetch(FetchDescriptor<HarnessSchemaV2.Application>())
        var byKey: [String: HarnessSchemaV2.Application] = [:]
        for app in existing {
            byKey[Self.key(projectPath: app.projectPath, scheme: app.scheme)] = app
        }

        for run in runs {
            let key = Self.key(projectPath: run.projectPath, scheme: run.scheme)
            let app: HarnessSchemaV2.Application
            if let existingApp = byKey[key] {
                app = existingApp
            } else {
                app = HarnessSchemaV2.Application(
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
