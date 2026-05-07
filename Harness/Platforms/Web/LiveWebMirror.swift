//
//  LiveWebMirror.swift
//  Harness
//
//  Tiny MainActor registry that lets the live `RunSessionView`'s
//  `WebMirrorView` and the run-time `WebPlatformAdapter` coordinate on
//  one thing: the canvas dimensions the WKWebView should render at.
//
//  Without this, the WKWebView renders at the user-configured viewport
//  (e.g. 1280×1600 portrait) and the live mirror has to letterbox the
//  resulting snapshot inside the actual middle-pane canvas (typically
//  landscape). Letterbox wastes pixels, and pixels-per-snapshot is what
//  determines how much page content the agent gets per turn — and
//  therefore how many turns and how much API spend a goal takes.
//
//  Flow:
//  1. `WebMirrorView` measures its canvas via `GeometryReader` and writes
//     the size into `canvasSize`.
//  2. If a run is already in flight, it also calls `resize` on
//     `activeDriver` so the WKWebView matches the canvas immediately.
//  3. When the *next* run starts, `WebPlatformAdapter.prepare()` reads
//     `canvasSize` and creates the WKWebView at those dimensions, so even
//     the very first screenshot fills the column with no letterbox.
//
//  Process-wide MainActor singleton. Only one run is live at a time, and
//  only one main window hosts the live mirror, so this is sufficient.
//

import Foundation

@MainActor
enum LiveWebMirror {
    /// Most recently measured canvas size (in points) of the run-session
    /// mirror's screen area. Read by `WebPlatformAdapter.prepare()` to
    /// pick the WKWebView's initial viewport. `nil` until the live mirror
    /// has rendered at least once.
    static var canvasSize: CGSize?

    /// Reference to the currently-active web run's driver. Set by
    /// `WebPlatformAdapter.prepare()`, cleared by `teardown(_:)`. Read by
    /// `RunSessionViewModel` when forwarding canvas-size updates to the
    /// live WKWebView mid-run.
    static var activeDriver: WebDriver?
}
