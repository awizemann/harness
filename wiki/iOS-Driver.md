# iOS Driver

The iOS run path. A booted iOS Simulator, an installed `.app`, and a `WebDriverAgent` test runner that drives input + exposes the live accessibility tree. Set-of-Mark scaffolding annotates each interactive element with a numbered badge so the agent can target by id rather than guessing pixel coordinates — same contract as [Web-Driver](Web-Driver) and [macOS-Driver](macOS-Driver).

| File | Role |
|---|---|
| `Harness/Platforms/iOS/IOSPlatformAdapter.swift` | `PlatformAdapter` lifecycle: build → boot → install → launch → start WDA input session → drive → teardown. Wraps `SimulatorDriver` so `RunCoordinator` stays platform-neutral. |
| `Harness/Services/SimulatorDriver.swift` | The actor that owns the per-run WDA stack. Routes `tap` / `swipe` / `type` / `pressButton` through `WDAClient`. Caches `lastMarks` per UDID for `tap_mark` dispatch. |
| `Harness/Services/WDAClient.swift` | URLSession HTTP client for WebDriverAgent's W3C endpoints. Source-of-truth for the AX probe + tap_mark resolution. |
| `Harness/Services/WDABuilder.swift` | Builds + caches the WDA xctestrun per iOS major.minor under `~/Library/Application Support/Harness/wda-build/`. SHA-gated rebuild. |
| `Harness/Services/WDARunner.swift` | Manages the `xcodebuild test-without-building` process hosting WDA inside the simulator. Cancellation flows through SIGTERM. |
| `Harness/Platforms/MarkRenderer.swift` | Shared with web and macOS. Draws numbered badges onto a copy of the screenshot, scaling mark rects from point space (what AX returns) to image space (pixel-resolution capture). |

## Lifecycle

```
IOSPlatformAdapter.prepare(_:runID:continuation:)
  1. XcodeBuilder.build(project, scheme, runID)   → buildStarted / buildCompleted
  2. SimulatorDriver.cleanupWDA(udid)              # kill any orphan from a prior crash
  3. SimulatorDriver.boot(ref)
  4. SimulatorDriver.install(appBundle, on: ref)
  5. SimulatorDriver.launch(bundleID, on: ref)
  6. SimulatorDriver.startInputSession(ref)        # WDABuilder.ensureBuilt → WDARunner.start → WDAClient.waitForReady → createSession
                                                   → simulatorReady
  7. Return RunSession{driver: IOSSimDriver, pointSize: ref.pointSize, ...}
```

Teardown runs `endInputSession()` regardless of run outcome (success / failure / cancellation).

`WDAClient.waitForReady` is 120s today — WDA's xcodebuild handoff can take 60-90s on iOS 26.2 simulators that weren't recently warmed. Bumped from 45s after CLI iOS runs hit timeouts on cold caches.

## Screenshot pipeline

`IOSSimDriver.screenshot(into:)` per agent step:

```
1. simulatorDriver.probeInteractiveElements(ref)  → [InteractiveMark]
   (cached on SimulatorDriver actor as lastMarks[ref.udid])
2. simulatorDriver.screenshot(ref, into: url)     → PNG at pixel resolution
3. If marks empty: return early, no overlay.
4. Otherwise: load PNG → MarkRenderer.draw(on:, marks:, markSpaceSize: ref.pointSize)
   The renderer scales mark rects (point space) up to image space (pixel = points × scaleFactor)
5. Encode the marked image, dump alongside the unmarked PNG if HARNESS_DUMP_MARKED=1
6. Return ScreenshotMetadata{ pixelSize, pointSize, markedImageData, markedAnnotationText }
```

`RunCoordinator` reads `markedImageData` for the LLM-bound JPEG and the unmarked URL for replay / friction reports. Disk PNG stays clean.

## Set-of-Mark probe

`WDAClient.probeInteractiveElements()` calls WDA's `/source?format=json`, parses the AX tree (an `Application` root with nested `Window` / `Other` / `Cell` / `Button` etc.), and returns a sorted, capped list of `InteractiveMark`s.

### Probe selector

Actionable XCUI roles, accepted in **both** short (`Button`) and long (`XCUIElementTypeButton`) forms. WDA 12.x returns short names; older builds returned long names. Accepting both keeps the probe forwards/backwards compatible.

| Category | Roles |
|---|---|
| Buttons + menus | Button, MenuButton, PopUpButton, MenuItem |
| Text input | TextField, SecureTextField, SearchField, TextView |
| Selection | CheckBox, RadioButton, Switch, Slider, Stepper |
| Lists | Cell |
| Pickers | Picker, PickerWheel, DatePicker |
| Tabs | Tab |
| Hardware-style | Key |

Containers (`NavigationBar`, `TabBar`, `Toolbar`) are walked instead of marked — the bar itself isn't a tap target, but its children (back button, tab items) are.

The probe filters out elements with sub-16pt rect dimensions (likely decorative) and stops recursing once it hits an actionable ancestor (avoids double-marking a `Cell` that contains a `Button`).

### Label rollup for empty Cells

iOS table-view cells commonly carry no AX label themselves — the visible text lives in child `StaticText` nodes. Before the rollup fix, a server-list cell came back as `label=""` and the agent had nothing to match its intent against.

`resolveLabel` now:

1. Tries the node's own `label` / `name` / `value` attributes.
2. If empty, walks descendants up to 3 levels deep, collecting up to 3 `StaticText` / `Image` (alt-text) labels.
3. Joins them with ` — `.

Empirically this turned `label=""` into `label="server.rack — 127.0.0.1 — alanwizemann@127.0.0.1"` on Scarf Mobile's servers screen.

## tap_mark dispatch

`SimulatorDriver.tapMark(id:on:)`:

1. Resolves `id` against `lastMarks[ref.udid]`. Stale id → `SimulatorError.actionFailed` ("id wasn't in the latest screenshot's mark set"); the loop's retry hint surfaces the message and the next turn's probe refreshes the marks.
2. Clips the mark's rect to the simulator viewport with a 4pt inset. Off-viewport midpoints (table cells extending past the screen bottom) would otherwise resolve to a hit-untestable coordinate; the clip guarantees the dispatch coord sits on a visible pixel.
3. Posts a WDA tap at the clipped midpoint.

`HARNESS_DUMP_MARKED=1` writes a diagnostic to stderr:

```
[WDA] tap_mark(6) label="Articles" role=button rect=(725,21,76,40) → tap(763,41)
```

## Settle gate

iOS has no DOM mutation observer; the equivalent is **screenshot dHash stability** (`IOSSimDriver.awaitScreenshotStable`).

The gate polls `simctl io screenshot` at ~150ms cadence, dHashes each capture (using the same `ScreenshotHasher` the agent loop's cycle detector uses), and resolves when two consecutive captures land within `cycleHashThreshold` Hamming distance AND `minMs` has elapsed.

Per-tool profiles:

| Tool family | idleMs | minMs | maxMs | Rationale |
|---|---:|---:|---:|---|
| tap / doubleTap / tapMark / pressButton / fillCredential | 250 | 250 | 2000 | Most taps converge in ≤400ms; allow up to 2s for modal/push transitions. |
| swipe | 400 | 400 | 3000 | Scroll deceleration + reflow commonly runs 600-900ms. |
| type | — | — | — | Native text-field input echoes synchronously; no animation worth gating on. |
| All others | — | — | — | No settle. |

Capture failures aren't run-fatal — the gate just times out at `maxMs`.

## tap_mark vs tap

Both ship in the iOS canonical tool set. The platform prompt at `docs/PROMPTS/platforms/ios.md` (and the per-turn user-message reminders generated by `LLMShared.currentTurnInstruction`) push agents to prefer `tap_mark` whenever a mark is visible. Empirically, the local-model story falls apart when the agent goes off-script with raw coordinates (the model's spatial reasoning at the LLM-side downscale isn't good enough); cloud models tolerate `tap` more gracefully but still benefit from the mark scaffolding.

## Why `type` requires `tap_mark` first

`type` writes to the **currently-focused** text field via WDA's `/wda/keys` endpoint. If no field is focused, the call silently succeeds but writes nothing. The platform prompt explicitly tells agents to `tap_mark` a text field BEFORE calling `type` — empirically Qwen3-VL would otherwise call `type` immediately on a freshly-loaded form, see no change in the next screenshot, and loop until the cycle detector or step budget bailed.

## Diagnostic env vars

| Variable | Effect |
|---|---|
| `HARNESS_DUMP_MARKED=1` | Writes `step-NNN.marked.png` next to the unmarked PNG (the actual marked image the LLM sees). Each tap_mark dispatch logs `[WDA] tap_mark(...) label=... role=... rect=... → tap(...)` to stderr. |

## Failure modes worth knowing

- **WDA never becomes ready** (timeout at 120s): WDA build cache might be stale, or the simulator's iOS version doesn't match what WDABuilder cached. Look in `~/Library/Application Support/Harness/wda-build/iOS-<version>/Build/Products/`.
- **Probe returns []**: AX tree isn't populated yet (app mid-launch) or WDA's `/source` errored. Re-running picks up the next session's probe.
- **`tap_mark(id)` throws `unknownMark(id:)`**: the mark id refers to a previous turn's cache. The retry-hint surfaces this to the model; next turn's screenshot has fresh ids.
- **Type without focus**: silent no-op. The platform prompt covers this rule; if you see it happen, the model didn't read the prompt — strengthen `LLMShared.currentTurnInstruction` reminders.

## Cross-references

- [HarnessCLI](HarnessCLI) — `--platform ios --project-path ... --scheme ... --simulator-udid ...`
- [Web-Driver](Web-Driver) — the same Set-of-Mark contract on WKWebView
- [macOS-Driver](macOS-Driver) — the same on AX API
- [Agent-Loop](Agent-Loop), [Tool-Schema](Tool-Schema)
- `docs/PROMPTS/platforms/ios.md` — the iOS platform-context block
