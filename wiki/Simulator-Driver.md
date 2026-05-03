# Simulator Driver

Wraps `xcrun simctl` (lifecycle) and **WebDriverAgent** (input). The standard at [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md) is the canonical reference for invariants. This page is the implementation deep-dive — concrete commands, error modes, the coordinate-scaling math, and the WDA lifecycle.

## Commands cheat sheet

| Op | Command / Endpoint |
|---|---|
| List | `xcrun simctl list devices --json` |
| Boot | `xcrun simctl boot <udid>` |
| Install | `xcrun simctl install <udid> <app-bundle-path>` |
| Launch | `xcrun simctl launch <udid> <bundle-id>` |
| Terminate | `xcrun simctl terminate <udid> <bundle-id>` |
| Erase | `xcrun simctl erase <udid>` |
| Screenshot | `xcrun simctl io <udid> screenshot <out-path>` |
| Build WDA | `xcodebuild build-for-testing -project vendor/WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'id=<udid>' -derivedDataPath <cache>` |
| Start runner | `xcodebuild test-without-building -xctestrun <path> -destination 'id=<udid>'` |
| Open session | `POST http://127.0.0.1:8100/session` body `{capabilities: {alwaysMatch: {platformName: "iOS", "appium:automationName": "XCUITest"}}}` |
| Tap | `POST /session/<id>/wda/tap` body `{x, y}` |
| Swipe | `POST /session/<id>/wda/dragfromtoforduration` body `{fromX, fromY, toX, toY, duration}` |
| Type | `POST /session/<id>/wda/keys` body `{value: [String], frequency}` |
| Button | `POST /session/<id>/wda/pressButton` body `{name}` |
| End session | `DELETE /session/<id>` |

All `simctl` / `xcodebuild` calls go through `ProcessRunner` per [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md). All HTTP calls go through `WDAClient` (`Harness/Services/WDAClient.swift`).

## Coordinate scaling (the gotcha)

`xcrun simctl io booted screenshot` writes a PNG at the device's **pixel** resolution. WDA's coordinate endpoints take **points**. The model emits points (the system prompt tells it the device's logical resolution; we downscale screenshots to point dimensions before sending).

`SimulatorDriver.toPoints(_:scaleFactor:)` is the single place pixel→point conversion happens — every other call site uses points directly.

Unit-tested in `SimulatorDriverCoordinateTests`:

- pixel-space (1200, 2400) on scale 3.0 → point-space (400, 800)
- point-space (200, 400) → pass-through (200, 400)

## WDA lifecycle

A run goes through five stages:

1. **`cleanupWDA(udid:)`** — `pkill -f "xcodebuild.*test-without-building.*<udid>"`. Tolerates "no matches" (the success case on a clean machine).
2. **`startInputSession(_:)`** orchestrates:
   - `WDABuilder.ensureBuilt(forSimulator:)` — builds WDA's `WebDriverAgentRunner` scheme into `~/Library/Application Support/Harness/wda-build/iOS-<ver>/` if the cache is cold or the submodule SHA changed. ~1–2 min on a cold cache.
   - `WDARunner.start(udid:xctestrun:port:)` — spawns `xcodebuild test-without-building` via `ProcessRunner.runStreaming`. The streaming task is the runner's lifeline; cancel it to SIGTERM the child.
   - `WDAClient.waitForReady(timeout:)` — polls `GET /status` until 200 (3–8 s typical).
   - `WDAClient.createSession()` — `POST /session` with W3C capabilities. The session id is stored on the `WDAClient` actor.
3. The agent loop runs — every `tap`/`swipe`/`type`/`pressButton` flows through `WDAClient` against the open session.
4. **`endInputSession()`** — `DELETE /session/<id>`, then cancel the runner Task. Always called, including on failure paths (RunCoordinator wraps the loop in `do/catch` to guarantee this).

Errors are typed: `WDABuildFailure`, `WDARunnerError`, `WDAClientError`, `SimulatorError`.

## Hiding Simulator.app

`SimulatorWindowController.hide()` calls `app.hide()` on every `NSRunningApplication` whose bundle id is `com.apple.iphonesimulator`. The simulator process and WDA inside it keep running — only the AppKit window is hidden, so Harness's mirror is the only thing visible.

Opt out via `AppState.keepSimulatorVisible` (Settings toggle).

## Cross-references

- [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md) — full standard.
- [Xcode-Builder](Xcode-Builder.md) — the upstream service that produces the `.app` bundle.
- [Build-and-Run](Build-and-Run.md) — first-run setup, including the WDA build estimate.
- [`../Harness/Services/WDAClient.swift`](../Harness/Services/WDAClient.swift), [`WDARunner.swift`](../Harness/Services/WDARunner.swift), [`WDABuilder.swift`](../Harness/Services/WDABuilder.swift) — the WDA stack.
