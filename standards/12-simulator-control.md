# 12 — Simulator Control

Applies to: **Harness**

How Harness drives the iOS Simulator. Pairs with `03-subprocess-and-filesystem.md` (process plumbing) and [Simulator-Driver](https://github.com/awizemann/harness/wiki/Simulator-Driver) (the implementation deep-dive).

---

## 1. Why two tools

`xcrun simctl` and **WebDriverAgent** (vendored as `vendor/WebDriverAgent`, run via `xcodebuild test-without-building`) are complementary. Don't pick one — use both.

| Tool | Owns |
|---|---|
| `xcrun simctl` | Lifecycle: list devices, boot, install `.app`, launch by bundle id, terminate, screenshot, erase, status bar overrides. |
| WebDriverAgent | Input: `tap`, `swipe`, `keys`, `pressButton`. Drives the simulator through `XCUICoordinate.tap` etc., so events flow through the UIKit responder chain — not raw HID injection. |

`simctl` ships with Xcode (always present). WebDriverAgent is vendored as a git submodule and built once per iOS version into `~/Library/Application Support/Harness/wda-build/iOS-<ver>/`.

The simulator UI itself is `Simulator.app`. We hide its window during runs (Harness's mirror is the source of truth) but never script it.

> **Why not idb?** As of iOS 26+, `idb`'s HID-injection input layer renders the green tap dot but doesn't reach the responder chain — `idb ui tap` reports success, the simulator visualizes the touch, and the running app never sees a UIEvent. WDA goes through the XCTest framework's `XCUIApplication` / `XCUIElement` APIs — the path Apple supports and updates per iOS release. Harness migrated in Phase 5.

---

## 2. SimulatorRef

A typed handle for "this simulator":

```swift
struct SimulatorRef: Sendable, Hashable, Codable {
    let udid: String        // e.g. "B8C5A8F1-…"
    let name: String        // e.g. "iPhone 16 Pro"
    let runtime: String     // e.g. "iOS 18.4"
    let pointSize: CGSize   // e.g. (430, 932)
    let scaleFactor: CGFloat // e.g. 3.0 → pixel size 1290 × 2796
}
```

Resolved from `xcrun simctl list devices --json` at app launch and after the user changes the simulator selection. Never inferred from a name string at call time — the user can have multiple devices with the same name across runtimes.

The runtime label is the cache key for the WDA build (`iOS-18.4` for `runtime == "iOS 18.4"`). One build serves all simulators of that runtime.

---

## 3. Lifecycle commands

All issued through `ProcessRunner` per standard 03. The `SimulatorDriving` protocol:

```swift
protocol SimulatorDriving: Sendable {
    func listDevices() async throws -> [SimulatorRef]
    func boot(_ ref: SimulatorRef) async throws
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws
    func launch(bundleID: String, on ref: SimulatorRef) async throws
    func terminate(bundleID: String, on ref: SimulatorRef) async throws
    func erase(_ ref: SimulatorRef) async throws

    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL
    func tap(at point: CGPoint, on ref: SimulatorRef) async throws
    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws
    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws
    func type(_ text: String, on ref: SimulatorRef) async throws
    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws

    func startInputSession(_ ref: SimulatorRef) async throws
    func endInputSession() async
    func cleanupWDA(udid: String) async
}
```

Concrete invocations:

| Op | Command / Endpoint |
|---|---|
| List | `xcrun simctl list devices --json` |
| Boot | `xcrun simctl boot <udid>` (idempotent) |
| Install | `xcrun simctl install <udid> <app-bundle-path>` |
| Launch | `xcrun simctl launch <udid> <bundle-id>` |
| Terminate | `xcrun simctl terminate <udid> <bundle-id>` |
| Erase | `xcrun simctl erase <udid>` |
| Screenshot | `xcrun simctl io <udid> screenshot <out-path>` |
| Build WDA | `xcodebuild build-for-testing -project vendor/WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'id=<udid>' -derivedDataPath <cache>` |
| Start runner | `xcodebuild test-without-building -xctestrun <path> -destination 'id=<udid>'` |
| Open session | `POST http://127.0.0.1:8100/session` |
| Tap | `POST /session/<id>/wda/tap` body `{x, y}` |
| DoubleTap | Two `tap` calls with 80ms gap (no native double-tap-by-coord endpoint) |
| Swipe | `POST /session/<id>/wda/dragfromtoforduration` body `{fromX, fromY, toX, toY, duration}` |
| Type | `POST /session/<id>/wda/keys` body `{value: [String], frequency}` |
| Button | `POST /session/<id>/wda/pressButton` body `{name}` |

Every command above is wrapped in a typed Swift function; the call site uses the function, never a raw string.

---

## 4. Coordinate space

This is the #1 expected failure mode. **Test it.**

- `xcrun simctl io booted screenshot` writes a PNG at the device's **pixel** resolution (e.g., 1290 × 2796 for iPhone 16 Pro).
- WDA's coordinate endpoints take **points** (e.g., 430 × 932 for iPhone 16 Pro).
- The model returns coordinates in **points** (per the system prompt; we tell it the device's logical resolution at run start, and we downscale screenshots to point dimensions before sending).

`SimulatorDriver.toPoints(_:scaleFactor:)` is the single place pixel→point conversion happens. Everywhere else uses points.

`SimulatorDriverCoordinateTests` covers the conversion at scale 2 (SE) and 3 (Pro). Off-by-2x bugs would show as "agent always taps in the upper left" — visually obvious in the live mirror, but defended-in-depth here.

---

## 5. WDA lifecycle

WDA is a real test bundle running inside the simulator. Each run goes through:

1. **`cleanupWDA(udid:)`** — `pkill -f "xcodebuild.*test-without-building.*<udid>"` to remove any orphan runner from a previous crash. Tolerates "no matches" silently.
2. **`startInputSession(_:)`** —
   - `WDABuilder.ensureBuilt(forSimulator:)`: returns the cached `.xctestrun` if the WDA submodule SHA is unchanged; otherwise runs `xcodebuild build-for-testing` (~1–2 min).
   - `WDARunner.start(udid:xctestrun:port:)`: spawns `xcodebuild test-without-building` via `ProcessRunner.runStreaming`. The runner is a long-lived subprocess; cancellation flows through the streaming task → SIGTERM.
   - `WDAClient.waitForReady(timeout:)`: polls `GET http://127.0.0.1:8100/status` until 200 (typically 3–8s).
   - `WDAClient.createSession()`: `POST /session` with W3C capabilities; stores the session id internally.
3. (Run loop — `tap`/`swipe`/`type`/`pressButton` calls flow through `WDAClient` against the open session.)
4. **`endInputSession()`** — `DELETE /session/<id>`, then cancel the runner Task. Always called, including on failure paths.

Errors are typed: `WDABuildFailure`, `WDARunnerError`, `WDAClientError`, `SimulatorError`. The Run UI surfaces the most actionable case (e.g., `WDABuildFailure.compileFailed`'s `recoverySuggestion` includes the full xcodebuild log path).

---

## 6. Hiding Simulator.app

By default, Harness hides Simulator.app's macOS window when a run starts (`SimulatorWindowController.hide()` via `NSWorkspace.runningApplications`) and unhides it on run end. The simulator process and WDA inside it keep running — only the AppKit window is hidden.

The opt-out is `AppState.keepSimulatorVisible` (Settings toggle). Useful when debugging WDA's behavior directly.

---

## 7. Erase between runs

By default, the simulator state is **left in place** between runs so the user can iterate (e.g., "re-open the app, did onboarding stick"). The goal-input form has an "Erase simulator before run" toggle.

When erase is selected: shut down → `simctl erase <udid>` → boot → install → launch.

When erase is off: previous state stays. If the simulator is already booted and the same app installed, install is re-run (`simctl install` is idempotent).

---

## 8. Build artifact pickup

After `xcodebuild` (see [Xcode-Builder](https://github.com/awizemann/harness/wiki/Xcode-Builder)), the `.app` lives at:

```
<derivedDataPath>/Build/Products/Debug-iphonesimulator/<TargetName>.app
```

`XcodeBuilder` returns this URL directly — never run `find` or `glob` on derived data. Failure to find the artifact at the expected path is a typed error (`BuildFailure.artifactNotFound`).

The same path math finds the `.xctestrun` for the WDA build, except under the WDA cache directory (`~/Library/Application Support/Harness/wda-build/iOS-<ver>/Build/Products/`).

The bundle id is read from the `.app/Info.plist` (`CFBundleIdentifier`) at install time. The user does not enter it manually.

---

## 9. Status bar overrides

For deterministic screenshots, override the simulator status bar:

```bash
xcrun simctl status_bar <udid> override \
  --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 \
  --dataNetwork wifi --operatorName ""
```

Run once at boot. Reset on run end (`xcrun simctl status_bar <udid> clear`). Reduces visual noise in screenshots and removes a source of false "screen changed" detection in the cycle detector.

---

## 10. Audit checklist

When reviewing simulator-control code:

- [ ] Do all `simctl` and `xcodebuild` calls go through `ProcessRunner`?
- [ ] Do all WDA HTTP calls go through `WDAClient` (no ad-hoc URLSession.shared)?
- [ ] Is the coordinate conversion (pixel → point) confined to one place?
- [ ] Is `SimulatorRef.scaleFactor` populated from `simctl list devices --json` (not assumed)?
- [ ] Is `cleanupWDA(udid:)` called BEFORE boot at run start?
- [ ] Does `endInputSession` run on every exit path (success / failure / cancellation)?
- [ ] Is the `.app` artifact picked up by deterministic path computation, not `find`?
- [ ] Is the status bar override applied at boot for production runs?
- [ ] Are typed errors (`SimulatorError.*`, `WDA*Error`) used, not raw `ProcessFailure`, at the boundary into the agent loop?
