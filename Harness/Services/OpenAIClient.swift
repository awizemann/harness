//
//  OpenAIClient.swift
//  Harness
//
//  `LLMClient` implementation for OpenAI Chat Completions. Translates the
//  provider-neutral `LLMStepRequest` into the OpenAI body shape, posts to
//  `https://api.openai.com/v1/chat/completions`, and projects the response
//  back to `LLMStepResponse`.
//
//  Differences from `ClaudeClient` worth knowing:
//    - System prompt is a regular `messages[0]` with role:"system".
//      No top-level `system` field, no `cache_control` markers (OpenAI's
//      prompt cache is automatic at ≥1024-token requests with a 50%
//      discount on the cached portion).
//    - Images use the `image_url` content block with a `data:image/jpeg;base64,...`
//      URL — a different shape from Anthropic's `{type:"image", source:{...}}`.
//    - Tool definitions wrap the canonical JSON Schema in `{type:"function", function:{...}}`.
//    - **Tool call arguments arrive as a JSON-encoded string** in
//      `choices[0].message.tool_calls[].function.arguments` (Anthropic
//      delivers a parsed object). The decode path JSON-parses it before
//      handing to `LLMShared.toolCall(name:inputData:)`.
//    - `tool_choice: "required"` forces the model to call exactly one
//      tool — important for cheaper models (GPT-4.1 Nano in particular)
//      that otherwise punt to plain text more often than Claude does.
//    - 429 responses: parse `retry-after` (seconds) AND `retry-after-ms`
//      (milliseconds, surfaced on some endpoints). Default to 2s if neither
//      header is present.
//    - Token usage: `usage.prompt_tokens` / `usage.completion_tokens` plus
//      `usage.prompt_tokens_details.cached_tokens` for cache hits. Reasoning
//      token count from `completion_tokens_details.reasoning_tokens` is
//      already counted inside `completion_tokens`; we surface it as
//      `TokenUsage.thinkingTokens` (telemetry-only — billing math reads
//      `outputTokens`, not thinking).
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

actor OpenAIClient: LLMClient {

    private static let logger = Logger(subsystem: "com.harness.app", category: "OpenAIClient")

    private let keychain: any KeychainStoring
    private let session: URLSession
    private let baseURL: URL

    private(set) var tokensUsedThisRun: TokenUsage = .zero

    /// `baseURL` is overridable for tests. Production hits `https://api.openai.com`.
    init(
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com")!
    ) {
        self.keychain = keychain
        self.session = session
        self.baseURL = baseURL
    }

    func reset() {
        tokensUsedThisRun = .zero
    }

    func step(_ request: LLMStepRequest) async throws -> LLMStepResponse {
        try Task.checkCancellation()

        guard let apiKey = try keychain.readKey(for: .openai), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 120

        let body = Self.buildRequestBody(request)
        urlRequest.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMError.timeout
        } catch {
            Self.logger.error("OpenAI request failed: \(error.localizedDescription, privacy: .public)")
            throw LLMError.serverError(status: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.serverError(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw LLMError.authenticationFailed
        case 429:
            let retry = Self.parseRetryAfter(headers: http.allHeaderFields)
            throw LLMError.rateLimited(retryAfter: retry)
        case 400:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.malformedRequest(detail: body)
        case 500...599:
            throw LLMError.serverError(status: http.statusCode)
        default:
            throw LLMError.serverError(status: http.statusCode)
        }

        let parsed: ParsedResponse
        do {
            parsed = try Self.decodeResponse(data)
        } catch let llmError as LLMError {
            // `decodeResponse` may surface multi-tool / parse errors as
            // `LLMError`s — let those fall through to the loop's retry
            // path verbatim, no remap.
            throw llmError
        } catch {
            Self.logger.error("OpenAI decode failed: \(error.localizedDescription, privacy: .public)")
            throw LLMError.decodingFailed(detail: error.localizedDescription)
        }

        // Update running usage.
        tokensUsedThisRun = TokenUsage(
            inputTokens: tokensUsedThisRun.inputTokens + parsed.usage.inputTokens,
            outputTokens: tokensUsedThisRun.outputTokens + parsed.usage.outputTokens,
            cacheReadInputTokens: tokensUsedThisRun.cacheReadInputTokens + parsed.usage.cacheReadInputTokens,
            cacheCreationInputTokens: tokensUsedThisRun.cacheCreationInputTokens + parsed.usage.cacheCreationInputTokens,
            thinkingTokens: tokensUsedThisRun.thinkingTokens + parsed.usage.thinkingTokens
        )

        guard let toolCallSpec = parsed.toolCall else {
            throw LLMError.noToolCallReturned
        }

        let toolCall = try LLMShared.toolCall(
            name: toolCallSpec.name,
            inputData: toolCallSpec.argumentsData
        )
        return LLMStepResponse(toolCall: toolCall, inlineFriction: parsed.inlineFriction, usage: parsed.usage)
    }

    // MARK: Request body

    private static func buildRequestBody(_ request: LLMStepRequest) -> Data {
        let system = assembleSystem(
            request.systemPrompt,
            persona: request.persona,
            goal: request.goal,
            pointSize: request.pointSize,
            platformContext: request.platformContext,
            deviceName: request.deviceName,
            credentialBlock: request.credentialBlock
        )

        var messages: [[String: Any]] = []

        // System message — first in the list. OpenAI doesn't have a
        // top-level `system` field on Chat Completions; it's just
        // role:"system" content.
        messages.append([
            "role": "system",
            "content": system
        ])

        // Compact history. Same one-user-message-per-turn shape ClaudeClient
        // uses, but with `image_url` content blocks instead of Anthropic's
        // `image`/`source` shape.
        for turn in request.history {
            var content: [[String: Any]] = []
            if let img = turn.screenshotJPEG {
                content.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(img.base64EncodedString())"
                    ]
                ])
            }
            let toolInputString = String(data: turn.toolInputJSON, encoding: .utf8) ?? "{}"
            content.append([
                "type": "text",
                "text": """
                Step recap:
                  observation: \(turn.observation)
                  intent: \(turn.intent)
                  tool: \(turn.toolName) \(toolInputString)
                  result: \(turn.toolResultSummary)
                """
            ])
            messages.append([
                "role": "user",
                "content": content
            ])
        }

        // Current turn. On retries the loop sets `retryHint` so the model
        // sees what went wrong on the prior attempt.
        let currentText: String
        if let hint = request.retryHint, !hint.isEmpty {
            currentText = """
            Your previous response was rejected: \(hint)
            Emit exactly one tool call.

            Current screen attached. Choose your next action by calling exactly one tool.
            """
        } else {
            currentText = "Current screen attached. Choose your next action by calling exactly one tool."
        }
        let currentContent: [[String: Any]] = [
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(request.screenshotJPEG.base64EncodedString())"
                ]
            ],
            [
                "type": "text",
                "text": currentText
            ]
        ]
        messages.append([
            "role": "user",
            "content": currentContent
        ])

        var top: [String: Any] = [
            "model": request.model.rawValue,
            "messages": messages,
            "max_completion_tokens": request.maxOutputTokens,
            "tools": ToolSchema.openAIShape(
                ToolSchema.canonical(platform: request.platformKind)
            ),
            // Force the model to call a tool. Cheaper models (4.1 Nano,
            // sometimes 5 Mini) otherwise occasionally answer in plain
            // text — the loop has a retry path for that, but `required`
            // tightens the failure rate.
            "tool_choice": "required"
        ]
        if request.deterministic {
            top["temperature"] = 0
            top["top_p"] = 1.0
        }

        return (try? JSONSerialization.data(withJSONObject: top, options: [])) ?? Data()
    }

    /// Mirror of `ClaudeClient.assembleSystem`. Kept duplicated rather
    /// than shared because the substitutions are tiny and lifting to a
    /// helper would only save a handful of lines while making the
    /// per-client request body harder to read.
    private static func assembleSystem(
        _ systemPrompt: String,
        persona: String,
        goal: String,
        pointSize: CGSize,
        platformContext: String,
        deviceName: String,
        credentialBlock: String
    ) -> String {
        var s = systemPrompt
        if !platformContext.isEmpty {
            s = platformContext + "\n\n" + s
        }
        s = s.replacingOccurrences(of: "{{POINT_WIDTH}}", with: "\(Int(pointSize.width))")
        s = s.replacingOccurrences(of: "{{POINT_HEIGHT}}", with: "\(Int(pointSize.height))")
        s = s.replacingOccurrences(of: "{{PERSONA}}", with: persona)
        s = s.replacingOccurrences(of: "{{GOAL}}", with: goal)
        s = s.replacingOccurrences(of: "{{DEVICE_NAME}}", with: deviceName)
        s = s.replacingOccurrences(of: "{{CREDENTIALS}}", with: credentialBlock)
        return s
    }

    // MARK: Response decoding

    private struct ParsedResponse {
        let toolCall: ToolCallSpec?
        let inlineFriction: [(FrictionKind, String)]
        let usage: TokenUsage
    }

    private struct ToolCallSpec {
        let id: String
        let name: String
        let argumentsData: Data
    }

    /// Decode a Chat Completions response. Throws `LLMError.invalidToolCall`
    /// when the model returns >1 tool call (the loop expects exactly one
    /// per turn) so the parse-retry path kicks in with a corrective hint
    /// instead of silently dropping the rest.
    private static func decodeResponse(_ data: Data) throws -> ParsedResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed(detail: "root is not an object")
        }

        let usage: TokenUsage = {
            guard let u = root["usage"] as? [String: Any] else { return .zero }
            let prompt = (u["prompt_tokens"] as? Int) ?? 0
            let completion = (u["completion_tokens"] as? Int) ?? 0
            let cached = ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
            let reasoning = ((u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int) ?? 0
            return TokenUsage(
                inputTokens: prompt,
                outputTokens: completion,
                cacheReadInputTokens: cached,
                cacheCreationInputTokens: 0,    // OpenAI's automatic cache has no explicit write cost
                thinkingTokens: reasoning
            )
        }()

        // Tool calls live on `choices[0].message.tool_calls[]`. Each entry
        // has `id`, `type:"function"`, and `function:{name, arguments}`.
        // **Arguments arrive as a JSON-encoded string**, not an object.
        var calls: [ToolCallSpec] = []
        if let choices = root["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let id = (tc["id"] as? String) ?? ""
                let argumentsString = (function["arguments"] as? String) ?? "{}"
                let argumentsData = argumentsString.data(using: .utf8) ?? Data("{}".utf8)
                calls.append(ToolCallSpec(id: id, name: name, argumentsData: argumentsData))
            }
        }

        // Per the system prompt, exactly one ACTION tool call per turn,
        // plus zero-or-more `note_friction` calls riding alongside.
        // Split + accept; surface frictions through `inlineFriction`.
        let frictionName = ToolKind.noteFriction.rawValue
        let actionCalls = calls.filter { $0.name != frictionName }
        let frictionCalls = calls.filter { $0.name == frictionName }

        if actionCalls.count > 1 {
            let names = actionCalls.map { $0.name }.joined(separator: ", ")
            throw LLMError.invalidToolCall(
                detail: "model emitted \(actionCalls.count) action tool calls (\(names)); expected exactly one (note_friction may accompany it)"
            )
        }

        let inlineFriction: [(FrictionKind, String)] = frictionCalls.compactMap { spec in
            guard let dict = (try? JSONSerialization.jsonObject(with: spec.argumentsData)) as? [String: Any]
            else { return nil }
            let kindRaw = (dict["kind"] as? String) ?? FrictionKind.unexpectedState.rawValue
            let kind = FrictionKind(rawValue: kindRaw) ?? .unexpectedState
            let detail = (dict["detail"] as? String) ?? ""
            return (kind, detail)
        }

        return ParsedResponse(toolCall: actionCalls.first, inlineFriction: inlineFriction, usage: usage)
    }

    // MARK: Headers

    /// OpenAI surfaces both `retry-after` (seconds) and `retry-after-ms`
    /// (milliseconds) on rate-limit responses depending on the endpoint
    /// and model; honor whichever is present.
    private static func parseRetryAfter(headers: [AnyHashable: Any]) -> Duration {
        var seconds: Int?
        for (key, value) in headers {
            guard let k = key as? String else { continue }
            let lower = k.lowercased()
            if lower == "retry-after-ms" {
                if let s = value as? String, let ms = Int(s) {
                    return .milliseconds(min(60_000, max(100, ms)))
                }
                if let ms = value as? Int {
                    return .milliseconds(min(60_000, max(100, ms)))
                }
            } else if lower == "retry-after" {
                if let s = value as? String, let secs = Int(s) {
                    seconds = secs
                } else if let secs = value as? Int {
                    seconds = secs
                }
            }
        }
        if let secs = seconds {
            return .seconds(min(60, max(1, secs)))
        }
        return .seconds(2)
    }
}
