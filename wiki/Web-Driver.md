# Web Driver

The web run path. An embedded `WKWebView` in an off-screen `NSWindow`, driven by JavaScript injection for inputs and `WKSnapshotConfiguration` for screenshots. Set-of-Mark scaffolding annotates each interactive element with a numbered badge so the agent can target by id rather than guessing pixel coordinates.

The pair lives at:

| File | Role |
|---|---|
| `Harness/Platforms/Web/WebPlatformAdapter.swift` | `PlatformAdapter` implementation. Owns the lifecycle: spawns the WebView, loads the start URL, hands `RunCoordinator` a `RunSession` whose driver is a `WebDriver`. |
| `Harness/Platforms/Web/WebDriver.swift` | `UXDriving` actor. Screenshots, click / type / scroll / navigate dispatch, Set-of-Mark probe + draw, DOM-quietness settle gate. |
| `Harness/Platforms/Web/WebViewWindowController.swift` | Holds the `NSWindow` + `WKWebView` on the main actor, navigation delegate. |
| `Harness/Platforms/Web/LiveWebMirror.swift` | Side channel for the GUI's live preview to subscribe to the active driver's snapshots. Not used by `HarnessCLI`. |

## Lifecycle

```
WebPlatformAdapter.prepare(_:runID:continuation:)
  1. Read request.webStartURL + webViewport{Width,Height}Pt
  2. Resolve preferred viewport (canvas-aspect-aware on GUI; configured size on CLI)
  3. Spawn WebViewWindowController on @MainActor at (-10_000, -10_000)
  4. webView.load(URLRequest(url: startURL))
  5. await navigationDelegate.awaitNextLoad(timeout: 20s)
  6. Construct WebDriver(controller, startURL, viewport, credential)
  7. driver.awaitDOMSettled(idleMs: 800, minMs: 800, maxMs: 10_000)
  8. yield .simulatorReady(pseudoSimRef)
  9. Return RunSession{ driver, pointSize: viewport, ... }
```

`teardown(_:)` closes the WebView's hosting window. Idempotent.

## Screenshot pipeline

`WebDriver.screenshot(into:)` runs once per agent step. The path:

```
1. probeInteractiveElements()       → [InteractiveMark]   (lastMarks cache)
2. captureSnapshot()                → NSImage at viewport CSS-pixel dimensions
3. write unmarked PNG to disk       (replay / friction-report / human review)
4. drawMarks(on: raw, marks, viewport)  → marked NSImage  (if marks ≥ 1)
5. encode marked → PNG bytes        → ScreenshotMetadata.markedImageData
6. (dev) HARNESS_DUMP_MARKED=1      → also write step-NNN.marked.png to disk
```

`RunCoordinator` reads `markedImageData` for the LLM-bound JPEG and the unmarked URL for everything else. The disk PNG **stays unmarked** so replay and friction reports never show agent scaffolding.

## Set-of-Mark

The agent never targets raw `(x, y)` for visible interactive elements. Instead, the screenshot it receives carries numbered green-pill badges floating just above each focusable target; the agent calls `tap_mark(id)` and `WebDriver.dispatchMarkClick(id:)` resolves to the element's center, then routes through the same click path as `tap`.

### Probe selector

The probe runs in WKWebView JavaScript inside `screenshot(into:)`. It walks the document (including open shadow roots) for the selector below, filters by visibility / size / bounds, sorts top-to-bottom then left-to-right, and caps at 80 marks per screenshot.

```
input:not([type="hidden"]):not([type="button"]):not([type="submit"]):not([type="reset"])
textarea
select
button
input[type="button"] | input[type="submit"] | input[type="reset"]
a[href]:not([href=""]):not([href="#"]):not([href^="javascript:"])
[role="link"]
[role="button"]
[role="checkbox"] | [role="radio"]
[role="textbox"] | [role="combobox"] | [role="searchbox"]
[role="switch"] | [role="menuitem"] | [role="tab"]
[contenteditable=""] | [contenteditable="true"]
```

**Anchors and `[role="link"]` are included.** Earlier the selector excluded them ("they bloated the mark count"), but every modern SPA's navigation is `<a href="...">` (Next.js Link, React Router Link, …). Without anchor coverage, top-of-page nav was never badged, and small vision models fell back to `tap(x, y)` and routinely missed by 50-100 CSS pixels at typical desktop resolutions — verified empirically against `alanwizemann.com` with Qwen3-VL 8B. The badge-clutter risk is mitigated by:

- Dropping decorative anchors (`href=""`, `href="#"`, `javascript:*`)
- Dropping big interactive containers with no visible label (`< 200×100` rect or has a label)
- Capping total badges at 80 per screenshot, in reading order

### Badge rendering

`drawMarks(on:marks:viewport:)` (nonisolated, runs off-actor for compute parallelism):

- Outline: 2pt stroke at `HarnessColor.accent` 0.85 alpha around the element's CSS bounding rect.
- Badge: green-accent pill, 22pt-bold white number, ≥ 32×30pt.
- Position: floats just **above** the element's top edge (4pt gap). Clamped inside the image when the element is right at the viewport top, so badges always stay drawable.

Sizing rationale: local sub-10B vision models (Qwen3-VL, Gemma 4, Llama 3.2 Vision) receive the JPEG clamped to a 768pt long edge (see `AgentModel.screenshotMaxLongEdge`), which on a 1280pt-wide viewport is a 0.6× downscale. A 22pt-bold badge becomes ~13pt — readable. The prior 13pt-medium sizing collapsed to ~8pt after downscale and was effectively invisible to small vision models. Cloud models get the native-resolution image; the slightly chunkier badges are visually fine and never seen by humans (disk PNGs are unmarked).

Placement rationale: the original "top-left inside the rect" position covered the first 2-3 characters of label text. The model read "perience" for `[4]` Experience, "icles" for `[6]` Articles. Floating above keeps the label readable and the badge legible at the same time.

### Tool surface

| Tool | What it does | When the agent uses it |
|---|---|---|
| `tap_mark(id)` | Resolves `id` against `lastMarks`, dispatches a click on the element's center via the standard click path | First-line tool for every visible interactive element. The system prompt at `docs/PROMPTS/platforms/web.md` strongly prefers this. |
| `tap(x, y)` | `document.elementFromPoint(x, y)` + native-or-synthetic click dispatch | Unmarked positions only — scrollable regions, image-tap targets, decorative anchors. |
| `tap_mark(id)` on stale id | Throws `WebDriverError.unknownMark(id:)` → loop retry hint surfaces "that id wasn't in the latest screenshot's mark set" | Never intentional — id mismatch usually means the page changed between screenshots. |

`mark.id` is 1-based and refreshes every screenshot. The agent **never reuses an id from an earlier turn** — it always reads the current screenshot's badges. See `Models.swift` → `ToolKind.tapMark` and the system prompt at `docs/PROMPTS/platforms/web.md` for the agent-facing description.

## Click dispatch

`dispatchClick(x:y:button:count:)` injects JS that:

1. Runs `document.elementFromPoint(x, y)`. Returns `{ ok: false, reason: 'no-element-at-point' }` if nothing's there.
2. Walks up the DOM via `closest('a[href], button, input[type="button"], input[type="submit"], [role="button"], [role="link"], [role="menuitem"], [role="tab"]')` to find the **best interactive ancestor**.
3. **If found (left-click only)**: calls `interactive.click()`. This is the native browser path — for anchors, `e.preventDefault()` handlers in React's onClick (`router.push(...)`) fire correctly; routers that gate on `event.isTrusted` see the standard non-trusted browser-generated path.
4. **Otherwise**: dispatches synthetic `mousedown` + `mouseup` + `click` events with `bubbles: true`. React's root-level synthetic listener catches the event.
5. Focus routing — after the click, walks the DOM to find the best focusable target (input / textarea / contenteditable) and calls `.focus()` so a follow-up `type` lands on the right field.

The JS returns `{ ok, elementTag, interactiveTag, url }`. The Swift side logs it via `os.Logger` (subsystem `com.harness.app`, category `WebDriver`):

```
click (x, y) → element=<tag> interactive=<tag[href=...]> url=<final href>
```

`HarnessCLI` runs with `HARNESS_DUMP_MARKED=1` also write this diagnostic to stderr so the user sees exactly what each click hit — invaluable for diagnosing "the model keeps tapping but the page doesn't change" failure modes.

## DOM-quietness settle gate

Static-content sites are fine with a fixed 1.5s sleep after navigation. SPAs are not — they fire WKWebView's `didFinish` once the initial HTML parses, then continue hydrating React/Vue/Svelte components, fetching content, loading lazy images, mounting heavy widgets for seconds afterward. The fixed-sleep era captured screenshots mid-hydration and fed the agent images of half-loaded pages.

`WebDriver.awaitDOMSettled(idleMs:minMs:maxMs:)` replaces the fixed wait with an adaptive gate:

```swift
let waitedMs = await driver.awaitDOMSettled(idleMs: 600, minMs: 600, maxMs: 8000)
```

It uses `WKWebView.callAsyncJavaScript` (a Promise-aware native API) to install a `MutationObserver` on `document.documentElement` that observes `childList`, `subtree`, `attributes`, and `characterData`. The body polls every ~50-150ms and resolves when:

- The DOM has gone **`idleMs` without a mutation** AND total elapsed ≥ `minMs`, OR
- Total elapsed ≥ `maxMs` (hard ceiling)

The settle parameters are call-site-tuned:

| Call site | `idleMs` | `minMs` | `maxMs` | Rationale |
|---|---|---|---|---|
| `WebPlatformAdapter.prepare` (initial load) | 800 | 800 | 10000 | First load needs the most room for hydration. |
| `WebDriver.settle(afterTool:)` for navigate / back / forward / refresh | 600 | 600 | 8000 | Route changes re-render whole pages. |
| `WebDriver.settle(afterTool:)` for tap / scroll / type / etc. | 250 | 250 | 2000 | Same-page interactions: paint settle for popovers / drawers / hover transitions. |

`minMs` is the floor: even if `MutationObserver` reports zero mutations immediately (very fast pages), wait at least this long before letting the agent see a screenshot. This prevents the gate from resolving during the moment between "shell parsed" and "hydration started" on SPAs whose hydration arrives in a burst.

Falls back to a fixed `Task.sleep(for: .milliseconds(minMs))` on JS bridge failure (rare — usually means the page was navigated away mid-call).

## Diagnostic env vars (dev-only)

| Variable | Effect |
|---|---|
| `HARNESS_DUMP_MARKED=1` | `WebDriver.screenshot` writes the marked PNG to disk next to the unmarked one (`step-NNN.marked.png`). Click and tap_mark dispatch also write a one-line diagnostic to stderr: `[WebDriver] tap_mark(6) label="Articles" role=a rect=(725,21,76,40) → click(763,41)` followed by `[WebDriver] → element=A interactive=A[href=/articles] url=https://...`. Useful when running [HarnessCLI](HarnessCLI) — gives you ground truth on exactly what the agent sees and what its tool call actually targets. |
| `HARNESS_OLLAMA_URL` | Override for the local Ollama base URL (default `http://127.0.0.1:11434`). Read by `HarnessRunner` in the CLI; read by `AppState.localBaseURL` in the GUI. |

Both env vars are no-ops when unset — production GUI runs are unaffected.

## Failure modes to keep in mind

- **`probeInteractiveElements` returns []**: the page has no focusable elements visible, or the JS bridge timed out (very rare). Marks fall back to empty; the agent can still call `tap(x, y)`. The disk PNG carries no overlay.
- **Stale mark id**: agent emits `tap_mark(id)` but the page changed between the screenshot it reasoned about and the click — `lastMarks` no longer has that id. `WebDriverError.unknownMark(id:)` throws; the loop's retry hint tells the model to read fresh badges.
- **Click hits non-interactive parent**: `closest(...)` returns null; synthetic `MouseEvent` fires; React onClick may or may not match. If `interactiveTag=none` and the URL didn't change, the click was a no-op. `HARNESS_DUMP_MARKED=1` surfaces this directly.
- **Cross-origin iframes / closed shadow roots**: the probe can't see into either. Marks are missing for elements inside them. Not currently addressed — most real-world goals don't traverse cross-origin iframes.

## Cross-references

- [HarnessCLI](HarnessCLI) — the development-time driver that surfaces all the diagnostics described here.
- [Agent-Loop](Agent-Loop) — how the per-step decision uses `markedImageData` and routes tool calls.
- [Tool-Schema](Tool-Schema) — the canonical tool list including `tap_mark`.
- [Run-Replay-Format](Run-Replay-Format) — what gets written to `events.jsonl` for each click / scroll.
- `Harness/Platforms/Web/WebDriver.swift` — the implementation.
- `docs/PROMPTS/platforms/web.md` — the platform context block injected into the system prompt for web runs.
