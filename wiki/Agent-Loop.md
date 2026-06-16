# Agent Loop

The mechanical detail lives in [`../standards/13-agent-loop.md`](https://github.com/awizemann/harness/blob/main/standards/13-agent-loop.md). This page is the prose walkthrough — read this for "what's happening here" intuition; read the standard for the load-bearing rules.

## Where it lives

| Concern | File |
|---|---|
| Per-step decision (the loop body) | `Harness/Domain/AgentLoop.swift` |
| Orchestration (build/install/screenshot/log around the loop) | `Harness/Domain/RunCoordinator.swift` |
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

`AgentLoop.recordPostStep(...)` maintains a rolling window of the last 3 `(dHash(screenshot), toolCall)` pairs. When **all 3 dHashes are within Hamming-distance 5** AND **all 3 tool calls are equivalent** (same kind + coordinates within 8pt of each other for tap/swipe; structural equality for type/wait/etc.), the loop bails with `mark_goal_done(blocked, "cycle detected ...")` and an `agent_blocked` friction event.

Why dHash and not exact equality: simulator status-bar overrides remove most chrome variance, but small animations (cursor blink, list ripple) would foil exact pixel hashing. dHash is robust to that.

### Parse-failure retry

The loop catches three `LLMError` cases and retries up to 2 times:

- `.invalidToolCall(detail:)` — the response was structurally wrong (couldn't parse tool args, or the model emitted multiple tool calls when the loop expects exactly one).
- `.unknownTool(name:)` — the model called a tool we don't advertise.
- `.noToolCallReturned` — the model punted to plain text instead of calling any tool.

On retry, the prior failure detail is ferried back to the model via `LLMStepRequest.retryHint` — the next call's user message gets a `"Your previous response was rejected: <detail>. Emit exactly one tool call."` prefix. Without this, cheaper models (GPT-4.1 Nano, Gemini Flash Lite, sometimes Haiku) loop on the same mistake until the cap. After 2 retries, the loop throws `AgentLoopError.parseFailureExhausted` and the run blocks.

### Step + token budgets

- **Step budget** (default 40, range 5–200, ceiling 200; **`stepBudget == 0` means unlimited**) — exceeded → `mark_goal_done(blocked, "step budget exhausted ...")`.
- **Token budget** — resolved per-run from per-run override → `AppState.defaultTokenBudget` global override → `AgentModel.defaultTokenBudget` per-model default, then clamped to `AgentModel.maxTokenBudget`. Exceeded → `mark_goal_done(blocked, "token budget exhausted ...")`.

Both checks happen at the top of every iteration, before any work. If the loop is mid-step when it would trip, it finishes that step and bails on the next iteration's check. Unlimited steps (`stepBudget == 0`) skips only the step-budget short-circuit; the token budget + cycle detector remain the safety rails.

## Friction taxonomy

Full taxonomy in [`../docs/PROMPTS/friction-vocab.md`](https://github.com/awizemann/harness/blob/main/docs/PROMPTS/friction-vocab.md). Quick reference:

| Kind | Who emits | When |
|---|---|---|
| `dead_end` | Model | Tried a path, nothing happened, backed out. |
| `ambiguous_label` | Model | Couldn't tell what a control did from its text. |
| `unresponsive` | Model | Interacted, no visible response. |
| `confusing_copy` | Model | Body / alert / error text was hard to parse. |
| `unexpected_state` | Model | Saw a state the agent didn't expect from its last action. |
| `auth_required` | Model | Hit a login wall the run can't pass — staged credential missing or doesn't unlock the surface. V5+. |
| `agent_blocked` | Loop (synthesized) | Budget exhausted, cycle detected, or parse-retry exhausted. |

## Replay-based testing

`Tests/HarnessTests/RunCoordinatorReplayTests.swift` runs the full coordinator end-to-end against `FakeXcodeBuilder` + `FakeSimulatorDriver` + `MockLLMClient`. The mock returns scripted responses so the loop is deterministic. Three scenarios kept green:

1. **Happy path** — tap → type → `mark_goal_done(success)`. Asserts driver was exercised, JSONL parses cleanly, `RunRecord` reflects the verdict.
2. **Cycle detection** — same screenshot 4 turns in a row → expect `verdict == .blocked` + an `agent_blocked` friction event.
3. **Step budget** — budget = 2, scripted 2 taps, no `mark_goal_done` → expect `verdict == .blocked` + summary mentions "step budget".

The `MockLLMClient` is at `Tests/HarnessTests/Mocks/MockLLMClient.swift` and supports both scripted-sequence and request-lookup-closure modes.

## Cross-references

- [`../standards/13-agent-loop.md`](https://github.com/awizemann/harness/blob/main/standards/13-agent-loop.md) — loop invariants.
- [`../standards/07-ai-integration.md`](https://github.com/awizemann/harness/blob/main/standards/07-ai-integration.md) — call-pattern + prompt-caching guidance.
- [`../docs/PROMPTS/system-prompt.md`](https://github.com/awizemann/harness/blob/main/docs/PROMPTS/system-prompt.md) — the prompt itself.
- [Tool-Schema](Tool-Schema) — what the model can emit.
- [Run-Replay-Format](Run-Replay-Format) — what each step writes to disk.

---

P26-05-05 — migrated to GitHub Wiki_