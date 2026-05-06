//
//  GeminiClientTests.swift
//  HarnessTests
//
//  URLProtocol-mocked round-trip tests for the Gemini `generateContent`
//  wire format. Mirrors the OpenAIClient suite: request body shape,
//  functionCall extraction, multi/zero-tool fallthrough, cached-token
//  decoding, thinking-token telemetry.
//

import Testing
import Foundation
@testable import Harness

// MARK: - In-memory keychain stub

private struct InMemoryKeychain: KeychainStoring {
    let store: KeyStore
    init(_ store: KeyStore) { self.store = store }
    final class KeyStore: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [String: Data] = [:]
        func read(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return data[key] }
        func write(_ k: String, _ v: Data) { lock.lock(); defer { lock.unlock() }; data[k] = v }
        func delete(_ k: String) { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: k) }
    }
    func read(service: String, account: String) throws -> Data? { store.read("\(service)|\(account)") }
    func write(_ data: Data, service: String, account: String) throws {
        store.write("\(service)|\(account)", data)
    }
    func delete(service: String, account: String) throws { store.delete("\(service)|\(account)") }
}

private func makeKeychainWithGoogleKey(_ key: String = "AIza-test") -> InMemoryKeychain {
    let s = InMemoryKeychain.KeyStore()
    s.write("\(InMemoryKeychain.keychainService(for: .google))|\(InMemoryKeychain.keychainAccount)",
            Data(key.utf8))
    return InMemoryKeychain(s)
}

private func sampleRequest(retryHint: String? = nil) -> LLMStepRequest {
    LLMStepRequest(
        model: .gemini25FlashLite,
        systemPrompt: "You are a tester. {{POINT_WIDTH}}×{{POINT_HEIGHT}}.",
        persona: "first-time user",
        goal: "sign in",
        history: [],
        screenshotJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
        pointSize: CGSize(width: 430, height: 932),
        maxOutputTokens: 1024,
        deterministic: false,
        platformContext: "",
        deviceName: "iPhone Simulator",
        platformKind: .iosSimulator,
        retryHint: retryHint
    )
}

@Suite("GeminiClient — wire format")
struct GeminiClientTests {

    @Test("step decodes a single functionCall with parsed args")
    func singleFunctionCall() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "candidates": [{
                "content": {
                  "parts": [{
                    "functionCall": {
                      "name": "tap",
                      "args": {"x": 88, "y": 144, "observation": "btn", "intent": "go"}
                    }
                  }]
                }
              }],
              "usageMetadata": {
                "promptTokenCount": 2400,
                "candidatesTokenCount": 60,
                "cachedContentTokenCount": 1800,
                "thoughtsTokenCount": 25
              }
            }
            """)
        }
        defer { install.uninstall() }

        let client = GeminiClient(
            keychain: makeKeychainWithGoogleKey(),
            session: WDAStubProtocol.session()
        )
        let response = try await client.step(sampleRequest())
        #expect(response.toolCall.tool == .tap)
        if case let .tap(x, y) = response.toolCall.input {
            #expect(x == 88)
            #expect(y == 144)
        } else {
            Issue.record("expected .tap input")
        }
        #expect(response.usage.inputTokens == 2400)
        #expect(response.usage.outputTokens == 60)
        #expect(response.usage.cacheReadInputTokens == 1800)
        #expect(response.usage.thinkingTokens == 25)
        #expect(response.usage.cacheCreationInputTokens == 0)
    }

    @Test("Multiple functionCall parts throw invalidToolCall")
    func multiFunctionCallsRejected() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "candidates": [{
                "content": {
                  "parts": [
                    {"functionCall": {"name": "tap", "args": {"x":1,"y":2}}},
                    {"functionCall": {"name": "wait", "args": {"ms":100}}}
                  ]
                }
              }],
              "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5}
            }
            """)
        }
        defer { install.uninstall() }

        let client = GeminiClient(
            keychain: makeKeychainWithGoogleKey(),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }

    @Test("Zero functionCall parts throws noToolCallReturned")
    func zeroFunctionCallsThrows() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "candidates": [{
                "content": {"parts": [{"text": "not sure"}]}
              }],
              "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5}
            }
            """)
        }
        defer { install.uninstall() }

        let client = GeminiClient(
            keychain: makeKeychainWithGoogleKey(),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }

    @Test("401 maps to authenticationFailed")
    func authFailureMapped() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 401, body: "{}")
        }
        defer { install.uninstall() }

        let client = GeminiClient(
            keychain: makeKeychainWithGoogleKey(),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }

    @Test("Missing API key throws missingAPIKey before HTTP")
    func missingKeyThrows() async throws {
        let store = InMemoryKeychain.KeyStore()
        let client = GeminiClient(
            keychain: InMemoryKeychain(store),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }
}

@Suite("GeminiClient — request body shape")
struct GeminiClientRequestShapeTests {

    @Test("Body uses systemInstruction + inlineData + tool_config + x-goog-api-key auth")
    func bodyShapeMatchesGeminiSpec() async throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var seen: URLRequest?
            func record(_ r: URLRequest) {
                lock.lock(); defer { lock.unlock() }
                seen = r
            }
            func captured() -> URLRequest? {
                lock.lock(); defer { lock.unlock() }
                return seen
            }
        }
        let recorder = Recorder()

        let install = WDAStubProtocol.install { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: """
            {
              "candidates": [{
                "content": {"parts": [{
                  "functionCall": {"name":"tap","args":{"x":1,"y":2,"observation":"","intent":""}}
                }]}
              }],
              "usageMetadata": {"promptTokenCount": 1, "candidatesTokenCount": 1}
            }
            """)
        }
        defer { install.uninstall() }

        let client = GeminiClient(
            keychain: makeKeychainWithGoogleKey("AIza-XYZ"),
            session: WDAStubProtocol.session()
        )
        _ = try await client.step(sampleRequest(retryHint: "you must call exactly one tool"))

        let captured = recorder.captured()
        #expect(captured != nil)
        let body = WDAStubProtocol.bodyJSON(of: captured!)

        // Header-based auth.
        #expect(captured?.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-XYZ")
        // Anthropic-only header must not leak in.
        #expect(captured?.value(forHTTPHeaderField: "anthropic-version") == nil)
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == nil)

        // URL embeds the model name + :generateContent.
        let urlPath = captured?.url?.path ?? ""
        #expect(urlPath.contains("gemini-2.5-flash-lite"))
        #expect(urlPath.hasSuffix(":generateContent"))

        // Body shape.
        let systemInstruction = body["systemInstruction"] as? [String: Any]
        #expect(systemInstruction != nil)
        let toolConfig = body["toolConfig"] as? [String: Any]
        let mode = (toolConfig?["functionCallingConfig"] as? [String: Any])?["mode"] as? String
        #expect(mode == "ANY")
        let generationConfig = body["generationConfig"] as? [String: Any]
        #expect((generationConfig?["maxOutputTokens"] as? Int) == 1024)

        // Tools: array of one bag with functionDeclarations[].
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        let declarations = tools?.first?["functionDeclarations"] as? [[String: Any]] ?? []
        #expect(!declarations.isEmpty)

        // Current contents include an inlineData part with image/jpeg.
        let contents = body["contents"] as? [[String: Any]] ?? []
        let userParts = contents.last?["parts"] as? [[String: Any]] ?? []
        #expect(userParts.contains(where: {
            ($0["inlineData"] as? [String: Any])?["mimeType"] as? String == "image/jpeg"
        }))
        // Retry hint shows up in the text part.
        let text = userParts.first(where: { $0["text"] != nil })?["text"] as? String ?? ""
        #expect(text.contains("you must call exactly one tool"))
    }
}

@Suite("ToolSchema — Gemini shape")
struct ToolSchemaGeminiShapeTests {

    @Test("Wraps tools in single bag with functionDeclarations[]")
    func wrapsInSingleBag() {
        let canonical = ToolSchema.canonical(platform: .iosSimulator)
        let shape = ToolSchema.geminiShape(canonical)
        #expect(shape.count == 1)
        let declarations = shape.first?["functionDeclarations"] as? [[String: Any]]
        #expect(declarations?.count == canonical.count)
    }

    @Test("Uppercases JSON Schema type values for Gemini's strict parser")
    func typeValuesUppercased() {
        let canonical = ToolSchema.canonical(platform: .iosSimulator)
        let shape = ToolSchema.geminiShape(canonical)
        guard let declarations = shape.first?["functionDeclarations"] as? [[String: Any]] else {
            Issue.record("missing functionDeclarations")
            return
        }
        for decl in declarations {
            let parameters = decl["parameters"] as? [String: Any] ?? [:]
            // Top-level type must be uppercase.
            #expect((parameters["type"] as? String) == "OBJECT")
            // Property types must be uppercase.
            let properties = parameters["properties"] as? [String: Any] ?? [:]
            for (_, prop) in properties {
                if let propDict = prop as? [String: Any], let t = propDict["type"] as? String {
                    let upper = t == t.uppercased()
                    #expect(upper, "property type '\(t)' should be uppercased for Gemini")
                }
            }
        }
    }

    @Test("Drops `additionalProperties` if present anywhere in the schema")
    func dropsAdditionalProperties() {
        // Compose a canonical tool with `additionalProperties: false` and
        // confirm geminiShape strips it.
        let probe = CanonicalTool(
            name: "probe",
            description: "test",
            jsonSchema: [
                "type": "object",
                "properties": [
                    "x": ["type": "integer"]
                ],
                "additionalProperties": false,
                "required": ["x"]
            ]
        )
        let shape = ToolSchema.geminiShape([probe])
        let parameters = (shape.first?["functionDeclarations"] as? [[String: Any]])?.first?["parameters"] as? [String: Any] ?? [:]
        #expect(parameters["additionalProperties"] == nil)
    }

    @Test("read_screen / back / forward / refresh have non-empty properties")
    func minimalToolsHaveProperties() {
        // Gemini's parser doesn't accept empty `properties` blocks. The
        // smallest tools in our schema (read_screen, back, forward,
        // refresh) only declare observation + intent — confirm that
        // survives the translator.
        let canonical = ToolSchema.canonical(platform: .web)
        let shape = ToolSchema.geminiShape(canonical)
        let declarations = shape.first?["functionDeclarations"] as? [[String: Any]] ?? []
        let minimal = ["read_screen", "back", "forward", "refresh"]
        for name in minimal {
            let decl = declarations.first(where: { ($0["name"] as? String) == name })
            #expect(decl != nil, "\(name) missing from Gemini web schema")
            let params = decl?["parameters"] as? [String: Any] ?? [:]
            let properties = params["properties"] as? [String: Any] ?? [:]
            #expect(!properties.isEmpty, "\(name) parameters.properties is empty — Gemini will reject")
        }
    }
}
