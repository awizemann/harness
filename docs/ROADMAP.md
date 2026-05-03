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

## Phase 1 — Plumbing (≈1–2 days)

Deliverable: an Xcode project that builds, with `ProcessRunner` + `ToolLocator` + `XcodeBuilder` + `SimulatorDriver` + `ClaudeClient` skeletons, all runnable in isolation but not yet wired into a UI.

- [ ] Create `Harness.xcodeproj` (single Mac target, non-sandboxed entitlements).
- [ ] Wire `HarnessDesign/` as a local Swift Package dependency.
- [ ] `Harness/Core/HarnessPaths.swift` + `Harness/Core/Models.swift` (Run, Step, Action, Friction, Verdict, FrictionKind, Persona).
- [ ] `Harness/Services/ProcessRunner.swift` (actor, with cancellation + timeout + streaming variant).
- [ ] `Harness/Services/ToolLocator.swift` (xcrun, idb, idb_companion, brew).
- [ ] `Harness/Services/XcodeBuilder.swift` (build with derived data isolated to run dir).
- [ ] `Harness/Services/SimulatorDriver.swift` (full protocol per standard 12; coord scaling unit-tested).
- [ ] `Harness/Services/ClaudeClient.swift` (single message + tool use; prompt caching wired; no loop yet).
- [ ] `Harness/Services/KeychainStore.swift` (read/write `com.harness.anthropic`).
- [ ] Smoke target: a tiny CLI-callable test target that boots a sim, takes a screenshot, sends to Claude, prints the response.

Wiki updates this phase: `Core-Services.md` populated with each service's row; `Build-and-Run.md` filled in; `Simulator-Driver.md` filled with concrete flag set.

---

## Phase 2 — Agent loop (≈1–2 days)

Deliverable: a non-UI run end-to-end. Goal in → loop runs → events.jsonl + screenshots on disk → verdict out.

- [ ] `Harness/Tools/AgentTools.swift` — tool schema + tagged-union action type.
- [ ] `Harness/Domain/AgentLoop.swift` — the loop, history compactor, cycle detector, parse-failure retry.
- [ ] `Harness/Services/RunLogger.swift` — JSONL writer + screenshot dump per standard 14.
- [ ] `Harness/Services/RunHistoryStore.swift` — SwiftData container + `RunRecord` + `ProjectRef`.
- [ ] `Harness/Domain/RunCoordinator.swift` — orchestrator actor wiring builder + driver + agent + logger + history.
- [ ] Wire prompt library: build script copies `docs/PROMPTS/*.md` into `Resources/`; `AgentLoop` loads via `Bundle.main`.
- [ ] Step-mode approval gate: `AsyncStream<UserApproval>` plumbed through coordinator.
- [ ] First replay test fixture: record a real "TodoSample add milk" run, freeze it, make it a regression test.

Wiki updates this phase: `Agent-Loop.md` filled with prose walkthrough; `Tool-Schema.md` finalized; `Run-Logger.md` filled; `Run-Replay-Format.md` filled with worked example.

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
