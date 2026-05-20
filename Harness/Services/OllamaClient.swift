//
//  OllamaClient.swift
//  Harness
//
//  `LLMClient` implementation for Ollama's native chat endpoint
//  (`POST /api/chat`). This is the canonical path for
//  `ModelProvider.local` because Ollama's OpenAI-compatible endpoint
//  silently drops the `options` field that controls `num_ctx`,
//  `num_predict`, `temperature`, and friends — confirmed empirically:
//  load logs always read `KvSize:4096` when going through `/v1/chat/
//  completions` regardless of what we put in the request body. With
//  the native API we can pass `options.num_ctx: 16384` per-request and
//  Ollama actually honours it.
//
//  Differences from `OpenAIClient` worth knowing:
//    - Images go in a separate `images` array on each user message,
//      base64-encoded raw — NOT in a content block with a `data:image/
//      jpeg;base64,...` URL prefix.
//    - Tool definitions reuse OpenAI's `{type: "function", function:
//      {...}}` shape — Ollama explicitly accepts the OpenAI function-
//      calling schema, so we share `ToolSchema.openAIShape(...)`.
//    - Tool call `arguments` arrive as a **JSON object** (not a JSON-
//      encoded string like OpenAI). We re-serialize before handing to
//      `LLMShared.toolCall(name:inputData:)`.
//    - No `choices[]` wrapper — the response has a single top-level
//      `message`.
//    - No `Authorization` header. Ollama doesn't authenticate.
//    - Token usage: `prompt_eval_count` and `eval_count`. No separate
//      cache token bucket (Ollama's cache is implicit + transparent).
//    - `keep_alive: "10m"` so the model stays in RAM between runs —
//      eliminates the ~5s reload cost on subsequent runs against the
//      same model.
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

actor OllamaClient: LLMClient {

    private static let logger = Logger(subsystem: "com.harness.app", category: "OllamaClient")

    private let session: URLSession
    private let baseURL: URL
    /// Override the `model` field sent in the request body. Used by the
    /// `.local` + `.customLocal` combo where the `AgentModel` enum's
    /// rawValue is a placeholder (`custom-local`) and the real model
    /// tag lives in `AppState.localCustomModelName`.
    private let modelNameOverride: String?

    private(set) var tokensUsedThisRun: TokenUsage = .zero

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        modelNameOverride: String? = nil
    ) {
        self.session = session
        self.baseURL = baseURL
        self.modelNameOverride = modelNameOverride
    }

    func reset() {
        tokensUsedThisRun = .zero
    }

    func step(_ request: LLMStepRequest) async throws -> LLMStepResponse {
        try Task.checkCancellation()

        let url = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Cold-start budget: ~5s model load + 60–90s input processing
        // on a fresh KV cache on M2 with Qwen3-VL 8B Q4_K_M. 600s gives
        // a comfortable ceiling without making cancel feel unreachable.
        // Subsequent warm requests typically settle under 60s.
        urlRequest.timeoutInterval = 600

        let body = Self.buildRequestBody(request, modelNameOverride: modelNameOverride)
        urlRequest.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMError.timeout
        } catch {
            Self.logger.error("Ollama request failed: \(error.localizedDescription, privacy: .public)")
            throw LLMError.serverError(status: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.serverError(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 400:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.malformedRequest(detail: bodyText)
        case 404:
            // Most likely the user hit a server that's not actually
            // Ollama (e.g. LM Studio at the same port). Surface clearly
            // so the user can re-check the URL.
            throw LLMError.malformedRequest(detail: "Ollama not detected at \(baseURL.absoluteString). If you're running LM Studio, set its URL in Settings — but note LM Studio uses the OpenAI-compatible endpoint, not Ollama's native API.")
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
            Self.logger.error("Ollama decode failed: \(error.localizedDescription, privacy: .public)")
            throw LLMError.decodingFailed(detail: error.localizedDescription)
        }

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

    private static func buildRequestBody(_ request: LLMStepRequest, modelNameOverride: String? = nil) -> Data {
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
        messages.append(["role": "system", "content": system])

        // Compact history. Ollama's `images` array sits alongside
        // `content` on each user message and takes base64 strings
        // directly (no data-URL prefix).
        for turn in request.history {
            let toolInputString = String(data: turn.toolInputJSON, encoding: .utf8) ?? "{}"
            let text = """
            Step recap:
              observation: \(turn.observation)
              intent: \(turn.intent)
              tool: \(turn.toolName) \(toolInputString)
              result: \(turn.toolResultSummary)
            """
            var msg: [String: Any] = [
                "role": "user",
                "content": text
            ]
            if let img = turn.screenshotJPEG {
                msg["images"] = [img.base64EncodedString()]
            }
            messages.append(msg)
        }

        // Current turn — screenshot + the "choose your action" text.
        // The Set-of-Mark annotation (when present) goes between the
        // call-to-action and the image so the model reads:
        //   1. What you should do (pick a tool call)
        //   2. What's actionable on the screen right now (id → label)
        //   3. The screen itself
        // For local sub-10B vision models this textual scaffolding is
        // what turns "I think id 6 is Articles" into "id 6 is labeled
        // 'Articles' so that's the right call."
        let currentText: String
        let baseInstruction = "Current screen attached. Choose your next action by calling exactly one tool."
        let annotation = request.screenshotAnnotation
        let annotated = annotation.isEmpty
            ? baseInstruction
            : "\(baseInstruction)\n\n\(annotation)"
        if let hint = request.retryHint, !hint.isEmpty {
            currentText = """
            Your previous response was rejected: \(hint)
            Emit exactly one tool call.

            \(annotated)
            """
        } else {
            currentText = annotated
        }
        messages.append([
            "role": "user",
            "content": currentText,
            "images": [request.screenshotJPEG.base64EncodedString()]
        ])

        // Options. The headline one is `num_ctx` — bumping above the
        // 4096 default lets us send the full system prompt + tool
        // schema + screenshot + history without truncation, which the
        // OpenAI-compat endpoint silently performs (`keep=4 new=4096`).
        // 16384 is comfortable for typical runs; KV-cache cost on
        // Qwen3-VL 8B is ~2.3 GiB at this size, fits on 16 GB Macs.
        var options: [String: Any] = [
            "num_ctx": 16384,
            "num_predict": request.maxOutputTokens
        ]
        if request.deterministic {
            options["temperature"] = 0
            options["top_p"] = 1.0
        }

        let top: [String: Any] = [
            "model": modelNameOverride ?? request.model.rawValue,
            "messages": messages,
            // Ollama accepts the OpenAI function-calling shape directly;
            // no per-format translation needed at this layer.
            "tools": ToolSchema.openAIShape(
                ToolSchema.canonical(platform: request.platformKind)
            ),
            "options": options,
            // Don't stream — we need the full response before continuing
            // the loop, and the additive parsing overhead of streaming
            // isn't worth it for this use case (single tool call per
            // turn, not a long-form generation).
            "stream": false,
            // Keep the model resident in RAM for 10 minutes after each
            // request — eliminates the ~5s reload cost on subsequent
            // runs against the same model without holding memory
            // forever (default is 5m, we extend slightly).
            "keep_alive": "10m"
        ]

        return (try? JSONSerialization.data(withJSONObject: top, options: [])) ?? Data()
    }

    /// Mirror of `OpenAIClient.assembleSystem` — kept duplicated for the
    /// same reason. The substitutions are tiny and lifting to a helper
    /// would only save a handful of lines while making the per-client
    /// request body harder to read.
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
        let name: String
        let argumentsData: Data
    }

    /// Decode an `/api/chat` response. Throws `LLMError.invalidToolCall`
    /// when the model returns >1 action tool call so the parse-retry
    /// path kicks in with a corrective hint — same contract as the
    /// other clients.
    private static func decodeResponse(_ data: Data) throws -> ParsedResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed(detail: "root is not an object")
        }

        // Token usage. Ollama reports `prompt_eval_count` for input and
        // `eval_count` for output. No explicit cache bucket — cache is
        // implicit + transparent in Ollama's KV management.
        let usage: TokenUsage = {
            let promptCount = (root["prompt_eval_count"] as? Int) ?? 0
            let evalCount = (root["eval_count"] as? Int) ?? 0
            return TokenUsage(
                inputTokens: promptCount,
                outputTokens: evalCount,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                thinkingTokens: 0
            )
        }()

        // Tool calls live on `message.tool_calls[]`. Each entry has
        // `function: { name, arguments }` where arguments is an
        // OBJECT (not the JSON-encoded string OpenAI returns). We
        // re-serialize to Data so `LLMShared.toolCall(name:inputData:)`
        // can consume it identically.
        var calls: [ToolCallSpec] = []
        if let message = root["message"] as? [String: Any],
           let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                // `arguments` is typically an object; some Ollama
                // versions / models occasionally return it as a string
                // (the OpenAI-compat behaviour leaking through). Handle
                // both for robustness.
                let argumentsData: Data
                if let argsObject = function["arguments"] as? [String: Any] {
                    argumentsData = (try? JSONSerialization.data(withJSONObject: argsObject)) ?? Data("{}".utf8)
                } else if let argsString = function["arguments"] as? String {
                    argumentsData = argsString.data(using: .utf8) ?? Data("{}".utf8)
                } else {
                    argumentsData = Data("{}".utf8)
                }
                calls.append(ToolCallSpec(name: name, argumentsData: argumentsData))
            }
        }

        // Split action vs note_friction; identical to the OpenAI path.
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
}
