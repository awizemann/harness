# Agent Loop

The mechanical detail lives in [`../standards/13-agent-loop.md`](../standards/13-agent-loop.md). This page is the prose walkthrough — read this for "what's happening here" intuition; read the standard for the load-bearing rules.

## Where it lives

| Concern | File |
|---|---|
| Per-step decision (the loop body) | `Harness/Domain/AgentLoop.swift` |
| Orchestration (build/install/screenshot/log around the loop) | `Harness/Domain/RunCoordinator.swift` |
| LLM API call | `Harness/Services/ClaudeClient.swift` (production) / `Tests/HarnessTests/Mocks/MockLLMClient.swift` (replay tests) |
| Tool schema (model-facing contract) | `Harness/Tools/AgentTools.swift` (+ [Tool-Schema](Tool-Schema.md)) |
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

## The pieces in `AgentLoop`

### History compactor

`HistoryCompactor.compact(_:keepFullTurns:)` keeps the **last 6 turns full** (observation + intent + tool call + screenshot). Older turns lose their screenshots but keep the text reasoning. The strategy is documented in [`../standards/07-ai-integration.md §4`](../standards/07-ai-integration.md). Token-cap-driven further collapse is a follow-up if 6-full proves too expensive.

### Cycle detector

`AgentLoop.recordPostStep(...)` maintains a rolling window of the last 3 `(dHash(screenshot), toolCall)` pairs. When **all 3 dHashes are within Hamming-distance 5** AND **all 3 tool calls are equivalent** (same kind + coordinates within 8pt of each other for tap/swipe; structural equality for type/wait/etc.), the loop bails with `mark_goal_done(blocked, "cycle detected ...")` and an `agent_blocked` friction event.

Why dHash and not exact equality: simulator status-bar overrides remove most chrome variance, but small animations (cursor blink, list ripple) would foil exact pixel hashing. dHash is robust to that.

### Parse-failure retry

When the model emits a tool call that doesn't match the schema (`ClaudeError.invalidToolCall` or `.unknownTool`), the loop retries up to 2 times. Each retry reissues the request — the next call ideally produces a valid tool call. After 2 retries, the loop throws `AgentLoopError.parseFailureExhausted` and the run blocks.

(Phase 1 ClaudeClient surfaces these errors but Phase 2 doesn't yet inject "your last call was malformed" feedback into history. That's a small Phase 3 follow-up.)

### Step + token budgets

- **Step budget** (default 40, range 5–200, ceiling enforced at 200) — exceeded → `mark_goal_done(blocked, "step budget exhausted ...")`.
- **Token budget** (default 250k input for Opus, 1M for Sonnet) — exceeded → `mark_goal_done(blocked, "token budget exhausted ...")`.

Both checks happen at the top of every iteration, before any work. If the loop is mid-step when it would trip, it finishes that step and bails on the next iteration's check.

## Friction taxonomy

Full taxonomy in [`../docs/PROMPTS/friction-vocab.md`](../docs/PROMPTS/friction-vocab.md). Quick reference:

| Kind | Who emits | When |
|---|---|---|
| `dead_end` | Model | Tried a path, nothing happened, backed out. |
| `ambiguous_label` | Model | Couldn't tell what a control did from its text. |
| `unresponsive` | Model | Interacted, no visible response. |
| `confusing_copy` | Model | Body / alert / error text was hard to parse. |
| `unexpected_state` | Model | Saw a state the agent didn't expect from its last action. |
| `agent_blocked` | Loop (synthesized) | Budget exhausted, cycle detected, or parse-retry exhausted. |

## Replay-based testing

`Tests/HarnessTests/RunCoordinatorReplayTests.swift` runs the full coordinator end-to-end against `FakeXcodeBuilder` + `FakeSimulatorDriver` + `MockLLMClient`. The mock returns scripted responses so the loop is deterministic. Three scenarios kept green:

1. **Happy path** — tap → type → `mark_goal_done(success)`. Asserts driver was exercised, JSONL parses cleanly, `RunRecord` reflects the verdict.
2. **Cycle detection** — same screenshot 4 turns in a row → expect `verdict == .blocked` + an `agent_blocked` friction event.
3. **Step budget** — budget = 2, scripted 2 taps, no `mark_goal_done` → expect `verdict == .blocked` + summary mentions "step budget".

The `MockLLMClient` is at `Tests/HarnessTests/Mocks/MockLLMClient.swift` and supports both scripted-sequence and request-lookup-closure modes.

## Cross-references

- [`../standards/13-agent-loop.md`](../standards/13-agent-loop.md) — loop invariants.
- [`../standards/07-ai-integration.md`](../standards/07-ai-integration.md) — call-pattern + prompt-caching guidance.
- [`../docs/PROMPTS/system-prompt.md`](../docs/PROMPTS/system-prompt.md) — the prompt itself.
- [Tool-Schema](Tool-Schema.md) — what the model can emit.
- [Run-Replay-Format](Run-Replay-Format.md) — what each step writes to disk.

---

_Last updated: 2026-05-03 — loop end-to-end against fakes; happy / cycled / budgeted scenarios pinned in tests._
