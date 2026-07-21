# Harness 0.7.0 — Agents drive the target directly (MCP UI sessions), and a standalone `harness-mcp`

0.6 opened Harness to agents with an **MCP server** that runs autonomous goals against the app's own store. 0.7 goes a level deeper: agents can now **drive a web or iOS target directly — see it, act on it, one step at a time — with no LLM loop and no API key**. And the `harness-mcp` binary becomes **standalone and relocatable**, so another product can bundle it and run it from anywhere.

## Highlights

### Step-level UI sessions — see and act, no LLM loop, no API key

Five new `harness-mcp` tools let an external MCP client drive a target *itself*, instead of handing a goal to Harness's autonomous agent:

- **`start_ui_session`** — launch a **web** (`url` + optional `viewport`) or **iOS Simulator** (`project_path` + `scheme` + `simulator_udid`) target and open a session. Blocks until ready (iOS builds take minutes) but is wedge-proof. `macos` returns a clear "deferred" error.
- **`observe_ui`** — capture the current screen. Returns the **Set-of-Mark** PNG (numbered badges over interactive elements, downscaled to point size) as image content, plus a text block with the `id → label (role)` mark table. `clean: true` returns the unmarked frame.
- **`act_ui`** — perform **one** action from the platform's tool vocabulary (`tap` / `tap_mark` / `type` / `scroll` / `swipe` / `navigate` / …), validated against that platform, then auto-observe. A failed execute is flagged as an error.
- **`end_ui_session`** — tear down the target (idempotent — an unknown/closed id returns a calm `already closed`).
- **`list_ui_sessions`** — open sessions with id, platform, label, and idle seconds.

**No API key is ever required on this path** — the credential Keychain is untouched. A `UISessionSupervisor` actor keeps it safe: a **concurrent-session cap of 2**, **idle teardown** (default 600s, `HARNESS_UI_SESSION_IDLE_TIMEOUT_SECONDS`), a **bounded start** so a hung build/load can't wedge the read loop (`HARNESS_UI_SESSION_START_TIMEOUT_SECONDS`), and idempotent teardown of every session on server shutdown. Sessions use an **in-memory store**, so a locked GUI store never gates them.

Each observation's **clean** frame is written to `<artifact_dir>/steps/NNN.png` with a row appended to `steps.jsonl`; the **marked** image lives only in the MCP image channel and never touches disk — the "no agent scaffolding on disk" invariant from Standard 14 §6.

### `harness-mcp` is now standalone and relocatable

The binary can be **copied anywhere and run from any working directory** — eventually bundled inside a consuming product (e.g. an external QA agent). It no longer assumes its own source checkout is present.

- **`--version` / `--help`** are parsed *before* the app run loop spins up, so they never hang. `--version` prints the **same** `name version` the MCP `initialize` handshake reports in `serverInfo` (single source of truth: `MCPServerIdentity`), so a consuming product can sanity-check a bundled binary without launching it.
- **Web sessions need nothing but the binary** — no repo checkout, no Xcode. A copied-out binary drives a real WKWebView session end-to-end.
- **iOS WebDriverAgent source resolution** in precedence order: **`HARNESS_WDA_PATH`** (env override; `~` expanded; a set-but-invalid value is a loud, actionable error, never a silent fall-through) → **`WebDriverAgent/` beside the binary** (or inside the `.app` bundle) → **`<repoRoot>/vendor/WebDriverAgent`** (developer checkouts only). When none resolves, an iOS start returns a clear per-tool error telling the operator to set `HARNESS_WDA_PATH` — never a crash or a wedge.
- **Graceful degradation without Xcode** — on a host with no usable `xcodebuild`, **web sessions keep working end-to-end** while an iOS start returns a clean per-tool error naming the missing tool. The tooling probe reports what's missing without throwing, so it can't crash or wedge the server.

Full env vars, flags, and consuming-app requirements are documented in [`HarnessMCP/README.md` → Running standalone](https://github.com/awizemann/harness/blob/main/HarnessMCP/README.md#running-standalone).

### Under the hood

- Fixed a pre-existing Swift 6 region-isolation build error in `RunCoordinator.popNextApproval` (a `Sendable` iterator box; behaviour unchanged) that had blocked all builds and tests on the current toolchain.
- The release scripts (`release.sh` / `appcast.sh`) gained an Xcode-toolchain guard that resolves a real `Xcode.app` via `DEVELOPER_DIR` (no `sudo`), surviving an Xcode swap that left `xcode-select` pointed at the Command Line Tools.
- **275 unit tests passing** (+46 across this release's two feature commits), plus live web smoke proofs for the UI-session lifecycle and for the relocated / stripped-Xcode standalone paths.

---

Architecture notes, gotchas, and the full tool schema live in the repo's memory tier and the [wiki](https://github.com/awizemann/harness/wiki).
