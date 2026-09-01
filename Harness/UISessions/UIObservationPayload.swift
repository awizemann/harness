//
//  UIObservationPayload.swift
//  Harness
//
//  The MCP `structuredContent` encoding for a `UIObservation`, plus the
//  matching JSON-Schema `outputSchema` the tool definitions advertise.
//
//  Lives in the `Harness/` module rather than `HarnessMCP/` for the same
//  reason the rest of the session surface does: the test bundle links the
//  Harness app module, not the MCP tool target, so anything genuinely
//  testable has to live here. `HarnessMCP/UISessionTools.swift` is a thin
//  caller.
//
//  WHY structured marks at all: the text mark table is written for a
//  vision model — `id → "label" (role)`, no geometry. A downstream
//  product driving these tools programmatically (drawing callouts over a
//  frame, diffing a single element between two frames, resolving an
//  intent to a target by position) needs the rects the badges were drawn
//  from. They already exist on the driver; this stops discarding them.
//
//  Back-compat: this is PURELY ADDITIVE. The image + text content blocks
//  are unchanged byte-for-byte; `structuredContent` is a sibling field on
//  the `tools/call` result, which clients that don't know it ignore.
//

import CoreGraphics
import Foundation

enum UIObservationPayload {

    /// Build the `structuredContent` object for an observation.
    ///
    /// Shape:
    /// ```json
    /// {
    ///   "session_id": "…UUID…",
    ///   "step": 3,
    ///   "point_size": { "width": 1280, "height": 800 },
    ///   "marks": [
    ///     { "id": 1, "label": "Sign in", "role": "a", "label_source": "text",
    ///       "rect": { "x": 24, "y": 16, "width": 72, "height": 32 } }
    ///   ],
    ///   "page_text": "…"          // web only; omitted elsewhere
    /// }
    /// ```
    ///
    /// `rect` and `point_size` are in the SAME coordinate space — the
    /// platform's point space (CSS pixels for web, simulator points for
    /// iOS, window points for macOS) — which is also the space `tap(x, y)`
    /// takes. Not the screenshot's pixel space, which differs by the
    /// device scale factor.
    ///
    /// Returns a `[String: Any]` because that's what the hand-rolled
    /// JSON-RPC layer serializes; it is only ever built and consumed
    /// inside the `MCPServer` actor.
    static func structuredContent(_ obs: UIObservation) -> [String: Any] {
        var payload: [String: Any] = [
            "session_id": obs.sessionID.uuidString,
            "step": obs.stepIndex,
            "point_size": [
                "width": jsonNumber(obs.pointSize.width),
                "height": jsonNumber(obs.pointSize.height)
            ],
            "marks": obs.marks.map(markJSON)
        ]
        // Omitted rather than null when the platform has no text roll-up —
        // "we didn't look" and "the page is blank" are different claims, and
        // an absent key is the honest one for the former.
        if let text = obs.pageText, !text.isEmpty {
            payload["page_text"] = text
        }
        return payload
    }

    /// One mark's JSON. `label` is always present (empty string when the
    /// driver resolved no accessible name — the caller shouldn't have to
    /// branch on key presence for the common field).
    static func markJSON(_ mark: InteractiveMark) -> [String: Any] {
        var out: [String: Any] = [
            "id": mark.id,
            "label": mark.label,
            "role": mark.role,
            "rect": [
                "x": jsonNumber(mark.rect.origin.x),
                "y": jsonNumber(mark.rect.origin.y),
                "width": jsonNumber(mark.rect.size.width),
                "height": jsonNumber(mark.rect.size.height)
            ]
        ]
        // Provenance for `label`. Web and macOS both report it; iOS does
        // not. OMITTED — not nulled — where it is unknown: an absent key is
        // the honest form of "we didn't record that", the same convention
        // `page_text` follows.
        if let source = mark.labelSource, !source.isEmpty {
            out["label_source"] = source
        }
        return out
    }

    /// Emit whole values as `Int` so a rect reads `24` and not `24.0` in
    /// the wire JSON (every current probe rounds to whole units), while a
    /// genuinely fractional value still round-trips as a Double. NaN and
    /// infinity — which `JSONSerialization` refuses outright and would take
    /// the whole result down with it — collapse to `0`.
    static func jsonNumber(_ value: CGFloat) -> Any {
        let d = Double(value)
        guard d.isFinite else { return 0 }
        if d == d.rounded(), abs(d) < 1e15 { return Int(d) }
        return d
    }

    // MARK: - outputSchema

    /// JSON Schema for `structuredContent`, advertised as the `outputSchema`
    /// of `observe_ui` and `act_ui` in `tools/list`. Kept beside the encoder
    /// so the two can't drift; the test suite pins them against each other.
    ///
    /// `page_text` is NOT in `required` — it is genuinely absent on iOS and
    /// macOS, and a schema that promised it would be lying about those.
    static func outputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "session_id": [
                    "type": "string",
                    "description": "The UI session's id (UUID)."
                ],
                "step": [
                    "type": "integer",
                    "description": "1-based observation index within the session; matches the steps/NNN.png artifact."
                ],
                "point_size": [
                    "type": "object",
                    "description": "The frame's size in point space — the coordinate space mark rects and tap(x, y) both use.",
                    "properties": [
                        "width": ["type": "number"],
                        "height": ["type": "number"]
                    ],
                    "required": ["width", "height"]
                ],
                "marks": [
                    "type": "array",
                    "description": "The Set-of-Mark interactive elements drawn on the returned image, with geometry. Empty when the probe found none.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "integer", "description": "The badge number; the id tap_mark(id) takes."],
                            "label": ["type": "string", "description": "Accessible label. Never empty in a web or macOS session — an unnameable control gets a synthesized placeholder (see label_source); iOS can still return an empty string."],
                            "role": ["type": "string", "description": "Source-platform role (web: a/button/…; iOS: XCUIElementType…; macOS: AX…)."],
                            "label_source": [
                                "type": "string",
                                "enum": ["aria-label", "labelledby", "label", "placeholder", "title", "value", "secure-field", "text", "img-alt", "svg-title", "text-content", "glyph", "testid", "name", "synthesized", "none", "ax-title", "ax-title-element", "ax-description", "ax-help", "ax-placeholder", "adjacent-text", "ax-identifier"],
                                "description": "Where `label` came from, in the probe's priority order. Web and macOS report it; omitted on iOS. WEB: aria-label / labelledby / label are the durable ones; placeholder and value are sample data that move with copy edits. img-alt / svg-title / text-content / glyph name icon-only controls (glyph reports a close ✕ as \"Close\"); testid is the page's own test hook. MACOS: ax-title / ax-title-element / ax-description / ax-help are what the app itself declared and are the durable ones; ax-placeholder and value are content, not names; adjacent-text is INFERRED — the visible static text beside an otherwise-unnamed control (the SwiftUI TextField case), correct for ordinary form layouts but a guess, so prefer it over nothing and re-check it if a resolver misfires; text is the control's own visible caption (a table row's contents); ax-identifier is the developer's test hook. BOTH: secure-field means a password field, whose value is never used as a label (it would be the plaintext) — the label is the constant \"Password\"; synthesized means nothing was derivable and the label is a placeholder like \"unlabelled textField\" — address that control by position and treat it as an app bug."
                            ],
                            "rect": [
                                "type": "object",
                                "description": "Bounding rect in point space, top-left origin.",
                                "properties": [
                                    "x": ["type": "number"],
                                    "y": ["type": "number"],
                                    "width": ["type": "number"],
                                    "height": ["type": "number"]
                                ],
                                "required": ["x", "y", "width", "height"]
                            ]
                        ],
                        "required": ["id", "label", "role", "rect"]
                    ]
                ],
                "page_text": [
                    "type": "string",
                    "description": "Visible text of the frame, whitespace-normalized and capped at 20000 characters (a trailing … marks truncation). Web sessions (the rendered document's text) and macOS sessions (the front window/sheet/popover's static text, in reading order — scoped to the SAME frame the marks came from). Omitted on iOS, which has no cheap text roll-up."
                ]
            ],
            "required": ["session_id", "step", "point_size", "marks"]
        ]
    }
}
