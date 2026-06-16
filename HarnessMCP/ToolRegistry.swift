//
//  ToolRegistry.swift
//  HarnessMCP
//
//  The MCP `tools/list` payload: every tool's name, description, and
//  JSON-Schema `inputSchema`. Built fresh on each call (returns a
//  non-`Sendable` `[[String: Any]]`, so it can't be a global constant
//  under Swift 6 strict concurrency) and consumed only inside the
//  `MCPServer` actor.
//
//  The handler bodies live in `ToolHandlers.swift`; the dispatch switch
//  in `MCPServer.dispatch(tool:args:)` must stay in sync with the names
//  declared here.
//

import Foundation

enum ToolRegistry {

    static func definitions() -> [[String: Any]] {
        [
            // MARK: Library — personas
            tool("list_personas",
                 "List personas in the Harness library. A persona is the test-user profile whose prompt text steers how the agent behaves during a run.",
                 obj(["include_archived": prop("boolean", "Include archived personas (default false).")],
                     required: [])),

            tool("create_persona",
                 "Create a custom persona. Its prompt_text becomes the {{PERSONA}} block injected into runs that reference it. Returns the new persona's id.",
                 obj(["name": prop("string", "Display name."),
                      "prompt_text": prop("string", "The persona system-prompt text (how the test user thinks/behaves)."),
                      "blurb": prop("string", "Optional one-line description.")],
                     required: ["name", "prompt_text"])),

            // MARK: Library — applications
            tool("list_applications",
                 "List Applications (the targets a run drives: an iOS Simulator app, a macOS .app, or a web URL).",
                 obj(["include_archived": prop("boolean", "Include archived applications (default false).")],
                     required: [])),

            tool("create_application",
                 "Create an Application target. For web set platform=web + web_url; for iOS set platform=ios_simulator + project_path/scheme/simulator_udid; for macOS set platform=macos_app + mac_app_path. Returns the new application's id.",
                 obj(["name": prop("string", "Display name."),
                      "platform": enumProp(["web", "ios_simulator", "macos_app"], "Target platform (default ios_simulator)."),
                      "web_url": prop("string", "Web start URL (platform=web)."),
                      "viewport_width": prop("integer", "Web viewport width in points (platform=web)."),
                      "viewport_height": prop("integer", "Web viewport height in points (platform=web)."),
                      "project_path": prop("string", "Absolute path to .xcodeproj/.xcworkspace (platform=ios_simulator)."),
                      "scheme": prop("string", "Xcode scheme (platform=ios_simulator)."),
                      "simulator_udid": prop("string", "Default simulator UDID (platform=ios_simulator)."),
                      "simulator_name": prop("string", "Default simulator name."),
                      "simulator_runtime": prop("string", "Default simulator runtime, e.g. \"18.4\"."),
                      "mac_app_path": prop("string", "Absolute path to a built .app bundle (platform=macos_app)."),
                      "default_model": prop("string", "Default model id for this app, e.g. \"claude-opus-4-7\"."),
                      "default_step_budget": prop("integer", "Default max steps (default 40).")],
                     required: ["name"])),

            // MARK: Library — actions & chains
            tool("list_actions",
                 "List Actions (reusable single-task prompts that can be run directly or composed into a chain).",
                 obj(["include_archived": prop("boolean", "Include archived actions (default false).")],
                     required: [])),

            tool("create_action",
                 "Create an Action (a named, reusable task prompt). Returns the new action's id.",
                 obj(["name": prop("string", "Display name."),
                      "prompt_text": prop("string", "The task prompt injected as the run goal."),
                      "notes": prop("string", "Optional private notes.")],
                     required: ["name", "prompt_text"])),

            tool("list_action_chains",
                 "List Action Chains (ordered sequences of Actions run as one multi-leg run).",
                 obj(["include_archived": prop("boolean", "Include archived chains (default false).")],
                     required: [])),

            tool("create_action_chain",
                 "Create an Action Chain from an ordered list of Action ids. Each step's preserves_state=false reinstalls/relaunches the target before that leg. Returns the new chain's id.",
                 obj(["name": prop("string", "Display name."),
                      "notes": prop("string", "Optional notes."),
                      "steps": arrayProp("Ordered chain steps.",
                                         items: obj(["action_id": prop("string", "An existing Action id (UUID)."),
                                                     "preserves_state": prop("boolean", "Keep target state from the previous leg (default false for the first step, true after).")],
                                                    required: ["action_id"]))],
                     required: ["name", "steps"])),

            // MARK: Credentials
            tool("stage_credential",
                 "Stage a login credential for an Application so runs can fill it via the fill_credential tool. The password is stored ONLY in the macOS Keychain — never in the run log or model context. Returns the credential id.",
                 obj(["application_id": prop("string", "The Application id (UUID) this credential belongs to."),
                      "label": prop("string", "Human label, e.g. \"free user\" or \"admin\"."),
                      "username": prop("string", "Username / email."),
                      "password": prop("string", "Password (stored in Keychain only).")],
                     required: ["application_id", "label", "username", "password"])),

            // MARK: Run control
            tool("start_run",
                 "Start a UI-testing run (autonomous). REQUIRED: (1) goal; (2) exactly one persona — persona_id (an existing persona) OR a raw persona prompt string; (3) a target — either application_id (platform + params derived from it) OR an explicit platform plus its params (web: web_url; ios_simulator: ios_project_path + ios_scheme + ios_simulator_udid; macos_app: mac_app_path). Returns a run_id immediately; the run executes asynchronously — poll get_run_status, fetch results with get_run_result, stop early with cancel_run.",
                 obj(["goal": prop("string", "What the agent should accomplish, e.g. \"sign up for a new account\"."),
                      "application_id": prop("string", "Existing Application id (UUID) to derive platform + target from."),
                      "persona_id": prop("string", "Existing Persona id (UUID); its prompt text steers the run."),
                      "persona": prop("string", "Raw persona prompt text (alternative to persona_id)."),
                      "platform": enumProp(["web", "ios_simulator", "macos_app"], "Target platform (when no application_id)."),
                      "web_url": prop("string", "Web start URL (platform=web)."),
                      "viewport_width": prop("integer", "Web viewport width in points (default 1280)."),
                      "viewport_height": prop("integer", "Web viewport height in points (default 800)."),
                      "ios_project_path": prop("string", "Absolute path to .xcodeproj/.xcworkspace (platform=ios_simulator)."),
                      "ios_scheme": prop("string", "Xcode scheme (platform=ios_simulator)."),
                      "ios_simulator_udid": prop("string", "Simulator UDID (platform=ios_simulator)."),
                      "ios_simulator_name": prop("string", "Simulator name (optional)."),
                      "ios_simulator_runtime": prop("string", "Simulator runtime, e.g. \"18.4\" (optional)."),
                      "mac_app_path": prop("string", "Absolute path to a built .app (platform=macos_app)."),
                      "model": prop("string", "Model id, e.g. \"claude-opus-4-7\", \"claude-sonnet-4-6\" (default opus)."),
                      "step_budget": prop("integer", "Max steps (default 40; 0 = unlimited)."),
                      "token_budget": prop("integer", "Max input tokens (default is per-model)."),
                      "credential_id": prop("string", "A staged credential id (UUID) to make available to fill_credential."),
                      "idle_timeout_seconds": prop("integer", "Auto-cancel if no activity for this many seconds (default 180). A stuck page-load settle emits no events, so this is the backstop the step budget can't be. 0 disables.")],
                     required: ["goal"])),

            tool("cancel_run",
                 "Stop an in-flight run started in this session (e.g. one wedged on a hung page load). Cancels the run and marks it cancelled. No-op error if the run isn't active in this process.",
                 obj(["run_id": prop("string", "The run id (UUID) returned by start_run.")],
                     required: ["run_id"])),

            tool("get_run_status",
                 "Poll a run's live status (phase, current step, friction count, and verdict/summary once finished). Falls back to the persisted record for runs not started in this process.",
                 obj(["run_id": prop("string", "The run id (UUID) returned by start_run.")],
                     required: ["run_id"])),

            tool("list_runs",
                 "List recent runs from history (most recent first).",
                 obj(["limit": prop("integer", "Max runs to return (default 20).")],
                     required: [])),

            tool("get_run_result",
                 "Get a finished run's outcome: verdict, summary, step/friction counts, token usage, and cost. Optionally include the raw events.jsonl log.",
                 obj(["run_id": prop("string", "The run id (UUID)."),
                      "include_log": prop("boolean", "Include the full events.jsonl text (default false).")],
                     required: ["run_id"])),

            tool("get_step_screenshot",
                 "Return the PNG screenshot captured at a given step of a run, as image content.",
                 obj(["run_id": prop("string", "The run id (UUID)."),
                      "step": prop("integer", "1-based step index.")],
                     required: ["run_id", "step"])),

            // MARK: Introspection
            tool("list_agent_tools",
                 "List the UI-driving tools the agent can use on a given platform (tap, type, navigate, fill_credential, mark_goal_done, …).",
                 obj(["platform": enumProp(["web", "ios_simulator", "macos_app"], "Platform (default ios_simulator).")],
                     required: []))
        ]
    }

    // MARK: - Schema builders

    private static func tool(_ name: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }

    private static func obj(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static func enumProp(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    private static func arrayProp(_ description: String, items: [String: Any]) -> [String: Any] {
        ["type": "array", "description": description, "items": items]
    }
}
