# Harness — Standards

**Version**: 1.0
**Last Updated**: 2026-05-03
**Applies To**: Harness (macOS-only AI-driven iOS UX test app)

These are the development, code, and architecture standards every contributor (human or agent) follows. Numbered files survive across iterations of the project; the audit checklist is the per-PR sanity check.

Standards 01, 02, 04, 09, 10 are borrowed from the centralized macOS-app suite library at `/Users/alanwizemann/Development/scarf/scarf/standards/` and adapted lightly. Standards 03, 05, 07, 08 are rewritten for Harness's reality. Standards 12, 13, 14 are Harness-only.

---

## Standards Files

| # | File | Origin | Description |
|---|------|--------|-------------|
| 01 | [01-architecture.md](01-architecture.md) | borrowed (suite) | MVVM-F pattern, AppCoordinator, AppState, directory layout, protocol-driven design |
| 02 | [02-swiftdata.md](02-swiftdata.md) | borrowed + scoped | SwiftData persistence — used **only for the Run history index**. Per-step data is JSONL on disk. |
| 03 | [03-subprocess-and-filesystem.md](03-subprocess-and-filesystem.md) | rewritten | `ProcessRunner` actor, tool discovery, working-dir hygiene, `HarnessPaths`, Keychain, non-sandboxed contract |
| 04 | [04-swift-conventions.md](04-swift-conventions.md) | borrowed (suite) | Swift 6 concurrency, `os.Logger` standard, error handling, file size limits, anti-patterns |
| 05 | [05-design-system.md](05-design-system.md) | rewritten | HarnessDesign tokens + primitives + screen drafts; light/dark; macOS conventions |
| 07 | [07-ai-integration.md](07-ai-integration.md) | rewritten | Claude defaults, prompt caching, history compaction, persona injection, cost budget, prompt-injection defense |
| 08 | [08-run-log-integrity.md](08-run-log-integrity.md) | rewritten | Append-only JSONL invariants, screenshot durability, atomic step boundaries, round-trip tests |
| 09 | [09-performance.md](09-performance.md) | borrowed (suite) | Component extraction, state ownership, view complexity, agent loop cost patterns, mirror polling |
| 10 | [10-testing.md](10-testing.md) | borrowed (suite) | Swift Testing, protocol mocks, no timing-dependent tests, replay-based agent tests |
| 12 | [12-simulator-control.md](12-simulator-control.md) | NEW | `simctl` + `idb` interfaces, `SimulatorRef`, coordinate space, daemon liveness, AppleScript fallback |
| 13 | [13-agent-loop.md](13-agent-loop.md) | NEW | The loop, cycle detector, step + token budgets, approval gate, friction taxonomy, system prompt structure |
| 14 | [14-run-logging-format.md](14-run-logging-format.md) | NEW | JSONL row schema by kind, screenshot conventions, versioning rules, replay invariants |
| -- | [AUDIT_CHECKLIST.md](AUDIT_CHECKLIST.md) | NEW | Per-PR sanity check distilled from every standard's audit section |

---

## Skipped (vs. the suite library)

| # | File | Reason |
|---|---|---|
| 06 | editor-patterns | Harness has no document editor. |
| 11 | multiplatform | Mac-only. |

If either becomes relevant, copy from `../scarf/scarf/standards/` and adapt.

---

## How to Use These

### For new code
1. Find the standard most relevant to what you're touching (architecture for new features, 03 for shell-outs, 13 for agent-loop changes, 14 for log format changes).
2. Read its **audit checklist** (section labeled "Audit checklist" in each file).
3. After your changes, run through the checklist. Add a "Standards: 03, 04" footer to your PR description.

### For audit / cleanup
1. Run `AUDIT_CHECKLIST.md` against the codebase before each release.
2. File issues for any failing checks.
3. Don't quietly fix audit fails — document them in the PR.

### When standards change
1. Edit the file.
2. Update the version + `Last Updated` line at the top of `INDEX.md`.
3. Update [`wiki/Standards-Index.md`](../wiki/Standards-Index.md) if the standard's title or scope changed.
4. Mention in the next CLAUDE.md commit if the change affects daily workflow.

---

_Last updated: 2026-05-03 — initial drop with foundation scaffolding._
