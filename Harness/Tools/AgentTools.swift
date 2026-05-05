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
//  Implementation note: definitions are computed inline (not stored as
//  static `[String: Any]` properties) because Swift 6 strict concurrency
//  forbids non-Sendable static state. The cost is negligible — the array
//  is built once per Claude call.
//

import Foundation

enum ToolSchema {

    // MARK: - iOS (the original schema — unchanged shape, agent path)

    /// Canonical JSON dictionaries for the iOS tool set. `cacheControl` adds
    /// the Anthropic prompt-caching marker on the last definition.
    static func iOSToolDefinitions(cacheControl: Bool) -> [[String: Any]] {
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

    // MARK: - macOS (Phase 2)
    //
    // Drops `swipe` / `press_button` (no hardware buttons on macOS, no
    // touch swipe gestures), adds `right_click`, `key_shortcut`, `scroll`.
    // `tap` is renamed-in-spirit to "click left mouse button" but we keep
    // the same tool name so the agent's vocabulary stays small across
    // platforms — the description tells the model what the click means
    // for this platform.

    static func macOSToolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        var defs: [[String: Any]] = [
            tapMac(),
            doubleTapMac(),
            rightClick(),
            scroll(),
            type(),
            keyShortcut(),
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

    // MARK: - Web (Phase 3) — placeholder schema; Phase 3 wires the driver.

    static func webToolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        var defs: [[String: Any]] = [
            tapWeb(),
            doubleTapMac(),
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
        if cacheControl, !defs.isEmpty {
            var last = defs[defs.count - 1]
            last["cache_control"] = ["type": "ephemeral"]
            defs[defs.count - 1] = last
        }
        return defs
    }

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

    // MARK: - Per-tool definitions

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

    private static func tapMac() -> [String: Any] {
        [
            "name": "tap",
            "description": "Click the left mouse button at one point. Coordinates in window points (top-left origin within the captured window).",
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

    private static func tapWeb() -> [String: Any] {
        [
            "name": "tap",
            "description": "Click at one point. Coordinates in CSS pixels (top-left origin within the rendered viewport).",
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

    private static func doubleTapMac() -> [String: Any] {
        [
            "name": "double_tap",
            "description": "Double-click the left mouse button at one point. (Same name as iOS double-tap; click on macOS / web.)",
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

    // MARK: - macOS / web extensions

    private static func rightClick() -> [String: Any] {
        [
            "name": "right_click",
            "description": "Right-click (secondary click) at one point — opens context menus on macOS / web.",
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

    private static func scroll() -> [String: Any] {
        [
            "name": "scroll",
            "description": "Scroll at a point. Positive dy = scroll DOWN (content moves up); positive dx = scroll RIGHT. Magnitude is in PIXELS — half a viewport is typically 300–400. The driver finds the nearest scrollable container under (x, y) and scrolls it.",
            "input_schema": [
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
        ]
    }

    private static func keyShortcut() -> [String: Any] {
        [
            "name": "key_shortcut",
            "description": "Press a keyboard shortcut. Pass modifiers + the final key in order, e.g. ['cmd','shift','n']. Modifier names: 'cmd', 'shift', 'option', 'control', 'fn'.",
            "input_schema": [
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
        ]
    }

    private static func navigate() -> [String: Any] {
        [
            "name": "navigate",
            "description": "Load a URL in the embedded browser.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "observation": ["type": "string"],
                    "intent": ["type": "string"]
                ],
                "required": ["url", "observation", "intent"]
            ]
        ]
    }

    private static func back() -> [String: Any] {
        [
            "name": "back",
            "description": "Browser back button.",
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

    private static func forward() -> [String: Any] {
        [
            "name": "forward",
            "description": "Browser forward button.",
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

    private static func refresh() -> [String: Any] {
        [
            "name": "refresh",
            "description": "Reload the current page.",
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
