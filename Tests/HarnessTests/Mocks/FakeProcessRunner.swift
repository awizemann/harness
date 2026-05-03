//
//  FakeProcessRunner.swift
//  HarnessTests
//
//  In-memory ProcessRunner used by WDARunner / WDABuilder tests. Records
//  every spec it sees and lets tests pre-load canned results / streams.
//
//  Locked-class flavor (vs an actor) because `ProcessRunning.runStreaming`
//  is nonisolated and synchronously returns an `AsyncThrowingStream`; an
//  actor can't await its own state to assemble the stream.
//

import Foundation
import os
@testable import Harness

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {

    typealias ResultBlock = @Sendable (ProcessSpec) -> Result<ProcessResult, any Error>
    typealias StreamBlock = @Sendable (ProcessSpec) -> AsyncThrowingStream<ProcessChunk, any Error>

    private struct State {
        var calls: [ProcessSpec] = []
        var resultForRun: ResultBlock = { _ in
            .success(ProcessResult(exitCode: 0, stdout: Data(), stderr: Data(), duration: .milliseconds(1)))
        }
        var streamForRun: StreamBlock = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.completed(exitCode: 0, duration: .milliseconds(1)))
                continuation.finish()
            }
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    // MARK: ProcessRunning

    func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        let block = state.withLock { (s: inout State) -> ResultBlock in
            s.calls.append(spec)
            return s.resultForRun
        }
        switch block(spec) {
        case .success(let result): return result
        case .failure(let err): throw err
        }
    }

    func runStreaming(_ spec: ProcessSpec) -> AsyncThrowingStream<ProcessChunk, any Error> {
        let block = state.withLock { (s: inout State) -> StreamBlock in
            s.calls.append(spec)
            return s.streamForRun
        }
        return block(spec)
    }

    // MARK: Test seam

    func setResultForRun(_ block: @escaping ResultBlock) {
        state.withLock { $0.resultForRun = block }
    }

    func setStreamForRun(_ block: @escaping StreamBlock) {
        state.withLock { $0.streamForRun = block }
    }

    func recordedCalls() -> [ProcessSpec] {
        state.withLock { $0.calls }
    }
}

// MARK: - Fake ToolLocator

/// In-memory ToolLocator that returns a canned `ToolPaths`.
final class FakeToolLocator: ToolLocating, @unchecked Sendable {

    private let _paths: OSAllocatedUnfairLock<ToolPaths>

    init(paths: ToolPaths = ToolPaths(
        xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"),
        xcodebuild: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
        idb: nil,
        idbCompanion: nil,
        brew: nil
    )) {
        self._paths = OSAllocatedUnfairLock(initialState: paths)
    }

    func locateAll() async throws -> ToolPaths {
        _paths.withLock { $0 }
    }

    func forceRefresh() async throws -> ToolPaths {
        _paths.withLock { $0 }
    }

    func resolved() async -> ToolPaths? {
        _paths.withLock { $0 }
    }

    func setPaths(_ paths: ToolPaths) {
        _paths.withLock { $0 = paths }
    }
}
