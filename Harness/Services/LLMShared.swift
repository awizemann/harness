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

}
