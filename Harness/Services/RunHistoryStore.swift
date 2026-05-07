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

    // MARK: Credentials (V5)
    /// All credentials stored against `applicationID`, sorted by `createdAt`.
    /// Empty when the Application has none staged.
    func credentials(forApplication applicationID: UUID) async throws -> [CredentialSnapshot]
    /// Look up a single credential by id. Returns `nil` if not found or if
    /// its parent Application was deleted.
    func credential(id: UUID) async throws -> CredentialSnapshot?
    /// Insert or update a credential. The parent Application referenced by
    /// `snapshot.applicationID` must already exist in the store.
    func upsertCredential(_ snapshot: CredentialSnapshot) async throws
    /// Remove a single credential by id. Idempotent — no-op if absent. The
    /// caller is responsible for clearing the matching Keychain entry via
    /// `CredentialStore.deletePassword` (kept separate so the SwiftData
    /// row and the Keychain item can be reasoned about independently).
    func deleteCredential(id: UUID) async throws
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
    /// Cache-read tokens accumulated across the run (≈90% off input rate).
    /// `0` for runs that completed before this column landed.
    let tokensUsedCacheRead: Int
    /// Cache-creation tokens (≈1.25× input rate). Same backwards-compat
    /// note as cache-read.
    let tokensUsedCacheCreation: Int
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

    /// V4: which platform kind this run drove. `nil` for legacy V3 rows;
    /// `platformKind` resolves nil to `.iosSimulator`.
    let platformKindRaw: String?

    var platformKind: PlatformKind { PlatformKind.from(rawValue: platformKindRaw) }

    var verdict: Verdict? { verdictRaw.flatMap(Verdict.init(rawValue:)) }
    var runDirectoryURL: URL { URL(fileURLWithPath: runDirectoryPath) }

    /// Itemized API cost computed from the four token buckets at the
    /// model's published rate. Pure function — re-prices historical runs
    /// any time Anthropic changes rates.
    var cost: RunCost {
        Pricing.cost(
            modelRaw: modelRaw,
            inputTokens: tokensUsedInput,
            outputTokens: tokensUsedOutput,
            cacheReadTokens: tokensUsedCacheRead,
            cacheCreationTokens: tokensUsedCacheCreation
        )
    }

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
        tokensUsedCacheRead: Int = 0,
        tokensUsedCacheCreation: Int = 0,
        runDirectoryPath: String,
        applicationID: UUID? = nil,
        personaID: UUID? = nil,
        actionID: UUID? = nil,
        actionChainID: UUID? = nil,
        legsJSON: String? = nil,
        platformKindRaw: String? = nil
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
        self.tokensUsedCacheRead = tokensUsedCacheRead
        self.tokensUsedCacheCreation = tokensUsedCacheCreation
        self.runDirectoryPath = runDirectoryPath
        self.applicationID = applicationID
        self.personaID = personaID
        self.actionID = actionID
        self.actionChainID = actionChainID
        self.legsJSON = legsJSON
        self.platformKindRaw = platformKindRaw
    }
}

/// Sendable snapshot of a `Credential`. Mirrors the SwiftData `@Model`
/// minus the relationship reference (the `applicationID` carries the link
/// across the actor boundary). The password value is NEVER part of this
/// type — passwords live exclusively in Keychain via `CredentialStore`.
struct CredentialSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let applicationID: UUID
    var label: String
    var username: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        applicationID: UUID,
        label: String,
        username: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.applicationID = applicationID
        self.label = label
        self.username = username
        self.createdAt = createdAt
    }
}

extension CredentialSnapshot {
    /// Build a Sendable snapshot from a fetched `Credential` row. Fails if
    /// the parent Application reference is somehow nil — shouldn't happen
    /// in practice (the cascade rule deletes the credential when the
    /// Application goes away), but we surface it cleanly rather than
    /// crashing.
    init?(from row: Credential) {
        guard let appID = row.application?.id else { return nil }
        self.init(
            id: row.id,
            applicationID: appID,
            label: row.label,
            username: row.username,
            createdAt: row.createdAt
        )
    }
}

// MARK: - Errors

enum RunHistoryStoreError: Error, Sendable, LocalizedError {
    /// Tried to insert a credential whose `applicationID` doesn't resolve
    /// to a row in the store. The caller should ensure the Application is
    /// inserted before staging credentials against it.
    case applicationNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound(let id):
            return "No Application with id \(id) exists in the store."
        }
    }
}

// MARK: - Default actor implementation

@ModelActor
actor RunHistoryStore: RunHistoryStoring {

    nonisolated private static let logger = Logger(subsystem: "com.harness.app", category: "RunHistoryStore")

    /// Production factory — opens the default app-support store with
    /// pre-release reset-on-migration-failure semantics. Tests that want
    /// strict failure propagation use `at(url:resetOnMigrationFailure:)`.
    static func openDefault() throws -> RunHistoryStore {
        try HarnessPaths.ensureDirectory(HarnessPaths.appSupport)
        let url = HarnessPaths.appSupport.appendingPathComponent("history.store")
        let container = try makeContainer(url: url, resetOnMigrationFailure: true)
        return RunHistoryStore(modelContainer: container)
    }

    /// Test factory — opens the store at `url` and surfaces migration
    /// failures unless `resetOnMigrationFailure` is true. Replaces the
    /// pre-`@ModelActor` `init(url:resetOnMigrationFailure:)`.
    static func at(url: URL, resetOnMigrationFailure: Bool = false) throws -> RunHistoryStore {
        let container = try makeContainer(url: url, resetOnMigrationFailure: resetOnMigrationFailure)
        return RunHistoryStore(modelContainer: container)
    }

    /// In-memory variant for unit tests. Same schema + migration plan as
    /// the on-disk store; no persistence between processes.
    static func inMemory() throws -> RunHistoryStore {
        let schema = Schema(versionedSchema: HarnessSchemaV5.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: HarnessMigrationPlan.self,
            configurations: [configuration]
        )
        return RunHistoryStore(modelContainer: container)
    }

    /// Pre-release recovery policy (`resetOnMigrationFailure == true`):
    /// if SwiftData can't migrate the on-disk store (typically after a
    /// model change without a paired `MigrationStage`), we delete the
    /// SQLite file + its WAL/SHM siblings and start over. Data loss is
    /// acceptable while we're iterating; the alternative — silently
    /// falling through to an in-memory store — was the bug that prompted
    /// this rewrite (Applications / Personas / Actions appeared to
    /// "disappear" on relaunch). When we get closer to ship we can
    /// graduate this to an archive-and-warn flow.
    nonisolated private static func makeContainer(
        url: URL,
        resetOnMigrationFailure: Bool
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HarnessSchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: HarnessMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            guard resetOnMigrationFailure else { throw error }
            logger.error("Couldn't open on-disk history store; deleting and starting fresh: \(error.localizedDescription, privacy: .public)")
            deleteStoreFiles(at: url)
            // One retry against the cleaned slot. If this still fails it's
            // a real problem (permissions, disk full) — let it propagate.
            return try ModelContainer(
                for: schema,
                migrationPlan: HarnessMigrationPlan.self,
                configurations: [configuration]
            )
        }
    }

    /// Remove the SQLite store file and its WAL/SHM siblings so the next
    /// `ModelContainer` open starts clean.
    nonisolated private static func deleteStoreFiles(at url: URL) {
        let fm = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
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
            row.tokensUsedCacheRead = snapshot.tokensUsedCacheRead
            row.tokensUsedCacheCreation = snapshot.tokensUsedCacheCreation
            row.legsJSON = snapshot.legsJSON
            row.platformKindRaw = snapshot.platformKindRaw
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
                platformKindRaw: snapshot.platformKindRaw,
                application: app,
                persona_: persona,
                action: action,
                actionChain: chain
            )
            row.legsJSON = snapshot.legsJSON
            row.tokensUsedCacheRead = snapshot.tokensUsedCacheRead
            row.tokensUsedCacheCreation = snapshot.tokensUsedCacheCreation
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
        row.tokensUsedCacheRead = outcome.tokensUsedCacheRead
        row.tokensUsedCacheCreation = outcome.tokensUsedCacheCreation
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
            row.platformKindRaw = snapshot.platformKindRaw
            row.projectPath = snapshot.projectPath
            row.projectBookmark = snapshot.projectBookmark
            row.scheme = snapshot.scheme
            row.defaultSimulatorUDID = snapshot.defaultSimulatorUDID
            row.defaultSimulatorName = snapshot.defaultSimulatorName
            row.defaultSimulatorRuntime = snapshot.defaultSimulatorRuntime
            row.macAppBundlePath = snapshot.macAppBundlePath
            row.macAppBundleBookmark = snapshot.macAppBundleBookmark
            row.webStartURL = snapshot.webStartURL
            row.webViewportWidthPt = snapshot.webViewportWidthPt
            row.webViewportHeightPt = snapshot.webViewportHeightPt
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
                platformKindRaw: snapshot.platformKindRaw,
                projectPath: snapshot.projectPath,
                projectBookmark: snapshot.projectBookmark,
                scheme: snapshot.scheme,
                defaultSimulatorUDID: snapshot.defaultSimulatorUDID,
                defaultSimulatorName: snapshot.defaultSimulatorName,
                defaultSimulatorRuntime: snapshot.defaultSimulatorRuntime,
                macAppBundlePath: snapshot.macAppBundlePath,
                macAppBundleBookmark: snapshot.macAppBundleBookmark,
                webStartURL: snapshot.webStartURL,
                webViewportWidthPt: snapshot.webViewportWidthPt,
                webViewportHeightPt: snapshot.webViewportHeightPt,
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

    // MARK: Credentials (V5)

    func credentials(forApplication applicationID: UUID) async throws -> [CredentialSnapshot] {
        let descriptor = FetchDescriptor<Credential>(
            predicate: #Predicate { $0.application?.id == applicationID },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).compactMap { CredentialSnapshot(from: $0) }
    }

    func credential(id: UUID) async throws -> CredentialSnapshot? {
        try fetchCredential(id: id).flatMap { CredentialSnapshot(from: $0) }
    }

    func upsertCredential(_ snapshot: CredentialSnapshot) async throws {
        let appID = snapshot.applicationID
        guard let app = try fetchApplication(id: appID) else {
            throw RunHistoryStoreError.applicationNotFound(appID)
        }
        if let existing = try fetchCredential(id: snapshot.id) {
            existing.label = snapshot.label
            existing.username = snapshot.username
            // `application` is the inverse of `Application.credentials`;
            // an Application change isn't supported here (caller would
            // delete + recreate). createdAt is immutable.
        } else {
            let row = Credential(
                id: snapshot.id,
                label: snapshot.label,
                username: snapshot.username,
                createdAt: snapshot.createdAt,
                application: app
            )
            modelContext.insert(row)
        }
        try saveOrLog("upsert(credential:)")
    }

    func deleteCredential(id: UUID) async throws {
        if let row = try fetchCredential(id: id) {
            modelContext.delete(row)
            try saveOrLog("deleteCredential")
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

    private func fetchCredential(id: UUID) throws -> Credential? {
        let d = FetchDescriptor<Credential>(predicate: #Predicate { $0.id == id })
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
            tokensUsedCacheRead: row.tokensUsedCacheRead ?? 0,
            tokensUsedCacheCreation: row.tokensUsedCacheCreation ?? 0,
            runDirectoryPath: row.runDirectoryPath,
            applicationID: row.applicationLookupID,
            personaID: row.personaLookupID,
            actionID: row.actionLookupID,
            actionChainID: row.actionChainLookupID,
            legsJSON: row.legsJSON,
            platformKindRaw: row.platformKindRaw
        )
    }

    nonisolated private static func snapshot(of row: Application) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: row.id,
            name: row.name,
            createdAt: row.createdAt,
            lastUsedAt: row.lastUsedAt,
            archivedAt: row.archivedAt,
            platformKindRaw: row.platformKindRaw,
            projectPath: row.projectPath,
            projectBookmark: row.projectBookmark,
            scheme: row.scheme,
            defaultSimulatorUDID: row.defaultSimulatorUDID,
            defaultSimulatorName: row.defaultSimulatorName,
            defaultSimulatorRuntime: row.defaultSimulatorRuntime,
            macAppBundlePath: row.macAppBundlePath,
            macAppBundleBookmark: row.macAppBundleBookmark,
            webStartURL: row.webStartURL,
            webViewportWidthPt: row.webViewportWidthPt,
            webViewportHeightPt: row.webViewportHeightPt,
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
            legsJSON: legsJSON,
            platformKindRaw: request.platformKindRaw
        )
    }
}
