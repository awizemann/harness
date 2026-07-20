//
//  WDASourceResolutionTests.swift
//  HarnessTests
//
//  Pins WebDriverAgent-source resolution for the standalone / relocatable
//  `harness-mcp` binary. Precedence is `HARNESS_WDA_PATH` → bundled copy →
//  `<repoRoot>/vendor/WebDriverAgent`, and when nothing resolves the iOS
//  session start must surface a clear, actionable `UISessionError` (never a
//  wedge or a bogus `/dev/null` handed to `WDABuilder`). The pure
//  `resolveWDASource(...)` is fully injected so precedence + env validation are
//  deterministic; the `resolvedWDASource(environment:)` wrapper is exercised
//  against a real temp checkout for the env override path.
//

import Testing
import Foundation
@testable import Harness

@Suite("WDA source resolution — precedence")
struct WDASourceResolutionTests {

    private let bundle = URL(fileURLWithPath: "/Bundle/Resources", isDirectory: true)
    private let repo = URL(fileURLWithPath: "/Repo/Root", isDirectory: true)
    private let envDir = URL(fileURLWithPath: "/Custom/WDA", isDirectory: true)

    private var expectedBundleWDA: String { bundle.appendingPathComponent("WebDriverAgent", isDirectory: true).path }

    @Test("env override wins over a valid bundle AND a repo checkout")
    func envWins() {
        let r = HarnessPaths.resolveWDASource(
            envPath: envDir.path,
            bundleResourceURL: bundle,
            repoRoot: repo,
            projectExists: { _ in true }   // every candidate would validate
        )
        #expect(r == .resolved(envDir))
    }

    @Test("env set but invalid → envInvalid, NOT a silent fall-through")
    func envInvalidDoesNotFallThrough() {
        // The bundle would validate, but a set-but-broken env is a loud
        // misconfiguration we must surface — not mask by using the bundle.
        let r = HarnessPaths.resolveWDASource(
            envPath: envDir.path,
            bundleResourceURL: bundle,
            repoRoot: repo,
            projectExists: { url in url.path != self.envDir.path }  // env fails, others pass
        )
        #expect(r == .envInvalid(envDir.path))
    }

    @Test("env path is tilde-expanded before probing")
    func envTildeExpanded() {
        var probed: [String] = []
        let r = HarnessPaths.resolveWDASource(
            envPath: "~/wda-checkout",
            bundleResourceURL: nil,
            repoRoot: nil,
            projectExists: { url in probed.append(url.path); return true }
        )
        let expected = ("~/wda-checkout" as NSString).expandingTildeInPath
        guard case .resolved(let url) = r else {
            Issue.record("expected .resolved, got \(r)")
            return
        }
        #expect(url.path == expected)
        #expect(probed.first == expected)
        #expect(probed.first?.hasPrefix("~") == false)   // literal ~ was expanded
    }

    @Test("empty / whitespace env is treated as unset")
    func blankEnvIsUnset() {
        for blank in ["", "   ", "\n", "\t "] {
            let r = HarnessPaths.resolveWDASource(
                envPath: blank,
                bundleResourceURL: bundle,
                repoRoot: repo,
                projectExists: { $0.path == self.expectedBundleWDA }
            )
            #expect(r == .resolved(bundle.appendingPathComponent("WebDriverAgent", isDirectory: true)))
        }
    }

    @Test("no env, valid bundle → bundle wins over repo")
    func bundleWinsOverRepo() {
        let r = HarnessPaths.resolveWDASource(
            envPath: nil,
            bundleResourceURL: bundle,
            repoRoot: repo,
            projectExists: { $0.path == self.expectedBundleWDA }  // only bundle validates
        )
        #expect(r == .resolved(bundle.appendingPathComponent("WebDriverAgent", isDirectory: true)))
    }

    @Test("no env, invalid bundle, repo present → repo (returned UNVALIDATED)")
    func repoFallbackUnvalidated() {
        // projectExists is always false — the repo candidate must still be
        // returned so an uninitialised submodule reaches WDABuilder's
        // submodule-specific guidance rather than a generic error here.
        let r = HarnessPaths.resolveWDASource(
            envPath: nil,
            bundleResourceURL: bundle,
            repoRoot: repo,
            projectExists: { _ in false }
        )
        #expect(r == .resolved(repo.appendingPathComponent("vendor/WebDriverAgent", isDirectory: true)))
    }

    @Test("no env, no bundle, repo present → repo")
    func repoOnly() {
        let r = HarnessPaths.resolveWDASource(
            envPath: nil,
            bundleResourceURL: nil,
            repoRoot: repo,
            projectExists: { _ in false }
        )
        #expect(r == .resolved(repo.appendingPathComponent("vendor/WebDriverAgent", isDirectory: true)))
    }

    @Test("nothing to try (standalone/relocated) → unresolved")
    func unresolved() {
        let r = HarnessPaths.resolveWDASource(
            envPath: nil,
            bundleResourceURL: nil,
            repoRoot: nil,
            projectExists: { _ in false }
        )
        #expect(r == .unresolved)
    }

    @Test("nil env, bundle present but no repo, bundle invalid → unresolved")
    func bundleInvalidNoRepo() {
        let r = HarnessPaths.resolveWDASource(
            envPath: nil,
            bundleResourceURL: bundle,
            repoRoot: nil,
            projectExists: { _ in false }
        )
        #expect(r == .unresolved)
    }
}

@Suite("WDA source resolution — live env wrapper")
struct WDASourceResolvedWrapperTests {

    /// The env var name is the documented contract with the consuming product.
    @Test("env var name is HARNESS_WDA_PATH")
    func envVarName() {
        #expect(HarnessPaths.wdaSourceEnvVar == "HARNESS_WDA_PATH")
    }

    @Test("valid HARNESS_WDA_PATH (real checkout) resolves to that directory")
    func envOverrideResolves() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wda-src-\(UUID().uuidString)", isDirectory: true)
        let proj = tmp.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = try HarnessPaths.resolvedWDASource(
            environment: [HarnessPaths.wdaSourceEnvVar: tmp.path]
        )
        #expect(resolved.path == tmp.path)
    }

    @Test("HARNESS_WDA_PATH without a WebDriverAgent.xcodeproj throws wdaEnvPathInvalid")
    func envOverrideInvalidThrows() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("no-wda-\(UUID().uuidString)", isDirectory: true)
        // Deliberately not created — no WebDriverAgent.xcodeproj inside.
        do {
            _ = try HarnessPaths.resolvedWDASource(
                environment: [HarnessPaths.wdaSourceEnvVar: bogus.path]
            )
            Issue.record("expected resolvedWDASource to throw for an invalid env path")
        } catch let error as UISessionError {
            guard case .wdaEnvPathInvalid(let path) = error else {
                Issue.record("expected .wdaEnvPathInvalid, got \(error)")
                return
            }
            #expect(path == bogus.path)
        } catch {
            Issue.record("expected UISessionError, got \(error)")
        }
    }
}

@Suite("iOS degradation — error copy")
struct IOSDegradationErrorTests {

    @Test("xcodeToolingUnavailable names the missing tool and reassures about web")
    func xcodeToolingCopy() {
        let msg = UISessionError.xcodeToolingUnavailable([.xcodebuild]).errorDescription ?? ""
        #expect(msg.contains("xcodebuild"))
        #expect(msg.contains("Web sessions work without it"))
        // Points at the two real fixes: install Xcode / point DEVELOPER_DIR.
        #expect(msg.contains("DEVELOPER_DIR"))
    }

    @Test("xcodeToolingUnavailable lists every missing tool by display name")
    func xcodeToolingListsAll() {
        let msg = UISessionError.xcodeToolingUnavailable([.xcrun, .xcodebuild]).errorDescription ?? ""
        #expect(msg.contains("xcrun"))
        #expect(msg.contains("xcodebuild"))
    }

    @Test("wdaSourceUnresolved tells the operator to set HARNESS_WDA_PATH")
    func wdaUnresolvedCopy() {
        let msg = UISessionError.wdaSourceUnresolved.errorDescription ?? ""
        #expect(msg.contains(HarnessPaths.wdaSourceEnvVar))
        #expect(msg.contains("WebDriverAgent.xcodeproj"))
    }

    @Test("wdaEnvPathInvalid echoes the bad path and the env var")
    func wdaEnvInvalidCopy() {
        let msg = UISessionError.wdaEnvPathInvalid("/tmp/wrong").errorDescription ?? ""
        #expect(msg.contains("/tmp/wrong"))
        #expect(msg.contains(HarnessPaths.wdaSourceEnvVar))
    }
}
