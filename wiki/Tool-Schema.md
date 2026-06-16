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

### `tap_mark` *(web, iOS, macOS)*

Click an interactive element by its **Set-of-Mark badge id** from the current screenshot. The screenshot the model sees carries a small numbered green pill floating just above every focusable target — inputs, buttons, anchors (`<a href="...">`, including nav links), checkboxes, dropdowns, role=button / role=link / role=tab / role=menuitem / role=switch, and contenteditable regions. The agent picks the id from the badge of the element it wants to act on; the driver resolves to the element's CSS-pixel center and routes through the same click path as `tap`.

**Strongly preferred over `tap(x, y)` whenever the target has a mark.** Coordinate-emission failure (model says "tap Articles" but the (x, y) lands on a neighbour nav link) is the dominant failure mode for sub-10B vision models. `tap_mark` eliminates the coordinate-rescale math entirely: the model picks a number, the driver knows the rect. Use `tap(x, y)` only for unmarked positions — scrolling targets, image-region taps, page-level positions where no interactive element exists.

```
tap_mark(
  id: int,        // 1-based; refreshes every screenshot
  observation: string,
  intent: string
)
```

Mark ids are 1-based, follow reading order (top-to-bottom, then left-to-right), and are **never reused across turns** — the agent always reads the current screenshot's badges. A stale id throws a driver-specific `unknownMark(id:)` error and the loop's retry hint surfaces the message to the model.

Per-platform probe details:
- **Web** — `getBoundingClientRect()` + shadow-root walk on every focusable element ([Web-Driver](Web-Driver)).
- **iOS** — WebDriverAgent's `/source?format=json` AX tree, filtered to actionable XCUI roles. Child `StaticText` rolls up into the cell's label so a server-list row reads as `"server.rack — 127.0.0.1 — alanwizemann@127.0.0.1"` instead of `""` ([iOS-Driver](iOS-Driver)).
- **macOS** — `AXUIElementCopyAttributeValue` on the focused window, filtered to actionable AX roles. Coordinate conversion subtracts the window origin to produce window-local point space ([macOS-Driver](macOS-Driver)).

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

### `fill_credential` *(V5+)*

Type the run's pre-staged credential into the currently-focused text field. Picks which slot to fill via `field`. The actual value lives outside the agent's context — the agent picks the slot, the runtime substitutes the configured value at type time. **The password value is never visible to the agent.**

Available on iOS, macOS, and web. Use only when the system prompt's `{{CREDENTIALS}}` block lists a staged credential. If no credential is staged and the agent encounters a login wall, it should emit `note_friction(kind: "auth_required", ...)` instead.

```
fill_credential(
  field: "username" | "password",
  observation: string,
  intent: string
)
```

The corresponding `tool_call.input` in the JSONL is exactly `{"field": "username"}` or `{"field": "password"}` — no value, ever. See [Run-Replay-Format](Run-Replay-Format) § Credential redaction.

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

P26-05-05 — migrated to GitHub Wiki_