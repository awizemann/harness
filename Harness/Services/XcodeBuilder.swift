//
//  XcodeBuilder.swift
//  Harness
//
//  Wraps `xcodebuild`. Builds the user's iOS project into a simulator-runnable
//  .app bundle, with derived data isolated under the run directory.
//
//  See `wiki/Xcode-Builder.md` for the canonical flag-set rationale.
//  See `standards/03-subprocess-and-filesystem.md` for the ProcessRunner contract.
//

import Foundation
import os

// MARK: - Output

struct BuildResult: Sendable {
    /// Absolute file URL to the built `.app` bundle inside derived data.
    let appBundle: URL
    /// `CFBundleIdentifier` parsed from the bundle's Info.plist.
    let bundleIdentifier: String
    /// Wall-clock duration of the build.
    let duration: Duration
    /// Path of the build log written to `<run-dir>/build/build.log`.
    let logPath: URL
}

enum BuildFailure: Error, Sendable, LocalizedError {
    case projectNotFound(URL)
    case schemeNotFound(name: String)
    case iOSSimulatorNotSupported(scheme: String, availableDestinations: [String])
    case compileFailed(exitCode: Int32, lastStderrSnippet: String, fullLogPath: URL)
    case artifactNotFound(searched: URL)
    case signingRequired(detail: String)
    case bundleIDUnreadable(URL)
    case unsupportedProjectFormat(URL)
    case xcodebuildUnavailable

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let url):
            return "Project not found at \(url.path)"
        case .schemeNotFound(let name):
            return "Scheme '\(name)' was not found in the project. Try selecting a different scheme, or open the project in Xcode and confirm the scheme is shared."
        case .iOSSimulatorNotSupported(let scheme, let available):
            let availableLine = available.isEmpty
                ? "This scheme has no destinations at all."
                : "This scheme builds for: \(available.joined(separator: ", "))."
            return """
            Scheme '\(scheme)' doesn't support iOS Simulator.

            Harness can only drive iOS apps. \(availableLine)

            If your project has multiple schemes (some macOS, some iOS), pick one that targets iOS. If it's macOS-only, Harness can't test it — Harness drives the iOS Simulator via idb, which has no Mac equivalent.
            """
        case .compileFailed(let code, let snippet, _):
            // The full-log location is in `recoverySuggestion` so the UI can
            // render it as a Reveal-in-Finder button.
            let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSnippet.isEmpty {
                return "xcodebuild failed (exit code \(code))."
            }
            return "xcodebuild failed (exit code \(code)).\n\nLast error from xcodebuild:\n\(trimmedSnippet)"
        case .artifactNotFound(let url):
            return "The build reported success, but the .app bundle was not at the expected location: \(url.path)"
        case .signingRequired(let detail):
            return "The project's settings require code signing. Harness passed CODE_SIGNING_ALLOWED=NO but the project still failed signing. Detail: \(detail)"
        case .bundleIDUnreadable(let url):
            return "Could not read CFBundleIdentifier from \(url.lastPathComponent)/Info.plist."
        case .unsupportedProjectFormat(let url):
            return "Unsupported project format: \(url.lastPathComponent). Pick a .xcodeproj or .xcworkspace."
        case .xcodebuildUnavailable:
            return "xcodebuild is not available. Install Xcode and run `xcode-select --install`."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .compileFailed(_, _, let log):
            return "Full xcodebuild log: \(log.path)"
        case .signingRequired:
            return "Open the project in Xcode and either turn off Signing & Capabilities for the scheme, or sign in with a development team."
        case .iOSSimulatorNotSupported:
            return "Pick a different scheme on the New Run screen — one that targets iOS instead of macOS."
        default:
            return nil
        }
    }

    /// Path to the full xcodebuild log, if this failure has one. The
    /// RunSession UI uses this to render a Reveal-in-Finder button.
    var buildLogURL: URL? {
        if case .compileFailed(_, _, let log) = self {
            return log
        }
        return nil
    }
}

// MARK: - Protocol

protocol XcodeBuilding: Sendable {
    /// Build the given project and return where the `.app` lives.
    func build(
        project: URL,
        scheme: String,
        runID: UUID
    ) async throws -> BuildResult

    /// Probe `xcodebuild -showdestinations` for one scheme. Used by the
    /// goal-input form to refuse macOS-only schemes before launching a run.
    func destinations(project: URL, scheme: String) async throws -> [XcodeBuilder.Destination]
}

// MARK: - Implementation

struct XcodeBuilder: XcodeBuilding {

    private static let logger = Logger(subsystem: "com.harness.app", category: "XcodeBuilder")

    private let processRunner: any ProcessRunning
    private let toolLocator: any ToolLocating

    init(processRunner: any ProcessRunning, toolLocator: any ToolLocating) {
        self.processRunner = processRunner
        self.toolLocator = toolLocator
    }

    func build(project: URL, scheme: String, runID: UUID) async throws -> BuildResult {
        try Task.checkCancellation()

        let fm = FileManager.default
        guard fm.fileExists(atPath: project.path) else {
            throw BuildFailure.projectNotFound(project)
        }

        let tools = try await toolLocator.locateAll()
        guard let xcodebuild = tools.xcodebuild else {
            throw BuildFailure.xcodebuildUnavailable
        }

        try HarnessPaths.prepareRunDirectory(for: runID)
        let derivedData = HarnessPaths.derivedData(for: runID)
        let logPath = HarnessPaths.buildLog(for: runID)

        // Touch the log file so we can stream into it.
        fm.createFile(atPath: logPath.path, contents: Data(), attributes: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logPath) else {
            Self.logger.warning("Could not open build log for writing at \(logPath.path, privacy: .public)")
            throw BuildFailure.compileFailed(exitCode: -1, lastStderrSnippet: "log open failed", fullLogPath: logPath)
        }
        defer { try? logHandle.close() }

        let projectFlag = projectOrWorkspaceFlag(for: project)
        var arguments: [String] = projectFlag + [
            "-scheme", scheme,
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path,
            "-configuration", "Debug",
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGN_IDENTITY=",
            "CODE_SIGNING_REQUIRED=NO",
            "ONLY_ACTIVE_ARCH=YES",
            "build"
        ]

        // Suppress the obnoxious xcodebuild banner.
        arguments.append("-quiet")

        let spec = ProcessSpec(
            executable: xcodebuild,
            arguments: arguments,
            environment: [:],
            workingDirectory: project.deletingLastPathComponent(),
            standardInput: nil,
            timeout: .seconds(900) // 15 min ceiling
        )

        let started = ContinuousClock().now
        let stream = processRunner.runStreaming(spec)

        var stderrTail = Data()
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
            // Map ProcessFailure → BuildFailure.
            switch failure {
            case .nonZeroExit(let code, _, let stdoutSnippet, let stderrSnippet):
                // xcodebuild writes the "no destination" diagnostic to stdout
                // (annoyingly), so combine both streams when probing.
                let combined = (stdoutSnippet + "\n" + stderrSnippet) + Self.snippetString(stderrTail)
                let snippet = stderrSnippet.isEmpty
                    ? Self.snippetString(stderrTail)
                    : stderrSnippet
                if Self.looksLikeIOSSimulatorMissing(combined) {
                    let available = Self.parseAvailableDestinations(combined)
                    throw BuildFailure.iOSSimulatorNotSupported(scheme: scheme, availableDestinations: available)
                }
                if Self.looksLikeSigningError(snippet) {
                    throw BuildFailure.signingRequired(detail: Self.firstSigningHint(in: snippet) ?? snippet)
                }
                Self.logger.error("xcodebuild non-zero exit \(code, privacy: .public) for \(project.lastPathComponent, privacy: .public)")
                throw BuildFailure.compileFailed(
                    exitCode: code,
                    lastStderrSnippet: snippet,
                    fullLogPath: logPath
                )
            case .launchFailed(let underlying):
                Self.logger.error("xcodebuild launch failed: \(String(describing: underlying), privacy: .public)")
                throw BuildFailure.compileFailed(exitCode: -1, lastStderrSnippet: String(describing: underlying), fullLogPath: logPath)
            case .timedOut:
                throw BuildFailure.compileFailed(exitCode: -1, lastStderrSnippet: "build timed out", fullLogPath: logPath)
            case .cancelled:
                throw CancellationError()
            }
        }

        let duration = ContinuousClock().now - started

        let appBundle = try Self.locateBuiltApp(in: derivedData, scheme: scheme)
        let bundleID = try Self.readBundleIdentifier(at: appBundle)

        Self.logger.info("Build OK: \(appBundle.lastPathComponent, privacy: .public) (\(bundleID, privacy: .public))")

        return BuildResult(
            appBundle: appBundle,
            bundleIdentifier: bundleID,
            duration: duration,
            logPath: logPath
        )
    }

    // MARK: Project / workspace flag

    private func projectOrWorkspaceFlag(for url: URL) -> [String] {
        switch url.pathExtension {
        case "xcworkspace": return ["-workspace", url.path]
        case "xcodeproj":   return ["-project", url.path]
        default:
            // Will throw downstream as artifactNotFound; we accept anything here for testability.
            return ["-project", url.path]
        }
    }

    // MARK: Artifact pickup

    /// `<derivedDataPath>/Build/Products/Debug-iphonesimulator/<TargetName>.app`
    /// Per `standards/12-simulator-control.md §8`, we use deterministic path math
    /// (never `find`) and fall back to enumerating the Products dir if the scheme
    /// name diverges from the target name.
    private static func locateBuiltApp(in derivedData: URL, scheme: String) throws -> URL {
        let productsDir = derivedData
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Debug-iphonesimulator", isDirectory: true)

        let primaryGuess = productsDir.appendingPathComponent("\(scheme).app", isDirectory: true)
        if FileManager.default.fileExists(atPath: primaryGuess.path) {
            return primaryGuess
        }

        // Scheme name often differs from target name. Enumerate the products dir
        // for any .app and return the first one. Multi-app builds are rare and
        // out of scope for v1.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: productsDir.path)) ?? []
        if let firstApp = entries.first(where: { $0.hasSuffix(".app") }) {
            return productsDir.appendingPathComponent(firstApp, isDirectory: true)
        }

        throw BuildFailure.artifactNotFound(searched: productsDir)
    }

    /// Read CFBundleIdentifier from `<bundle>/Info.plist`.
    private static func readBundleIdentifier(at appBundle: URL) throws -> String {
        let plistURL = appBundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else {
            throw BuildFailure.bundleIDUnreadable(appBundle)
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else {
            throw BuildFailure.bundleIDUnreadable(appBundle)
        }
        return bundleID
    }

    // MARK: stderr tail

    private static func appendBoundedTail(_ existing: Data, _ chunk: Data, cap: Int) -> Data {
        var combined = existing
        combined.append(chunk)
        if combined.count <= cap { return combined }
        return combined.suffix(cap)
    }

    private static func snippetString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Signing-error heuristic

    private static let signingMarkers: [String] = [
        "Code signing is required",
        "No certificate signing identity",
        "requires a development team",
        "automatic signing"
    ]

    private static func looksLikeSigningError(_ text: String) -> Bool {
        signingMarkers.contains(where: { text.contains($0) })
    }

    private static func firstSigningHint(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            for marker in signingMarkers where line.contains(marker) {
                return String(line)
            }
        }
        return nil
    }

    // MARK: iOS-Simulator-missing heuristic

    /// xcodebuild emits something like:
    /// ```
    /// xcodebuild: error: Unable to find a destination matching the provided destination specifier:
    ///         { generic:1, platform:iOS Simulator }
    /// Available destinations for the "X" scheme:
    ///         { platform:macOS, ... }
    /// ```
    static func looksLikeIOSSimulatorMissing(_ text: String) -> Bool {
        text.contains("Unable to find a destination") &&
            text.contains("iOS Simulator") &&
            text.contains("Available destinations")
    }

    /// Parse out the "Available destinations" lines so we can show the user
    /// what the scheme actually supports.
    ///
    /// xcodebuild's failure log prints the *requested* destination on its
    /// own bracketed line (`{ generic:1, platform:iOS Simulator }`) before
    /// the "Available destinations for the …" header. We only collect lines
    /// AFTER that header so we don't echo the requested-but-missing iOS
    /// Simulator back at the user as if it were available.
    static func parseAvailableDestinations(_ text: String) -> [String] {
        var results: [String] = []
        var inAvailableSection = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Available destinations for") {
                inAvailableSection = true
                continue
            }
            guard inAvailableSection, line.hasPrefix("{") else { continue }
            if let value = Self.extractField("platform", from: line) {
                if !results.contains(value) {
                    results.append(value)
                }
            }
        }
        return results
    }

    fileprivate static func extractField(_ key: String, from line: String) -> String? {
        guard let range = line.range(of: "\(key):") else { return nil }
        let after = line[range.upperBound...]
        let stop = after.firstIndex(where: { $0 == "," || $0 == "}" })
        let value = stop.map { after[..<$0] } ?? after[...]
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Scheme compatibility probe

extension XcodeBuilder {

    /// A single destination row from `xcodebuild -showdestinations`.
    struct Destination: Sendable, Hashable {
        let platform: String
        let arch: String?
        let name: String?

        var supportsIOSSimulator: Bool {
            platform == "iOS Simulator"
        }
    }

    /// Run `xcodebuild -showdestinations -scheme <X>` and parse the destinations.
    /// Throws if `xcodebuild` isn't available; returns an empty array if the
    /// command runs but produces no parseable destination rows.
    func destinations(project: URL, scheme: String) async throws -> [Destination] {
        try Task.checkCancellation()

        let tools = try await toolLocator.locateAll()
        guard let xcodebuild = tools.xcodebuild else {
            throw BuildFailure.xcodebuildUnavailable
        }

        let projectFlag = projectOrWorkspaceFlag(for: project)
        let spec = ProcessSpec(
            executable: xcodebuild,
            arguments: projectFlag + [
                "-scheme", scheme,
                "-showdestinations"
            ],
            workingDirectory: project.deletingLastPathComponent(),
            timeout: .seconds(30)
        )

        do {
            let result = try await processRunner.run(spec)
            return Self.parseDestinations(result.stdoutString + "\n" + result.stderrString)
        } catch ProcessFailure.nonZeroExit(_, _, let so, let se) {
            // showdestinations may print to stdout even on non-zero exit codes.
            let combined = so + "\n" + se
            return Self.parseDestinations(combined)
        }
    }

    /// Parse `xcodebuild -showdestinations` output into typed rows.
    static func parseDestinations(_ text: String) -> [Destination] {
        var results: [Destination] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), line.contains("platform:") else { continue }
            let platform = extractField("platform", from: line) ?? ""
            let arch = extractField("arch", from: line)
            let name = extractField("name", from: line)
            guard !platform.isEmpty else { continue }
            results.append(Destination(platform: platform, arch: arch, name: name))
        }
        // Dedupe by platform+name (per-arch rows are noise for the picker).
        var seen = Set<String>()
        return results.filter {
            let key = "\($0.platform)|\($0.name ?? "")"
            return seen.insert(key).inserted
        }
    }
}
