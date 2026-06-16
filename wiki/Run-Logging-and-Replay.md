# Run Logging and Replay

Every run produces an **append-only JSONL log** at `~/Library/Application Support/Harness/runs/<run-id>/events.jsonl`, plus a `meta.json` snapshot and disk PNG screenshots. This format enables replay, friction analysis, and long-term archival.

## File structure

```
runs/<run-id>/
  ├─ events.jsonl          # append-only event log (v2+)
  ├─ meta.json             # run metadata snapshot
  ├─ screenshots/
  │  ├─ step-1.png
  │  ├─ step-2.png
  │  └─ ...
  └─ friction-report.txt   # optional; human-readable summary (generated post-run)
```

All files are **append-only** (no edits after write) except `friction-report.txt` (generated last). This guarantees consistency: a run directory is always in a consistent state, even if the process crashes mid-run.

## JSONL log format (v2+)

Each line is a single JSON object representing an event. Events are emitted in chronological order.

### Common fields

All events have:

```json
{
  "eventType": "<kind>",
  "timestamp": "2024-05-12T14:30:45.123456Z",
  "runID": "<uuid>",
  "stepNumber": 1
}
```

### Event types

#### `run_started`

Emitted once at the beginning of the run. Captures the request and context.

```json
{
  "eventType": "run_started",
  "timestamp": "...",
  "runID": "...",
  "applicationID": "<uuid or null>",
  "applicationName": "MyApp",
  "applicationKind": "ios_simulator|macos|web",
  "projectPath": "/Users/alice/Projects/MyApp",
  "scheme": "MyApp-Debug",
  "simulatorID": "<simulator-uuid>",
  "simulatorName": "iPhone 16 Pro",
  "personaID": "<uuid or null>",
  "personaName": "First-time user",
  "goal": "Sign up and create a list",
  "mode": "full_auto|step_by_step",
  "modelProvider": "anthropic|openai|google|local_mac",
  "modelName": "claude-opus-4-7|gpt-5-mini|gemini-2-5-flash|qwen3-vl-8b",
  "stepBudget": 100,
  "tokenBudget": 250000,
  "credentialLabel": "alice@example.com (optional)",
  "credentialUsername": "alice (optional)"
}
```

#### `leg_started` / `leg_completed`

For runs with action chains (multiple sequential goals), each leg has a boundary marker.

```json
{
  "eventType": "leg_started",
  "legNumber": 1,
  "action": "Sign up",
  "preserveState": true
}
```

```json
{
  "eventType": "leg_completed",
  "legNumber": 1,
  "verdict": "success|failure|blocked|budget_exhausted",
  "summary": "Successfully filled in signup form and created account."
}
```

#### `step_started` / `step_completed`

One per loop iteration (one per agent decision + execution).

```json
{
  "eventType": "step_started",
  "stepNumber": 1,
  "legNumber": 1
}
```

```json
{
  "eventType": "step_completed",
  "stepNumber": 1,
  "legNumber": 1,
  "screenshotHash": "<64-bit dHash hex>",
  "tokensCurrent": 1200,
  "tokensUsed": 800,
  "screenPath": "MyApp / Login / Signup"
}
```

ScreenPath is inferred from the agent's last observation (e.g., button labels, screen title) and aids manual review.

#### `tool_call`

The agent's action: a tool invocation from the schema.

```json
{
  "eventType": "tool_call",
  "stepNumber": 1,
  "toolName": "tap_mark|tap|swipe|type|fill_credential|navigate|scroll|mark_goal_done",
  "toolInput": {
    "id": 5,
    "x": null,
    "y": null
  },
  "reasoning": "User should tap the Sign Up button to proceed."
}
```

For `fill_credential`, the input is `{ "field": "username"|"password" }` — no plaintext secret.

#### `tool_result`

The outcome of executing the tool.

```json
{
  "eventType": "tool_result",
  "stepNumber": 1,
  "toolName": "tap_mark",
  "status": "success|failure|timeout",
  "message": "Button tapped; keyboard appeared.",
  "screenshotAfterExecution": "<base64-encoded PNG (optional, for simple tools; omitted for screenshot-heavy ones)>"
}
```

The full screenshot is saved to disk as `screenshots/step-<N>.png` and referenced by path, not inlined, to save log size.

#### `note_friction`

The agent flagged a UX issue. Can be emitted inline during a step or as a standalone event.

```json
{
  "eventType": "note_friction",
  "stepNumber": 1,
  "frictionKind": "confusing_label|missing_affordance|unresponsive_control|goal_blocked|auth_required|cycle_detected|parse_error",
  "description": "The 'Next' button label is unclear; it doesn't say what happens next.",
  "context": null,
  "screenshotHash": "<64-bit dHash>"
}
```

Built-in friction kinds:

- **`confusing_label`** — button/field text is misleading or unclear.
- **`missing_affordance`** — expected UI element is hidden or absent.
- **`unresponsive_control`** — tap/input had no visible effect.
- **`goal_blocked`** — user cannot proceed (dead end, paywall, unsupported state).
- **`auth_required`** — login wall with no credentials staged.
- **`cycle_detected`** — agent looped on the same screen/action pair.
- **`parse_error`** — agent produced invalid tool calls repeatedly.

#### `run_completed`

Emitted once at the end of the run (success, failure, cancellation, or error).

```json
{
  "eventType": "run_completed",
  "verdict": "success|failure|blocked|budget_exhausted|cancelled|error",
  "summary": "The user successfully signed up, but encountered confusion when trying to create a list. The 'New List' button was not clearly discoverable.",
  "frictionCount": 2,
  "frictionKinds": [ "missing_affordance", "confusing_label" ],
  "stepsTaken": 8,
  "tokensUsed": 10500,
  "totalDuration": 42.5
}
```

## Schema versioning

The JSONL format is versioned by `schemaVersion` (bumped in `standards/14-run-logging-format.md` when the log format changes). Current version: **v2**.

**v2 additions (v0.3+):**
- `leg_started` / `leg_completed` rows for multi-leg runs.
- Optional `credentialLabel` / `credentialUsername` in `run_started`.
- `legNumber` in step rows.

**v1→v2 migration:** RunLogParser is tolerant; v1 logs are wrapped in a single virtual leg on load, so replay works seamlessly. New runs emit v2.

## Writing logs

**RunLogger** (actor in `Harness/Services/RunLogger.swift`) owns the JSONL file:

```swift
actor RunLogger {
  func append(_ event: RunEvent) async throws
  func flushAndClose() async throws
}
```

Each call to `append` does:

1. Encode the event to JSON.
2. Write the line + newline to the JSONL file.
3. Call `synchronize()` (fsync) to ensure the line hits disk immediately.
4. Return.

This per-line fsync is intentional: if the process crashes, the log is consistent up to the last event write. Screenshots and `meta.json` are written separately and may lag.

## Parsing logs

**RunLogParser** (in `Harness/Services/RunLogParser.swift`) reads a JSONL file and emits a **strongly typed** `ParsedRun`:

```swift
struct ParsedRun {
  let meta: RunStartedEvent
  let legs: [ParsedLeg]
  let verdict: Verdict
  let summary: String
  let frictions: [ParsedFriction]
}

struct ParsedLeg {
  let number: Int
  let steps: [ParsedStep]
}

struct ParsedStep {
  let number: Int
  let toolCall: ToolCall?
  let toolResult: ToolResult?
  let inlineFrictions: [ParsedFriction]
}
```

Parser is **tolerant**:

- Missing optional fields default to `nil` or empty.
- Trailing garbage is ignored (crash-resilient).
- Out-of-order events are buffered and re-ordered.
- v1 logs are detected and wrapped in a virtual leg.

Parser validates invariants (e.g., a `tool_result` must follow a `tool_call` in the same step); validation failures are logged but don't stop the parse.

## Replay

**RunReplayView** loads a parsed run and displays it as a scrubber + timeline:

1. Load `events.jsonl` via `RunLogParser`.
2. Load `meta.json` for run context (goal, persona, model, duration).
3. Load `screenshots/<step-N>.png` for each step on demand (lazy).
4. User scrubs the timeline (← / → keys or slider) to jump between steps.
5. Each step card shows:
   - Tool call (reasoning + action).
   - Tool result (success / failure / timeout).
   - Inline friction observations.
   - Screenshot (side-by-side or full-width per layout).

Replays are **read-only** — they archive the run for later review, UX audit, and debugging.

## Friction report

Post-run, **FrictionReportView** generates a summary:

```
Run: "Sign up and create a list"
Persona: "First-time user"
Verdict: Success (8 steps, ~42s)

Friction events:

  Step 3: Missing affordance
    "The 'New List' button is not visible on the home screen. 
     User had to scroll down to find it."

  Step 5: Confusing label
    "The 'Confirm' button at the top of the dialog is unclear. 
     'OK' or 'Save' would be more intuitive."

Summary: User successfully signed up but encountered two UX issues that slowed progress.
```

The report is exported (markdown, PDF, JSON) for sharing with designers and product managers.

## Testing

RunLogger and RunLogParser are tested via:

- **Unit tests** — write events, parse, verify structure.
- **Crash-resilience tests** — truncate log at various points, verify parser recovers gracefully.
- **Round-trip tests** — load a real run, parse, serialize, parse again; ensure the two parsed trees match.
- **Replay tests** — load a parsed run, replayed through the UI; verify scrolling, step navigation, and friction markers all work.

See `tests/Services/RunLoggerTests.swift` and `tests/Services/RunLogParserTests.swift`.