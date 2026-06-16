# HarnessCLI

A development-time command-line driver for Harness's web run path. Bypasses the SwiftUI app entirely so you can iterate on the agent loop, prompts, and model picks against a real URL in seconds — without rebuilding the Mac app.

Lives alongside `Harness` and `HarnessTests` as a third xcodegen target. Reuses the existing `Harness/` source root (minus the SwiftUI surface), produces a `harness-cli` Mach-O binary.

> **Status**: development-only. Not shipped to users — there's no Developer-ID signature, no notarisation, no install path. Builds locally from this repo.

## Supported platforms

Three platforms today, picked via `--platform`:

| Platform | Required flags | What it drives |
|---|---|---|
| `web` *(default)* | `--url <URL>` | An off-screen `WKWebView` at `--viewport-width`×`--viewport-height` ([Web-Driver](Web-Driver)) |
| `ios` | `--project-path <PATH>` `--scheme <NAME>` `--simulator-udid <UDID>` | Xcode-builds the project + boots the simulator + installs/launches + opens a WebDriverAgent session ([iOS-Driver](iOS-Driver)) |
| `macos` | `--app-path <PATH>` | Launches the `.app` and drives it via CGEvent + AX ([macOS-Driver](macOS-Driver)) |

iOS UDIDs come from `xcrun simctl list devices --json` or from the GUI app's Application detail screen. macOS runs pre-flight Screen Recording + Accessibility checks; the first run pops the system dialogs once (CLI binary is signed separately from the GUI, so its grants are independent).

## Why this exists

The inner loop for any web/agent change used to be: edit code → rebuild the .app (30-60s) → click through Compose Run → wait for cold-start → watch the simulator → paste Mac Console + Ollama logs into chat → infer what happened. Iterating on a single bug (web click dispatch, screenshot capture, page-load settling, model context-window) took five or six round-trips, and the agent driving the work couldn't observe most of it.

With the CLI, the loop is:

1. Edit code
2. `xcodebuild -scheme HarnessCLI build`
3. Run the binary against a real URL with chosen `--provider` / `--model`
4. `Read` the per-step PNGs and `events.jsonl` directly from disk
5. Repeat

The agent (or the human, or both) gets to **see the same artifacts that would land in the GUI's run history**, just one `cd` away in the working tree.

## When to reach for it

- **Iterating on the agent loop**: AgentLoop changes, prompt edits in `docs/PROMPTS/`, history-compaction tweaks, cycle-detector thresholds.
- **Comparing models on identical input**: run the same `--url` + `--goal` + `--persona` against `--provider local --model qwen3-vl:8b` and `--provider anthropic --model claude-opus-4-7` — diff the per-step screenshots and tool calls to answer "is this a small-model failure or a Harness bug?"
- **Cross-provider validation**: confirm OpenAI / Gemini paths still produce sensible tool calls after a refactor without booting the GUI.
- **Headless CI** (future): no Dock icon, no menu bar, exits with a status code based on verdict. Drop-in for a future "smoke an example run on every PR" workflow.

Reach for the **full GUI app** instead when you need: live mirror, step-by-step approvals, replay scrubber, friction-report rendering, multi-leg chains, or anything iOS/macOS.

## Build

```bash
xcodegen generate                                             # only after project.yml changes
xcodebuild -project Harness.xcodeproj -scheme HarnessCLI build
```

The binary lands at `$(BUILT_PRODUCTS_DIR)/harness-cli`. Resolve the path with:

```bash
CLI="$(xcodebuild -project Harness.xcodeproj -scheme HarnessCLI \
        -showBuildSettings build 2>/dev/null \
        | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/harness-cli"
```

## Invocation

```bash
"$CLI" \
  --url https://alanwizemann.com \
  --goal "Read a few articles from this website" \
  --persona "A curious first-time user" \
  --provider local \
  --model qwen3-vl:8b \
  --output ./test-run \
  --max-steps 5
```

Flags:

| Flag | Required | Default | Notes |
|---|---|---|---|
| `--url` | ✓ | — | Start URL the WKWebView loads. |
| `--goal` | ✓ | — | Plain-language goal injected into `{{GOAL}}`. |
| `--provider` | ✓ | — | `anthropic` / `openai` / `google` / `local`. |
| `--model` | ✓ | — | `AgentModel` raw value, e.g. `claude-opus-4-7`, `gpt-5-mini`, `qwen3-vl:8b`. Unknown tags with `--provider local` are sent verbatim to Ollama. |
| `--persona` | | "curious first-time user" | Literal persona text. (Preset-name lookup is a follow-up — see Roadmap.) |
| `--max-steps` | | 20 | Step budget. The agent's `mark_goal_done` can still end the run earlier. |
| `--output` | | `./runs/<timestamp>/` | Where `events.jsonl` + `step-NNN.png` + `meta.json` land. |
| `--viewport-width` | | 1280 | CSS-pixel width — sets `window.innerWidth`. |
| `--viewport-height` | | 880 | CSS-pixel height. |
| `--deterministic` | | false | Advisory `temperature=0`; provider-dependent honouring. |

Credentials are read from env vars (no Keychain entanglement):

| Env var | Used when |
|---|---|
| `ANTHROPIC_API_KEY` | `--provider anthropic` |
| `OPENAI_API_KEY` | `--provider openai` |
| `GOOGLE_API_KEY` | `--provider google` |
| `HARNESS_OLLAMA_URL` | `--provider local`, defaults to `http://127.0.0.1:11434` |
| `HARNESS_DUMP_MARKED` | Set to `1` to dump diagnostic info — see [Diagnostic env vars](#diagnostic-env-vars) below. |

## Diagnostic env vars

When iterating on web-platform behaviour, set `HARNESS_DUMP_MARKED=1`. Two things change:

1. Every screenshot pass writes the **Set-of-Mark overlay** next to the unmarked PNG: `step-NNN.marked.png`. This is exactly what the LLM sees — useful for verifying probe coverage, badge legibility, and which elements got which id.
2. Every click (`tap` or `tap_mark`) emits a one-line stderr diagnostic with the resolved element, interactive ancestor, and post-click URL:
   ```
   [WebDriver] tap_mark(6) label="Articles" role=a rect=(725,21,76,40) → click(763,41)
   [WebDriver]   → element=A interactive=A[href=/articles] url=https://alanwizemann.com/articles
   ```

This is dev-only — the env var is never set in the GUI app. See [Web-Driver](Web-Driver) § Diagnostic env vars.

## Output

`--output` lands per-run artifacts flat:

```
test-run/
├── events.jsonl          ← JSONL row stream (same schema as the GUI)
├── step-001.png          ← unmarked page capture at the start of step 1
├── step-002.png
├── step-NNN.png
├── meta.json             ← run outcome + budget aggregates
└── build/                ← reserved for build artefacts (empty on web)
```

`events.jsonl` is the same v3 schema as the GUI's run history — see [Run-Replay-Format](Run-Replay-Format). Inspect with `jq` or just `Read` it row-by-row.

stdout gets a human-readable echo: `[step N] tool=tap input=tap(592,56)` with the model's `observation` and `intent` text, the per-step duration, token counts, and the final verdict.

## How it wires together

`HarnessCLI/Main.swift` pumps `NSApplication.run()` at activation policy `.prohibited` (no Dock icon, no menu bar) — WKWebView's delegate callbacks (page load, JS evaluation, snapshot completion) need the main run loop ticking. The actual work runs on a Task that calls `exit()` when done.

`HarnessRunner.run(_:)` constructs:

- An **`EnvKeychain`** — a `KeychainStoring` shim backed by the cloud env vars.
- An **`OllamaClient` / `ClaudeClient` / `OpenAIClient` / `GeminiClient`** via `LLMClientFactory.client(for:)`.
- A **`RunRequest`** with `platformKindRaw = "web"`, the start URL, viewport, and a placeholder `ProjectRequest` (web doesn't xcodebuild).
- A **`WebPlatformAdapter`** with no-op `XcodeBuilding` / `SimulatorDriving` fakes (the web path never invokes them, but `PlatformAdapterServices` is a required parameter shape).
- A **`RunCoordinator`** with the web adapter injected via `platformAdapterOverride:`.

From there it consumes the standard `AsyncThrowingStream<RunEvent>` exactly like the GUI's `RunSessionViewModel` does, then exits 0 (`.success`), 1 (anything else), or 130 (cancelled).

## Touch points in the shared `Harness/` source

The CLI deliberately reuses the production code paths. The only two adjustments needed to host it:

| File | Change |
|---|---|
| `Harness/Core/HarnessPaths.swift` | Added `nonisolated(unsafe) static var runsRootOverride: URL?`. When non-nil, `runDir(for:)` returns the override directly (no per-UUID nesting) so a CLI run's artifacts land flat in `--output`. The GUI never sets it; its paths are unchanged. |
| `Harness/Core/PromptLibrary.swift` | Added a fallback: when `Bundle.main` doesn't carry the `PROMPTS/` resource (tool targets don't get a `Resources/` directory next to the binary), fall back to `HarnessGeneratedRepoRoot.path/docs/PROMPTS/`. Same content as the bundled copy; resolves only in dev builds where SRCROOT was baked in. |

## Excluded from the CLI target

`project.yml` excludes the SwiftUI surface so the tool target builds clean:

```yaml
HarnessCLI:
  type: tool
  platform: macOS
  sources:
    - path: HarnessCLI
    - path: Harness
      excludes:
        - "Features/**"              # all SwiftUI views
        - "App/HarnessApp.swift"     # @main collides with CLI @main
        - "App/AppContainer.swift"
        - "App/AppCoordinator.swift"
        - "App/AppState.swift"
        - "App/FirstRunWizard.swift"
        - "App/SidebarView.swift"
        - "Services/ProjectPicker.swift"   # SwiftUI NSOpenPanel wrapper
        - "Domain/Mappers.swift"           # bridges to HarnessDesign Preview* types
    - path: docs/PROMPTS
      type: folder
      buildPhase: resources
```

If you add a new SwiftUI-touching file under `Harness/`, the CLI build will fail; extend the `excludes:` list (the compiler points at the symbol that brought SwiftUI in).

## File map

| File | Role |
|---|---|
| `HarnessCLI/Main.swift` | Entry point. Pumps `NSApplication.run()`, dispatches `HarnessRunner.run` on a Task, exits on completion. |
| `HarnessCLI/CLIArgs.swift` | Hand-rolled flag parser. No `swift-argument-parser` dependency. |
| `HarnessCLI/HarnessRunner.swift` | Builds the LLM client / RunRequest / WebPlatformAdapter / RunCoordinator and consumes the event stream. |
| `HarnessCLI/ConsoleEventPrinter.swift` | Formats `RunEvent`s for stdout. |
| `HarnessCLI/EnvKeychain.swift` | In-memory `KeychainStoring` backed by `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY`. |
| `HarnessCLI/NoopBuilders.swift` | `XcodeBuilding` / `SimulatorDriving` shims required by `PlatformAdapterServices`, never invoked on web. |

## Limitations

- **Web only.** iOS / macOS would require booting an iOS simulator + idb daemon / Screen Recording — overkill for a CLI loop. If you need to drive an iOS run, use the GUI app.
- **No GUI run history.** The CLI uses `RunHistoryStore.inMemory()`, so completed runs don't show up in the GUI's History tab. (Intentional — the CLI is for inspection on disk.)
- **Persona presets aren't parsed.** Only literal `--persona "..."` text. If you want a preset, copy the markdown block from `docs/PROMPTS/persona-defaults.md` into the flag.
- **No SPM `Package.swift`.** Builds via `xcodebuild`. Adding SPM later for `swift run harness-cli` ergonomics is reasonable but unnecessary for v1.
- **Code signing**: ad-hoc / unsigned. If macOS prompts about Network access on first run, allow it once.
