# Claude Client

The Anthropic implementation of the vendor-agnostic `LLMClient` protocol. Lives at `Harness/Services/ClaudeClient.swift`.

Per [`../standards/07-ai-integration.md`](https://github.com/awizemann/harness/blob/main/standards/07-ai-integration.md). 0.2 introduced sibling clients for OpenAI and Google — see [Core-Services](Core-Services). The shared decode (canonical-tool-name → typed `ToolCall`) lives in `LLMShared`; the per-provider tool-schema projections live on `ToolSchema` (`anthropicShape`, `openAIShape`, `geminiShape`).

## Responsibilities

- Hold the API key (fetched from `KeychainStore.readKey(for: .anthropic)`; never persisted to disk).
- Build per-step requests using prompt caching (system + persona + goal + tool schema cached; per-step screenshot + last 6 turns not cached).
- POST to `https://api.anthropic.com/v1/messages` with the chosen model.
- Parse the response into a typed `LLMStepResponse` carrying one tool call.
- Reject responses with multiple tool-use blocks (throws `LLMError.invalidToolCall` so the loop's parse-retry path recovers with a corrective hint instead of silently dropping the rest).
- Track running token usage (`tokensUsedThisRun`).
- Map vendor errors to typed `LLMError` cases (shared with the OpenAI / Gemini clients).

What it does **not** do:

- The agent loop itself (that's `AgentLoop`).
- History compaction (that's `HistoryCompactor`, owned by `AgentLoop`).
- Tool-name → `ToolCall` decoding (that's `LLMShared.toolCall(name:inputData:)` — shared across all clients).
- Tool-schema → wire-format projection (that's `ToolSchema.anthropicShape(_:cacheLast:)`).
- Subprocess invocation (no shell-outs from this service).
- File I/O (just reads the API key once at init).

## Prompt caching strategy

| Segment | Cache control |
|---|---|
| System prompt | `cache_control: ephemeral` — system block. |
| Persona + goal | Substituted into the system prompt template; cached with it. |
| Tool schema | `cache_control: ephemeral` on the last tool definition (Anthropic supports up to 4 breakpoints; we use 2). |
| Per-step screenshot | No cache. |
| Recent history (last 6 turns) | No cache. |

The first call in a run pays the cache write cost; every subsequent call pays the per-step delta only.

OpenAI prompt caching is **automatic** at ≥1024 tokens (50% off). Gemini 2.5+ uses **implicit caching** (90% off). Neither needs per-call directives — see the sibling client pages for details.

## Error mapping

`LLMError` is shared across every `LLMClient` impl. The Anthropic-specific mappings:

| API condition | `LLMError` case | Loop behavior |
|---|---|---|
| 401 / 403 | `.authenticationFailed` | Halt; offer settings. |
| 429 | `.rateLimited(retryAfter:)` | Sleep per `Retry-After`, retry once. |
| 5xx | `.serverError(status:)` | Retry once with backoff. |
| 400 malformed | `.malformedRequest(detail:)` | Halt + diagnostic friction. |
| Multiple `tool_use` blocks | `.invalidToolCall(detail:)` | Parse-retry path with corrective hint. |
| Zero tool calls returned | `.noToolCallReturned` | Parse-retry path with corrective hint. |
| Tool-call parse fail | `.invalidToolCall(detail:)` | Parse-retry path; up to 2 retries. |
| Network timeout | `.timeout` | Retry once. |

The retry path passes the prior parse-failure detail back to the model via `LLMStepRequest.retryHint` so the next call sees what went wrong — small models loop on the same mistake without it. See [Agent-Loop](Agent-Loop) for the loop side of this contract.

See [`../standards/07-ai-integration.md`](https://github.com/awizemann/harness/blob/main/standards/07-ai-integration.md) for full detail.

## Determinism

`LLMStepRequest.deterministic: Bool` toggles `temperature: 0` + `top_p: 1.0`. Used by replay tests; off by default in production.

## Cross-references

- [`../standards/07-ai-integration.md`](https://github.com/awizemann/harness/blob/main/standards/07-ai-integration.md) — full standard.
- [Agent-Loop](Agent-Loop) — the consumer of `LLMStepResponse`.
- [Core-Services](Core-Services) — sibling LLM clients (`OpenAIClient`, `GeminiClient`) and the factory.
- [`../docs/PROMPTS/system-prompt.md`](https://github.com/awizemann/harness/blob/main/docs/PROMPTS/system-prompt.md) — the prompt this client sends.

---

_Last updated 2026-05-06 — 0.2.0_
