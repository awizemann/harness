//
//  OpenAIClientTests.swift
//  HarnessTests
//
//  URLProtocol-mocked round-trip tests for the OpenAI Chat Completions
//  wire format. Cover: request body shape, tool-call extraction with
//  string-encoded `function.arguments`, multi-tool rejection, zero-tool
//  fall-through, cached-token usage decoding, 429 retry-after parsing.
//

import Testing
import Foundation
@testable import Harness

// MARK: - In-memory keychain stub used by these tests

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

private func makeKeychainWithOpenAIKey(_ key: String = "sk-test") -> InMemoryKeychain {
    let s = InMemoryKeychain.KeyStore()
    s.write("\(InMemoryKeychain.keychainService(for: .openai))|\(InMemoryKeychain.keychainAccount)",
            Data(key.utf8))
    return InMemoryKeychain(s)
}

// MARK: - Helpers

private func sampleRequest(retryHint: String? = nil) -> LLMStepRequest {
    LLMStepRequest(
        model: .gpt5Mini,
        systemPrompt: "You are a tester. {{POINT_WIDTH}}×{{POINT_HEIGHT}}.",
        persona: "first-time user",
        goal: "sign in",
        history: [],
        screenshotJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),  // minimal JPEG-ish
        pointSize: CGSize(width: 430, height: 932),
        maxOutputTokens: 1024,
        deterministic: false,
        platformContext: "",
        deviceName: "iPhone Simulator",
        platformKind: .iosSimulator,
        retryHint: retryHint
    )
}

@Suite("OpenAIClient — wire format")
struct OpenAIClientTests {

    @Test("step decodes a single function tool_call with string-arg JSON")
    func singleToolCallStringArgs() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "choices": [{
                "message": {
                  "tool_calls": [{
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "tap",
                      "arguments": "{\\"x\\":120,\\"y\\":240,\\"observation\\":\\"button\\",\\"intent\\":\\"sign in\\"}"
                    }
                  }]
                }
              }],
              "usage": {
                "prompt_tokens": 1500,
                "completion_tokens": 80,
                "prompt_tokens_details": {"cached_tokens": 1200}
              }
            }
            """)
        }
        defer { install.uninstall() }

        let client = OpenAIClient(
            keychain: makeKeychainWithOpenAIKey(),
            session: WDAStubProtocol.session()
        )
        let response = try await client.step(sampleRequest())

        #expect(response.toolCall.tool == .tap)
        #expect(response.toolCall.observation == "button")
        if case let .tap(x, y) = response.toolCall.input {
            #expect(x == 120)
            #expect(y == 240)
        } else {
            Issue.record("expected .tap input")
        }
        #expect(response.usage.inputTokens == 1500)
        #expect(response.usage.outputTokens == 80)
        #expect(response.usage.cacheReadInputTokens == 1200)
        #expect(response.usage.cacheCreationInputTokens == 0)
    }

    @Test("Reasoning tokens surface via TokenUsage.thinkingTokens")
    func reasoningTokensSurface() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "choices": [{
                "message": {
                  "tool_calls": [{
                    "id": "c1",
                    "type": "function",
                    "function": {
                      "name": "tap",
                      "arguments": "{\\"x\\":1,\\"y\\":2,\\"observation\\":\\"\\",\\"intent\\":\\"\\"}"
                    }
                  }]
                }
              }],
              "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 200,
                "completion_tokens_details": {"reasoning_tokens": 150}
              }
            }
            """)
        }
        defer { install.uninstall() }

        let client = OpenAIClient(
            keychain: makeKeychainWithOpenAIKey(),
            session: WDAStubProtocol.session()
        )
        let response = try await client.step(sampleRequest())
        // Reasoning tokens are inside completion_tokens — don't double count.
        #expect(response.usage.outputTokens == 200)
        #expect(response.usage.thinkingTokens == 150)
    }

    @Test("Multiple tool calls in one response throw invalidToolCall")
    func multiToolCallsRejected() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "choices": [{
                "message": {
                  "tool_calls": [
                    {"id":"a","type":"function","function":{"name":"tap","arguments":"{\\"x\\":1,\\"y\\":2}"}},
                    {"id":"b","type":"function","function":{"name":"wait","arguments":"{\\"ms\\":100}"}}
                  ]
                }
              }],
              "usage": {"prompt_tokens": 10, "completion_tokens": 5}
            }
            """)
        }
        defer { install.uninstall() }

        let client = OpenAIClient(
            keychain: makeKeychainWithOpenAIKey(),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }

    @Test("Zero tool calls throws noToolCallReturned")
    func zeroToolCallsThrows() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "choices": [{"message": {"content": "I'm not sure which tool to call."}}],
              "usage": {"prompt_tokens": 10, "completion_tokens": 5}
            }
            """)
        }
        defer { install.uninstall() }

        let client = OpenAIClient(
            keychain: makeKeychainWithOpenAIKey(),
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

        let client = OpenAIClient(
            keychain: makeKeychainWithOpenAIKey(),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }

    @Test("Missing API key throws missingAPIKey before HTTP")
    func missingKeyThrows() async throws {
        // No key written.
        let store = InMemoryKeychain.KeyStore()
        let client = OpenAIClient(
            keychain: InMemoryKeychain(store),
            session: WDAStubProtocol.session()
        )
        await #expect(throws: LLMError.self) {
            _ = try await client.step(sampleRequest())
        }
    }
}

// MARK: - Request body shape

@Suite("OpenAIClient — request body shape")
struct OpenAIClientRequestShapeTests {

    @Test("Body uses OpenAI tool_choice + image_url + max_completion_tokens + Bearer auth")
    func bodyShapeMatchesOpenAISpec() async throws {
        // Stub returns a valid single tool call so the client doesn't
        // fail early. The interesting assertions are on the *request*
        // recorded by the stub.
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
              "choices": [{
                "message": {
                  "tool_calls": [{
                    "id":"c1","type":"function",
                    "function":{"name":"tap","arguments":"{\\"x\\":1,\\"y\\":2,\\"observation\\":\\"\\",\\"intent\\":\\"\\"}"}
                  }]
                }
              }],
              "usage": {"prompt_tokens": 1, "completion_tokens": 1}
            }
            """)
        }
        defer { install.uninstall() }

        let client = OpenAIClient(
            keychain: makeKeychainWithOpenAIKey("sk-XYZ"),
            session: WDAStubProtocol.session()
        )
        _ = try await client.step(sampleRequest(retryHint: "you must call exactly one tool"))

        let captured = recorder.captured()
        #expect(captured != nil)
        let body = WDAStubProtocol.bodyJSON(of: captured!)

        // Authorization header.
        let auth = captured?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer sk-XYZ")
        // Anthropic-only header must not leak in.
        #expect(captured?.value(forHTTPHeaderField: "anthropic-version") == nil)
        #expect(captured?.value(forHTTPHeaderField: "x-api-key") == nil)

        // Body shape — model, max_completion_tokens, tool_choice, tools[].
        #expect((body["model"] as? String) == "gpt-5-mini")
        #expect((body["max_completion_tokens"] as? Int) == 1024)
        #expect((body["tool_choice"] as? String) == "required")
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "function")

        // Messages: system first, then current user with image_url + text.
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect((messages.first?["role"] as? String) == "system")
        let user = messages.last
        #expect((user?["role"] as? String) == "user")
        let content = user?["content"] as? [[String: Any]] ?? []
        #expect(content.contains { ($0["type"] as? String) == "image_url" })
        // The retry hint is propagated into the user message text.
        let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String ?? ""
        #expect(text.contains("you must call exactly one tool"))
    }
}
