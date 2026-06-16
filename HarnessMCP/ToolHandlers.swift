//
//  ToolHandlers.swift
//  HarnessMCP
//
//  The `tools/call` dispatch table and every tool body. Each handler is a
//  thin adapter onto the same domain surface the GUI uses:
//  `RunHistoryStoring` (library + credentials CRUD), `RunBuilder` +
//  `RunCoordinator` (runs), `RunSupervisor` (live status), `RunLogParser`
//  / `HarnessPaths` (results + screenshots), and `ToolSchema` (agent-tool
//  introspection).
//
//  All methods are actor-isolated on `MCPServer`, so they can freely use
//  `[String: Any]` JSON without tripping Sendable checks — they only pass
//  Sendable values (UUID/String/RunRequest/…) across the store/coordinator
//  boundaries.
//

import Foundation

extension MCPServer {

    func dispatch(tool: String, args: MCPArguments) async throws -> MCPToolOutcome {
        // Resolve the shared store/deps. A failure here (e.g. the store is
        // locked or un-openable) surfaces as a clear tool error.
        let c: MCPContainer
        do {
            c = try container()
        } catch {
            return .error("Harness store unavailable: \(error.localizedDescription)")
        }

        // Mirror the GUI's launch-time bootstrap so a fresh store exposes the
        // stock personas (and `start_run` works) without first opening the app.
        await seedBuiltInPersonasOnce(c)

        switch tool {
        case "list_personas":        return try await listPersonas(c, args)
        case "create_persona":       return try await createPersona(c, args)
        case "list_applications":    return try await listApplications(c, args)
        case "create_application":   return try await createApplication(c, args)
        case "list_actions":         return try await listActions(c, args)
        case "create_action":        return try await createAction(c, args)
        case "list_action_chains":   return try await listActionChains(c, args)
        case "create_action_chain":  return try await createActionChain(c, args)
        case "stage_credential":     return try await stageCredential(c, args)
        case "start_run":            return try await startRun(c, args)
        case "cancel_run":           return try await cancelRun(c, args)
        case "get_run_status":       return try await getRunStatus(c, args)
        case "list_runs":            return try await listRuns(c, args)
        case "get_run_result":       return try await getRunResult(c, args)
        case "get_step_screenshot":  return try await getStepScreenshot(c, args)
        case "list_agent_tools":     return try listAgentTools(args)
        default:                     return .error("Unknown tool: '\(tool)'")
        }
    }

    /// Seed built-in personas once per process — idempotent, mirrors the
    /// GUI's `AppContainer.bootstrapPersonas()` so `list_personas` /
    /// `start_run` work against a fresh store without first launching the
    /// app. The success flag is set only AFTER a successful seed: tool calls
    /// are serialized on this actor (so a retry can't double-seed) and the
    /// underlying seed is idempotent, so on a transient failure we leave the
    /// flag false and retry on the next tool call rather than permanently
    /// serving an empty persona set. Best-effort; never blocks a tool call.
    private func seedBuiltInPersonasOnce(_ c: MCPContainer) async {
        guard !didSeedBuiltIns else { return }
        do {
            let markdown = try PromptLibrary().personaDefaults()
            try await c.history.seedBuiltInPersonasIfNeeded(from: markdown)
            didSeedBuiltIns = true
            log("seeded built-in personas (idempotent)")
        } catch {
            log("built-in persona seed skipped (will retry): \(error.localizedDescription)")
        }
    }

    // MARK: - Personas

    private func listPersonas(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let personas = try await c.history.personas(includeArchived: args.bool("include_archived") ?? false)
        let arr: [[String: Any]] = personas.map {
            ["id": $0.id.uuidString, "name": $0.name, "blurb": $0.blurb,
             "is_built_in": $0.isBuiltIn, "archived": $0.archived, "prompt_text": $0.promptText]
        }
        return jsonText(["personas": arr, "count": arr.count])
    }

    private func createPersona(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let name = try args.requireString("name")
        let promptText = try args.requireString("prompt_text")
        let now = Date()
        let snap = PersonaSnapshot(
            id: UUID(), name: name, blurb: args.string("blurb") ?? "",
            promptText: promptText, isBuiltIn: false,
            createdAt: now, lastUsedAt: now, archivedAt: nil
        )
        try await c.history.upsert(snap)
        return jsonText(["created": ["id": snap.id.uuidString, "name": name]])
    }

    // MARK: - Applications

    private func listApplications(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let apps = try await c.history.applications(includeArchived: args.bool("include_archived") ?? false)
        let arr: [[String: Any]] = apps.map {
            var d: [String: Any] = [
                "id": $0.id.uuidString, "name": $0.name,
                "platform": $0.platformKind.rawValue, "archived": $0.archived
            ]
            if !$0.scheme.isEmpty { d["scheme"] = $0.scheme }
            if !$0.projectPath.isEmpty { d["project_path"] = $0.projectPath }
            if let u = $0.webStartURL { d["web_url"] = u }
            if let p = $0.macAppBundlePath { d["mac_app_path"] = p }
            return d
        }
        return jsonText(["applications": arr, "count": arr.count])
    }

    private func createApplication(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let name = try args.requireString("name")
        let platform = PlatformKind.from(rawValue: args.string("platform"))
        let now = Date()
        let snap = ApplicationSnapshot(
            id: UUID(), name: name, createdAt: now, lastUsedAt: now, archivedAt: nil,
            platformKindRaw: platform.rawValue,
            projectPath: args.string("project_path") ?? "",
            scheme: args.string("scheme") ?? "",
            defaultSimulatorUDID: args.string("simulator_udid"),
            defaultSimulatorName: args.string("simulator_name"),
            defaultSimulatorRuntime: args.string("simulator_runtime"),
            macAppBundlePath: args.string("mac_app_path"),
            webStartURL: args.string("web_url"),
            webViewportWidthPt: args.int("viewport_width"),
            webViewportHeightPt: args.int("viewport_height"),
            defaultModelRaw: args.string("default_model") ?? AgentModel.opus47.rawValue,
            defaultModeRaw: RunMode.autonomous.rawValue,
            defaultStepBudget: args.int("default_step_budget") ?? 40
        )
        try await c.history.upsert(snap)
        return jsonText(["created": ["id": snap.id.uuidString, "name": name, "platform": platform.rawValue]])
    }

    // MARK: - Actions & chains

    private func listActions(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let actions = try await c.history.actions(includeArchived: args.bool("include_archived") ?? false)
        let arr: [[String: Any]] = actions.map {
            ["id": $0.id.uuidString, "name": $0.name, "prompt_text": $0.promptText,
             "notes": $0.notes, "archived": $0.archived]
        }
        return jsonText(["actions": arr, "count": arr.count])
    }

    private func createAction(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let name = try args.requireString("name")
        let promptText = try args.requireString("prompt_text")
        let now = Date()
        let snap = ActionSnapshot(
            id: UUID(), name: name, promptText: promptText,
            notes: args.string("notes") ?? "", createdAt: now, lastUsedAt: now, archivedAt: nil
        )
        try await c.history.upsert(snap)
        return jsonText(["created": ["id": snap.id.uuidString, "name": name]])
    }

    private func listActionChains(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let chains = try await c.history.actionChains(includeArchived: args.bool("include_archived") ?? false)
        let arr: [[String: Any]] = chains.map { chain in
            ["id": chain.id.uuidString, "name": chain.name, "notes": chain.notes,
             "archived": chain.archived,
             "steps": chain.steps.map { step -> [String: Any] in
                var d: [String: Any] = ["index": step.index, "preserves_state": step.preservesState]
                if let a = step.actionID { d["action_id"] = a.uuidString }
                return d
             }]
        }
        return jsonText(["action_chains": arr, "count": arr.count])
    }

    private func createActionChain(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let name = try args.requireString("name")
        let rawSteps = args.objectArray("steps")
        guard !rawSteps.isEmpty else {
            throw MCPToolError.invalidArgument("steps", "expected a non-empty array of { action_id, preserves_state? }")
        }
        var steps: [ActionChainStepSnapshot] = []
        for (i, s) in rawSteps.enumerated() {
            guard let aidStr = s["action_id"] as? String, let aid = UUID(uuidString: aidStr) else {
                throw MCPToolError.invalidArgument("steps[\(i)].action_id", "expected a UUID string")
            }
            let preserves = (s["preserves_state"] as? Bool) ?? (i > 0)
            steps.append(ActionChainStepSnapshot(id: UUID(), index: i, actionID: aid, preservesState: preserves))
        }
        let now = Date()
        let snap = ActionChainSnapshot(
            id: UUID(), name: name, notes: args.string("notes") ?? "",
            createdAt: now, lastUsedAt: now, archivedAt: nil, steps: steps
        )
        try await c.history.upsert(snap)
        return jsonText(["created": ["id": snap.id.uuidString, "name": name, "step_count": steps.count]])
    }

    // MARK: - Credentials

    private func stageCredential(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let appID = try args.requireUUID("application_id")
        let label = try args.requireString("label")
        let username = try args.requireString("username")
        let password = try args.requireString("password")

        guard try await c.history.application(id: appID) != nil else {
            throw MCPToolError.notFound("Application \(appID.uuidString)")
        }
        let snap = CredentialSnapshot(id: UUID(), applicationID: appID, label: label, username: username, createdAt: Date())
        // Write the Keychain password FIRST: if it fails (e.g. an ACL prompt is
        // denied), bail before persisting the SwiftData row so we never leave an
        // orphan credential with no backing password. A leftover Keychain item
        // with no row is inert and overwritten on the next stage of this id.
        // (EnvKeychain.write is a no-op, so use the real KeychainStore directly.)
        try KeychainStore().writePassword(password, applicationID: appID, credentialID: snap.id)
        try await c.history.upsertCredential(snap)

        return jsonText(["staged": [
            "credential_id": snap.id.uuidString,
            "application_id": appID.uuidString,
            "label": label,
            "username": username
        ]])
    }

    // MARK: - Run control

    private func startRun(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let goal = try args.requireString("goal")

        // Resolve persona prompt text (persona_id wins over a raw string).
        var personaPrompt = args.string("persona") ?? ""
        var personaID: UUID?
        if let pid = args.uuid("persona_id") {
            guard let persona = try await c.history.persona(id: pid) else {
                throw MCPToolError.notFound("Persona \(pid.uuidString)")
            }
            personaPrompt = persona.promptText
            personaID = persona.id
        }
        guard !personaPrompt.isEmpty else {
            throw MCPToolError.message("Provide persona_id (an existing persona) or a non-empty 'persona' prompt string.")
        }

        var params = RunBuilder.Params(
            platform: .web,
            goal: goal,
            personaPrompt: personaPrompt,
            personaID: personaID,
            applicationID: nil,
            model: .opus47,
            stepBudget: args.int("step_budget"),
            tokenBudget: args.int("token_budget"),
            credentialID: args.uuid("credential_id"),
            webURL: args.string("web_url"),
            viewportW: args.int("viewport_width") ?? 1280,
            viewportH: args.int("viewport_height") ?? 800,
            iosProjectPath: args.string("ios_project_path"),
            iosScheme: args.string("ios_scheme"),
            iosSimulatorUDID: args.string("ios_simulator_udid"),
            iosSimulatorName: args.string("ios_simulator_name"),
            iosSimulatorRuntime: args.string("ios_simulator_runtime"),
            macAppPath: args.string("mac_app_path")
        )

        if let appID = args.uuid("application_id") {
            guard let app = try await c.history.application(id: appID) else {
                throw MCPToolError.notFound("Application \(appID.uuidString)")
            }
            params.applicationID = appID
            params.platform = app.platformKind
            // Fill any param the caller didn't pass explicitly from the app.
            if params.webURL == nil { params.webURL = app.webStartURL }
            if args.int("viewport_width") == nil, let w = app.webViewportWidthPt { params.viewportW = w }
            if args.int("viewport_height") == nil, let h = app.webViewportHeightPt { params.viewportH = h }
            if params.iosProjectPath == nil { params.iosProjectPath = app.projectPath.isEmpty ? nil : app.projectPath }
            if params.iosScheme == nil { params.iosScheme = app.scheme.isEmpty ? nil : app.scheme }
            if params.iosSimulatorUDID == nil { params.iosSimulatorUDID = app.defaultSimulatorUDID }
            if params.iosSimulatorName == nil { params.iosSimulatorName = app.defaultSimulatorName }
            if params.iosSimulatorRuntime == nil { params.iosSimulatorRuntime = app.defaultSimulatorRuntime }
            if params.macAppPath == nil { params.macAppPath = app.macAppBundlePath }
            if args.string("model") == nil, let m = app.defaultModel { params.model = m }
        } else {
            params.platform = PlatformKind.from(rawValue: args.string("platform"))
            // Ad-hoc run (no application_id): thread it into the app-centric
            // model by matching an existing Application that targets the same
            // thing, or creating one. This is what lands agent runs in the
            // GUI's normal per-app History (badged "Agent") instead of leaving
            // them app-less and invisible there. Best-effort — if the target
            // is incomplete this returns nil and RunBuilder throws the precise
            // validation error below.
            params.applicationID = try await resolveOrCreateApplication(c, params)
        }

        // Explicit model arg always wins.
        if let mstr = args.string("model"), let m = AgentModel(rawValue: mstr) { params.model = m }

        // Validate a staged credential: it must exist, and (when the run is
        // tied to an Application) belong to THAT application — otherwise a
        // credential_id from another app would inject the wrong username /
        // password into this run (credential confusion).
        if let credID = params.credentialID {
            guard let cred = try await c.history.credential(id: credID) else {
                throw MCPToolError.notFound("Credential \(credID.uuidString)")
            }
            if let appID = params.applicationID, cred.applicationID != appID {
                throw MCPToolError.message("Credential \(credID.uuidString) belongs to a different Application (\(cred.applicationID.uuidString)) than this run's Application (\(appID.uuidString)). Stage a credential for the run's Application instead.")
            }
        }

        // Fail fast with a clear message if a cloud model has no API key.
        if params.model.provider != .local {
            let key = (try? c.keychain.readKey(for: params.model.provider)) ?? nil
            if (key ?? "").isEmpty {
                throw MCPToolError.message("No API key for provider '\(params.model.provider.rawValue)'. Add it in Harness → Settings, or export \(Self.envVarName(params.model.provider)) before launching harness-mcp.")
            }
        }

        // Idle watchdog: auto-cancel if no run event arrives for this many
        // seconds (a hung page-load settle emits nothing). 0 disables.
        let idleTimeout = args.int("idle_timeout_seconds") ?? 180

        let (request, coordinator) = try RunBuilder.build(params, container: c)
        await c.supervisor.start(id: request.id, request: request, coordinator: coordinator, idleTimeoutSeconds: idleTimeout)

        return jsonText([
            "started": [
                "run_id": request.id.uuidString,
                "platform": params.platform.rawValue,
                "model": params.model.rawValue,
                "goal": goal,
                "idle_timeout_seconds": idleTimeout
            ],
            "note": "Run is executing asynchronously. Poll get_run_status with this run_id; fetch results with get_run_result once finished. Use cancel_run to stop it early."
        ])
    }

    /// Ad-hoc runs (no `application_id`) get threaded into the app-centric
    /// model: match an existing Application that targets the same thing, or
    /// create one, and return its id. That's what makes agent runs appear in
    /// the GUI's normal per-app History (badged "Agent") rather than floating
    /// app-less. Returns nil when the target params are insufficient (e.g. web
    /// with no URL) so the caller still hits `RunBuilder`'s precise error.
    private func resolveOrCreateApplication(_ c: MCPContainer, _ p: RunBuilder.Params) async throws -> UUID? {
        // Propagate a store-read failure instead of silently treating it as
        // "no apps" — that would mint a duplicate Application and bury a real
        // error (the explicit application_id path also surfaces store errors).
        let existing = try await c.history.applications(includeArchived: false)
        let now = Date()

        func create(
            name: String,
            projectPath: String = "",
            scheme: String = "",
            simUDID: String? = nil,
            simName: String? = nil,
            simRuntime: String? = nil,
            macAppPath: String? = nil,
            webURL: String? = nil
        ) async throws -> UUID {
            let snap = ApplicationSnapshot(
                id: UUID(), name: name, createdAt: now, lastUsedAt: now,
                platformKindRaw: p.platform.rawValue,
                projectPath: projectPath, scheme: scheme,
                defaultSimulatorUDID: simUDID, defaultSimulatorName: simName,
                defaultSimulatorRuntime: simRuntime,
                macAppBundlePath: macAppPath,
                webStartURL: webURL,
                webViewportWidthPt: p.viewportW, webViewportHeightPt: p.viewportH,
                defaultModelRaw: AgentModel.opus47.rawValue,
                defaultModeRaw: RunMode.autonomous.rawValue,
                defaultStepBudget: 40
            )
            try await c.history.upsert(snap)
            return snap.id
        }

        switch p.platform {
        case .web:
            guard let raw = p.webURL, !raw.isEmpty, let host = Self.normalizedHost(raw) else { return nil }
            if let match = existing.first(where: {
                $0.platformKind == .web && Self.normalizedHost($0.webStartURL ?? "") == host
            }) { return match.id }
            return try await create(name: host, webURL: raw)
        case .iosSimulator:
            guard let proj = p.iosProjectPath, let scheme = p.iosScheme else { return nil }
            if let match = existing.first(where: {
                $0.platformKind == .iosSimulator && $0.projectPath == proj && $0.scheme == scheme
            }) { return match.id }
            return try await create(
                name: scheme, projectPath: proj, scheme: scheme,
                simUDID: p.iosSimulatorUDID, simName: p.iosSimulatorName, simRuntime: p.iosSimulatorRuntime
            )
        case .macosApp:
            guard let path = p.macAppPath, !path.isEmpty else { return nil }
            if let match = existing.first(where: {
                $0.platformKind == .macosApp && $0.macAppBundlePath == path
            }) { return match.id }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return try await create(name: name, macAppPath: path)
        }
    }

    /// Lowercased host without a leading "www.", for grouping web runs by
    /// site. `nil` when no host resolves, so callers skip matching rather than
    /// collapsing unrelated runs under an empty key.
    private static func normalizedHost(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: withScheme)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func cancelRun(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let runID = try args.requireUUID("run_id")
        let cancelled = await c.supervisor.cancel(id: runID)
        guard cancelled else {
            throw MCPToolError.notFound("active run \(runID.uuidString) (not started in this process, or already finished)")
        }
        return jsonText(["cancelled": ["run_id": runID.uuidString]])
    }

    private func getRunStatus(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let runID = try args.requireUUID("run_id")
        if let s = await c.supervisor.status(id: runID) {
            return jsonText(liveStatusJSON(runID, s))
        }
        // Not started in this process — fall back to the persisted record.
        if let rec = try await c.history.fetch(id: runID) {
            return jsonText(recordSummaryJSON(rec))
        }
        throw MCPToolError.notFound("Run \(runID.uuidString)")
    }

    private func listRuns(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let recs = try await c.history.fetchRecent(limit: args.int("limit") ?? 20)
        let arr = recs.map { recordSummaryJSON($0) }
        return jsonText(["runs": arr, "count": arr.count])
    }

    private func getRunResult(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let runID = try args.requireUUID("run_id")
        // While a run is in flight the persisted record is still the skeleton
        // (0 steps/tokens, no verdict) — markCompleted only writes the real
        // numbers at the end. Report live status instead of misleading zeros.
        if let s = await c.supervisor.status(id: runID), s.finishedAt == nil {
            var live = liveStatusJSON(runID, s)
            live["note"] = "Run is still in progress — verdict, token usage, and cost are only available once it finishes. Poll get_run_status, or cancel_run to stop it."
            return jsonText(live)
        }
        guard let rec = try await c.history.fetch(id: runID) else {
            throw MCPToolError.notFound("Run \(runID.uuidString)")
        }
        var out = recordSummaryJSON(rec)
        if args.bool("include_log") ?? false,
           let text = try? String(contentsOf: HarnessPaths.eventsLog(for: runID), encoding: .utf8) {
            out["events_jsonl"] = text
        }
        return jsonText(out)
    }

    private func getStepScreenshot(_ c: MCPContainer, _ args: MCPArguments) async throws -> MCPToolOutcome {
        let runID = try args.requireUUID("run_id")
        let step = try args.requireInt("step")
        let url = HarnessPaths.screenshot(for: runID, step: step)
        guard let data = try? Data(contentsOf: url) else {
            throw MCPToolError.notFound("screenshot for run \(runID.uuidString) step \(step) (\(url.path))")
        }
        return MCPToolOutcome([.image(base64: data.base64EncodedString(), mimeType: "image/png")])
    }

    // MARK: - Introspection

    private func listAgentTools(_ args: MCPArguments) throws -> MCPToolOutcome {
        let platform = PlatformKind.from(rawValue: args.string("platform"))
        let tools = ToolSchema.canonical(platform: platform)
        let arr: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.jsonSchema]
        }
        return jsonText(["platform": platform.rawValue, "tools": arr, "count": arr.count])
    }

    // MARK: - JSON helpers

    private func liveStatusJSON(_ id: UUID, _ s: RunSupervisor.Status) -> [String: Any] {
        var d: [String: Any] = [
            "run_id": id.uuidString,
            "phase": s.phase,
            "current_step": s.currentStep,
            "friction_count": s.frictionCount,
            "finished": s.finishedAt != nil,
            "started_at": Self.iso(s.startedAt)
        ]
        if let v = s.verdict { d["verdict"] = v }
        if let sm = s.summary { d["summary"] = sm }
        if let e = s.error { d["error"] = e }
        if let f = s.finishedAt { d["finished_at"] = Self.iso(f) }
        return d
    }

    private func recordSummaryJSON(_ rec: RunRecordSnapshot) -> [String: Any] {
        var d: [String: Any] = [
            "run_id": rec.id.uuidString,
            "goal": rec.goal,
            "model": rec.modelRaw,
            "platform": rec.platformKind.rawValue,
            "created_at": Self.iso(rec.createdAt),
            "finished": rec.completedAt != nil,
            "step_count": rec.stepCount,
            "friction_count": rec.frictionCount,
            "would_real_user_succeed": rec.wouldRealUserSucceed,
            "tokens": [
                "input": rec.tokensUsedInput,
                "output": rec.tokensUsedOutput,
                "cache_read": rec.tokensUsedCacheRead,
                "cache_creation": rec.tokensUsedCacheCreation
            ],
            "cost_usd": rec.cost.total,
            "run_directory": rec.runDirectoryPath
        ]
        if let c = rec.completedAt { d["completed_at"] = Self.iso(c) }
        if let v = rec.verdictRaw { d["verdict"] = v }
        if let s = rec.summary { d["summary"] = s }
        return d
    }

    func jsonText(_ value: Any) -> MCPToolOutcome {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return .text(s)
        }
        return .text(String(describing: value))
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func envVarName(_ p: ModelProvider) -> String {
        switch p {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai:    return "OPENAI_API_KEY"
        case .google:    return "GOOGLE_API_KEY"
        case .local:     return "(no key needed)"
        }
    }
}
