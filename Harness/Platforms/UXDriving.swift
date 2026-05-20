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
    /// V0.3.1 — optional in-memory PNG with agent scaffolding (e.g. the
    /// web driver's Set-of-Mark numbered badges) drawn on top of the
    /// same snapshot. Drivers that don't render scaffolding leave this
    /// nil. The run-loop substitutes these bytes for the disk PNG when
    /// building the LLM payload, so replay / friction reports / shared
    /// screenshots see the clean rendered page while the agent still
    /// sees its targeting overlay.
    let markedImageData: Data?
    /// Optional text annotation describing the scaffolding rendered in
    /// `markedImageData`. The agent loop injects this into the
    /// per-turn user message just above the screenshot so the LLM can
    /// match its intent to a mark by label without trusting its visual
    /// read of the badge numbers — the dominant failure mode for
    /// sub-10B vision models when nav layouts shift across page
    /// transitions (verified: Qwen3-VL 8B treated `id 6` as
    /// semantically "Articles" because the homepage badge had been
    /// Articles, then re-emitted `tap_mark(6)` on a downstream page
    /// where id 6 was a scroll-anchor).
    ///
    /// Web populates this from the SoM probe; iOS / macOS leave it
    /// nil today. Empty string is treated the same as nil — both mean
    /// "no scaffolding to describe."
    let markedAnnotationText: String?

    init(
        pixelSize: CGSize,
        pointSize: CGSize,
        markedImageData: Data? = nil,
        markedAnnotationText: String? = nil
    ) {
        self.pixelSize = pixelSize
        self.pointSize = pointSize
        self.markedImageData = markedImageData
        self.markedAnnotationText = markedAnnotationText
    }
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

    /// Optional hook called by `RunCoordinator` AFTER `execute(_:)`
    /// returns and BEFORE the next step's screenshot capture, so the
    /// driver can wait for paint / animation / lazy-loaded content to
    /// settle. The duration is driver- and tool-specific:
    ///
    /// - Web post-navigation (`navigate`, `back`, `forward`, `refresh`)
    ///   waits ~1500ms — XHR/fetch chatter, lazy images, and JS-driven
    ///   layout shifts commonly land hundreds of ms after `didFinish`.
    /// - Web post-click waits ~500ms for paint settle after same-page
    ///   interactions.
    /// - iOS post-tap waits ~150ms for animation settle.
    /// - Other (read_screen, note_friction, mark_goal_done, type, etc)
    ///   typically no-op.
    ///
    /// Default implementation is a no-op so drivers that don't care
    /// don't pay anything.
    func settle(afterTool call: ToolCall) async

    /// Optional live-preview snapshot for the UI mirror — DIFFERENT
    /// from the LLM-bound `screenshot(into:)` path. Returned bytes are
    /// JPEG (or PNG) and intended for off-the-hot-path display
    /// updates, not on-disk durability.
    ///
    /// `RunCoordinator` polls this every few hundred ms between
    /// `simulatorReady` and `runCompleted` so the UI mirror reflects
    /// the current page/app state, not the frozen snapshot captured
    /// at the last step's start. Critical for slow local-model runs
    /// where steps are minutes apart — without this the user stares
    /// at a stale screenshot the entire time.
    ///
    /// Default implementation returns `nil` (no live preview), which
    /// the coordinator interprets as "platform doesn't support live
    /// previews, skip emission". iOS already has a live path through
    /// `SimulatorDriver.screenshotImage(ref)` so it currently relies
    /// on that; this hook is the seam for web and macOS to opt in.
    func liveSnapshot() async -> Data?

    /// Optional driver-supplied detail string describing what just
    /// happened on the most recent `execute(_:)` call, surfaced into
    /// the next turn's history as part of `toolResultSummary`. Used
    /// by web's `scroll` to report `scrollY → scrollY' (% of page)`
    /// so the agent has an objective progress signal when screenshots
    /// alone don't differentiate (long uniform article body, paged
    /// scrolling at end-of-content, etc.) — local sub-10B vision
    /// models otherwise loop on identical-looking scroll states until
    /// the step budget or cycle detector trips.
    ///
    /// `nil` (the default) means "nothing to add"; the coordinator
    /// falls back to the simple "ok"/"fail" summary.
    func lastExecutionDetail() async -> String?
}

extension UXDriving {
    func settle(afterTool call: ToolCall) async {
        // No-op default. Drivers that need to wait override this.
    }

    func liveSnapshot() async -> Data? {
        // No-op default. Drivers that want to drive the live mirror
        // override this with a fast, low-allocation capture path.
        return nil
    }

    func lastExecutionDetail() async -> String? {
        // No-op default. Drivers that produce per-tool diagnostic
        // text (web's scroll progress, future: macOS scroll, iOS
        // gesture details) override this.
        return nil
    }
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
