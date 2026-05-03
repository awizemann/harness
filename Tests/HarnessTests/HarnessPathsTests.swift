//
//  HarnessPathsTests.swift
//  HarnessTests
//
//  Verifies the per-run path math is deterministic and the run directory tree
//  pre-creates without error. Per `standards/03-subprocess-and-filesystem.md §6`,
//  this is the one place these paths are derived; if it drifts, every service breaks.
//

import Testing
import Foundation
@testable import Harness

@Suite("HarnessPaths")
struct HarnessPathsTests {

    @Test("App support root resolves under Library/Application Support/Harness")
    func appSupportPath() {
        let path = HarnessPaths.appSupport.path
        #expect(path.hasSuffix("/Library/Application Support/Harness"))
    }

    @Test("Run-id derived paths are deterministic and well-formed")
    func runIDDerivedPaths() {
        let id = UUID()
        let runDir = HarnessPaths.runDir(for: id)
        #expect(runDir.lastPathComponent == id.uuidString)

        let events = HarnessPaths.eventsLog(for: id)
        #expect(events.lastPathComponent == "events.jsonl")
        #expect(events.deletingLastPathComponent() == runDir)

        let meta = HarnessPaths.metaFile(for: id)
        #expect(meta.lastPathComponent == "meta.json")

        let step17 = HarnessPaths.screenshot(for: id, step: 17)
        #expect(step17.lastPathComponent == "step-017.png")

        let step1 = HarnessPaths.screenshot(for: id, step: 1)
        #expect(step1.lastPathComponent == "step-001.png")

        let step999 = HarnessPaths.screenshot(for: id, step: 999)
        #expect(step999.lastPathComponent == "step-999.png")

        let derived = HarnessPaths.derivedData(for: id)
        #expect(derived.lastPathComponent == "DerivedData-\(id.uuidString)")
        #expect(derived.deletingLastPathComponent().lastPathComponent == "build")
    }

    @Test("prepareRunDirectory creates the tree idempotently")
    func prepareIdempotent() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: HarnessPaths.runDir(for: id)) }

        try HarnessPaths.prepareRunDirectory(for: id)
        try HarnessPaths.prepareRunDirectory(for: id)  // again — must not throw

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: HarnessPaths.runDir(for: id).path))
        #expect(fm.fileExists(atPath: HarnessPaths.buildDir(for: id).path))
        #expect(fm.fileExists(atPath: HarnessPaths.derivedData(for: id).path))
    }

    @Test("ensureDirectory tolerates already-exists")
    func ensureDirectoryIdempotent() throws {
        let id = UUID()
        let path = HarnessPaths.runDir(for: id)
        defer { try? FileManager.default.removeItem(at: path) }

        try HarnessPaths.ensureDirectory(path)
        try HarnessPaths.ensureDirectory(path)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}
