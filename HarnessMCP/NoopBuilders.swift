//
//  NoopBuilders.swift
//  HarnessMCP
//
//  No-op `XcodeBuilding` and `SimulatorDriving` implementations for the
//  web / macOS run paths. `RunCoordinator` and `PlatformAdapterServices`
//  keep these as required slots so the iOS code path compiles — the web
//  and macOS paths never invoke them.
//
//  Verbatim sibling of `HarnessCLI/NoopBuilders.swift`; each dev-time tool
//  target keeps its own copy so it stays self-contained. Any unexpected
//  call returns a synthesized error rather than silently no-op-ing — if a
//  web run ever started routing through one of these slots, we want the
//  failure mode loud.
//

import AppKit
import CoreGraphics
import Foundation

enum NoopUseError: Error, LocalizedError {
    case notReachable(callsite: String)

    var errorDescription: String? {
        switch self {
        case .notReachable(let callsite):
            return "HarnessMCP noop fake reached \(callsite) — this slot should never be invoked on a web/macOS run. File a bug."
        }
    }
}

struct NoopXcodeBuilder: XcodeBuilding {
    func build(project: URL, scheme: String, runID: UUID) async throws -> BuildResult {
        throw NoopUseError.notReachable(callsite: "NoopXcodeBuilder.build")
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
        throw NoopUseError.notReachable(callsite: "NoopSimulatorDriver.screenshot")
    }

    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage {
        throw NoopUseError.notReachable(callsite: "NoopSimulatorDriver.screenshotImage")
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
        throw NoopUseError.notReachable(callsite: "NoopSimulatorDriver.tapMark")
    }
}
