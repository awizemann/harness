# HarnessMCP

A development-time **MCP server** that lets agents (Claude Code, etc.) drive Harness over
stdio: create personas / applications / actions / chains, stage credentials, start UI-testing
runs, and read back results + screenshots.

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
