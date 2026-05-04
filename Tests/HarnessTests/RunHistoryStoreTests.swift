//
//  RunHistoryStoreTests.swift
//  HarnessTests
//
//  In-memory SwiftData container roundtrips. Verifies skeleton-first insert,
//  mark-completed update, recents fetch, project-recents touch.
//

import Testing
import Foundation
@testable import Harness

@Suite("RunHistoryStore")
struct RunHistoryStoreTests {

    @Test("Skeleton insert + markCompleted updates the row in place")
    func skeletonThenComplete() async throws {
        let store = try RunHistoryStore.inMemory()

        let request = Self.makeRequest()
        let skeleton = RunRecordSnapshot.skeleton(from: request)
        try await store.upsert(skeleton)

        let pre = try await store.fetch(id: request.id)
        #expect(pre?.verdictRaw == nil)
        #expect(pre?.completedAt == nil)
        #expect(pre?.stepCount == 0)

        let outcome = RunOutcome(
            verdict: .success,
            summary: "Did it.",
            frictionCount: 2,
            wouldRealUserSucceed: true,
            stepCount: 9,
            tokensUsedInput: 12_000,
            tokensUsedOutput: 1_300,
            completedAt: Date()
        )
        try await store.markCompleted(id: request.id, outcome: outcome)

        let post = try await store.fetch(id: request.id)
        #expect(post?.verdict == .success)
        #expect(post?.summary == "Did it.")
        #expect(post?.stepCount == 9)
        #expect(post?.frictionCount == 2)
        #expect(post?.wouldRealUserSucceed == true)
        #expect(post?.tokensUsedInput == 12_000)
        #expect(post?.tokensUsedOutput == 1_300)
        #expect(post?.completedAt != nil)
    }

    @Test("fetchRecent returns newest-first up to limit")
    func recentOrdering() async throws {
        let store = try RunHistoryStore.inMemory()

        // Build 3 snapshots with distinct createdAt times.
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<3 {
            var snap = RunRecordSnapshot.skeleton(from: Self.makeRequest())
            // Tweak createdAt so we can verify ordering.
            snap = RunRecordSnapshot(
                id: snap.id,
                createdAt: base.addingTimeInterval(TimeInterval(i * 60)),
                completedAt: snap.completedAt,
                projectPath: snap.projectPath,
                scheme: snap.scheme,
                displayName: snap.displayName,
                simulatorUDID: snap.simulatorUDID,
                simulatorName: snap.simulatorName,
                simulatorRuntime: snap.simulatorRuntime,
                goal: "goal-\(i)",
                persona: snap.persona,
                modelRaw: snap.modelRaw,
                modeRaw: snap.modeRaw,
                verdictRaw: snap.verdictRaw,
                summary: snap.summary,
                stepCount: snap.stepCount,
                frictionCount: snap.frictionCount,
                wouldRealUserSucceed: snap.wouldRealUserSucceed,
                tokensUsedInput: snap.tokensUsedInput,
                tokensUsedOutput: snap.tokensUsedOutput,
                runDirectoryPath: snap.runDirectoryPath
            )
            try await store.upsert(snap)
        }

        let recents = try await store.fetchRecent(limit: 10)
        #expect(recents.count == 3)
        #expect(recents.first?.goal == "goal-2")
        #expect(recents.last?.goal == "goal-0")

        let limited = try await store.fetchRecent(limit: 1)
        #expect(limited.count == 1)
        #expect(limited.first?.goal == "goal-2")
    }

    @Test("Application upsert + archive + delete round-trip")
    func applicationsCRUD() async throws {
        let store = try RunHistoryStore.inMemory()

        let now = Date()
        let appA = ApplicationSnapshot(
            id: UUID(),
            name: "A",
            createdAt: now,
            lastUsedAt: now,
            archivedAt: nil,
            projectPath: "/tmp/A.xcodeproj",
            projectBookmark: nil,
            scheme: "ASchema",
            defaultSimulatorUDID: nil,
            defaultSimulatorName: nil,
            defaultSimulatorRuntime: nil,
            defaultModelRaw: AgentModel.opus47.rawValue,
            defaultModeRaw: RunMode.stepByStep.rawValue,
            defaultStepBudget: 40
        )
        try await store.upsert(appA)

        let appB = ApplicationSnapshot(
            id: UUID(),
            name: "B",
            createdAt: now.addingTimeInterval(60),
            lastUsedAt: now.addingTimeInterval(60),
            archivedAt: nil,
            projectPath: "/tmp/B.xcodeproj",
            projectBookmark: nil,
            scheme: "BSchema",
            defaultSimulatorUDID: "UDID-B",
            defaultSimulatorName: "iPhone B",
            defaultSimulatorRuntime: "iOS 18.4",
            defaultModelRaw: AgentModel.opus47.rawValue,
            defaultModeRaw: RunMode.stepByStep.rawValue,
            defaultStepBudget: 40
        )
        try await store.upsert(appB)

        // Bump A's lastUsedAt forward and rename — should reorder.
        let appARenamed = ApplicationSnapshot(
            id: appA.id,
            name: "A renamed",
            createdAt: appA.createdAt,
            lastUsedAt: now.addingTimeInterval(120),
            archivedAt: nil,
            projectPath: appA.projectPath,
            projectBookmark: nil,
            scheme: appA.scheme,
            defaultSimulatorUDID: "UDID-XYZ",
            defaultSimulatorName: "iPhone XYZ",
            defaultSimulatorRuntime: "iOS 18.4",
            defaultModelRaw: appA.defaultModelRaw,
            defaultModeRaw: appA.defaultModeRaw,
            defaultStepBudget: appA.defaultStepBudget
        )
        try await store.upsert(appARenamed)

        let active = try await store.applications()
        #expect(active.count == 2)
        #expect(active.first?.id == appA.id)
        #expect(active.first?.name == "A renamed")
        #expect(active.first?.defaultSimulatorUDID == "UDID-XYZ")

        // Archive B; default-listing should now skip it.
        try await store.archive(applicationID: appB.id)
        let afterArchive = try await store.applications()
        #expect(afterArchive.count == 1)
        let withArchived = try await store.applications(includeArchived: true)
        #expect(withArchived.count == 2)

        // Hard-delete A.
        try await store.deleteApplication(id: appA.id)
        let afterDelete = try await store.applications(includeArchived: true)
        #expect(afterDelete.count == 1)
        #expect(afterDelete.first?.id == appB.id)
    }

    @Test("Deleting an Application nullifies bound RunRecord refs but keeps denormalized fields")
    func deleteApplicationNullifiesRunRecords() async throws {
        let store = try RunHistoryStore.inMemory()

        let app = ApplicationSnapshot(
            id: UUID(),
            name: "ListApp",
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil,
            projectPath: "/tmp/ListApp.xcodeproj",
            projectBookmark: nil,
            scheme: "ListApp",
            defaultSimulatorUDID: nil,
            defaultSimulatorName: nil,
            defaultSimulatorRuntime: nil,
            defaultModelRaw: AgentModel.opus47.rawValue,
            defaultModeRaw: RunMode.stepByStep.rawValue,
            defaultStepBudget: 40
        )
        try await store.upsert(app)

        var skel = RunRecordSnapshot.skeleton(from: Self.makeRequest())
        skel = RunRecordSnapshot(
            id: skel.id,
            name: skel.name,
            createdAt: skel.createdAt,
            completedAt: skel.completedAt,
            projectPath: skel.projectPath,
            scheme: skel.scheme,
            displayName: skel.displayName,
            simulatorUDID: skel.simulatorUDID,
            simulatorName: skel.simulatorName,
            simulatorRuntime: skel.simulatorRuntime,
            goal: skel.goal,
            persona: skel.persona,
            modelRaw: skel.modelRaw,
            modeRaw: skel.modeRaw,
            verdictRaw: skel.verdictRaw,
            summary: skel.summary,
            stepCount: skel.stepCount,
            frictionCount: skel.frictionCount,
            wouldRealUserSucceed: skel.wouldRealUserSucceed,
            tokensUsedInput: skel.tokensUsedInput,
            tokensUsedOutput: skel.tokensUsedOutput,
            runDirectoryPath: skel.runDirectoryPath,
            applicationID: app.id,
            personaID: nil,
            actionID: nil,
            actionChainID: nil
        )
        try await store.upsert(skel)

        let pre = try await store.fetch(id: skel.id)
        #expect(pre?.applicationID == app.id)
        #expect(pre?.projectPath == skel.projectPath) // denormalized survives

        try await store.deleteApplication(id: app.id)

        let post = try await store.fetch(id: skel.id)
        #expect(post?.applicationID == nil)
        #expect(post?.projectPath == skel.projectPath)
        #expect(post?.scheme == skel.scheme)
    }

    @Test("Persona delete leaves runs pointing at it readable")
    func deletePersonaDoesNotBreakRuns() async throws {
        let store = try RunHistoryStore.inMemory()

        let p = PersonaSnapshot(
            id: UUID(),
            name: "explorer",
            blurb: "patient",
            promptText: "you are patient",
            isBuiltIn: false,
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil
        )
        try await store.upsert(p)

        var skel = RunRecordSnapshot.skeleton(from: Self.makeRequest())
        skel = RunRecordSnapshot(
            id: skel.id,
            name: skel.name,
            createdAt: skel.createdAt,
            completedAt: skel.completedAt,
            projectPath: skel.projectPath,
            scheme: skel.scheme,
            displayName: skel.displayName,
            simulatorUDID: skel.simulatorUDID,
            simulatorName: skel.simulatorName,
            simulatorRuntime: skel.simulatorRuntime,
            goal: skel.goal,
            persona: skel.persona,
            modelRaw: skel.modelRaw,
            modeRaw: skel.modeRaw,
            verdictRaw: skel.verdictRaw,
            summary: skel.summary,
            stepCount: skel.stepCount,
            frictionCount: skel.frictionCount,
            wouldRealUserSucceed: skel.wouldRealUserSucceed,
            tokensUsedInput: skel.tokensUsedInput,
            tokensUsedOutput: skel.tokensUsedOutput,
            runDirectoryPath: skel.runDirectoryPath,
            applicationID: nil,
            personaID: p.id,
            actionID: nil,
            actionChainID: nil
        )
        try await store.upsert(skel)
        let pre = try await store.fetch(id: skel.id)
        #expect(pre?.personaID == p.id)

        try await store.deletePersona(id: p.id)

        let post = try await store.fetch(id: skel.id)
        #expect(post != nil)
        #expect(post?.personaID == nil)
        // Denormalized text field still there.
        #expect(post?.persona == skel.persona)
    }

    @Test("Deleting an Action nullifies any chain-step that referenced it")
    func deleteActionNullifiesChainSteps() async throws {
        let store = try RunHistoryStore.inMemory()

        let act1 = ActionSnapshot(
            id: UUID(),
            name: "Add milk",
            promptText: "add milk to list",
            notes: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil
        )
        let act2 = ActionSnapshot(
            id: UUID(),
            name: "Mark milk done",
            promptText: "mark milk as done",
            notes: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil
        )
        try await store.upsert(act1)
        try await store.upsert(act2)

        let chain = ActionChainSnapshot(
            id: UUID(),
            name: "Milk flow",
            notes: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            archivedAt: nil,
            steps: [
                ActionChainStepSnapshot(id: UUID(), index: 0, actionID: act1.id, preservesState: false),
                ActionChainStepSnapshot(id: UUID(), index: 1, actionID: act2.id, preservesState: true)
            ]
        )
        try await store.upsert(chain)

        let pre = try await store.actionChain(id: chain.id)
        #expect(pre?.steps.count == 2)
        #expect(pre?.steps[0].actionID == act1.id)

        try await store.deleteAction(id: act1.id)

        let post = try await store.actionChain(id: chain.id)
        #expect(post?.steps.count == 2) // step survives, ref nullified
        #expect(post?.steps[0].actionID == nil)
        #expect(post?.steps[1].actionID == act2.id)
    }

    @Test("seedBuiltInPersonasIfNeeded is idempotent across calls")
    func seedBuiltInPersonasIdempotent() async throws {
        let store = try RunHistoryStore.inMemory()

        let markdown = """
        # Default Personas

        ---

        ## first-time user

        A curious first-time user. They explore.

        ---

        ## power user

        Knows the app inside out.

        ---
        """
        try await store.seedBuiltInPersonasIfNeeded(from: markdown)
        let first = try await store.personas()
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.isBuiltIn })

        try await store.seedBuiltInPersonasIfNeeded(from: markdown)
        let second = try await store.personas()
        #expect(second.count == 2)
    }

    // MARK: Helper

    private static func makeRequest() -> GoalRequest {
        GoalRequest(
            id: UUID(),
            goal: "Test goal",
            persona: "first-time user",
            project: ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/A.xcodeproj"),
                scheme: "ASchema",
                displayName: "A"
            ),
            simulator: SimulatorRef(
                udid: "UDID-AAA",
                name: "iPhone 16 Pro",
                runtime: "iOS 18.4",
                pointSize: CGSize(width: 430, height: 932),
                scaleFactor: 3.0
            ),
            model: .opus47,
            mode: .stepByStep
        )
    }
}
