//
//  RunHistoryStore.swift
//  Harness
//
//  SwiftData container for the Run history index plus the small library
//  entities (Applications / Personas / Actions / Action Chains) that the
//  workspace rework introduces. Per `standards/02-swiftdata.md`, SwiftData
//  is the queryable index; per-step events still live in JSONL on disk.
//
//  The `@Model` classes themselves and the schema versions live in
//  `Harness/Services/HarnessSchema.swift`. This file owns the
//  `RunHistoryStoring` actor, the Sendable snapshot bridge, and the CRUD
//  surface.
//

import Foundation
import SwiftData
import os

// MARK: - Protocol

protocol RunHistoryStoring: Sendable {

    // MARK: Run records
    /// Insert or update a run record (Skeleton-First pattern from `02-swiftdata.md §2`).
    func upsert(_ record: RunRecordSnapshot) async throws
    func markCompleted(id: UUID, outcome: RunOutcome) async throws
    /// Update the leg-record blob mid-flight. Called by `ChainExecutor`
    /// after each leg ends so the History view sees verdicts roll in
    /// without waiting for the whole chain.
    func updateLegsJSON(id: UUID, legsJSON: String?) async throws
    func fetchRecent(limit: Int) async throws -> [RunRecordSnapshot]
    func fetch(id: UUID) async throws -> RunRecordSnapshot?
    func delete(id: UUID) async throws

    // MARK: Applications
    func applications(includeArchived: Bool) async throws -> [ApplicationSnapshot]
    func application(id: UUID) async throws -> ApplicationSnapshot?
    func upsert(_ snapshot: ApplicationSnapshot) async throws
    func archive(applicationID: UUID) async throws
    func deleteApplication(id: UUID) async throws

    // MARK: Personas
    func personas(includeArchived: Bool) async throws -> [PersonaSnapshot]
    func persona(id: UUID) async throws -> PersonaSnapshot?
    func upsert(_ snapshot: PersonaSnapshot) async throws
    func archive(personaID: UUID) async throws
    func deletePersona(id: UUID) async throws
    /// Idempotent: inserts personas from `docs/PROMPTS/persona-defaults.md` whose
    /// `name` doesn't already exist as a built-in.
    func seedBuiltInPersonasIfNeeded(from markdown: String) async throws

    // MARK: Actions
    func actions(includeArchived: Bool) async throws -> [ActionSnapshot]
    func action(id: UUID) async throws -> ActionSnapshot?
    func upsert(_ snapshot: ActionSnapshot) async throws
    func archive(actionID: UUID) async throws
    func deleteAction(id: UUID) async throws

    // MARK: Action chains
    func actionChains(includeArchived: Bool) async throws -> [ActionChainSnapshot]
    func actionChain(id: UUID) async throws -> ActionChainSnapshot?
    func upsert(_ snapshot: ActionChainSnapshot) async throws
    func archive(actionChainID: UUID) async throws
    func deleteActionChain(id: UUID) async throws
}

// Default-argument shims so callers can write `applications()`.
extension RunHistoryStoring {
    func applications() async throws -> [ApplicationSnapshot] {
        try await applications(includeArchived: false)
    }
    func personas() async throws -> [PersonaSnapshot] {
        try await personas(includeArchived: false)
    }
    func actions() async throws -> [ActionSnapshot] {
        try await actions(includeArchived: false)
    }
    func actionChains() async throws -> [ActionChainSnapshot] {
        try await actionChains(includeArchived: false)
    }
}

// MARK: - Snapshots

/// Sendable snapshot of a `RunRecord`. Used to ferry data across the actor
/// boundary; the `@Model` itself isn't `Sendable`.
struct RunRecordSnapshot: Sendable, Hashable {
    let id: UUID
    let name: String?
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

    /// Optional refs to the library entities the run was launched from.
    /// `nil` means the row was created before the workspace rework, or its
    /// referent was deleted (denormalized fields above still hold the
    /// durable snapshot).
    let applicationID: UUID?
    let personaID: UUID?
    let actionID: UUID?
    let actionChainID: UUID?

    /// JSON-encoded `[LegRecord]` for chain runs. `nil` for single-action
    /// runs (the executor never writes a chain header for those). Phase E
    /// added this column via additive lightweight migration on V2.
    let legsJSON: String?

    var verdict: Verdict? { verdictRaw.flatMap(Verdict.init(rawValue:)) }
    var runDirectoryURL: URL { URL(fileURLWithPath: runDirectoryPath) }

    /// Decoded leg records, or empty when the run wasn't a chain (or the
    /// blob couldn't decode). Sorted by `index` ascending.
    var legs: [LegRecord] {
        guard let blob = legsJSON, !blob.isEmpty else { return [] }
        let data = Data(blob.utf8)
        guard let decoded = try? JSONDecoder().decode([LegRecord].self, from: data) else { return [] }
        return decoded.sorted(by: { $0.index < $1.index })
    }

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
        applicationID: UUID? = nil,
        personaID: UUID? = nil,
        actionID: UUID? = nil,
        actionChainID: UUID? = nil,
        legsJSON: String? = nil
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
        self.applicationID = applicationID
        self.personaID = personaID
        self.actionID = actionID
        self.actionChainID = actionChainID
        self.legsJSON = legsJSON
    }
}

// MARK: - Default actor implementation

actor RunHistoryStore: RunHistoryStoring {

    private static let logger = Logger(subsystem: "com.harness.app", category: "RunHistoryStore")

    private let modelContainer: ModelContainer
    private var modelContext: ModelContext

    /// Production initializer using the default app-support store.
    /// In-memory variant exists for tests; see `inMemory()`.
    init(url: URL? = nil) throws {
        let schema = Schema(versionedSchema: HarnessSchemaV2.self)
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
        let schema = Schema(versionedSchema: HarnessSchemaV2.self)
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

    // MARK: Run records — upsert / mark completed

    func upsert(_ snapshot: RunRecordSnapshot) async throws {
        let id = snapshot.id
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        let existing = try modelContext.fetch(descriptor).first

        // Resolve optional refs once — they're shared between insert and update.
        let app = try snapshot.applicationID.flatMap { try fetchApplication(id: $0) }
        let persona = try snapshot.personaID.flatMap { try fetchPersona(id: $0) }
        let action = try snapshot.actionID.flatMap { try fetchAction(id: $0) }
        let chain = try snapshot.actionChainID.flatMap { try fetchActionChain(id: $0) }

        if let row = existing {
            row.name = snapshot.name
            row.completedAt = snapshot.completedAt
            row.verdictRaw = snapshot.verdictRaw
            row.summary = snapshot.summary
            row.stepCount = snapshot.stepCount
            row.frictionCount = snapshot.frictionCount
            row.wouldRealUserSucceed = snapshot.wouldRealUserSucceed
            row.tokensUsedInput = snapshot.tokensUsedInput
            row.tokensUsedOutput = snapshot.tokensUsedOutput
            row.legsJSON = snapshot.legsJSON
            if let app { row.application = app; row.applicationLookupID = app.id }
            if let persona { row.persona_ = persona; row.personaLookupID = persona.id }
            if let action { row.action = action; row.actionLookupID = action.id }
            if let chain { row.actionChain = chain; row.actionChainLookupID = chain.id }
        } else {
            let row = RunRecord(
                id: snapshot.id,
                name: snapshot.name,
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
                runDirectoryPath: snapshot.runDirectoryPath,
                application: app,
                persona_: persona,
                action: action,
                actionChain: chain
            )
            row.legsJSON = snapshot.legsJSON
            modelContext.insert(row)
        }

        do {
            try modelContext.save()
        } catch {
            Self.logger.error("upsert save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func updateLegsJSON(id: UUID, legsJSON: String?) async throws {
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.legsJSON = legsJSON
        try saveOrLog("updateLegsJSON")
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

    // MARK: Run records — fetch

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

    // MARK: Applications

    func applications(includeArchived: Bool) async throws -> [ApplicationSnapshot] {
        let descriptor = FetchDescriptor<Application>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        let rows = try modelContext.fetch(descriptor)
        let filtered = includeArchived ? rows : rows.filter { $0.archivedAt == nil }
        return filtered.map(Self.snapshot(of:))
    }

    func application(id: UUID) async throws -> ApplicationSnapshot? {
        try fetchApplication(id: id).map(Self.snapshot(of:))
    }

    func upsert(_ snapshot: ApplicationSnapshot) async throws {
        if let row = try fetchApplication(id: snapshot.id) {
            row.name = snapshot.name
            row.lastUsedAt = snapshot.lastUsedAt
            row.archivedAt = snapshot.archivedAt
            row.projectPath = snapshot.projectPath
            row.projectBookmark = snapshot.projectBookmark
            row.scheme = snapshot.scheme
            row.defaultSimulatorUDID = snapshot.defaultSimulatorUDID
            row.defaultSimulatorName = snapshot.defaultSimulatorName
            row.defaultSimulatorRuntime = snapshot.defaultSimulatorRuntime
            row.defaultModelRaw = snapshot.defaultModelRaw
            row.defaultModeRaw = snapshot.defaultModeRaw
            row.defaultStepBudget = snapshot.defaultStepBudget
        } else {
            let row = Application(
                id: snapshot.id,
                name: snapshot.name,
                createdAt: snapshot.createdAt,
                lastUsedAt: snapshot.lastUsedAt,
                archivedAt: snapshot.archivedAt,
                projectPath: snapshot.projectPath,
                projectBookmark: snapshot.projectBookmark,
                scheme: snapshot.scheme,
                defaultSimulatorUDID: snapshot.defaultSimulatorUDID,
                defaultSimulatorName: snapshot.defaultSimulatorName,
                defaultSimulatorRuntime: snapshot.defaultSimulatorRuntime,
                defaultModelRaw: snapshot.defaultModelRaw,
                defaultModeRaw: snapshot.defaultModeRaw,
                defaultStepBudget: snapshot.defaultStepBudget
            )
            modelContext.insert(row)
        }
        try saveOrLog("upsert(application:)")
    }

    func archive(applicationID: UUID) async throws {
        guard let row = try fetchApplication(id: applicationID) else { return }
        if row.archivedAt == nil {
            row.archivedAt = Date()
            try saveOrLog("archive(applicationID:)")
        }
    }

    func deleteApplication(id: UUID) async throws {
        if let row = try fetchApplication(id: id) {
            // Manually nullify on bound RunRecords. SwiftData's relationship
            // cascade clears the relationship object but doesn't update our
            // mirrored lookup-ID column; do it explicitly so snapshots stay
            // accurate.
            let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.applicationLookupID == id })
            for r in try modelContext.fetch(descriptor) {
                r.application = nil
                r.applicationLookupID = nil
            }
            modelContext.delete(row)
            try saveOrLog("deleteApplication")
        }
    }

    // MARK: Personas

    func personas(includeArchived: Bool) async throws -> [PersonaSnapshot] {
        let descriptor = FetchDescriptor<Persona>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        let rows = try modelContext.fetch(descriptor)
        let filtered = includeArchived ? rows : rows.filter { $0.archivedAt == nil }
        return filtered.map(Self.snapshot(of:))
    }

    func persona(id: UUID) async throws -> PersonaSnapshot? {
        try fetchPersona(id: id).map(Self.snapshot(of:))
    }

    func upsert(_ snapshot: PersonaSnapshot) async throws {
        if let row = try fetchPersona(id: snapshot.id) {
            row.name = snapshot.name
            row.blurb = snapshot.blurb
            row.promptText = snapshot.promptText
            row.isBuiltIn = snapshot.isBuiltIn
            row.lastUsedAt = snapshot.lastUsedAt
            row.archivedAt = snapshot.archivedAt
        } else {
            let row = Persona(
                id: snapshot.id,
                name: snapshot.name,
                blurb: snapshot.blurb,
                promptText: snapshot.promptText,
                isBuiltIn: snapshot.isBuiltIn,
                createdAt: snapshot.createdAt,
                lastUsedAt: snapshot.lastUsedAt,
                archivedAt: snapshot.archivedAt
            )
            modelContext.insert(row)
        }
        try saveOrLog("upsert(persona:)")
    }

    func archive(personaID: UUID) async throws {
        guard let row = try fetchPersona(id: personaID) else { return }
        if row.archivedAt == nil {
            row.archivedAt = Date()
            try saveOrLog("archive(personaID:)")
        }
    }

    func deletePersona(id: UUID) async throws {
        if let row = try fetchPersona(id: id) {
            let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.personaLookupID == id })
            for r in try modelContext.fetch(descriptor) {
                r.persona_ = nil
                r.personaLookupID = nil
            }
            modelContext.delete(row)
            try saveOrLog("deletePersona")
        }
    }

    func seedBuiltInPersonasIfNeeded(from markdown: String) async throws {
        let sections = PromptLibrary.parseMarkdownSections(markdown)
        if sections.isEmpty { return }

        // Index existing built-ins by name so re-runs are no-ops.
        let descriptor = FetchDescriptor<Persona>()
        let existing = try modelContext.fetch(descriptor)
        var existingByName: [String: Persona] = [:]
        for row in existing where row.isBuiltIn {
            existingByName[row.name] = row
        }

        var inserted = 0
        for section in sections {
            if existingByName[section.title] != nil { continue }
            let blurb = Self.firstSentence(of: section.body)
            let row = Persona(
                name: section.title,
                blurb: blurb,
                promptText: section.body,
                isBuiltIn: true
            )
            modelContext.insert(row)
            inserted += 1
        }
        if inserted > 0 {
            try saveOrLog("seedBuiltInPersonasIfNeeded(inserted: \(inserted))")
        }
    }

    // MARK: Actions

    func actions(includeArchived: Bool) async throws -> [ActionSnapshot] {
        let descriptor = FetchDescriptor<Action>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        let rows = try modelContext.fetch(descriptor)
        let filtered = includeArchived ? rows : rows.filter { $0.archivedAt == nil }
        return filtered.map(Self.snapshot(of:))
    }

    func action(id: UUID) async throws -> ActionSnapshot? {
        try fetchAction(id: id).map(Self.snapshot(of:))
    }

    func upsert(_ snapshot: ActionSnapshot) async throws {
        if let row = try fetchAction(id: snapshot.id) {
            row.name = snapshot.name
            row.promptText = snapshot.promptText
            row.notes = snapshot.notes
            row.lastUsedAt = snapshot.lastUsedAt
            row.archivedAt = snapshot.archivedAt
        } else {
            let row = Action(
                id: snapshot.id,
                name: snapshot.name,
                promptText: snapshot.promptText,
                notes: snapshot.notes,
                createdAt: snapshot.createdAt,
                lastUsedAt: snapshot.lastUsedAt,
                archivedAt: snapshot.archivedAt
            )
            modelContext.insert(row)
        }
        try saveOrLog("upsert(action:)")
    }

    func archive(actionID: UUID) async throws {
        guard let row = try fetchAction(id: actionID) else { return }
        if row.archivedAt == nil {
            row.archivedAt = Date()
            try saveOrLog("archive(actionID:)")
        }
    }

    func deleteAction(id: UUID) async throws {
        if let row = try fetchAction(id: id) {
            // Clear the action ref on any chain step pointing here.
            let stepsDescriptor = FetchDescriptor<ActionChainStep>()
            for step in try modelContext.fetch(stepsDescriptor) where step.action?.id == id {
                step.action = nil
            }
            // And on any RunRecords that ran a single-action variant of this Action.
            let runDescriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.actionLookupID == id })
            for r in try modelContext.fetch(runDescriptor) {
                r.action = nil
                r.actionLookupID = nil
            }
            modelContext.delete(row)
            try saveOrLog("deleteAction")
        }
    }

    // MARK: Action chains

    func actionChains(includeArchived: Bool) async throws -> [ActionChainSnapshot] {
        let descriptor = FetchDescriptor<ActionChain>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        let rows = try modelContext.fetch(descriptor)
        let filtered = includeArchived ? rows : rows.filter { $0.archivedAt == nil }
        return filtered.map(Self.snapshot(of:))
    }

    func actionChain(id: UUID) async throws -> ActionChainSnapshot? {
        try fetchActionChain(id: id).map(Self.snapshot(of:))
    }

    func upsert(_ snapshot: ActionChainSnapshot) async throws {
        let row: ActionChain
        if let existing = try fetchActionChain(id: snapshot.id) {
            row = existing
            row.name = snapshot.name
            row.notes = snapshot.notes
            row.lastUsedAt = snapshot.lastUsedAt
            row.archivedAt = snapshot.archivedAt
        } else {
            row = ActionChain(
                id: snapshot.id,
                name: snapshot.name,
                notes: snapshot.notes,
                createdAt: snapshot.createdAt,
                lastUsedAt: snapshot.lastUsedAt,
                archivedAt: snapshot.archivedAt,
                steps: []
            )
            modelContext.insert(row)
        }

        // Reconcile steps: drop existing, insert in snapshot order.
        for old in row.steps {
            modelContext.delete(old)
        }
        var rebuilt: [ActionChainStep] = []
        for step in snapshot.steps.sorted(by: { $0.index < $1.index }) {
            let action = try step.actionID.flatMap { try fetchAction(id: $0) }
            let stepRow = ActionChainStep(
                id: step.id,
                index: step.index,
                action: action,
                preservesState: step.preservesState
            )
            modelContext.insert(stepRow)
            rebuilt.append(stepRow)
        }
        row.steps = rebuilt

        try saveOrLog("upsert(actionChain:)")
    }

    func archive(actionChainID: UUID) async throws {
        guard let row = try fetchActionChain(id: actionChainID) else { return }
        if row.archivedAt == nil {
            row.archivedAt = Date()
            try saveOrLog("archive(actionChainID:)")
        }
    }

    func deleteActionChain(id: UUID) async throws {
        if let row = try fetchActionChain(id: id) {
            let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.actionChainLookupID == id })
            for r in try modelContext.fetch(descriptor) {
                r.actionChain = nil
                r.actionChainLookupID = nil
            }
            modelContext.delete(row)
            try saveOrLog("deleteActionChain")
        }
    }

    // MARK: Internal fetch helpers (actor-isolated; @Model is not Sendable)

    private func fetchApplication(id: UUID) throws -> Application? {
        let d = FetchDescriptor<Application>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(d).first
    }

    private func fetchPersona(id: UUID) throws -> Persona? {
        let d = FetchDescriptor<Persona>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(d).first
    }

    private func fetchAction(id: UUID) throws -> Action? {
        let d = FetchDescriptor<Action>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(d).first
    }

    private func fetchActionChain(id: UUID) throws -> ActionChain? {
        let d = FetchDescriptor<ActionChain>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(d).first
    }

    private func saveOrLog(_ operation: String) throws {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("\(operation, privacy: .public) save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: Snapshot helpers

    nonisolated private static func snapshot(of row: RunRecord) -> RunRecordSnapshot {
        RunRecordSnapshot(
            id: row.id,
            name: row.name,
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
            runDirectoryPath: row.runDirectoryPath,
            applicationID: row.applicationLookupID,
            personaID: row.personaLookupID,
            actionID: row.actionLookupID,
            actionChainID: row.actionChainLookupID,
            legsJSON: row.legsJSON
        )
    }

    nonisolated private static func snapshot(of row: Application) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: row.id,
            name: row.name,
            createdAt: row.createdAt,
            lastUsedAt: row.lastUsedAt,
            archivedAt: row.archivedAt,
            projectPath: row.projectPath,
            projectBookmark: row.projectBookmark,
            scheme: row.scheme,
            defaultSimulatorUDID: row.defaultSimulatorUDID,
            defaultSimulatorName: row.defaultSimulatorName,
            defaultSimulatorRuntime: row.defaultSimulatorRuntime,
            defaultModelRaw: row.defaultModelRaw,
            defaultModeRaw: row.defaultModeRaw,
            defaultStepBudget: row.defaultStepBudget
        )
    }

    nonisolated private static func snapshot(of row: Persona) -> PersonaSnapshot {
        PersonaSnapshot(
            id: row.id,
            name: row.name,
            blurb: row.blurb,
            promptText: row.promptText,
            isBuiltIn: row.isBuiltIn,
            createdAt: row.createdAt,
            lastUsedAt: row.lastUsedAt,
            archivedAt: row.archivedAt
        )
    }

    nonisolated private static func snapshot(of row: Action) -> ActionSnapshot {
        ActionSnapshot(
            id: row.id,
            name: row.name,
            promptText: row.promptText,
            notes: row.notes,
            createdAt: row.createdAt,
            lastUsedAt: row.lastUsedAt,
            archivedAt: row.archivedAt
        )
    }

    nonisolated private static func snapshot(of row: ActionChain) -> ActionChainSnapshot {
        let stepSnaps = row.steps
            .sorted(by: { $0.index < $1.index })
            .map { step in
                ActionChainStepSnapshot(
                    id: step.id,
                    index: step.index,
                    actionID: step.action?.id,
                    preservesState: step.preservesState
                )
            }
        return ActionChainSnapshot(
            id: row.id,
            name: row.name,
            notes: row.notes,
            createdAt: row.createdAt,
            lastUsedAt: row.lastUsedAt,
            archivedAt: row.archivedAt,
            steps: stepSnaps
        )
    }

    // MARK: Markdown helpers
    //
    // The `## section` parser lives on `PromptLibrary` so any caller can
    // reuse it without going through this actor — see
    // `PromptLibrary.parseMarkdownSections(_:)`. The seeder above invokes
    // it directly. Only the persona-specific blurb extraction stays here,
    // since it's an implementation detail of the seed pipeline.

    nonisolated private static func firstSentence(of body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = trimmed.firstIndex(of: ".") {
            let head = trimmed[..<dot]
            return String(head).trimmingCharacters(in: .whitespaces) + "."
        }
        return trimmed
    }
}

// MARK: - Convenience builder

extension RunRecordSnapshot {
    /// Build a "skeleton" snapshot from a freshly-started request — outcome
    /// fields default to "still running." After Phase E this also lifts the
    /// run name + library refs (Application/Persona/Action/ActionChain) into
    /// the snapshot, and seeds the `legsJSON` blob for chain runs so a
    /// reload-mid-flight still shows the leg structure in the History view.
    static func skeleton(from request: RunRequest) -> RunRecordSnapshot {
        let runDir = HarnessPaths.runDir(for: request.id).path
        let resolvedActionID: UUID?
        let resolvedChainID: UUID?
        let legsJSON: String?
        switch request.payload {
        case .singleAction(let actionID, _):
            resolvedActionID = actionID
            resolvedChainID = nil
            legsJSON = nil
        case .chain(let chainID, let legs):
            resolvedActionID = nil
            resolvedChainID = chainID
            // Seed an in-progress LegRecord per leg with verdictRaw=nil.
            let initial: [LegRecord] = legs.map {
                LegRecord(
                    id: $0.id,
                    index: $0.index,
                    actionName: $0.actionName,
                    goal: $0.goal,
                    preservesState: $0.preservesState,
                    verdictRaw: nil,
                    summary: nil
                )
            }
            legsJSON = (try? JSONEncoder().encode(initial))
                .flatMap { String(data: $0, encoding: .utf8) }
        case .ad_hoc:
            resolvedActionID = nil
            resolvedChainID = nil
            legsJSON = nil
        }
        return RunRecordSnapshot(
            id: request.id,
            name: request.name.isEmpty ? nil : request.name,
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
            runDirectoryPath: runDir,
            applicationID: request.applicationID,
            personaID: request.personaID,
            actionID: resolvedActionID,
            actionChainID: resolvedChainID,
            legsJSON: legsJSON
        )
    }
}
