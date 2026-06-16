# Run Replay Format

Human-facing reference for "I need to read a run file right now." The full canonical schema is at [`../standards/14-run-logging-format.md`](https://github.com/awizemann/harness/blob/main/standards/14-run-logging-format.md). This page is the cheat-sheet version with examples.

## Files per run

```
~/Library/Application Support/Harness/runs/<run-id>/
├── events.jsonl
├── meta.json
├── step-001.png
├── step-002.png
├── …
└── build/DerivedData-<run-id>/
```

Run directories are portable — copy or zip and replay anywhere.

## JSONL row kinds

Every row is a complete JSON object on a single line. Common fields: `schemaVersion` (`1` pre-Phase-E, `2` Phase E+, `3` V5+ — credential metadata on `run_started` and `fill_credential` tool calls), `runId`, `ts` (ISO 8601 UTC), `kind`. The parser accepts all three; unknown versions throw.

Phase E added two row kinds: `leg_started` and `leg_completed`. Single-action runs synthesize one of each so every run's JSONL has at least one leg sandwich around its step rows. Chain runs emit one pair per leg; aborted-after-failure legs get a `leg_completed` with `verdict: "skipped"`. v1 logs (which carry no leg rows at all) read back as one virtual leg; the parser's `legViews(from:)` does that synthesis transparently.

### `run_started` — first row

```jsonc
{
  "schemaVersion": 3, "runId": "B8C5...", "ts": "2026-05-03T19:14:22.118Z",
  "kind": "run_started",
  "goal": "I want to keep track of things to buy. Try to add 'milk' to my list and mark it as done.",
  "persona": "first-time user, never seen this app",
  "model": "claude-opus-4-1",
  "mode": "stepByStep",
  "stepBudget": 40,
  "tokenBudget": 250000,
  "credentialLabel": "Test Account",
  "credentialUsername": "testuser@example.com",
  "project": { "path": "...", "scheme": "TodoSample", "displayName": "TodoSample" },
  "simulator": { "udid": "...", "name": "iPhone 16 Pro", "runtime": "iOS 18.4",
                 "pointWidth": 430, "pointHeight": 932, "scaleFactor": 3.0 }
}
```

### `leg_started` *(v2+)*

```jsonc
{ "kind": "leg_started", "leg": 0,
  "actionName": "Add 'milk'", "goal": "Add 'milk' to the list.", "preservesState": false }
```

Wraps every chain leg's step rows. Single-action runs emit one with `leg: 0` and an empty `actionName`. The replay UI uses these to section the timeline + group the friction report.

### `leg_completed` *(v2+)*

```jsonc
{ "kind": "leg_completed", "leg": 0, "verdict": "success", "summary": "Added 'milk'." }
```

`verdict` is one of `"success" | "failure" | "blocked" | "skipped"`. `"skipped"` is synthesized for legs that follow a failed/blocked leg in a chain — they're written so the replay shape stays predictable but never executed.

### `step_started`

```jsonc
{ "kind": "step_started", "step": 3, "screenshot": "step-003.png", "tokensUsedSoFar": 14820 }
```

### `tool_call`

```jsonc
{
  "kind": "tool_call", "step": 3, "tool": "tap",
  "input": { "x": 215, "y": 482 },
  "observation": "I see a centered + button at the bottom of the list.",
  "intent": "I'll tap it to open the new-todo input."
}
```

For `fill_credential`, the input is redacted:

```jsonc
{
  "kind": "tool_call", "step": 5, "tool": "fill_credential",
  "input": { "field": "password" },
  "observation": "A password field is focused.",
  "intent": "I'll fill in the password from credentials."
}
```

### `tool_result`

```jsonc
{ "kind": "tool_result", "step": 3, "tool": "tap", "success": true, "duration_ms": 47, "error": null }
```

User-rejected variant (step mode):

```jsonc
{ "kind": "tool_result", "step": 3, "tool": "tap", "success": false, "userDecision": "rejected", "userNote": "wrong button" }
```

### `friction`

```jsonc
{ "kind": "friction", "step": 3, "frictionKind": "ambiguous_label",
  "detail": "The button just says 'Go' — I'm not sure what it does until I tap it." }
```

### `step_completed`

```jsonc
{ "kind": "step_completed", "step": 3, "durationMs": 4218,
  "tokensThisStep": { "input": 4820, "output": 311 } }
```

### `run_completed` — last row

```jsonc
{
  "kind": "run_completed",
  "verdict": "success",
  "summary": "Added 'milk' via the + button, tapped the row to mark it done. Saw a checkmark.",
  "frictionCount": 2,
  "wouldRealUserSucceed": true,
  "stepCount": 9,
  "tokensUsedTotal": { "input": 41280, "output": 2104 }
}
```

## Replay invariant

Every row type in a valid JSONL is **idempotent** — if a tool execution failed and the agent retried, both the original failure and the retry are logged. The replay engine reads the stream linearly and applies each row in order. A failed `tool_result` doesn't block the next step; the loop decides whether to continue or abort based on the tool's error message and the agent's retry hint.

The disk PNG for a step stays **immutable** once written. If a step was retried (rare — usually only parse failures), the original screenshot at `step-003.png` is still the one the agent saw on that attempt. Subsequent attempts see fresh screenshots with new names.

