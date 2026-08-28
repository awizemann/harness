# HarnessMCP

`harness-mcp` is a stdio **MCP** (Model Context Protocol) server that lets an external agent — Claude Code, or any MCP client — drive Harness without the GUI. It's built from the same `Harness/` source root as the app and the CLI (minus the SwiftUI surface) and reuses the same `RunCoordinator`, platform adapters, and on-disk `RunHistoryStore` the app uses — so anything created over MCP shows up in the Harness app, and vice-versa.

Lives alongside `Harness` / `HarnessTests` / `HarnessCLI` as an xcodegen target; produces a `harness-mcp` Mach-O binary. Registered in [`.mcp.json`](https://github.com/awizemann/harness/blob/main/.mcp.json) as the `harness` server. Full env-var / flag reference lives in [`HarnessMCP/README.md`](https://github.com/awizemann/harness/blob/main/HarnessMCP/README.md).

> **Status**: a development-time tool that grew a **standalone** path in 0.7 — the binary is relocatable and can be bundled into another product. Cloud *runs* still need an API key; the step-level UI sessions never do.

## Two ways to drive

harness-mcp exposes two distinct surfaces over the same engine:

1. **Autonomous runs (0.6)** — hand the agent loop a goal and let Harness's LLM agent pursue it end-to-end, then read back verdict + friction + per-step screenshots. Runs surface as first-class, badged history in the GUI. See [Autonomous-run tools](#autonomous-run-tools).
2. **Step-level UI sessions (0.7)** — the client drives the target itself, seeing the screen and acting on it one step at a time, with **no LLM loop and no API key**. See [Step-level UI sessions](#step-level-ui-sessions).

## Autonomous-run tools

Register the server in your MCP client and an agent can compose and launch real user-test runs against the shared store:

| Tool | Purpose |
| --- | --- |
| `list_personas` / `create_persona` | Agent test-user profiles (`prompt_text` → `{{PERSONA}}`). |
| `list_applications` / `create_application` | Run targets: web URL, iOS Simulator app, or macOS `.app`. |
| `list_actions` / `create_action` | Reusable task prompts. |
| `list_action_chains` / `create_action_chain` | Ordered multi-leg runs over Actions. |
| `stage_credential` | Login for an Application (password → **Keychain only**, never the model's context or the log). |
| `start_run` | Start an autonomous run; returns a `run_id` immediately. |
| `get_run_status` / `list_runs` | Poll live status / list recent runs. |
| `get_run_result` / `get_step_screenshot` | Verdict + summary + cost; per-step PNG. |
| `cancel_run` | Cancel a live run (an idle watchdog also auto-cancels a wedged one). |
| `list_agent_tools` | Introspect the UI-driving tools per platform (see [Tool-Schema](Tool-Schema)). |

Runs execute asynchronously under a supervisor with an **idle watchdog** that auto-cancels a wedged run — the backstop the step budget can't be. Because the app and the server are separate processes sharing one store, the app watches a per-run marker file the server writes and refreshes History the moment a run finishes.

**Cloud models need an API key** on this path: set it in Harness → Settings, or export `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` before launching the server. `start_run` fails fast with a clear message if the key is missing.

## Step-level UI sessions

_New in 0.7._ For a client that wants to drive a target **itself** — see it and act on it — without Harness's autonomous agent. These tools launch a target, return marked screenshots plus a Set-of-Mark table, and dispatch one action at a time. **No API key is ever required on this path** (the credential Keychain is untouched).

| Tool | Purpose |
| --- | --- |
| `start_ui_session` | Launch a target and open a session. `platform`: `web` (`url` + optional `viewport` = `desktop`/`mobile`) or `ios` (`project_path` + `scheme` + `simulator_udid`; `macos` → a clear "deferred" error). Optional `artifact_dir` (**absolute**; relative rejected). Blocks until ready (iOS builds take minutes) but is wedge-proof. Returns `session_id`, `display_label`, `point_size`, `platform`. |
| `observe_ui` | Capture the current screen. Returns the **marked** PNG (numbered badges over interactive elements, downscaled to point size) as image content, plus a text block with the `id → label (role)` mark table — and a `structuredContent` object with the same marks as rects (see [Structured observation](#structured-observation)). `clean: true` returns the unmarked frame. |
| `act_ui` | Perform **one** action (`tap`, `tap_mark`, `double_tap`, `type`, `key_shortcut`, `scroll`, `swipe` (iOS), `navigate`/`back`/`forward`/`refresh` (web), `press_button` (iOS), `right_click`, `wait`), validated against the platform vocabulary, then auto-observe. A failed execute is flagged as an error. Meta tools (`read_screen` / `note_friction` / `mark_goal_done`) are rejected. |
| `end_ui_session` | Tear down the target. Idempotent — an unknown/closed id returns a calm `already closed`. |
| `list_ui_sessions` | Open sessions: id, platform, label, created time, idle seconds. |
| `export_ui_session_state` | **Web only.** The live session's cookies + current-origin `localStorage`, in the same shape `start_ui_session`'s `session_state` takes. **Sensitive** — see [Authenticated apps](#authenticated-apps--session-state). |

The action vocabulary `act_ui` validates against is the same per-platform contract the autonomous agent uses — see [Tool-Schema](Tool-Schema).

### Structured observation

_New in 0.8.0._ Alongside the image and text blocks, `observe_ui` and `act_ui` return an MCP `structuredContent` object matching the `outputSchema` they advertise in `tools/list`. The text mark table is written for a **vision model** (`id → "label" (role)`, no geometry); `structuredContent` is the machine-facing surface, carrying the rects the badges were drawn from:

```json
{
  "session_id": "77F248B2-…",
  "step": 1,
  "point_size": { "width": 1280, "height": 800 },
  "marks": [
    { "id": 1, "label": "name field", "role": "input", "label_source": "aria-label",
      "rect": { "x": 40, "y": 116, "width": 264, "height": 41 } }
  ],
  "page_text": "Harness UI Session Smoke Fixture\n\nFocus the field, type, …"
}
```

- **Coordinate space** — `rect` and `point_size` are both in **point** space (CSS pixels for web, simulator points for iOS, window points for macOS), the same space `tap(x, y)` takes; *not* the screenshot's pixel space, which differs by the scale factor. The rects come from the same `InteractiveMark` list [MarkRenderer](Web-Driver) draws the badges from, so ids match the table exactly.
- **`marks`** is always present — `[]` when the probe found nothing.
- **`label_source`** (web only, new in 0.8.1) names which rule produced the mark's `label`. The web probe resolves an accessible name in priority order — `aria-label` → `labelledby` → `label` (an associated `<label for>` or wrapping `<label>`) → `placeholder` → `title` → `value` → `text` → `name` → `none` — and reports the winner. Before this ordering the probe reached for `placeholder` second, so a field with `<label for="name">Your Name *</label>` and `placeholder="John Doe"` was labelled **"John Doe"**: downstream resolvers keyed on sample data and that text leaked into published guide alt text. Prefer the first three for durable selectors; `placeholder` and `value` move with copy edits. iOS and macOS omit the key — their probes resolve a name without provenance.
- **`page_text`** is the frame's visible text, whitespace-normalized and capped at 20 000 characters (trailing `…` marks truncation). **Web only**, from an `innerText` read of the rendered document. iOS and macOS **omit the key**: their AX/WDA probes yield per-element labels, not a screen text roll-up, and Harness does not walk the tree again to synthesize one. Absent means "not available on this platform", not "no text on screen".
- **Additive** — the `image` and `text` content blocks are byte-identical to before, so an existing client that ignores `structuredContent` sees the historical result. A failed `act_ui` returns it too, alongside `isError: true`.

### Settle: when `act_ui` returns

`act_ui` acts, waits for the page to stop changing, then observes. Two envelopes:

| Class | Wait |
| --- | --- |
| `navigate` / `back` / `forward` / `refresh`, plus any click that changed `location.href` | quiet 600ms, floor 600ms, ceiling 8s, **and** at least one `childList` mutation (a React Suspense lull is not "settled") |
| Every other action (`tap`, `tap_mark`, `type`, `scroll`, …) | quiet 250ms, floor 250ms, ceiling 3s, **and** no tracked async work in flight |

For the second class the MutationObserver is armed **before** the action is dispatched, and the gate also tracks the page's pending work — `setTimeout` ≤ 2000ms, in-flight `fetch`, in-flight `XMLHttpRequest`. (`setInterval` and `requestAnimationFrame` are not tracked: a polling loop never drains and would pin every settle to the ceiling.)

This fixed a real miss: a **same-URL** React state swap (form → success screen, landing ~500ms behind an awaited POST) returned the **pre-action** frame at ~481ms, while a route-changing tap settled correctly at 6.5s. The observer was armed after the click and its only test was "quiet for 250ms" — which a page that has not reacted *yet* passes exactly like a page that never will. A page with nothing in flight still returns at the 250ms floor, so idle pages pay nothing. Fixture: `HarnessMCP/fixtures/spa-settle-fixture.html`, asserted by the live smoke.

### Authenticated apps — session state

Web sessions run on a **non-persistent** `WKWebsiteDataStore`: a fresh user every time, nothing inherited, nothing on disk ([Web-Driver](Web-Driver)). That default stands. It also means an SSO-only product has no way in — there is no password to type.

The path through, **web only**:

1. `start_ui_session({ platform: "web", url, visible: true })` — the window comes on screen (titled, key, real mouse + keyboard) instead of sitting off-view at alpha 0. The MCP binary raises its activation policy from `.prohibited` to `.accessory` so the window can take key focus; still no Dock icon.
2. A **human** logs in there.
3. `export_ui_session_state({ session_id })` → cookies + the current origin's `localStorage`.
4. The client stores it in a secret manager / the Keychain — never a repo file or a log.
5. Later headless runs pass it back as `session_state`, which is injected into the (still non-persistent) store **before the first navigation**. Each `origins` entry costs one extra page load at start; a cookie-only state costs none.

**Secrets.** Cookie and `localStorage` values are credentials and follow the `fill_credential` precedent: never logged (counts only — `3 cookie(s), 1 origin(s) / 2 localStorage item(s) — values redacted`), never in `steps.jsonl`, never on disk, and never in a tool result except `export_ui_session_state`'s, which flags itself `"sensitive": true`. The value types render redacted `description`s so a future stray log interpolation still cannot leak one.

**The fresh-user invariant holds.** A session started without `session_state` inherits nothing — not from the machine's browsers, not from a previous session, not from a sibling session that injected state. The live smoke asserts it. `session_state` / `visible` / `export_ui_session_state` are rejected with a clear error on `ios` and `macos` sessions rather than silently ignored.

### Artifacts

When `artifact_dir` is set (absolute path), each observation's **clean** frame is written to `<artifact_dir>/steps/NNN.png` and a row is appended to `<artifact_dir>/steps.jsonl` (timestamp, tool call + input, screenshot ref, result summary, point size, mark count). With no `artifact_dir`, a temp dir under Harness's runs root is used. The **marked** image never touches disk — it lives only in the MCP `image` content channel. This is the "no agent scaffolding on disk" invariant from [`standards/14-run-logging-format.md`](https://github.com/awizemann/harness/blob/main/standards/14-run-logging-format.md) §6, the same one the GUI honours for [Set-of-Mark](Web-Driver) frames.

### Limits & knobs

`UISessionSupervisor` (a `Harness`-module actor, sibling to `RunSupervisor`) keeps sessions bounded and wedge-proof:

- **Concurrent-session cap: 2** — a clear error beyond it; `end_ui_session` to make room.
- **Idle teardown** — a session with no observe/act for `HARNESS_UI_SESSION_IDLE_TIMEOUT_SECONDS` (default **600**; `0` disables) is auto-torn-down. All sessions are also torn down on server shutdown (stdin close).
- **Start timeout** — `start_ui_session` is bounded by `HARNESS_UI_SESSION_START_TIMEOUT_SECONDS` (default: web **120s**, iOS **900s**) so a hung build/load can't wedge the read loop.
- **In-memory store** — sessions never write run rows, so a locked GUI store doesn't gate them, and no `LLMClient` / `RunCoordinator` / API key sits on this path.

## Running standalone

_New in 0.7._ `harness-mcp` is **relocatable**: copy the binary anywhere — eventually bundled inside a consuming app — and run it from any working directory; it makes no assumption that its own source checkout is present.

- **`--version` / `--help`** are parsed *before* any `NSApplication` bring-up, so they never spin the run loop. `--version` prints the **same** `name version` the MCP `initialize` handshake reports in `serverInfo` (single source of truth: `MCPServerIdentity` in `Harness/Core/`), so a consuming product can sanity-check a bundled binary without launching it.
- **Web sessions need nothing but the binary** — no repo checkout, no Xcode. A copied-out binary drives a real WKWebView session end-to-end.
- **iOS WebDriverAgent source resolution** runs in precedence order — a set-but-invalid override is a loud, actionable error, never a silent fall-through:
  1. **`HARNESS_WDA_PATH`** — an absolute path to a WebDriverAgent checkout (the dir containing `WebDriverAgent.xcodeproj`); `~` is expanded.
  2. **`WebDriverAgent/` beside the binary** — a folder shipped next to the binary or inside the `.app` bundle (`Bundle.main.resourceURL`).
  3. **`<repoRoot>/vendor/WebDriverAgent`** — resolves only from a developer checkout.

  When none resolves, an iOS start returns a clear per-tool error telling the operator to set `HARNESS_WDA_PATH` — never a crash or a wedge.
- **Graceful degradation without Xcode** — on a host with no usable `xcodebuild`, **web sessions keep working end-to-end** while an iOS start returns a clean per-tool error naming the missing tool. The tooling probe reports what's missing without throwing, so it can't crash or wedge the server.

| Capability | What a consuming app must ship / point at |
| --- | --- |
| Web sessions | The `harness-mcp` binary only. No repo, no Xcode. |
| iOS sessions | Xcode + an iOS simulator on the host; a WebDriverAgent checkout with `HARNESS_WDA_PATH` set to it (or `WebDriverAgent/` beside the binary). |
| Version check | `harness-mcp --version` (exit 0); matches the handshake `serverInfo`. |

## How it wires together

- **`AdapterUISessionPreparer`** (in `HarnessMCP/`) builds the real web/iOS adapter with an in-memory store — no `LLMClient`, `RunCoordinator`, or API key on the step-level path.
- **`UISessionSupervisor` / `UISessionSupport`** live in the `Harness/` module (not `HarnessMCP/`), so the whole session surface is unit-testable via `@testable import Harness` — the `HarnessMCP/` target itself is not in the test graph. Same reason `MCPServerIdentity` and the flag parser live in `Harness/Core/`.
- The autonomous-run path reuses `RunBuilder` + `RunCoordinator` exactly as the GUI does; the step-level path bypasses both.

## Build

```bash
xcodegen generate                                             # only after project.yml changes
xcodebuild -project Harness.xcodeproj -scheme HarnessMCP \
  -configuration Debug -derivedDataPath ./.build/derived build
```

Produces `./.build/derived/Build/Products/Debug/harness-mcp` (gitignored under `.build/`). Rebuild after changing any source; restart your MCP client to pick up the new binary. Smoke tests: `HarnessMCP/smoke-test.sh` (full tool surface) and `HarnessMCP/ui-session-smoke.sh` (drives a real web session start→observe→act→end against a local fixture).

## Notes & limits

- **Autonomous runs are one-shot** — no per-step approval gate over MCP yet (feeding `UserApproval` over the wire is a clean follow-up).
- **Built-in personas** are seeded by the GUI app at launch. Run the app once, or use `create_persona`.
- **Shared store, two processes** — while both the GUI and `harness-mcp` hold the SwiftData store open there's no live cross-process refresh beyond the per-run marker file (SQLite WAL prevents corruption; the GUI re-fetches on view appearance). An in-app embedded server would be the path to live co-presence.
- **macOS-app runs** trigger per-binary Screen Recording / Accessibility prompts the first time (same as `harness-cli`); web runs need no such grant. Step-level `macos` sessions are deferred.

## See also

- [`HarnessMCP/README.md`](https://github.com/awizemann/harness/blob/main/HarnessMCP/README.md) — exhaustive env-var / flag / standalone reference.
- [HarnessCLI](HarnessCLI) — the sibling dev-time driver (same shared source, command-line instead of MCP).
- [Tool-Schema](Tool-Schema) — the per-platform action vocabulary `act_ui` and the agent share.
- [Agent-Loop](Agent-Loop) — how the autonomous run path thinks.
- [Run-Replay-Format](Run-Replay-Format) — the JSONL schema autonomous runs write.

---
_Last updated: 2026-07-21 — v0.7.0 (step-level UI sessions + standalone harness-mcp)_
