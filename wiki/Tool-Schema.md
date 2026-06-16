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

Click an interactive element by its **Set-of-Mark badge id** from the current screenshot. The screenshot the model sees carries a small numbered green pill floating just above every focusable target — inputs, buttons, anchors (`<a href="...">`), checkboxes, dropdowns, and `role=button` / `role=link` / `role=tab` / `role=menuitem` / `role=switch` elements, and contenteditable regions. The agent picks the id from the badge of the element it wants to act on; the driver resolves to the element's center and routes through the same click path as `tap`.

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

### `press_button`

Press a hardware button (iOS only: home, volume-up, volume-down).

```
press_button(
  name: "home" | "volume_up" | "volume_down",
  observation: string,
  intent: string
)
```

### `wait`

Wait for a duration in milliseconds. Useful when the UI is animated (e.g., a sheet is sliding in) and you want to let it finish before screenshotting.

```
wait(
  duration_ms: int,
  observation: string,
  intent: string
)
```

### `read_screen`

Take a fresh screenshot and OCR all visible text. Returns a plain-text dump of every label, button, field, and image alt-text on the screen. No coordinate info — just a readout of "what's written here". Useful when the agent is unsure what a button does or can't locate something by tapping.

```
read_screen(
  observation: string,
  intent: string
)
```

---

## Terminal tools

### `note_friction`

Flag a UX friction event. Emitted by the agent (or synthesized by the loop) to record a confusing moment.

```
note_friction(
  kind: string,  // one of the taxonomy in docs/PROMPTS/friction-vocab.md
  detail: string // plain-language description in the persona's voice
)
```

Common kinds: `ambiguous_label`, `dead_end`, `unresponsive_control`, `auth_required`, `missing_affordance`, `unexpected_layout`, `validation_unclear`. Full list in `docs/PROMPTS/friction-vocab.md`.

### `mark_goal_done`

Signal that the goal has been completed. The agent fills in an optional `summary` field describing what was accomplished.

```
mark_goal_done(
  summary: string // "I signed up with email alice@example.com and created a 'Groceries' list with three items."
)
```

Emitting this tool ends the run with `verdict: success`. If the agent gets stuck, the loop's cycle detector or step/token budgets will end with `failure` or `blocked` instead.

