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

            tool("list_credentials",
                 "List the credentials staged for an Application: id, label, username, and when it was staged. Passwords are NEVER returned — they live only in the macOS Keychain. Use the returned credential_id as start_run's or start_ui_session's credential_id.",
                 obj(["application_id": prop("string", "The Application id (UUID) whose credentials to list.")],
                     required: ["application_id"])),

            tool("delete_credential",
                 "Remove a staged credential: the library row AND its macOS Keychain password. Use it to clean up after an automated run so a test credential does not outlive the test. Deleting an id that names no credential is an ERROR, not a quiet success — a caller cleaning up needs to know its id was wrong.",
                 obj(["credential_id": prop("string", "The credential id (UUID) from stage_credential or list_credentials.")],
                     required: ["credential_id"])),

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
                     required: [])),

            // MARK: Step-level UI sessions (no LLM loop, no API key)
            tool(UISessionTool.startUISession.rawValue,
                 "Launch a target and open a step-driving session you observe + act on directly (no autonomous run, no API key). Returns session_id, display_label, point_size, platform. Web is zero-setup; iOS builds the project (can take minutes; the call blocks until ready or fails with the xcodebuild tail). macOS drives a built .app in a contained backend (AX actions + postToPid — the real pointer never moves, focus is never stolen); pass app_path (preferred) or project_path + scheme, and optionally env / launch_args to put that app into its own test-fixture mode.",
                 obj(["platform": enumProp(["web", "ios", "macos"], "Target platform: \"web\", \"ios\", or \"macos\"."),
                      "url": prop("string", "Web start URL (platform=web). http(s) or a local server."),
                      "viewport": enumProp(["desktop", "mobile"], "Web viewport (platform=web): desktop (1280×800, default) or mobile (390×844)."),
                      "project_path": prop("string", "Absolute path to .xcodeproj/.xcworkspace (platform=ios, or platform=macos when not passing app_path)."),
                      "scheme": prop("string", "Xcode scheme (platform=ios, or platform=macos when not passing app_path)."),
                      "simulator_udid": prop("string", "Simulator UDID (platform=ios)."),
                      "simulator_name": prop("string", "Simulator name (optional)."),
                      "simulator_runtime": prop("string", "Simulator runtime, e.g. \"18.4\" (optional)."),
                      "app_path": prop("string", "Absolute path to a built .app bundle. platform=macos: the PREFERRED QA flow — drive this build product directly (no xcodebuild). platform=ios: reserved (use project_path + scheme + simulator_udid)."),
                      "artifact_dir": prop("string", "ABSOLUTE path for the artifact bundle (steps/NNN.png CLEAN frames + steps.jsonl). Relative paths are rejected. Omit → a temp dir under Harness's runs root."),
                      "visible": prop("boolean", "platform=web ONLY. Show the session's window on screen so a HUMAN can interact with it — log in by hand, clear an SSO/MFA prompt — and then hand the result to export_ui_session_state. Default false (the window sits off-view at alpha 0). The website data store stays non-persistent either way."),
                      "credential_id": prop("string", "A credential staged with stage_credential (UUID), made available to act_ui(tool: \"fill_credential\"). ALL platforms. Rejected at start if it names no staged credential or its Keychain password is missing. The username/password are read inside the session and never appear in any result, log, or artifact — only the label + username are echoed back."),
                      "env": envSchema(),
                      "launch_args": arrayProp("platform=macos ONLY. Arguments passed to the launched app as argv, e.g. [\"--fixture-mode\"]. Same contract as env: handed to LaunchServices directly, never through a shell — no expansion, no word-splitting, no interpolation. Rejected on any other platform.", items: prop("string", "One argument, verbatim.")),
                      "session_state": sessionStateSchema()],
                     required: ["platform"])),

            tool(UISessionTool.observeUI.rawValue,
                 "Capture the current screen of a session. Returns the MARKED screenshot (Set-of-Mark numbered badges over interactive elements, downscaled to point size) as image content, plus a text block with the id→label(role) mark table, point size, and session label. ALSO returns structuredContent: the same marks with their rects in point space, plus — on web sessions — page_text (the visible text of the frame, scoped by the same modal rule the marks are) and frame_url (the frame's location, redacted to scheme/host/port/path). On macOS, page_text is present too (the front frame's visible static text, scoped the same way the marks are) and there is no frame_url — a window has no location, and the key is ABSENT rather than null. A macOS observation is a snapshot of a live app, and one thing on screen expires on its own: an open MENU self-dismisses after roughly 7 seconds of no input, so its items are addressable only for about that long after you observe them — act on the next call, don't deliberate, and re-open the menu if the marks come back without it. Pass clean:true for the unmarked frame.",
                 obj(["session_id": prop("string", "The session id (UUID) from start_ui_session."),
                      "clean": prop("boolean", "Return the unmarked frame instead of the marked one (default false).")],
                     required: ["session_id"]),
                 outputSchema: UIObservationPayload.outputSchema()),

            tool(UISessionTool.actUI.rawValue,
                 "Perform one UI action in a session, then auto-observe. `tool` is one of the platform's action tools (web: tap, tap_mark, double_tap, right_click, scroll, scroll_into_view, type, set_value, key_shortcut, navigate, back, forward, refresh, fill_credential, wait; ios: tap, tap_mark, double_tap, swipe, type, press_button, fill_credential, wait; macos: tap, tap_mark, double_tap, right_click, scroll, type, key_shortcut, fill_credential, wait). Pass that tool's args at the top level (e.g. tap_mark → id; scroll_into_view → id; set_value → id,value; tap → x,y; type → text; scroll → x,y,dx,dy; navigate → url; key_shortcut → keys; fill_credential → field). set_value (WEB ONLY) sets an input/textarea/select behind a mark id to a value the controlled-component (React/Vue) way — use it for date/datetime-local/time/month/week/number inputs and for select dropdowns, and whenever a plain `type` lands nothing because the field is controlled; the returned observation reports whether the value stuck. scroll_into_view (WEB ONLY) scrolls a mark's element fully into view without clicking it — marks cover only what intersects the viewport, so this is how you reach an element clipped by the fold: scroll it to the centre, then read the re-probed marks in the returned observation. fill_credential types the session's staged credential into the FOCUSED field — focus it first (tap_mark), and start the session with credential_id or the step FAILS. ON macOS, tap_mark's meaning follows the mark's ROLE, so you can tell from the mark table what it will do: a textField/textArea/comboBox/searchField/secureTextField is FOCUSED (not pressed — pressing a field does nothing, which is why type used to land in the previous field); a row/cell is SELECTED, never activated — to OPEN a row, double_tap at its centre (the rect is in structuredContent.marks); everything else is pressed as before. ALSO ON macOS: an open menu dismisses itself after roughly 7 seconds of no input. That is AppKit's behaviour, not a timeout Harness imposes and not something it can hold open, so act on a menu promptly — observe, then tap the item in the next call rather than pausing to think between them; if the menu is gone from the marks, re-open it. Returns the same payload as observe_ui. Meta tools (read_screen, note_friction, mark_goal_done) are rejected.",
                 obj(["session_id": prop("string", "The session id (UUID)."),
                      "tool": prop("string", "The action tool name."),
                      "id": prop("integer", "Set-of-Mark id (tool=tap_mark or tool=scroll_into_view)."),
                      "x": prop("integer", "X coordinate (tap/double_tap/right_click/scroll)."),
                      "y": prop("integer", "Y coordinate (tap/double_tap/right_click/scroll)."),
                      "dx": prop("integer", "Horizontal scroll pixels (tool=scroll)."),
                      "dy": prop("integer", "Vertical scroll pixels; positive = down (tool=scroll)."),
                      "x1": prop("integer", "Swipe start X (tool=swipe, ios)."),
                      "y1": prop("integer", "Swipe start Y (tool=swipe, ios)."),
                      "x2": prop("integer", "Swipe end X (tool=swipe, ios)."),
                      "y2": prop("integer", "Swipe end Y (tool=swipe, ios)."),
                      "duration_ms": prop("integer", "Swipe duration ms (tool=swipe, ios)."),
                      "text": prop("string", "Text to type (tool=type)."),
                      "value": prop("string", "Value to set on the marked field (tool=set_value). Date/time fields use ISO-like formats — datetime-local yyyy-MM-ddThh:mm, date yyyy-MM-dd, time hh:mm; a select takes the option value or its visible label."),
                      "keys": arrayProp("Modifiers + final key, e.g. [\"cmd\",\"a\"] (tool=key_shortcut).", items: prop("string", "A key name.")),
                      "url": prop("string", "URL to load (tool=navigate)."),
                      "field": enumProp(["username", "password"], "Which slot of the session's staged credential to type (tool=fill_credential; default username). The value itself never appears in the request or the result."),
                      "button": enumProp(["home", "lock", "side", "siri"], "Hardware button (tool=press_button, ios)."),
                      "ms": prop("integer", "Milliseconds to wait (tool=wait).")],
                     required: ["session_id", "tool"]),
                 outputSchema: UIObservationPayload.outputSchema()),

            tool(UISessionTool.endUISession.rawValue,
                 "Close a UI session and tear down its target (WKWebView / simulator / the launched macOS app — a macOS session QUITS the app on close). Idempotent — an unknown or already-closed session id returns a calm \"already closed\" status, not an error.",
                 obj(["session_id": prop("string", "The session id (UUID).")],
                     required: ["session_id"])),

            tool(UISessionTool.listUISessions.rawValue,
                 "List open UI sessions: id, platform, label, created time, and idle seconds since the last observe/act.",
                 obj([:], required: [])),

            tool(UISessionTool.exportUISessionState.rawValue,
                 "Web sessions ONLY. Return this session's cookies plus the CURRENT origin's localStorage, in exactly the shape start_ui_session's session_state accepts. Intended flow: start a session with visible:true → a human logs in by hand → export here → the client stores the result in a secret manager → later headless runs pass it back as session_state. **THE RESULT IS SENSITIVE**: session cookies are bearer credentials — treat it like a password, never write it to a repo file, a log, or a transcript you keep. Harness itself never logs or persists it.",
                 obj(["session_id": prop("string", "The session id (UUID) of an open WEB session.")],
                     required: ["session_id"]))
        ]
    }

    /// Schema for `start_ui_session(session_state:)` — the injectable cookie /
    /// localStorage bundle. Kept beside the tool so the accepted shape and the
    /// shape `export_ui_session_state` RETURNS stay identical: an export must
    /// round-trip into an injection with no client-side transformation.
    private static func sessionStateSchema() -> [String: Any] {
        [
            "type": "object",
            "description": "platform=web ONLY. Cookies / localStorage to seed into the session BEFORE its first navigation — the authenticated-app path for products that have no password to type (SSO-only apps). SENSITIVE: cookie values are login credentials; Harness never logs them, never writes them to the artifact bundle, and never persists them (the data store stays NON-PERSISTENT, so the state dies with the session). Get this object from export_ui_session_state.",
            "properties": [
                "cookies": [
                    "type": "array",
                    "description": "Cookies to install in the session's cookie store before the first request.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "value": ["type": "string", "description": "SENSITIVE — the cookie value."],
                            "domain": ["type": "string", "description": "Cookie domain, e.g. \".example.com\"."],
                            "path": ["type": "string", "description": "Cookie path (default \"/\")."],
                            "expires": ["type": "number", "description": "Expiry in SECONDS since the Unix epoch. Omit for a session cookie."],
                            "secure": ["type": "boolean"],
                            "httpOnly": ["type": "boolean"]
                        ],
                        "required": ["name", "value", "domain"]
                    ]
                ],
                "origins": [
                    "type": "array",
                    "description": "Optional localStorage per origin. Each origin costs one extra page load at start (localStorage is only reachable from a document on that origin); a cookie-only state costs none.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "origin": ["type": "string", "description": "Scheme + host + port, e.g. \"https://app.example.com\"."],
                            "localStorage": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "name": ["type": "string"],
                                        "value": ["type": "string", "description": "SENSITIVE — may be a bearer token."]
                                    ],
                                    "required": ["name", "value"]
                                ]
                            ]
                        ],
                        "required": ["origin", "localStorage"]
                    ]
                ]
            ],
            "required": []
        ]
    }

    // MARK: - Schema builders

    /// One `tools/list` entry. `outputSchema` is emitted only when the tool
    /// actually returns `structuredContent` — advertising one for a tool that
    /// returns only content blocks would make a strict client reject a
    /// perfectly good result.
    private static func tool(
        _ name: String,
        _ description: String,
        _ inputSchema: [String: Any],
        outputSchema: [String: Any]? = nil
    ) -> [String: Any] {
        var def: [String: Any] = ["name": name, "description": description, "inputSchema": inputSchema]
        if let outputSchema { def["outputSchema"] = outputSchema }
        return def
    }

    /// Schema for `start_ui_session(env:)` — W26. Free-form string→string, so
    /// the object takes `additionalProperties` rather than a property list.
    private static func envSchema() -> [String: Any] {
        [
            "type": "object",
            "description": "platform=macos ONLY. Environment variables applied to the LAUNCHED app — how you reach an app's own test-fixture mode (a sandbox home, a seeded database, a \"don't touch the real data\" switch): the macOS counterpart of web's session_state. Values are handed to LaunchServices and ADDED to the environment the app would normally launch with — an existing name is overridden, the rest is untouched — and appear in the new process's environment verbatim; there is no shell on the path, so nothing is expanded, word-split, or interpolated. Applies to the locally built .app you named in app_path / project_path and nothing else. Rejected on web and iOS sessions rather than silently dropped. May carry secrets — Harness never logs the values (the launch line records key names only).",
            "additionalProperties": ["type": "string"]
        ]
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
