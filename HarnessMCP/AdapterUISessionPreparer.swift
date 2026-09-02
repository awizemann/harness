//
//  AdapterUISessionPreparer.swift
//  HarnessMCP
//
//  Production `UISessionPreparing`: builds the real web / iOS platform
//  adapter (the same shapes `HarnessCLI/HarnessRunner` and
//  `HarnessMCP/RunBuilder` construct), calls `adapter.prepare(...)`, and
//  drains its `RunEvent` build-progress stream into the log. Returns the
//  live `RunSession` + adapter for the `UISessionSupervisor` to drive and
//  tear down.
//
//  NO LLM client, NO `RunCoordinator`, NO API key — session driving
//  bypasses the autonomous loop entirely. The history store handed to
//  `PlatformAdapterServices` is IN-MEMORY (the CLI precedent): sessions
//  never write run rows, and a locked on-disk GUI store must not gate the
//  QA path.
//
//  EXCEPT for credentials: `start_ui_session(credential_id:)` names a row
//  `stage_credential` wrote to the SHARED on-disk store, so a session that
//  asks for one is handed `credentialHistory` (that shared store) instead —
//  `resolveCredentialBinding` reads label + username from it and the
//  password from the Keychain, exactly as an autonomous run does. A session
//  with no `credentialID` keeps the in-memory store and the keychain stays
//  an unused slot (`resolveCredentialBinding` short-circuits on nil).
//

import CoreGraphics
import Foundation
import os

struct AdapterUISessionPreparer: UISessionPreparing {

    private static let logger = Logger(subsystem: "com.harness.app", category: "UISessionPreparer")

    /// In-memory store for the session itself (no run rows ever written).
    let history: any RunHistoryStoring
    /// The SHARED on-disk store `stage_credential` writes to. Only consulted
    /// when the session names a `credentialID`. Defaults to `history` so a
    /// test double needs to inject just one store.
    let credentialHistory: any RunHistoryStoring
    let keychain: any KeychainStoring

    init(
        history: any RunHistoryStoring,
        credentialHistory: (any RunHistoryStoring)? = nil,
        keychain: any KeychainStoring
    ) {
        self.history = history
        self.credentialHistory = credentialHistory ?? history
        self.keychain = keychain
    }

    func prepare(_ config: UISessionConfig, sessionID: UUID) async throws -> PreparedUISession {
        let processRunner = ProcessRunner()
        let toolLocator = ToolLocator(processRunner: processRunner)

        // The adapter resolves `request.credentialID` against whichever store
        // it is handed (`PlatformAdapterServices.resolveCredentialBinding` is
        // its only reader), so point it at the shared store precisely when a
        // credential was asked for.
        let adapterHistory: any RunHistoryStoring =
            config.credentialID == nil ? history : credentialHistory

        let request: RunRequest
        let adapter: any PlatformAdapter

        switch config.platform {
        case .web:
            guard let urlString = config.webURL, !urlString.isEmpty else {
                throw UISessionError.missingWebURL
            }
            let pseudoSim = SimulatorRef(
                udid: "harness-mcp-ui-web",
                name: "Web",
                runtime: "Web",
                pointSize: CGSize(width: config.viewportWidth, height: config.viewportHeight),
                scaleFactor: 1.0
            )
            let placeholderProject = ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/harness-mcp-ui-session"),
                scheme: "harness-mcp",
                displayName: "harness-mcp"
            )
            request = RunRequest(
                id: sessionID,
                name: "mcp-ui-session",
                goal: "ui-session",
                persona: "ui-session",
                payload: .ad_hoc,
                project: placeholderProject,
                simulator: pseudoSim,
                model: .opus47,
                mode: .autonomous,
                platformKindRaw: PlatformKind.web.rawValue,
                webStartURL: urlString,
                webViewportWidthPt: config.viewportWidth,
                webViewportHeightPt: config.viewportHeight,
                credentialID: config.credentialID
            )
            let services = PlatformAdapterServices(
                processRunner: processRunner,
                toolLocator: toolLocator,
                xcodeBuilder: NoopXcodeBuilder(),
                simulatorDriver: NoopSimulatorDriver(),
                promptLibrary: PromptLibrary(),
                keychain: keychain,
                runHistory: adapterHistory
            )
            // `sessionState` / `visibleWindow` ride on the ADAPTER, never on
            // `RunRequest`: RunRequest is the persisted run model, and a
            // cookie value must not reach a store, a log line, or a run row.
            // The adapter is a transient value scoped to this session.
            adapter = WebPlatformAdapter(
                services: services,
                sessionState: config.webSessionState,
                visibleWindow: config.webVisible
            )

        case .iosSimulator:
            guard let projectPath = config.iosProjectPath, !projectPath.isEmpty,
                  let scheme = config.iosScheme, !scheme.isEmpty,
                  let udid = config.iosSimulatorUDID, !udid.isEmpty else {
                throw UISessionError.missingIOSTarget
            }

            // Preflight (graceful web-only degradation): iOS needs Xcode
            // command-line tooling to build + boot. Probe up front so a bare
            // box or a stripped DEVELOPER_DIR yields ONE clear per-tool error
            // HERE rather than a late, obscure failure deep in the build — and
            // so web sessions, which never reach this branch, keep working.
            // `locateAll()` is internally bounded and reports missing tools as
            // nil (never throws on absence), so it can't wedge; the whole
            // prepare is also bounded by the supervisor's start timeout.
            let toolPaths = try await toolLocator.locateAll()
            let missingTools = toolPaths.allMissing
            guard missingTools.isEmpty else {
                throw UISessionError.xcodeToolingUnavailable(missingTools)
            }

            // Resolve WebDriverAgent source: HARNESS_WDA_PATH → bundled copy →
            // repo checkout. Throws an actionable UISessionError (clean MCP
            // tool error) before any adapter is built when nothing resolves,
            // instead of handing WDABuilder a bogus path.
            let wdaSource = try HarnessPaths.resolvedWDASource()

            let simRef = SimulatorRef(
                udid: udid,
                name: config.iosSimulatorName ?? "iOS Simulator",
                runtime: config.iosSimulatorRuntime ?? "iOS",
                pointSize: CGSize(width: 440, height: 956),
                scaleFactor: 3.0
            )
            let project = ProjectRequest(
                path: URL(fileURLWithPath: projectPath),
                scheme: scheme,
                displayName: scheme
            )
            request = RunRequest(
                id: sessionID,
                name: "mcp-ui-session",
                goal: "ui-session",
                persona: "ui-session",
                payload: .ad_hoc,
                project: project,
                simulator: simRef,
                model: .opus47,
                mode: .autonomous,
                platformKindRaw: PlatformKind.iosSimulator.rawValue,
                credentialID: config.credentialID
            )
            let wdaBuilder = WDABuilder(
                processRunner: processRunner,
                toolLocator: toolLocator,
                sourceURL: wdaSource
            )
            let simulatorDriver = SimulatorDriver(
                processRunner: processRunner,
                toolLocator: toolLocator,
                wdaBuilder: wdaBuilder,
                wdaRunner: WDARunner(processRunner: processRunner, toolLocator: toolLocator),
                wdaClient: WDAClient()
            )
            let services = PlatformAdapterServices(
                processRunner: processRunner,
                toolLocator: toolLocator,
                xcodeBuilder: XcodeBuilder(processRunner: processRunner, toolLocator: toolLocator),
                simulatorDriver: simulatorDriver,
                promptLibrary: PromptLibrary(),
                keychain: keychain,
                runHistory: adapterHistory
            )
            adapter = IOSPlatformAdapter(services: services)

        case .macosApp:
            // Prefer a prebuilt `.app` (the QA flow: drive a worktree build
            // product directly, no xcodebuild); otherwise build from
            // project + scheme. The supervisor already validated that one of
            // the two is present (and that app_path is absolute).
            let appPath = config.macAppPath
            let projectPath = config.macProjectPath
            let scheme = config.macScheme
            let hasApp = (appPath?.isEmpty == false)
            let hasProject = (projectPath?.isEmpty == false) && (scheme?.isEmpty == false)
            guard hasApp || hasProject else { throw UISessionError.missingMacTarget }

            // Build-from-source needs Xcode command-line tooling; preflight so
            // a bare box yields ONE clear per-tool error HERE rather than a
            // late, obscure failure deep in xcodebuild. A prebuilt app_path
            // skips the build entirely, so it needs no such probe.
            if hasProject && !hasApp {
                let toolPaths = try await toolLocator.locateAll()
                let missingTools = toolPaths.allMissing
                guard missingTools.isEmpty else {
                    throw UISessionError.xcodeToolingUnavailable(missingTools)
                }
            }

            let displayName = scheme
                ?? appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? "macOS app"
            // ProjectRequest is required by RunRequest; for the prebuilt path
            // the macOS adapter ignores it (macAppBundlePath wins), so a
            // placeholder is fine there.
            let project = ProjectRequest(
                path: URL(fileURLWithPath: projectPath ?? "/tmp/harness-mcp-ui-session"),
                scheme: scheme ?? "harness-mcp",
                displayName: displayName
            )
            // The macOS adapter synthesises its own pseudo SimulatorRef for
            // the `simulatorReady` "target is ready" cue; RunRequest needs a
            // non-nil one, so pass a placeholder (never used to boot a sim).
            let pseudoSim = SimulatorRef(
                udid: "harness-mcp-ui-macos",
                name: "macOS",
                runtime: "macOS",
                pointSize: CGSize(width: 1280, height: 800),
                scaleFactor: 1.0
            )
            request = RunRequest(
                id: sessionID,
                name: "mcp-ui-session",
                goal: "ui-session",
                persona: "ui-session",
                payload: .ad_hoc,
                project: project,
                simulator: pseudoSim,
                model: .opus47,
                mode: .autonomous,
                platformKindRaw: PlatformKind.macosApp.rawValue,
                macAppBundlePath: hasApp ? appPath : nil,
                credentialID: config.credentialID
            )
            let services = PlatformAdapterServices(
                processRunner: processRunner,
                toolLocator: toolLocator,
                xcodeBuilder: XcodeBuilder(processRunner: processRunner, toolLocator: toolLocator),
                simulatorDriver: NoopSimulatorDriver(),
                promptLibrary: PromptLibrary(),
                keychain: keychain,
                runHistory: adapterHistory
            )
            // terminatesOnTeardown: a ui-session ending must QUIT the SUT
            // (unlike a GUI run, which leaves it open for inspection).
            // W26 — the caller's fixture-mode switches ride on the adapter,
            // not on `RunRequest`: a RunRequest is a persisted, Codable
            // record, and an env value can be a secret. Keeping them here
            // means they exist only for the life of this session's launch.
            adapter = MacOSPlatformAdapter(
                services: services,
                terminatesOnTeardown: true,
                launchEnvironment: config.macLaunchEnvironment ?? [:],
                launchArguments: config.macLaunchArguments ?? []
            )
        }

        // Drain the adapter's build-progress stream (iOS emits buildStarted /
        // buildCompleted / simulatorReady; web just simulatorReady) so it
        // doesn't leak, folding the last phase into a log line. Any thrown
        // build error propagates out of `prepare(...)` (its
        // `localizedDescription` carries the xcodebuild tail for
        // `XcodeBuilderError.compileFailed`).
        let (stream, continuation) = AsyncThrowingStream<RunEvent, any Error>.makeStream()
        let drain = Task<Void, Never> {
            var last = ""
            do {
                for try await event in stream { last = Self.describe(event) ?? last }
            } catch {
                // The prepare error surfaces via `adapter.prepare`'s throw;
                // the stream side just stops.
            }
            if !last.isEmpty {
                Self.logger.info("session \(sessionID.uuidString, privacy: .public) prepare progress: \(last, privacy: .public)")
            }
        }
        defer { continuation.finish() }

        do {
            let session = try await adapter.prepare(request, runID: sessionID, continuation: continuation)
            continuation.finish()
            await drain.value
            return PreparedUISession(session: session, adapter: adapter)
        } catch {
            continuation.finish()
            await drain.value
            throw UISessionError.prepareFailed(error.localizedDescription)
        }
    }

    private static func describe(_ event: RunEvent) -> String? {
        switch event {
        case .buildStarted:                 return "building…"
        case .buildCompleted(_, let id):    return "built (\(id))"
        case .simulatorReady(let ref):      return "ready (\(ref.name))"
        default:                            return nil
        }
    }
}
