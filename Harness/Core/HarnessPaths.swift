//
//  HarnessPaths.swift
//  Harness
//
//  Centralized filesystem path constants. Per `standards/03-subprocess-and-filesystem.md`,
//  no other file in the app should hard-code `~/Library/Application Support/Harness`.
//
//  Also resolves the per-run subdirectories deterministically: every UUID maps to
//  exactly one path, and screenshot / events.jsonl / DerivedData / meta.json paths
//  are derived from that single root.
//

import Foundation

enum HarnessPaths {

    // MARK: Roots

    /// `~/Library/Application Support/Harness/`. Created on first access.
    /// Force-tries because Application Support always resolves on macOS, and
    /// `create: true` is itself idempotent. A failure here means the user's
    /// home directory is unwritable — there's no graceful path forward.
    static let appSupport: URL = {
        let fm = FileManager.default
        let root = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent("Harness", isDirectory: true)
    }()

    /// `<App Support>/Harness/runs/`
    static var runsDir: URL { appSupport.appendingPathComponent("runs", isDirectory: true) }

    /// `<App Support>/Harness/settings.json`
    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }

    /// `<App Support>/Harness/tools.json`
    static var toolsCacheFile: URL { appSupport.appendingPathComponent("tools.json") }

    // MARK: Per-run paths

    /// `<App Support>/Harness/runs/<run-id>/`
    static func runDir(for runID: UUID) -> URL {
        runsDir.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    /// `<run-dir>/events.jsonl`
    static func eventsLog(for runID: UUID) -> URL {
        runDir(for: runID).appendingPathComponent("events.jsonl")
    }

    /// `<run-dir>/meta.json`
    static func metaFile(for runID: UUID) -> URL {
        runDir(for: runID).appendingPathComponent("meta.json")
    }

    /// `<run-dir>/step-NNN.png`. Step is zero-padded to 3 digits.
    static func screenshot(for runID: UUID, step: Int) -> URL {
        let name = String(format: "step-%03d.png", step)
        return runDir(for: runID).appendingPathComponent(name)
    }

    /// `<run-dir>/build/`
    static func buildDir(for runID: UUID) -> URL {
        runDir(for: runID).appendingPathComponent("build", isDirectory: true)
    }

    /// `<run-dir>/build/DerivedData-<run-id>/` — passed to `xcodebuild -derivedDataPath`.
    static func derivedData(for runID: UUID) -> URL {
        buildDir(for: runID).appendingPathComponent("DerivedData-\(runID.uuidString)", isDirectory: true)
    }

    /// `<run-dir>/build/build.log` — full xcodebuild stdout/stderr stream.
    static func buildLog(for runID: UUID) -> URL {
        buildDir(for: runID).appendingPathComponent("build.log")
    }

    // MARK: Helpers

    /// Ensures the directory at `url` exists. `withIntermediateDirectories: true`
    /// is idempotent — already-exists is a no-op.
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Pre-creates the per-run directory tree (run-dir, build/, DerivedData/).
    /// Call this once at run start before any subprocess writes here.
    static func prepareRunDirectory(for runID: UUID) throws {
        try ensureDirectory(runDir(for: runID))
        try ensureDirectory(buildDir(for: runID))
        try ensureDirectory(derivedData(for: runID))
    }
}
