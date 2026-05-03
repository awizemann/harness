# Run Logger

Append-only writer for `events.jsonl` and the per-step PNG dump. One actor per active run; the actor owns the `FileHandle` and serializes every write.

The schema is in [Run-Replay-Format](Run-Replay-Format.md). The integrity invariants are in [`../standards/08-run-log-integrity.md`](../standards/08-run-log-integrity.md).

## Implementation

| File | Role |
|---|---|
| `Harness/Services/RunLogger.swift` | The writer + row encoder + meta.json writer. |
| `Harness/Services/RunLogParser.swift` | The reader + invariant checker. |

## Lifecycle

```swift
let logger = try RunLogger.open(runID: id)        // creates run dir; opens FileHandle
try await logger.append(.runStarted(from: req))   // first row
_ = try await logger.writeScreenshot(png, step: 1) // PNG before its step_started row
try await logger.append(.stepStarted(...))
try await logger.append(.toolCall(step: 1, call: ...))
try await logger.append(.toolResult(...))
try await logger.append(.friction(...))            // optional
try await logger.append(.stepCompleted(...))
// ... more steps ...
try await logger.append(.runCompleted(...))        // terminal
try await logger.writeMeta(outcome, request: req)  // redundant snapshot
await logger.close()
```

## Invariants enforced by the actor

- **Single `runStarted`.** Second emission throws `LogWriteFailure.duplicateStart`.
- **Append before start.** Throws `LogWriteFailure.appendBeforeStart`.
- **Append after completion.** Throws `LogWriteFailure.appendAfterCompletion`.
- **PNG-then-row.** `writeScreenshot(_:step:)` writes the PNG atomically; the corresponding `step_started` row references it by relative path. If the PNG write fails, the row is never written and `LogWriteFailure.screenshotWriteFailed` propagates.
- **`synchronize()` after every row.** Crash mid-line leaves a valid prefix; the parser truncates at the last newline.
- **Schema version 1 stamped on every row.** Future bumps add a versioned decoder; old runs stay readable forever.
- **Disk-full** maps to `LogWriteFailure.diskFull`; **permission denied** maps to `LogWriteFailure.permissionDenied`.

## Encoding

Per-row encoding lives in `RunLogger.encode(_:runID:ts:)`. The function is `static` (test-callable) and emits a sorted-keys JSON object (no trailing newline; the actor appends `\n`).

The tagged-union `ToolInput` is encoded by `LogRow.toolInputJSONString(_:)` using the wire-shape field names matching `wiki/Tool-Schema.md` (`x`, `y`, `x1`, `y1`, ..., `duration_ms`, `text`, `button`, `ms`, `kind`, `detail`, `verdict`, `summary`, `friction_count`, `would_real_user_succeed`).

## Parsing

`RunLogParser.parse(runID:)` reads `events.jsonl` from the run directory and returns `[DecodedRow]`. Behaviors:

- **Trailing partial rows are tolerated.** A truncated final line is silently dropped — a crashed Harness still produces a parseable file.
- **Unknown row `kind` is silently skipped.** Forward-compatible — old parsers don't fail on rows from a future schema.
- **Unsupported `schemaVersion` throws `ParseError.schemaVersionUnsupported(Int)`.**
- **`validateInvariants(_:)`** is a separate call that checks the cross-row rules: `run_started` first, `run_completed` (when present) last, step numbers monotonic + gap-free.

## Tests

`Tests/HarnessTests/RunLoggerTests.swift`:

- Full happy-path round-trip (every row kind populated; parses back identically).
- Truncated trailing line tolerated.
- Append-before-start, duplicate-start, append-after-completion all throw the right typed error.
- Step-gap detected by `validateInvariants`.

## meta.json

Written at run end alongside the last `runCompleted` row. Carries a redundant snapshot of the `RunRecord` SwiftData fields so a copied run directory replays without the user's history store.

## Cross-references

- [Run-Replay-Format](Run-Replay-Format.md) — the JSONL schema this writer emits.
- [`../standards/08-run-log-integrity.md`](../standards/08-run-log-integrity.md) — invariants.
- [`../standards/14-run-logging-format.md`](../standards/14-run-logging-format.md) — schema.
- [Agent-Loop](Agent-Loop.md) — what's calling this writer.

---

_Last updated: 2026-05-03 — Phase 2 ship._
