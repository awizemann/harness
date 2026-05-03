//
//  ToolLocatorTests.swift
//  HarnessTests
//
//  Smoke test for the tool locator. As of Phase 5 (idb→WDA migration), the
//  only required external CLIs are xcrun and xcodebuild — both Apple-supplied
//  — so the locator's job is much narrower than before. This test just
//  verifies the public surface is reachable; deeper PATH-discovery work is
//  exercised by the existing ProcessRunner tests against real binaries.
//

import Testing
import Foundation
@testable import Harness

@Suite("ToolLocator — public surface")
struct ToolLocatorPublicSurfaceTests {

    @Test("Tool enum has the three remaining cases")
    func toolEnumShape() {
        let cases = Set(Tool.allCases.map(\.rawValue))
        #expect(cases == ["xcrun", "xcodebuild", "brew"])
    }

    @Test("ToolPaths.allMissing reports xcrun + xcodebuild but not brew")
    func allMissingExcludesBrew() {
        let paths = ToolPaths(xcrun: nil, xcodebuild: nil, brew: nil)
        let missing = Set(paths.allMissing.map(\.rawValue))
        #expect(missing == ["xcrun", "xcodebuild"])
    }
}
