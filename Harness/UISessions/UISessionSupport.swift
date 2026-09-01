//
//  UISessionSupport.swift
//  Harness
//
//  Value types, protocols, and helpers for the step-level UI session
//  registry (`UISessionSupervisor`). Kept in the `Harness/` source root —
//  not the `HarnessMCP/` target — so the whole registry surface is
//  unit-testable via `@testable import Harness` (the test bundle links the
//  Harness app module; the HarnessMCP target is not in the test graph).
//
//  The MCP server owns the JSON-RPC glue (`HarnessMCP/UISessionTools.swift`)
//  and the concrete adapter preparer (`HarnessMCP/AdapterUISessionPreparer.swift`);
//  everything genuinely testable — lifecycle, cap enforcement, idle
//  teardown, artifact writing, tool validation/mapping — lives here.
//
//  These tools drive a target WITHOUT Harness's own LLM loop: an external
//  MCP client (another product's QA agent) launches a target, SEES it
//  (screenshots + Set-of-Mark marks), and ACTS on it. No API key is ever
//  required on this path.
//

import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-repo tool-name contract

/// The five step-session tool names. **This is a cross-repo contract**
/// (Orchestric's QA agent pre-allows the `mcp__harness__*` prefix and
/// dispatches these exact names) — the raw values must not drift. The MCP
/// `ToolRegistry` builds its definitions from these cases so the wire names
/// have a single source of truth that the test suite pins.
enum UISessionTool: String, CaseIterable, Sendable {
    case startUISession = "start_ui_session"
    case observeUI      = "observe_ui"
    case actUI          = "act_ui"
    case endUISession   = "end_ui_session"
    case listUISessions = "list_ui_sessions"
    /// Web only. Returns the live session's cookies + current-origin
    /// localStorage in the SAME shape `start_ui_session(session_state:)`
    /// accepts, so a human-authenticated visible session round-trips into
    /// later headless ones. The result is SENSITIVE — see the tool
    /// description and `WebSessionState`.
    case exportUISessionState = "export_ui_session_state"
}

// MARK: - Tool policy (act_ui validation)

/// Which tools `act_ui` accepts. Session driving is action-only — the
/// meta/non-action tools that only make sense inside the autonomous loop
/// (`read_screen` forces a re-capture, `note_friction` records UX notes,
/// `mark_goal_done` terminates a run) are rejected, since `observe_ui`
/// already re-captures and there is no run to terminate or annotate.
enum UIToolPolicy {
    /// Non-action tools rejected by `act_ui`. Matches the `UXDriving`
    /// contract's "non-action tools are no-ops at the driver layer"
    /// note — the loop handles them upstream, and there is no loop here.
    static let metaTools: Set<String> = [
        ToolKind.readScreen.rawValue,
        ToolKind.noteFriction.rawValue,
        ToolKind.markGoalDone.rawValue
    ]

    /// Validate a requested `act_ui` tool against the active platform's
    /// vocabulary. Throws a precise error the agent can act on.
    ///
    /// - `allowed`: the platform adapter's `toolNames()` (its real
    ///   vocabulary — the same list `AgentLoop` validates model output
    ///   against).
    static func validate(tool: String, allowed: [String]) throws {
        if metaTools.contains(tool) {
            throw UISessionError.metaToolRejected(tool)
        }
        guard allowed.contains(tool) else {
            let actionable = allowed.filter { !metaTools.contains($0) }.sorted()
            throw UISessionError.unsupportedTool(tool, allowed: actionable)
        }
    }
}

// MARK: - Config / info / observation value types

/// Everything `start_ui_session` needs to stand up a session. Sendable so
/// it crosses the actor boundary cleanly.
struct UISessionConfig: Sendable {
    var platform: PlatformKind
    /// Absolute path (validated by the supervisor) where the full bundle is
    /// written: `steps/NNN.png` (CLEAN frames) + `steps.jsonl`. `nil` →
    /// a temp location under Harness's runs root.
    var artifactDirPath: String?

    // Web
    var webURL: String?
    var viewportWidth: Int
    var viewportHeight: Int

    /// Web only — cookies / localStorage to seed into the session's still
    /// NON-PERSISTENT data store before the first navigation. `nil` keeps the
    /// fresh-user invariant untouched, which is what every session that does
    /// not explicitly ask for state gets.
    ///
    /// SECRET: never log this. Log `redactedSummary` if you must log anything.
    var webSessionState: WebSessionState?
    /// Web only — show the session window on screen so a human can interact
    /// with it (log in by hand, solve an SSO prompt). Default `false`.
    var webVisible: Bool

    /// A credential staged with `stage_credential`, made available to this
    /// session's `fill_credential` action. ALL platforms.
    ///
    /// Only the ID travels here — the username is read from the store and
    /// the password from the Keychain at prepare time, exactly as an
    /// autonomous run does (`PlatformAdapterServices.resolveCredentialBinding`).
    /// The resolved values live on the driver for the session's lifetime and
    /// never reach a result, a log line, or `steps.jsonl`. `nil` → the
    /// session has no credential and `fill_credential` FAILS the step.
    var credentialID: UUID?

    // iOS
    var iosProjectPath: String?
    var iosScheme: String?
    var iosSimulatorUDID: String?
    var iosSimulatorName: String?
    var iosSimulatorRuntime: String?
    /// Optional prebuilt `.app` bundle path for iOS (skips xcodebuild when
    /// the existing request model already accepts one). Reserved — the
    /// current preparer builds from project + scheme.
    var iosAppBundlePath: String?

    // macOS
    /// Absolute path to a built `.app` bundle — the PREFERRED macOS QA flow
    /// (drive a worktree build product directly, no xcodebuild). One of
    /// `macAppPath` OR (`macProjectPath` + `macScheme`) is required.
    var macAppPath: String?
    /// Absolute path to a `.xcodeproj`/`.xcworkspace` for the fallback
    /// build-from-source macOS flow.
    var macProjectPath: String?
    /// Xcode scheme for the build-from-source macOS flow.
    var macScheme: String?

    init(
        platform: PlatformKind,
        artifactDirPath: String? = nil,
        webURL: String? = nil,
        viewportWidth: Int = 1280,
        viewportHeight: Int = 800,
        webSessionState: WebSessionState? = nil,
        webVisible: Bool = false,
        credentialID: UUID? = nil,
        iosProjectPath: String? = nil,
        iosScheme: String? = nil,
        iosSimulatorUDID: String? = nil,
        iosSimulatorName: String? = nil,
        iosSimulatorRuntime: String? = nil,
        iosAppBundlePath: String? = nil,
        macAppPath: String? = nil,
        macProjectPath: String? = nil,
        macScheme: String? = nil
    ) {
        self.platform = platform
        self.artifactDirPath = artifactDirPath
        self.webURL = webURL
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.webSessionState = webSessionState
        self.webVisible = webVisible
        self.credentialID = credentialID
        self.iosProjectPath = iosProjectPath
        self.iosScheme = iosScheme
        self.iosSimulatorUDID = iosSimulatorUDID
        self.iosSimulatorName = iosSimulatorName
        self.iosSimulatorRuntime = iosSimulatorRuntime
        self.iosAppBundlePath = iosAppBundlePath
        self.macAppPath = macAppPath
        self.macProjectPath = macProjectPath
        self.macScheme = macScheme
    }
}

/// What `start_ui_session` / `list_ui_sessions` report about a session.
struct UISessionInfo: Sendable, Hashable {
    let id: UUID
    let platform: PlatformKind
    let displayLabel: String
    let pointSize: CGSize
    let createdAt: Date
    /// Seconds since the last observe/act on this session (0 at creation).
    let idleSeconds: Int
}

/// One captured observation — returned by both `observe_ui` and (after the
/// action) `act_ui`. Carries the downscaled image bytes plus the mark
/// table + session identity so the MCP layer can format content directly.
struct UIObservation: Sendable {
    let sessionID: UUID
    let platform: PlatformKind
    let displayLabel: String
    let pointSize: CGSize
    /// Downscaled PNG bytes for the MCP `image` content block. Marked
    /// (Set-of-Mark badges) unless `clean` was requested.
    let imageData: Data
    let imageIsMarked: Bool
    /// `MarkRenderer.describe(...)` output — the `id → "label" (role)`
    /// table. `nil` when the driver produced no marks (probe failure, or
    /// a page/screen with no interactive elements).
    let markTable: String?
    let markCount: Int
    /// The same marks `markTable` describes, kept as structured geometry.
    /// Rects are in `pointSize` space. Empty when the driver produced no
    /// marks — and also, for a driver that fills only the older
    /// `markedAnnotationText`, when a table IS present; `markCount` covers
    /// both. Encoded into the MCP result's `structuredContent.marks`.
    let marks: [InteractiveMark]
    /// Visible page text for the observed frame, normalized + capped by the
    /// driver. Web only — iOS / macOS leave it nil (see `ScreenshotMetadata`).
    let pageText: String?
    /// 1-based observation index within the session (the `NNN` in
    /// `steps/NNN.png`).
    let stepIndex: Int
    /// Relative artifact ref, e.g. `steps/003.png`.
    let screenshotRef: String
    /// Driver-supplied post-action detail (web scroll progress, etc.) or the
    /// execution error. Populated for `act_ui`; `nil` for a plain `observe_ui`.
    let lastExecutionDetail: String?
    /// True when this observation followed an `act_ui` whose `driver.execute`
    /// threw (e.g. a stale `tap_mark` id). The MCP layer flags the result as
    /// `isError` while STILL returning the fresh frame + mark table so the
    /// agent sees the current state alongside the failure.
    let actionFailed: Bool
}

/// Result of `end_ui_session`. Idempotent — ending an unknown/closed
/// session is a calm success, never an error.
struct UISessionEndResult: Sendable {
    let id: UUID
    let wasOpen: Bool
    let message: String
}

// MARK: - Preparer seam

/// A prepared, ready-to-drive session plus the adapter that owns its
/// lifecycle (kept for idempotent teardown). Sendable — `RunSession` and
/// `any PlatformAdapter` both are.
struct PreparedUISession: Sendable {
    let session: RunSession
    let adapter: any PlatformAdapter
}

/// Builds a live `RunSession` for a config. Production conformer
/// (`AdapterUISessionPreparer`, in the MCP target) constructs the real
/// web / iOS platform adapter and calls `adapter.prepare(...)`; tests
/// inject a fake that returns a fake `UXDriving` — no WebKit, no xcodebuild.
protocol UISessionPreparing: Sendable {
    func prepare(_ config: UISessionConfig, sessionID: UUID) async throws -> PreparedUISession
}

// MARK: - Errors

enum UISessionError: Error, Sendable, LocalizedError {
    case relativeArtifactDir(String)
    case capReached(Int)
    case sessionNotFound(UUID)
    /// The id WAS a session in this process and is not any more — ended,
    /// idle-swept, or torn down at shutdown. Distinct from `sessionNotFound`
    /// on purpose (W32): "your session died under you" and "that id was never
    /// a session here" call for different reactions from the caller.
    case sessionEnded(id: UUID, reason: String, endedAt: Date)
    case unsupportedTool(String, allowed: [String])
    case metaToolRejected(String)
    case startTimedOut(seconds: Int, platform: PlatformKind)
    case prepareFailed(String)
    case missingWebURL
    case missingIOSTarget
    /// macOS start with neither a prebuilt `app_path` nor a
    /// `project_path` + `scheme` pair to build from.
    case missingMacTarget
    /// macOS `app_path` was given but is not an absolute path.
    case relativeMacAppPath(String)
    /// iOS start on a machine without usable Xcode command-line tooling
    /// (xcrun/xcodebuild) — e.g. a bare box or a stripped `DEVELOPER_DIR`.
    /// Web sessions still work; iOS can't build/boot without it.
    case xcodeToolingUnavailable([Tool])
    /// iOS start where no WebDriverAgent source resolves (no
    /// `HARNESS_WDA_PATH`, no bundled copy, no repo checkout).
    case wdaSourceUnresolved
    /// `HARNESS_WDA_PATH` is set but the directory has no `WebDriverAgent.xcodeproj`.
    case wdaEnvPathInvalid(String)
    /// A web-only session capability (`session_state`, `visible`,
    /// `export_ui_session_state`) was asked for on an iOS / macOS session.
    case webOnlyCapability(String, PlatformKind)
    /// `credential_id` doesn't resolve to a staged credential in the shared
    /// store (wrong id, or staged against a different Harness install).
    case credentialNotStaged(UUID)
    /// The credential row exists but its Keychain password doesn't —
    /// a half-staged credential. Caught at START so the failure lands where
    /// the caller can fix it, not mid-session on the first fill.
    case credentialPasswordMissing(id: UUID, label: String)
    /// The session is a web session but its driver isn't the WebKit one —
    /// only reachable with an injected test double; reported honestly rather
    /// than returning a silently empty state.
    case sessionStateUnavailable

    var errorDescription: String? {
        switch self {
        case .relativeArtifactDir(let path):
            return "artifact_dir must be an absolute path (got \"\(path)\"). Pass a path starting with \"/\"."
        case .capReached(let cap):
            return "Concurrent UI session limit reached (\(cap)). End an existing session with end_ui_session before starting another."
        case .sessionNotFound(let id):
            return "No UI session with id \(id.uuidString) has ever been open in this engine process. Check the id, or start a new session — if harness-mcp restarted since you got that id, every session it was holding died with it (sessions do not survive the process). Call list_ui_sessions to see what is open now."
        case .sessionEnded(let id, let reason, let endedAt):
            let ago = max(0, Int(Date().timeIntervalSince(endedAt)))
            return "UI session \(id.uuidString) was open in this process but closed \(ago)s ago — \(reason). The target app is gone with it; start a new session with start_ui_session. Call list_ui_sessions to see what is still open."
        case .unsupportedTool(let tool, let allowed):
            return "Tool '\(tool)' is not available on this platform. Supported action tools: \(allowed.joined(separator: ", "))."
        case .metaToolRejected(let tool):
            return "Tool '\(tool)' is a meta tool and does not apply to act_ui (observe_ui already re-captures; there is no run to terminate). Use an action tool."
        case .startTimedOut(let seconds, let platform):
            return "Starting the \(platform.displayName) session exceeded \(seconds)s and was aborted. For iOS, a slow/hung xcodebuild is the usual cause; check the project builds standalone."
        case .prepareFailed(let detail):
            return "Failed to start UI session: \(detail)"
        case .missingWebURL:
            return "Web sessions require a 'url'."
        case .missingIOSTarget:
            return "iOS sessions require 'project_path' + 'scheme' + 'simulator_udid'."
        case .missingMacTarget:
            return "macOS sessions require an absolute 'app_path' to a built .app (the preferred QA flow), or 'project_path' + 'scheme' to build from source."
        case .relativeMacAppPath(let path):
            return "macOS 'app_path' must be an absolute path to a built .app (got \"\(path)\"). Pass a path starting with \"/\"."
        case .xcodeToolingUnavailable(let tools):
            let names = tools.map(\.displayName).joined(separator: ", ")
            return "iOS sessions need Xcode command-line tooling, but it's unavailable (missing: \(names.isEmpty ? "xcodebuild" : names)). Install Xcode and run `xcode-select --install`, or point DEVELOPER_DIR at a valid Xcode. Web sessions work without it."
        case .wdaSourceUnresolved:
            return "No WebDriverAgent source resolved for the iOS session. Set \(HarnessPaths.wdaSourceEnvVar) to a WebDriverAgent checkout (the directory containing WebDriverAgent.xcodeproj — e.g. the harness repo's vendor/WebDriverAgent) so the standalone binary can build the iOS driver. Web sessions need no such setup."
        case .wdaEnvPathInvalid(let path):
            return "\(HarnessPaths.wdaSourceEnvVar) is set to \"\(path)\" but no WebDriverAgent.xcodeproj was found there. Point it at a WebDriverAgent checkout (the directory that contains WebDriverAgent.xcodeproj)."
        case .webOnlyCapability(let name, let platform):
            return "'\(name)' applies to web sessions only (this session is \(platform.displayName)). A native app has no cookie jar or localStorage to seed or export."
        case .credentialNotStaged(let id):
            return "No staged credential with id \(id.uuidString). Stage one with stage_credential (its password goes to the Keychain only), or call list_credentials for an application to see the ids it already has."
        case .credentialPasswordMissing(let id, let label):
            return "Credential \(id.uuidString) (\"\(label)\") has no password in the Keychain — it was never fully staged, or the Keychain entry was removed. Re-stage it with stage_credential."
        case .sessionStateUnavailable:
            return "This session's driver does not expose cookie / localStorage state."
        }
    }
}

// MARK: - Image helper

/// Downscaling for the returned session images. Mirrors
/// `RunCoordinator.downscaleJPEG(_:toPointSize:)`'s bitmap approach (the
/// LLM-copy path) but emits PNG — the session tools return lossless PNG
/// image content, matching the existing `get_step_screenshot` shape.
enum UISessionImage {
    /// Downscale `data` to `pointSize` and re-encode as PNG. For web
    /// (scaleFactor 1) point size equals pixel size, so this is a no-op
    /// re-encode; for iOS (pixel = point × 3) it is a real 3× reduction,
    /// matching the unit the model / agent speaks in.
    static func downscalePNG(_ data: Data, toPointSize pointSize: CGSize) -> Data? {
        #if canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        let w = max(1, Int(pointSize.width.rounded()))
        let h = max(1, Int(pointSize.height.rounded()))
        let targetSize = NSSize(width: w, height: h)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: targetSize))
        }
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    /// Count the `id → label` rows in a `MarkRenderer.describe(...)` block
    /// (each mark line carries a `→`; the header line does not). Used only
    /// for the observe payload's convenience count.
    static func markCount(inAnnotation annotation: String?) -> Int {
        guard let annotation else { return 0 }
        return annotation
            .split(separator: "\n")
            .filter { $0.contains("→") }
            .count
    }
}
