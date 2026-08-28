//
//  UISessionSupervisor.swift
//  Harness
//
//  In-process registry for step-level UI sessions. Sits BESIDE the MCP
//  server's `RunSupervisor` (same style: detached bookkeeping, an idle
//  watchdog, idempotent teardown) but drives a target WITHOUT the LLM loop
//  — an external MCP client launches a target, observes it (screenshot +
//  Set-of-Mark marks), and acts on it directly.
//
//  Lives in the `Harness/` module (not `HarnessMCP/`) so the whole surface
//  is unit-testable; the concrete session preparer and JSON-RPC glue live
//  in the MCP target. See `UISessionSupport.swift` for the value types.
//
//  Invariants held here:
//    - Concurrent-session cap (default 2); clear error beyond.
//    - Per-session idle teardown (default 600s; env-overridable at the MCP
//      composition root) via a single actor-owned sweeper.
//    - Idempotent teardown, also run for every session on shutdown.
//    - CLEAN frames only on disk (`steps/NNN.png`); the marked image never
//      touches disk (standard 14 §6). `steps.jsonl` records each observation.
//

import CoreGraphics
import Foundation
import os

actor UISessionSupervisor {

    private let logger = Logger(subsystem: "com.harness.app", category: "UISessionSupervisor")

    /// Concurrent-session cap. Two lets a QA agent compare two targets /
    /// viewports without unbounded WebKit / simulator fan-out.
    static let maxConcurrentSessions = 2

    private let preparer: any UISessionPreparing
    /// Seconds of inactivity before a session is auto-torn-down. `0`
    /// disables the sweeper entirely. Resolved from the environment at the
    /// MCP composition root (`HARNESS_UI_SESSION_IDLE_TIMEOUT_SECONDS`).
    private let idleTimeoutSeconds: Int
    /// Optional override for the bounded `start` wait. `nil` → per-platform
    /// defaults (web 120s, iOS 900s). Always finite — `start` can never wedge.
    private let startTimeoutOverrideSeconds: Int?
    /// Base directory for sessions started WITHOUT an explicit `artifact_dir`.
    /// `nil` (production default) → `<runs>/ui-sessions/`, byte-identical to
    /// the historical behavior. Tests inject a per-test temporary root so a
    /// suite run never litters `~/Library/Application Support/Harness`.
    private let defaultArtifactRoot: URL?

    private var sessions: [UUID: Entry] = [:]
    /// Starts that have passed the cap check but haven't finished `prepare`
    /// yet. Counted against the cap so two concurrent `start`s can't both
    /// slip past it across the prepare await. (The MCP read loop is serial
    /// today, but the actor enforces its own invariant regardless of caller.)
    private var pendingStarts = 0
    private var sweeper: Task<Void, Never>?

    init(
        preparer: any UISessionPreparing,
        idleTimeoutSeconds: Int = 600,
        startTimeoutOverrideSeconds: Int? = nil,
        defaultArtifactRoot: URL? = nil
    ) {
        self.preparer = preparer
        self.idleTimeoutSeconds = max(0, idleTimeoutSeconds)
        self.startTimeoutOverrideSeconds = startTimeoutOverrideSeconds
        self.defaultArtifactRoot = defaultArtifactRoot
    }

    /// Per-session bookkeeping. Reference type kept strictly on the actor
    /// (never crosses an isolation boundary), so it needn't be Sendable.
    private final class Entry {
        /// The supervisor-minted session id (the registry key). `RunSession`
        /// itself carries no id — the id lives here.
        let id: UUID
        let session: RunSession
        let adapter: any PlatformAdapter
        let platform: PlatformKind
        let displayLabel: String
        let pointSize: CGSize
        let createdAt: Date
        var lastActivityAt: Date
        var stepIndex = 0
        let artifactRoot: URL
        var tornDown = false

        init(id: UUID, prepared: PreparedUISession, artifactRoot: URL, now: Date) {
            self.id = id
            self.session = prepared.session
            self.adapter = prepared.adapter
            self.platform = prepared.session.kind
            self.displayLabel = prepared.session.displayLabel
            self.pointSize = prepared.session.pointSize
            self.createdAt = now
            self.lastActivityAt = now
            self.artifactRoot = artifactRoot
        }
    }

    // MARK: - start

    func start(_ config: UISessionConfig) async throws -> UISessionInfo {
        // 1. artifact_dir, when provided, must be absolute.
        if let raw = config.artifactDirPath, !raw.isEmpty {
            guard (raw as NSString).isAbsolutePath else {
                throw UISessionError.relativeArtifactDir(raw)
            }
        }

        // 1b. `session_state` / `visible` are web-only. Reject them loudly on
        //     a native platform rather than accepting an argument that would
        //     be silently dropped — a client that thinks it injected an auth
        //     cookie and got a logged-out session deserves the error.
        if config.platform != .web {
            if let state = config.webSessionState, !state.isEmpty {
                throw UISessionError.webOnlyCapability("session_state", config.platform)
            }
            if config.webVisible {
                throw UISessionError.webOnlyCapability("visible", config.platform)
            }
        }

        // 2. Platform target sanity (clearer than letting the adapter throw).
        switch config.platform {
        case .web:
            guard let url = config.webURL, !url.isEmpty else { throw UISessionError.missingWebURL }
            _ = url
        case .iosSimulator:
            // The preparer builds from project + scheme on a specific
            // simulator; require all three so the error is precise here
            // rather than late from `prepare`. (Prebuilt-.app support is a
            // Phase B item — the iOS RunRequest model builds from project.)
            let hasIOS = (config.iosProjectPath?.isEmpty == false)
                && (config.iosScheme?.isEmpty == false)
                && (config.iosSimulatorUDID?.isEmpty == false)
            guard hasIOS else { throw UISessionError.missingIOSTarget }
        case .macosApp:
            // Prefer a prebuilt `.app` (the QA flow: drive a worktree build
            // product directly); otherwise `project_path` + `scheme` to build
            // from source. Require one of the two so the error is precise HERE
            // rather than late from `prepare`.
            let hasApp = (config.macAppPath?.isEmpty == false)
            let hasProject = (config.macProjectPath?.isEmpty == false)
                && (config.macScheme?.isEmpty == false)
            guard hasApp || hasProject else { throw UISessionError.missingMacTarget }
            // A prebuilt app_path, when given, must be absolute (same rule as
            // artifact_dir — a relative build product can't be resolved here).
            if let appPath = config.macAppPath, !appPath.isEmpty {
                guard (appPath as NSString).isAbsolutePath else {
                    throw UISessionError.relativeMacAppPath(appPath)
                }
            }
        }

        // 3. Concurrency cap — count live sessions AND in-flight starts.
        guard sessions.count + pendingStarts < Self.maxConcurrentSessions else {
            throw UISessionError.capReached(Self.maxConcurrentSessions)
        }

        // 4. Prepare (bounded — never wedges). Reserve the slot across the
        //    await so a concurrent start can't overshoot the cap.
        let sessionID = UUID()
        let seconds = startTimeoutOverrideSeconds ?? Self.defaultStartTimeout(for: config.platform)
        let prepared: PreparedUISession
        pendingStarts += 1
        do {
            prepared = try await preparedWithTimeout(config, sessionID: sessionID, seconds: seconds)
        } catch {
            pendingStarts -= 1
            throw error
        }
        pendingStarts -= 1   // synchronous from here to the insert below — no reentrancy

        // 5. Resolve the artifact root now that we know the id.
        let artifactRoot = resolveArtifactRoot(config: config, sessionID: sessionID)
        try? HarnessPaths.ensureDirectory(artifactRoot)

        let now = Date()
        let entry = Entry(
            id: sessionID,
            prepared: prepared,
            artifactRoot: artifactRoot,
            now: now
        )
        sessions[sessionID] = entry
        startSweeperIfNeeded()

        logger.info("started UI session \(sessionID.uuidString, privacy: .public) platform=\(config.platform.rawValue, privacy: .public) label=\(entry.displayLabel, privacy: .public) artifacts=\(artifactRoot.path, privacy: .public)")

        return UISessionInfo(
            id: sessionID,
            platform: entry.platform,
            displayLabel: entry.displayLabel,
            pointSize: entry.pointSize,
            createdAt: now,
            idleSeconds: 0
        )
    }

    // MARK: - observe

    func observe(id: UUID, clean: Bool) async throws -> UIObservation {
        guard let entry = sessions[id], !entry.tornDown else {
            throw UISessionError.sessionNotFound(id)
        }
        entry.lastActivityAt = Date()   // reset idle before the (bounded) capture
        return try await capture(entry, executed: nil, preferMarked: !clean, lastDetail: nil)
    }

    // MARK: - act

    func act(id: UUID, tool: String, inputData: Data) async throws -> UIObservation {
        guard let entry = sessions[id], !entry.tornDown else {
            throw UISessionError.sessionNotFound(id)
        }
        entry.lastActivityAt = Date()

        // Validate against the platform's real vocabulary; reject meta tools.
        try UIToolPolicy.validate(tool: tool, allowed: entry.adapter.toolNames())

        // Map name + args → typed ToolCall (reuses the exact decoder the LLM
        // path uses, incl. numeric-string coercion + credential redaction).
        let call: ToolCall
        do {
            call = try LLMShared.toolCall(name: tool, inputData: inputData)
        } catch {
            throw UISessionError.prepareFailed("could not map tool '\(tool)': \(error.localizedDescription)")
        }

        let driver = entry.session.driver
        var execError: String?
        do {
            try await driver.execute(call)
            await driver.settle(afterTool: call)
        } catch {
            execError = error.localizedDescription
        }
        let detail = await driver.lastExecutionDetail()
        let resultSummary = execError.map { "error: \($0)" } ?? detail

        entry.lastActivityAt = Date()
        return try await capture(
            entry, executed: call, preferMarked: true,
            lastDetail: resultSummary, actionFailed: execError != nil
        )
    }

    // MARK: - export session state (web only)

    /// Read the live web session's cookies + current-origin `localStorage`.
    ///
    /// **The return value is a bag of credentials.** The supervisor does not
    /// log it, does not write it to `steps.jsonl`, and does not keep a copy:
    /// it goes straight to the `export_ui_session_state` tool result and
    /// nowhere else. `lastActivityAt` is refreshed (this IS activity — a
    /// human mid-login must not be idle-swept), but no step is captured and
    /// no artifact row is appended, so nothing about this call touches disk.
    func exportWebSessionState(id: UUID) async throws -> WebSessionState {
        guard let entry = sessions[id], !entry.tornDown else {
            throw UISessionError.sessionNotFound(id)
        }
        guard entry.platform == .web else {
            throw UISessionError.webOnlyCapability(
                UISessionTool.exportUISessionState.rawValue, entry.platform
            )
        }
        guard let driver = entry.session.driver as? WebDriver else {
            throw UISessionError.sessionStateUnavailable
        }
        entry.lastActivityAt = Date()
        let state = await driver.exportSessionState()
        entry.lastActivityAt = Date()
        // Counts only. Never the values.
        logger.info("exported session state for \(id.uuidString, privacy: .public): \(state.redactedSummary, privacy: .public)")
        return state
    }

    // MARK: - end / list

    /// Idempotent. An unknown / already-closed id is a calm success.
    func end(id: UUID) async -> UISessionEndResult {
        guard sessions[id] != nil else {
            return UISessionEndResult(id: id, wasOpen: false, message: "already closed")
        }
        await teardown(id: id, reason: "end_ui_session")
        return UISessionEndResult(id: id, wasOpen: true, message: "closed")
    }

    func list() -> [UISessionInfo] {
        let now = Date()
        return sessions.values
            .filter { !$0.tornDown }
            .map { entry in
                UISessionInfo(
                    id: entry.id,
                    platform: entry.platform,
                    displayLabel: entry.displayLabel,
                    pointSize: entry.pointSize,
                    createdAt: entry.createdAt,
                    idleSeconds: max(0, Int(now.timeIntervalSince(entry.lastActivityAt)))
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Tear down every open session. Run on server-shutdown paths so no
    /// WKWebView window / booted simulator / WDA process leaks.
    func shutdownAll() async {
        sweeper?.cancel()
        sweeper = nil
        for id in Array(sessions.keys) {
            await teardown(id: id, reason: "server shutdown")
        }
    }

    // MARK: - Idle sweep (test seam + watchdog core)

    /// Tear down sessions idle ≥ `idleTimeoutSeconds` as of `now`. Returns
    /// the ids torn down. Called on a timer by the sweeper; called directly
    /// (with a synthetic `now`) by tests so idle teardown is deterministic,
    /// not timing-dependent.
    @discardableResult
    func sweepIdle(now: Date = Date()) async -> [UUID] {
        guard idleTimeoutSeconds > 0 else { return [] }
        let stale = sessions.values
            .filter { !$0.tornDown && now.timeIntervalSince($0.lastActivityAt) >= Double(idleTimeoutSeconds) }
            .map(\.id)
        for id in stale {
            let idle = Int(now.timeIntervalSince(sessions[id]?.lastActivityAt ?? now))
            await teardown(id: id, reason: "idle watchdog: no activity for ~\(idle)s")
        }
        return stale
    }

    // MARK: - Internals

    private func startSweeperIfNeeded() {
        guard idleTimeoutSeconds > 0, sweeper == nil else { return }
        // Poll at a fraction of the timeout, capped so a long timeout still
        // reclaims within a bounded window.
        let interval = max(1, min(idleTimeoutSeconds, 30))
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await self.sweepIdle()
            }
        }
    }

    /// Idempotent teardown: cancel bookkeeping, run adapter teardown once,
    /// drop the entry.
    private func teardown(id: UUID, reason: String) async {
        guard let entry = sessions[id], !entry.tornDown else {
            sessions[id] = nil
            return
        }
        entry.tornDown = true
        sessions[id] = nil
        logger.info("tearing down UI session \(id.uuidString, privacy: .public) — \(reason, privacy: .public)")
        await entry.adapter.teardown(entry.session)
    }

    /// Teardown for a session that was prepared but never registered (a
    /// late-arriving result after a start timeout). Prevents a leaked
    /// WebView window / simulator.
    private func tearDownPrepared(_ prepared: PreparedUISession) async {
        await prepared.adapter.teardown(prepared.session)
    }

    private func resolveArtifactRoot(config: UISessionConfig, sessionID: UUID) -> URL {
        if let raw = config.artifactDirPath, !raw.isEmpty, (raw as NSString).isAbsolutePath {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        // No explicit artifact_dir → per-session dir under the default root.
        // Production (`defaultArtifactRoot == nil`) resolves to
        // `<runs>/ui-sessions/`, unchanged; tests inject a temp root.
        let base = defaultArtifactRoot
            ?? HarnessPaths.runsDir.appendingPathComponent("ui-sessions", isDirectory: true)
        return base.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Capture one observation: CLEAN PNG → `steps/NNN.png`, append
    /// `steps.jsonl`, return the (marked, downscaled-to-point-size) image
    /// unless `preferMarked` is false. The marked image never touches disk.
    private func capture(
        _ entry: Entry,
        executed: ToolCall?,
        preferMarked: Bool,
        lastDetail: String?,
        actionFailed: Bool = false
    ) async throws -> UIObservation {
        entry.stepIndex += 1
        let n = entry.stepIndex
        let stepsDir = entry.artifactRoot.appendingPathComponent("steps", isDirectory: true)
        try? HarnessPaths.ensureDirectory(stepsDir)
        let cleanURL = stepsDir.appendingPathComponent(String(format: "%03d.png", n))

        let metadata = try await entry.session.driver.screenshot(into: cleanURL)

        // Invariant guard (standard 14 §6): a driver only writes a
        // `<name>.marked.png` sibling under the HARNESS_DUMP_MARKED dev flag
        // (unset on this path) — delete it defensively so the session path
        // upholds "no agent scaffolding on disk" unconditionally.
        let markedSibling = cleanURL.deletingPathExtension().appendingPathExtension("marked.png")
        try? FileManager.default.removeItem(at: markedSibling)

        let cleanBytes = (try? Data(contentsOf: cleanURL)) ?? Data()
        let sourceBytes: Data
        let isMarked: Bool
        if preferMarked, let marked = metadata.markedImageData {
            sourceBytes = marked
            isMarked = true
        } else {
            sourceBytes = cleanBytes
            isMarked = false
        }
        let imageData = UISessionImage.downscalePNG(sourceBytes, toPointSize: metadata.pointSize) ?? sourceBytes

        let markTable: String? = {
            guard let text = metadata.markedAnnotationText, !text.isEmpty else { return nil }
            return text
        }()
        // Prefer the driver's structured mark list for the count — it is the
        // same data the badges and the table are built from, without the
        // round-trip through prose. Fall back to counting table rows for a
        // driver that supplies an annotation but no structured marks.
        let marks = metadata.marks
        let markCount = marks.isEmpty
            ? UISessionImage.markCount(inAnnotation: markTable)
            : marks.count

        let ref = "steps/\(String(format: "%03d.png", n))"
        appendStepsJSONL(
            entry: entry,
            step: n,
            screenshotRef: ref,
            executed: executed,
            resultSummary: lastDetail,
            pointSize: metadata.pointSize,
            markCount: markCount
        )
        entry.lastActivityAt = Date()

        return UIObservation(
            sessionID: entry.id,
            platform: entry.platform,
            displayLabel: entry.displayLabel,
            pointSize: metadata.pointSize,
            imageData: imageData,
            imageIsMarked: isMarked,
            markTable: markTable,
            markCount: markCount,
            marks: marks,
            pageText: metadata.pageText,
            stepIndex: n,
            screenshotRef: ref,
            lastExecutionDetail: executed != nil ? lastDetail : nil,
            actionFailed: actionFailed
        )
    }

    /// Append one JSONL row for an observation. Best-effort — an artifact
    /// write failure must never fail the observe/act itself.
    private func appendStepsJSONL(
        entry: Entry,
        step: Int,
        screenshotRef: String,
        executed: ToolCall?,
        resultSummary: String?,
        pointSize: CGSize,
        markCount: Int
    ) {
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "step": step,
            "screenshot": screenshotRef,
            "point_size": ["w": Int(pointSize.width), "h": Int(pointSize.height)],
            "marks": markCount
        ]
        if let executed {
            row["tool"] = executed.tool.rawValue
            if let json = try? LogRow.toolInputJSONString(executed.input),
               let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                row["input"] = obj
            }
            row["result"] = resultSummary ?? "ok"
        } else {
            row["kind"] = "observe"
            row["result"] = "observed"
        }

        guard let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        let url = entry.artifactRoot.appendingPathComponent("steps.jsonl")
        var payload = line
        payload.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)   // first row creates the file
        }
    }

    // MARK: - Bounded start

    private struct StartTimeout: Error {}

    private func preparedWithTimeout(
        _ config: UISessionConfig,
        sessionID: UUID,
        seconds: Int
    ) async throws -> PreparedUISession {
        let preparer = self.preparer
        let work = Task<PreparedUISession, any Error> {
            try await preparer.prepare(config, sessionID: sessionID)
        }
        do {
            return try await Self.race(seconds: seconds) { try await work.value }
        } catch is StartTimeout {
            // Timeout won the race. `work` may still be mid-prepare (a
            // WKWebView load / xcodebuild) — await its eventual result off
            // to the side and tear it down so nothing leaks.
            Task.detached { [weak self] in
                if let late = try? await work.value { await self?.tearDownPrepared(late) }
            }
            work.cancel()
            throw UISessionError.startTimedOut(seconds: seconds, platform: config.platform)
        }
    }

    private static func race<T: Sendable>(
        seconds: Int,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw StartTimeout()
            }
            guard let first = try await group.next() else { throw StartTimeout() }
            group.cancelAll()
            return first
        }
    }

    /// Per-platform default bound on `start`. `internal` (not `private`) so
    /// the test suite can pin the contract without a live prepare.
    /// `HARNESS_UI_SESSION_START_TIMEOUT_SECONDS` overrides at the MCP
    /// composition root.
    static func defaultStartTimeout(for platform: PlatformKind) -> Int {
        switch platform {
        case .web:          return 120     // adapter's own waits cap ~30s; generous backstop
        case .iosSimulator: return 900     // xcodebuild + boot + WDA can run minutes
        case .macosApp:     return 600     // xcodebuild (macOS) or prebuilt .app launch + window-appear poll
        }
    }
}
