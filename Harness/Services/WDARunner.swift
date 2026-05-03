//
//  WDARunner.swift
//  Harness
//
//  Lifecycle controller for the `xcodebuild test-without-building` process
//  that hosts WebDriverAgent inside the iOS Simulator. The runner is what
//  keeps WDA's HTTP server (port 8100 by default) alive while a Harness run
//  is in progress; `WDAClient` is the HTTP-side counterpart.
//
//  Phase C of the idb→WDA migration. Symmetric with `XcodeBuilder` /
//  `SimulatorDriver`'s lifecycle helpers — every shell-out goes through
//  `ProcessRunner`, every error path is typed.
//

import Foundation
import os

// MARK: - Result

struct WDARunnerHandle: Sendable {
    /// Port WDA is reachable at. Mirror of the port passed at start.
    let port: Int
    /// Background task wrapping the xcodebuild streaming process. Cancelling
    /// it triggers SIGTERM via `ProcessRunner.runStreaming`'s onTermination.
    let task: Task<Void, any Error>
}

// MARK: - Errors

enum WDARunnerError: Error, Sendable, LocalizedError {
    case xcodebuildUnavailable
    case readinessTimeout(after: Duration)
    case startFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .xcodebuildUnavailable:
            return "xcodebuild is not available. Install Xcode and run `xcode-select --install`."
        case .readinessTimeout(let after):
            return "WebDriverAgent did not finish booting within \(after). Check the simulator and try again."
        case .startFailed(let detail):
            return "Could not start the WebDriverAgent test runner: \(detail)"
        }
    }
}

// MARK: - Protocol

protocol WDARunning: Sendable {
    /// Spawn the WDA test runner against the given simulator. Returns once the
    /// process is launched; the caller is responsible for polling WDA's
    /// `/status` endpoint via `WDAClient.waitForReady` to know when the HTTP
    /// server is actually accepting requests.
    func start(udid: String, xctestrun: URL, port: Int) async throws -> WDARunnerHandle

    /// Stop a previously-started runner. Idempotent.
    func stop(_ handle: WDARunnerHandle) async

    /// Kill any orphan `xcodebuild test-without-building` process bound to
    /// this UDID. Tolerant of "no processes matched" (the success case).
    /// Symmetric with the old `cleanupCompanion(udid:)` for idb.
    func cleanupOrphans(udid: String) async
}

// MARK: - Implementation

actor WDARunner: WDARunning {

    private static let logger = Logger(subsystem: "com.harness.app", category: "WDARunner")

    /// Default WDA listen port.
    static let defaultPort: Int = 8100

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating

    init(processRunner: any ProcessRunning, toolLocator: any ToolLocating) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
    }

    // MARK: start / stop

    func start(udid: String, xctestrun: URL, port: Int = WDARunner.defaultPort) async throws -> WDARunnerHandle {
        try Task.checkCancellation()

        let tools = try await toolLocator.locateAll()
        guard let xcodebuild = tools.xcodebuild else {
            throw WDARunnerError.xcodebuildUnavailable
        }

        // The runner is open-ended — no timeout. Cancellation flows through
        // the streaming task's onTermination handler, which SIGTERMs the
        // child via `ProcessRunner`.
        let spec = ProcessSpec(
            executable: xcodebuild,
            arguments: [
                "test-without-building",
                "-xctestrun", xctestrun.path,
                "-destination", "id=\(udid)",
                "-disable-concurrent-destination-testing"
            ],
            timeout: nil
        )

        let stream = processRunner.runStreaming(spec)
        let task = Task<Void, any Error> {
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    if case .completed(let exit, _) = chunk, exit != 0 {
                        Self.logger.warning("WDA runner exited non-zero: \(exit, privacy: .public)")
                    }
                }
            } catch is CancellationError {
                // Normal shutdown path.
                throw CancellationError()
            } catch {
                Self.logger.error("WDA runner stream error: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        Self.logger.info("WDA runner spawned (udid=\(udid, privacy: .public) port=\(port, privacy: .public))")
        return WDARunnerHandle(port: port, task: task)
    }

    func stop(_ handle: WDARunnerHandle) async {
        handle.task.cancel()
        // Wait briefly for SIGTERM to land. Don't await indefinitely — if the
        // process refuses to die, ProcessRunner will SIGKILL after its
        // grace window.
        _ = try? await withTimeout(.seconds(8)) {
            _ = try await handle.task.value
        }
        Self.logger.info("WDA runner stopped (port=\(handle.port, privacy: .public))")
    }

    // MARK: Orphan cleanup

    func cleanupOrphans(udid: String) async {
        let pkill = URL(fileURLWithPath: "/usr/bin/pkill")
        // -f matches against the full command line. xcodebuild is invoked with
        // `test-without-building ... -destination id=<UDID>` so the UDID
        // narrows the match to this exact run.
        let pattern = "xcodebuild.*test-without-building.*\(udid)"
        do {
            _ = try await processRunner.run(ProcessSpec(
                executable: pkill,
                arguments: ["-f", pattern],
                timeout: .seconds(5)
            ))
            try? await Task.sleep(for: .milliseconds(150))
            Self.logger.info("Killed orphan WDA runner for \(udid, privacy: .public)")
        } catch ProcessFailure.nonZeroExit(let code, _, _, _) where code == 1 {
            // No matches — fresh-machine path.
        } catch {
            Self.logger.warning("WDA orphan cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    /// Run `body` with a wall-clock timeout. Returns the body's value, or
    /// throws CancellationError on timeout.
    private func withTimeout<T: Sendable>(_ duration: Duration, body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}
