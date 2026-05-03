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
//  As of Phase 5 (idb→WDA migration), the only required external CLIs are
//  `xcrun` and `xcodebuild` — Apple-supplied. WebDriverAgent is built
//  in-tree from the `vendor/WebDriverAgent` submodule and managed by
//  `WDABuilder`, not surfaced through the locator.
//

import Foundation
import os

/// Snapshot of resolved tool locations.
struct ToolPaths: Sendable, Codable, Hashable {
    let xcrun: URL?
    let xcodebuild: URL?
    let brew: URL?

    var allMissing: [Tool] {
        var missing: [Tool] = []
        if xcrun == nil { missing.append(.xcrun) }
        if xcodebuild == nil { missing.append(.xcodebuild) }
        // brew is optional — only used to surface install commands. Don't gate on it.
        return missing
    }
}

enum Tool: String, Sendable, Hashable, CaseIterable {
    case xcrun, xcodebuild, brew

    /// User-facing display name.
    var displayName: String {
        switch self {
        case .xcrun: return "xcrun"
        case .xcodebuild: return "xcodebuild"
        case .brew: return "Homebrew"
        }
    }

    /// Suggested install command shown to the user when missing.
    var installCommand: String {
        switch self {
        case .xcrun, .xcodebuild:
            return "Install Xcode from the App Store, then run: xcode-select --install"
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
        async let xcrun = locate(.xcrun, candidates: ["/usr/bin/xcrun"])
        async let xcodebuild = locateViaXcrun(.xcodebuild)
        async let brew = locate(.brew, candidates: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ])

        let paths = ToolPaths(
            xcrun: await xcrun,
            xcodebuild: await xcodebuild,
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
        // Apps launched from Finder inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
        // — they don't see Homebrew or pipx. Enrich PATH with the locations
        // where shell-installed binaries commonly live so `which` can still
        // find them.
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
