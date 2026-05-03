# Core Services

The services in this layer are the data-and-side-effects bridge between the iOS Simulator / Anthropic API / filesystem and the SwiftUI features. Update this table as services land.

Status legend: ⏳ planned · 🚧 in progress · ✅ shipped.

| Status | Service | File | Isolation | Purpose |
|---|---|---|---|---|
| ⏳ | `ProcessRunner` | `Harness/Services/ProcessRunner.swift` | `actor` | The only owner of `Process()` in Harness. Runs subprocesses with cancellation + timeout + streaming. See [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md). |
| ⏳ | `ToolLocator` | `Harness/Services/ToolLocator.swift` | `Sendable struct` | Resolves paths for `xcrun`, `xcodebuild`, `idb`, `idb_companion`, `brew` at app launch. Caches in `tools.json`. |
| ⏳ | `XcodeBuilder` | `Harness/Services/XcodeBuilder.swift` | `Sendable struct` | Wraps `xcodebuild` with derived data isolated per run. Returns the `.app` bundle URL. See [Xcode-Builder](Xcode-Builder.md). |
| ⏳ | `SimulatorDriver` | `Harness/Services/SimulatorDriver.swift` | `Sendable struct` | Wraps `simctl` + `idb`. Owns the coordinate-scaling math. See [Simulator-Driver](Simulator-Driver.md) and [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md). |
| ⏳ | `ClaudeClient` | `Harness/Services/ClaudeClient.swift` | `actor` | Anthropic SDK wrapper. Owns prompt caching, history compaction, tool-call parsing, error mapping. See [Claude-Client](Claude-Client.md) and [`../standards/07-ai-integration.md`](../standards/07-ai-integration.md). |
| ⏳ | `RunLogger` | `Harness/Services/RunLogger.swift` | `actor` | Append-only JSONL writer + screenshot dump per run. One actor per active run. See [Run-Logger](Run-Logger.md) and [`../standards/14-run-logging-format.md`](../standards/14-run-logging-format.md). |
| ⏳ | `RunHistoryStore` | `Harness/Services/RunHistoryStore.swift` | `actor` | SwiftData container for the `RunRecord` + `ProjectRef` index. Read by `RunHistoryView`, written at run end. |
| ⏳ | `KeychainStore` | `Harness/Services/KeychainStore.swift` | `Sendable struct` | Thin wrapper around `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`. Used for the Anthropic API key (service `com.harness.anthropic`, account `default`). |
| ⏳ | `RunCoordinator` | `Harness/Domain/RunCoordinator.swift` | `actor` | Orchestrates one run: build → boot → install → launch → loop → log → cleanup. Returns `AsyncThrowingStream<RunEvent, Error>`. |
| ⏳ | `AgentLoop` | `Harness/Domain/AgentLoop.swift` | `Sendable struct` | The loop. Owns history compaction, cycle detector, parse-failure retry, budget enforcement. See [Agent-Loop](Agent-Loop.md). |

---

## Adding a service

When a new service lands:

1. Conform to a protocol in `01-architecture.md §6` style.
2. Add a row above with a one-line purpose.
3. If it's non-trivial (>200 lines, multiple responsibilities, complex CLI surface), give it its own deep-dive page — copy [Simulator-Driver](Simulator-Driver.md)'s shape.
4. Cross-link from the relevant standard.

See [Adding-a-Service](Adding-a-Service.md) for the full recipe.

---

_Last updated: 2026-05-03 — initial scaffolding (no services shipped yet)._
