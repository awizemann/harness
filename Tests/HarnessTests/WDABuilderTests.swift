//
//  WDABuilderTests.swift
//  HarnessTests
//
//  Pure-helper tests for WDABuilder. The xcodebuild path itself is exercised
//  by the manual smoke test plan — building WebDriverAgent on every CI run
//  would burn ~2 minutes of wall clock for no real coverage gain, since the
//  `xcodebuild` invocation shape is verified by `WDABuilderInvocationTests`
//  via a fake ProcessRunner.
//

import Testing
import Foundation
@testable import Harness

@Suite("WDABuilder — iOS version key normalization")
struct WDABuilderVersionKeyTests {

    @Test("Humanized 'iOS 18.4' becomes '18.4'")
    func humanizedSpaceForm() {
        #expect(WDABuilder.iosVersionKey(from: "iOS 18.4") == "18.4")
    }

    @Test("Hyphenated 'iOS-18-4' becomes '18.4'")
    func hyphenatedRuntimeForm() {
        #expect(WDABuilder.iosVersionKey(from: "iOS-18-4") == "18.4")
    }

    @Test("Already clean '18.4' passes through")
    func alreadyClean() {
        #expect(WDABuilder.iosVersionKey(from: "18.4") == "18.4")
    }

    @Test("Three-component '18.4.1' passes through")
    func threeComponent() {
        #expect(WDABuilder.iosVersionKey(from: "18.4.1") == "18.4.1")
    }

    @Test("Empty input falls back to 'unknown'")
    func emptyFallback() {
        #expect(WDABuilder.iosVersionKey(from: "") == "unknown")
    }

    @Test("Whitespace-only input falls back to 'unknown'")
    func whitespaceFallback() {
        #expect(WDABuilder.iosVersionKey(from: "   ") == "unknown")
    }
}

@Suite("WDABuilder — xctestrun discovery")
struct WDABuilderXCTestRunDiscoveryTests {

    @Test("Finds the .xctestrun under Build/Products")
    func findsXCTestRun() throws {
        let tmp = try TempDir()
        let products = tmp.url
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)

        let xctestrun = products.appendingPathComponent("WebDriverAgentRunner_iphonesimulator26.2-arm64.xctestrun")
        try Data().write(to: xctestrun)

        let found = try WDABuilder.findXCTestRun(in: tmp.url)
        #expect(found.lastPathComponent.hasSuffix(".xctestrun"))
    }

    @Test("Throws xctestrunNotFound when Products is empty")
    func throwsWhenMissing() throws {
        let tmp = try TempDir()
        let products = tmp.url
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)

        do {
            _ = try WDABuilder.findXCTestRun(in: tmp.url)
            Issue.record("expected throw")
        } catch WDABuildFailure.xctestrunNotFound {
            // OK
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

@Suite("HarnessPaths — WDA cache directories")
struct HarnessPathsWDATests {

    @Test("wdaRoot is under appSupport")
    func wdaRootShape() {
        let root = HarnessPaths.wdaRoot
        #expect(root.lastPathComponent == "wda-build")
        #expect(root.deletingLastPathComponent().path == HarnessPaths.appSupport.path)
    }

    @Test("Per-version dir embeds the iOS key")
    func perVersionDir() {
        let dir = HarnessPaths.wdaBuildDir(forIOSVersion: "18.4")
        #expect(dir.lastPathComponent == "iOS-18.4")
    }
}

// MARK: - Tiny test helper (test-only)

private struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-wda-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
