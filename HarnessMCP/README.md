# HarnessMCP

A development-time **MCP server** that lets agents (Claude Code, etc.) drive Harness over
stdio: create personas / applications / actions / chains, stage credentials, start UI-testing
runs, and read back results + screenshots. It also exposes **step-level UI sessions** —
launch a target and observe/act on it directly, without the LLM loop and without any API key
(see [Step-level UI sessions](#step-level-ui-sessions-no-llm-loop-no-api-key)).

It is built exactly like `HarnessCLI` — the same `Harness/` source root minus the SwiftUI
surface — and reuses the same `RunCoordinator` and **on-disk** `RunHistoryStore` the GUI uses,
so anything created over MCP shows up in the Harness app (and vice versa).

## Build

```sh
xcodegen generate
xcodebuild -project Harness.xcodeproj -scheme HarnessMCP -configuration Debug \
  -derivedDataPath ./.build/derived build
```

Produces `./.build/derived/Build/Products/Debug/harness-mcp` (gitignored under `.build/`).

## Register

Already wired in `.mcp.json` as the `harness` server, pointing at the path above. Rebuild
after changing any source; restart your MCP client to pick up the new binary.

## Smoke test

```sh
HarnessMCP/smoke-test.sh
```

## Tools

| Tool | Purpose |
| --- | --- |
| `list_personas` / `create_persona` | The agent test-user profiles (`prompt_text` → `{{PERSONA}}`). |
| `list_applications` / `create_application` | Run targets: web URL, iOS Simulator app, or macOS `.app`. |
| `list_actions` / `create_action` | Reusable task prompts. |
| `list_action_chains` / `create_action_chain` | Ordered multi-leg runs over Actions. |
| `stage_credential` | Login for an Application (password → **Keychain only**). |
| `start_run` | Start an autonomous run; returns a `run_id` immediately. |
| `get_run_status` / `list_runs` | Poll live status / list recent runs. |
| `get_run_result` / `get_step_screenshot` | Verdict + summary + cost; per-step PNG. |
| `list_agent_tools` | Introspect the UI-driving tools per platform. |

### Step-level UI sessions (no LLM loop, no API key)

For an external MCP client that wants to drive a target itself — **see** it and **act** on
it — without Harness's autonomous agent. These tools launch a target, return marked
screenshots + a Set-of-Mark table, and dispatch one action at a time. **No API key is ever
required on this path** (`EnvKeychain` is untouched).

| Tool | Purpose |
| --- | --- |
| `start_ui_session` | Launch a target and open a session. `platform`: `web` (`url` + optional `viewport` = `desktop`/`mobile`), `ios` (`project_path` + `scheme` + `simulator_udid`), or `macos` (`app_path` to a built `.app` — the preferred QA flow — **or** `project_path` + `scheme`; contained backend, so the real pointer never moves and focus is never stolen; ending the session quits the app). Optional `artifact_dir` (**absolute**; relative rejected). Web also accepts `visible: true` (show the window for a human) and `session_state` (inject cookies / `localStorage`) — see [Authenticated apps](#authenticated-apps-session_state--visible). Blocks until ready (iOS/macOS builds take minutes) but is wedge-proof. Returns `session_id`, `display_label`, `point_size`, `platform`. |
| `observe_ui` | Capture the current screen. Returns the **marked** PNG (numbered badges over interactive elements, downscaled to point size) as image content + a text block with the `id → label (role)` mark table, point size, and session label — **plus `structuredContent`** carrying the same marks as machine-readable rects (see below). `clean: true` returns the unmarked frame. |
| `act_ui` | Perform one action (`tool` = `tap`, `tap_mark`, `double_tap`, `type`, `key_shortcut`, `scroll`, `swipe` (iOS), `navigate`/`back`/`forward`/`refresh` (web), `press_button` (iOS), `right_click`, `wait`), pass that tool's args at the top level, then auto-observe. Returns the same payload as `observe_ui`, `structuredContent` included. Meta tools (`read_screen` / `note_friction` / `mark_goal_done`) are rejected. |
| `end_ui_session` | Tear down the target. Idempotent — an unknown/closed id returns a calm `already closed`. |
| `list_ui_sessions` | Open sessions: id, platform, label, created time, idle seconds. |
| `export_ui_session_state` | **Web only.** The live session's cookies + current-origin `localStorage`, in exactly the shape `session_state` accepts. **The result is SENSITIVE** — see [Authenticated apps](#authenticated-apps-session_state--visible). |

**Structured observation (`structuredContent`).** `observe_ui` and `act_ui` also return an MCP
`structuredContent` object matching the `outputSchema` they advertise in `tools/list`. It carries
the geometry the badges were drawn from, which the prose mark table discards — for callout
annotation, element-scoped visual diffs, and resolving an intent to a target by position:

```json
{
  "session_id": "77F248B2-8679-4CC2-9C39-45E36570276B",
  "step": 1,
  "point_size": { "width": 1280, "height": 800 },
  "marks": [
    { "id": 1, "label": "name field", "role": "input", "label_source": "aria-label",
      "rect": { "x": 40, "y": 116, "width": 264, "height": 41 } },
    { "id": 2, "label": "waiting", "role": "button", "label_source": "text",
      "rect": { "x": 320, "y": 116, "width": 220, "height": 41 } },
    { "id": 3, "label": "Your Email *", "role": "input", "label_source": "label",
      "rect": { "x": 40, "y": 180, "width": 264, "height": 41 } }
  ],
  "page_text": "Harness UI Session Smoke Fixture\n\nFocus the field, type, …"
}
```

- **Coordinate space.** `rect` and `point_size` are both in the platform's **point** space — CSS
  pixels for web, simulator points for iOS, window points for macOS — the same space `tap(x, y)`
  takes. **Not** the screenshot's pixel space, which differs by the device scale factor.
- **`marks`** is the same list, in the same order and with the same ids, that the text mark table
  and the drawn badges come from. Always present; `[]` when the probe found nothing.
- **`label_source`** (web only) names WHERE each mark's `label` came from, so a client can prefer
  stable sources. The web probe resolves an accessible name in this order — and reports which step
  won: `aria-label` → `labelledby` (an `aria-labelledby` reference, resolved to its text) → `label`
  (an associated `<label for>` or a wrapping `<label>`) → `placeholder` → `title` → `value` →
  `text` (the element's own visible text) → `name` (the `name` attribute) → `none`.
  **`placeholder` and `value` are sample data** — they change whenever a designer edits the copy,
  so a resolver that wants a durable selector should treat them as weak and prefer the first three.
  (Before this ordering, a field with `<label for="name">Your Name *</label>` and
  `placeholder="John Doe"` was labelled "John Doe".) **iOS and macOS omit the key entirely**: their
  accessibility probes resolve a name without recording its provenance, and inventing one would be
  a guess.
- **`page_text`** is the frame's visible text, whitespace-normalized and capped at **20 000**
  characters (a trailing `…` marks truncation). **Web sessions only** — it comes from an
  `innerText` read of the rendered document. **iOS and macOS omit the key entirely**: their
  accessibility probes yield per-element labels, not a screen text roll-up, and Harness does not
  walk the AX tree a second time to synthesize one. An absent key means "not available on this
  platform", which is not the same claim as "the screen has no text".
- **Back-compatible.** The `image` and `text` content blocks are unchanged;
  `structuredContent` is an additive sibling field on the `tools/call` result that clients which
  don't know it ignore. A failed `act_ui` still returns `structuredContent` alongside
  `isError: true`, so the caller sees current state as well as the failure.

#### When `act_ui` returns — the settle contract

`act_ui` performs its action and then auto-observes. Between the two it waits for the page to
stop changing, with a per-class envelope:

| Action class | Wait |
| --- | --- |
| `navigate` / `back` / `forward` / `refresh`, and any click that changed `location.href` | DOM quiet 600ms, floor 600ms, ceiling 8s, and at least one structural (`childList`) mutation must have been seen — a React Suspense lull is not "settled" |
| Everything else (`tap`, `tap_mark`, `type`, `scroll`, `key_shortcut`, …) | DOM quiet 250ms, floor 250ms, ceiling 3s, **and** no tracked async work still in flight |

For that second class, observation is armed **before** the action is dispatched, and the gate also
waits for the page's own pending work to drain: `setTimeout` callbacks scheduled with a delay
≤ 2000ms, in-flight `fetch`, and in-flight `XMLHttpRequest`. `setInterval` and
`requestAnimationFrame` are deliberately not tracked (a polling loop or an animation never drains,
and gating on one would pin every settle to its ceiling).

Why: a same-URL state swap — a React form that awaits a POST and then renders a success screen —
used to return the **pre-action** frame. The observer was armed after the click, and its only test
was "quiet for 250ms", which a page that has not reacted *yet* passes exactly like a page that
never will. A page with genuinely nothing in flight still returns at the 250ms floor, so idle
pages are not slowed down.

#### Authenticated apps (`session_state` / `visible`)

Web sessions run on a **non-persistent** `WKWebsiteDataStore`: every session is a fresh user, with
nothing inherited and nothing written to disk. That is deliberate and it is still the default.
It also means an SSO-only product is unreachable — there is no password to type.

The way through, for **web sessions only**:

1. `start_ui_session({ platform: "web", url, visible: true })` — the session's window comes on
   screen (titled, key, accepting real mouse + keyboard input) instead of sitting off-view at
   alpha 0.
2. A **human** logs in in that window — password, SSO redirect, MFA, whatever the product needs.
3. `export_ui_session_state({ session_id })` → the resulting cookies plus the current origin's
   `localStorage`.
4. The client stores that securely — a secret manager or the macOS Keychain. **Not** a repo file,
   not a log, not a saved transcript.
5. Later, headless runs pass it straight back:

```jsonc
start_ui_session({
  "platform": "web",
  "url": "https://app.example.com/dashboard",
  "session_state": {
    "cookies": [
      { "name": "session", "value": "…", "domain": ".example.com", "path": "/",
        "expires": 1800000000, "secure": true, "httpOnly": true }
    ],
    "origins": [
      { "origin": "https://app.example.com",
        "localStorage": [ { "name": "auth.token", "value": "…" } ] }
    ]
  }
})
```

`export_ui_session_state` returns exactly the shape `session_state` accepts, so an export
round-trips into an injection with no transformation on the client side.

**What is injected, and when.** Cookies go into the session's cookie store **before the first
navigation**, so the very first request already carries them. Each `origins` entry costs one extra
page load at start (`localStorage` is only reachable from a document on that origin) — a
cookie-only state costs none. Only `name`, `value`, and `domain` are required per cookie; `path`
defaults to `/`, `expires` is epoch **seconds** and omitting it makes a session cookie.

**Secret handling.** Cookie and `localStorage` values are login credentials, and are treated the
way `fill_credential`'s password is:

- **Never logged.** Harness logs counts (`3 cookie(s), 1 origin(s) / 2 localStorage item(s) —
  values redacted`), never values. The value types' `description` is redacted by construction, so
  an accidental interpolation in some future log line still cannot leak one.
- **Never in `steps.jsonl`.** The artifact writer records `act_ui` calls; `session_state` rides on
  `start_ui_session`, which writes no row at all. `export_ui_session_state` writes none either.
- **Never in a tool result** — except `export_ui_session_state`, whose entire job is to return
  them, and which flags itself `"sensitive": true`.
- **Never on disk.** The data store stays non-persistent: injected state lives in memory and dies
  with the session.

**The fresh-user invariant is untouched.** A session started without `session_state` inherits
nothing — not from the machine's browsers, not from a previous session, not from a sibling session
that injected state. The live smoke asserts exactly this.

`session_state` and `visible` are rejected (with a clear error) on `ios` / `macos` sessions rather
than silently ignored, and `export_ui_session_state` is web-only for the same reason: a native app
has no cookie jar to seed or export.

**Artifacts.** When `artifact_dir` is set (absolute path), each observation's **CLEAN** frame is
written to `<artifact_dir>/steps/NNN.png` and a row is appended to `<artifact_dir>/steps.jsonl`
(timestamp, tool call + input, screenshot ref, result summary, point size, mark count). No
`artifact_dir` → a temp dir under Harness's runs root. The **marked** image never touches disk —
it lives only in the MCP `image` content channel (the "no agent scaffolding on disk" invariant,
`standards/14-run-logging-format.md` §6).

**Limits & knobs.**

- **Concurrent-session cap: 2** — a clear error beyond it; `end_ui_session` to make room.
- **Idle teardown** — a session with no observe/act for `HARNESS_UI_SESSION_IDLE_TIMEOUT_SECONDS`
  (default **600**; `0` disables) is auto-torn-down. All sessions are also torn down on server
  shutdown (stdin close).
- **Start timeout** — `start_ui_session` is bounded by `HARNESS_UI_SESSION_START_TIMEOUT_SECONDS`
  (default: web **120s**, iOS **900s**) so a hung build/load can't wedge the read loop.
- **Sessions use an in-memory store** — they never write run rows, so a locked GUI store doesn't
  gate them.

Smoke test (serves a local fixture, drives a real web session start→observe→act→end):

```sh
HarnessMCP/ui-session-smoke.sh
```

## Running standalone

`harness-mcp` is a **relocatable** stdio binary. Copy it anywhere — eventually
bundled inside a consuming app — and run it from any working directory; it makes
no assumption that its own source checkout is present. This is how another
product (e.g. an external QA agent) consumes it.

### Identity — `--version` / `--help`

```sh
harness-mcp --version   # → "harness-mcp 0.8.0"  (stdout, exit 0)
harness-mcp --help      # → one-line usage note   (stdout, exit 0)
```

`--version` prints the **same** `name version` the MCP `initialize` handshake
reports in `serverInfo` (single source of truth: `MCPServerIdentity`), so a
consuming product can sanity-check a bundled binary without launching it.
**Neither flag starts the app run loop** — they print and exit. With no
recognized flag the binary serves MCP JSON-RPC over stdin/stdout (the default;
an unrecognized flag is ignored and still serves).

### Web sessions — zero setup

Web UI sessions (`start_ui_session` `platform:"web"`) need nothing beyond the
binary: no repo checkout, no Xcode. A copied-out binary drives a real WKWebView
session end-to-end. (Cloud LLM *runs* still need an API key; the step-level UI
session tools never do.)

### iOS sessions — WebDriverAgent source resolution

iOS sessions build WebDriverAgent from source. The binary resolves that source
in precedence order:

1. **`HARNESS_WDA_PATH`** (env override — highest precedence): an absolute path
   to a WebDriverAgent checkout (the directory that contains
   `WebDriverAgent.xcodeproj`). `~` is expanded. A **set-but-invalid** value is
   a loud, actionable error — never a silent fall-through to the paths below.
2. **`WebDriverAgent/` beside the binary** — a folder shipped next to the binary
   or inside the `.app` bundle (`Bundle.main.resourceURL/WebDriverAgent`).
3. **`<repoRoot>/vendor/WebDriverAgent`** — only resolves from a developer
   checkout.

A consuming product with iOS support must **point `HARNESS_WDA_PATH` at a WDA
checkout it bundles** (or ship `WebDriverAgent/` beside the binary). When none
resolves, `start_ui_session` `platform:"ios"` returns a clear per-tool error
telling the operator to set `HARNESS_WDA_PATH` — never a crash or a wedge.

iOS args: `project_path` + `scheme` + `simulator_udid` (all required; pick a
udid via `xcrun simctl list devices available -j`). Optional `simulator_runtime`
(e.g. `"iOS 27.0"`) names the WDA build-cache directory. WDA's **first** build
for a given iOS version takes minutes; later sessions hit the cache at
`~/Library/Application Support/Harness/wda-build/iOS-<version>/`.

### Graceful degradation without Xcode

On a host without usable Xcode command-line tooling — no `xcodebuild`, or a
`DEVELOPER_DIR` that points nowhere — **web sessions keep working end-to-end**,
and `start_ui_session` `platform:"ios"` returns a clean per-tool error naming
the missing tool (`… missing: xcodebuild … Web sessions work without it.`). The
tooling probe reports missing tools without throwing, so it never crashes or
wedges the server; iOS simply degrades to a clear error while web is unaffected.

### What a consuming app must ship / point at

| Capability | Requirement |
| --- | --- |
| Web sessions | The `harness-mcp` binary only. No repo, no Xcode. |
| iOS sessions | Xcode + an iOS simulator on the host; a WebDriverAgent checkout with `HARNESS_WDA_PATH` set to it (or `WebDriverAgent/` beside the binary). |
| Version check | `harness-mcp --version` (exit 0); matches the handshake `serverInfo`. |

### Reproduce the relocated web proof

`ui-session-smoke.sh` / `ui-session-smoke.py` take an optional **absolute**
fixture dir, so a copied-out binary can be driven against an out-of-repo fixture
from a non-repo cwd:

```sh
mkdir -p /tmp/standalone/bin /tmp/standalone/fixtures
cp .build/derived/Build/Products/Debug/harness-mcp /tmp/standalone/bin/
cp HarnessMCP/fixtures/ui-session-fixture.html      /tmp/standalone/fixtures/
python3 "$PWD/HarnessMCP/ui-session-smoke.py" \
  /tmp/standalone/bin/harness-mcp /tmp/standalone/fixtures
```

A minimal iOS fixture app for the iOS proof lives at
`HarnessMCP/fixtures/ios-app/` (regenerate its `.xcodeproj` with
`cd HarnessMCP/fixtures/ios-app && xcodegen generate`).

## Notes & limits (v1)

- **Autonomous runs only** — no per-step approval gate yet (feeding `UserApproval` over MCP is
  a clean follow-up).
- **Cloud models need an API key**: set it in Harness → Settings, or export
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` before launching the server.
  `start_run` fails fast with a clear message if the key is missing.
- **Built-in personas** are seeded by the GUI app at launch. Run the app once, or just use
  `create_persona`.
- **Shared store, two processes**: while both the GUI and `harness-mcp` hold the SwiftData
  store open, there is no live cross-process refresh (SQLite WAL prevents corruption; the GUI
  re-fetches on view appearance). An in-app embedded server would be the path to live
  co-presence.
- **macOS-app runs** trigger per-binary Screen Recording / Accessibility prompts the first
  time (same as `harness-cli`); web runs need no such grant.
