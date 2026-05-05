# Harness 0.1.0 — Multi-platform alpha

The first tagged release. All three target platforms — **iOS Simulator**, **macOS apps**, and **web apps** — are wired end-to-end. Per-app setting; same Compose-Run flow for all three; same replay + friction artefacts.

## What it does

Write a goal in plain language ("Sign up and create my first list", "Find a vegetarian restaurant near me and save it"). Pick a persona ("first-time user", "returning power user", "keyboard-first"). Hit Start. An LLM agent reads screenshots, drives the UI, and reports:

- Did the goal complete? (success / failure / blocked + summary)
- What was the path? (replayable timeline of every screen + action)
- Where was the friction? (timestamped events the agent flagged as confusing)

## Targets

| Kind | How |
|---|---|
| **iOS Simulator** | `xcodebuild` your project + scheme; `simctl` boot/install/launch; WebDriverAgent for input. |
| **macOS app** | `NSWorkspace` launch (pre-built `.app` *or* `xcodebuild` macOS scheme); `CGEvent` for clicks / scroll / keyboard / shortcuts; `CGWindowListCreateImage` for window capture. |
| **Web app** | Embedded `WKWebView` at any CSS-pixel viewport; JS-synthesised events for input; `WKWebView.takeSnapshot` for capture. |

## Architecture

- `Harness/Platforms/` — `PlatformKind` discriminator, `UXDriving` + `PlatformAdapter` protocols, per-platform adapters.
- `RunCoordinator` dispatches through `PlatformAdapterFactory.make(for:services:)`. The agent loop reads its tool schema from `adapter.toolDefinitions(...)`; the system prompt's `{{PLATFORM_CONTEXT}}` block loads from `docs/PROMPTS/platforms/<kind>.md`.
- Run history, replay, and friction events are platform-neutral — JSONL events are the same shape regardless of target.
- SwiftData V4 schema: `Application.platformKindRaw` + per-platform optional fields (mac bundle path, web URL + viewport).

## What's in this build

- 175 unit tests passing.
- macOS 14+ minimum.
- Apple Silicon (universal).
- Notarized + signed with Developer ID.

## Known limits

- **Web is WebKit only.** A future opt-in CDP-backed driver (Chrome) is on the roadmap. Browser-chrome shortcuts (`Cmd+L`, `Cmd+T`) won't fire — that's a runtime limit, not a UX problem to flag.
- **macOS needs Screen Recording permission.** First run prompts; subsequent runs are silent.
- **iOS first build is 1–2 minutes** while WebDriverAgent compiles for your simulator runtime. Cached after that.
- **Personas are shared across platforms.** Built-in iOS / macOS / web personas exist (`docs/PROMPTS/personas/<kind>-defaults.md`); the picker doesn't filter by platform yet — pick anything sensible. Filtering is a follow-up if it gets cluttered.

## Setup

1. Install [Homebrew](https://brew.sh).
2. `brew tap facebook/fb && brew install idb-companion` (only needed for iOS).
3. Get an [Anthropic API key](https://console.anthropic.com).
4. Open Harness → first-run wizard walks you through API key + WebDriverAgent build.

## Acknowledgements

Built with Claude (Anthropic) — agent loop runs against the public Messages API. Thanks to Appium for [WebDriverAgent](https://github.com/appium/WebDriverAgent), the iOS responder-chain bridge that makes simulator input actually fire UIKit events.

---

Full source + docs: <https://github.com/awizemann/harness>
Wiki (architecture, services, agent loop): <https://github.com/awizemann/harness/wiki>
Issues: <https://github.com/awizemann/harness/issues>
