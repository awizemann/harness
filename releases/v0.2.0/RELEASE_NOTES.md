# Harness 0.2.0 — Multi-provider LLM, configurable budgets, persistent defaults

The 0.1 release shipped the platform plumbing (iOS Simulator, macOS apps, web) wired to a single Anthropic-only model path. 0.2 cracks that path open: **seven supported models across three providers**, with cost rails, persistence, and unlimited-step support so the agent loop can run as long as the goal needs.

## Highlights

### Multi-provider LLM support

Pick any of three providers in Settings, then a model from that provider. Compose Run can override per-run.

| Provider | Models | Notes |
|---|---|---|
| **Anthropic** | Opus 4.7, Sonnet 4.6, **Haiku 4.5** *(new)* | Same `cache_control` ephemeral caching as 0.1 |
| **OpenAI** | **GPT-5 Mini, GPT-4.1 Nano** *(new)* | Automatic prompt caching at ≥1024 tokens (50% off) |
| **Google** | **Gemini 2.5 Flash, Gemini 2.5 Flash Lite** *(new)* | Implicit caching on 2.5+ models (90% off) |

Each provider gets its own Keychain entry (`com.harness.anthropic`, `com.harness.openai`, `com.harness.google`). Add keys in Settings; the per-provider status indicator confirms what's wired up.

### Per-model token budgets

The legacy `model == .opus47 ? 250_000 : 1_000_000` ternary is gone. Every model has a justified default and a hard ceiling:

| Model | Default | Max |
|---|---:|---:|
| Opus 4.7 | 250k | 1M |
| Sonnet 4.6 | 1M | 3M |
| Haiku 4.5 | 2M | 10M |
| GPT-5 Mini, GPT-4.1 Nano | 2M | 10M |
| Gemini 2.5 Flash, Flash Lite | 2M | 10M |

Override globally in Settings (applies to every run regardless of model) or per-run on Compose Run's Advanced section. The resolved value clamps to the active model's max so a 5M override on a cheap model can't follow you when you switch to Opus mid-form.

### Unlimited steps

Toggle in Settings, Compose Run Advanced, or any Application's defaults. The token budget + cycle detector remain the safety rails — unlimited steps is not unlimited cost.

### Persistent defaults

Settings now actually persist across launches. In 0.1, only the active Application id was saved; everything else (default model, mode, step budget, simulator visibility) reset every launch. 0.2 saves all of them via an extended `PersistedSettings` structure (legacy `settings.json` files decode cleanly).

### Real screenshot thumbnails in the step feed

The step feed's right column previously showed a static gradient placeholder. Now it renders the captured screenshot for each step, sized aspect-aware so portrait iOS shots and landscape macOS / web shots both look right.

## Loop hardening

Cheaper models (GPT-4.1 Nano, Gemini Flash Lite, sometimes Haiku) misbehave more than Opus did. Three changes keep the loop resilient:

- **Multi-tool responses** — a model emitting >1 tool call now throws `invalidToolCall` instead of silently dropping the rest.
- **Zero-tool responses** — a model punting to plain text instead of calling a tool now goes through the parse-retry path with a corrective hint, instead of failing the run.
- **Retry-detail propagation** — on retry, the prior parse error is prepended to the user message so the model sees what went wrong. The previous loop retried blind and small models would loop on the same mistake until the cap.

## Architecture

- New `LLMShared` enum centralizes the canonical-tool-name → typed `ToolCall` decode used by every client (Anthropic / OpenAI / Gemini).
- `ToolSchema` refactored to `CanonicalTool` + per-provider shape translators (`anthropicShape`, `openAIShape`, `geminiShape`). The Gemini translator uppercases JSON Schema types and strips `additionalProperties` so the strict OpenAPI parser accepts our schemas.
- `LLMClientFactory.client(for:keychain:)` dispatches per `request.model.provider`. Each run gets a fresh client so token-usage accounting and the cycle-detector window reset correctly.
- `ClaudeError` renamed to `LLMError` (provider-neutral messages). Existing call sites updated; no deprecation alias.
- `LLMStepRequest.platformKind` is now plumbed through, so each client picks the right canonical tool set per platform — fixes a latent bug where macOS / web runs always advertised the iOS tool set.
- `TokenUsage.thinkingTokens` (telemetry) — surfaces reasoning-token counts from GPT-5 / Gemini 2.5 / extended-thinking Claude calls without double-counting in cost math.

## Tests

218 unit tests passing (was 175 in 0.1). New / extended suites:

- `ToolSchemaShapesTests` — Anthropic + OpenAI + Gemini shape translators
- `LLMSharedToolCallTests` — canonical decode coverage
- `OpenAIClientTests` + `OpenAIClientRequestShapeTests` — wire-format round trip
- `GeminiClientTests` + `GeminiClientRequestShapeTests` + `ToolSchemaGeminiShapeTests` — wire-format + OpenAPI gotchas
- `AgentLoopRetryHintTests` — parse-failure detail propagation
- `RunCoordinatorReplayTests.unlimitedStepBudgetSkipsShortCircuit` — drives 50 steps with unlimited budget
- `PersistedSettingsTests` — round-trip + legacy-file + nil-roundtrip
- `AgentModelTokenBudgetTests` — per-model lookup sanity, resolution, and clamping

## Known limits / scoped out

- **Per-Application token budget** — `defaultStepBudget` exists at the per-Application level (in `Application` SwiftData `@Model`), but `defaultTokenBudget` doesn't yet. Adding it requires a SwiftData V4→V5 migration; deferred to a future release. Settings + per-run overrides cover most use cases in the meantime.
- **Web is still WebKit-only.** Chrome / CDP support remains on the roadmap.
- **macOS still needs Screen Recording permission.** First run prompts; subsequent runs are silent.

## Standards updates

- `standards/07-ai-integration.md §7` — token-budget resolution chain + per-model table
- `standards/13-agent-loop.md §3` — `stepBudget == 0` sentinel for unlimited
- `standards/14-run-logging-format.md` — clarified `stepBudget` and `tokenBudget` semantics

## Compatibility

- macOS 14+
- Apple Silicon (universal)
- Notarized + signed with Developer ID
- Existing 0.1 run records, Applications, Personas, and Action chains load unchanged. Existing `settings.json` decodes cleanly (the new fields default to nil and AppState falls back to its property initializers — Settings re-saves them on first edit).
