//
//  UXDriving.swift
//  Harness
//
//  The platform-neutral driver protocol. Every `PlatformAdapter` produces a
//  `UXDriving` for the run; `RunCoordinator`'s per-step loop talks to the
//  driver and never to a platform-specific service directly.
//
//  Coordinate-space contract: the agent ALWAYS speaks in the screenshot's
//  natural unit. Each driver translates to whatever the underlying input
//  layer needs at the boundary.
//
//    - iOS:   points (matches `SimulatorRef.pointSize`)
//    - macOS: window-local logical points (CGWindow capture)
//    - Web:   CSS pixels (WKWebView snapshot)
//
//  See `https://github.com/awizemann/harness/wiki/Architecture-Overview` for
//  the platform breakdown.
//

import Foundation
import CoreGraphics

/// Captured screenshot metadata returned by `UXDriving.screenshot(into:)`.
/// The natural-unit size is what the model sees and emits coordinates in.
struct ScreenshotMetadata: Sendable, Hashable {
    /// Native pixel size of the PNG written to disk.
    let pixelSize: CGSize
    /// Logical/point size — the unit the model speaks in for this driver.
    /// For iOS this equals `SimulatorRef.pointSize`; for macOS the
    /// captured window's logical point size; for web the CSS-pixel
    /// viewport size.
    let pointSize: CGSize
}

/// What `RunCoordinator` does per step. Implementations are platform-
/// specific. The protocol intentionally stays small — lifecycle (build,
/// boot, install, launch, teardown) lives in `PlatformAdapter` so the
/// per-platform messy parts don't leak into the coordinator.
protocol UXDriving: Sendable {
    /// Capture a screenshot to `url`. Returns natural-unit + pixel sizes.
    /// Implementations MUST write the PNG before returning so the
    /// "screenshot exists on disk before stepStarted" invariant holds
    /// (see `standards/08-run-log-integrity.md`).
    func screenshot(into url: URL) async throws -> ScreenshotMetadata

    /// Execute one tool call. Drivers MUST handle all `ToolInput` cases
    /// their adapter declared in `PlatformAdapter.toolDefinitions(...)`,
    /// and SHOULD throw `UXDriverError.unsupportedTool` when handed a
    /// tool that doesn't apply to their platform. The non-action tools
    /// (`readScreen`, `noteFriction`, `markGoalDone`) are no-ops at the
    /// driver layer — `RunCoordinator` handles them upstream.
    func execute(_ call: ToolCall) async throws

    /// Reinstall + relaunch the system-under-test between chain legs that
    /// don't preserve state. iOS reinstalls the .app and relaunches via
    /// simctl; macOS quits + relaunches the running app; web reloads the
    /// start URL.
    func relaunchForNewLeg() async throws
}

enum UXDriverError: Error, Sendable, LocalizedError {
    /// The driver was handed a tool variant it doesn't implement (e.g.
    /// the iOS driver received `right_click`, or the web driver received
    /// `swipe`). Always indicates a `PlatformAdapter` bug — adapters
    /// shouldn't expose tools they can't execute.
    case unsupportedTool(name: String, platform: PlatformKind)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name, let platform):
            return "Tool '\(name)' is not supported on \(platform.displayName)."
        }
    }
}
