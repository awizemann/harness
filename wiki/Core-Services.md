# Core Services

The services in this layer are the data-and-side-effects bridge between the iOS Simulator / Anthropic API / filesystem and the SwiftUI features. Update this table as services land.

Status legend: ⏳ planned · 🚧 in progress · ✅ shipped.

| Status | Service | File | Isolation | Purpose |
|---|---|---|---|---|
| ✅ | `ProcessRunner` | `Harness/Services/ProcessRunner.swift` | `actor` | The only owner of `Process()` in Harness. One-shot + streaming variants. SIGTERM/SIGKILL on cancel; explicit Pipe close in `defer`. See [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md). |
| ✅ | `ToolLocator` | `Harness/Services/ToolLocator.swift` | `actor` | Resolves paths for `xcrun`, `xcodebuild`, `brew` at app launch. Caches in `tools.json` with a 12h TTL. |
| ✅ | `XcodeBuilder` | `Harness/Services/XcodeBuilder.swift` | `Sendable struct` | Wraps `xcodebuild` with derived data isolated per run. Streams the build log to disk; maps signing-required errors specifically. Returns `(.app URL, bundle id, duration, log path)`. See [Xcode-Builder](Xcode-Builder.md). |
| ✅ | `SimulatorDriver` | `Harness/Services/SimulatorDriver.swift` | `actor` | Wraps `simctl` (lifecycle) + WebDriverAgent (input). Pixel→point conversion lives in `toPoints(_:scaleFactor:)` — the one place that math runs. Idempotent boot tolerated. Owns the active WDA runner handle. See [Simulator-Driver](Simulator-Driver.md) and [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md). |
| ✅ | `WDABuilder` | `Harness/Services/WDABuilder.swift` | `actor` | Builds + caches the WebDriverAgent xctestrun once per iOS major.minor under `~/Library/Application Support/Harness/wda-build/iOS-<ver>/`. SHA-gated rebuild. |
| ✅ | `WDARunner` | `Harness/Services/WDARunner.swift` | `actor` | Manages the lifecycle of the `xcodebuild test-without-building` process that hosts WDA inside the simulator. Cancellation flows through the streaming task → SIGTERM. |
| ✅ | `WDAClient` | `Harness/Services/WDAClient.swift` | `actor` | URLSession HTTP client for WDA's W3C / `/wda/*` endpoints. Retries 5xx + connection-refused. Tested with URLProtocol stubs. |
| ✅ | `SimulatorWindowController` | `Harness/Services/SimulatorWindowController.swift` | `Sendable struct` | Hides / unhides Simulator.app's macOS window during runs via `NSWorkspace.runningApplications`. |
| ✅ | `ClaudeClient` | `Harness/Services/ClaudeClient.swift` | `actor` | Anthropic SDK wrapper. Single-shot `step(_:)` with prompt caching markers and full tool-call parsing. Wrapped by `AgentLoop`. See [Claude-Client](Claude-Client.md) and [`../standards/07-ai-integration.md`](../standards/07-ai-integration.md). |
| ✅ | `KeychainStore` | `Harness/Services/KeychainStore.swift` | `Sendable struct` | Thin wrapper around `SecItemAdd` / `SecItemUpdate` / `SecItemCopyMatching` / `SecItemDelete`. Convenience methods for the Anthropic key (service `com.harness.anthropic`, account `default`). |
| ✅ | `RunLogger` | `Harness/Services/RunLogger.swift` | `actor` | Append-only JSONL writer + screenshot dump per run. One actor per active run. Per-row `synchronize()`. Order-invariant (single `runStarted`, terminal `runCompleted`). See [Run-Logger](Run-Logger.md) and [`../standards/14-run-logging-format.md`](../standards/14-run-logging-format.md). |
| ✅ | `RunLogParser` | `Harness/Services/RunLogParser.swift` | `enum` (static) | Reads JSONL back into typed `DecodedRow`s. Tolerates trailing partial rows. `validateInvariants(_:)` checks step monotonicity + run-start/end positions. |
| ✅ | `RunHistoryStore` | `Harness/Services/RunHistoryStore.swift` | `actor` | SwiftData container for `RunRecord` + `ProjectRef`. Skeleton-first insert + `markCompleted` update. In-memory variant for tests via `RunHistoryStore.inMemory()`. |
| ✅ | `RunCoordinator` | `Harness/Domain/RunCoordinator.swift` | `actor` | Orchestrates one run: build → boot → install → launch → loop → log → cleanup. Returns `AsyncThrowingStream<RunEvent>`. Step-mode approval gate plumbed via `AsyncStream<UserApproval>`. |
| ✅ | `AgentLoop` | `Harness/Domain/AgentLoop.swift` | `actor` | The loop: `HistoryCompactor` (last-6 turns kept full, older screenshots dropped), cycle detector (3 consecutive matching `(dHash, toolCall)` → blocked), parse-failure retry (cap 2), step + token budget short-circuits. See [Agent-Loop](Agent-Loop.md). |
| ✅ | `PromptLibrary` | `Harness/Core/PromptLibrary.swift` | `Sendable struct` | Loads `docs/PROMPTS/*.md` from `Bundle.main` (xcodegen ships them as the `PROMPTS/` Resources subdir). Single source of truth for the system prompt + persona defaults + friction vocab. |

## Phase 1 + 2 cross-cutting

These also landed alongside the services, supporting the layer above:

- `Harness/Core/HarnessPaths.swift` — every filesystem path constant. The single source of truth for `~/Library/Application Support/Harness/...`.
- `Harness/Core/Models.swift` — domain types: `GoalRequest`, `ProjectRequest`, `SimulatorRef`, `Step`, `ToolCall`, `ToolKind`, `ToolInput`, `ToolResult`, `FrictionEvent`, `FrictionKind`, `Verdict`, `RunOutcome`, `RunEvent`, `UserApproval`. Naming matches [Glossary](Glossary.md) exactly.
- `Harness/Tools/AgentTools.swift` — `ToolSchema.toolDefinitions(cacheControl:)`, the Anthropic tool schema. Pinned by `AgentToolsSchemaTests`.

## Phase 3 (still planned)

- App shell + AppCoordinator + AppState.
- First-run wizard (API key, WebDriverAgent build, default sim).
- Feature modules: `GoalInput`, `RunSession`, `RunHistory`, `RunReplay`, `FrictionReport`, `Settings`.

## Adding a service

When a new service lands:

1. Conform to a `Sendable` protocol per `01-architecture.md §6` (`SimulatorDriving`, `XcodeBuilding`, `LLMClient`, `RunLogging`, `RunHistoryStoring` are the templates).
2. Add a row above with status, file path, isolation, one-line purpose.
3. If it's non-trivial (>200 lines, multiple responsibilities, complex CLI surface, or has subtle behavioral guarantees), give it its own deep-dive page — copy [Simulator-Driver](Simulator-Driver.md)'s shape.
4. Cross-link from the relevant standard.
5. Add at least one mock for the test suite per [`../standards/10-testing.md`](../standards/10-testing.md). The current mocks are at `Tests/HarnessTests/Mocks/`.

See [Adding-a-Service](Adding-a-Service.md) for the full recipe.

---

_Last updated: 2026-05-03 — Phase 5 idb→WebDriverAgent migration shipped. Added WDABuilder / WDARunner / WDAClient / SimulatorWindowController; SimulatorDriver is now an actor. 105 tests green._
