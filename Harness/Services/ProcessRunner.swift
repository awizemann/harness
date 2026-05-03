//
//  ProcessRunner.swift
//  Harness
//
//  The single owner of `Process()` invocation in Harness, per
//  `standards/03-subprocess-and-filesystem.md`.
//
//  Why an actor: it serializes Pipe-handle ownership and gives us a clean
//  cancellation handler that signals + closes file descriptors uniformly.
//  No other code in the app should instantiate `Process()` directly.
//

import Foundation
import os

// MARK: - Public types

/// Declarative description of one subprocess invocation.
struct ProcessSpec: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL?
    let standardInput: Data?
    /// Hard upper bound on wall-clock duration. `nil` = no timeout.
    let timeout: Duration?

    init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let duration: Duration

    var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}

/// One chunk of streaming output. Useful for long-running commands like xcodebuild.
enum ProcessChunk: Sendable {
    case stdout(Data)
    case stderr(Data)
    case completed(exitCode: Int32, duration: Duration)
}

/// Thrown for non-zero exit codes and termination edge cases.
enum ProcessFailure: Error, Sendable {
    /// Process exited non-zero. Stdout/stderr snippets capped at 4 KB.
    case nonZeroExit(exitCode: Int32, command: String, stdoutSnippet: String, stderrSnippet: String)
    case launchFailed(underlying: any Error)
    case timedOut(after: Duration, command: String)
    case cancelled(command: String)

    var snippet: String {
        switch self {
        case .nonZeroExit(let code, let cmd, let so, let se):
            return "exit=\(code) cmd=\(cmd)\nstdout: \(so)\nstderr: \(se)"
        case .launchFailed(let err):
            return "launch failed: \(err)"
        case .timedOut(let dur, let cmd):
            return "timed out after \(dur) cmd=\(cmd)"
        case .cancelled(let cmd):
            return "cancelled cmd=\(cmd)"
        }
    }
}

// MARK: - Protocol

protocol ProcessRunning: Sendable {
    func run(_ spec: ProcessSpec) async throws -> ProcessResult
    func runStreaming(_ spec: ProcessSpec) -> AsyncThrowingStream<ProcessChunk, any Error>
}

// MARK: - Default implementation

actor ProcessRunner: ProcessRunning {

    private static let logger = Logger(subsystem: "com.harness.app", category: "ProcessRunner")

    /// Bytes retained from each pipe for diagnostic snippets on failure.
    private static let snippetCap = 4_096

    /// Grace window between SIGTERM and SIGKILL.
    private static let sigtermGrace: Duration = .seconds(5)

    init() {}

    // MARK: One-shot

    nonisolated func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        if !spec.environment.isEmpty {
            process.environment = spec.environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdinData = spec.standardInput {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            // Write input synchronously — the child will read at its own pace.
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            } catch {
                Self.logger.error("stdin write failed: \(error.localizedDescription, privacy: .public)")
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        let commandLabel = spec.executable.path + (spec.arguments.isEmpty ? "" : " " + spec.arguments.joined(separator: " "))
        let started = ContinuousClock().now

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                // Termination handler runs on a background thread, owned by `Process`.
                process.terminationHandler = { proc in
                    let duration = ContinuousClock().now - started
                    let stdoutData = Self.readToEnd(stdoutPipe)
                    let stderrData = Self.readToEnd(stderrPipe)
                    Self.closeBothEnds(stdoutPipe)
                    Self.closeBothEnds(stderrPipe)

                    let result = ProcessResult(
                        exitCode: proc.terminationStatus,
                        stdout: stdoutData,
                        stderr: stderrData,
                        duration: duration
                    )

                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: ProcessFailure.nonZeroExit(
                            exitCode: proc.terminationStatus,
                            command: commandLabel,
                            stdoutSnippet: Self.snippet(of: stdoutData),
                            stderrSnippet: Self.snippet(of: stderrData)
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    Self.closeBothEnds(stdoutPipe)
                    Self.closeBothEnds(stderrPipe)
                    Self.logger.error("Process launch failed for \(commandLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: ProcessFailure.launchFailed(underlying: error))
                    return
                }

                // Optional timeout: schedule a kill after the grace window.
                if let timeout = spec.timeout {
                    Task.detached { [weak process] in
                        try? await Task.sleep(for: timeout)
                        guard let process, process.isRunning else { return }
                        Self.logger.warning("Process \(commandLabel, privacy: .public) timed out after \(String(describing: timeout), privacy: .public); SIGTERM")
                        process.terminate()
                        try? await Task.sleep(for: Self.sigtermGrace)
                        if process.isRunning {
                            Self.logger.warning("Process \(commandLabel, privacy: .public) still alive after grace; SIGKILL")
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        } onCancel: {
            // Cooperative cancellation: SIGTERM, then SIGKILL after grace.
            if process.isRunning {
                Self.logger.info("Process \(commandLabel, privacy: .public) cancelled; SIGTERM")
                process.terminate()
                Task.detached {
                    try? await Task.sleep(for: Self.sigtermGrace)
                    if process.isRunning {
                        Self.logger.warning("Process \(commandLabel, privacy: .public) still alive after cancel grace; SIGKILL")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    // MARK: Streaming

    nonisolated func runStreaming(_ spec: ProcessSpec) -> AsyncThrowingStream<ProcessChunk, any Error> {
        AsyncThrowingStream<ProcessChunk, any Error> { continuation in
            let process = Process()
            process.executableURL = spec.executable
            process.arguments = spec.arguments
            process.currentDirectoryURL = spec.workingDirectory
            if !spec.environment.isEmpty {
                process.environment = spec.environment
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if let stdinData = spec.standardInput {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                do { try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData) }
                catch { Self.logger.error("stdin write failed: \(error.localizedDescription, privacy: .public)") }
                try? stdinPipe.fileHandleForWriting.close()
            }

            let commandLabel = spec.executable.path + (spec.arguments.isEmpty ? "" : " " + spec.arguments.joined(separator: " "))
            let started = ContinuousClock().now

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                continuation.yield(.stdout(data))
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                continuation.yield(.stderr(data))
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                Self.closeBothEnds(stdoutPipe)
                Self.closeBothEnds(stderrPipe)

                let duration = ContinuousClock().now - started
                continuation.yield(.completed(exitCode: proc.terminationStatus, duration: duration))

                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProcessFailure.nonZeroExit(
                        exitCode: proc.terminationStatus,
                        command: commandLabel,
                        stdoutSnippet: "<streamed>",
                        stderrSnippet: "<streamed>"
                    ))
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                    Task.detached {
                        try? await Task.sleep(for: Self.sigtermGrace)
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                Self.closeBothEnds(stdoutPipe)
                Self.closeBothEnds(stderrPipe)
                continuation.finish(throwing: ProcessFailure.launchFailed(underlying: error))
            }
        }
    }

    // MARK: Helpers

    /// Drain any remaining pipe contents (post-termination).
    private static func readToEnd(_ pipe: Pipe) -> Data {
        let handle = pipe.fileHandleForReading
        // `readDataToEndOfFile()` is documented to throw on Process pipes that have
        // already been partially read by readabilityHandler — we don't use that
        // for one-shot, but defensively use `availableData` in a loop.
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer
    }

    /// Truncate to UTF-8 string at `snippetCap`, suffixed with `…` when trimmed.
    private static func snippet(of data: Data) -> String {
        let trimmed = data.prefix(snippetCap)
        let s = String(data: trimmed, encoding: .utf8) ?? ""
        return data.count > snippetCap ? s + "\n…(\(data.count - snippetCap) bytes truncated)" : s
    }

    /// Close both ends of a Pipe explicitly. Per the global rule, both file handles
    /// must be closed to prevent fd leaks.
    private static func closeBothEnds(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
