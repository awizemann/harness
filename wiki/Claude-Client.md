# Claude Client

The Anthropic SDK wrapper. Lives at `Harness/Services/ClaudeClient.swift` and conforms to the vendor-agnostic `LLMClient` protocol per [`../standards/07-ai-integration.md §11`](../standards/07-ai-integration.md).

Status: scaffold. Filled out as the service lands in Phase 1.

## Responsibilities

- Hold the API key (fetched from `KeychainStore`; never persisted to disk).
- Build per-step requests using prompt caching (system + persona + goal + tool schema cached; per-step screenshot + last 6 turns not cached).
- Send via the Anthropic SDK with the chosen model.
- Parse the response into a typed `LLMStepResponse` carrying one tool call.
- Track running token usage (`tokensUsedThisRun`).
- Map vendor errors to typed `ClaudeError` cases.

What it does **not** do:

- The agent loop itself (that's `AgentLoop`).
- History compaction (that's `HistoryCompactor`, owned by `AgentLoop`).
- Subprocess invocation (no shell-outs from this service).
- File I/O (just reads the API key once at init).

## Prompt caching strategy

| Segment | Cache control |
|---|---|
| System prompt | `cache_control: ephemeral` — set on the message. |
| Persona + goal | Same message as the system prompt; same cache mark. |
| Tool schema | `cache_control: ephemeral` on the tools array. |
| Per-step screenshot | No cache. |
| Recent history (last 6 turns) | No cache. |

The first call in a run pays the cache write cost; every subsequent call pays the per-step delta only.

## Error mapping

| API condition | `ClaudeError` case | Loop behavior |
|---|---|---|
| 401 | `.authenticationFailed` | Halt; offer settings. |
| 429 | `.rateLimited(retryAfter:)` | Sleep, retry once. |
| 5xx | `.serverError(status:)` | Retry once with backoff. |
| 400 malformed | `.malformedRequest` | Halt + diagnostic friction. |
| Tool-call parse fail | `.invalidToolCall` | Inject corrective user message; retry up to 2x. |
| Network timeout | `.timeout` | Retry once. |

See [`../standards/07-ai-integration.md §10`](../standards/07-ai-integration.md) for full detail.

## Determinism

`deterministicMode: Bool` toggles `temperature: 0` + `top_p: 1.0`. Used by replay tests; off by default in production.

## Cross-references

- [`../standards/07-ai-integration.md`](../standards/07-ai-integration.md) — full standard.
- [Agent-Loop](Agent-Loop.md) — the consumer of `LLMStepResponse`.
- [`../docs/PROMPTS/system-prompt.md`](../docs/PROMPTS/system-prompt.md) — the prompt this client sends.

---

_Last updated: 2026-05-03 — initial scaffolding._
