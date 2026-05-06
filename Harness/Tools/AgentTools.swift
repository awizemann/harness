//
//  AgentTools.swift
//  Harness
//
//  The model-facing tool schema. Phase 2 split this into per-platform
//  builders so each `PlatformAdapter` can hand the agent only the tools
//  its driver can actually execute.
//
//  **`ToolSchema.iOSToolDefinitions(...)` and `https://github.com/awizemann/harness/wiki/Tool-Schema`
//  must agree byte-for-byte** (the iOS schema is the canonical reference;
//  CI checks it). macOS / web schemas are documented inline in the wiki
//  page's per-platform sections.
//
//  Multi-provider support: the schema is now built in two layers:
//
//    1. `canonical(platform:)` returns provider-neutral `[CanonicalTool]`.
//       Every tool the agent can call appears exactly once across the
//       entire codebase.
//
//    2. Per-provider shape translators (`anthropicShape`, `openAIShape`,
//       `geminiShape`) project that canonical list into the wire-format
//       dictionary each provider's API expects. Adding a provider means
//       adding one translator function — never duplicating tool definitions.
//
//  The pre-existing `iOSToolDefinitions(cacheControl:)` etc. callers
//  continue to work; they're now thin wrappers around
//  `anthropicShape(canonical(platform: ...))`.
//

import Foundation

// MARK: - Canonical tool definition

/// Provider-neutral tool definition. Holds the name, the model-facing
/// description, and the JSON Schema body that goes inside `input_schema`
/// (Anthropic) / `function.parameters` (OpenAI) / `parameters` (Gemini).
struct CanonicalTool {
    let name: String
    let description: String
    /// JSON Schema object — `{type: "object", properties: {...}, required: [...]}`.
    let jsonSchema: [String: Any]
}

enum ToolSchema {

    // MARK: - Canonical (provider-neutral) per-platform tool sets

    /// Per-platform canonical tool set. Each platform advertises only the
    /// tools its driver can execute; provider-specific projections come
    /// from the shape translators below.
    static func canonical(platform: PlatformKind) -> [CanonicalTool] {
        switch platform {
        case .iosSimulator: return iOSCanonical()
        case .macosApp:     return macOSCanonical()
        case .web:          return webCanonical()
        }
    }

    // MARK: - Provider shape translators

    /// Anthropic Messages API shape: `[{name, description, input_schema, [cache_control]?}]`.
    /// `cacheLast == true` adds an `ephemeral` cache marker on the final
    /// definition so the tool list is part of the prompt cache.
    static func anthropicShape(_ tools: [CanonicalTool], cacheLast: Bool) -> [[String: Any]] {
        var defs: [[String: Any]] = tools.map { t in
            [
                "name": t.name,
                "description": t.description,
                "input_schema": t.jsonSchema
            ]
        }
        if cacheLast, !defs.isEmpty {
            var last = defs[defs.count - 1]
            last["cache_control"] = ["type": "ephemeral"]
            defs[defs.count - 1] = last
        }
        return defs
    }

    /// OpenAI Chat Completions / Responses API shape:
    /// `[{type:"function", function:{name, description, parameters}}]`.
    /// No cache markers — OpenAI prompt caching is automatic at ≥1024
    /// tokens and accepts no per-call directives.
    static func openAIShape(_ tools: [CanonicalTool]) -> [[String: Any]] {
        tools.map { t in
            [
                "type": "function",
                "function": [
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.jsonSchema
                ]
            ]
        }
    }

    // MARK: - Backwards-compatible Anthropic per-platform helpers

    /// Anthropic shape for the iOS toolset. `cacheControl` adds the prompt-
    /// caching marker on the last definition. Existing callers
    /// (`ClaudeClient.buildRequestBody`, the `AgentToolsSchemaTests` suite)
    /// continue to use this; new code should call
    /// `anthropicShape(canonical(platform: .iosSimulator), cacheLast:)`.
    static func iOSToolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        anthropicShape(canonical(platform: .iosSimulator), cacheLast: cacheControl)
    }

    static func macOSToolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        anthropicShape(canonical(platform: .macosApp), cacheLast: cacheControl)
    }

    static func webToolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        anthropicShape(canonical(platform: .web), cacheLast: cacheControl)
    }

    // MARK: - Per-platform tool name lists

    static let iOSToolNames: [String] = [
        ToolKind.tap.rawValue,
        ToolKind.doubleTap.rawValue,
        ToolKind.swipe.rawValue,
        ToolKind.type.rawValue,
        ToolKind.pressButton.rawValue,
        ToolKind.wait.rawValue,
        ToolKind.readScreen.rawValue,
        ToolKind.noteFriction.rawValue,
        ToolKind.markGoalDone.rawValue
    ]

    static let macOSToolNames: [String] = [
        ToolKind.tap.rawValue,
        ToolKind.doubleTap.rawValue,
        ToolKind.rightClick.rawValue,
        ToolKind.scroll.rawValue,
        ToolKind.type.rawValue,
        ToolKind.keyShortcut.rawValue,
        ToolKind.wait.rawValue,
        ToolKind.readScreen.rawValue,
        ToolKind.noteFriction.rawValue,
        ToolKind.markGoalDone.rawValue
    ]

    static let webToolNames: [String] = [
        ToolKind.tap.rawValue,
        ToolKind.doubleTap.rawValue,
        ToolKind.rightClick.rawValue,
        ToolKind.scroll.rawValue,
        ToolKind.type.rawValue,
        ToolKind.keyShortcut.rawValue,
        ToolKind.navigate.rawValue,
        ToolKind.back.rawValue,
        ToolKind.forward.rawValue,
        ToolKind.refresh.rawValue,
        ToolKind.wait.rawValue,
        ToolKind.readScreen.rawValue,
        ToolKind.noteFriction.rawValue,
        ToolKind.markGoalDone.rawValue
    ]

    // MARK: - Per-platform canonical builders

    private static func iOSCanonical() -> [CanonicalTool] {
        [
            tap(description: "Tap a single point on the screen. Coordinates in screen points, top-left origin."),
            doubleTap(description: "Tap twice quickly at one point."),
            swipe(),
            type(),
            pressButton(),
            wait(),
            readScreen(),
            noteFriction(),
            markGoalDone()
        ]
    }

    private static func macOSCanonical() -> [CanonicalTool] {
        // Click left mouse button at one point. Coordinates in window
        // points (top-left origin within the captured window).
        [
            tap(description: "Click the left mouse button at one point. Coordinates in window points (top-left origin within the captured window)."),
            doubleTap(description: "Double-click the left mouse button at one point. (Same name as iOS double-tap; click on macOS / web.)"),
            rightClick(),
            scroll(),
            type(),
            keyShortcut(),
            wait(),
            readScreen(),
            noteFriction(),
            markGoalDone()
        ]
    }

    private static func webCanonical() -> [CanonicalTool] {
        [
            tap(description: "Click at one point. Coordinates in CSS pixels (top-left origin within the rendered viewport)."),
            doubleTap(description: "Double-click the left mouse button at one point. (Same name as iOS double-tap; click on macOS / web.)"),
            rightClick(),
            scroll(),
            type(),
            keyShortcut(),
            navigate(),
            back(),
            forward(),
            refresh(),
            wait(),
            readScreen(),
            noteFriction(),
            markGoalDone()
        ]
    }

    // MARK: - Per-tool canonical definitions
    //
    // Each helper returns a `CanonicalTool`. The shape translators above
    // project these into provider-native dictionaries.

    private static func tap(description: String) -> CanonicalTool {
        CanonicalTool(
            name: "tap",
            description: description,
            jsonSchema: [
                "type": "object",
                "properties": [
                    "x": ["type": "integer", "description": "x coordinate in points"],
                    "y": ["type": "integer", "description": "y coordinate in points"],
                    "observation": ["type": "string", "description": "What you see right now."],
                    "intent": ["type": "string", "description": "What this action is for and why it serves the goal."]
                ],
                "required": ["x", "y", "observation", "intent"]
            ]
        )
    }

    private static func doubleTap(description: String) -> CanonicalTool {
        CanonicalTool(
            name: "double_tap",
            description: description,
            jsonSchema: [
                "type": "object",
                "properties": [
                    "x": ["type": "integer"],
                    "y": ["type": "integer"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["x", "y", "observation", "intent"]
            ]
        )
    }

    private static func swipe() -> CanonicalTool {
        CanonicalTool(
            name: "swipe",
            description: "Swipe from one point to another over a duration.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "x1": ["type": "integer"],
                    "y1": ["type": "integer"],
                    "x2": ["type": "integer"],
                    "y2": ["type": "integer"],
                    "duration_ms": ["type": "integer", "description": "Default 200"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["x1", "y1", "x2", "y2", "observation", "intent"]
            ]
        )
    }

    private static func type() -> CanonicalTool {
        CanonicalTool(
            name: "type",
            description: "Type a string of characters into the currently-focused field.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["text", "observation", "intent"]
            ]
        )
    }

    private static func pressButton() -> CanonicalTool {
        CanonicalTool(
            name: "press_button",
            description: "Press a hardware-style button on the simulator.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "button": ["type": "string", "enum": ["home", "lock", "side", "siri"]],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["button", "observation", "intent"]
            ]
        )
    }

    private static func wait() -> CanonicalTool {
        CanonicalTool(
            name: "wait",
            description: "Pause for some milliseconds. The loop captures a fresh screenshot afterward.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "ms": ["type": "integer"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["ms", "observation", "intent"]
            ]
        )
    }

    private static func readScreen() -> CanonicalTool {
        CanonicalTool(
            name: "read_screen",
            description: "No-op. Forces a fresh screenshot capture next iteration without any UI action.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["observation", "intent"]
            ]
        )
    }

    private static func noteFriction() -> CanonicalTool {
        CanonicalTool(
            name: "note_friction",
            description: "Flag a UX problem. Emit alongside or instead of an action. Multiple per step OK.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["dead_end", "ambiguous_label", "unresponsive", "confusing_copy", "unexpected_state"]
                    ],
                    "detail": ["type": "string", "description": "One or two sentences in the persona's voice."]
                ],
                "required": ["kind", "detail"]
            ]
        )
    }

    private static func markGoalDone() -> CanonicalTool {
        CanonicalTool(
            name: "mark_goal_done",
            description: "Terminate the run. Emit when you've succeeded, failed, or would give up as a real user.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "verdict": ["type": "string", "enum": ["success", "failure", "blocked"]],
                    "summary": ["type": "string"],
                    "friction_count": ["type": "integer"],
                    "would_real_user_succeed": ["type": "boolean"]
                ],
                "required": ["verdict", "summary", "friction_count", "would_real_user_succeed"]
            ]
        )
    }

    // MARK: - macOS / web extensions

    private static func rightClick() -> CanonicalTool {
        CanonicalTool(
            name: "right_click",
            description: "Right-click (secondary click) at one point — opens context menus on macOS / web.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "x": ["type": "integer"],
                    "y": ["type": "integer"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["x", "y", "observation", "intent"]
            ]
        )
    }

    private static func scroll() -> CanonicalTool {
        CanonicalTool(
            name: "scroll",
            description: "Scroll at a point. Positive dy = scroll DOWN (content moves up); positive dx = scroll RIGHT. Magnitude is in PIXELS — half a viewport is typically 300–400. The driver finds the nearest scrollable container under (x, y) and scrolls it.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "x": ["type": "integer", "description": "x coordinate of the cursor for the scroll event"],
                    "y": ["type": "integer", "description": "y coordinate of the cursor for the scroll event"],
                    "dx": ["type": "integer", "description": "Horizontal pixels to scroll. 0 for vertical-only."],
                    "dy": ["type": "integer", "description": "Vertical pixels to scroll. 300–400 ≈ half a viewport."],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["x", "y", "dx", "dy", "observation", "intent"]
            ]
        )
    }

    private static func keyShortcut() -> CanonicalTool {
        CanonicalTool(
            name: "key_shortcut",
            description: "Press a keyboard shortcut. Pass modifiers + the final key in order, e.g. ['cmd','shift','n']. Modifier names: 'cmd', 'shift', 'option', 'control', 'fn'.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "keys": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Modifiers first, ending with the final key (e.g. 'n', 'return', 'escape')."
                    ],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["keys", "observation", "intent"]
            ]
        )
    }

    private static func navigate() -> CanonicalTool {
        CanonicalTool(
            name: "navigate",
            description: "Load a URL in the embedded browser.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["url", "observation", "intent"]
            ]
        )
    }

    private static func back() -> CanonicalTool {
        CanonicalTool(
            name: "back",
            description: "Browser back button.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["observation", "intent"]
            ]
        )
    }

    private static func forward() -> CanonicalTool {
        CanonicalTool(
            name: "forward",
            description: "Browser forward button.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["observation", "intent"]
            ]
        )
    }

    private static func refresh() -> CanonicalTool {
        CanonicalTool(
            name: "refresh",
            description: "Reload the current page.",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["observation", "intent"]
            ]
        )
    }
}

// MARK: - Backwards compatibility

extension ToolSchema {
    /// Pre-Phase-2 callers used `toolDefinitions(cacheControl:)`; this
    /// shim keeps existing tests / callers compiling while the migration
    /// completes. New code should call the per-platform variant.
    static func toolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        iOSToolDefinitions(cacheControl: cacheControl)
    }

    static var allToolNames: [String] { iOSToolNames }
}
