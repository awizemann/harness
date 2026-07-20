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
