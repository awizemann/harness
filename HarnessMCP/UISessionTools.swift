//
//  UISessionTools.swift
//  HarnessMCP
//
//  The five step-level UI session tools' `tools/call` handlers. Thin
//  adapters over `MCPContainer.uiSessions` (`UISessionSupervisor`, in the
//  Harness module): parse MCP args, call the actor, format the MCP
//  content. All the testable logic — lifecycle, cap, idle teardown,
//  artifact writing, tool validation/mapping — lives in the supervisor.
//
//  These tools let an external MCP client (another product's QA agent)
//  launch a target, SEE it (marked screenshot + mark table), and ACT on
//  it — WITHOUT Harness's own LLM loop, and WITHOUT any API key.
//

import Foundation

extension MCPServer {

    // MARK: - start_ui_session

    func startUISession(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let platform = try Self.parseSessionPlatform(args.string("platform"))
        let (viewportW, viewportH) = Self.viewport(for: args.string("viewport"))

        // `session_state` carries COOKIE VALUES — credentials. It is parsed
        // here and handed straight to the supervisor: never echoed into the
        // result, never logged, never written to steps.jsonl (which records
        // `act_ui` calls only — `start_ui_session` writes no row at all).
        // Parse errors name the offending index and field, never the value.
        let sessionState: WebSessionState? = try {
            guard let raw = args.raw["session_state"] else { return nil }
            do { return try WebSessionState.parse(raw) }
            catch { throw MCPToolError.invalidArgument("session_state", error.localizedDescription) }
        }()

        // `credential_id` names a credential staged with `stage_credential`.
        // Validate it HERE — the row must exist AND its Keychain password
        // must be readable — so a caller that mistypes an id learns at start
        // instead of watching `fill_credential` fail mid-session. Only the id
        // is carried into the config; the username/password are resolved
        // inside the adapter and never touch this layer.
        let credential = try await validatedCredentialID(c, args)

        let config = UISessionConfig(
            platform: platform,
            artifactDirPath: args.string("artifact_dir"),
            webURL: args.string("url"),
            viewportWidth: viewportW,
            viewportHeight: viewportH,
            webSessionState: sessionState,
            webVisible: args.bool("visible") ?? false,
            credentialID: credential?.id,
            iosProjectPath: args.string("project_path"),
            iosScheme: args.string("scheme"),
            iosSimulatorUDID: args.string("simulator_udid"),
            iosSimulatorName: args.string("simulator_name"),
            iosSimulatorRuntime: args.string("simulator_runtime"),
            iosAppBundlePath: args.string("app_path"),
            // macOS: app_path (preferred) OR project_path + scheme. The
            // arg names are shared with the other platforms — the supervisor
            // reads only the fields that apply to the chosen platform.
            macAppPath: args.string("app_path"),
            macProjectPath: args.string("project_path"),
            macScheme: args.string("scheme")
        )

        let info = try await c.uiSessions.start(config)
        var payload: [String: Any] = [
            "session_id": info.id.uuidString,
            "display_label": info.displayLabel,
            "platform": Self.sessionPlatformName(info.platform),
            "point_size": ["width": Int(info.pointSize.width), "height": Int(info.pointSize.height)],
            "note": "Session is ready. Call observe_ui to see it, act_ui to interact, end_ui_session when done."
        ]
        if let credential {
            // Label + username only — the same public-safe identity
            // `RunLogger` records for an autonomous run. The password is
            // never part of any result.
            payload["credential"] = [
                "credential_id": credential.id.uuidString,
                "label": credential.label,
                "username": credential.username
            ]
            payload["note"] = "Session is ready, with credential \"\(credential.label)\" available to act_ui(tool: \"fill_credential\", field: \"username\"|\"password\"). Focus the field first, then fill it."
        }
        return jsonText(payload)
    }

    /// Resolve + validate `credential_id`, or nil when the caller passed none.
    ///
    /// Two failures are caught here rather than mid-session: an id that names
    /// no staged credential, and a credential row whose Keychain password is
    /// missing (a half-staged credential). The password itself is read only to
    /// prove it exists — the value is discarded immediately and never held,
    /// logged, or returned; the driver re-resolves its own copy inside
    /// `resolveCredentialBinding`.
    private func validatedCredentialID(
        _ c: MCPContainer,
        _ args: MCPArguments
    ) async throws -> CredentialSnapshot? {
        guard args.raw["credential_id"] != nil else { return nil }
        let id = try args.requireUUID("credential_id")
        guard let snapshot = try await c.history.credential(id: id) else {
            throw UISessionError.credentialNotStaged(id)
        }
        // A THROW here is a Keychain failure (locked, access denied) — very
        // different advice from "never staged", so don't collapse the two.
        // The value is proven present and immediately dropped; the driver
        // resolves its own copy inside `resolveCredentialBinding`.
        do {
            guard try c.keychain.readPassword(
                applicationID: snapshot.applicationID,
                credentialID: snapshot.id
            ) != nil else {
                throw UISessionError.credentialPasswordMissing(id: snapshot.id, label: snapshot.label)
            }
        } catch let error as UISessionError {
            throw error
        } catch {
            throw MCPToolError.message(
                "Could not read credential \(snapshot.id.uuidString) (\"\(snapshot.label)\") from the Keychain: \(error.localizedDescription). Unlock the login keychain, or allow harness-mcp access to the \"\(KeychainStore.credentialsService)\" item, and retry."
            )
        }
        return snapshot
    }

    // MARK: - observe_ui

    func observeUI(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let id = try args.requireUUID("session_id")
        let clean = args.bool("clean") ?? false
        let obs = try await c.uiSessions.observe(id: id, clean: clean)
        return Self.observationOutcome(obs)
    }

    // MARK: - act_ui

    func actUI(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let id = try args.requireUUID("session_id")
        let tool = try args.requireString("tool")

        // The tool's own args ride at the top level alongside session_id +
        // tool; strip those two and hand the rest to the supervisor, which
        // maps them via the same decoder the LLM path uses.
        var input = args.raw
        input.removeValue(forKey: "session_id")
        input.removeValue(forKey: "tool")
        let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)

        let obs = try await c.uiSessions.act(id: id, tool: tool, inputData: inputData)
        return Self.observationOutcome(obs)
    }

    // MARK: - export_ui_session_state

    /// Return the live web session's cookies + current-origin localStorage.
    ///
    /// **This result is SENSITIVE** — session cookies are bearer credentials.
    /// It is the single sanctioned egress point for that data: nothing here
    /// logs it, nothing writes it to the artifact bundle, and the supervisor
    /// keeps no copy. The client is responsible for storing it securely (the
    /// macOS Keychain, a secret manager — not a file in a repo).
    func exportUISessionState(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let id = try args.requireUUID("session_id")
        let state = try await c.uiSessions.exportWebSessionState(id: id)
        var payload = state.exportJSON()
        payload["session_id"] = id.uuidString
        payload["sensitive"] = true
        payload["note"] = "SENSITIVE — these cookies are login credentials. Store them in a secret manager (never a repo file or a log), and pass them back as start_ui_session's session_state to reuse the login headlessly."
        return jsonText(payload)
    }

    // MARK: - end_ui_session

    func endUISession(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let id = try args.requireUUID("session_id")
        let result = await c.uiSessions.end(id: id)
        return jsonText([
            "session_id": result.id.uuidString,
            "closed": result.wasOpen,
            "status": result.message
        ])
    }

    // MARK: - list_ui_sessions

    func listUISessions(_ c: MCPContainer, _ args: MCPArguments) async -> MCPToolOutcome {
        let sessions = await c.uiSessions.list()
        let arr: [[String: Any]] = sessions.map { s in
            [
                "session_id": s.id.uuidString,
                "platform": Self.sessionPlatformName(s.platform),
                "display_label": s.displayLabel,
                "point_size": ["width": Int(s.pointSize.width), "height": Int(s.pointSize.height)],
                "created_at": Self.iso(s.createdAt),
                "idle_seconds": s.idleSeconds
            ]
        }
        return jsonText(["sessions": arr, "count": arr.count])
    }

    // MARK: - Formatting

    /// Build the shared observe/act payload: the (marked, downscaled) PNG as
    /// image content, plus a text block carrying the mark table, point size,
    /// and session label. Mirrors `get_step_screenshot`'s image shape.
    ///
    /// Also attaches `structuredContent` (see `UIObservationPayload`) —
    /// the same marks as machine-readable geometry plus, on web, the frame's
    /// visible text. Strictly additive: the image + text blocks above are
    /// unchanged, so existing clients see the identical result.
    private static func observationOutcome(_ obs: UIObservation) -> MCPToolOutcome {
        let image = MCPContent.image(base64: obs.imageData.base64EncodedString(), mimeType: "image/png")

        var lines: [String] = []
        lines.append("Session: \(obs.displayLabel) (\(sessionPlatformName(obs.platform)))  ·  id \(obs.sessionID.uuidString)")
        lines.append("Point size: \(Int(obs.pointSize.width))×\(Int(obs.pointSize.height))  ·  image: \(obs.imageIsMarked ? "marked" : "clean")  ·  step \(obs.stepIndex) → \(obs.screenshotRef)")
        if let detail = obs.lastExecutionDetail, !detail.isEmpty {
            lines.append("Last action: \(detail)")
        }
        lines.append("")
        if let table = obs.markTable {
            lines.append(table)
        } else {
            lines.append("MARKS — none on this frame (no interactive elements detected, or probe returned empty). Use tap(x, y) coordinates from the image if you need to act.")
        }

        // A failed action still returns the fresh frame + marks so the agent
        // sees current state, but the MCP result is flagged isError.
        return MCPToolOutcome(
            [image, .text(lines.joined(separator: "\n"))],
            isError: obs.actionFailed,
            structuredContent: UIObservationPayload.structuredContent(obs)
        )
    }

    // MARK: - Parsing helpers

    static func parseSessionPlatform(_ raw: String?) throws -> PlatformKind {
        switch raw?.lowercased() {
        case "web":
            return .web
        case "ios", "ios_simulator":
            return .iosSimulator
        case "macos", "macos_app", "mac":
            return .macosApp
        case .none, .some(""):
            throw MCPToolError.missingArgument("platform")
        case .some(let other):
            throw MCPToolError.invalidArgument("platform", "expected \"web\", \"ios\", or \"macos\" (got \"\(other)\")")
        }
    }

    /// Session-tool platform wire names: `web` | `ios` | `macos` (distinct
    /// from the library tools' `ios_simulator` / `macos_app`).
    static func sessionPlatformName(_ kind: PlatformKind) -> String {
        switch kind {
        case .web:          return "web"
        case .iosSimulator: return "ios"
        case .macosApp:     return "macos"
        }
    }

    private static func viewport(for raw: String?) -> (Int, Int) {
        switch raw?.lowercased() {
        case "mobile": return (390, 844)     // iPhone-class CSS viewport
        default:       return (1280, 800)    // desktop (the default)
        }
    }
}
