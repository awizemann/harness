# Per-PR Audit Checklist

Distilled from every standard's audit section. Run before requesting review.

A checked box means the change conforms to the standard. A red flag means the standard is violated and needs justification (or an issue filed for follow-up).

---

## 01 — Architecture

- [ ] No feature module imports a sibling feature.
- [ ] Cross-feature communication goes through `Core/` or `Services/`.
- [ ] All navigation state lives on `AppCoordinator`; views never own independent navigation.
- [ ] Only one `NavigationSplitView` at the top level — no nested navigation stacks.
- [ ] New services have a protocol interface. Concrete types live behind the protocol.
- [ ] No `ObservableObject` / `@Published` / Combine in new code — `@Observable` only.

## 02 — SwiftData (Run history index only)

- [ ] No per-step data lives in SwiftData (it lives in JSONL).
- [ ] Schema changes go through `VersionedSchema` + `SchemaMigrationPlan`.
- [ ] No bare `try?` on `modelContext.save()`.
- [ ] In-memory filtering of unbounded result sets is forbidden.
- [ ] Logger in `@Model` uses `private nonisolated(unsafe) let` at file scope.

## 03 — Subprocess & Filesystem

- [ ] No direct `Process()` instantiation outside `ProcessRunner`.
- [ ] Both `Pipe` file handles closed in `defer`.
- [ ] `Task.checkCancellation()` called before/after long subprocess invocations.
- [ ] All paths derive from `HarnessPaths.swift` constants.
- [ ] External tool paths resolved via `ToolLocator`, not hardcoded.
- [ ] Non-zero exit codes thrown as `ProcessFailure`, not silently logged.
- [ ] No filesystem reads in SwiftUI view bodies.

## 04 — Swift Conventions

- [ ] No `print()` in production code (only in `#Preview` and test helpers).
- [ ] Logger uses static subsystem string `"com.harness.app"`.
- [ ] Every `catch` block logs, re-throws, or returns `.failure` — no empty catches.
- [ ] No force-unwraps (`!`) introduced.
- [ ] No `DispatchQueue.main.async` — use `@MainActor`.
- [ ] No `NSLock` for boolean flags — use `os_unfair_lock`.
- [ ] No bare `try?` without a comment justifying the ignored error.

## 05 — Design System

- [ ] No hardcoded colors / fonts / spacings — all routed through HarnessDesign tokens.
- [ ] No new button styles introduced — use existing primary/secondary/ghost/destructive.
- [ ] New custom controls have `accessibilityLabel` + `accessibilityValue`.
- [ ] `#Preview` blocks render in both light + dark mode.
- [ ] No raw `Color(red:green:blue:)` literals in feature code.

## 07 — AI Integration

- [ ] System prompt loaded from `docs/PROMPTS/system-prompt.md`, not embedded as a string literal.
- [ ] Persona + goal + system prompt + tool schema marked for prompt caching.
- [ ] Tool schema in `Harness/Tools/AgentTools.swift` agrees with `wiki/Tool-Schema.md` byte-for-byte.
- [ ] Token-budget check happens before each Claude call.
- [ ] Errors mapped to typed `ClaudeError` cases, not raw `URLError`.
- [ ] Prompt-injection regression test still green.

## 08 — Run Log Integrity

- [ ] Every JSONL write appends; never seeks/overwrites.
- [ ] `synchronize()` called after every row write.
- [ ] Screenshot PNG written before the corresponding `step_started` row.
- [ ] `schemaVersion` field present on every row.
- [ ] Round-trip test exercises every `kind`.
- [ ] Screenshot paths in JSONL are relative, not absolute.

## 09 — Performance

- [ ] No view exceeds 800 lines (services 1000, view-models 600).
- [ ] No view has more than ~10 `@State` variables.
- [ ] `.task(id:)` includes ALL dependencies in its identifier string.
- [ ] Screenshots downscaled to ≤1024px long edge before sending to Claude.
- [ ] Screenshot poller cancels on view disappear / run end.
- [ ] No `Date()` in hot paths without `#if DEBUG`.

## 10 — Testing

- [ ] New tests use Swift Testing (`@Suite`, `@Test`, `#expect`).
- [ ] No timing-dependent tests — polling with early exit only.
- [ ] Singleton state reset before each test that touches it.
- [ ] Cancellation paths covered for any long-running task.
- [ ] Round-trip test runs on schema or logger changes.
- [ ] Replay fixtures still pass on agent-loop or prompt changes.
- [ ] No `print()` in test helpers — `os.Logger` only.

## 12 — Simulator Control

- [ ] All `simctl` and `idb` commands go through `ProcessRunner`.
- [ ] Coordinate scaling (pixel → point) confined to one place in `SimulatorDriver`.
- [ ] `SimulatorRef.scaleFactor` populated from `simctl list devices --json`, not assumed.
- [ ] `idb_companion` health-checked before each run.
- [ ] AppleScript fallback path tested at least at smoke level.
- [ ] Build artifact picked up by deterministic path math, not `find`.

## 13 — Agent Loop

- [ ] `Task.checkCancellation()` at the top of each loop iteration.
- [ ] Fresh screenshot captured every iteration (never reused).
- [ ] Cycle detector runs and trips on repeated identical state.
- [ ] Step + token budget short-circuits emit `mark_goal_done(blocked)`.
- [ ] Parse-failure retry capped at 2.
- [ ] Persona injected into system prompt, not goal.
- [ ] `FrictionEvent.Kind` enum matches `docs/PROMPTS/friction-vocab.md`.

## 14 — Run Logging Format

- [ ] `RunLogger` writes `schemaVersion: 1` on every row.
- [ ] Reasoning fields (`observation`, `intent`) preserved verbatim.
- [ ] `meta.json` written at run end on both success and failure paths.
- [ ] Parser tolerates unknown `kind` values (warns, doesn't crash).
- [ ] Timestamps ISO 8601 UTC with `Z` suffix.

---

## Cross-cutting

- [ ] Wiki updated if a service / feature / tool / format / standard changed (per the rules in `CLAUDE.md`).
- [ ] PR description names the standards touched (e.g., "Standards: 03, 13, 14").
- [ ] No commits include API keys, `.env` files, real bundle IDs from production apps, or any user PII.
- [ ] No `--no-verify` or skipped pre-commit hooks.
