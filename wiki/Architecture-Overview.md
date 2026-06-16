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

Phase 2 introduced the abstraction layer [[memophant/architecture/platform-drivers-ios-macos-web-set-of-mark-smart-gates-input]]:

- `Harness/Platforms/UXDriving.swift` — common driver protocol (`screenshot(into:)`, `execute(_:)`, `relaunchForNewLeg()`).
- `Harness/Platforms/PlatformAdapter.swift` + `RunSession` — per-platform façade owning lifecycle, tool schema, and prompt context.
- `IOSPlatformAdapter` wraps the existing `XcodeBuilder` + `SimulatorDriver` pieces. `MacOSPlatformAdapter` orchestrates the macOS launch / build / drive path.
- `RunCoordinator` dispatches through `PlatformAdapterFactory.make(for:services:)` — it no longer references `SimulatorDriving` or `XcodeBuilder` directly.
- `AgentTools` split into `iOSToolDefinitions(cacheControl:)`, `macOSToolDefinitions(cacheControl:)`, `webToolDefinitions(cacheControl:)`. Each adapter advertises its own subset.
- `docs/PROMPTS/platforms/<kind>.md` — per-platform context block prepended to the canonical iOS-flavoured system prompt for non-iOS runs.
- `docs/PROMPTS/personas/<kind>-defaults.md` — per-platform persona library (Phase 2 ships macOS personas; Phase 3 ships web personas).

Phase 3 added `WebPlatformAdapter` driving an embedded `WKWebView` in an off-screen `NSWindow`. Input events go through `dispatchEvent` in the page (clicks, scroll, keyboard); navigation goes through JavaScript `location.href`. The adapter owns the `WebViewWindowController` lifecycle and hands `RunCoordinator` a `RunSession` whose driver is a `WebDriver` (see [Web-Driver](Web-Driver)).

---

## Feature modules (MVVM-F)

Harness is **MVVM-F**: Model-View-ViewModel + Features. No feature module imports sibling feature modules; all cross-feature communication flows through the `AppCoordinator` (a central event hub). See [`standards/01-architecture.md`](https://github.com/awizemann/harness/blob/main/standards/01-architecture.md) for the full rule.

Features live under `Harness/Features/`:  
Applications, Personas, Actions, GoalInput, RunSession, RunHistory, RunReplay, FrictionReport, AgentSessions, Settings.

Each feature is self-contained: a `ViewModels/` folder (SwiftUI state + business logic), a `Views/` folder (SwiftUI `@View` types), and sometimes a `Models/` folder (domain types). See [Adding-a-Feature](Adding-a-Feature) for the step-by-step.

---

## Set-of-Mark and smart settle gates

Every platform driver layers two pieces on top of the universal loop [[memophant/architecture/platform-drivers-ios-macos-web-set-of-mark-smart-gates-input]].

**Set-of-Mark badges:** Every screenshot the LLM sees has numbered green pills floating above each interactive element. The agent calls `tap_mark(id)` instead of `tap(x, y)` — coordinate-emission failure on small vision models drops out entirely. Disk PNGs stay unmarked so replay surfaces don't show scaffolding.

**Smart settle gate:** Replaces fixed sleep timers that routinely captured pages / windows mid-render or mid-animation.

| Platform | Mark probe | Settle gate | Doc |
|---|---|---|---|
| Web | JS `querySelectorAll` walk piercing shadow roots; anchors, buttons, role=*, contenteditable, etc. | `MutationObserver` quietness, with a `childList`-mutation requirement for SPA route transitions. | [Web-Driver](Web-Driver) |
| iOS | WebDriverAgent's `/source?format=json` AX tree; actionable XCUI roles; `StaticText` rolls up into cell labels. | Screenshot dHash stability via `simctl io screenshot` polling. | [iOS-Driver](iOS-Driver) |
| macOS | `AXUIElementCopyAttributeValue` walk of the focused window; actionable AX roles; window-local point space. | Screenshot dHash stability via `CGWindowListCreateImage` polling. | [macOS-Driver](macOS-Driver) |

Together these are what make local vision models (Qwen3-VL 8B, Gemma 4 Vision, Llama 3.2 Vision) usable across all three platforms.
