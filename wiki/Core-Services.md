# Core Services

The services in this layer are the data-and-side-effects bridge between the iOS Simulator / Anthropic API / filesystem and the SwiftUI features. Update this table as services land.

Status legend: ⏳ planned · 🚧 in progress · ✅ shipped (Phase 1+).

| Status | Service | File | Isolation | Purpose |
|---|---|---|---|---|
| ✅ | `ProcessRunner` | `Harness/Services/ProcessRunner.swift` | `actor` | The only owner of `Process()` in Harness. One-shot + streaming variants. SIGTERM/SIGKILL on cancel; explicit Pipe close in `defer`. See [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md). |
| ✅ | `ToolLocator` | `Harness/Services/ToolLocator.swift` | `actor` | Resolves paths for `xcrun`, `xcodebuild`, `idb`, `idb_companion`, `brew` at app launch. Caches in `tools.json` with a 12h TTL. |
| ✅ | `XcodeBuilder` | `Harness/Services/XcodeBuilder.swift` | `Sendable struct` | Wraps `xcodebuild` with derived data isolated per run. Streams the build log to disk; maps signing-required errors specifically. Returns `(.app URL, bundle id, duration, log path)`. See [Xcode-Builder](Xcode-Builder.md). |
| ✅ | `SimulatorDriver` | `Harness/Services/SimulatorDriver.swift` | `Sendable struct` | Wraps `simctl` (lifecycle) + `idb` (input). Pixel→point conversion lives in `toPoints(_:scaleFactor:)` — the one place that math runs. Idempotent boot tolerated. See [Simulator-Driver](Simulator-Driver.md) and [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md). |
| ✅ | `ClaudeClient` | `Harness/Services/ClaudeClient.swift` | `actor` | Anthropic SDK wrapper. Phase 1 is single-shot `step(_:)` with prompt caching markers and full tool-call parsing. The agent loop wraps it in Phase 2. See [Claude-Client](Claude-Client.md) and [`../standards/07-ai-integration.md`](../standards/07-ai-integration.md). |
| ✅ | `KeychainStore` | `Harness/Services/KeychainStore.swift` | `Sendable struct` | Thin wrapper around `SecItemAdd` / `SecItemUpdate` / `SecItemCopyMatching` / `SecItemDelete`. Convenience methods for the Anthropic key (service `com.harness.anthropic`, account `default`). |
| ⏳ | `RunLogger` | `Harness/Services/RunLogger.swift` | `actor` | Append-only JSONL writer + screenshot dump per run. One actor per active run. Lands Phase 2. See [Run-Logger](Run-Logger.md) and [`../standards/14-run-logging-format.md`](../standards/14-run-logging-format.md). |
| ⏳ | `RunHistoryStore` | `Harness/Services/RunHistoryStore.swift` | `actor` | SwiftData container for `RunRecord` + `ProjectRef`. Lands Phase 2. |
| ⏳ | `RunCoordinator` | `Harness/Domain/RunCoordinator.swift` | `actor` | Orchestrates one run. Lands Phase 2. |
| ⏳ | `AgentLoop` | `Harness/Domain/AgentLoop.swift` | `Sendable struct` | The loop: cycle detector, history compactor, parse-failure retry, budget enforcement. Lands Phase 2. See [Agent-Loop](Agent-Loop.md). |

## Phase 1 cross-cutting

These also landed in Phase 1, supporting the services above:

- `Harness/Core/HarnessPaths.swift` — every filesystem path constant. The single source of truth for `~/Library/Application Support/Harness/...`.
- `Harness/Core/Models.swift` — domain types: `GoalRequest`, `ProjectRequest`, `SimulatorRef`, `Step`, `ToolCall`, `ToolKind`, `ToolInput`, `ToolResult`, `FrictionEvent`, `FrictionKind`, `Verdict`, `RunOutcome`, `RunEvent`, `UserApproval`. Naming matches [Glossary](Glossary.md) exactly.
- `Harness/Tools/AgentTools.swift` — `ToolSchema.toolDefinitions(cacheControl:)`, the Anthropic tool schema. Pinned by `AgentToolsSchemaTests`.

## Adding a service

When a new service lands:

1. Conform to a protocol in `01-architecture.md §6` style (`SimulatorDriving`, `XcodeBuilding`, `LLMClient` are the templates).
2. Add a row above with status, file path, isolation, one-line purpose.
3. If it's non-trivial (>200 lines, multiple responsibilities, complex CLI surface), give it its own deep-dive page — copy [Simulator-Driver](Simulator-Driver.md)'s shape.
4. Cross-link from the relevant standard.
5. Add at least one mock for the test suite per [`../standards/10-testing.md`](../standards/10-testing.md).

See [Adding-a-Service](Adding-a-Service.md) for the full recipe.

---

_Last updated: 2026-05-03 — Phase 1 plumbing complete. ProcessRunner / ToolLocator / XcodeBuilder / SimulatorDriver / ClaudeClient / KeychainStore shipped. RunLogger / RunHistoryStore / RunCoordinator / AgentLoop are Phase 2._
