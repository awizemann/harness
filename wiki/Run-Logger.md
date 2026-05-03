# Run Logger

Append-only writer for `events.jsonl` and the per-step PNG dump. One actor per active run; the actor owns the `FileHandle` and serializes writes.

The schema is in [Run-Replay-Format](Run-Replay-Format.md). The integrity invariants are in [`../standards/08-run-log-integrity.md`](../standards/08-run-log-integrity.md). This page is the implementation deep-dive.

Status: scaffold. Filled out as `Harness/Services/RunLogger.swift` lands in Phase 2.

## Lifecycle

```swift
let logger = try await RunLogger.open(runID: id, in: HarnessPaths.runDir(for: id))
try await logger.append(.runStarted(...))
// ... per step ...
try await logger.append(.stepStarted(step: 3, screenshot: "step-003.png"))
try await logger.append(.toolCall(step: 3, tool: .tap(...)))
try await logger.append(.toolResult(step: 3, success: true))
try await logger.append(.friction(step: 3, kind: .ambiguousLabel, detail: "..."))
try await logger.append(.stepCompleted(step: 3, durationMs: 4218, tokens: ...))
// ... eventually ...
try await logger.append(.runCompleted(verdict: .success, ...))
try await logger.close()
```

`close()` writes `meta.json` and releases the `FileHandle`.

## Invariants enforced by the actor

- One `FileHandle` per run; never shared.
- Every row is one complete JSON object on a single line, terminated by `\n`.
- `synchronize()` is called after every row.
- The screenshot PNG is written **before** the corresponding `step_started` row. If the PNG write fails, no row is written and the actor throws `LogWriteFailure.screenshotWriteFailed`.
- `runStarted` is enforced as the first row; `runCompleted` (when present) as the last; the actor refuses to append a second `runStarted` or anything after `runCompleted`.

## Error surface

| Condition | `LogWriteFailure` |
|---|---|
| Disk full | `.diskFull` |
| Permission denied | `.permissionDenied(path:)` |
| Screenshot write failed | `.screenshotWriteFailed(step:, underlying:)` |
| Append after `runCompleted` | `.appendAfterCompletion` |
| Encoding failure | `.encodingFailed(kind:, underlying:)` |

Any of these terminates the run. The orchestrator surfaces the error to the UI; the partial JSONL is still parseable up to the last successful row.

## Cross-references

- [Run-Replay-Format](Run-Replay-Format.md) — the JSONL schema this writer emits.
- [`../standards/08-run-log-integrity.md`](../standards/08-run-log-integrity.md) — invariants.
- [`../standards/14-run-logging-format.md`](../standards/14-run-logging-format.md) — schema.

---

_Last updated: 2026-05-03 — initial scaffolding._
