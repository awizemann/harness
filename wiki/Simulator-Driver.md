# Simulator Driver

Wraps `xcrun simctl` (lifecycle) and `idb` (input). The standard at [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md) is the canonical reference for invariants. This page is the implementation deep-dive — concrete commands, error modes, and the coordinate-scaling math.

Status: scaffold. Filled out as `Harness/Services/SimulatorDriver.swift` lands in Phase 1.

## Commands cheat sheet

| Op | Command |
|---|---|
| List | `xcrun simctl list devices --json` |
| Boot | `xcrun simctl boot <udid>` |
| Install | `xcrun simctl install <udid> <app-bundle-path>` |
| Launch | `xcrun simctl launch <udid> <bundle-id>` |
| Terminate | `xcrun simctl terminate <udid> <bundle-id>` |
| Erase | `xcrun simctl erase <udid>` |
| Screenshot | `xcrun simctl io <udid> screenshot <out-path>` |
| Tap | `idb ui tap <x> <y> --udid <udid>` |
| Swipe | `idb ui swipe <x1> <y1> <x2> <y2> --udid <udid> --duration <s>` |
| Type | `idb ui text "<string>" --udid <udid>` |
| Button | `idb ui button <home\|lock\|side\|siri> --udid <udid>` |

All issued through `ProcessRunner` per [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md).

## Coordinate scaling (the gotcha)

`xcrun simctl io booted screenshot` writes a PNG at the device's **pixel** resolution. `idb ui tap` takes coordinates in **points**. The model emits points (the system prompt tells it the device's logical resolution).

`SimulatorDriver` divides any pixel-derived coordinate by `SimulatorRef.scaleFactor` before issuing the tap. There is **exactly one place** this conversion happens — every other call site uses points directly.

Unit-tested in `SimulatorDriverCoordinateTests`:

- pixel-space (1200, 2400) on scale 3.0 → point-space (400, 800)
- point-space (200, 400) → pass-through (200, 400)

## idb daemon liveness

Health check before each run:

1. `idb list-targets --udid <udid>` (3s timeout).
2. If failed → attempt `idb_companion --udid <udid> &`.
3. Re-check.
4. If still failed → user-facing error with the exact `brew install idb-companion` (or restart) command.

## AppleScript fallback

If `idb` is unavailable, Harness drops into an AppleScript-driven degraded mode. Tap and type are approximated; swipe is unsupported. The UI shows a banner: "AppleScript fallback — swipes disabled." See [`../standards/12-simulator-control.md §6`](../standards/12-simulator-control.md).

## Cross-references

- [`../standards/12-simulator-control.md`](../standards/12-simulator-control.md) — full standard.
- [Xcode-Builder](Xcode-Builder.md) — the upstream service that produces the `.app` bundle.
- [Build-and-Run](Build-and-Run.md) — first-run install instructions for `idb`.

---

_Last updated: 2026-05-03 — initial scaffolding._
