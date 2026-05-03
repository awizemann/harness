# Harness — Architecture Overview

A one-page block diagram + data flow. For deeper detail per layer see the per-service wiki pages.

---

## Block diagram

```
+----------------------------------------------------------------------+
|  Harness.app                       Swift 6 / SwiftUI / non-sandboxed |
|                                                                      |
|  +----------------+  +-------------------+  +--------------------+   |
|  | GoalInputView  |  | RunSessionView    |  | RunHistoryView     |   |
|  | (compose)      |  | (live)            |  | (past runs)        |   |
|  +-------+--------+  +---------+---------+  +---------+----------+   |
|          |                     |                       |             |
|          v                     v                       v             |
|        AppCoordinator (@Observable, navigation only)                 |
|                       |                                              |
|                       v                                              |
|        AppState (@Observable, cross-section app-level state)         |
|                       |                                              |
|                       v                                              |
|  +------------------------------------------------------------------+|
|  |  RunCoordinator (actor) — orchestrates one run                   ||
|  |    build → boot → install → launch → loop → log → cleanup        ||
|  +-+---------------+----------------+--------------+----------------+|
|    |               |                |              |                 |
|    v               v                v              v                 |
|  +---------+  +-----------+  +-------------+  +-----------+          |
|  | XcodeBuilder|SimulatorDriver|  AgentLoop |  RunLogger | RunHistoryStore|
|  | (xcodebuild)|(simctl + idb) |  (loop)    |  (JSONL)   | (SwiftData)    |
|  +------+---+  +-------+-------+  +----+----+  +----+----+ +-----+----+   |
|         |             |                |              |        |         |
|         |             |                v              |        |         |
|         |             |        +-------+--------+     |        |         |
|         |             |        | ClaudeClient   |     |        |         |
|         |             |        | (Anthropic SDK)|     |        |         |
|         |             |        +-------+--------+     |        |         |
|         |             |                |              |        |         |
|         v             v                v              v        v         |
|  +----------------------------------+   +----------------------------+   |
|  |  ProcessRunner (actor)           |   |  Filesystem                |   |
|  |  the only owner of Process()     |   |  ~/Library/Application     |   |
|  +-+--------------+-----------------+   |  Support/Harness/runs/<id>/|   |
|    |              |                     +----------------------------+   |
|    v              v                                                       |
| `xcodebuild`   `xcrun simctl` / `idb` / `idb_companion`                   |
+----------------------------------------------------------------------+
```

---

## Data flow per run

1. **Compose** — User enters project + scheme + simulator + persona + goal + mode in `GoalInputView`. The view-model assembles a `GoalRequest`.
2. **Start** — User clicks Start. `RunSessionViewModel` calls `RunCoordinator.run(_:)` which returns an `AsyncThrowingStream<RunEvent, Error>`.
3. **Build** — Coordinator invokes `XcodeBuilder.build(...)` → spawns `xcodebuild` via `ProcessRunner` with derived data isolated under the run dir → returns the `.app` bundle URL.
4. **Sim setup** — `SimulatorDriver.boot(...)`, `install(_:)`, `launch(bundleID:)`. Status bar overrides applied.
5. **Loop** — `AgentLoop` runs (per `13-agent-loop.md`):
   - Screenshot via `SimulatorDriver`
   - `ClaudeClient.step(...)` → tool call
   - In step mode, the coordinator awaits user approval via `AsyncStream<UserApproval>` injected from the view-model
   - Execute tool via `SimulatorDriver`
   - `RunLogger` appends events
   - Loop until `mark_goal_done` / cancel / budget
6. **Wrap-up** — Final `run_completed` row written. `meta.json` written. SwiftData `RunRecord` saved by `RunHistoryStore`. Coordinator emits a final `RunEvent.completed(verdict:)` and the stream finishes.
7. **Replay** — User opens history, double-clicks a row. `RunReplayView` loads `events.jsonl` + `meta.json` from the run directory. The view scrubs through steps with full reasoning visible.

---

## State ownership

| Concern | Owner | Scope |
|---|---|---|
| Navigation (sidebar selection, sheets, modal flags) | `AppCoordinator` | App lifetime |
| App-level cross-section state (API key presence, idb health, default sim) | `AppState` | App lifetime |
| Per-run state (live screenshot, step feed, approval pending) | `RunSessionViewModel` | One run |
| Run orchestration (build/install/loop/log) | `RunCoordinator` (actor) | One run |
| Per-run history record | `RunRecord` (SwiftData) | Persisted |
| Per-step events | `events.jsonl` on disk | Persisted |
| Recently-used Xcode projects | `ProjectRef` (SwiftData) | Persisted |

No singletons except `ToolLocator` (paths to external CLIs) and the keychain accessor (cached API key). Everything else is injected.

---

## Concurrency model

- **`@MainActor`** by default in views and view-models.
- **Actors** for `RunCoordinator`, `ProcessRunner`, `RunLogger`, `RunHistoryStore`, `ClaudeClient`. Reading/writing their state from `@MainActor` always goes through `await`.
- **`Task.detached`** for filesystem reads triggered from view bodies (none allowed in production, but lifecycle-bound load methods may use it).
- **`AsyncThrowingStream`** for run events, screenshot frames, and process streaming output.
- **Cancellation** propagates: cancelling the run task cancels the coordinator; the coordinator cancels its child tasks (loop, screenshot poller, in-flight Claude call). `ProcessRunner` catches cancellation and SIGTERMs the child process.

---

## What lives where (lookup table)

| Concern | Location |
|---|---|
| App entry / `@main` | `Harness/App/HarnessApp.swift` |
| Navigation state | `Harness/App/AppCoordinator.swift` |
| App-level state | `Harness/App/AppState.swift` |
| Path constants | `Harness/Core/HarnessPaths.swift` |
| Domain models (Run, Step, Action, Friction, Verdict) | `Harness/Core/Models.swift` |
| Tool schema | `Harness/Tools/AgentTools.swift` |
| The loop | `Harness/Domain/AgentLoop.swift` |
| Run orchestration | `Harness/Domain/RunCoordinator.swift` |
| Subprocess actor | `Harness/Services/ProcessRunner.swift` |
| External CLI discovery | `Harness/Services/ToolLocator.swift` |
| `xcodebuild` wrapper | `Harness/Services/XcodeBuilder.swift` |
| `simctl` + `idb` wrapper | `Harness/Services/SimulatorDriver.swift` |
| Anthropic SDK wrapper | `Harness/Services/ClaudeClient.swift` |
| JSONL writer | `Harness/Services/RunLogger.swift` |
| SwiftData index | `Harness/Services/RunHistoryStore.swift` |
| Keychain wrapper | `Harness/Services/KeychainStore.swift` |
| First-run wizard | `Harness/App/FirstRunWizard.swift` |
| Settings sheet | `Harness/Features/Settings/` |
| Goal input | `Harness/Features/GoalInput/` |
| Live run view | `Harness/Features/RunSession/` |
| History | `Harness/Features/RunHistory/` |
| Replay | `Harness/Features/RunReplay/` |
| Friction report | `Harness/Features/FrictionReport/` |
| Design tokens + primitives | `HarnessDesign/` (separate package) |
| Prompt library | `docs/PROMPTS/` (loaded as bundle resources) |

---

## Cross-cutting

- **Logging.** Every type uses `os.Logger` with subsystem `com.harness.app`. No `print()` outside previews.
- **Error surface.** Typed errors per layer (`ProcessFailure`, `BuildFailure`, `SimulatorError`, `ClaudeError`, `LogWriteFailure`). The view-model layer maps these to user-facing messages.
- **Testing.** Every protocol has a mock; the agent loop has replay-based fixtures. See `standards/10-testing.md`.

For per-component depth, see [`wiki/Core-Services.md`](../wiki/Core-Services.md).
