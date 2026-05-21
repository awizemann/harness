# Harness 0.5.0 — Local Mac inference, Set-of-Mark on iOS + macOS, and a dev-time CLI

0.3 cracked the agent's targeting open on web. 0.5 finishes the job: **Set-of-Mark on every platform**, **a new "Local Mac" provider** that runs a vision LLM on your machine (screenshots never leave the Mac, runs cost $0, you can work offline), and **`harness-cli`** — a development-time command-line driver for iterating on prompts and models without rebuilding the Mac app.

## Highlights

### Local Mac inference (Ollama)

New `Local Mac` provider runs a vision LLM on your Mac via Ollama at `http://127.0.0.1:11434`. Screenshots never leave the machine, runs cost $0 at the API level, and you can work offline.

**Curated model picker** in Settings → Local Mac:

- **Qwen3-VL 8B** (`qwen3-vl:8b`) — recommended; Alibaba's GUI-trained vision LLM. The model the rest of the local path is tuned against.
- **Gemma 4 Vision 9B** (`gemma4-vision:9b`) — Google. Conservative tool emitter.
- **Llama 3.2 Vision 11B** (`llama3.2-vision:11b`) — Meta. Older but battle-tested in Ollama.
- **Custom local model…** — type-your-own tag. Sent verbatim to Ollama; useful for experimenting with new releases (`qwen2.5-vl:7b`, `minicpm-v:8b`, etc.) without a Harness update.

**Server reachability surfaced in the UI.** Settings shows a pill (`reachable` / `unreachable`) plus the base URL field; Compose Run's Start button is gated on the last probe being green. First-run wizard adds an "Or run fully local" card with copy-paste install commands.

**Native Ollama `/api/chat` (not the OpenAI-compat shim).** The compat endpoint silently drops `options.num_ctx` — 0.5 calls `/api/chat` directly so Qwen3-VL 8B actually gets the 16k context it needs to hold a multi-step run's history. 600s URL timeout (Qwen3-VL 8B's cold start is ~5s model load + 60-90s first-token on M2). Subsequent warm requests typically settle under 60s.

**Honest trade-offs.** The per-run picker labels local models as **5-10× slower per step** with **lower friction-event quality** than cloud-class models — they get the job done, but Sonnet 4.6 will still beat them on synthesis. The [Local-vs-Cloud-Models wiki page](https://github.com/awizemann/harness/wiki/Local-vs-Cloud-Models) has a same-goal-same-site three-way head-to-head with concrete numbers.

The OpenAI-compatible path stays available for LM Studio users — `AppState.localBaseURL` is a free-form field. Standard 07 §12 documents the trade-offs between the two transports.

### Set-of-Mark everywhere (iOS + macOS + web)

0.3 shipped Set-of-Mark badges on web. 0.5 brings the same scaffolding to **iOS and macOS** — every screenshot the LLM sees now has numbered green pills over interactive elements; the agent calls `tap_mark(id)` instead of `tap(x, y)` on all three platforms. The disk PNGs stay clean (the marked image lives in an in-memory `ScreenshotMetadata.markedImageData` channel and never lands on disk, same invariant as web).

**iOS probe** walks WebDriverAgent's `/source?format=json` accessibility tree, filters to actionable XCUI roles (Button, Cell, TextField, Switch, Slider, SegmentedControl, etc.), and resolves rects from the AX frame. WDA 12.x returns short role names (`Button`) on some builds and long names (`XCUIElementTypeButton`) on others — both accepted via parallel `actionableIOSRolesShort` + `actionableIOSRolesLong` sets. **Cell label rollup**: when a Cell's own label is empty, the probe walks descendants up to 3 levels for StaticText/Image labels and joins them with " — " so the LLM sees "Settings — General — About" instead of "(unlabeled)".

**macOS probe** walks the AX tree via `AXUIElementCreateApplication(pid)`, filtered to actionable AX roles (`AXButton`, `AXTextField`, `AXLink`, `AXSecureTextField`, `AXSearchField`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXStepper`, `AXSwitch`, `AXMenuItem`, `AXTab`). Container roles (`AXWindow`, `AXGroup`, `AXScrollArea`) are walked-into instead of marked. Bounded walk: max depth 24, max 1500 nodes — keeps the probe under 200ms even on dense windows. Coordinates convert from global screen space to window-local by subtracting `windowOrigin`.

**Shared `MarkRenderer`** ([Harness/Platforms/MarkRenderer.swift](https://github.com/awizemann/harness/blob/main/Harness/Platforms/MarkRenderer.swift)) scales mark rects from point space to image space internally — iOS and macOS hand it point-space marks against pixel-resolution captures and the renderer does the math. Web's per-element overlay code now lives in the shared helper too; one annotation pipeline across all three platforms.

**`tap_mark` is now in the tool schema for all three platforms.** The cycle detector ([AgentLoop.recordPostStep](https://github.com/awizemann/harness/blob/main/Harness/Domain/AgentLoop.swift)) gained equivalence rules for `tap_mark` (same id), `scroll`, `navigate`, `back/forward/refresh`, `rightClick`, `keyShortcut`, and `fillCredential` — same-id taps in a row trip the detector the same way same-coordinate taps did.

### Smart settle gates on iOS + macOS

Fixed-sleep settle ("wait 150ms after every tool") routinely captured screens mid-animation, costing the agent a wasted step every time. 0.5 replaces the sleep with **screenshot-stability gating** on iOS and macOS — poll captures at 150ms cadence and accept the gate once two consecutive screenshots dHash within Hamming-distance 5.

Per-tool profiles balance latency vs. correctness:

- **Tap** — idle 250ms, min 250ms, max 2000ms.
- **Swipe** — idle 400ms, min 400ms, max 3000ms (longer max for momentum scroll).
- **Key shortcut / right click** — same as tap.

The web platform already had a `MutationObserver`-based DOM-quietness gate from 0.3; it now also handles SPA route transitions correctly via a `requireChildListMutation` flag (React Suspense keeps the old DOM mounted during route changes, so "idle 200ms after click" was firing on a stale page).

### HarnessCLI — development-time driver

New xcodegen target produces `harness-cli`, a development-time command-line driver that **shares the entire `Harness/` source root with the GUI app** and runs against `WebDriver` / `IOSPlatformAdapter` / `MacAppDriver` end-to-end. The same `RunCoordinator`, `RunLogger`, and event stream the GUI consumes — just no SwiftUI.

```bash
harness-cli \
  --platform web \
  --url https://alanwizemann.com \
  --goal "Find Alan's most recent article and tell me what it's about in your own words" \
  --persona "A curious first-time user" \
  --provider local \
  --model qwen3-vl:8b \
  --output ./test-run \
  --max-steps 15
```

Web, iOS, and macOS all supported via `--platform web|ios|macos`. iOS needs `--project-path` + `--scheme` + `--simulator-udid`; macOS needs `--app-path` and runs Screen Recording + Accessibility preflight checks. Cloud credentials come from env vars first (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY`) with a **system Keychain fallback** — the GUI's saved keys work for the CLI binary too, so you don't have to re-stash them in your shell.

`HARNESS_DUMP_MARKED=1` writes the marked PNG next to every step capture for debugging probe coverage.

`harness-cli` is **development-only** — not Developer-ID signed, not notarised, builds locally from this repo via `xcodebuild -scheme HarnessCLI build`. See the [HarnessCLI wiki page](https://github.com/awizemann/harness/wiki/HarnessCLI) for the full reference.

## Fixes

- **WebContent log flood silenced.** The off-screen `(-10_000, -10_000)` window placement triggered WebKit's aggressive volatile-layer scheduling — every snapshot tick failed to mark layers as volatile and emitted `WebProcess::markAllLayersVolatile: Failed` to the unified log multiple times per second. Window is now placed at `(0, 0)` with `alphaValue = 0`, `ignoresMouseEvents = true`, and `level = NSWindow.Level.normal - 1` — visually invisible, but WebKit sees a "real" on-screen window and doesn't try to free its layers. Live-mirror poller also dropped from 3fps to 1fps.
- **`simctl screenshot` exit-code flakes tolerated.** Rapid back-to-back captures occasionally produce a complete PNG on disk but exit non-zero. The driver now checks for a valid PNG header (`89 50 4E 47`) at the expected path and treats the capture as successful if the file looks right; only fails the screenshot if both the file is missing/short AND a 200ms-later retry also fails.
- **WDA `waitForReady` timeout bumped 45s → 120s.** iOS 26.2 simulators occasionally take 60-90s to stand up the WebDriverAgent session on first run; the old timeout was tripping during steady-state warm boots.
- **Non-persistent `WKWebsiteDataStore` for web runs.** Every run starts with a clean slate — no cookies, no localStorage, no IndexedDB. Two reasons: (1) reproducibility — SPAs storing theme/locale/dismissed-banner state would render differently across runs; (2) "what a fresh user sees" — Harness is a UX testing tool, the agent's screenshots are most informative when they reflect a first-time visitor's experience. Logged-in flows are still handled via `fill_credential(field:)`.
- **`NSAppearance` bound to system Dark Mode preference, not the host app.** The GUI binary may render itself in a different mode than macOS is set to; the agent's screenshots should match what the **user's** system is set to. `AppleInterfaceStyle` read from `UserDefaults.standard` to resolve.
- **Per-turn user-message reminder.** `LLMShared.currentTurnInstruction(annotation:)` prefixes every step's user message with the three behavior rules ("tap a text field first to focus it before calling type", "prefer `tap_mark` over `tap` when marks are available", "call `mark_goal_done` when the goal is genuinely complete"). Used by all four LLM clients. Helps smaller cloud models AND local models stay on-track without bloating the system prompt.

## Architecture notes

- **Shared `MarkRenderer`** at `Harness/Platforms/MarkRenderer.swift` — single annotation pipeline across iOS, macOS, and web. `InteractiveMark` struct, point-space `draw(on:marks:markSpaceSize:)`, `describe(_:)` annotation text helper.
- **`SimulatorDriving` protocol** gains `probeInteractiveElements(_:)` and `tapMark(id:on:)`. Per-UDID `lastMarks` cache lives on the driver actor.
- **`MacAppDriving` protocol** gains an AX-tree probe + `tapMark` dispatch. `dispatchMarkClick(id:info:)` viewport-clips the resolved coordinate so mark hits near the window edge don't slip into the surrounding desktop.
- **`docs/PROMPTS/platforms/ios.md`** — new platform context file with the critical "MUST `tap_mark` a text field FIRST to focus it before calling `type`" rule. Loaded via `PromptLibrary` with a Bundle-first → repo-root-fallback so the CLI binary picks it up without a Resources/ directory.
- **`HistoryCompactor.recentTurnsKeptLocal = 3`** (vs. `recentTurnsKept = 6` for cloud) — local models can't fit a 6-turn screenshot history at 16k context. The compactor swaps to the shorter cap when `request.modelProvider == .local`.
- **`HarnessPaths.runsRootOverride`** — when non-nil, `runDir(for:)` returns the override directly so CLI runs land flat in `--output` instead of nesting under a UUID. GUI never sets it.

## Run-log schema

Unchanged at **v3**. The Set-of-Mark extension to iOS + macOS uses the existing `tap_mark` tool-call shape from 0.3; no new row kinds. Existing v3 logs (and v2 / v1 logs) load unchanged.

## Tests

228 unit tests passing (was 223 in 0.3). New / extended suites:

- `OllamaClientTests` — full request/response round-trip against a mock URLSession, cancellation propagation, malformed-response handling, base-URL injection, custom-model-tag passthrough.
- `AgentToolsSchemaTests` — extended for `tap_mark` membership in iOS / macOS tool sets.
- `RunCoordinatorReplayTests` — happy-path / cycle-detection / step-budget tests now exercise both web AND ios platforms through the same scripted scenarios.
- `FakeServices` updated for the new `SimulatorDriving` / `MacAppDriving` protocol methods.

## Known limits

- **Local model latency.** Qwen3-VL 8B on M2 is ~5-10× slower per step than Sonnet 4.6. The token + step budgets remain the safety rails; for an 8-step run the wall-clock difference is "minutes vs seconds" not "hours vs minutes", but plan accordingly.
- **Stop button + Ollama GPU.** Pressing Stop during a local-model run cancels the Swift Task immediately (UI flips to `.failed` the same tick), but Ollama's `/api/chat` is non-streaming and the GPU stays busy computing the in-flight token for 30-90s before noticing the disconnect. Cosmetic for the user, but kicking off another local run immediately will queue behind the still-running one. Migrating `OllamaClient` to streaming mode would fix this; tracked for a future release.
- **Real iPhones still unsupported.** iOS targets remain Simulator-only. WebDriverAgent + idb against a real device is on the roadmap.
- **eBay-style hostile DOMs.** Closed shadow roots and cross-origin auth iframes are platform-impossible to introspect; the web driver falls back to coordinate-based targeting there.
- **2FA / human-in-the-loop interrupts** remain unsupported. Use test accounts without SMS/TOTP, or watch the Roadmap for the planned `request_user_input(reason, secret)` tool.

## Compatibility

- macOS 14+
- Apple Silicon (universal)
- Notarized + signed with Developer ID
- Existing 0.3 run records, Applications, Personas, Action chains, and credentials load unchanged.
- SwiftData stays at V5.
- Run-log schema stays at v3.
