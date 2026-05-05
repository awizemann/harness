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
//    - Errors mapped to typed `ClaudeError` cases
//    - Token usage tracked per run
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Errors

enum ClaudeError: Error, Sendable, LocalizedError {
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
            return "Anthropic API authentication failed. Check the key in Settings."
        case .rateLimited(let retry):
            return "Anthropic rate-limited the request. Retry after \(retry)."
        case .serverError(let s):
            return "Anthropic server error \(s). Try again in a moment."
        case .malformedRequest(let d):
            return "The request to Anthropic was malformed.\n\(d)"
        case .invalidToolCall(let d):
            return "Anthropic returned a tool call we couldn't parse.\n\(d)"
        case .timeout:
            return "Request to Anthropic timed out."
        case .missingAPIKey:
            return "No Anthropic API key in Keychain. Add one in Settings."
        case .decodingFailed(let d):
            return "Could not decode Anthropic's response.\n\(d)"
        case .noToolCallReturned:
            return "Anthropic responded without a tool call. The agent loop expects exactly one per turn."
        case .unknownTool(let n):
            return "Anthropic tried to call an unknown tool: '\(n)'."
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
        deviceName: String = "iPhone Simulator"
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
    let usage: TokenUsage
}

struct TokenUsage: Sendable, Hashable, Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int

    static let zero = TokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheCreationInputTokens: 0
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
            throw ClaudeError.missingAPIKey
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
            throw ClaudeError.timeout
        } catch {
            Self.logger.error("Claude request failed: \(error.localizedDescription, privacy: .public)")
            throw ClaudeError.serverError(status: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.serverError(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ClaudeError.authenticationFailed
        case 429:
            let retry = Self.parseRetryAfter(headers: http.allHeaderFields)
            throw ClaudeError.rateLimited(retryAfter: retry)
        case 400:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.malformedRequest(detail: body)
        case 500...599:
            throw ClaudeError.serverError(status: http.statusCode)
        default:
            throw ClaudeError.serverError(status: http.statusCode)
        }

        let parsed: ParsedResponse
        do {
            parsed = try Self.decodeResponse(data)
        } catch {
            Self.logger.error("Decode failed: \(error.localizedDescription, privacy: .public)")
            throw ClaudeError.decodingFailed(detail: error.localizedDescription)
        }

        // Update running usage.
        tokensUsedThisRun = TokenUsage(
            inputTokens: tokensUsedThisRun.inputTokens + parsed.usage.inputTokens,
            outputTokens: tokensUsedThisRun.outputTokens + parsed.usage.outputTokens,
            cacheReadInputTokens: tokensUsedThisRun.cacheReadInputTokens + parsed.usage.cacheReadInputTokens,
            cacheCreationInputTokens: tokensUsedThisRun.cacheCreationInputTokens + parsed.usage.cacheCreationInputTokens
        )

        guard let toolUse = parsed.toolUse else {
            throw ClaudeError.noToolCallReturned
        }

        let toolCall = try Self.toolCall(fromToolUse: toolUse)
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

        // Current turn: screenshot + a brief instruction to act.
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
                "text": "Current screen attached. Choose your next action by calling exactly one tool."
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
            "tools": ToolSchema.toolDefinitions(cacheControl: true)
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
        deviceName: String
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
        return s
    }

    // MARK: Response decoding

    private struct ParsedResponse {
        let toolUse: ToolUseBlock?
        let usage: TokenUsage
    }

    private struct ToolUseBlock {
        let id: String
        let name: String
        let input: Data
    }

    private static func decodeResponse(_ data: Data) throws -> ParsedResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decodingFailed(detail: "root is not an object")
        }

        let usage: TokenUsage = {
            guard let u = root["usage"] as? [String: Any] else { return .zero }
            return TokenUsage(
                inputTokens: (u["input_tokens"] as? Int) ?? 0,
                outputTokens: (u["output_tokens"] as? Int) ?? 0,
                cacheReadInputTokens: (u["cache_read_input_tokens"] as? Int) ?? 0,
                cacheCreationInputTokens: (u["cache_creation_input_tokens"] as? Int) ?? 0
            )
        }()

        // Find the first tool_use content block.
        var toolUse: ToolUseBlock?
        if let content = root["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "tool_use" {
                let id = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? ""
                let inputObj = block["input"] ?? [:]
                let inputData = (try? JSONSerialization.data(withJSONObject: inputObj, options: [])) ?? Data("{}".utf8)
                toolUse = ToolUseBlock(id: id, name: name, input: inputData)
                break
            }
        }

        return ParsedResponse(toolUse: toolUse, usage: usage)
    }

    // MARK: tool_use → ToolCall

    private static func toolCall(fromToolUse use: ToolUseBlock) throws -> ToolCall {
        guard let kind = ToolKind(rawValue: use.name) else {
            throw ClaudeError.unknownTool(use.name)
        }

        // Decode the `input` blob and extract the reasoning fields shared
        // across most tools.
        guard let input = (try? JSONSerialization.jsonObject(with: use.input)) as? [String: Any] else {
            throw ClaudeError.invalidToolCall(detail: "input is not an object")
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
        // Phase 2 — macOS extensions:
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
        // Phase 3 — web extensions:
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

    /// Anthropic occasionally returns numbers as strings if the model JSON-encodes
    /// them inconsistently. Coerce defensively.
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
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
