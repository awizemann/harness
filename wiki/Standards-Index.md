# Standards Index

The wiki-side mirror of [`../standards/INDEX.md`](../standards/INDEX.md). Each link opens the canonical standard file.

When a new contributor (human or agent) is about to write code, they:

1. Find the relevant standard below.
2. Read it.
3. Skim its **audit checklist** section.
4. After their change, run the checklist over their diff.

Standards are **load-bearing**. Disagreement = a PR amending the standard, not silent deviation.

---

## The list

| # | Standard | Origin | One-liner |
|---|---|---|---|
| 01 | [Architecture](../standards/01-architecture.md) | borrowed | MVVM-F + AppCoordinator + protocol-driven services. |
| 02 | [SwiftData (scoped)](../standards/02-swiftdata.md) | borrowed + scoped | Used **only** for the Run history index. Per-step data is JSONL on disk. |
| 03 | [Subprocess & Filesystem](../standards/03-subprocess-and-filesystem.md) | rewritten | `ProcessRunner` actor; `ToolLocator`; non-sandboxed; `HarnessPaths`. |
| 04 | [Swift Conventions](../standards/04-swift-conventions.md) | borrowed | Swift 6 concurrency; `os.Logger`; error handling; file size limits; anti-patterns. |
| 05 | [Design System](../standards/05-design-system.md) | rewritten | HarnessDesign tokens + primitives; light/dark; macOS conventions. |
| 07 | [AI Integration](../standards/07-ai-integration.md) | rewritten | Claude defaults; prompt caching; history compaction; persona injection; budget; injection defense. |
| 08 | [Run Log Integrity](../standards/08-run-log-integrity.md) | rewritten | Append-only JSONL; screenshot durability; round-trip tests; replay invariants. |
| 09 | [Performance](../standards/09-performance.md) | borrowed | View complexity; state ownership; agent loop cost; mirror polling. |
| 10 | [Testing](../standards/10-testing.md) | borrowed | Swift Testing; protocol mocks; no timing-dependent tests; replay-based agent tests. |
| 12 | [Simulator Control](../standards/12-simulator-control.md) | NEW | `simctl` + `idb`; `SimulatorRef`; coordinate space; daemon liveness; AppleScript fallback. |
| 13 | [Agent Loop](../standards/13-agent-loop.md) | NEW | The loop; cycle detector; budgets; approval gate; friction taxonomy; system prompt structure. |
| 14 | [Run Logging Format](../standards/14-run-logging-format.md) | NEW | JSONL row schema; screenshot conventions; versioning rules; replay invariants. |

Plus [`AUDIT_CHECKLIST.md`](../standards/AUDIT_CHECKLIST.md) — distilled per-PR sanity check.

## Skipped from the suite library

- **06 editor-patterns** — Harness has no document editor.
- **11 multiplatform** — Mac-only.

If either becomes relevant, copy from `../scarf/scarf/standards/` and adapt.

---

_Last updated: 2026-05-03 — initial scaffolding._
