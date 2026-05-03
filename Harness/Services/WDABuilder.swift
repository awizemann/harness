//
//  WDABuilder.swift
//  Harness
//
//  Builds the WebDriverAgentRunner xctestrun once per iOS major.minor and
//  caches it under `~/Library/Application Support/Harness/wda-build/iOS-<ver>/`.
//  Subsequent runs short-circuit when the cache hits and the WDA submodule's
//  git SHA matches the SHA recorded at build time.
//
//  Phase B of the idb→WDA migration. Pairs with `WDARunner` (which executes
//  `xcodebuild test-without-building` against the xctestrun this builder
//  produces) and `WDAClient` (which talks to the running WDA HTTP server).
//

import Foundation
import os

// MARK: - Result

struct WDABuildResult: Sendable, Hashable {
    /// Absolute path to the `*.xctestrun` file produced by `build-for-testing`.
    let xctestrun: URL
    /// The derived-data root used for this build. `WDARunner` reuses the same
    /// directory when invoking `xcodebuild test-without-building`.
    let derivedData: URL
    /// iOS major.minor key the build was cached under.
    let iosVersionKey: String
}

// MARK: - Errors

enum WDABuildFailure: Error, Sendable, LocalizedError {
    case sourceMissing(URL)
    case xcodebuildUnavailable
    case xctestrunNotFound(searched: URL)
    case compileFailed(exitCode: Int32, lastStderrSnippet: String, fullLogPath: URL)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "WebDriverAgent source not found at \(url.path). Run `git submodule update --init --recursive` from the repo root."
        case .xcodebuildUnavailable:
            return "xcodebuild is not available. Install Xcode and run `xcode-select --install`."
        case .xctestrunNotFound(let searched):
            return "WDA build reported success but no .xctestrun was found in \(searched.path)."
        case .compileFailed(let code, let snippet, _):
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "WebDriverAgent build failed (exit code \(code))."
            }
            return "WebDriverAgent build failed (exit code \(code)).\n\nLast error:\n\(trimmed)"
        }
    }

    var recoverySuggestion: String? {
        if case .compileFailed(_, _, let log) = self {
            return "Full xcodebuild log: \(log.path)"
        }
        return nil
    }

    /// Path to the full xcodebuild log when applicable. Mirrors `BuildFailure.buildLogURL`.
    var buildLogURL: URL? {
        if case .compileFailed(_, _, let log) = self { return log }
        return nil
    }
}

// MARK: - Protocol

protocol WDABuilding: Sendable {
    /// Resolve the WDA xctestrun for the given simulator. Builds on cache miss
    /// or when the WDA submodule SHA differs from the SHA recorded with the
    /// last build. Idempotent across processes (the cache is on disk).
    func ensureBuilt(forSimulator ref: SimulatorRef) async throws -> WDABuildResult

    /// Whether a usable xctestrun already exists for `ref`'s iOS version.
    /// Cheap — does not invoke xcodebuild. The first-run wizard's "WDA: ready"
    /// indicator reads this.
    func isReady(forSimulator ref: SimulatorRef) async -> Bool
}

// MARK: - Implementation

actor WDABuilder: WDABuilding {

    private static let logger = Logger(subsystem: "com.harness.app", category: "WDABuilder")

    /// 15-minute build ceiling. WDA's first build is ~1–2 min on a current Mac;
    /// the ceiling protects against deadlocks from broken xcodebuild state.
    private static let buildTimeout: Duration = .seconds(900)

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating
    private let sourceURL: URL

    init(processRunner: any ProcessRunning, toolLocator: any ToolLocating, sourceURL: URL) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
        self.sourceURL = sourceURL
    }

    // MARK: ensureBuilt

    func ensureBuilt(forSimulator ref: SimulatorRef) async throws -> WDABuildResult {
        try Task.checkCancellation()

        let project = sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj")
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw WDABuildFailure.sourceMissing(sourceURL)
        }

        let version = Self.iosVersionKey(from: ref.runtime)
        let derivedData = HarnessPaths.wdaBuildDir(forIOSVersion: version)
        let shaFile = derivedData.appendingPathComponent("wda.sha")

        let currentSHA = (try? await readWDASHA()) ?? ""

        if let cachedRun = try? Self.findXCTestRun(in: derivedData),
           let storedSHA = Self.readSHA(at: shaFile),
           !currentSHA.isEmpty, storedSHA == currentSHA {
            Self.logger.info("WDA cache hit (ios=\(version, privacy: .public) sha=\(currentSHA, privacy: .public))")
            return WDABuildResult(xctestrun: cachedRun, derivedData: derivedData, iosVersionKey: version)
        }

        try HarnessPaths.ensureDirectory(derivedData)
        let logPath = derivedData.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: logPath.path, contents: Data(), attributes: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logPath) else {
            throw WDABuildFailure.compileFailed(exitCode: -1, lastStderrSnippet: "log open failed", fullLogPath: logPath)
        }
        defer { try? logHandle.close() }

        let tools = try await toolLocator.locateAll()
        guard let xcodebuild = tools.xcodebuild else {
            throw WDABuildFailure.xcodebuildUnavailable
        }

        let arguments: [String] = [
            "build-for-testing",
            "-project", project.path,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "id=\(ref.udid)",
            "-derivedDataPath", derivedData.path,
            "-configuration", "Debug",
            // Ad-hoc sign (matches XcodeBuilder; lets the test bundle load
            // its entitlements without a real Apple Developer team).
            "CODE_SIGN_IDENTITY=-",
            "CODE_SIGNING_REQUIRED=YES",
            "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGN_STYLE=Manual",
            "DEVELOPMENT_TEAM="
        ]

        let spec = ProcessSpec(
            executable: xcodebuild,
            arguments: arguments,
            workingDirectory: sourceURL,
            timeout: Self.buildTimeout
        )

        var stderrTail = Data()
        let stream = processRunner.runStreaming(spec)
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                switch chunk {
                case .stdout(let data):
                    try? logHandle.write(contentsOf: data)
                case .stderr(let data):
                    try? logHandle.write(contentsOf: data)
                    stderrTail = Self.appendBoundedTail(stderrTail, data, cap: 4 * 1024)
                case .completed:
                    break
                }
            }
        } catch let failure as ProcessFailure {
            switch failure {
            case .nonZeroExit(let code, _, _, let stderrSnippet):
                let snippet = stderrSnippet.isEmpty
                    ? (String(data: stderrTail, encoding: .utf8) ?? "")
                    : stderrSnippet
                Self.logger.error("WDA build failed (exit=\(code, privacy: .public))")
                throw WDABuildFailure.compileFailed(
                    exitCode: code,
                    lastStderrSnippet: snippet,
                    fullLogPath: logPath
                )
            case .launchFailed(let underlying):
                throw WDABuildFailure.compileFailed(
                    exitCode: -1,
                    lastStderrSnippet: String(describing: underlying),
                    fullLogPath: logPath
                )
            case .timedOut:
                throw WDABuildFailure.compileFailed(
                    exitCode: -1,
                    lastStderrSnippet: "build timed out",
                    fullLogPath: logPath
                )
            case .cancelled:
                throw CancellationError()
            }
        }

        let xctestrun = try Self.findXCTestRun(in: derivedData)
        if !currentSHA.isEmpty {
            try? Data(currentSHA.utf8).write(to: shaFile, options: [.atomic])
        }
        Self.logger.info("WDA build complete (ios=\(version, privacy: .public) artifact=\(xctestrun.lastPathComponent, privacy: .public))")
        return WDABuildResult(xctestrun: xctestrun, derivedData: derivedData, iosVersionKey: version)
    }

    func isReady(forSimulator ref: SimulatorRef) async -> Bool {
        let version = Self.iosVersionKey(from: ref.runtime)
        let derivedData = HarnessPaths.wdaBuildDir(forIOSVersion: version)
        return (try? Self.findXCTestRun(in: derivedData)) != nil
    }

    // MARK: WDA SHA

    /// Read the HEAD SHA of the WDA submodule. Submodules use a `.git` *file*
    /// pointing to `<super>/.git/modules/<path>`, so reading `<source>/.git/HEAD`
    /// directly is fragile — `git rev-parse HEAD` resolves both layouts.
    private func readWDASHA() async throws -> String {
        let result = try await processRunner.run(ProcessSpec(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "HEAD"],
            workingDirectory: sourceURL,
            timeout: .seconds(5)
        ))
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readSHA(at url: URL) -> String? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Pure helpers (tested in isolation)

    /// Map a `SimulatorRef.runtime` label to the major.minor key used as the
    /// cache directory suffix.
    /// - `"iOS 18.4"` → `"18.4"`
    /// - `"iOS-18-4"` → `"18.4"`
    /// - `"18.4"` → `"18.4"` (already clean)
    /// Anything we can't normalize falls back to `"unknown"`.
    static func iosVersionKey(from runtime: String) -> String {
        let trimmed = runtime.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            return trimmed
        }
        var stripped = trimmed
        // Drop leading "iOS " / "iOS-" / "iOS".
        for prefix in ["iOS ", "iOS-", "iOS"] {
            if stripped.hasPrefix(prefix) {
                stripped.removeFirst(prefix.count)
                break
            }
        }
        // Convert dashes to dots so "18-4" → "18.4".
        stripped = stripped.replacingOccurrences(of: "-", with: ".")
        let normalized = stripped.trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? "unknown" : normalized
    }

    /// Locate the `*.xctestrun` produced by `xcodebuild build-for-testing` under
    /// `<derivedData>/Build/Products/`. Throws if no candidate is present.
    static func findXCTestRun(in derivedData: URL) throws -> URL {
        let products = derivedData
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        if let name = entries.first(where: { $0.hasSuffix(".xctestrun") }) {
            return products.appendingPathComponent(name)
        }
        throw WDABuildFailure.xctestrunNotFound(searched: products)
    }

    private static func appendBoundedTail(_ existing: Data, _ chunk: Data, cap: Int) -> Data {
        var combined = existing
        combined.append(chunk)
        if combined.count <= cap { return combined }
        return combined.suffix(cap)
    }
}
