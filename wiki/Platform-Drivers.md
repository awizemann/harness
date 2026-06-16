# Platform Drivers

Harness drives three platforms — iOS Simulator, macOS app, and web. Each platform has a driver that handles building, launching, screenshotting, Set-of-Mark probing, and input execution.

## Architecture overview

All platforms conform to a **`SimulatorDriving`** protocol (or platform-specific variant like `MacAppDriving`), enabling the `RunCoordinator` and `AgentLoop` to work platform-agnostically. The driver abstracts:

- **Building** — xcodebuild for iOS/macOS; web needs no build.
- **Launching** — simctl + WebDriverAgent for iOS; NSWorkspace + process monitoring for macOS; WKWebView for web.
- **Screenshotting** — WDA endpoint for iOS; CGWindowListCreateImage for macOS; WKWebView.takeSnapshot for web.
- **Set-of-Mark probing** — accessibility tree for iOS/macOS; DOM walk for web.
- **Input** — WebDriverAgent endpoints for iOS; CGEvent for macOS; JS-synthesized events for web.
- **Settle gates** — screenshot stability polling (iOS/macOS via dHash; web via MutationObserver).

## iOS Simulator driver

**Location:** `Harness/Services/SimulatorDriver.swift` (iOS portions) + `Harness/Services/WDABuilder.swift` + `Harness/Services/WDAClient.swift`

### Build and launch pipeline

1. **WDABuilder** — builds WebDriverAgent once per iOS version and caches under `~/Library/Application Support/Harness/wda-build/iOS-<ver>/`.
   - Runs `xcodebuild build-for-testing` on the vendored `vendor/WebDriverAgent` submodule.
   - SHA of the submodule commits determines if a rebuild is needed.
   - Result is an `.xctestrun` bundle.

2. **SimulatorDriver.boot(...)** — uses `xcrun simctl` to:
   - Check if the simulator already boots; if yes, don't re-boot (idempotent).
   - If cold, boot it and poll until `simctl list --json` reports it as booted.
   - Apply status bar overrides (hide time, battery, signal icons) so screenshots are consistent.

3. **SimulatorDriver.install(...)** — `simctl install <sim-id> <app-bundle>`.

4. **SimulatorDriver.launch(bundleID:)** — `simctl launch <sim-id> <bundle-id>`.

5. **WDARunner** — after launch, spawns a long-running `xcodebuild test-without-building` with the cached `.xctestrun` against the target simulator. WDA starts an HTTP server on the simulator's local network interface (via `iproxy` tunneling).

6. **WDAClient** — URLSession HTTP client that connects to WDA's local server and calls W3C / `/wda/*` endpoints.

### Screenshot + Set-of-Mark

```swift
func screenshot() async throws -> ScreenshotMetadata
```

1. **Raw screenshot** — call WDA `/screenshot` endpoint → PNG bytes.
2. **AX tree probe** — call WDA `/source?format=json` → accessibility tree as JSON (AppKit AX elements + their labels, values, enabled state).
3. **Mark assignment** — walk the AX tree, identify interactive elements (buttons, text fields, cells), assign numeric IDs (1, 2, 3, ...).
4. **Image overlay** — PIL or equivalent marks the PNG with small green badges labeled with IDs, for the LLM's eyes only.
5. **Return** — `ScreenshotMetadata` containing:
   - `screenshotData` — the **clean** PNG (no marks on disk).
   - `markedImageData` — the marked PNG for the LLM.
   - `marks` — array of `{ id: Int, label: String, x: Int, y: Int, width: Int, height: Int }`.
   - `axTree` — raw AX JSON for reference.

**Cell label roll-up:** if a cell contains child images and text fields, the label is synthesized as `"<StaticText1> — <StaticText2> — <Image>"` so the LLM sees context (e.g., "Settings — General — About") instead of `"(unlabeled)"` for each child.

### Input execution

**Tap:**
```swift
func tap(at point: CGPoint) async throws
```
- Via `tap_mark(id)`: resolve ID to a coordinate in the marks array, tap.
- Via `tap(x, y)`: direct coordinate.
- WDAClient calls `/wda/tap` endpoint.
- **Settle gate:** poll screenshot stability via dHash until idle ≥250ms, max 2s.

**Swipe:**
```swift
func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws
```
- WDAClient calls `/wda/swipe` endpoint.
- **Settle gate:** poll screenshot stability via dHash until idle ≥400ms, max 3s.

**Type:**
```swift
func type(text: String) async throws
```
- WDAClient calls `/wda/type` endpoint (assumes focus is already in a text field).
- Settle gate: wait 200ms (no polling; text input doesn't trigger layout shifts as often).

**Credential fill:**
```swift
func fillCredential(field: String) async throws
```
- Resolve the credential from `Application.credentials` (stored in SwiftData).
- Call `/wda/type` with the username or password.
- JSONL log records `{ "field": "<field>" }` only, no plaintext password.

### Settle gates

After each tool execution, the driver polls for screenshot stability. iOS driver uses **dHash** (difference hash):

1. Compute a 64-bit perceptual hash of the current screenshot.
2. Compare to the previous hash via Hamming distance (bit-flip count).
3. If distance ≤5 and idle time ≥threshold, accept the gate (default: 250ms idle for tap, 400ms for swipe).
4. If idle time exceeds max (2s for tap, 3s for swipe), time out and accept anyway (assume the target is stalled).

This replaces fixed sleep timers, which often captured mid-render or mid-animation frames.

## macOS driver

**Location:** `Harness/Services/MacAppDriver.swift`

### Build and launch

1. **XcodeBuilder** — if the Application uses an Xcode scheme, builds via `xcodebuild` and returns the `.app` bundle path. If pre-built, `MacAppDriver` uses the `.app` as-is.
2. **Launch** — `NSWorkspace.shared.openApplication(...)` or `NSWorkspace.shared.open(...)` the `.app` bundle or `.app/Contents/MacOS/<binary>` directly.
3. **Process monitoring** — track the process PID so we can terminate it on cleanup.

### Screenshot + Set-of-Mark

```swift
func screenshot() async throws -> ScreenshotMetadata
```

1. **Window capture** — `CGWindowListCreateImage` fetches the target app's main window → CGImage → convert to PNG.
2. **AX tree probe** — `AXUIElementCreateApplication` + AXUIElement queries to walk the app's accessibility tree (buttons, fields, menus, etc.).
3. **Mark assignment** — walk the tree, identify interactive elements, assign IDs.
4. **Image overlay** — mark the PNG with badges for the LLM.
5. **Return** — `ScreenshotMetadata` as above.

### Input execution

**Tap:**
```swift
func tap(at point: CGPoint) async throws
```
- Convert screen coordinates to app-local coordinates (account for window position).
- Synthesize a left-mouse-down, then left-mouse-up via `CGEvent`.
- Settle gate: poll screenshot stability via dHash (250ms idle, 2s max).

**Swipe:**
```swift
func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws
```
- Synthesize a left-mouse-down at `from`, then a series of left-mouse-move events to `to` over `duration`, then left-mouse-up.
- Settle gate: dHash poll (400ms idle, 3s max).

**Type:**
```swift
func type(text: String) async throws
```
- Use AX APIs to find the currently-focused text field, then synthesize key-down/key-up events for each character.
- Settle gate: wait 200ms.

**Credential fill:**
- Same as iOS; resolve and type the credential from the Application's stored list.

## Web driver

**Location:** `Harness/Services/WebDriver.swift`

### Setup

1. **WKWebView instance** — created off-screen in a transparent NSWindow at `(0, 0)` with `alphaValue = 0` and window level below normal.
   - Invisible to the user but real enough that WebKit doesn't try to free layers.
   - Viewport size configurable: default **1280×1600** (tall desktop); also supports mobile (375×812).
   - Non-persistent data store (fresh cookies/storage per run, reproducible behavior).

2. **Initial navigation** — `webView.load(URLRequest(url: goal.appURL))` and wait for page to stabilize.

3. **Status bar override** — inject JS to hide browser UI elements (address bar, tabs) so the page screenshot fills the frame.

### Screenshot + Set-of-Mark

```swift
func screenshot() async throws -> ScreenshotMetadata
```

1. **Viewport snapshot** — `WKWebView.takeSnapshot(configuration:, completionHandler:)` → NSImage → PNG bytes (captures rendered page at the configured viewport size).
2. **DOM probe** — inject JS:
   ```javascript
   document.querySelectorAll('button, input, [role="button"], a[onclick], ...')
   ```
   Walk each element: compute bounding rect, check if visible (offsetHeight > 0), check if interactive (not disabled, not hidden). Assign IDs.
3. **Mark overlay** — JS injects small `<div>` badges absolutely positioned over each marked element (SVG or Canvas overlay; never persisted to disk).
4. **Return** — `ScreenshotMetadata` with snapshot, marks array, and optional DOM dump.

**Shadow DOM piercing:** modern web apps (React, custom elements, payment widgets) use shadow roots. The DOM probe pierces them by checking each element's `shadowRoot` and recursing.

### Input execution

**Tap:**
```swift
func tap(at point: CGPoint) async throws
```
- Via `tap_mark(id)`: resolve ID to element in DOM, call `element.click()`.
- Via `tap(x, y)`: use `document.elementFromPoint(x, y)` to find the element at that coordinate, then click it.
- Settle gate: `MutationObserver` watches the DOM for changes; gate closes when the DOM is quiet for 200ms.

**Swipe:**
```swift
func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws
```
- Synthesize `touchstart` → `touchmove` (series) → `touchend` events via `createEvent` + `initTouchEvent` (or `new PointerEvent` on modern browsers).
- Settle gate: `MutationObserver` (200ms quiet).

**Type:**
```swift
func type(text: String) async throws
```
- Find the focused input (via `document.activeElement`) or the element most recently tapped.
- Use the `Object.getOwnPropertyDescriptor` trick to set the value directly (so React's value tracker sees the change).
- Synthesize `input` and `change` events.
- Settle gate: 200ms.

**Navigate:**
```swift
func navigate(to url: URL) async throws
```
- `webView.load(URLRequest(url:))` and wait for page to stabilize.
- Settle gate: `MutationObserver` (200ms quiet).

**Credential fill:**
- Resolve credential, then use the type flow to fill text fields (usually username/password pair).

### Settle gates (DOM quiet check)

Web uses a `MutationObserver` instead of screenshot polling:

```javascript
const observer = new MutationObserver(() => {
  lastMutationTime = Date.now();
});
observer.observe(document.documentElement, {
  attributes: true,
  childList: true,
  subtree: true
});
```

The gate checks: `Date.now() - lastMutationTime >= idleThreshold` (default 200ms). If mutations keep firing, the gate waits up to 3s.

**`requireChildListMutation` flag:** SPAs (React, Vue) often change the DOM subtly. Route transitions in React Suspense keep the old DOM mounted while the new one loads, so "DOM quiet" fires on stale state. The flag (set per SPA, per Application in settings) requires at least one `childList` mutation before closing the gate.

## Testing

Each driver has unit tests:

- **SimulatorDriver tests** — mock WDAClient, verify screenshot parsing, coordinate scaling (`toPoints` conversion from device pixels to points).
- **MacAppDriver tests** — mock AX APIs, verify window capture and element probing.
- **WebDriver tests** — mock WKWebView, verify DOM probe JS injection and settle-gate logic.
- **Replay-based integration tests** — pre-recorded run logs with real platform responses (sanitized PNGs) are replayed to ensure the driver round-trips correctly.

See `tests/Services/` for implementations.