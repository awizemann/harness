# 08 — Run Log Integrity

Applies to: **Harness**

The replay UI is only as good as the JSONL it reads. A corrupt or partial run log isn't an inconvenience — it strands the artifact users came to Harness for. This standard codifies the invariants the writer must preserve and the parser must enforce. Pairs with `14-run-logging-format.md` (the schema) and `wiki/Run-Replay-Format.md` (the human-facing reference).

---

## 1. Append-only writes

`events.jsonl` is **append-only**. A run never rewrites earlier rows.

- One `RunLogger` actor per active run owns the `FileHandle` and serializes writes.
- Every row is a complete JSON object on a single line, terminated with `\n`.
- `FileHandle.write(_:)` is followed by `FileHandle.synchronize()` before the call returns. We accept the per-row fsync cost in exchange for the guarantee that a crashed Harness leaves a valid prefix.

If the writer crashes mid-line, the parser truncates at the last newline. **Partial trailing rows are tolerated.** Earlier rows must be intact.

---

## 2. Schema versioning

Every row carries `schemaVersion: 1`. Adding optional fields keeps `schemaVersion: 1`. Renaming, removing, or changing the type of a field bumps the version.

The parser knows how to read every shipped version; old runs stay replayable forever. New writers always write the latest version.

```jsonc
{"schemaVersion":1,"runId":"...","ts":"2026-05-03T19:14:22.118Z","kind":"step_started","step":3, ...}
```

Forward-compatible (no version bump):

- Add an optional field.
- Add a new `kind` value (parser ignores unknown kinds → friction warning, not error).

Backward-incompatible (must bump):

- Rename a field.
- Change a field's type.
- Remove a required field.

When the version bumps, the parser dispatches on `schemaVersion` to a versioned decoder. Don't try to silently coerce — explicit dispatch keeps every shipped version honest.

---

## 3. Row kinds

The `kind` field discriminates the row's payload (full table in `14-run-logging-format.md`):

- `run_started` — once at run start; carries goal, persona, model, mode, project, simulator.
- `step_started` — once per step, before any tool call.
- `tool_call` — every tool the agent invokes.
- `tool_result` — paired with each `tool_call`.
- `friction` — emitted alongside or independently when the agent flags `note_friction`.
- `step_completed` — once per step, after the tool sequence resolves.
- `run_completed` — once at run end; carries verdict, summary, friction count, tokens used.

Invariant: `run_started` is always the first row; `run_completed` is always the last. Replay parsers reject files violating this.

---

## 4. Screenshot durability

Screenshots are stored alongside `events.jsonl` as `step-NNN.png`. Rules:

- The PNG file is written **before** the corresponding `step_started` row is appended. If the PNG write fails, no event row is written; the loop retries or fails the step.
- Filename uses three-digit zero-padded step number (`step-001.png`, `step-042.png`) so directory listing sorts correctly.
- The event row references the screenshot by **relative path** (`"screenshot": "step-003.png"`), never absolute. This makes a run directory portable — copy/zip it, replay anywhere.

---

## 5. Atomic step boundaries

A step is the unit of replayable progress. Within one step:

1. Capture screenshot → write PNG.
2. Append `step_started` row.
3. Send to Claude → get response.
4. Append `tool_call` row.
5. Execute tool via `SimulatorDriver` → get result.
6. Append `tool_result` row.
7. Append zero or more `friction` rows.
8. Append `step_completed` row.

A run can crash anywhere in this sequence and the parser must produce a sensible reconstruction:

- If `step_started` exists without `step_completed`, the replay UI shows that step as "incomplete" and stops there.
- If a `tool_call` exists without `tool_result`, the replay shows the proposed action with a "result unknown" badge.

Don't try to repair partial steps on disk. Read what's there; don't speculate.

---

## 6. Idempotent re-reads

The parser is idempotent and side-effect-free. Reading the same file twice produces equivalent in-memory `Run` structs. Specifically:

- No filesystem mutations during parse.
- No clock dependencies (don't compare event timestamps to `Date()`; treat them as opaque ISO 8601 strings).
- No environment dependencies (Anthropic API key, network, simulator state) needed.

This is what enables offline replay of an old run on a different machine.

---

## 7. Concurrent run isolation

Multiple Harness runs can be in flight simultaneously (rare, but possible if the user opens a second window). Each run has its own `RunLogger` actor, its own `FileHandle`, its own `<run-id>` directory. There is **no shared writer**; concurrent runs never touch the same JSONL file.

If a future feature adds inter-run aggregation (e.g., "compare two runs"), it operates on closed run files only — never on a live run.

---

## 8. Disk-full handling

When the JSONL append fails (disk full, permission lost), the run terminates immediately:

- `RunLogger` throws `LogWriteFailure(underlying:, runId:)`.
- The orchestrator catches it, terminates the simulator, and surfaces a clear error in the UI ("disk full at step 18; the run was preserved up to that point").
- The partial run is parseable; the user can replay what was captured.

We don't attempt to retry, buffer, or fail-soft. A run with mid-flight log gaps is more dangerous than a run that ends honestly.

---

## 9. Round-trip test (required)

Per `10-testing.md §6`: any change to `RunLogger` or the parser must include a roundtrip test:

1. Construct a fully-populated `Run` (every optional field non-nil; every `kind` represented; multi-step with friction events).
2. `RunLogger.write(_:)` it to a temp directory.
3. Parse the JSONL back.
4. `#expect` the parsed `Run` equals the original.

Don't skip optional fields. Populate every one — they are exactly the fields most likely to drop on schema changes.

---

## 10. Migration

When the schema bumps from v1 to v2:

- Versioned decoders for v1 and v2 ship side-by-side.
- A migration helper reads v1 runs and emits v2-shaped `Run` structs in memory (no rewriting on disk — old files stay v1 forever).
- The `wiki/Run-Replay-Format.md` page is updated to document both versions and the migration mapping.

---

## 11. Audit checklist

When reviewing run-log code:

- [ ] Does every write append to `events.jsonl` and not seek/overwrite?
- [ ] Is `synchronize()` called after every row write?
- [ ] Are screenshots written before the corresponding event row?
- [ ] Is the `schemaVersion` field present on every row?
- [ ] Does the parser tolerate trailing partial lines?
- [ ] Does the parser reject runs missing `run_started` or `run_completed` (after explicit reachable EOF)?
- [ ] Are screenshot paths relative, not absolute?
- [ ] Does the round-trip test still pass?
- [ ] Does the writer hold the only `FileHandle` for the run via a single actor?
