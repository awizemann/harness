//
//  ClaudeClient.swift
//  Harness
//
//  Anthropic SDK wrapper. Phase 1 surface: single-shot `step(_:)` with image
//  input + tool use + prompt caching markers. The agent loop, history compactor,
//  cycle detector etc. live in `Harness/Domain/AgentLoop.swift` (Phase 2).
//
//  Per `standards/07-ai-integration.md`:
//    - System prompt + persona + goal + tool schema marked for caching
//    - Per-step screenshot + recent history not cached
//    - Errors mapped to typed `LLMError` cases (shared with other LLM clients)
//    - Token usage tracked per run
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Errors

enum LLMError: Error, Sendable, LocalizedError {
    case authenticationFailed
    case rateLimited(retryAfter: Duration)
    case serverError(status: Int)
    case malformedRequest(detail: String)
    case invalidToolCall(detail: String)
    case timeout
    case missingAPIKey
    case decodingFailed(detail: String)
    case noToolCallReturned
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "LLM API authentication failed. Check the API key for the selected provider in Settings."
        case .rateLimited(let retry):
            return "The LLM provider rate-limited the request. Retry after \(retry)."
        case .serverError(let s):
            return "LLM provider server error \(s). Try again in a moment."
        case .malformedRequest(let d):
            return "The request to the LLM was malformed.\n\(d)"
        case .invalidToolCall(let d):
            return "The model returned a tool call we couldn't parse.\n\(d)"
        case .timeout:
            return "Request to the LLM timed out."
        case .missingAPIKey:
            return "No API key in Keychain for the selected provider. Add one in Settings."
        case .decodingFailed(let d):
            return "Could not decode the LLM's response.\n\(d)"
        case .noToolCallReturned:
            return "The model responded without a tool call. The agent loop expects exactly one per turn."
        case .unknownTool(let n):
            return "The model tried to call an unknown tool: '\(n)'."
        }
    }
}

// MARK: - Public types

struct LLMStepRequest: Sendable {
    let model: AgentModel
    /// Always cached. Static for the run.
    let systemPrompt: String
    /// Always cached. Static for the run. Concatenated into system in
    /// `ClaudeClient.assembleSystem(_:persona:goal:)`.
    let persona: String
    /// Always cached. Static for the run.
    let goal: String
    /// Compact history (last N turns). Per `13-agent-loop.md §8`.
    let history: [LLMTurn]
    /// Current screenshot (downscaled) — sent as a base64 image content block.
    let screenshotJPEG: Data
    /// Logical screen size in points (drives the system-prompt device line).
    let pointSize: CGSize
    /// Hard cap on output tokens for this turn. 1024 fits a verbose tool call.
    let maxOutputTokens: Int
    /// Determinism toggle for replay/debug runs. False in production by default.
    let deterministic: Bool
    /// Phase 2: optional platform-specific override block prepended to the
    /// system prompt. Empty for iOS (which keeps the canonical iOS-flavoured
    /// system prompt as-is); macOS / web pass a paragraph that re-frames
    /// the model's UI metaphors.
    let platformContext: String
    /// Phase 2: substitution for `{{DEVICE_NAME}}`. iOS = "iPhone Simulator"
    /// (back-compat default); macOS = the SUT's display name; web = the
    /// browser identifier ("Embedded WebKit").
    let deviceName: String
    /// Which platform's canonical tool set to advertise to the model.
    /// Each client uses this to project the per-platform `[CanonicalTool]`
    /// onto its provider's wire format. Defaults to `.iosSimulator` so
    /// pre-multi-platform tests / call sites keep working.
    let platformKind: PlatformKind
    /// V5: text substituted into the system prompt's `{{CREDENTIALS}}`
    /// slot. Built by `PromptLibrary.credentialBlock(for:)` from the
    /// resolved binding (or "no credential staged" when nil). Empty
    /// string also works — substitutes a blank section. Always cached.
    let credentialBlock: String
    /// Retry-detail hint surfaced after a parse-failure. When non-nil,
    /// the client prepends "Your previous response was rejected: <hint>.
    /// Emit exactly one tool call." to the current-turn user message so
    /// the next attempt sees the corrective context. Cheaper models
    /// (GPT-4.1 Nano, Gemini Flash Lite) loop on the same mistake without
    /// this nudge.
    let retryHint: String?

    init(
        model: AgentModel,
        systemPrompt: String,
        persona: String,
        goal: String,
        history: [LLMTurn],
        screenshotJPEG: Data,
        pointSize: CGSize,
        maxOutputTokens: Int = 1024,
        deterministic: Bool = false,
        platformContext: String = "",
        deviceName: String = "iPhone Simulator",
        platformKind: PlatformKind = .iosSimulator,
        credentialBlock: String = "",
        retryHint: String? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.persona = persona
        self.goal = goal
        self.history = history
        self.screenshotJPEG = screenshotJPEG
        self.pointSize = pointSize
        self.maxOutputTokens = maxOutputTokens
        self.deterministic = deterministic
        self.platformContext = platformContext
        self.deviceName = deviceName
        self.platformKind = platformKind
        self.credentialBlock = credentialBlock
        self.retryHint = retryHint
    }
}

struct LLMTurn: Sendable {
    let observation: String
    let intent: String
    let toolName: String
    let toolInputJSON: Data
    /// Optional thumbnail of the screenshot at this turn. May be omitted for older turns.
    let screenshotJPEG: Data?
    let toolResultSummary: String
}

struct LLMStepResponse: Sendable {
    let toolCall: ToolCall
    /// Friction events the model emitted alongside the action tool on
    /// this same turn (per the system prompt, "exactly one tool call …
    /// optionally accompanied by one or more `note_friction` calls").
    /// Empty when the model only emitted the action. Surfaced through
    /// `AgentDecision.inlineFriction` so the orchestrator can log + emit
    /// them at the current step's index without a second round-trip.
    let inlineFriction: [(FrictionKind, String)]
    let usage: TokenUsage
}

struct TokenUsage: Sendable, Hashable, Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    /// Reasoning/thinking tokens reported separately by the provider.
    /// Telemetry-only — these are *already counted* inside `outputTokens`
    /// for both Anthropic (extended thinking) and OpenAI/Gemini (reasoning
    /// summaries). Surfaced so the run-detail UI can show "model spent
    /// X of Y output tokens thinking" without double-counting in cost math.
    let thinkingTokens: Int

    init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        thinkingTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.thinkingTokens = thinkingTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens
        case cacheReadInputTokens, cacheCreationInputTokens
        case thinkingTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        self.outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        self.cacheReadInputTokens = try c.decode(Int.self, forKey: .cacheReadInputTokens)
        self.cacheCreationInputTokens = try c.decode(Int.self, forKey: .cacheCreationInputTokens)
        // Optional in the Codable shape — historical persisted TokenUsage
        // (none on disk today, but stay safe) decodes cleanly to 0.
        self.thinkingTokens = try c.decodeIfPresent(Int.self, forKey: .thinkingTokens) ?? 0
    }

    static let zero = TokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheCreationInputTokens: 0,
        thinkingTokens: 0
    )
}

// MARK: - Protocol

protocol LLMClient: Sendable {
    func step(_ request: LLMStepRequest) async throws -> LLMStepResponse
    var tokensUsedThisRun: TokenUsage { get async }
    func reset() async
}

// MARK: - Default ClaudeClient

actor ClaudeClient: LLMClient {

    private static let logger = Logger(subsystem: "com.harness.app", category: "ClaudeClient")

    private let keychain: any KeychainStoring
    private let session: URLSession
    private let baseURL: URL
    private let apiVersion: String

    private(set) var tokensUsedThisRun: TokenUsage = .zero

    /// `endpoint` and `apiVersion` are overridable for tests. Production defaults
    /// hit `https://api.anthropic.com/v1/messages` with `anthropic-version: 2023-06-01`.
    init(
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = "2023-06-01"
    ) {
        self.keychain = keychain
        self.session = session
        self.baseURL = baseURL
        self.apiVersion = apiVersion
    }

    func reset() {
        tokensUsedThisRun = .zero
    }

    func step(_ request: LLMStepRequest) async throws -> LLMStepResponse {
        try Task.checkCancellation()

        guard let apiKey = try keychain.readAnthropicAPIKey(), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }

        let url = baseURL.appendingPathComponent("v1/messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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
            Self.logger.error("Claude request failed: \(error.localizedDescription, privacy: .public)")
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
        } catch {
            Self.logger.error("Decode failed: \(error.localizedDescription, privacy: .public)")
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

        guard let toolUse = parsed.toolUse else {
            throw LLMError.noToolCallReturned
        }

        let toolCall = try Self.toolCall(fromToolUse: toolUse)
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

        // System: array form so each block can carry cache_control.
        let systemBlocks: [[String: Any]] = [
            [
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"]
            ]
        ]

        var messages: [[String: Any]] = []

        // Compact history first. Each turn renders as a single user message
        // that quotes the model's prior observation/intent and the tool result.
        for turn in request.history {
            var content: [[String: Any]] = []
            if let img = turn.screenshotJPEG {
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": img.base64EncodedString()
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

        // Current turn: screenshot + a brief instruction to act. When the
        // loop is retrying after a parse failure, prepend the corrective
        // hint so the model sees what went wrong on the prior attempt.
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
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": request.screenshotJPEG.base64EncodedString()
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
            "max_tokens": request.maxOutputTokens,
            "system": systemBlocks,
            "messages": messages,
            "tools": ToolSchema.anthropicShape(
                ToolSchema.canonical(platform: request.platformKind),
                cacheLast: true
            )
        ]
        if request.deterministic {
            top["temperature"] = 0
            top["top_p"] = 1.0
        }

        return (try? JSONSerialization.data(withJSONObject: top, options: [])) ?? Data()
    }

    /// Concatenate system prompt + persona + goal + device line. Per
    /// `13-agent-loop.md §6` the persona goes in the system prompt, not the goal.
    private static func assembleSystem(
        _ systemPrompt: String,
        persona: String,
        goal: String,
        pointSize: CGSize,
        platformContext: String,
        deviceName: String,
        credentialBlock: String
    ) -> String {
        // Phase 2: prepend the platform-context override block when an
        // adapter provides one (macOS / web). iOS adapters return "" so
        // the canonical iOS-flavoured system prompt loads unchanged.
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
        let toolUse: ToolUseBlock?
        let inlineFriction: [(FrictionKind, String)]
        let usage: TokenUsage
    }

    private struct ToolUseBlock {
        let id: String
        let name: String
        let input: Data
    }

    private static func decodeResponse(_ data: Data) throws -> ParsedResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingFailed(detail: "root is not an object")
        }

        let usage: TokenUsage = {
            guard let u = root["usage"] as? [String: Any] else { return .zero }
            return TokenUsage(
                inputTokens: (u["input_tokens"] as? Int) ?? 0,
                outputTokens: (u["output_tokens"] as? Int) ?? 0,
                cacheReadInputTokens: (u["cache_read_input_tokens"] as? Int) ?? 0,
                cacheCreationInputTokens: (u["cache_creation_input_tokens"] as? Int) ?? 0,
                thinkingTokens: 0
            )
        }()

        // Collect every tool_use content block. Per the system prompt:
        // "exactly one tool call (the action) ... optionally accompanied
        // by one or more `note_friction` calls". So we accept ANY number
        // of `note_friction` blocks, but exactly one action block. The
        // frictions ride out via `inlineFriction` and get logged at the
        // current step's index by `RunCoordinator`.
        var blocks: [ToolUseBlock] = []
        if let content = root["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "tool_use" {
                let id = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? ""
                let inputObj = block["input"] ?? [:]
                let inputData = (try? JSONSerialization.data(withJSONObject: inputObj, options: [])) ?? Data("{}".utf8)
                blocks.append(ToolUseBlock(id: id, name: name, input: inputData))
            }
        }

        let frictionName = ToolKind.noteFriction.rawValue
        let actionBlocks = blocks.filter { $0.name != frictionName }
        let frictionBlocks = blocks.filter { $0.name == frictionName }

        if actionBlocks.count > 1 {
            let names = actionBlocks.map { $0.name }.joined(separator: ", ")
            throw LLMError.invalidToolCall(
                detail: "model emitted \(actionBlocks.count) action tool calls (\(names)); expected exactly one (note_friction may accompany it)"
            )
        }

        let inlineFriction: [(FrictionKind, String)] = frictionBlocks.compactMap { block in
            guard let dict = (try? JSONSerialization.jsonObject(with: block.input)) as? [String: Any]
            else { return nil }
            let kindRaw = (dict["kind"] as? String) ?? FrictionKind.unexpectedState.rawValue
            let kind = FrictionKind(rawValue: kindRaw) ?? .unexpectedState
            let detail = (dict["detail"] as? String) ?? ""
            return (kind, detail)
        }

        return ParsedResponse(toolUse: actionBlocks.first, inlineFriction: inlineFriction, usage: usage)
    }

    // MARK: tool_use → ToolCall

    /// Project a Claude `tool_use` block onto the typed `ToolCall` the
    /// loop expects. Per-tool decoding lives in `LLMShared` so OpenAI /
    /// Gemini clients can share the same map.
    private static func toolCall(fromToolUse use: ToolUseBlock) throws -> ToolCall {
        try LLMShared.toolCall(name: use.name, inputData: use.input)
    }

    // MARK: Headers

    private static func parseRetryAfter(headers: [AnyHashable: Any]) -> Duration {
        // `Retry-After` is in seconds (integer).
        for (key, value) in headers {
            if let k = key as? String, k.lowercased() == "retry-after" {
                if let s = value as? String, let secs = Int(s) {
                    return .seconds(min(60, max(1, secs)))
                }
                if let secs = value as? Int {
                    return .seconds(min(60, max(1, secs)))
                }
            }
        }
        return .seconds(2)
    }
}
