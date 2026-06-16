# Core Services

The services in this layer are the data-and-side-effects bridge between the iOS Simulator / LLM providers / filesystem and the SwiftUI features. Update this table as services land.

Status legend: ⏳ planned · 🚧 in progress · ✅ shipped.

| Status | Service | File | Isolation | Purpose |
|---|---|---|---|---|
| ✅ | `ProcessRunner` | `Harness/Services/ProcessRunner.swift` | `actor` | The only owner of `Process()` in Harness. One-shot + streaming variants. SIGTERM/SIGKILL on cancel; explicit Pipe close in `defer`. See [`../standards/03-subprocess-and-filesystem.md`](https://github.com/awizemann/harness/blob/main/standards/03-subprocess-and-filesystem.md). |
| ✅ | `ToolLocator` | `Harness/Services/ToolLocator.swift` | `actor` | Resolves paths for `xcrun`, `xcodebuild`, `brew` at app launch. Caches in `tools.json` with a 12h TTL. |
| ✅ | `XcodeBuilder` | `Harness/Services/XcodeBuilder.swift` | `Sendable struct` | Wraps `xcodebuild` with derived data isolated per run. Streams the build log to disk; maps signing-required errors specifically. Returns `(.app URL, bundle id, duration, log path)`. See [Xcode-Builder](Xcode-Builder). |
| ✅ | `SimulatorDriver` | `Harness/Services/SimulatorDriver.swift` | `actor` | Wraps `simctl` (lifecycle) + WebDriverAgent (input). Pixel→point conversion lives in `toPoints(_:scaleFactor:)` — the one place that math runs. Idempotent boot tolerated. Owns the active WDA runner handle. See [Simulator-Driver](Simulator-Driver) and [`../standards/12-simulator-control.md`](https://github.com/awizemann/harness/blob/main/standards/12-simulator-control.md). |
| ✅ | `WDABuilder` | `Harness/Services/WDABuilder.swift` | `actor` | Builds + caches the WebDriverAgent xctestrun once per iOS major.minor under `~/Library/Application Support/Harness/wda-build/iOS-<ver>/`. SHA-gated rebuild. |
| ✅ | `WDARunner` | `Harness/Services/WDARunner.swift` | `actor` | Manages the lifecycle of the `xcodebuild test-without-building` process that hosts WDA inside the simulator. Cancellation flows through the streaming task → SIGTERM. |
| ✅ | `WDAClient` | `Harness/Services/WDAClient.swift` | `actor` | URLSession HTTP client for WDA's W3C / `/wda/*` endpoints. Retries 5xx + connection-refused. Tested with URLProtocol stubs. |
| ✅ | `SimulatorWindowController` | `Harness/Services/SimulatorWindowController.swift` | `Sendable struct` | Hides / unhides Simulator.app's macOS window during runs via `NSWorkspace.runningApplications`. |
| ✅ | `WebDriver` | `Harness/Platforms/Web/WebDriver.swift` | `actor` | Drives an embedded `WKWebView`: screenshots, click / type / scroll / navigate dispatch, Set-of-Mark probe + numbered-badge overlay, `awaitDOMSettled` MutationObserver gate that rides out SPA hydration. See [Web-Driver](Web-Driver). |
| ✅ | `WebPlatformAdapter` | `Harness/Platforms/Web/WebPlatformAdapter.swift` | `Sendable struct` | `PlatformAdapter` for `.web` runs. Spawns an off-screen `WebViewWindowController`, loads the start URL, awaits the first DOM-quietness window, hands `RunCoordinator` a `RunSession` whose driver is a `WebDriver`. |
| ✅ | `ClaudeClient` | `Harness/Services/ClaudeClient.swift` | `actor` | Anthropic implementation of `LLMClient`. Single-shot `step(_:)` with explicit `cache_control: ephemeral` markers and full tool-call parsing. See [Claude-Client](Claude-Client). |
| ✅ | `OpenAIClient` | `Harness/Services/OpenAIClient.swift` | `actor` | OpenAI Chat Completions implementation of `LLMClient`. `Bearer` auth, `image_url` content blocks, `tool_choice: required`, parses string-encoded `function.arguments`. Automatic prompt cache (50% off at ≥1024 tokens). |
| ✅ | `GeminiClient` | `Harness/Services/GeminiClient.swift` | `actor` | Google `generateContent` implementation of `LLMClient`. `x-goog-api-key` auth, `inlineData` parts, `systemInstruction` + `toolConfig.functionCallingConfig.mode = "ANY"`. Implicit caching on 2.5+ (90% off). |
| ✅ | Local Mac (Ollama / LM Studio) | `Harness/Services/OpenAIClient.swift` + factory | `actor` (reuses OpenAIClient) | `ModelProvider.local` runs a vision LLM on the user's Mac via an OpenAI-compatible HTTP server. Both Ollama (`http://localhost:11434`) and LM Studio (`http://localhost:1234`) speak the same `/v1/chat/completions` shape, so one client implementation covers both — `OpenAIClient` relaxes its API-key guard when `baseURL.host != "api.openai.com"` and sends `Bearer local`. Curated models: Qwen3-VL 8B (recommended; GUI-trained), Gemma 4 9B, Llama 3.2 Vision 11B, plus a `Custom local model…` escape hatch (tag lives in `AppState.localCustomModelName`). Privacy invariant: a `.local` run produces zero outbound connections to any cloud LLM endpoint. See [`../standards/07-ai-integration.md` §12](https://github.com/awizemann/harness/blob/main/standards/07-ai-integration.md). |
| ✅ | `LLMClientFactory` | `Harness/Services/LLMClientFactory.swift` | `enum` (static) | Picks the right `LLMClient` for a run's `ModelProvider`. Hands back a fresh client per run so token-usage accounting + cycle-detector window reset cleanly. For `.local`, constructs an `OpenAIClient` with the user's persisted base URL and (only for `.customLocal`) a model-name override sourced from `AppState`. |
| ✅ | `LLMShared` | `Harness/Services/LLMShared.swift` | `enum` (static) | Provider-neutral helpers used by every `LLMClient` impl. `toolCall(name:inputData:)` decodes a tool-name + JSON blob into a typed `ToolCall`; `intValue(_:)` coerces string-encoded numbers. |
| ✅ | `KeychainStore` | `Harness/Services/KeychainStore.swift` | `Sendable struct` | Thin wrapper around `SecItemAdd` / `SecItemUpdate` / `SecItemCopyMatching` / `SecItemDelete`. Per-provider conveniences via `readKey(for:)` / `writeKey(_:for:)` / `deleteKey(for:)` keyed by `ModelProvider` (services `com.harness.{anthropic,openai,google}`, account `default`). `.local` has a vestigial `com.harness.local` service id that's never read; the local-server base URL lives in `settings.json` instead. Legacy `readAnthropicAPIKey()` shim kept for back-compat. |
| ✅ | `RunLogger` | `Harness/Services/RunLogger.swift` | `actor` | Append-only JSONL writer + screenshot dump per run. One actor per active run. Per-row `synchronize()`. Order-invariant (single `runStarted`, terminal `runCompleted`). See [Run-Logger](Run-Logger) and [`../standards/14-run-logging-format.md`](https://github.com/awizemann/harness/blob/main/standards/14-run-logging-format.md). |
| ✅ | `RunLogParser` | `Harness/Services/RunLogParser.swift` | `enum` (static) | Reads JSONL back into typed `DecodedRow`s. Tolerates trailing partial rows. `validateInvariants(_:)` checks step monotonicity + run-start/end positions. |
| ✅ | `RunHistoryStore` | `Harness/Services/RunHistoryStore.swift` | `actor` | SwiftData container for `RunRecord` + `ProjectRef`. Skeleton-first insert + `markCompleted` update. In-memory variant for tests via `RunHistoryStore.inMemory()`. |
| ✅ | `RunCoordinator` | `Harness/Domain/RunCoordinator.swift` | `actor` | Orchestrates one run: build → boot → install → launch → loop → log → cleanup. Returns `AsyncThrowingStream<RunEvent>`. Step-mode approval gate plumbed via `AsyncStream<UserApproval>`. |
| ✅ | `AgentLoop` | `Harness/Domain/AgentLoop.swift` | `actor` | The loop: `HistoryCompactor` (last-6 turns kept full, older screenshots dropped), cycle detector (3 consecutive matching `(dHash, toolCall)` → blocked), parse-failure retry (cap 2), step + token budget short-circuits. See [Agent-Loop](Agent-Loop). |
| ✅ | `PromptLibrary` | `Harness/Core/PromptLibrary.swift` | `Sendable struct` | Loads `docs/PROMPTS/*.md` from `Bundle.main` (xcodegen ships them as the `PROMPTS/` Resources subdir). Single source of truth for the system prompt + persona defaults + friction vocab. |

## Phase 1 + 2 cross-cutting

These also landed alongside the services, supporting the layer above:

- `Harness/Core/HarnessPaths.swift` — every filesystem path constant. The single source of truth for `~/Library/Application Support/Harness/...`.
- `Harness/Core/Models.swift` — domain types: `GoalRequest`, `ProjectRequest`, `SimulatorRef`, `Step`, `ToolCall`, `ToolKind`, `ToolInput`, `ToolResult`, `FrictionEvent`, `FrictionKind`, `Verdict`, `RunOutcome`, `RunEvent`, `UserApproval`. Naming matches [Glossary](Glossary) exactly.
- `Harness/Tools/AgentTools.swift` — `CanonicalTool` + `ToolSchema.canonical(platform:)` (provider-neutral) and per-provider shape translators (`anthropicShape`, `openAIShape`, `geminiShape`). The Gemini translator uppercases JSON Schema types and strips `additionalProperties` for the strict OpenAPI parser. Pinned by `AgentToolsSchemaTests` + `ToolSchemaShapesTests` + `ToolSchemaGeminiShapeTests`.

## Phase 3 (still planned)

- App shell + AppCoordinator + AppState.
- First-run wizard (API key, WebDriverAgent build, default sim).
- Feature modules: `GoalInput`, `RunSession`, `RunHistory`, `RunReplay`, `FrictionReport`, `Settings`.

## Adding a service

When a new service lands:

1. Conform to a `Sendable` protocol per `01-architecture.md §6` (`SimulatorDriving`, `XcodeBuilding`, `LLMClient`, `RunLogging`, `RunHistoryStoring` are the templates).
2. Add a row above with status, file path, isolation, one-line purpose.
3. If it's non-trivial (>200 lines, multiple responsibilities, complex CLI surface, or has subtle behavioral guarantees), give it its own deep-dive page — copy [Simulator-Driver](Simulator-Driver)'s shape.
4. Cross-link from the relevant standard.
5. Add at least one mock for the test suite per [`../standards/10-testing.md`](https://github.com/awizemann/harness/blob/main/standards/10-testing.md). The current mocks are at `Tests/HarnessTests/Mocks/`.

See [Adding-a-Service](Adding-a-Service) for the full recipe.

---

P26-05-05 — migrated to GitHub Wiki_