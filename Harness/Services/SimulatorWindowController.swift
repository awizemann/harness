//
//  SimulatorWindowController.swift
//  Harness
//
//  Hide / unhide the iOS Simulator's macOS window. Harness's mirror is the
//  user's window into the running app — keeping Simulator.app visible
//  alongside is just visual noise (and tempting them to click it, which
//  bypasses our event log).
//
//  The simulator process keeps running — we only hide the AppKit window.
//  WDA inside the simulator is unaffected; `simctl screenshot` keeps
//  working; everything off-screen.
//

import Foundation
import AppKit

protocol SimulatorWindowControlling: Sendable {
    func hide() async
    func unhide() async
}

struct SimulatorWindowController: SimulatorWindowControlling {

    /// Bundle identifier of `Simulator.app`.
    static let bundleID = "com.apple.iphonesimulator"

    func hide() async {
        await MainActor.run {
            for app in NSWorkspace.shared.runningApplications
                where app.bundleIdentifier == Self.bundleID {
                _ = app.hide()
            }
        }
    }

    func unhide() async {
        await MainActor.run {
            for app in NSWorkspace.shared.runningApplications
                where app.bundleIdentifier == Self.bundleID {
                _ = app.unhide()
            }
        }
    }
}

/// No-op window controller for tests / contexts that don't want to touch
/// the running Simulator.app. The default `RunCoordinator.windowController`.
struct NoopWindowController: SimulatorWindowControlling {
    func hide() async {}
    func unhide() async {}
}
