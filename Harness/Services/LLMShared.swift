//
//  LLMShared.swift
//  Harness
//
//  Provider-neutral helpers used by every `LLMClient` implementation.
//  Each client speaks its provider's wire format (Anthropic, OpenAI,
//  Gemini), but the model-facing tool vocabulary is one-to-one across
//  providers, so the per-tool decode (raw input JSON → typed `ToolCall`)
//  lives here.
//
//  Adding a tool means adding a `ToolKind` case + its `ToolInput`
//  variant, then extending `LLMShared.toolCall(name:inputData:)` to
//  decode the new variant. No per-client duplication.
//

import Foundation

enum LLMShared {

    /// Build a typed `ToolCall` from a tool name + input JSON blob. Both
    /// arguments come from the provider's response (Anthropic's
    /// `tool_use.{name,input}`, OpenAI's `tool_calls[].function.{name,arguments}`,
    /// Gemini's `functionCall.{name,args}` — note OpenAI returns
    /// arguments as a JSON-encoded **string** which the client must parse
    /// to `Data` before calling here).
    ///
    /// Throws `LLMError.unknownTool` for an unrecognized name and
    /// `LLMError.invalidToolCall` for input that doesn't decode to an
    /// object.
    static func toolCall(name: String, inputData: Data) throws -> ToolCall {
        guard let kind = ToolKind(rawValue: name) else {
            throw LLMError.unknownTool(name)
        }

        guard let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
            throw LLMError.invalidToolCall(detail: "input is not an object")
        }

        let observation = (input["observation"] as? String) ?? ""
        let intent = (input["intent"] as? String) ?? ""

        let payload: ToolInput
        switch kind {
        case .tap:
            payload = .tap(x: intValue(input["x"]) ?? 0, y: intValue(input["y"]) ?? 0)
        case .doubleTap:
            payload = .doubleTap(x: intValue(input["x"]) ?? 0, y: intValue(input["y"]) ?? 0)
        case .swipe:
            payload = .swipe(
                x1: intValue(input["x1"]) ?? 0,
                y1: intValue(input["y1"]) ?? 0,
                x2: intValue(input["x2"]) ?? 0,
                y2: intValue(input["y2"]) ?? 0,
                durationMs: intValue(input["duration_ms"]) ?? 200
            )
        case .type:
            payload = .type(text: (input["text"] as? String) ?? "")
        case .pressButton:
            let raw = (input["button"] as? String) ?? "home"
            payload = .pressButton(button: SimulatorButton(rawValue: raw) ?? .home)
        case .wait:
            payload = .wait(ms: intValue(input["ms"]) ?? 500)
        case .readScreen:
            payload = .readScreen
        case .noteFriction:
            let kindRaw = (input["kind"] as? String) ?? FrictionKind.unexpectedState.rawValue
            let frictionKind = FrictionKind(rawValue: kindRaw) ?? .unexpectedState
            payload = .noteFriction(kind: frictionKind, detail: (input["detail"] as? String) ?? "")
        case .markGoalDone:
            let verdictRaw = (input["verdict"] as? String) ?? Verdict.blocked.rawValue
            let verdict = Verdict(rawValue: verdictRaw) ?? .blocked
            payload = .markGoalDone(
                verdict: verdict,
                summary: (input["summary"] as? String) ?? "",
                frictionCount: intValue(input["friction_count"]) ?? 0,
                wouldRealUserSucceed: (input["would_real_user_succeed"] as? Bool) ?? false
            )
        case .rightClick:
            payload = .rightClick(x: intValue(input["x"]) ?? 0, y: intValue(input["y"]) ?? 0)
        case .keyShortcut:
            let keys = (input["keys"] as? [String]) ?? []
            payload = .keyShortcut(keys: keys)
        case .scroll:
            payload = .scroll(
                x: intValue(input["x"]) ?? 0,
                y: intValue(input["y"]) ?? 0,
                dx: intValue(input["dx"]) ?? 0,
                dy: intValue(input["dy"]) ?? 0
            )
        case .navigate:
            payload = .navigate(url: (input["url"] as? String) ?? "")
        case .back:
            payload = .back
        case .forward:
            payload = .forward
        case .refresh:
            payload = .refresh
        case .fillCredential:
            // Fall back to .username if the model omits the field — it's
            // the safer of the two slots to retry against (typing the
            // username doesn't expose anything sensitive). The driver
            // ignores the call when no credential is staged.
            let raw = (input["field"] as? String) ?? CredentialField.username.rawValue
            let field = CredentialField(rawValue: raw) ?? .username
            payload = .fillCredential(field: field)
        case .tapMark:
            payload = .tapMark(id: intValue(input["id"]) ?? 0)
        }

        return ToolCall(tool: kind, input: payload, observation: observation, intent: intent)
    }

    /// Models occasionally return numbers as strings if their JSON encoder
    /// is inconsistent. Coerce defensively across providers.
    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }

    /// Builds the text portion of the **current turn**'s user message —
    /// shared across all four `LLMClient` implementations so the
    /// instruction the model receives is identical regardless of provider.
    ///
    /// Composition:
    ///   1. Bolded call-to-action (one tool call this turn).
    ///   2. **Behavior reminders** — short bullet list that addresses
    ///      the failure modes we've seen empirically on small local
    ///      vision models. These read as duplicates of what the system
    ///      prompt covers, intentionally: local 8B models respond
    ///      much better to repeated immediate prompts than to a single
    ///      mention buried in the system prompt cached from earlier
    ///      turns. The list intentionally stays short — three bullets,
    ///      each one a specific failure mode the run logs revealed.
    ///   3. Screenshot annotation (when provided by the platform —
    ///      web's Set-of-Mark id→label table).
    static func currentTurnInstruction(annotation: String) -> String {
        let header = """
            Current screen attached. Choose your next action by calling exactly one tool.

            Reminders before responding:
            - When an element has a numbered mark badge, you MUST call `tap_mark(id)` — never `tap(x, y)` — and the id MUST be one you can see in the marks list below for THIS screenshot. Never reuse a remembered id from a prior turn; mark ids re-number every turn.
            - When the previous result said "page did not move" or "click was effectively a no-op", do not repeat that tool. Try a different tool (a different `tap_mark` id, or `mark_goal_done` if you have read enough).
            - If two consecutive screenshots look the same, the action did not have an effect — pick a different action.
            """
        if annotation.isEmpty {
            return header
        }
        return "\(header)\n\n\(annotation)"
    }

}
