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

    @Test("touchProject inserts then updates by path; recents reflect lastUsedAt")
    func projectRecentsTouch() async throws {
        let store = try RunHistoryStore.inMemory()

        let now = Date()
        let snap = ProjectRefSnapshot(
            id: UUID(),
            path: "/tmp/A.xcodeproj",
            displayName: "A",
            defaultScheme: "ASchema",
            defaultSimulatorUDID: nil,
            lastUsedAt: now
        )
        try await store.touchProject(snap)

        let snapB = ProjectRefSnapshot(
            id: UUID(),
            path: "/tmp/B.xcodeproj",
            displayName: "B",
            defaultScheme: "BSchema",
            defaultSimulatorUDID: nil,
            lastUsedAt: now.addingTimeInterval(60)
        )
        try await store.touchProject(snapB)

        // Touch A again with a later timestamp; should reorder.
        let snapAUpdated = ProjectRefSnapshot(
            id: snap.id, // ID is ignored on update; lookup is by path.
            path: "/tmp/A.xcodeproj",
            displayName: "A renamed",
            defaultScheme: "ASchema",
            defaultSimulatorUDID: "UDID-XYZ",
            lastUsedAt: now.addingTimeInterval(120)
        )
        try await store.touchProject(snapAUpdated)

        let recents = try await store.recentProjects(limit: 10)
        #expect(recents.count == 2)
        #expect(recents.first?.path == "/tmp/A.xcodeproj")
        #expect(recents.first?.displayName == "A renamed")
        #expect(recents.first?.defaultSimulatorUDID == "UDID-XYZ")
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
