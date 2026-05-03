# Tool Schema

The model-facing contract. **This page and `Harness/Tools/AgentTools.swift` must agree byte-for-byte** — a CI test enforces this. When you change a tool, update both in the same commit.

Every tool call carries two reasoning fields the model fills in before each action:

- `observation` — what the agent sees on the current screen, in its own words.
- `intent` — what the agent is trying to do and why this action serves the goal.

These are not optional. Coordinates are in **screen points** (not pixels), origin at top-left.

---

## Action tools

### `tap`

Tap a single point on the screen.

```
tap(
  x: int,
  y: int,
  observation: string,
  intent: string
)
```

### `double_tap`

Tap twice quickly at one point.

```
double_tap(
  x: int,
  y: int,
  observation: string,
  intent: string
)
```

### `swipe`

Swipe from one point to another over a duration (default 200ms).

```
swipe(
  x1: int,
  y1: int,
  x2: int,
  y2: int,
  duration_ms: int = 200,
  observation: string,
  intent: string
)
```

### `type`

Type a string of characters into the currently-focused field.

```
type(
  text: string,
  observation: string,
  intent: string
)
```

### `press_button`

Press a hardware-style button on the simulator.

```
press_button(
  button: "home" | "lock" | "side" | "siri",
  observation: string,
  intent: string
)
```

### `wait`

Pause for some milliseconds. Useful when the agent expects an animation or load to finish before acting again. The loop still captures a fresh screenshot afterward.

```
wait(
  ms: int,
  observation: string,
  intent: string
)
```

### `read_screen`

A no-op action: the agent forces a fresh screenshot capture next iteration without taking any UI action. Useful when the agent wants to re-examine what's there before deciding.

```
read_screen(
  observation: string,
  intent: string
)
```

---

## Reporting tools

### `note_friction`

Flag a UX problem. Emitted alongside or instead of an action. Multiple `note_friction` calls per step are allowed.

```
note_friction(
  kind: "dead_end" | "ambiguous_label" | "unresponsive" | "confusing_copy" | "unexpected_state",
  detail: string
)
```

`kind` enum is closed and matches `docs/PROMPTS/friction-vocab.md` exactly.

### `mark_goal_done`

Terminate the run. The agent calls this when it succeeds, fails, or would give up.

```
mark_goal_done(
  verdict: "success" | "failure" | "blocked",
  summary: string,
  friction_count: int,
  would_real_user_succeed: bool
)
```

- `verdict` — what happened from the agent's perspective.
- `summary` — one-paragraph plain-English description.
- `friction_count` — how many friction events were emitted this run.
- `would_real_user_succeed` — the agent's honest read on whether *the persona it's playing* could complete the goal. Can disagree with `verdict`.

---

## Schema agreement

The Swift definitions in `Harness/Tools/AgentTools.swift`:

- enumerate the same tool names,
- have the same field names with matching types,
- have the same enum values (verbatim).

A unit test (`AgentToolSchemaTests`) loads this markdown file, parses the documented schema, and `#expect`s it equals `AgentTools.allTools`. PR with drift fails the build.

---

_Last updated: 2026-05-03 — initial scaffolding._
