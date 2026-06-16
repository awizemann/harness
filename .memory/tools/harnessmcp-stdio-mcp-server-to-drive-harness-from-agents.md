---
title: HarnessMCP: Stdio MCP Server to Drive Harness from Agents
type: note
permalink: harness/tools/harnessmcp-stdio-mcp-server-to-drive-harness-from-agents
tags:
- mcp
- tooling
- cli
- architecture
---

## Observations
- [tool] HarnessMCP (new, v0.5): development-time stdio MCP server. New xcodegen `tool` target `harness-mcp`, built exactly like HarnessCLI — shares all of `Harness/` minus the SwiftUI/App surface. Entry point `HarnessMCP/Main.swift` pumps `NSApplication.run()` for WKWebView callbacks. #mcp #tooling
- [architecture] Hand-rolled JSON-RPC 2.0 over stdio (newline-delimited); zero new SPM deps. All logic inside one `MCPServer` actor; stdout = protocol, stderr = logs. Runs driven on detached tasks via `RunSupervisor` so the read loop never blocks. #architecture
- [persistence] Opens the GUI's on-disk SwiftData store via `RunHistoryStore.at(url:)` (`resetOnMigrationFailure:false`), so MCP-created data appears in the app and vice versa. #persistence
- [verified] Shared store CONFIRMED: app NOT sandboxed (`Harness.entitlements` app-sandbox=false) → GUI + harness-mcp both use `~/Library/Application Support/Harness/history.store`. Cross-process *fresh fetches* see each other's commits in real time (proven). The "no live refresh" caveat is only SwiftUI `@Query` auto-update. RunHistoryView reloads via `.task { reload() }` (manual fetch), so MCP runs DO appear in History on open/refresh. #persistence
- [seeding] harness-mcp seeds built-in personas on first tool call (idempotent, mirrors `AppContainer.bootstrapPersonas()`), guarded by `didSeedBuiltIns`. #seeding
- [tooling] 16 tools. v1.1 added `cancel_run` (manual abort) + an idle WATCHDOG in `RunSupervisor`: auto-cancels a run after `idle_timeout_seconds` with no `RunEvent` (default 180s, configurable on start_run, 0=off) — the backstop the step budget can't be (budget is only checked at the top of `runLeg`). Also `get_run_result` now reports live status for in-flight runs instead of the skeleton-zeros record. #tools
- [gotcha] start_run resolves persona_id -> `PersonaSnapshot.promptText` into `RunRequest.persona` (the `{{PERSONA}}` slot). It carries prompt TEXT, not a name. #gotcha
- [gotcha] Cloud runs read the API key via EnvKeychain: env var FIRST, then the GUI's Keychain item (owned by the GUI binary → a first read from harness-mcp can pop a macOS prompt; click Always Allow, or export the key in the client's env). #credentials
- [gotcha] While a run is in flight the persisted RunRecord is the skeleton (0 steps/tokens, no verdict) until `markCompleted`. `get_run_status` (in-process supervisor) is the real-time truth; `get_run_result` now detects in-flight and returns live status. #gotcha
- [finding] First real test (travelsynch.com, first-time-user persona, haiku, 2026-06-16): 12 clean steps in ~66s (landing → features → testimonials → pricing, 0 friction), then HUNG on a step-13 `tap_mark` of "Start Free Trial". Root cause: the web driver's post-action settle/load-wait has NO hard timeout, so a navigating click whose page never finishes loading freezes the run between `tool_result` and `step_completed`. Belongs in the web driver (`WebPlatformAdapter`/`WebDriver` settle/awaitNextLoad); affects GUI runs too. MCP watchdog + cancel_run are the backstops. Spawned a task to add the driver-level timeout. #finding
- [planned] App-side MCP-activity indicator approved (placement: BOTH global banner + sidebar 'Agent Sessions'; liveness: live step counter). Plan: harness-mcp writes an active-session marker file the GUI watches; same signal auto-refreshes RunHistory. Live screenshot mirror (tail events.jsonl + reuse RunReplay) is a follow-up. Needs design-tier consult before SwiftUI. #roadmap
- [build] `.mcp.json` server `harness`; binary `./.build/derived/Build/Products/Debug/harness-mcp` (gitignored). Build: `xcodegen generate` + `xcodebuild -scheme HarnessMCP -derivedDataPath ./.build/derived`. Smoke: `HarnessMCP/smoke-test.sh`. #build

## Relations
- relates_to [[HarnessCLI: Development-Time Driver — Shared Source, Same Artifacts]]
- relates_to [[Run Lifecycle & Orchestration]]
- relates_to [[Per-Application Credentials & Persona Library]]
- relates_to [[Platform Drivers — iOS, macOS, Web]]


## Audit findings & fixes (2026-06-16, multi-agent fresh-eyes review)
- [fix] The web-driver hang fix was INCOMPLETE at first — only `settle` was bounded. The audit caught that `probeInteractiveElements` (unbounded `evaluateJavaScript`) runs BEFORE the snapshot every step, and `dispatchClick`'s `runJS`/`runJSAndReturn` are unbounded too — so a navigating click to a hung page still froze the run one function later. Fix: EVERY per-step WKWebView await is now bounded via `WebDriver.raceAgainstTimeout` — settle, probe, runJS, runJSAndReturn, captureSnapshot. #fix
- [pattern] `raceAgainstTimeout` must use unstructured `Task`s + a continuation guarded by a one-shot actor (`RaceBox`). A `withTaskGroup` does NOT work here: it awaits ALL children before returning, so a wedged child re-introduces the hang. Abandon the wedged task; it's a bounded leak (≤1 main-actor-pinned call per timeout, freed at teardown). #pattern
- [fix] `captureSnapshot` now ferries a CGImage + the original POINT size across the race (NOT a TIFF round-trip, which can hand the image back at pixel size and misplace every Set-of-Mark badge). #fix
- [fix] Ghost RunRecord: `markCompleted` only runs on the happy path (`RunCoordinator.runAllLegs` end), so cancel/watchdog/error left a permanent "still running" skeleton in the shared store. Fixed MCP-side: `RunSupervisor` now holds `history` and writes a terminal record (`markCompleted` with `.blocked`/`.failure`) on cancel/fail/finishIfNeeded/idleCheck, plus an apply() guard to ignore late events after terminal. NOTE: a coordinator-level fix (terminal write in `RunCoordinator.execute`'s catch) would ALSO cover GUI-initiated aborts — still open. #fix
- [fix] Seeding flag (`didSeedBuiltIns`) now set AFTER a successful seed (was before the await), so a transient store failure retries instead of permanently serving empty personas. Safe: tool calls are serialized on the MCPServer actor + the seed is idempotent. #fix
- [open] Remaining audit findings NOT yet applied (recommended quick batch): (1) `MCPArguments.int()/bool()` coerce JSON booleans/numbers — e.g. `step_budget: true`→1, `step_budget: false`→0=unlimited, `include_archived: 5`→true — add `CFBooleanGetTypeID` guards; (2) `stage_credential` writes the SwiftData row BEFORE the Keychain password → orphan credential row on Keychain failure (write Keychain first, or compensating delete); (3) `start_run` doesn't validate `credential_id` belongs to `application_id` → cross-app password-injection risk (assert ownership); (4) `start_run` schema marks only `goal` required but the handler needs persona + platform params — clarify in the tool description; (5) no busy-retry on concurrent SwiftData `save()`; (6) supervisor `statuses`/`tasks`/`watchdogs` dicts never pruned; (7) GUI+MCP must ship lock-step SwiftData schema versions (two processes self-migrating one file is hazardous). #open


## Hardening batch applied (2026-06-16)
- [fix] Audit items 1–4 fixed + built + verified: (1) `MCPArguments.int()/bool()` reject mismatched JSON types via a CFBoolean guard (`isJSONBool`) — `step_budget: true` and `include_archived: 5` are no longer silently coerced; (2) `stage_credential` writes the Keychain password BEFORE the SwiftData row (no orphan row on Keychain failure); (3) `start_run` validates `credential_id` exists and — when `application_id` is set — belongs to it (blocks cross-app credential injection); (4) `start_run` tool description now states the goal + persona + target requirements. #fix
- [open] Still deferred (lower priority, mostly shared-code): busy-retry on concurrent SwiftData `save()` (touches shared RunHistoryStore, GUI too); supervisor `statuses/tasks/watchdogs` dict pruning (negligible leak); a coordinator-level terminal-record write in `RunCoordinator.execute`'s catch (would ALSO fix GUI-initiated abort ghosts — the MCP-side supervisor backstop already covers MCP aborts); GUI+MCP lock-step SwiftData schema versions (advisory). #open


## Validated end-to-end (2026-06-16)
- [verified] travelsynch.com retry on the rebuilt binary COMPLETED CLEANLY — 14 steps in 48s, verdict `blocked` = step-budget exhausted (NOT a hang). The agent drove INTO the email sign-in modal, typed an email, and clicked "Send sign-in link" → "Sending..." — exactly the dynamic-submit/navigation moment that froze run 1 (which hung on a "Start Free Trial" click). The web-driver per-step timeouts work. #verified
- [verified] Ghost-record fix confirmed in the shared store: the new run is a terminal RunRecord (completed, blocked, 15 steps); the pre-fix orphaned run (581CCC5F) still shows GHOST(running, 0 steps). New aborts won't ghost. #verified
- [process] To pick up a new harness-mcp binary in a live session, `pkill -x harness-mcp` — the MCP client auto-respawns the latest binary on the next tool call (verified). A running process can't hot-swap its binary. #process
- [note] Runs hitting the step budget end `blocked` mid-exploration with `wouldRealUserSucceed:false` — to get a real success/failure verdict via `mark_goal_done`, give a larger step_budget (~25–30). #note
