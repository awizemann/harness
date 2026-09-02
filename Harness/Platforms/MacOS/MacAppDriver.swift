//
//  MacAppDriver.swift
//  Harness
//
//  `UXDriving` for a macOS app. Captures the app's window with
//  `CGWindowListCreateImage` and synthesises input through a pluggable
//  backend (see `MacInputBackend.swift`).
//
//  The driver targets a specific window owned by `bundleIdentifier`. On
//  every screenshot we re-resolve the front window's CG window-id and
//  bounds — apps move and resize during a run, and we want to follow,
//  not chase a stale frame.
//
//  Coordinate space: screenshots are at point resolution
//  (`CGWindowListCreateImage` returns the visible window content in logical
//  points on the main display unless the user is on a custom Retina mode;
//  see `pointSize` resolution). The agent emits coordinates in those same
//  points; the driver translates window-local point → screen-global point
//  before actuating (both `AXUIElementCopyElementAtPosition` and `CGEvent`
//  use that same global, top-left-origin space).
//
//  Input backend (chosen once, from `HARNESS_MACOS_INPUT`):
//   - `.contained` (DEFAULT) — never touches the real pointer, focus, or
//     any app other than the SUT. Per-step ladder: AX action first
//     (`kAXPressAction`; focus + `AXSetValue` for text), then a `CGEvent`
//     delivered to the SUT's own queue via `postToPid(_:)` (scroll,
//     shortcuts, raw-coordinate / double / right clicks). No global HID,
//     no `ensureFront()`; when neither path can land it throws
//     `MacDriverError.unactuatable`. `kAXRaiseAction` on the SUT's own
//     window would be a within-app raise (permitted) — not used today.
//   - `.hid` (`HARNESS_MACOS_INPUT=hid`) — legacy, preserved verbatim:
//     global-HID `CGEvent`s (`.cghidEventTap`, which takes over the real
//     mouse/keyboard) plus `ensureFront()` foregrounding.
//
//  Permissions (contained mode): Screen Recording (Privacy & Security →
//  Screen & System Audio Recording) for window capture — captures
//  background/occluded windows, so no foregrounding is needed — and
//  Accessibility for the AX actions and `postToPid` event delivery. The
//  first capture / AX call surfaces the respective system prompt; once
//  granted, subsequent runs work silently. TCC grants attach to the
//  responsible parent process, not this binary. (Legacy `.hid` mode
//  needs the same two grants but additionally moves the real pointer and
//  foregrounds the SUT.)
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os

actor MacAppDriver: UXDriving {

    private static let logger = Logger(subsystem: "com.harness.app", category: "MacAppDriver")

    let bundleIdentifier: String
    /// Optional `.app` bundle URL — used by `relaunchForNewLeg()` to
    /// terminate + relaunch the app between chain legs that don't
    /// preserve state.
    let appBundleURL: URL?
    /// V5 — pre-staged credential for this run, or nil. Same lifecycle as
    /// the iOS driver's: resolved once at run start, dropped at teardown.
    let credential: CredentialBinding?

    /// Which input-synthesis backend this run uses. Resolved once, at
    /// construction, from `HARNESS_MACOS_INPUT` (default `.contained`).
    /// Governs the actuation ladder AND whether the SUT is foregrounded
    /// before capture/input.
    let backend: MacInputBackendKind

    /// W26 — the environment and arguments this SUT was LAUNCHED with, kept
    /// so `relaunchForNewLeg()` reproduces the same process. Without them a
    /// chain leg would silently drop the app's fixture mode halfway through a
    /// run and start driving the user's real data. Never logged: an env value
    /// can be a secret.
    let launchEnvironment: [String: String]
    let launchArguments: [String]

    /// The launched SUT's process id. EVERY SUT operation (terminate,
    /// foreground, window lookup, input delivery) binds to this pid, never
    /// to a bundle-id match — a same-bundle-id stranger (e.g. the
    /// developer's own running copy of the crew-built app) must never be
    /// touched. Mutable because `relaunchForNewLeg()` quits this instance
    /// and adopts the freshly-launched instance's pid from the launch
    /// result. Bundle-id resolution is legitimate in exactly one place
    /// (`relaunchForNewLeg`), and even there only to find a `.app` path to
    /// launch FROM — the authoritative pid always comes from the launch.
    private var launchedPID: pid_t

    /// Set-of-Mark cache for the most recent screenshot's probe.
    /// `tap_mark(id)` resolves against this; refreshed on every
    /// `screenshot(into:)` call so marks reflect the same DOM state
    /// the snapshot captured. Same lifecycle as web's / iOS's.
    private var lastMarks: [InteractiveMark] = []

    init(
        bundleIdentifier: String,
        appBundleURL: URL?,
        credential: CredentialBinding? = nil,
        backend: MacInputBackendKind? = nil,
        processIdentifier: pid_t,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = []
    ) {
        self.launchEnvironment = launchEnvironment
        self.launchArguments = launchArguments
        self.bundleIdentifier = bundleIdentifier
        self.appBundleURL = appBundleURL
        self.credential = credential
        self.backend = backend ?? .fromEnvironment(ProcessInfo.processInfo.environment)
        self.launchedPID = processIdentifier
    }

    // MARK: - UXDriving

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        // Contained backend never foregrounds — CGWindowListCreateImage
        // captures background/occluded windows fine. Only legacy HID
        // needs the SUT frontmost so global-HID events land on it.
        if backend.requiresForeground { try ensureFront() }
        guard let info = try findFrontWindow() else {
            throw MacDriverError.windowNotFound(
                bundleID: bundleIdentifier,
                screenAccessGranted: CGPreflightScreenCaptureAccess()
            )
        }

        // Probe AX tree BEFORE capture so marks reflect the same
        // state the snapshot captures. Same invariant the iOS / web
        // drivers enforce. Probe failure is non-fatal — agent can
        // still call coordinate-based tools with no scaffolding.
        // The CAPTURED window's rect is the authority on coordinate space:
        // marks come back in its space, and nothing outside it is marked.
        let probed = probeFrame(pid: info.ownerPID, frame: info.bounds)
        let marks = probed.marks
        let pageText = probed.pageText
        lastMarks = marks
        Self.logger.info("AX probe yielded \(marks.count, privacy: .public) marks for \(self.bundleIdentifier, privacy: .public)")

        guard let cgImage = CGWindowListCreateImage(
            CGRectNull,                              // CGRectNull → use the window's full rect
            .optionIncludingWindow,
            CGWindowID(info.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            throw MacDriverError.captureFailed(screenAccessGranted: CGPreflightScreenCaptureAccess())
        }
        let pixelW = cgImage.width
        let pixelH = cgImage.height
        let pointSize = CGSize(width: info.bounds.width, height: info.bounds.height)

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MacDriverError.captureFailed(screenAccessGranted: CGPreflightScreenCaptureAccess())
        }
        try png.write(to: url, options: .atomic)

        // No marks → no scaffolding to compose. Return the bare
        // disk PNG via the standard metadata shape.
        guard !marks.isEmpty,
              let raw = NSImage(data: png) else {
            // `marks` is empty in the common case here; when it isn't (the
            // PNG failed to decode) the AX geometry is still valid, so pass
            // it through rather than dropping it.
            return ScreenshotMetadata(
                pixelSize: CGSize(width: pixelW, height: pixelH),
                pointSize: pointSize,
                marks: marks,
                pageText: pageText
            )
        }

        // Render badges. `markSpaceSize` = window point size; the
        // CGImage is at the window's pixel resolution, which on
        // retina displays differs from the point size — MarkRenderer
        // scales mark rects from point space to pixel space.
        let marked = MarkRenderer.draw(on: raw, marks: marks, markSpaceSize: pointSize)
        let markedData = MarkRenderer.pngData(from: marked)

        if let markedData,
           ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let markedURL = url
                .deletingPathExtension()
                .appendingPathExtension("marked.png")
            try? markedData.write(to: markedURL, options: .atomic)
        }

        let annotation = MarkRenderer.describe(marks)
        // `pageText` is the front frame's AXStaticText sweep (W20) — the same
        // observation field the web driver fills, so `text_visible` /
        // `for_text` assertions work on macOS instead of silently degrading
        // to a search over control labels. Scoped to the captured frame, so a
        // sheet's page_text is the sheet's text, not the window behind it.
        return ScreenshotMetadata(
            pixelSize: CGSize(width: pixelW, height: pixelH),
            pointSize: pointSize,
            markedImageData: markedData,
            markedAnnotationText: annotation,
            marks: marks,
            pageText: pageText
        )
    }

    func execute(_ call: ToolCall) async throws {
        // Contained backend never foregrounds the SUT; only legacy HID
        // needs it frontmost so global-HID events reach it.
        if backend.requiresForeground { try ensureFront() }
        guard let info = try findFrontWindow() else {
            throw MacDriverError.windowNotFound(
                bundleID: bundleIdentifier,
                screenAccessGranted: CGPreflightScreenCaptureAccess()
            )
        }

        switch call.input {
        case .tap(let x, let y):
            try await actuateClick(button: .left, count: 1, windowLocal: CGPoint(x: x, y: y), info: info, planInput: call.input)
        case .doubleTap(let x, let y):
            try await actuateClick(button: .left, count: 2, windowLocal: CGPoint(x: x, y: y), info: info, planInput: call.input)
        case .rightClick(let x, let y):
            try await actuateClick(button: .right, count: 1, windowLocal: CGPoint(x: x, y: y), info: info, planInput: call.input)
        case .scroll(let x, let y, let dx, let dy):
            try await actuateScroll(windowLocal: CGPoint(x: x, y: y), dx: dx, dy: dy, info: info, planInput: call.input)
        case .type(let text):
            try await actuateType(text, info: info, planInput: call.input)
        case .keyShortcut(let keys):
            try await actuateShortcut(keys, info: info, planInput: call.input)
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .readScreen, .noteFriction, .markGoalDone:
            return
        case .fillCredential(let field):
            // No staged credential → THROW (never a silent no-op: the
            // caller would see an unchanged screen and no reason why).
            // With a binding, route through the same text-entry ladder as
            // the ordinary `type` tool — the macOS app sees a focused text
            // field receive the value, just like a human typing.
            guard let credential else {
                throw UXDriverError.credentialUnavailable(field: field)
            }
            do {
                try await actuateType(credential.value(for: field), info: info, planInput: call.input)
            } catch {
                // An AX / input-backend error can quote the text it tried
                // to insert; scrub the credential before it escapes.
                throw UXDriverError.credentialFillFailed(
                    field: field,
                    detail: credential.redacting(error.localizedDescription)
                )
            }
        case .tapMark(let id):
            try await dispatchMarkClick(id: id, info: info)
        case .swipe, .pressButton, .navigate, .back, .forward, .refresh, .scrollIntoView:
            // `scroll_into_view` is web-only for now: AX exposes
            // `NSAccessibilityScrollToVisibleAction`, but only some views
            // implement it, and a silent no-op that REPORTS a scroll is
            // exactly the dishonesty this codebase refuses. macOS keeps
            // coordinate `scroll` until that can be verified per-role.
            throw UXDriverError.unsupportedTool(name: call.tool.rawValue, platform: .macosApp)
        }
    }

    // MARK: - Settle

    /// Post-action settle. macOS has no DOM mutation observer; we use
    /// the same screenshot-stability approach as iOS: capture at a
    /// fixed cadence, dHash each frame, resolve when two consecutive
    /// frames are visually equivalent OR `maxMs` elapses. Profiles
    /// tuned for typical Mac-app paint cycles (NSAnimation sheet/
    /// modal transitions ~300ms, scroll inertia ~600ms).
    func settle(afterTool call: ToolCall) async {
        let idleMs: Int
        let minMs: Int
        let maxMs: Int
        switch call.input {
        case .tap, .doubleTap, .tapMark, .rightClick, .fillCredential:
            idleMs = 250
            minMs = 250
            maxMs = 2000
        case .scroll:
            idleMs = 400
            minMs = 400
            maxMs = 3000
        case .keyShortcut:
            // Shortcuts can trigger sheet/menu presentations — give
            // a bit more rope than a plain click.
            idleMs = 350
            minMs = 350
            maxMs = 2500
        case .type, .wait, .readScreen, .noteFriction, .markGoalDone,
             .swipe, .pressButton, .navigate, .back, .forward, .refresh,
             .scrollIntoView:
            return
        }
        await awaitWindowStable(idleMs: idleMs, minMs: minMs, maxMs: maxMs)
    }

    /// WB-25 — the settle gate is pixels AND scoped AX geometry.
    ///
    /// The pixel half is unchanged: two consecutive dHash-equivalent frames.
    /// The geometry half is new, and it exists because the pixel half is
    /// perceptually blind to exactly the motion that matters. A popover
    /// finishing its presentation animation moves its `Add` button from x=395
    /// to x=400 — five points, invisible to an 8×8 perceptual hash, and
    /// decisive to a resolver comparing rects. `settle` therefore returned
    /// mid-animation, the next observation reported different geometry from
    /// the one the flow was authored against, and the staleness net called a
    /// step `changed` on a screen where nothing had changed (about one run in
    /// three on Scarf's popover step).
    ///
    /// So a poll now resolves only when BOTH halves agree with the previous
    /// poll. The geometry sample is scoped the same way the mark table is
    /// (`MacMarkProbe.geometrySignature`), so it describes the front
    /// container's elements — the popover's, when a popover owns the frame —
    /// and not the whole app.
    ///
    /// Two properties keep this from ever becoming a hang. `maxMs` is the same
    /// budget as before and still governs the whole loop: a screen that never
    /// stops moving costs exactly what it used to. And a nil signature — no
    /// matching AX root, Accessibility denied, the snapshot budget spent — is
    /// "no opinion", NOT "unstable": the gate falls back to the pixel-only
    /// behaviour rather than spinning out the full budget on an app whose AX
    /// tree we simply cannot read.
    ///
    /// This is the macOS driver only. The web path settles on its own DOM
    /// signal and is untouched.
    private func awaitWindowStable(idleMs: Int, minMs: Int, maxMs: Int) async {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(maxMs))
        let floor = start.advanced(by: .milliseconds(minMs))
        let pollInterval: Duration = .milliseconds(150)

        var previous: MacSettleGate.Sample?
        while clock.now < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(for: pollInterval)
            guard let info = (try? findFrontWindow()) ?? nil else { continue }
            guard let cgImage = CGWindowListCreateImage(
                CGRectNull,
                .optionIncludingWindow,
                CGWindowID(info.windowNumber),
                [.boundsIgnoreFraming, .nominalResolution]
            ) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let current = MacSettleGate.Sample(
                hash: ScreenshotHasher.dHash(jpeg: png),
                geometry: Self.geometrySignature(pid: info.ownerPID, frame: info.bounds)
            )
            let settled = clock.now >= floor
                && MacSettleGate.isSettled(previous: previous, current: current)
            previous = current
            if settled { return }
        }
    }

    /// Sample the front frame's scoped AX geometry for the settle gate.
    ///
    /// Deliberately cheaper than the mark probe's own snapshot: this runs on
    /// every settle poll, and it needs positions, not labels.
    ///
    /// The budget is a CORRECTNESS boundary, not just a cost one.
    /// `MacAXSnapshot.capture` does not fail when it runs out — it returns the
    /// root with a truncated child list, and the cut lands wherever the wall
    /// clock happened to stop it. A digest built from that is a prefix whose
    /// length varies poll to poll, which would make a static screen look like
    /// a moving one and burn the whole settle budget on every action. So an
    /// exhausted budget is reported as nil, and the gate reverts to the
    /// pixel-only behaviour it had before this change.
    ///
    /// The numbers sit close to the mark probe's own (1500 nodes / 1200ms) so
    /// the settle really is looking at the geometry the mark table is built
    /// from, and not a shorter prefix of it. A sample slower than the 150ms
    /// poll interval costs polls AND overshoots the deadline by at most one
    /// sample — the loop checks `maxMs` at the top — which is bounded and
    /// acceptable; a wrong stability verdict is not.
    private static let settleSnapshotNodes = 1500
    private static let settleSnapshotBudgetMs = 400

    /// Static, not `nonisolated`: it touches no instance state, and
    /// `nonisolated` on a synchronous method would only imply an offload that
    /// does not happen — the AX walk still blocks the caller's executor.
    private static func geometrySignature(pid: Int, frame: CGRect) -> String? {
        let appElem = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(appElem, Float(axMessagingTimeoutSeconds))
        // The clock starts HERE, before the per-root rect reads below: each of
        // those is an AX round trip that can take up to the messaging timeout,
        // and a budget that only starts after them could be spent before the
        // first node is captured.
        var budget = MacAXSnapshot.Budget(
            nodesRemaining: settleSnapshotNodes,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(settleSnapshotBudgetMs))
        )
        var rootElements: [AXUIElement] = []
        if let windows = axAttribute(appElem, attribute: kAXWindowsAttribute) as? [AXUIElement] {
            rootElements.append(contentsOf: windows)
        }
        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let w = axAttribute(appElem, attribute: attr),
               CFGetTypeID(w) == AXUIElementGetTypeID() {
                rootElements.append(unsafeDowncast(w, to: AXUIElement.self))
            }
        }
        guard !rootElements.isEmpty else { return nil }
        var seen: Set<UInt64> = []
        var roots: [AXSnapshotNode] = []
        // Capture in the order `selectRoot` would CHOOSE: most of the frame
        // covered first, and among roots that cover it equally the smallest —
        // which is the overlay. An overlay and the window behind it both
        // "contain" a popover's frame, so overlap alone leaves the tie to
        // enumeration order, and losing that tie spends the whole budget on
        // the background window before reaching the frame the settle is about.
        //
        // Sorted on a QUANTISED overlap rather than an epsilon comparison: an
        // "equal within 0.05" predicate is not a strict weak ordering (the
        // relation isn't transitive across the epsilon) and leaves the result
        // undefined for three or more roots straddling it — a second, silent
        // source of poll-to-poll signature churn.
        struct RootRank {
            var element: AXUIElement
            var bucket: Int
            var area: CGFloat
        }
        var ranked: [RootRank] = []
        for element in rootElements {
            let rect: CGRect? = MacAXSnapshot.axRect(element)
            let overlap: CGFloat = frameOverlap(rect, frame)
            let width: CGFloat = rect?.width ?? CGFloat.greatestFiniteMagnitude
            let height: CGFloat = rect?.height ?? CGFloat(1)
            ranked.append(RootRank(
                element: element,
                bucket: Int((overlap * 20).rounded()),
                area: width * height
            ))
        }
        ranked.sort { a, b in a.bucket == b.bucket ? a.area < b.area : a.bucket > b.bucket }
        let ordered = ranked.map(\.element)
        for element in ordered {
            let identity = MacAXSnapshot.identity(of: element)
            if !seen.insert(identity).inserted { continue }
            guard let node = MacAXSnapshot.capture(
                element: element, frame: frame, depth: 0, budget: &budget
            ) else { continue }
            roots.append(node)
        }
        // An exhausted budget means the tree we captured is a truncation, not
        // a description. Say so.
        guard budget.nodesRemaining > 0, !budget.expired else { return nil }
        return MacMarkProbe.geometrySignature(roots: roots, frame: frame)
    }

    // MARK: - Set-of-Mark dispatch

    /// Resolve `id` to a cached `InteractiveMark` and actuate the center of
    /// its visible-in-window portion, with the semantics its ROLE calls for
    /// (`MacMarkActuationPolicy`, WB-23):
    ///
    ///  * a text-entry role is FOCUSED (`kAXFocused`, verified by read-back),
    ///    because `kAXPressAction` on a field is a no-op — the old ladder
    ///    reported a landed press and the caller's next `type` went wherever
    ///    focus already happened to be;
    ///  * a row / cell is SELECTED (`kAXSelected` on the row, else
    ///    `kAXSelectedRows` on its table), never pressed. Press on a row can
    ///    ACTIVATE it — open a document, push a detail view — and a tap that
    ///    sometimes selects and sometimes navigates is not something a guide
    ///    can be authored against. Opening is `double_tap` at the mark's
    ///    centre — the caller has the rect;
    ///  * everything else keeps the single-left-click ladder (AX press first
    ///    in contained mode, global HID under the legacy backend).
    ///
    /// Every intent falls back to ONE targeted left click at the mark's
    /// centre, which is what a human does and which focuses a field and
    /// selects a row on every standard AppKit / SwiftUI control. Note what
    /// that fallback means for a list whose rows open on a SINGLE click
    /// (a Finder-style "single click opens" preference, a custom
    /// `onTapGesture` row): AX selection is tried first precisely because it
    /// cannot activate anything, and the click is only reached when the app
    /// exposes no selection at all. When neither lands, the step fails
    /// honestly (`unactuatable`) rather than reporting a tap that did
    /// nothing.
    private func dispatchMarkClick(id: Int, info: WindowInfo) async throws {
        guard let mark = lastMarks.first(where: { $0.id == id }) else {
            throw MacDriverError.unknownMark(id: id)
        }
        let inset: CGFloat = 4
        let winW = info.bounds.width
        let winH = info.bounds.height
        let visibleMinX = max(mark.rect.minX, 0) + inset
        let visibleMinY = max(mark.rect.minY, 0) + inset
        let visibleMaxX = min(mark.rect.maxX, winW) - inset
        let visibleMaxY = min(mark.rect.maxY, winH) - inset
        let cx: CGFloat
        let cy: CGFloat
        if visibleMaxX > visibleMinX && visibleMaxY > visibleMinY {
            cx = (visibleMinX + visibleMaxX) / 2
            cy = (visibleMinY + visibleMaxY) / 2
        } else {
            cx = mark.rect.midX
            cy = mark.rect.midY
        }
        let intent = MacMarkActuationPolicy.intent(forRole: mark.role)
        Self.logger.info("tap_mark(\(id, privacy: .public)) → label=\"\(mark.label, privacy: .public)\" role=\(mark.role, privacy: .public) intent=\(intent.rawValue, privacy: .public) rect=(\(Int(mark.rect.minX), privacy: .public),\(Int(mark.rect.minY), privacy: .public),\(Int(mark.rect.width), privacy: .public),\(Int(mark.rect.height), privacy: .public)) → (\(Int(cx), privacy: .public),\(Int(cy), privacy: .public))")
        if ProcessInfo.processInfo.environment["HARNESS_DUMP_MARKED"] == "1" {
            let line = "[MacAX] tap_mark(\(id)) label=\"\(mark.label)\" role=\(mark.role) intent=\(intent.rawValue) rect=(\(Int(mark.rect.minX)),\(Int(mark.rect.minY)),\(Int(mark.rect.width)),\(Int(mark.rect.height))) → (\(Int(cx)),\(Int(cy)))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        try await actuateMark(
            intent: intent,
            id: id,
            role: mark.role,
            windowLocal: CGPoint(x: cx, y: cy),
            info: info
        )
    }

    /// The `tap_mark` ladder, per intent. `.press` is the pre-WB-23 path,
    /// unchanged; `.focus` and `.select` swap the AX rung for one that
    /// actually does what the role means, keeping the same targeted-click
    /// fallback and the same honest `unactuatable` failure.
    private func actuateMark(
        intent: MacMarkIntent,
        id: Int,
        role: String,
        windowLocal: CGPoint,
        info: WindowInfo
    ) async throws {
        guard intent != .press else {
            try await actuateClick(
                button: .left, count: 1, windowLocal: windowLocal,
                info: info, planInput: .tapMark(id: id)
            )
            return
        }
        let global = toGlobalPoint(windowLocal, info)
        let pid = info.ownerPID
        try await runLadder(
            action: "tap_mark(\(id)) [\(role) → \(intent.rawValue)] at (\(Int(windowLocal.x)),\(Int(windowLocal.y)))",
            steps: MacActuationPlan.steps(for: .tapMark(id: id), backend: backend, markIntent: intent),
            axFocus: {
                guard let element = Self.axFocusableElement(pid: pid, atGlobal: global) else {
                    return .notApplicable("no focusable AX element at the mark's point")
                }
                return Self.axFocus(element)
                    ? .landed
                    : .notApplicable("element did not report kAXFocused after being set")
            },
            axSelect: {
                guard let row = Self.axRowElement(pid: pid, atGlobal: global) else {
                    return .notApplicable("no AXRow at the mark's point")
                }
                return Self.axSelectRow(row)
                    ? .landed
                    : .notApplicable("neither the row nor its table accepted a verified selection")
            },
            cgTargeted: {
                self.postClickToPid(button: .left, count: 1, global: global, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try await self.postClickHID(button: .left, count: 1, global: global)
                return .landed
            }
        )
    }

    /// Quit the running SUT: ask it to `terminate()`, wait ~2s, then
    /// `forceTerminate()` as a fallback so a hung app never blocks the
    /// caller. Idempotent — a no-op when the app isn't running (already
    /// quit / never launched). Shared by `relaunchForNewLeg()` (which then
    /// relaunches) and the ui-session teardown path (which does not), so
    /// the two can't diverge on how the SUT is killed.
    func terminateApp() async {
        // Resolve strictly by the launched pid — a same-bundle-id stranger
        // (the developer's own copy) must never be the one we quit. nil ⇒
        // already gone (idempotent no-op).
        guard let app = NSRunningApplication(processIdentifier: launchedPID) else { return }
        app.terminate()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if app.isTerminated { return }
        }
        if !app.isTerminated {
            _ = app.forceTerminate()
        }
    }

    func relaunchForNewLeg() async throws {
        // Quit THIS instance (by its pid), then launch a fresh one and adopt
        // the NEW instance's pid straight from the launch result.
        // `terminateApp()` has already driven the old pid to termination
        // (terminate → force-terminate), so the old instance is gone before
        // any bundle-id-based rediscovery below — we can never re-adopt the
        // instance we just killed, nor bind to a same-bundle-id stranger:
        // the pid we store comes only from `openApplication`.
        await terminateApp()
        let cfg = NSWorkspace.OpenConfiguration()
        // Contained backend must not steal focus on reopen; only legacy HID
        // relaunches activated.
        cfg.activates = backend.activatesOnLaunch
        // Force a genuinely new process. Without this, if a same-bundle-id
        // stranger (the dev's own copy) is running, LaunchServices would just
        // activate IT and hand its NSRunningApplication back — and we'd bind
        // `launchedPID` to the stranger. A new instance guarantees the pid we
        // adopt is the one we launched.
        cfg.createsNewApplicationInstance = true
        // W26 — the new leg must be the SAME process shape as the first one.
        if !launchEnvironment.isEmpty { cfg.environment = launchEnvironment }
        if !launchArguments.isEmpty { cfg.arguments = launchArguments }
        let launched: NSRunningApplication
        if let bundleURL = appBundleURL {
            // NSWorkspace handles "cold relaunch from .app".
            launched = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
        } else if let runningURL = appBundleURLByLookup() {
            // No stored bundle URL → user provided an already-running app via
            // bundle id. This is the ONE legitimate bundle-id lookup, and it
            // only supplies a `.app` path to launch FROM; the authoritative
            // pid still comes from the launch result below.
            launched = try await NSWorkspace.shared.openApplication(at: runningURL, configuration: cfg)
        } else {
            // Nothing left to relaunch from (old instance gone, no URL, no
            // same-bundle-id copy to borrow a path from). Surface the standard
            // not-running error rather than silently binding to a stale pid.
            throw MacDriverError.appNotRunning(bundleID: bundleIdentifier)
        }
        // Bind every subsequent SUT operation to the freshly-launched pid.
        launchedPID = launched.processIdentifier
        // Wait briefly for the app's main window to come back. If it
        // doesn't, the next screenshot() will throw `windowNotFound`
        // and surface a clean error.
        for _ in 0..<30 {
            if (try? findFrontWindow()) ?? nil != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Internals

    /// Bring the SUT to the front so screenshots and CGEvents target it.
    /// Idempotent — safe to call before every step. Resolves strictly by
    /// the launched pid; nil ⇒ the SUT died (surfaced as `appNotRunning`).
    private func ensureFront() throws {
        guard let app = NSRunningApplication(processIdentifier: launchedPID) else {
            throw MacDriverError.appNotRunning(bundleID: bundleIdentifier)
        }
        if !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Resolve the SUT's frontmost on-screen window from the CG window list.
    /// Returns nil when nothing matches (app is hidden, mid-launch, etc.).
    struct WindowInfo {
        let windowNumber: Int
        let bounds: CGRect      // global screen coordinates, top-left origin in macOS-y space
        let ownerPID: Int
    }

    /// The SUT's front window, or nil when there isn't one (still launching,
    /// hidden, or the process is gone). Non-throwing: the launch settle polls
    /// this and treats every "not yet" the same way, so folding the
    /// `appNotRunning` throw into nil here keeps that caller from having to
    /// distinguish two flavours of "no window".
    func frontWindow() -> WindowInfo? {
        (try? findFrontWindow()) ?? nil
    }

    private func findFrontWindow() throws -> WindowInfo? {
        // Liveness check binds to the launched pid — a dead SUT throws
        // `appNotRunning`; we never adopt a same-bundle-id stranger.
        guard NSRunningApplication(processIdentifier: launchedPID) != nil else {
            throw MacDriverError.appNotRunning(bundleID: bundleIdentifier)
        }
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return Self.selectFrontWindow(rows: raw, pid: launchedPID)
    }

    /// Pick the topmost on-screen window owned by `pid` with non-trivial
    /// size. Pure over the CGWindowList rows so the pid-binding invariant —
    /// rows owned by a same-bundle-id stranger are ignored — is unit-testable
    /// without a live app.
    nonisolated static func selectFrontWindow(rows: [[String: Any]], pid: pid_t) -> WindowInfo? {
        for entry in rows {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid),
                  let windowNumber = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 50, rect.height > 50
            else { continue }
            return WindowInfo(windowNumber: windowNumber, bounds: rect, ownerPID: ownerPID)
        }
        return nil
    }

    /// Last-ditch lookup for the running app's bundle URL — used ONLY by
    /// `relaunchForNewLeg()` to find a `.app` path to launch from in raw
    /// bundle-id run mode (no stored URL). This is the single sanctioned
    /// bundle-id resolution; it yields a launch path, never a pid.
    private func appBundleURLByLookup() -> URL? {
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })?
            .bundleURL
    }

    // MARK: - CGEvent helpers

    /// Convert window-local point → global screen point (where CGEvent
    /// expects its coordinates). macOS's CGEvent uses top-left origin
    /// global, which matches `kCGWindowBounds` directly.
    private func toGlobalPoint(_ windowLocal: CGPoint, _ info: WindowInfo) -> CGPoint {
        CGPoint(x: info.bounds.minX + windowLocal.x,
                y: info.bounds.minY + windowLocal.y)
    }

    // MARK: - Actuation ladder

    /// Outcome of one ladder rung. `.landed` stops the ladder;
    /// `.notApplicable` records why and moves to the next rung.
    private enum StepResult {
        case landed
        case notApplicable(String)
    }

    /// Walk `steps` in order, stopping at the first that lands. If every
    /// rung is `.notApplicable`, throw `unactuatable` naming what was
    /// attempted — the honest failure mode. Never falls back to global
    /// HID. (In `.hid` mode the single global-HID rung throws
    /// `eventCreationFailed` on construction failure, verbatim to the
    /// pre-0.8 behavior, and so never reaches the `unactuatable` throw.)
    private func runLadder(
        action: String,
        steps: [MacActuationStep],
        axPress: () -> StepResult = { .notApplicable("no AX-press path for this tool") },
        axSetValue: () -> StepResult = { .notApplicable("no AX-value path for this tool") },
        axFocus: () -> StepResult = { .notApplicable("no AX-focus path for this tool") },
        axSelect: () -> StepResult = { .notApplicable("no AX-select path for this tool") },
        cgTargeted: () -> StepResult = { .notApplicable("no targeted-CGEvent path for this tool") },
        cgGlobalHID: () async throws -> StepResult = { .notApplicable("no HID path for this tool") }
    ) async throws {
        var reasons: [String] = []
        for step in steps {
            let result: StepResult
            switch step {
            case .axPress:          result = axPress()
            case .axSetValue:       result = axSetValue()
            case .axFocus:          result = axFocus()
            case .axSelect:         result = axSelect()
            case .cgEventTargeted:  result = cgTargeted()
            case .cgEventGlobalHID: result = try await cgGlobalHID()
            }
            if case .landed = result { return }
            if case .notApplicable(let why) = result { reasons.append("\(step.label): \(why)") }
        }
        throw MacDriverError.unactuatable(
            action: action,
            detail: reasons.isEmpty ? "no actuation path available" : reasons.joined(separator: "; ")
        )
    }

    private func actuateClick(
        button: CGMouseButton,
        count: Int,
        windowLocal: CGPoint,
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        let global = toGlobalPoint(windowLocal, info)
        let pid = info.ownerPID
        try await runLadder(
            action: "click(button:\(button.rawValue) count:\(count)) at (\(Int(windowLocal.x)),\(Int(windowLocal.y)))",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            axPress: {
                // AXPress models a single activation only; double / right
                // click have no single-action equivalent → fall through.
                guard button == .left, count == 1 else {
                    return .notApplicable("AX press applies only to a single left click")
                }
                guard let element = Self.axPressableElement(pid: pid, atGlobal: global) else {
                    return .notApplicable("no actionable AX element at point")
                }
                return Self.axPerformPress(element)
                    ? .landed
                    : .notApplicable("AXPress returned an error")
            },
            cgTargeted: {
                self.postClickToPid(button: button, count: count, global: global, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try await self.postClickHID(button: button, count: count, global: global)
                return .landed
            }
        )
    }

    private func actuateScroll(
        windowLocal: CGPoint,
        dx: Int,
        dy: Int,
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        let global = toGlobalPoint(windowLocal, info)
        let pid = info.ownerPID
        try await runLadder(
            action: "scroll(dx:\(dx) dy:\(dy)) at (\(Int(windowLocal.x)),\(Int(windowLocal.y)))",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            cgTargeted: {
                self.postScrollToPid(global: global, dx: dx, dy: dy, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try self.postScrollHID(global: global, dx: dx, dy: dy)
                return .landed
            }
        )
    }

    private func actuateType(
        _ text: String,
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        let pid = info.ownerPID
        try await runLadder(
            action: "type(\(text.count) chars)",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            axSetValue: {
                // Whole-value entry into the app's focused text element.
                // NOTE: this replaces the field's value rather than
                // appending keystrokes — it does not fire per-keystroke
                // handlers. When the focused element rejects AXSetValue
                // (not settable / no focus) we fall through to synthetic
                // keystrokes, which do.
                guard let element = Self.axFocusedElement(pid: pid) else {
                    return .notApplicable("no focused AX element to receive text")
                }
                return Self.axSetValue(element, text: text)
                    ? .landed
                    : .notApplicable("focused element did not accept AXSetValue")
            },
            cgTargeted: {
                self.postTypeToPid(text, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try self.postTypeHID(text)
                return .landed
            }
        )
    }

    private func actuateShortcut(
        _ keys: [String],
        info: WindowInfo,
        planInput: ToolInput
    ) async throws {
        // Resolve the key combo up front — `unknownKey` is a bad-input
        // error, independent of backend, and empty keys are a no-op.
        guard let resolved = try Self.resolveShortcut(keys) else { return }
        let pid = info.ownerPID
        try await runLadder(
            action: "key_shortcut(\(keys.joined(separator: "+")))",
            steps: MacActuationPlan.steps(for: planInput, backend: backend),
            cgTargeted: {
                self.postShortcutToPid(vk: resolved.vk, flags: resolved.flags, pid: pid)
                    ? .landed
                    : .notApplicable("CGEvent construction failed")
            },
            cgGlobalHID: {
                try self.postShortcutHID(vk: resolved.vk, flags: resolved.flags)
                return .landed
            }
        )
    }

    // MARK: - Contained synthesis (postToPid — pointer never moves)

    /// Post a click to the SUT's own event queue. Returns false only if
    /// a `CGEvent` couldn't be constructed. `postToPid` delivers to the
    /// app's queue without moving the real cursor, so no inter-click
    /// sleep is needed — the `clickState` field is what marks a
    /// double-click.
    private func postClickToPid(button: CGMouseButton, count: Int, global: CGPoint, pid: Int) -> Bool {
        let (downType, upType) = Self.mouseTypes(for: button)
        for i in 1...count {
            guard postMouseToPid(type: downType, location: global, mouseButton: button, clickState: i, pid: pid),
                  postMouseToPid(type: upType,   location: global, mouseButton: button, clickState: i, pid: pid)
            else { return false }
        }
        return true
    }

    private func postMouseToPid(type: CGEventType, location: CGPoint, mouseButton: CGMouseButton, clickState: Int, pid: Int) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        ) else { return false }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.postToPid(pid_t(pid))
        return true
    }

    private func postScrollToPid(global: CGPoint, dx: Int, dy: Int, pid: Int) -> Bool {
        // A synthetic mouse-moved so the app's own hover / scroll routing
        // targets the right view. Delivered to the app queue only — the
        // real system cursor does NOT move.
        _ = postMouseToPid(type: .mouseMoved, location: global, mouseButton: .left, clickState: 0, pid: pid)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-dy),   // UI convention (positive = down) → CGEvent up-positive
            wheel2: Int32(dx),
            wheel3: 0
        ) else { return false }
        event.postToPid(pid_t(pid))
        return true
    }

    private func postTypeToPid(_ text: String, pid: Int) -> Bool {
        let chars = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        down.postToPid(pid_t(pid))
        up.postToPid(pid_t(pid))
        return true
    }

    private func postShortcutToPid(vk: CGKeyCode, flags: CGEventFlags, pid: Int) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags   = flags
        down.postToPid(pid_t(pid))
        up.postToPid(pid_t(pid))
        return true
    }

    // MARK: - Legacy HID synthesis (global .cghidEventTap — verbatim pre-0.8)

    private func postClickHID(button: CGMouseButton, count: Int, global: CGPoint) async throws {
        let (downType, upType) = Self.mouseTypes(for: button)
        for i in 1...count {
            try postMouseHID(type: downType, location: global, mouseButton: button, clickState: i)
            try postMouseHID(type: upType,   location: global, mouseButton: button, clickState: i)
            // Tiny inter-click gap so double-clicks register as one gesture.
            if i < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
    }

    private func postMouseHID(type: CGEventType, location: CGPoint, mouseButton: CGMouseButton, clickState: Int) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        ) else {
            throw MacDriverError.eventCreationFailed(action: "mouse:\(type.rawValue)")
        }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postScrollHID(global: CGPoint, dx: Int, dy: Int) throws {
        try postMouseHID(type: .mouseMoved, location: global, mouseButton: .left, clickState: 0)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else {
            throw MacDriverError.eventCreationFailed(action: "scroll")
        }
        event.post(tap: .cghidEventTap)
    }

    private func postTypeHID(_ text: String) throws {
        let chars = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            throw MacDriverError.eventCreationFailed(action: "type")
        }
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw MacDriverError.eventCreationFailed(action: "type")
        }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postShortcutHID(vk: CGKeyCode, flags: CGEventFlags) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else {
            throw MacDriverError.eventCreationFailed(action: "key_shortcut")
        }
        down.flags = flags
        up.flags   = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Input primitives shared by both backends

    private static func mouseTypes(for button: CGMouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left:  return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        default:     return (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Parse a shortcut key list into `(modifier flags, final virtual
    /// key)`. Returns nil for an empty list (a no-op). Throws
    /// `unknownKey` for an unrecognised final key. Backend-independent —
    /// bad input fails the same way in both modes.
    private static func resolveShortcut(_ keys: [String]) throws -> (flags: CGEventFlags, vk: CGKeyCode)? {
        guard !keys.isEmpty else { return nil }
        let lowered = keys.map { $0.lowercased() }
        let modifierNames: Set<String> = ["cmd", "command", "shift", "option", "alt", "ctrl", "control", "fn"]
        let modifiers = lowered.filter { modifierNames.contains($0) }
        let finalKey = lowered.last(where: { !modifierNames.contains($0) })

        var flags: CGEventFlags = []
        for m in modifiers {
            switch m {
            case "cmd", "command":  flags.insert(.maskCommand)
            case "shift":           flags.insert(.maskShift)
            case "option", "alt":   flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn":              flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        guard let key = finalKey, let vk = MacKeyCodes.virtualKey(for: key) else {
            throw MacDriverError.unknownKey(name: finalKey ?? "<empty>")
        }
        return (flags, vk)
    }

    // MARK: - AX actuation (contained clicks / text entry)

    /// Hit-test the SUT at a global point and climb up to a few ancestors
    /// looking for an element that advertises `kAXPressAction` — the deep
    /// hit is often a static label inside the actual button. Returns nil
    /// when nothing pressable is under the point (raw-coordinate click on
    /// non-AX content) so the caller falls through to a CGEvent. Requires
    /// Accessibility; on denial the copy fails and we return nil.
    nonisolated private static func axPressableElement(pid: Int, atGlobal p: CGPoint) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success,
              var element = hit else {
            return nil
        }
        for _ in 0..<5 {
            if axSupportsPress(element) { return element }
            // Checked, never forced: these values come from ANOTHER process's
            // accessibility server. A SUT that publishes a malformed
            // attribute must degrade to "no actionable element", never crash
            // the engine — and a crew-built app under test is exactly the
            // population that publishes malformed AX data.
            guard let parent = axAttribute(element, attribute: kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    nonisolated private static func axSupportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    nonisolated private static func axPerformPress(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // MARK: AX focus / selection (WB-23 — what tap_mark means per role)

    /// Hit-test at a global point and climb to the nearest element that will
    /// accept keyboard focus (`kAXFocused` settable). The deep hit inside a
    /// SwiftUI `TextField` is routinely the inner text area or a static
    /// label, so the climb is what finds the field itself.
    nonisolated private static func axFocusableElement(pid: Int, atGlobal p: CGPoint) -> AXUIElement? {
        axClimb(pid: pid, atGlobal: p) { element in
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success
            else { return false }
            return settable.boolValue
        }
    }

    /// Hit-test at a global point and climb to the nearest `AXRow`. A click
    /// on a list lands on a cell or on the text inside it far more often
    /// than on the row itself.
    nonisolated private static func axRowElement(pid: Int, atGlobal p: CGPoint) -> AXUIElement? {
        axClimb(pid: pid, atGlobal: p) { element in
            axRole(element) == "AXRow"
        }
    }

    /// Shared hit-test-then-climb. At most five hops, and every attribute
    /// read is CHECKED, never forced: these values come from another
    /// process's accessibility server, and a SUT publishing a malformed
    /// attribute must degrade to "nothing here", never crash the engine.
    nonisolated private static func axClimb(
        pid: Int,
        atGlobal p: CGPoint,
        matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<5 {
            if matches(element) { return element }
            guard let parent = axAttribute(element, attribute: kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    nonisolated private static func axRole(_ element: AXUIElement) -> String? {
        axAttribute(element, attribute: kAXRoleAttribute) as? String
    }

    /// Focus an element and PROVE it took. `AXUIElementSetAttributeValue`
    /// returning `.success` means the app accepted the message, not that
    /// anything moved — several AppKit views answer success and leave focus
    /// where it was. Read-back is the difference between a focus and a
    /// report of one; without it the caller's next `type` lands in the field
    /// they were already in, which is precisely the bug this replaces.
    nonisolated private static func axFocus(_ element: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        else { return false }
        if let value = axAttribute(element, attribute: kAXFocusedAttribute) as? Bool, value { return true }
        // Some views never publish `AXFocused` on the element itself; the
        // application's own focused-element pointer is the second opinion.
        let pid = pidOf(element)
        guard pid > 0, let focused = axFocusedElement(pid: pid) else { return false }
        return CFEqual(focused, element)
    }

    /// Select a row, verified by read-back, without ever pressing it.
    ///
    /// Two paths, in order: the row's own `kAXSelected`, then the owning
    /// table / outline / list's `kAXSelectedRows`. `kAXPressAction` is
    /// deliberately NOT a fallback — press on a row means "activate", which
    /// on a real list opens a document or navigates, and `tap_mark` promising
    /// selection must not sometimes navigate instead.
    nonisolated private static func axSelectRow(_ row: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(row, kAXSelectedAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success,
           axIsSelected(row) {
            return true
        }
        // The container path: climb to the nearest ancestor that publishes
        // `AXSelectedRows` and hand it a one-row selection.
        var element = row
        for _ in 0..<5 {
            guard let parent = axAttribute(element, attribute: kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = unsafeDowncast(parent, to: AXUIElement.self)
            var containerSettable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXSelectedRowsAttribute as CFString, &containerSettable) == .success,
                  containerSettable.boolValue else { continue }
            let selection = [row] as CFArray
            guard AXUIElementSetAttributeValue(element, kAXSelectedRowsAttribute as CFString, selection) == .success
            else { return false }
            return axIsSelected(row)
        }
        return false
    }

    nonisolated private static func axIsSelected(_ element: AXUIElement) -> Bool {
        (axAttribute(element, attribute: kAXSelectedAttribute) as? Bool) == true
    }

    /// The pid that owns an element, for the focused-element second opinion.
    /// Returns 0 when AX won't say, which resolves to "no focused element".
    nonisolated private static func pidOf(_ element: AXUIElement) -> Int {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return 0 }
        return Int(pid)
    }

    /// The app's currently focused UI element (where typed text would
    /// land), or nil if nothing is focused / Accessibility is denied.
    nonisolated private static func axFocusedElement(pid: Int) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        guard let focused = axAttribute(app, attribute: kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focused, to: AXUIElement.self)
    }

    /// Focus the element, then set its whole value via `AXSetValue`.
    /// Returns false when the element's value isn't settable or the set
    /// fails, so the caller falls through to synthetic keystrokes.
    nonisolated private static func axSetValue(_ element: AXUIElement, text: String) -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    // MARK: - AX (Set-of-Mark probe)

    /// Snapshot the app's accessibility tree for the CAPTURED frame and hand
    /// it to `MacMarkProbe`, which decides what gets marked, what it's
    /// called, and what the frame's text says. Everything AX-specific — the
    /// attribute reads, the hit test — lives here; every judgement lives in
    /// the pure probe, where the test suite can pin it.
    ///
    /// `frame` is the captured window's rect in global screen points. It is
    /// the authority on coordinate space (W24): marks come back in ITS space,
    /// so a callout drawn on the returned image lands where the badge is.
    ///
    /// Requires the Accessibility permission. Without the grant every
    /// attribute read returns `.cannotComplete` and this returns nothing —
    /// the same silent degradation as before, and the agent can still call
    /// coordinate-based tools.
    /// Wall-clock ceiling for the whole occlusion pass. Past it the hit test
    /// answers "unknown" and the probe stops dropping anything — a slow app
    /// costs us stale rows, never a missing control.
    private static let hitTestBudgetMs = 600

    /// Per-call ceiling on one synchronous AX round trip to the SUT.
    private static let axMessagingTimeoutSeconds = 0.25

    /// Wall-clock ceiling on the whole tree snapshot, alongside the node
    /// count. A node budget alone bounds the number of round trips, not
    /// their duration.
    private static let snapshotBudgetMs = 1200

    /// Intersection area of a candidate root with the captured frame, as a
    /// fraction of the frame. Only used to ORDER the capture, so a coarse
    /// number is enough.
    nonisolated private static func frameOverlap(_ rect: CGRect?, _ frame: CGRect) -> CGFloat {
        guard let rect else { return 0 }
        let inter = rect.intersection(frame)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        return (inter.width * inter.height) / max(1, frame.width * frame.height)
    }

    nonisolated private func probeFrame(pid: Int, frame: CGRect) -> MacMarkProbe.Result {
        let appElem = AXUIElementCreateApplication(pid_t(pid))
        // Bound the IPC itself, not just our own loops. Every attribute read
        // and hit test below is a SYNCHRONOUS round trip to the target app,
        // and the AX default timeout is ~6s — one call to a beachballing SUT
        // would blow every budget in this function by an order of magnitude
        // and stall the step. 250ms is far above a healthy app's response
        // (sub-millisecond) and far below a stall the caller would tolerate.
        // The timeout is set on the application element, so it applies to
        // every element derived from it.
        AXUIElementSetMessagingTimeout(appElem, Float(Self.axMessagingTimeoutSeconds))
        var budget = MacAXSnapshot.Budget(deadline: ContinuousClock().now.advanced(by: .milliseconds(Self.snapshotBudgetMs)))

        // Candidate roots: every window the app advertises, plus its focused
        // and main window (an app can expose a sheet / popover that is not in
        // `AXWindows`). The probe picks the one matching the captured frame.
        var rootElements: [AXUIElement] = []
        if let windows = Self.axAttribute(appElem, attribute: kAXWindowsAttribute) as? [AXUIElement] {
            rootElements.append(contentsOf: windows)
        }
        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let w = Self.axAttribute(appElem, attribute: attr),
               CFGetTypeID(w) == AXUIElementGetTypeID() {
                rootElements.append(unsafeDowncast(w, to: AXUIElement.self))
            }
        }
        guard !rootElements.isEmpty else { return MacMarkProbe.Result(marks: [], pageText: nil) }

        // Capture the window that best matches the captured frame FIRST. The
        // node budget is shared across roots, so a large background window
        // read first could starve the very window the frame belongs to; the
        // cheap rect read below costs two attribute pulls per window and
        // removes that failure mode entirely.
        var seenRoots: Set<UInt64> = []
        let ordered = rootElements
            .map { (element: $0, overlap: Self.frameOverlap(MacAXSnapshot.axRect($0), frame)) }
            .enumerated()
            .sorted { a, b in
                a.element.overlap == b.element.overlap
                    ? a.offset < b.offset
                    : a.element.overlap > b.element.overlap
            }
            .map(\.element.element)

        var roots: [AXSnapshotNode] = []
        for element in ordered {
            let identity = MacAXSnapshot.identity(of: element)
            if seenRoots.contains(identity) { continue }
            seenRoots.insert(identity)
            guard let node = MacAXSnapshot.capture(
                element: element,
                frame: frame,
                depth: 0,
                budget: &budget
            ) else { continue }
            roots.append(node)
        }

        // Occlusion probe. Bounded: an AX hit test is an IPC round trip, and
        // this runs on every capture, so we spend at most `hitTestBudgetMs`
        // on it and then answer "don't know" (nil), which the probe reads as
        // "don't drop anything on a guess".
        let deadline = ContinuousClock().now.advanced(by: .milliseconds(Self.hitTestBudgetMs))
        let hitTest: MacMarkProbe.HitTest = { point in
            guard ContinuousClock().now < deadline else { return nil }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(appElem, Float(point.x), Float(point.y), &hit) == .success,
                  let element = hit else { return nil }
            return MacAXSnapshot.identity(of: element)
        }

        return MacMarkProbe.probe(roots: roots, frame: frame, hitTest: hitTest)
    }


    /// Pull a single AX attribute. Returns nil on any error (missing
    /// attribute, permission denied, etc.) so the caller can keep
    /// walking instead of throwing.
    nonisolated fileprivate static func axAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }
}

// MARK: - AX snapshot

/// Reads a live `AXUIElement` subtree into the plain `AXSnapshotNode` values
/// `MacMarkProbe` works over. This is the ONLY place the mark pipeline talks
/// to the accessibility API.
///
/// Every read is an IPC round trip to the target app, so the capture is
/// deliberately frugal: role and geometry for every node, the full label
/// attribute set only for nodes that could actually become a mark or supply
/// a label, and an early prune of subtrees that don't intersect the captured
/// frame (a background window's content can't appear in this image, so
/// there's no reason to pay for reading it).
enum MacAXSnapshot {

    /// Shared work budget for one capture: nodes visited and elements seen.
    /// Bounds a pathological app (deep outline, thousands of cells) to a
    /// predictable cost instead of stalling the step.
    struct Budget {
        var nodesRemaining: Int = 1500
        var maxDepth: Int = 24
        var visited: Set<UInt64> = []
        /// Wall-clock stop. `nil` (tests) means "no time limit"; production
        /// always sets one, because a node count bounds how MANY round trips
        /// we make, not how long each of them takes.
        var deadline: ContinuousClock.Instant?

        var expired: Bool {
            guard let deadline else { return false }
            return ContinuousClock().now >= deadline
        }
    }

    /// `CFHash` is equal for two references to the same AX element and
    /// stable for its lifetime — the identity `MacMarkProbe` de-duplicates
    /// on (W21) and hit-tests against.
    static func identity(of element: AXUIElement) -> UInt64 {
        UInt64(CFHash(element))
    }

    static func capture(
        element: AXUIElement,
        frame: CGRect,
        depth: Int,
        budget: inout Budget
    ) -> AXSnapshotNode? {
        if depth > budget.maxDepth { return nil }
        if budget.nodesRemaining <= 0 { return nil }
        if budget.expired { return nil }
        budget.nodesRemaining -= 1

        let identity = identity(of: element)
        // The AX graph is not a tree — the same element is reachable through
        // more than one parent (a menu, from both its owning control and the
        // window). Capturing it once is where menu duplication dies (W21).
        if budget.visited.contains(identity) { return nil }
        budget.visited.insert(identity)

        let role = (MacAppDriver.axAttribute(element, attribute: kAXRoleAttribute) as? String) ?? ""
        let rect = axRect(element)

        // Skip a WINDOW that can't appear in the captured frame at all —
        // there is no reason to pay for reading a background window's tree.
        //
        // The prune stops at the window: inside one, a child may legitimately
        // paint OUTSIDE its parent's rect. An open `Menu` is exactly that —
        // it hangs off the button that owns it while sitting well below the
        // button's own 24pt-tall rect — so pruning by geometry mid-tree
        // silently loses every menu item. Depth is bounded by the node
        // budget instead, which is what the pre-W19 walk relied on too.
        if let rect, depth == 0 {
            let inter = rect.intersection(frame)
            if inter.isNull || inter.width <= 0 || inter.height <= 0 { return nil }
        }

        let wantsLabels = MacMarkProbe.actionableRoles.contains(role)
            || MacMarkProbe.staticTextRoles.contains(role)

        var node = AXSnapshotNode(identity: identity, role: role, rect: rect)
        if wantsLabels {
            node.subrole = MacAppDriver.axAttribute(element, attribute: kAXSubroleAttribute) as? String
            node.title = MacAppDriver.axAttribute(element, attribute: kAXTitleAttribute) as? String
            node.value = stringValue(MacAppDriver.axAttribute(element, attribute: kAXValueAttribute))
            node.axDescription = MacAppDriver.axAttribute(element, attribute: kAXDescriptionAttribute) as? String
            node.help = MacAppDriver.axAttribute(element, attribute: kAXHelpAttribute) as? String
            node.placeholder = MacAppDriver.axAttribute(element, attribute: kAXPlaceholderValueAttribute) as? String
            node.identifier = MacAppDriver.axAttribute(element, attribute: kAXIdentifierAttribute) as? String
            node.enabled = (MacAppDriver.axAttribute(element, attribute: kAXEnabledAttribute) as? Bool) ?? true
            // `AXTitleUIElement` is the platform's own "that element is my
            // label" pointer. When an app sets it we take it verbatim rather
            // than inferring anything — it beats adjacency by construction.
            if let titleRef = MacAppDriver.axAttribute(element, attribute: kAXTitleUIElementAttribute),
               CFGetTypeID(titleRef) == AXUIElementGetTypeID() {
                let titleElement = unsafeDowncast(titleRef, to: AXUIElement.self)
                node.titleElementText =
                    (MacAppDriver.axAttribute(titleElement, attribute: kAXValueAttribute) as? String)
                    ?? (MacAppDriver.axAttribute(titleElement, attribute: kAXTitleAttribute) as? String)
            }
        }

        let childrenAny = MacAppDriver.axAttribute(element, attribute: kAXChildrenAttribute)
                       ?? MacAppDriver.axAttribute(element, attribute: kAXVisibleChildrenAttribute)
        if let children = childrenAny as? [AXUIElement] {
            var captured: [AXSnapshotNode] = []
            captured.reserveCapacity(children.count)
            for child in children {
                if budget.nodesRemaining <= 0 { break }
                if let childNode = capture(element: child, frame: frame, depth: depth + 1, budget: &budget) {
                    captured.append(childNode)
                }
            }
            node.children = captured
        }
        return node
    }

    /// AXValue is not always a string — a checkbox reports a number, a
    /// slider a double. Only string-ish values can be a label or page text.
    private static func stringValue(_ raw: AnyObject?) -> String? {
        if let s = raw as? String { return s }
        return nil
    }

    /// Read an element's global-screen-space rect from its position + size.
    static func axRect(_ element: AXUIElement) -> CGRect? {
        guard let posRef = MacAppDriver.axAttribute(element, attribute: kAXPositionAttribute),
              let sizeRef = MacAppDriver.axAttribute(element, attribute: kAXSizeAttribute) else {
            return nil
        }
        // Both the type check and `AXValueGetValue`'s own result matter. An
        // unchecked read of a wrong-typed value leaves `pos` at .zero, and a
        // rect at the global origin is not obviously bogus — on a frame
        // anchored at (0,0) it becomes a plausible-looking mark in the
        // corner. No geometry is better than invented geometry.
        guard CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(posRef, to: AXValue.self), .cgPoint, &pos),
              AXValueGetValue(unsafeDowncast(sizeRef, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }
}

// MARK: - Settle gate (WB-25)

/// The decision `awaitWindowStable` makes on each poll, as a pure function so
/// the suite can pin it. The loop around it is timing and IPC; THIS is the
/// contract, and it was the part with no test.
enum MacSettleGate {

    /// One poll's reading of the front frame.
    struct Sample: Equatable, Sendable {
        /// Perceptual hash of the captured window.
        var hash: UInt64
        /// Scoped AX geometry digest, or nil when the probe could not describe
        /// the frame completely (Accessibility denied, app mid-relaunch,
        /// snapshot budget exhausted). Nil is "no opinion", never "stable".
        var geometry: String?
    }

    /// Has the screen stopped moving?
    ///
    /// Both halves must agree with the previous poll:
    ///
    ///  * the pixels, within `AgentLoop.cycleHashThreshold` — unchanged from
    ///    the pre-WB-25 gate;
    ///  * the scoped AX geometry, exactly — because an 8×8 perceptual hash
    ///    cannot see a control still sliding five points into place, and five
    ///    points is the difference between a resolver matching and a flow
    ///    being reported `changed`.
    ///
    /// A nil on EITHER side is "no opinion": the pixel verdict then stands
    /// alone, which is exactly the behaviour this gate replaced. That is a
    /// deliberate asymmetry — treating an unreadable AX tree as instability
    /// would spend the full settle budget on every action of every app whose
    /// accessibility we cannot read, and would fail closed on a permission
    /// problem rather than degrading.
    static func isSettled(previous: Sample?, current: Sample) -> Bool {
        guard let previous else { return false }
        guard ScreenshotHasher.hammingDistance(current.hash, previous.hash)
                <= AgentLoop.cycleHashThreshold else { return false }
        if let a = previous.geometry, let b = current.geometry, a != b { return false }
        return true
    }
}

enum MacDriverError: Error, Sendable, LocalizedError {
    case appNotRunning(bundleID: String)
    /// No frontmost SUT window resolved. `screenAccessGranted` is a snapshot
    /// of `CGPreflightScreenCaptureAccess()` taken WHEN the error was built
    /// (never per-frame) so the message can be honest: window enumeration
    /// works without the Screen Recording grant, so a missing window WITH
    /// access is a genuine window problem — not a permissions one.
    case windowNotFound(bundleID: String, screenAccessGranted: Bool)
    /// The window resolved but `CGWindowListCreateImage` returned nothing.
    /// `screenAccessGranted` snapshots preflight at build time so we only
    /// blame permissions when they're actually the cause.
    case captureFailed(screenAccessGranted: Bool)
    case eventCreationFailed(action: String)
    case unknownKey(name: String)
    case unknownMark(id: Int)
    /// Contained backend exhausted its ladder without landing the action.
    /// `detail` names each rung attempted and why it didn't apply. There
    /// is deliberately no global-HID fallback — this is honest failure.
    case unactuatable(action: String, detail: String)

    /// TCC grants attach to the responsible parent process, not this binary,
    /// so we point the human at the app that launched `harness-mcp`.
    private static let grantHint = "Grant Harness the Screen Recording permission (Privacy & Security → Screen & System Audio Recording); the grant may attach to the parent app that launched harness-mcp, since macOS attributes it to the responsible process."

    /// Pure message selection for a capture failure — factored out so the
    /// granted/not-granted branch is unit-testable without real TCC state.
    static func captureFailureMessage(screenAccessGranted: Bool) -> String {
        if screenAccessGranted {
            return "Couldn't capture the target window — it may have just closed or moved off-screen. Re-observe to refresh the window; if it persists the app may have quit. (Screen Recording is granted, so this is not a permissions problem.)"
        }
        return "Screen capture failed. \(grantHint)"
    }

    /// Pure message selection for a missing window — same testable shape.
    static func windowNotFoundMessage(bundleID: String, screenAccessGranted: Bool) -> String {
        if screenAccessGranted {
            return "Couldn't find a frontmost window for '\(bundleID)' — it may be miniaturized, closed, or still launching. Re-observe once the window is visible. (Screen Recording is granted, so this is a window problem, not a permissions one.)"
        }
        return "Couldn't find a frontmost window for '\(bundleID)'. \(grantHint)"
    }

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let id):
            return "macOS app '\(id)' isn't running. Launch failed or it quit unexpectedly."
        case .windowNotFound(let id, let granted):
            return Self.windowNotFoundMessage(bundleID: id, screenAccessGranted: granted)
        case .captureFailed(let granted):
            return Self.captureFailureMessage(screenAccessGranted: granted)
        case .eventCreationFailed(let action):
            return "Failed to synthesise input event '\(action)'. Make sure Harness has Accessibility permission if needed."
        case .unknownKey(let name):
            return "Unknown key shortcut: '\(name)'. Use names like 'a'…'z', '0'…'9', 'return', 'escape', 'tab', 'space', 'delete', 'left'/'right'/'up'/'down', 'f1'…'f12'."
        case .unknownMark(let id):
            return "tap_mark(id: \(id)) — that id wasn't in the latest screenshot's mark set. The window may have changed; the next screenshot will refresh the marks."
        case .unactuatable(let action, let detail):
            return "Couldn't actuate '\(action)' in contained mode: \(detail). No global-HID fallback is used — this control could not be reached process-locally. Grant Accessibility to the responsible process, or set HARNESS_MACOS_INPUT=hid to opt into legacy pointer-driving input."
        }
    }
}

// MARK: - Virtual key code map

/// Minimal name → CGKeyCode map. Covers letters, digits, common control
/// keys, and arrows — sufficient for the macOS shortcuts the agent emits
/// in practice. Extend on demand.
enum MacKeyCodes {
    static func virtualKey(for name: String) -> CGKeyCode? {
        switch name {
        // Letters
        case "a": return 0x00; case "b": return 0x0B; case "c": return 0x08
        case "d": return 0x02; case "e": return 0x0E; case "f": return 0x03
        case "g": return 0x05; case "h": return 0x04; case "i": return 0x22
        case "j": return 0x26; case "k": return 0x28; case "l": return 0x25
        case "m": return 0x2E; case "n": return 0x2D; case "o": return 0x1F
        case "p": return 0x23; case "q": return 0x0C; case "r": return 0x0F
        case "s": return 0x01; case "t": return 0x11; case "u": return 0x20
        case "v": return 0x09; case "w": return 0x0D; case "x": return 0x07
        case "y": return 0x10; case "z": return 0x06
        // Digits
        case "0": return 0x1D; case "1": return 0x12; case "2": return 0x13
        case "3": return 0x14; case "4": return 0x15; case "5": return 0x17
        case "6": return 0x16; case "7": return 0x1A; case "8": return 0x1C
        case "9": return 0x19
        // Whitespace / control
        case "return", "enter": return 0x24
        case "tab":              return 0x30
        case "space":            return 0x31
        case "delete", "backspace": return 0x33
        case "escape":           return 0x35
        // Arrows
        case "left":  return 0x7B
        case "right": return 0x7C
        case "up":    return 0x7E
        case "down":  return 0x7D
        // Function row
        case "f1":  return 0x7A; case "f2":  return 0x78; case "f3":  return 0x63
        case "f4":  return 0x76; case "f5":  return 0x60; case "f6":  return 0x61
        case "f7":  return 0x62; case "f8":  return 0x64; case "f9":  return 0x65
        case "f10": return 0x6D; case "f11": return 0x67; case "f12": return 0x6F
        default: return nil
        }
    }
}
