//
//  AgentTools.swift
//  Harness
//
//  The model-facing tool schema. **This file and `wiki/Tool-Schema.md` must
//  agree byte-for-byte** — a CI test (Phase 2) loads the wiki page, parses
//  the documented schema, and #expects equality with `ToolSchema.toolDefinitions`.
//
//  Phase 1 ships the schema definitions only; the Phase 2 agent loop wires
//  them through.
//
//  Implementation note: definitions are computed inline (not stored as static
//  `[String: Any]` properties) because Swift 6 strict concurrency forbids
//  non-Sendable static state. The cost is negligible — these are built once
//  per Claude call.
//

import Foundation

enum ToolSchema {

    // MARK: Public API

    /// Canonical JSON dictionaries for each tool. `cacheControl: true` adds the
    /// Anthropic prompt-caching marker on the last tool definition (the runtime
    /// caches the whole tools array on the first call of a run).
    static func toolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        var defs: [[String: Any]] = [
            tap(),
            doubleTap(),
            swipe(),
            type(),
            pressButton(),
            wait(),
            readScreen(),
            noteFriction(),
            markGoalDone()
        ]
        if cacheControl, !defs.isEmpty {
            var last = defs[defs.count - 1]
            last["cache_control"] = ["type": "ephemeral"]
            defs[defs.count - 1] = last
        }
        return defs
    }

    /// Names in canonical order.
    static let allToolNames: [String] = [
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

    // MARK: Per-tool definitions

    private static func tap() -> [String: Any] {
        [
            "name": "tap",
            "description": "Tap a single point on the screen. Coordinates in screen points, top-left origin.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "x": ["type": "integer", "description": "x coordinate in points"],
                    "y": ["type": "integer", "description": "y coordinate in points"],
                    "observation": ["type": "string", "description": "What you see right now."],
                    "intent": ["type": "string", "description": "What this action is for and why it serves the goal."]
                ],
                "required": ["x", "y", "observation", "intent"]
            ]
        ]
    }

    private static func doubleTap() -> [String: Any] {
        [
            "name": "double_tap",
            "description": "Tap twice quickly at one point.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "x": ["type": "integer"],
                    "y": ["type": "integer"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["x", "y", "observation", "intent"]
            ]
        ]
    }

    private static func swipe() -> [String: Any] {
        [
            "name": "swipe",
            "description": "Swipe from one point to another over a duration.",
            "input_schema": [
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
        ]
    }

    private static func type() -> [String: Any] {
        [
            "name": "type",
            "description": "Type a string of characters into the currently-focused field.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["text", "observation", "intent"]
            ]
        ]
    }

    private static func pressButton() -> [String: Any] {
        [
            "name": "press_button",
            "description": "Press a hardware-style button on the simulator.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "button": ["type": "string", "enum": ["home", "lock", "side", "siri"]],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["button", "observation", "intent"]
            ]
        ]
    }

    private static func wait() -> [String: Any] {
        [
            "name": "wait",
            "description": "Pause for some milliseconds. The loop captures a fresh screenshot afterward.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "ms": ["type": "integer"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["ms", "observation", "intent"]
            ]
        ]
    }

    private static func readScreen() -> [String: Any] {
        [
            "name": "read_screen",
            "description": "No-op. Forces a fresh screenshot capture next iteration without any UI action.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["observation", "intent"]
            ]
        ]
    }

    private static func noteFriction() -> [String: Any] {
        [
            "name": "note_friction",
            "description": "Flag a UX problem. Emit alongside or instead of an action. Multiple per step OK.",
            "input_schema": [
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
        ]
    }

    private static func markGoalDone() -> [String: Any] {
        [
            "name": "mark_goal_done",
            "description": "Terminate the run. Emit when you've succeeded, failed, or would give up as a real user.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "verdict": ["type": "string", "enum": ["success", "failure", "blocked"]],
                    "summary": ["type": "string"],
                    "friction_count": ["type": "integer"],
                    "would_real_user_succeed": ["type": "boolean"]
                ],
                "required": ["verdict", "summary", "friction_count", "would_real_user_succeed"]
            ]
        ]
    }
}
