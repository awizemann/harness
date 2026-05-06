//
//  GeminiClient.swift
//  Harness
//
//  `LLMClient` implementation for Google Gemini's `generateContent` API.
//  Translates the provider-neutral `LLMStepRequest` into the Gemini body
//  shape and projects the response back to `LLMStepResponse`.
//
//  Notable differences from Anthropic / OpenAI:
//    - System prompt goes in a top-level `systemInstruction` field
//      (not as a chat message). Stays cached implicitly on Gemini 2.5+.
//    - Image content uses `inlineData` parts (`{mimeType, data}`) rather
//      than Anthropic's `image/source` or OpenAI's `image_url`.
//    - Tool definitions wrap in `tools[].functionDeclarations[]` with
//      uppercase OpenAPI types — see `ToolSchema.geminiShape`.
//    - `tool_choice` equivalent: `toolConfig.functionCallingConfig.mode = "ANY"`
//      to force the model to call some declared function.
//    - Tool call arguments arrive *parsed* (Gemini gives an `args`
//      object directly, unlike OpenAI's JSON-encoded string).
//    - Token usage: `usageMetadata.{promptTokenCount, candidatesTokenCount,
//      cachedContentTokenCount, thoughtsTokenCount}`. Caching is implicit
//      on 2.5+ — no client-side directive needed.
//    - 429 responses: no `Retry-After` header — exponential backoff
//      defaults are the safe play. We surface 2s for now.
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

actor GeminiClient: LLMClient {

    private static let logger = Logger(subsystem: "com.harness.app", category: "GeminiClient")

    private let keychain: any KeychainStoring
    private let session: URLSession
    private let baseURL: URL

    private(set) var tokensUsedThisRun: TokenUsage = .zero

    init(
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!
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

        guard let apiKey = try keychain.readKey(for: .google), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }

        let url = baseURL.appendingPathComponent("v1beta/models/\(request.model.rawValue):generateContent")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header-based auth is preferred over `?key=` query strings —
        // keeps secrets out of URL query logs.
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
            Self.logger.error("Gemini request failed: \(error.localizedDescription, privacy: .public)")
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
            // Gemini doesn't reliably surface a Retry-After header; let
            // the caller back off on its own cadence.
            throw LLMError.rateLimited(retryAfter: .seconds(2))
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
            throw llmError
        } catch {
            Self.logger.error("Gemini decode failed: \(error.localizedDescription, privacy: .public)")
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
        return LLMStepResponse(toolCall: toolCall, usage: parsed.usage)
    }

    // MARK: Request body

    private static func buildRequestBody(_ request: LLMStepRequest) -> Data {
        let system = assembleSystem(
            request.systemPrompt,
            persona: request.persona,
            goal: request.goal,
            pointSize: request.pointSize,
            platformContext: request.platformContext,
            deviceName: request.deviceName
        )

        var contents: [[String: Any]] = []

        // Compact history — same one-user-message-per-turn shape as the
        // other clients, just with `inlineData` parts.
        for turn in request.history {
            var parts: [[String: Any]] = []
            if let img = turn.screenshotJPEG {
                parts.append([
                    "inlineData": [
                        "mimeType": "image/jpeg",
                        "data": img.base64EncodedString()
                    ]
                ])
            }
            let toolInputString = String(data: turn.toolInputJSON, encoding: .utf8) ?? "{}"
            parts.append([
                "text": """
                Step recap:
                  observation: \(turn.observation)
                  intent: \(turn.intent)
                  tool: \(turn.toolName) \(toolInputString)
                  result: \(turn.toolResultSummary)
                """
            ])
            contents.append([
                "role": "user",
                "parts": parts
            ])
        }

        // Current turn — image + instruction text. The retry hint is
        // ferried back to the model on parse-failure retries.
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
        contents.append([
            "role": "user",
            "parts": [
                [
                    "inlineData": [
                        "mimeType": "image/jpeg",
                        "data": request.screenshotJPEG.base64EncodedString()
                    ]
                ],
                [
                    "text": currentText
                ]
            ]
        ])

        var generationConfig: [String: Any] = [
            "maxOutputTokens": request.maxOutputTokens
        ]
        if request.deterministic {
            generationConfig["temperature"] = 0
            generationConfig["topP"] = 1.0
        }

        let top: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": system]]
            ],
            "contents": contents,
            "tools": ToolSchema.geminiShape(
                ToolSchema.canonical(platform: request.platformKind)
            ),
            // Force the model to call a declared function. Without this,
            // smaller Gemini models occasionally answer in plain text,
            // which the loop's parse-retry then has to recover from.
            "toolConfig": [
                "functionCallingConfig": [
                    "mode": "ANY"
                ]
            ],
            "generationConfig": generationConfig
        ]

        return (try? JSONSerialization.data(withJSONObject: top, options: [])) ?? Data()
    }

    private static func assembleSystem(
        _ systemPrompt: String,
        persona: String,
        goal: String,
        pointSize: CGSize,
        platformContext: String,
        deviceName: String
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
        return s
    }

    // MARK: Response decoding

    private struct ParsedResponse {
        let toolCall: ToolCallSpec?
        let usage: TokenUsage
    }

    private struct ToolCallSpec {
        let name: String
        /// `args` arrives parsed; we re-encode to Data so the shared
        /// helper can run its JSON-object extraction against a uniform
        /// interface across providers.
        let argumentsData: Data
    }

    private static func decodeResponse(_ data: Data) throws -> ParsedResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed(detail: "root is not an object")
        }

        let usage: TokenUsage = {
            guard let u = root["usageMetadata"] as? [String: Any] else { return .zero }
            let prompt = (u["promptTokenCount"] as? Int) ?? 0
            let candidates = (u["candidatesTokenCount"] as? Int) ?? 0
            let cached = (u["cachedContentTokenCount"] as? Int) ?? 0
            // `thoughtsTokenCount` is already counted in candidatesTokenCount —
            // surface as telemetry only, do NOT add to outputTokens.
            let thoughts = (u["thoughtsTokenCount"] as? Int) ?? 0
            return TokenUsage(
                inputTokens: prompt,
                outputTokens: candidates,
                cacheReadInputTokens: cached,
                cacheCreationInputTokens: 0,
                thinkingTokens: thoughts
            )
        }()

        // Function calls live inside `candidates[0].content.parts[].functionCall`.
        // Just like the other clients, we throw on >1 to flag parse failures
        // back to the loop's retry path with a corrective hint.
        var calls: [ToolCallSpec] = []
        if let candidates = root["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let fnCall = part["functionCall"] as? [String: Any],
                   let name = fnCall["name"] as? String {
                    let args = fnCall["args"] ?? [String: Any]()
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    calls.append(ToolCallSpec(name: name, argumentsData: argsData))
                }
            }
        }

        if calls.count > 1 {
            let names = calls.map { $0.name }.joined(separator: ", ")
            throw LLMError.invalidToolCall(
                detail: "model emitted \(calls.count) tool calls (\(names)); expected exactly one"
            )
        }

        return ParsedResponse(toolCall: calls.first, usage: usage)
    }
}
