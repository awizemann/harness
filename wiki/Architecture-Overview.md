# Architecture Overview

The block diagram, data flow per run, and the "where does X live" lookup table all live in [`../docs/ARCHITECTURE.md`](https://github.com/awizemann/harness/blob/main/docs/ARCHITECTURE.md). That document is the canonical version. This wiki page exists so an agent looking for "architecture" via the wiki finds it; consider this a redirect.

Read [`../docs/ARCHITECTURE.md`](https://github.com/awizemann/harness/blob/main/docs/ARCHITECTURE.md) first. Then drill into:

- [Core-Services](Core-Services) — table of every service with file path + isolation + purpose
- [Agent-Loop](Agent-Loop) — the loop in prose
- [Tool-Schema](Tool-Schema) — the model-facing contract
- [Run-Replay-Format](Run-Replay-Format) — JSONL schema reference

Concurrency model, state ownership, and the core lookup table are not duplicated here — keeping one source of truth means they don't drift.

---

## Workspace shape (Phase 6, 2026-05-04)

Harness has two concentric models the architecture docs don't fully cover yet:

- **Library entities** (`Application`, `Persona`, `Action`, `ActionChain`) — saved on disk in SwiftData, scoped per user. Always visible in the sidebar.
- **Workspace sections** (`New Run`, `Active Run`, `History`, `Friction`) — gated on the user having selected an active `Application` via `coordinator.selectedApplicationID`.

`SidebarSection.category` (`.library` vs `.workspace`) drives the sidebar's two-tier render. `selectedApplicationID` is persisted in `~/Library/Application Support/Harness/settings.json` and validated against the live store on launch.

A run is composed of: an active Application (project + scheme + simulator + run defaults), one Persona, and either a single Action or an Action Chain. Single-action runs have one Leg implicitly. Chain runs have N Legs — each Leg gets its own AgentLoop with cycle-detector + step-budget reset; the `preservesState` toggle on each chain step controls whether the simulator reinstalls the app between legs. JSONL schema v2 ships `leg_started` / `leg_completed` row kinds; v1 logs (pre-Phase 6) parse as one virtual leg.

For per-feature wiring (Compose Run form, Replay leg sections, etc.) see [Adding-a-Feature.md](Adding-a-Feature)'s "real examples" section.

---

## Platform discriminator (Phase 1, 2026-05-05)

Harness's roadmap covers three target platforms, declared per-Application:

| Kind | Status | What Harness drives |
|---|---|---|
| `.iosSimulator` | **Live** | iOS Simulator via `simctl` + `XcodeBuilder` + WebDriverAgent. |
| `.macosApp` | **Live (Phase 2)** | macOS apps via `CGEvent` + `CGWindowListCreateImage` (pre-built `.app` or `xcodebuild` macOS scheme). |
| `.web` | **Live (Phase 3)** | URLs in an embedded `WKWebView`. |

Phase 2 introduced the abstraction layer:

- `Harness/Platforms/UXDriving.swift` — common driver protocol (`screenshot(into:)`, `execute(_:)`, `relaunchForNewLeg()`).
- `Harness/Platforms/PlatformAdapter.swift` + `RunSession` — per-platform façade owning lifecycle, tool schema, and prompt context.
- `IOSPlatformAdapter` wraps the existing `XcodeBuilder` + `SimulatorDriver` pieces. `MacOSPlatformAdapter` orchestrates the macOS launch / build / drive path.
- `RunCoordinator` dispatches through `PlatformAdapterFactory.make(for:services:)` — it no longer references `SimulatorDriving` or `XcodeBuilder` directly.
- `AgentTools` split into `iOSToolDefinitions(cacheControl:)`, `macOSToolDefinitions(cacheControl:)`, `webToolDefinitions(cacheControl:)`. Each adapter advertises its own subset.
- `docs/PROMPTS/platforms/<kind>.md` — per-platform context block prepended to the canonical iOS-flavoured system prompt for non-iOS runs.
- `docs/PROMPTS/personas/<kind>-defaults.md` — per-platform persona library (Phase 2 ships macOS personas; Phase 3 ships web personas).

Phase 3 added `WebPlatformAdapter` driving an embedded `WKWebView` in an off-screen `NSWindow`. Input events go through `dispatchEvent` in the page (clicks, scroll, keyboard); navigation goes through `WKWebView.load` / `goBack` / `goForward` / `reload`. Browser-chrome shortcuts (Cmd+L, Cmd+T) won't work — that's a known v1 limit; the v2 CDP-backed adapter (Chrome) would lift it.

The `Application` SwiftData model gained `platformKindRaw` (V3→V4 migration; `nil` resolves to `.iosSimulator`) plus per-platform optional fields (`macAppBundlePath`, `webStartURL` + viewport, etc.). `RunRecord` gained the same column so the history index renders the right per-row icon and Phase 2 / 3 replays can pick the right mirror view.

`ApplicationCreateView` shows a three-segment platform picker today; only iOS is selectable. The macOS and web segments carry "Coming soon" affordances and become live as Phase 2 / 3 ship.

When a phase introduces a real adapter, the abstraction layer (`UXDriving`, `PlatformAdapter`) lands at the same time — `RunCoordinator` and `AgentLoop` are kept iOS-only until then to avoid premature abstraction.

---

_Last updated: 2026-05-05 — added platform discriminator section_