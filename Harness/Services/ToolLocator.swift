//
//  ToolLocator.swift
//  Harness
//
//  Resolves paths for the external CLIs Harness depends on. Per
//  `standards/03-subprocess-and-filesystem.md §4`, all tool discovery happens
//  here; service code receives resolved URLs and never `which`s its own.
//
//  Strategy: probe canonical install locations in order, fall back to
//  `which`/`xcrun --find`. Cache results to disk so we don't re-resolve every
//  app launch (~50ms saved). Surface missing tools as actionable errors with
//  the exact `brew install` command users need.
//

import Foundation
import os

/// Snapshot of resolved tool locations.
struct ToolPaths: Sendable, Codable, Hashable {
    let xcrun: URL?
    let xcodebuild: URL?
    let idb: URL?
    let idbCompanion: URL?
    let brew: URL?

    var allMissing: [Tool] {
        var missing: [Tool] = []
        if xcrun == nil { missing.append(.xcrun) }
        if xcodebuild == nil { missing.append(.xcodebuild) }
        if idb == nil { missing.append(.idb) }
        if idbCompanion == nil { missing.append(.idbCompanion) }
        // brew is optional — only used to surface install commands. Don't gate on it.
        return missing
    }
}

enum Tool: String, Sendable, Hashable, CaseIterable {
    case xcrun, xcodebuild, idb, idbCompanion, brew

    /// User-facing display name.
    var displayName: String {
        switch self {
        case .xcrun: return "xcrun"
        case .xcodebuild: return "xcodebuild"
        case .idb: return "idb"
        case .idbCompanion: return "idb_companion"
        case .brew: return "Homebrew"
        }
    }

    /// Suggested install command shown to the user when missing.
    var installCommand: String {
        switch self {
        case .xcrun, .xcodebuild:
            return "Install Xcode from the App Store, then run: xcode-select --install"
        case .idb:
            return "brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb"
        case .idbCompanion:
            return "brew tap facebook/fb && brew install idb-companion"
        case .brew:
            return "Install Homebrew from https://brew.sh"
        }
    }
}

protocol ToolLocating: Sendable {
    func locateAll() async throws -> ToolPaths
    func resolved() async -> ToolPaths?
}

actor ToolLocator: ToolLocating {

    private static let logger = Logger(subsystem: "com.harness.app", category: "ToolLocator")

    private let processRunner: any ProcessRunning
    private var cached: ToolPaths?

    init(processRunner: any ProcessRunning) {
        self.processRunner = processRunner
    }

    func resolved() -> ToolPaths? { cached }

    func locateAll() async throws -> ToolPaths {
        if let cached, isCacheFresh(cached) {
            return cached
        }

        // Probe each tool. Order of candidates matters — Apple Silicon Homebrew
        // (`/opt/homebrew/bin`) before Intel Homebrew (`/usr/local/bin`).
        async let xcrun = locate(.xcrun, candidates: ["/usr/bin/xcrun"])
        async let xcodebuild = locateViaXcrun(.xcodebuild)
        async let idb = locate(.idb, candidates: [
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/idb",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/idb"
        ])
        async let idbCompanion = locate(.idbCompanion, candidates: [
            "/opt/homebrew/bin/idb_companion",
            "/usr/local/bin/idb_companion"
        ])
        async let brew = locate(.brew, candidates: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ])

        let paths = ToolPaths(
            xcrun: await xcrun,
            xcodebuild: await xcodebuild,
            idb: await idb,
            idbCompanion: await idbCompanion,
            brew: await brew
        )
        cached = paths
        try? persist(paths)
        Self.logger.info("Tools resolved. Missing: \(paths.allMissing.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        return paths
    }

    // MARK: Private

    private func locate(_ tool: Tool, candidates: [String]) async -> URL? {
        let fm = FileManager.default
        for candidate in candidates {
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        // Last-resort: `/usr/bin/which`. Honor the user's PATH at app launch.
        return await whichOnPath(tool.rawValue)
    }

    private func locateViaXcrun(_ tool: Tool) async -> URL? {
        guard let xcrun = await locate(.xcrun, candidates: ["/usr/bin/xcrun"]) else { return nil }
        let spec = ProcessSpec(
            executable: xcrun,
            arguments: ["--find", tool.rawValue],
            timeout: .seconds(5)
        )
        do {
            let result = try await processRunner.run(spec)
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    private func whichOnPath(_ name: String) async -> URL? {
        let spec = ProcessSpec(
            executable: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [name],
            timeout: .seconds(2)
        )
        do {
            let result = try await processRunner.run(spec)
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    // MARK: Cache

    /// Cache validity window: 12 hours. Tool paths rarely change; even rarer in-session.
    private static let cacheTTL: TimeInterval = 12 * 60 * 60

    private func isCacheFresh(_: ToolPaths) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: HarnessPaths.toolsCacheFile.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(mtime) < Self.cacheTTL
    }

    private func persist(_ paths: ToolPaths) throws {
        try HarnessPaths.ensureDirectory(HarnessPaths.appSupport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(paths)
        try data.write(to: HarnessPaths.toolsCacheFile, options: [.atomic])
    }
}
