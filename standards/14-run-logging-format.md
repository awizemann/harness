# 14 — Run Logging Format

Applies to: **Harness**

The on-disk format for run artifacts. Pairs with `08-run-log-integrity.md` (write/read invariants) and `wiki/Run-Replay-Format.md` (human-facing reference).

---

## 1. Files per run

```
<App Support>/Harness/runs/<run-id>/
├── events.jsonl          append-only event stream
├── meta.json             redundant copy of RunRecord fields (offline-portable)
├── step-001.png          screenshots (3-digit zero-padded)
├── step-002.png
├── …
└── build/                xcodebuild derived data (kept for reproducibility)
    └── DerivedData-<run-id>/
```

`<run-id>` is a UUID. Every path under the run dir is portable — copy or zip the directory and replay it on another machine.

---

## 2. JSONL row schema

Every row is a complete JSON object on a single line. Common fields on every row:

| Field | Type | Required | Notes |
|---|---|---|---|
| `schemaVersion` | int | yes | `1` today. Bumps only on backward-incompatible change. |
| `runId` | string (UUID) | yes | Constant across the whole file. |
| `ts` | string (ISO 8601, UTC) | yes | `2026-05-03T19:14:22.118Z` |
| `kind` | string | yes | One of the enum below. |

Unknown fields are tolerated by the parser. Adding new optional fields is forward-compatible.

---

## 3. Row kinds

### `run_started`

First row in the file. Carries the run setup.

```jsonc
{
  "schemaVersion": 1,
  "runId": "B8C5A8F1-…",
  "ts": "2026-05-03T19:14:22.118Z",
  "kind": "run_started",
  "goal": "I want to keep track of things to buy. Try to add 'milk' to my list and mark it as done.",
  "persona": "first-time user, never seen this app",
  "model": "claude-opus-4-7",
  "mode": "stepByStep",                       // or "autonomous"
  "stepBudget": 40,
  "tokenBudget": 250000,
  "project": {
    "path": "/Users/alanwizemann/Development/TodoSample",
    "scheme": "TodoSample",
    "displayName": "TodoSample"
  },
  "simulator": {
    "udid": "B8C5A8F1-…",
    "name": "iPhone 16 Pro",
    "runtime": "iOS 18.4",
    "pointWidth": 430,
    "pointHeight": 932,
    "scaleFactor": 3.0
  }
}
```

### `step_started`

One per step, before any tool call. References the screenshot taken at the top of the iteration.

```jsonc
{
  "schemaVersion": 1, "runId": "...", "ts": "...",
  "kind": "step_started",
  "step": 3,
  "screenshot": "step-003.png",                // relative path
  "tokensUsedSoFar": 14820
}
```

### `tool_call`

The tool the agent emitted on this step. Reasoning fields included.

```jsonc
{
  "schemaVersion": 1, "runId": "...", "ts": "...",
  "kind": "tool_call",
  "step": 3,
  "tool": "tap",
  "input": { "x": 215, "y": 482 },
  "observation": "I see a centered + button at the bottom of the list.",
  "intent": "I'll tap it to open the new-todo input."
}
```

The `input` schema varies by `tool`. See `wiki/Tool-Schema.md` for each tool's payload.

### `tool_result`

Paired with the most recent `tool_call` for this step. Captures execution outcome.

```jsonc
{
  "schemaVersion": 1, "runId": "...", "ts": "...",
  "kind": "tool_result",
  "step": 3,
  "tool": "tap",
  "success": true,
  "duration_ms": 47,
  "error": null
}
```

If the user rejected (step mode) or skipped:

```jsonc
{ "kind": "tool_result", "step": 3, "tool": "tap", "success": false, "userDecision": "rejected", "userNote": "the + is below — it shouldn't be in the corner" }
```

### `friction`

Emitted when the agent calls `note_friction` or when the loop synthesizes one.

```jsonc
{
  "schemaVersion": 1, "runId": "...", "ts": "...",
  "kind": "friction",
  "step": 3,
  "frictionKind": "ambiguous_label",
  "detail": "The button just says 'Go' — I'm not sure what it does until I tap it."
}
```

The `frictionKind` values are the taxonomy from `13-agent-loop.md §5` plus the synthesized `agent_blocked`.

### `step_completed`

Emitted after the tool sequence resolves (one tool_call → one tool_result, plus any friction rows).

```jsonc
{
  "schemaVersion": 1, "runId": "...", "ts": "...",
  "kind": "step_completed",
  "step": 3,
  "durationMs": 4218,
  "tokensThisStep": { "input": 4820, "output": 311 }
}
```

### `run_completed`

Last row in the file. Carries the verdict.

```jsonc
{
  "schemaVersion": 1, "runId": "...", "ts": "...",
  "kind": "run_completed",
  "verdict": "success",                         // "success" | "failure" | "blocked"
  "summary": "Added 'milk' via the + button, tapped the row to mark it done. Saw a checkmark.",
  "frictionCount": 2,
  "wouldRealUserSucceed": true,
  "stepCount": 9,
  "tokensUsedTotal": { "input": 41280, "output": 2104 }
}
```

If the run crashed mid-flight, `run_completed` is absent. The parser detects this and surfaces the run as "incomplete" in the history view.

---

## 4. meta.json

A redundant snapshot of the `RunRecord` SwiftData fields written at run end. Lets a copied run directory replay without the SwiftData index:

```json
{
  "schemaVersion": 1,
  "id": "B8C5A8F1-…",
  "createdAt": "2026-05-03T19:14:22.118Z",
  "completedAt": "2026-05-03T19:18:04.005Z",
  "verdict": "success",
  "frictionCount": 2,
  "stepCount": 9,
  "tokensUsedInput": 41280,
  "tokensUsedOutput": 2104,
  "model": "claude-opus-4-7",
  "mode": "stepByStep",
  "goal": "...",
  "persona": "...",
  "projectPath": "/Users/alanwizemann/Development/TodoSample",
  "scheme": "TodoSample",
  "simulator": { "udid": "...", "name": "iPhone 16 Pro", "runtime": "iOS 18.4" }
}
```

---

## 5. Versioning rules

- Adding an optional field → no version bump.
- Adding a new `kind` → no version bump (parsers must tolerate unknown kinds; warn, don't fail).
- Renaming, removing, or retyping a required field → version bump. Versioned decoders ship side-by-side; old runs stay readable forever.

When `schemaVersion` bumps:

1. Add a new versioned decoder.
2. Keep the old one. Don't migrate on disk.
3. Update `wiki/Run-Replay-Format.md` to document both versions.
4. Update the round-trip test (`Tests/HarnessTests/RunLoggerRoundTripTests.swift`) to cover the new version while keeping the old version's fixture green.

---

## 6. Screenshot conventions

- PNG, simulator native resolution (no downscaling on disk — downscaling happens only when sending to Claude).
- Filename: `step-NNN.png` with N zero-padded to 3 digits. Steps beyond 999 are out of scope (hard ceiling is 200).
- The PNG is written **before** the `step_started` row that references it. If the PNG write fails, no `step_started` is emitted; the loop fails the step and emits a `friction` of kind `unexpected_state`.

---

## 7. Replay invariants

A correctly-formed run satisfies:

- `run_started` is the first row.
- For every `step_started`, exactly one `tool_call` and at most one `tool_result` exist with the same `step`.
- `step_completed` appears once per step, after that step's `tool_result`.
- If `run_completed` appears, it is the last row.
- Step numbers are 1-indexed, monotonically increasing, no gaps.
- Every `screenshot` field references a file that exists in the run directory.

Replay parsers verify these on load and surface specific errors when violated.

---

## 8. Audit checklist

When reviewing run-log code:

- [ ] Does `RunLogger` write `schemaVersion: 1` on every row?
- [ ] Are reasoning fields (`observation`, `intent`) preserved verbatim from the model?
- [ ] Does `step_started` reference a screenshot file that already exists at write time?
- [ ] Is `meta.json` written at run end (success or failure path)?
- [ ] Does the parser tolerate unknown `kind` values without crashing?
- [ ] Does the round-trip test exercise every kind?
- [ ] Are timestamps ISO 8601 with `Z` suffix (UTC), not local time?
