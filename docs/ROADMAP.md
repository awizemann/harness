# Harness — Roadmap

A condensed roadmap matching the implementation plan at `~/.claude/plans/harness-application-foundation.md`. This is the build order; status is tracked in the GitHub issue tracker once we have one.

---

## Phase 0 — Foundation (this commit)

- ✅ git init + `.gitignore` + `README.md`.
- ✅ `standards/` library (12 numbered files + INDEX + AUDIT_CHECKLIST).
- ✅ `docs/` (PRD, ARCHITECTURE, ROADMAP).
- ✅ `docs/PROMPTS/` (system prompt, persona defaults, friction vocab).
- ✅ `wiki/` scaffold (Home + 17 reference pages).
- ✅ `CLAUDE.md` root.
- ✅ Design system + primitives + screen drafts already shipped in `HarnessDesign/`.

---

## Phase 1 — Plumbing ✅ shipped 2026-05-03

Deliverable: an Xcode project that builds, with the service skeletons wired up and unit-tested in isolation.

- [x] Create `Harness.xcodeproj` (single Mac target, non-sandboxed entitlements). Generated from `project.yml` via xcodegen.
- [x] Include `HarnessDesign/` source in the main app target. *(Revised from "Swift Package" — graduated to Package later if/when we add a second target.)*
- [x] `Harness/Core/HarnessPaths.swift` — every filesystem-path constant.
- [x] `Harness/Core/Models.swift` — `GoalRequest`, `ProjectRequest`, `SimulatorRef`, `Step`, `ToolCall`, `ToolKind`, `ToolInput`, `ToolResult`, `FrictionEvent`, `FrictionKind`, `Verdict`, `RunOutcome`, `RunEvent`, `UserApproval`.
- [x] `Harness/Services/ProcessRunner.swift` — actor; cancellation; timeout; streaming variant; explicit Pipe close on `defer`.
- [x] `Harness/Services/ToolLocator.swift` — actor; resolves xcrun / xcodebuild / idb / idb_companion / brew; 12h cache.
- [x] `Harness/Services/KeychainStore.swift` — `SecItem*` wrapper; convenience methods for the Anthropic key.
- [x] `Harness/Services/XcodeBuilder.swift` — `xcodebuild` wrapper; derived data isolated; signing-error mapping; `.app` artifact pickup.
- [x] `Harness/Services/SimulatorDriver.swift` — full `SimulatorDriving` protocol; pixel→point conversion in `toPoints` (unit-tested); idempotent boot.
- [x] `Harness/Services/ClaudeClient.swift` — single-shot `step(_:)`; prompt-caching markers; full tool-call parsing; typed `ClaudeError` cases.
- [x] `Harness/Tools/AgentTools.swift` — `ToolSchema.toolDefinitions(cacheControl:)` matching `wiki/Tool-Schema.md`.
- [x] Tests: 28 across `HarnessPaths`, `ProcessRunner` (cancellation, streaming), `KeychainStore` (round-trip), `SimulatorDriver` (coord scaling, simctl JSON parsing), `AgentTools` (schema invariants).

Wiki updates landed: `Core-Services.md` with shipped status, `Build-and-Run.md` filled in, `Design-System.md` reconciled to actual API names (`Theme.*` / `HFont.*` / `Color.harness*`), `Simulator-Driver.md` linked.

**Carries forward into Phase 2:** the smoke "boot sim → screenshot → send to Claude → print response" CLI is deferred to Phase 2 — once `RunCoordinator` exists, it's a thin orchestration on top, not an independent target.

---

## Phase 2 — Agent loop ✅ shipped 2026-05-03

Deliverable: a non-UI run end-to-end. Goal in → loop runs → events.jsonl + screenshots on disk → verdict out.

- [x] `Harness/Tools/AgentTools.swift` — landed in Phase 1.
- [x] `Harness/Domain/AgentLoop.swift` — actor; `HistoryCompactor` (last-6 turns kept full, older screenshots dropped); cycle detector via `ScreenshotHasher` dHash + tool-call equivalence; parse-failure retry (cap 2); step + token budget short-circuits.
- [x] `Harness/Services/RunLogger.swift` + `Harness/Services/RunLogParser.swift` — append-only JSONL with per-row `synchronize()`; meta.json snapshot; tolerant parser with `validateInvariants(_:)`.
- [x] `Harness/Services/RunHistoryStore.swift` — SwiftData container with `RunRecord` + `ProjectRef`; `VersionedSchema` + migration plan in place; `inMemory()` for tests.
- [x] `Harness/Domain/RunCoordinator.swift` — actor; `run(_:approvals:)` returns `AsyncThrowingStream<RunEvent>`; build → boot → install → launch → loop → log → cleanup; step-mode approval gate via `AsyncStream<UserApproval>`.
- [x] Prompt library: `Harness/Core/PromptLibrary.swift` + xcodegen `resources: docs/PROMPTS type: folder`. `AgentLoop` caches the system prompt after first load.
- [x] Replay test infrastructure: `MockLLMClient` (scripted-sequence + lookup-closure modes), `FakeXcodeBuilder`, `FakeSimulatorDriver` with synthesized solid-color PNGs.
- [x] Replay tests: happy path, cycle detector trip, step budget short-circuit. All green.

Wiki updates landed: `Core-Services` flips RunLogger/RunLogParser/RunHistoryStore/RunCoordinator/AgentLoop/PromptLibrary to ✅; `Agent-Loop.md` filled with the prose walkthrough; `Run-Logger.md` filled with implementation detail.

Test count: 50 across 12 suites.

---

## Phase 3 — Visibility (≈1 day)

Deliverable: full UI shell. Screens compose from `HarnessDesign` primitives and bind to real view-models.

- [ ] `Harness/App/HarnessApp.swift`, `AppCoordinator.swift`, `AppState.swift`.
- [ ] `Harness/App/FirstRunWizard.swift` — API key, idb health, default sim.
- [ ] `Harness/Features/GoalInput/` — view-model + view bound to real picker / text fields / mode toggle.
- [ ] `Harness/Features/RunSession/` — live mirror at 3 fps, step feed via `AsyncThrowingStream<RunEvent>` consumption, ApprovalCard wired.
- [ ] `Harness/Features/RunHistory/` — SwiftData-backed list with verdict pills.
- [ ] `Harness/Features/RunReplay/` — TimelineScrubber + step playback.
- [ ] `Harness/Features/FrictionReport/` — filtered timeline + export.
- [ ] `Harness/Features/Settings/` — API key, default model, default step budget, screenshot poll rate, log retention.
- [ ] Smoke test: full path from "open app, click New Run, enter goal, click Start" through "run completes, opens replay automatically".

Wiki updates this phase: `Adding-a-Feature.md` filled with the recipe used; `Adding-a-Service.md` likewise; `Design-System.md` index populated with primitive map; `Glossary.md` reviewed for completeness.

---

## Phase 4 — Polish

- [ ] Cycle detector + step/token-budget bail-outs verified.
- [ ] Stop button cascades cancellation reliably.
- [ ] Coordinate-overlay visualization (last-tap dot animates correctly across resolutions).
- [ ] Run filtering / search / export.
- [ ] Crash-resilience test: kill Harness mid-run; reopen; confirm partial run is parseable.
- [ ] Code-sign + notarize a Developer ID build; ship to a couple of friendly devs.

---

## Phase 5+ — deferred

See `PRD.md` "Deferred / future ideas." Track as GitHub issues once the repo is public.

---

## Tracking

Per-PR status: PRs reference standards touched (e.g., "Standards: 03, 13") in their description and run the audit checklist before requesting review.

Per-phase status: each phase ends with a tagged commit `phase-1`, `phase-2`, etc., for easy diff windowing.
