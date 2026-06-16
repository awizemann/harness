# Agent Loop

The mechanical detail lives in [`../standards/13-agent-loop.md`](https://github.com/awizemann/harness/blob/main/standards/13-agent-loop.md). This page is the prose walkthrough — read this for "what's happening here" intuition; read the standard for the load-bearing rules.

## Where it lives

| Concern | File |
|---|---|
| Per-step decision (the loop body) | `Harness/Domain/AgentLoop.swift` (`actor AgentLoop: AgentLooping`) |
| Orchestration (build/install/screenshot/log around the loop) | `Harness/Domain/RunCoordinator.swift` (`actor RunCoordinator`) |
| LLM API call | `LLMClientFactory.client(for:keychain:)` returns one of `ClaudeClient` / `OpenAIClient` / `GeminiClient` per the run's `ModelProvider`; `Tests/HarnessTests/Mocks/MockLLMClient.swift` for replay tests |
| Tool schema (model-facing contract) | `Harness/Tools/AgentTools.swift` (+ [Tool-Schema](Tool-Schema)) |
| System prompt + persona defaults + friction vocab | `docs/PROMPTS/*.md`, loaded via `Harness/Core/PromptLibrary.swift` |

## The loop, step by step

```
RunCoordinator.run(_:) → AsyncThrowingStream<RunEvent>

  ① build (XcodeBuilder)            → buildStarted, buildCompleted(.app, bundleID)
  ② boot + install + launch (sim)   → simulatorReady
  ③ loop (per step):
       a. screenshot (write step-NNN.png)        → stepStarted(step, path, url)
       b. AgentLoop.step(state:)                 → toolProposed(step, call)
       c. step mode? wait on AsyncStream         → awaitingApproval(step, call)
       d. execute tool via SimulatorDriver        → toolExecuted(step, call, result)
       e. friction (if note_friction emitted)    → frictionEmitted(event)
       f. update token usage; log step_completed → stepCompleted(step, ms, in/out)
       g. if mark_goal_done → break loop
       h. cycle detector recordPostStep(...)
          → trips? log agent_blocked friction; break loop
       i. budget short-circuits (steps, tokens)
          → trip? log agent_blocked friction; break loop
  ④ writeMeta + RunHistoryStore.markCompleted   → runCompleted(outcome)
```

## Platform scaffolding

Every platform driver layers two pieces on top of the universal loop. Same agent-facing contract; per-platform implementations:

- **Set-of-Mark badges.** Every screenshot the LLM sees has numbered green pills floating above each interactive element. The agent calls `tap_mark(id)` instead of `tap(x, y)` — coordinate-emission failure on small vision models drops out entirely. Disk PNGs stay unmarked so replay surfaces don't show scaffolding.
- **Smart settle gate.** Replaces fixed sleep timers that routinely captured pages / windows mid-render or mid-animation.

| Platform | Mark probe | Settle gate | Doc |
|---|---|---|---|
| Web | JS `querySelectorAll` walk piercing shadow roots; anchors, buttons, role=*, contenteditable, etc. | `MutationObserver` quietness, with a `childList`-mutation requirement for SPA route transitions. | [Web-Driver](Web-Driver) |
| iOS | WebDriverAgent's `/source?format=json` AX tree; actionable XCUI roles; `StaticText` rolls up into cell labels. | Screenshot dHash stability via `simctl io screenshot` polling. | [iOS-Driver](iOS-Driver) |
| macOS | `AXUIElementCopyAttributeValue` walk of the focused window; actionable AX roles; window-local point space. | Screenshot dHash stability via `CGWindowListCreateImage` polling. | [macOS-Driver](macOS-Driver) |

Together these are what make local vision models (Qwen3-VL 8B, Gemma 4 Vision, Llama 3.2 Vision) usable across all three platforms.

## The pieces in `AgentLoop`

### History compactor

`HistoryCompactor.compact(_:keepFullTurns:)` keeps the **last 6 turns full** (observation + intent + tool call + screenshot). Older turns lose their screenshots but keep the text reasoning. The strategy is documented in [`../standards/07-ai-integration.md §4`](https://github.com/awizemann/harness/blob/main/standards/07-ai-integration.md). Token-cap-driven further collapse is a follow-up if 6-full proves too expensive.

### Cycle detector

`AgentLoop.recordPostStep(...)` maintains a history of the last 3 tool calls (tool name + coordinates / text) and rejects the 4th if it's identical. Coordinates within 5 pixels and text within Levenshtein 2 are considered "identical". Thrown error type: `AgentLoopError.cycleDetected(detail)` — the loop catches it, logs an `agent_blocked` friction event, and breaks.

The detector resets on each new leg (for chain runs).

### Retry hint

When a tool-call parse fails (e.g., the model emits two `tool_use` blocks instead of one), the loop doesn't just repeat — it passes the prior error detail back to the model on the next `LLMStepRequest.retryHint: String?` field. Small models loop on the same mistake without this signal; with it, they self-correct.

### Prompt caching

The system prompt + persona + goal + tool schema are sent to the LLM once at the top of the run and reused on every step. Anthropic: explicit `cache_control: ephemeral` directives. OpenAI: automatic caching at ≥1024 tokens. Google: implicit caching on Gemini 2.5+.

See [Claude-Client](Claude-Client) for the Anthropic caching contract.

