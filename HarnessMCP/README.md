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
it — without Harness's autonomous agent. These five tools launch a target, return marked
screenshots + a Set-of-Mark table, and dispatch one action at a time. **No API key is ever
required on this path** (`EnvKeychain` is untouched).

| Tool | Purpose |
| --- | --- |
| `start_ui_session` | Launch a target and open a session. `platform`: `web` (`url` + optional `viewport` = `desktop`/`mobile`) or `ios` (`project_path` + `scheme` + `simulator_udid`; `macos` → clear "deferred" error). Optional `artifact_dir` (**absolute**; relative rejected). Blocks until ready (iOS builds take minutes) but is wedge-proof. Returns `session_id`, `display_label`, `point_size`, `platform`. |
| `observe_ui` | Capture the current screen. Returns the **marked** PNG (numbered badges over interactive elements, downscaled to point size) as image content + a text block with the `id → label (role)` mark table, point size, and session label. `clean: true` returns the unmarked frame. |
| `act_ui` | Perform one action (`tool` = `tap`, `tap_mark`, `double_tap`, `type`, `key_shortcut`, `scroll`, `swipe` (iOS), `navigate`/`back`/`forward`/`refresh` (web), `press_button` (iOS), `right_click`, `wait`), pass that tool's args at the top level, then auto-observe. Meta tools (`read_screen` / `note_friction` / `mark_goal_done`) are rejected. |
| `end_ui_session` | Tear down the target. Idempotent — an unknown/closed id returns a calm `already closed`. |
| `list_ui_sessions` | Open sessions: id, platform, label, created time, idle seconds. |

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
harness-mcp --version   # → "harness-mcp 0.7.0"  (stdout, exit 0)
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
