//
//  ProcessRunnerTests.swift
//  HarnessTests
//
//  Integration tests against /bin/echo, /bin/sleep. Verifies one-shot exit
//  capture, non-zero exit handling, and cancellation propagation (the actor
//  must SIGTERM the child when the parent task is cancelled).
//

import Testing
import Foundation
@testable import Harness

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("Successful run captures stdout")
    func echoStdout() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "world"]
        ))
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test("Non-zero exit throws ProcessFailure.nonZeroExit")
    func nonZeroExit() async {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(ProcessSpec(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo whoops; exit 42"]
            ))
            Issue.record("expected throw")
        } catch let failure as ProcessFailure {
            if case .nonZeroExit(let code, _, let so, _) = failure {
                #expect(code == 42)
                #expect(so.contains("whoops"))
            } else {
                Issue.record("wrong failure case: \(failure)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Cancellation SIGTERMs the child")
    func cancellationKillsChild() async throws {
        let runner = ProcessRunner()
        let task = Task<ProcessResult, any Error> {
            try await runner.run(ProcessSpec(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            ))
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        let started = ContinuousClock().now
        let result = await task.result
        let elapsed = ContinuousClock().now - started

        // The child should die within the 5s grace; we expect a thrown failure.
        if case .success = result {
            Issue.record("expected cancellation to throw")
        }
        // 10s sleep, but we cancelled — total time well under 6s.
        #expect(elapsed < .seconds(6))
    }

    @Test("Streaming yields completion event")
    func streamingCompletion() async throws {
        let runner = ProcessRunner()
        let stream = runner.runStreaming(ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["stream-me"]
        ))

        var sawStdout = false
        var sawCompleted = false
        for try await chunk in stream {
            switch chunk {
            case .stdout: sawStdout = true
            case .completed: sawCompleted = true
            case .stderr: break
            }
        }
        #expect(sawStdout)
        #expect(sawCompleted)
    }
}
