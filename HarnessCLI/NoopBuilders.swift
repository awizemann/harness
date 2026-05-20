//
//  NoopBuilders.swift
//  HarnessCLI
//
//  No-op `XcodeBuilding` and `SimulatorDriving` implementations for the
//  web-only CLI. `RunCoordinator` and `PlatformAdapterServices` keep
//  these as required slots so the iOS / macOS code paths compile —
//  the web path never invokes them.
//
//  Live in the CLI target rather than `Tests/HarnessTests/Mocks/`
//  because the test fakes use `@testable import Harness` and aren't
//  reachable from a non-test target.
//
//  Any unexpected call here returns a synthesized error rather than
//  silently no-op-ing: if RunCoordinator ever started routing a web
//  run through one of these, we want the failure mode loud.
//

import AppKit
import CoreGraphics
import Foundation

enum NoopUseError: Error, LocalizedError {
    case notReachableOnWeb(callsite: String)

    var errorDescription: String? {
        switch self {
        case .notReachableOnWeb(let callsite):
            return "HarnessCLI noop fake reached \(callsite) — this slot should never be invoked on a web-only run. File a bug."
        }
    }
}

struct NoopXcodeBuilder: XcodeBuilding {
    func build(project: URL, scheme: String, runID: UUID) async throws -> BuildResult {
        throw NoopUseError.notReachableOnWeb(callsite: "NoopXcodeBuilder.build")
    }

    func destinations(project: URL, scheme: String) async throws -> [XcodeBuilder.Destination] {
        []
    }
}

struct NoopSimulatorDriver: SimulatorDriving {
    func listDevices() async throws -> [SimulatorRef] { [] }
    func boot(_ ref: SimulatorRef) async throws {}
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws {}
    func launch(bundleID: String, on ref: SimulatorRef) async throws {}
    func terminate(bundleID: String, on ref: SimulatorRef) async throws {}
    func erase(_ ref: SimulatorRef) async throws {}

    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL {
        throw NoopUseError.notReachableOnWeb(callsite: "NoopSimulatorDriver.screenshot")
    }

    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage {
        throw NoopUseError.notReachableOnWeb(callsite: "NoopSimulatorDriver.screenshotImage")
    }

    func tap(at point: CGPoint, on ref: SimulatorRef) async throws {}
    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws {}
    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws {}
    func type(_ text: String, on ref: SimulatorRef) async throws {}
    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws {}

    func startInputSession(_ ref: SimulatorRef) async throws {}
    func endInputSession() async {}
    func cleanupWDA(udid: String) async {}
    func probeInteractiveElements(_ ref: SimulatorRef) async -> [InteractiveMark] { [] }
    func tapMark(id: Int, on ref: SimulatorRef) async throws {
        throw NoopUseError.notReachableOnWeb(callsite: "NoopSimulatorDriver.tapMark")
    }
}
