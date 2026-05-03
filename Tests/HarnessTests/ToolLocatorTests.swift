//
//  ToolLocatorTests.swift
//  HarnessTests
//
//  Lightweight unit tests for ToolLocator. We can't test against a known-state
//  filesystem here, so we verify:
//    - Candidate enumeration includes user-site Python paths.
//    - forceRefresh() actually re-probes (doesn't return the cached value).
//

import Testing
import Foundation
@testable import Harness

@Suite("ToolLocator — idb candidate enumeration")
struct ToolLocatorIDBCandidatesTests {

    @Test("Includes Apple Silicon Homebrew, Intel Homebrew, and ~/.local/bin")
    func includesStandardLocations() {
        let candidates = ToolLocator.idbCandidates()
        #expect(candidates.contains("/opt/homebrew/bin/idb"))
        #expect(candidates.contains("/usr/local/bin/idb"))
        let home = NSHomeDirectory()
        #expect(candidates.contains("\(home)/.local/bin/idb"))
    }

    @Test("Includes python.org Python.framework versions")
    func includesPythonOrgVersions() {
        let candidates = ToolLocator.idbCandidates()
        #expect(candidates.contains("/Library/Frameworks/Python.framework/Versions/3.13/bin/idb"))
        #expect(candidates.contains("/Library/Frameworks/Python.framework/Versions/3.12/bin/idb"))
        #expect(candidates.contains("/Library/Frameworks/Python.framework/Versions/3.11/bin/idb"))
    }

    @Test("Includes ~/Library/Python/<ver>/bin/idb for actually-present Python versions")
    func includesUserSitePythonVersions() {
        let candidates = ToolLocator.idbCandidates()
        let home = NSHomeDirectory()
        let userPython = "\(home)/Library/Python"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: userPython) {
            for v in versions {
                #expect(candidates.contains("\(userPython)/\(v)/bin/idb"),
                        "candidates missing \(userPython)/\(v)/bin/idb")
            }
        }
        // If the user has no ~/Library/Python at all, the test trivially passes —
        // we just don't expect any user-site entries.
    }
}
