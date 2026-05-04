//
//  FrictionReportViewModelTests.swift
//  HarnessTests
//
//  Asserts that the friction-report VM joins friction rows with their
//  same-step `tool_call.observation` and `step_started.ts`, that the kind
//  filter buckets the production taxonomy correctly, and that load handles
//  the empty / missing-run cases without crashing.
//

import Testing
import Foundation
@testable import Harness

@Suite("FrictionReportViewModel")
struct FrictionReportViewModelTests {

    @Test("Loads friction events with joined observation + elapsed timestamp")
    @MainActor
    func happyPath() async throws {
        let runID = UUID()
        let store = try RunHistoryStore.inMemory()
        try await Self.seedRun(store: store, runID: runID)

        let req = Self.makeRequest(id: runID)
        let baseTs = Date(timeIntervalSinceReferenceDate: 1_000)
        try Self.writeRows([
            (.runStarted(from: req), baseTs),
            (.stepStarted(StepStartedPayload(step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0)),
             baseTs.addingTimeInterval(14)),
            (.toolCall(step: 1, call: ToolCall(
                tool: .tap, input: .tap(x: 100, y: 200),
                observation: "I see a 22pt unfilled circle to the left of the row text.",
                intent: "Trying tap and observing.")), baseTs.addingTimeInterval(15)),
            (.friction(FrictionPayload(
                step: 1, frictionKind: FrictionKind.ambiguousLabel.rawValue,
                detail: "Empty checkbox has no label or hint. The circle on the left functions as a checkbox.")),
             baseTs.addingTimeInterval(16)),
            (.toolCall(step: 2, call: ToolCall(
                tool: .swipe, input: .swipe(x1: 300, y1: 200, x2: 50, y2: 200, durationMs: 200),
                observation: "Swiping left exposes only Delete.",
                intent: "Looking for an Unmark.")), baseTs.addingTimeInterval(40)),
            (.friction(FrictionPayload(
                step: 2, frictionKind: FrictionKind.deadEnd.rawValue,
                detail: "No way to unmark a completed item.")), baseTs.addingTimeInterval(41)),
            (.friction(FrictionPayload(
                step: 2, frictionKind: FrictionKind.confusingCopy.rawValue,
                detail: "Trash icon is unlabeled.")), baseTs.addingTimeInterval(42)),
        ], runID: runID)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        let vm = FrictionReportViewModel(store: store)
        await vm.load(preferredRunID: runID)

        #expect(vm.runID == runID)
        #expect(vm.loadError == nil)
        #expect(vm.totalFriction == 3)
        #expect(vm.runDisplayLabel.contains("Sample"))

        // First entry — joined observation + 00:14 elapsed
        #expect(vm.entries[0].step == 1)
        #expect(vm.entries[0].kind == .ambiguousLabel)
        #expect(vm.entries[0].agentObservation.contains("22pt"))
        #expect(vm.entries[0].timestampLabel == "00:14")

        // Filter buckets:
        vm.filter = .ambiguous
        // ambiguousLabel + confusingCopy → 2
        #expect(vm.filteredEntries.count == 2)
        vm.filter = .deadEnds
        #expect(vm.filteredEntries.count == 1)
        vm.filter = .missing
        #expect(vm.filteredEntries.count == 0)
        vm.filter = .all
        #expect(vm.filteredEntries.count == 3)

        // Tally counts kinds in canonical order.
        let kinds = vm.kindCounts.map(\.kind)
        #expect(kinds.contains(.deadEnd))
        #expect(kinds.contains(.ambiguousLabel))
        #expect(kinds.contains(.confusingCopy))
    }

    @Test("Run with zero friction loads with empty entries, no error")
    @MainActor
    func zeroFriction() async throws {
        let runID = UUID()
        let store = try RunHistoryStore.inMemory()
        try await Self.seedRun(store: store, runID: runID)
        let req = Self.makeRequest(id: runID)
        try Self.writeRows([
            (.runStarted(from: req), Date()),
            (.stepStarted(StepStartedPayload(step: 1, screenshot: "step-001.png", tokensUsedSoFar: 0)), Date()),
            (.toolCall(step: 1, call: ToolCall(
                tool: .tap, input: .tap(x: 0, y: 0),
                observation: "obs", intent: "intent")), Date()),
            (.toolResult(ToolResultPayload(
                step: 1, tool: "tap", success: true, durationMs: 10,
                error: nil, userDecision: nil, userNote: nil)), Date()),
        ], runID: runID)
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: runID)) }

        let vm = FrictionReportViewModel(store: store)
        await vm.load(preferredRunID: runID)

        #expect(vm.runID == runID)
        #expect(vm.totalFriction == 0)
        #expect(vm.kindCounts.isEmpty)
        #expect(vm.loadError == nil)
    }

    @Test("Missing events.jsonl surfaces a load error, no crash")
    @MainActor
    func missingRun() async throws {
        let runID = UUID()
        let store = try RunHistoryStore.inMemory()
        // Seed history but DO NOT write any events.jsonl on disk.
        try await Self.seedRun(store: store, runID: runID)

        let vm = FrictionReportViewModel(store: store)
        await vm.load(preferredRunID: runID)

        #expect(vm.runID == runID)
        #expect(vm.entries.isEmpty)
        #expect(vm.loadError != nil)
    }

    @Test("Nil preferred run + empty store yields a clean empty state")
    @MainActor
    func emptyStore() async throws {
        let store = try RunHistoryStore.inMemory()
        let vm = FrictionReportViewModel(store: store)
        await vm.load(preferredRunID: nil)

        #expect(vm.runID == nil)
        #expect(vm.entries.isEmpty)
        #expect(vm.loadError == nil)
        #expect(vm.runDisplayLabel.isEmpty)
    }

    // MARK: Helpers

    private static func makeRequest(id: UUID) -> GoalRequest {
        GoalRequest(
            id: id,
            goal: "Add 'milk' and mark it done.",
            persona: "first-time user",
            project: ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/Sample.xcodeproj"),
                scheme: "Sample",
                displayName: "Sample"
            ),
            simulator: SimulatorRef(
                udid: "FAKE-UDID",
                name: "iPhone 16 Pro",
                runtime: "iOS 18.4",
                pointSize: CGSize(width: 430, height: 932),
                scaleFactor: 3.0
            ),
            model: .opus47,
            mode: .stepByStep
        )
    }

    private static func seedRun(store: RunHistoryStore, runID: UUID) async throws {
        let req = makeRequest(id: runID)
        var snap = RunRecordSnapshot.skeleton(from: req)
        snap = RunRecordSnapshot(
            id: snap.id,
            createdAt: snap.createdAt,
            completedAt: nil,
            projectPath: snap.projectPath,
            scheme: snap.scheme,
            displayName: snap.displayName,
            simulatorUDID: snap.simulatorUDID,
            simulatorName: snap.simulatorName,
            simulatorRuntime: snap.simulatorRuntime,
            goal: snap.goal,
            persona: snap.persona,
            modelRaw: snap.modelRaw,
            modeRaw: snap.modeRaw,
            verdictRaw: nil,
            summary: nil,
            stepCount: 0,
            frictionCount: 0,
            wouldRealUserSucceed: false,
            tokensUsedInput: 0,
            tokensUsedOutput: 0,
            runDirectoryPath: snap.runDirectoryPath
        )
        try await store.upsert(snap)
    }

    private static func writeRows(_ pairs: [(LogRow, Date)], runID: UUID) throws {
        try HarnessPaths.prepareRunDirectory(for: runID)
        let url = HarnessPaths.eventsLog(for: runID)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for (row, ts) in pairs {
            let data = try RunLogger.encode(row, runID: runID, ts: ts)
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }
}
