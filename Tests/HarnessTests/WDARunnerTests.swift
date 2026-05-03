//
//  WDARunnerTests.swift
//  HarnessTests
//
//  Tests for the lifecycle wrapper around `xcodebuild test-without-building`.
//  The runner streams indefinitely in production, so the fake here returns a
//  stream that we can drive frame-by-frame via continuation.
//

import Testing
import Foundation
@testable import Harness

@Suite("WDARunner — xcodebuild invocation shape")
struct WDARunnerInvocationTests {

    @Test("start invokes xcodebuild test-without-building with -xctestrun and -destination")
    func startInvocationShape() async throws {
        let runner = FakeProcessRunner()
        let locator = FakeToolLocator()

        // Yield a single .completed chunk so the streaming task finishes; in
        // production it stays alive until cancelled.
        let stream = AsyncThrowingStream<ProcessChunk, any Error> { continuation in
            // Immediately complete — the runner's task drains and exits.
            continuation.yield(.completed(exitCode: 0, duration: .milliseconds(1)))
            continuation.finish()
        }
        runner.setStreamForRun { _ in stream }

        let wda = WDARunner(processRunner: runner, toolLocator: locator)
        let xctestrun = URL(fileURLWithPath: "/tmp/WebDriverAgentRunner.xctestrun")
        let handle = try await wda.start(udid: "FAKE-UDID", xctestrun: xctestrun, port: 8100)
        // Drain the task so we don't leak.
        _ = try? await handle.task.value

        let calls = runner.recordedCalls()
        #expect(calls.count == 1)
        let spec = calls[0]
        #expect(spec.executable.path.hasSuffix("xcodebuild"))
        #expect(spec.arguments.contains("test-without-building"))
        #expect(spec.arguments.contains("-xctestrun"))
        #expect(spec.arguments.contains("/tmp/WebDriverAgentRunner.xctestrun"))
        #expect(spec.arguments.contains("-destination"))
        #expect(spec.arguments.contains("id=FAKE-UDID"))
        #expect(handle.port == 8100)
    }

    @Test("start throws xcodebuildUnavailable when toolPaths.xcodebuild is nil")
    func missingXcodebuild() async throws {
        let runner = FakeProcessRunner()
        let locator = FakeToolLocator(paths: ToolPaths(
            xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"),
            xcodebuild: nil,
            idb: nil, idbCompanion: nil, brew: nil
        ))
        let wda = WDARunner(processRunner: runner, toolLocator: locator)

        do {
            _ = try await wda.start(
                udid: "X",
                xctestrun: URL(fileURLWithPath: "/tmp/foo.xctestrun"),
                port: 8100
            )
            Issue.record("expected throw")
        } catch let error as WDARunnerError {
            if case .xcodebuildUnavailable = error { return }
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("stop cancels the runner task")
    func stopCancelsTask() async throws {
        let runner = FakeProcessRunner()
        let locator = FakeToolLocator()

        // Long-running stream — drains only when the consumer cancels.
        let stream = AsyncThrowingStream<ProcessChunk, any Error> { continuation in
            continuation.onTermination = { _ in
                continuation.finish()
            }
            // Don't yield — wait for cancellation.
        }
        runner.setStreamForRun { _ in stream }

        let wda = WDARunner(processRunner: runner, toolLocator: locator)
        let handle = try await wda.start(
            udid: "FAKE-UDID",
            xctestrun: URL(fileURLWithPath: "/tmp/WDA.xctestrun"),
            port: 8100
        )
        await wda.stop(handle)
        // Cancelled task — `task.value` either throws CancellationError or
        // returns; both are acceptable. Just confirm it doesn't hang.
        let raceTask = Task<Void, Never> {
            _ = try? await handle.task.value
        }
        let timeout = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(3))
            raceTask.cancel()
            return false
        }
        await raceTask.value
        timeout.cancel()
    }

    @Test("cleanupOrphans pkills xcodebuild matching the UDID and tolerates no-match")
    func cleanupOrphansShape() async throws {
        let runner = FakeProcessRunner()
        let locator = FakeToolLocator()

        // pkill exit-code 1 = no processes matched — fake it as nonZeroExit(1).
        runner.setResultForRun { spec in
            if spec.executable.path == "/usr/bin/pkill" {
                return .failure(ProcessFailure.nonZeroExit(
                    exitCode: 1,
                    command: "/usr/bin/pkill -f xcodebuild.*test-without-building.*FAKE-UDID",
                    stdoutSnippet: "",
                    stderrSnippet: ""
                ))
            }
            return .success(ProcessResult(exitCode: 0, stdout: Data(), stderr: Data(), duration: .milliseconds(1)))
        }

        let wda = WDARunner(processRunner: runner, toolLocator: locator)
        await wda.cleanupOrphans(udid: "FAKE-UDID")

        let calls = runner.recordedCalls()
        // Exactly one call — the pkill. The exit-1 should be swallowed.
        #expect(calls.count == 1)
        let spec = calls[0]
        #expect(spec.executable.path == "/usr/bin/pkill")
        #expect(spec.arguments.contains("-f"))
        #expect(spec.arguments.last?.contains("FAKE-UDID") == true)
        #expect(spec.arguments.last?.contains("test-without-building") == true)
    }
}

