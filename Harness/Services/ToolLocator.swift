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
    /// Bypass the in-memory cache and re-probe every candidate. The first-run
    /// wizard's "Re-check" and Settings's "Re-detect tools" call this so the
    /// user gets up-to-date results after installing missing tools.
    func forceRefresh() async throws -> ToolPaths
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
        return try await probeAll()
    }

    func forceRefresh() async throws -> ToolPaths {
        cached = nil
        return try await probeAll()
    }

    /// Re-probe every candidate. Cheap (sub-10ms) — no shell-out unless the
    /// `xcrun --find` fallback path is taken for xcodebuild.
    private func probeAll() async throws -> ToolPaths {
        // Order of candidates matters — Apple Silicon Homebrew
        // (`/opt/homebrew/bin`) before Intel Homebrew (`/usr/local/bin`).
        // For `idb` we also enumerate user-site Python directories because
        // `pip3 install fb-idb` lands the CLI in `~/Library/Python/<ver>/bin/idb`
        // by default on Apple's bundled Python (PEP 668 user-install path).
        async let xcrun = locate(.xcrun, candidates: ["/usr/bin/xcrun"])
        async let xcodebuild = locateViaXcrun(.xcodebuild)
        async let idb = locate(.idb, candidates: Self.idbCandidates())
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

    /// All probable filesystem locations for the `idb` Python CLI.
    /// - `/opt/homebrew/bin/idb` — Apple Silicon Homebrew Python or pipx symlink.
    /// - `/usr/local/bin/idb` — Intel Homebrew or older system pip install.
    /// - `~/.local/bin/idb` — pipx default user install.
    /// - `~/Library/Python/<ver>/bin/idb` — Apple's system Python user-install
    ///   (where `pip3 install fb-idb` lands by default).
    /// - `/Library/Frameworks/Python.framework/Versions/<ver>/bin/idb` — official
    ///   python.org installer.
    nonisolated static func idbCandidates() -> [String] {
        var paths: [String] = [
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb"
        ]
        let home = NSHomeDirectory()
        paths.append("\(home)/.local/bin/idb")

        let userPython = "\(home)/Library/Python"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: userPython) {
            for v in versions {
                paths.append("\(userPython)/\(v)/bin/idb")
            }
        }
        // python.org versions in canonical order — newer first.
        for v in ["3.13", "3.12", "3.11", "3.10", "3.9"] {
            paths.append("/Library/Frameworks/Python.framework/Versions/\(v)/bin/idb")
        }
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
        // Apps launched from Finder inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
        // — they don't see Homebrew, pipx, or user-site Python. We enrich PATH
        // with the locations where the missing tools commonly live, so `which`
        // can still find shell-installed binaries.
        let home = NSHomeDirectory()
        let enrichedPath = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")

        let spec = ProcessSpec(
            executable: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [name],
            environment: ["PATH": enrichedPath, "HOME": home],
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
