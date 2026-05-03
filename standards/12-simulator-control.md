# 12 — Simulator Control

Applies to: **Harness**

How Harness drives the iOS Simulator. Pairs with `03-subprocess-and-filesystem.md` (process plumbing) and `wiki/Simulator-Driver.md` (the implementation deep-dive).

---

## 1. Why two tools

`xcrun simctl` and `idb` are complementary. Don't pick one — use both.

| Tool | Owns |
|---|---|
| `xcrun simctl` | Lifecycle: list devices, boot, install `.app`, launch by bundle id, terminate, screenshot, erase, set status bar overrides. |
| `idb` (+ `idb_companion`) | Input: `tap`, `swipe`, `text`, `key`. Plus `ui describe-all` for accessibility-tree fallback. |

`simctl` ships with Xcode (always present); `idb` ships via Homebrew (must be installed first-run). The simulator UI itself is `Simulator.app`, which we drive only through the two CLIs above — we don't AppleScript it as a primary path.

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
}
```

Concrete invocations:

| Op | Command |
|---|---|
| List | `xcrun simctl list devices --json` |
| Boot | `xcrun simctl boot <udid>` (idempotent — already-booted is a warning, not an error) |
| Install | `xcrun simctl install <udid> <app-bundle-path>` |
| Launch | `xcrun simctl launch <udid> <bundle-id>` |
| Terminate | `xcrun simctl terminate <udid> <bundle-id>` |
| Erase | `xcrun simctl erase <udid>` (must be shut down first) |
| Screenshot | `xcrun simctl io <udid> screenshot <out-path>` |
| Tap | `idb ui tap <x> <y> --udid <udid>` |
| DoubleTap | `idb ui tap <x> <y> --udid <udid>` (twice with 80ms gap, internal) |
| Swipe | `idb ui swipe <x1> <y1> <x2> <y2> --udid <udid> --duration <s>` |
| Type | `idb ui text <string> --udid <udid>` |
| Button | `idb ui button <home\|lock\|side\|siri> --udid <udid>` |

Every command above is wrapped in a typed Swift function; the call site uses the function, never a raw string.

---

## 4. Coordinate space

This is the #1 expected failure mode. **Test it.**

- `xcrun simctl io booted screenshot` writes a PNG at the device's **pixel** resolution (e.g., 1290 × 2796 for iPhone 16 Pro).
- `idb ui tap` takes coordinates in **points** (e.g., 430 × 932 for iPhone 16 Pro).
- The model returns coordinates in **points** (per the system prompt; we tell it the device's logical resolution at run start).

`SimulatorDriver` divides any pixel-derived coordinate by `SimulatorRef.scaleFactor` before issuing the tap. There is exactly one place this conversion happens; everywhere else uses points.

A unit test (`SimulatorDriverCoordinateTests`) constructs a `SimulatorRef` with scaleFactor 3.0 and asserts:

- A pixel-space (1200, 2400) tap converts to point-space (400, 800).
- A point-space (200, 400) tap passes through unchanged.

Off-by-2x bugs would show as "agent always taps in the upper left" — visually obvious in the live mirror, but defended-in-depth here.

---

## 5. idb daemon liveness

`idb_companion` is a per-simulator process that bridges `idb` CLI calls to the simulator. It can:

- Not be installed at all → fail at `which idb`.
- Be installed but not running → fail with a connection error on first command.
- Be running but unresponsive → command times out.

`SimulatorDriver` checks daemon health before each run:

1. `idb list-targets --udid <udid>` with a 3s timeout.
2. If failed: attempt `idb_companion --udid <udid> &` to launch.
3. Re-check.
4. If still failed: surface the error to the UI with the exact command for the user to run manually.

The first-run wizard runs the full check at app launch and offers `brew install idb-companion` if not installed.

---

## 6. AppleScript fallback (degraded mode)

If `idb` itself fails to install or run on the user's machine (rare, but happens after macOS upgrades), Harness has a degraded **AppleScript fallback**:

- Drive `Simulator.app` through Accessibility / UI scripting.
- Tap is approximated by clicking the simulator window at the screen-space mapped coordinates (less precise; subject to window position).
- Text input goes through CGEvent keyboard synthesis with the simulator window focused.
- Swipes are not supported in degraded mode.

When fallback is active, the live UI shows a banner: "AppleScript fallback active — swipes disabled." The user can still complete tap/type-only goals.

`SimulatorDriver` exposes its current backend (`idb` vs `appleScriptFallback`) so the UI knows which mode it's in.

---

## 7. Erase between runs

By default, the simulator state is **left in place** between runs so the user can iterate (e.g., test "re-open the app, did onboarding stick"). The goal-input form has an "Erase simulator before run" toggle (per project, persisted on `ProjectRef`).

When erase is selected: shut down → `simctl erase <udid>` → boot → install → launch.

When erase is off: the previous run's state stays. If the simulator was already booted and the same app installed, install is still re-run (`simctl install` is idempotent and overwrites).

---

## 8. Build artifact pickup

After `xcodebuild` (see `wiki/Xcode-Builder.md`), the `.app` lives at:

```
<derivedDataPath>/Build/Products/Debug-iphonesimulator/<TargetName>.app
```

`XcodeBuilder` returns this URL directly — never run `find` or `glob` on derived data. Failure to find the artifact at the expected path is a typed error (`BuildFailure.artifactNotFound`) with the searched path included.

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

- [ ] Do all `simctl` and `idb` calls go through `ProcessRunner`?
- [ ] Is the coordinate conversion (pixel → point) confined to one place?
- [ ] Is `SimulatorRef.scaleFactor` populated from `simctl list devices --json` (not assumed)?
- [ ] Is `idb_companion` health-checked before each run?
- [ ] Does the AppleScript fallback path exist and is it covered by at least a smoke test?
- [ ] Is the `.app` artifact picked up by deterministic path computation, not `find`?
- [ ] Is the status bar override applied at boot for production runs?
- [ ] Are typed errors (`SimulatorError.*`) used, not raw `ProcessFailure`, at the boundary into the agent loop?
