//
//  OllamaClientTests.swift
//  HarnessTests
//
//  URLProtocol-mocked round-trip tests for Ollama's native `/api/chat`
//  wire format. Focus on the bits that differ from `OpenAIClient`:
//    - `options.num_ctx` is sent in every body (load-bearing for
//      avoiding the OpenAI-compat truncation bug)
//    - `keep_alive` is set so the model stays warm between runs
//    - No `Authorization` header (Ollama doesn't authenticate)
//    - Tool-call `arguments` arrive as an OBJECT (not a JSON string
//      like OpenAI); also tolerant of the string form for resilience.
//    - Request URL targets `/api/chat`, not `/v1/chat/completions`.
//

import Testing
import Foundation
@testable import Harness

@Suite("OllamaClient — wire format")
struct OllamaClientTests {

    /// Minimal request fixture; same shape as the OpenAIClient tests.
    private func sampleRequest(retryHint: String? = nil) -> LLMStepRequest {
        LLMStepRequest(
            model: .qwen3VL8B,
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

    @Test("Request body sets options.num_ctx, keep_alive, stream=false; hits /api/chat; no Authorization")
    func requestShape() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: URLRequest?
            func record(_ r: URLRequest) { lock.lock(); defer { lock.unlock() }; seen = r }
            func captured() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let recorder = Recorder()

        let install = WDAStubProtocol.install { request in
            recorder.record(request)
            return WDAStubProtocol.Response(status: 200, body: """
            {
              "model": "qwen3-vl:8b",
              "message": {
                "role": "assistant",
                "tool_calls": [{
                  "function": {
                    "name": "tap",
                    "arguments": {"x": 1, "y": 2, "observation": "", "intent": ""}
                  }
                }]
              },
              "prompt_eval_count": 100,
              "eval_count": 20,
              "done": true
            }
            """)
        }
        defer { install.uninstall() }

        let client = OllamaClient(
            session: WDAStubProtocol.session(),
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        _ = try await client.step(sampleRequest())

        let captured = recorder.captured()
        #expect(captured != nil)
        // Hits /api/chat, NOT /v1/chat/completions.
        #expect(captured?.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        // Ollama doesn't authenticate. No Authorization header.
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == nil)

        // Body asserts.
        let body = WDAStubProtocol.bodyJSON(of: captured!)
        #expect((body["model"] as? String) == "qwen3-vl:8b")
        #expect((body["stream"] as? Bool) == false)
        // keep_alive keeps the model resident in RAM between requests.
        #expect((body["keep_alive"] as? String) == "10m")

        // options.num_ctx = 16384 is THE reason this client exists —
        // it's the field Ollama's OpenAI-compat endpoint silently drops
        // but the native API honours. If this assertion fails, the
        // local provider is back to a 4096-token squeeze.
        let options = body["options"] as? [String: Any] ?? [:]
        #expect((options["num_ctx"] as? Int) == 16384)
        #expect((options["num_predict"] as? Int) == 1024)

        // Tools schema — OpenAI shape, accepted by Ollama natively.
        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(!tools.isEmpty)
        #expect(tools.first?["type"] as? String == "function")

        // Messages: system first, then user with the current screenshot.
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect((messages.first?["role"] as? String) == "system")
        let user = messages.last
        #expect((user?["role"] as? String) == "user")
        // Image lives in `images` array (Ollama-native), NOT as a
        // content block with a data-URL prefix.
        let images = user?["images"] as? [String] ?? []
        #expect(images.count == 1)
        #expect(!images[0].isEmpty)
    }

    @Test("Decodes a single tool_call with object arguments (Ollama-native shape)")
    func decodeToolCallObjectArgs() async throws {
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "model": "qwen3-vl:8b",
              "message": {
                "role": "assistant",
                "tool_calls": [{
                  "function": {
                    "name": "tap",
                    "arguments": {
                      "x": 120,
                      "y": 240,
                      "observation": "button",
                      "intent": "sign in"
                    }
                  }
                }]
              },
              "prompt_eval_count": 100,
              "eval_count": 20,
              "done": true
            }
            """)
        }
        defer { install.uninstall() }

        let client = OllamaClient(session: WDAStubProtocol.session())
        let response = try await client.step(sampleRequest())

        if case let .tap(x, y) = response.toolCall.input {
            #expect(x == 120)
            #expect(y == 240)
        } else {
            Issue.record("Expected .tap input, got \(response.toolCall.input)")
        }
        #expect(response.toolCall.observation == "button")
        #expect(response.toolCall.intent == "sign in")
        // Token usage flows through.
        #expect(response.usage.inputTokens == 100)
        #expect(response.usage.outputTokens == 20)
    }

    @Test("Decodes a tool_call when arguments come back as a JSON string (defensive)")
    func decodeToolCallStringArgs() async throws {
        // Some Ollama versions / model-side templates serialize
        // arguments as a string instead of an object (the
        // OpenAI-compat behaviour leaking through). The client
        // tolerates both shapes so we don't fail just because of
        // upstream serialization variance.
        let install = WDAStubProtocol.install { _ in
            WDAStubProtocol.Response(status: 200, body: """
            {
              "model": "qwen3-vl:8b",
              "message": {
                "role": "assistant",
                "tool_calls": [{
                  "function": {
                    "name": "tap",
                    "arguments": "{\\"x\\":7,\\"y\\":8,\\"observation\\":\\"\\",\\"intent\\":\\"\\"}"
                  }
                }]
              },
              "prompt_eval_count": 50,
              "eval_count": 5,
              "done": true
            }
            """)
        }
        defer { install.uninstall() }

        let client = OllamaClient(session: WDAStubProtocol.session())
        let response = try await client.step(sampleRequest())

        if case let .tap(x, y) = response.toolCall.input {
            #expect(x == 7)
            #expect(y == 8)
        } else {
            Issue.record("Expected .tap input, got \(response.toolCall.input)")
        }
    }
}
