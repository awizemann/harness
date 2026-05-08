# Harness

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Targets: iOS · macOS · Web](https://img.shields.io/badge/targets-iOS%20%C2%B7%20macOS%20%C2%B7%20Web-3DDC97)
![Version: 0.3.1](https://img.shields.io/badge/version-0.3.1-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/landing/assets/screenshots/runsession-hero-dark.png">
    <img alt="Harness Run Session — simulator mirror, step feed, and approval card visible mid-run" src="site/landing/assets/screenshots/runsession-hero.png" width="900">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/awizemann/harness/releases/download/v0.3.1/Harness-v0.3.1-Universal.zip">
    <img alt="Download Harness v0.3.1 — macOS Universal (Apple Silicon + Intel)" src="https://img.shields.io/badge/Download%20for%20Mac-v0.3.1%20Universal-1f6feb?style=for-the-badge&logo=apple&logoColor=white">
  </a>
  <br>
  <sub>macOS 14+ · Apple Silicon &amp; Intel · ~12 MB</sub>
</p>

<p align="center">
  <a href="https://awizemann.github.io/harness/"><strong>awizemann.github.io/harness</strong></a> &nbsp;·&nbsp;
  <a href="https://github.com/awizemann/harness/wiki">Wiki</a> &nbsp;·&nbsp;
  <a href="https://github.com/awizemann/harness/releases/latest">All releases</a>
</p>

> A native macOS developer tool that drives an **iOS Simulator, a macOS app, or a web app** with an AI agent so you can run **user tests** — not scripted UI tests, but real-user simulation.

You write a goal in plain language ("I want to sign up and create my first list", "delete my account", "find a vegetarian restaurant near me and save it") and a persona ("first-time user, never seen this app"). Harness builds (or just launches) your target, and an LLM agent reads screenshots, clicks/types/scrolls, and pursues the goal — narrating what it sees, flagging UX friction (dead ends, ambiguous labels, unresponsive controls), and stopping when it succeeds, fails, or would give up.

Three artifacts come out of every run:

1. **Did the goal complete?** — success / failure / blocked + summary
2. **What was the path?** — replayable sequence of screens + actions
3. **Where was the friction?** — timestamped events the agent flagged as confusing

## Targets

| Kind | How Harness drives it |
|---|---|
| **iOS Simulator** | `xcodebuild` your project + scheme; `simctl` boot/install/launch; WebDriverAgent for input. |
| **macOS app** | NSWorkspace launch (pre-built `.app` *or* xcodebuild macOS scheme); `CGEvent` for input; `CGWindowListCreateImage` for capture. |
| **Web app** | Embedded `WKWebView` at a chosen viewport (default **1280×1600** tall desktop, or 375×812 mobile); JS-synthesised events for input; `WKWebView.takeSnapshot` for capture. The mirror shows a flat browser chrome (no device bezel) so the screenshot fills the full pane and one snapshot covers more page — fewer scrolls per goal, lower API cost. |

Per-app setting: each Application declares its kind once at create time. The agent's tool schema (clicks vs swipes vs key shortcuts vs navigate) and the system-prompt context block re-shape per platform. Run history, replay, and friction reporting are platform-neutral.

> **Status:** v0.3.1 (alpha). All three platforms wired end-to-end; **per-Application credential storage + Set-of-Mark targeting on web** (numbered overlays on focusable elements; agent clicks by id, no pixel guessing — agent-only, never on disk); **multi-provider LLM support** (Anthropic Opus 4.7 / Sonnet 4.6 / Haiku 4.5 + OpenAI GPT-5 Mini / GPT-4.1 Nano + Google Gemini 2.5 Flash / Flash Lite); per-provider Keychain storage; configurable per-model token budgets; unlimited-step option. macOS needs Screen Recording permission. Web is WebKit-only; Chrome via CDP is on the roadmap. See [`docs/ROADMAP.md`](docs/ROADMAP.md).

## What's new in 0.3.1

- **Set-of-Mark badges no longer leak into human-visible surfaces.** The disk PNG is the **clean rendered page** — replay, friction reports, and exported screenshots show what a real user would see. The agent still receives the marked-up image (numbered green badges over focusable elements) via an in-memory `ScreenshotMetadata.markedImageData` channel; the on-disk artifact stays free of dev-tool clutter. Standard 14 §6 documents the new "no agent scaffolding on disk" invariant.
- **Compose Run pairs Persona + Credential side-by-side.** Both sections answer "who's running this?", so they read as one row instead of two stacked panels. Saves vertical scroll; auto-falls-back to a single column on narrow windows via `ViewThatFits`. When no credentials are staged, Persona expands to fill the row naturally.

## What's new in 0.3.0

- **Per-Application credential storage.** Pre-stage username/password pairs against an Application; pick one per run in Compose Run. The agent gets a new `fill_credential(field: "username"|"password")` tool for iOS, macOS, and web. Password bytes never enter the model's context, the JSONL log, or any prompt template — `tool_call.input` for password fills records `{"field":"password"}` and nothing else. New friction kind `auth_required` for the "agent hit a login wall and has nothing to fill" case.
- **Set-of-Mark targeting (web).** Every screenshot now overlays small numbered badges on focusable elements (form fields, buttons, dropdowns, checkboxes). The agent calls `tap_mark(id)` and the WebDriver resolves to the element's center — no more "agent picked y=228, input was at y=242" misses. Coordinate `tap(x, y)` stays available for unmarked content. Probe pierces open shadow roots so inputs in modern signin / payment widgets get marks. iOS / macOS get the same treatment in a follow-up via accessibility-tree probes (tracked on the [wiki Roadmap](https://github.com/awizemann/harness/wiki/Roadmap)).
- **Web mirror reworked.** Replaced the iPad-shaped device bezel with a flat browser chrome (URL pill, lock glyph, back/forward/refresh affordances) so web runs use the full middle column. Default viewport bumped to 1280×1600 — taller snapshots mean fewer scroll turns, which translates directly to lower API spend per run.
- **React-aware form fill.** `dispatchType` now uses the native value setter via `Object.getOwnPropertyDescriptor`, so React's value tracker actually sees the change and re-renders won't reset typed text. Same fix applies to `fill_credential`. Click-target focus routing now walks `<label>`, wrappers, and shadow children to focus the actual input, not the styled `<div>` on top of it.
- **Multi-tool emissions accepted.** The system prompt always allowed *"exactly one tool call ... optionally accompanied by one or more `note_friction` calls"*; the parsers were rejecting anything > 1 block. Each provider's parser now splits action vs `note_friction` and forwards inline frictions through `AgentDecision.inlineFriction` → JSONL friction rows.
- **Run-log schema v3.** `run_started` payload gains optional `credentialLabel` + `credentialUsername` (decode-if-present so v2 logs round-trip). Standards doc §5 documents the v2→v3 migration and the three credential-redaction invariants.
- **`RunHistoryStore` adopts `@ModelActor`.** Eliminates the *"Unbinding from the main queue. ModelContexts are not Sendable"* runtime warning that Swift's strict concurrency was right to flag.

## What's new in 0.2.0

- **Seven supported models across three providers.** Pick a provider in Settings, then a model. Compose Run can override per-run. Each provider has its own Keychain entry; swap mid-session without restart.
- **Per-model token budgets.** The legacy "Opus → 250k, else 1M" ternary is gone — every model has a justified default and a hard ceiling, configurable globally in Settings and per-run in Compose Run.
- **Unlimited steps.** Toggle in Settings, Compose Run, or Application defaults. The token budget + cycle detector remain the safety rails.
- **Settings persist across launches.** Default provider, model, mode, step + token budgets, and simulator visibility all survive a restart now (they didn't in 0.1).
- **Real screenshot thumbnails** in the step feed, sized to each platform's aspect ratio.
- **Loop hardening for cheaper models.** Multi-tool / zero-tool / parse-failure responses now surface a corrective hint to the model on retry instead of failing the run silently.
- 218 unit tests passing (was 175 in 0.1).

## First clone

Harness vendors `appium/WebDriverAgent` as a git submodule under `vendor/WebDriverAgent` (it's how we drive the iOS Simulator's responder chain). The Xcode project is generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/awizemann/harness.git
cd harness
git submodule update --init --recursive
brew install xcodegen
xcodegen generate
open Harness.xcodeproj
```

You'll also need `idb_companion` for simulator control:

```bash
brew tap facebook/fb && brew install idb-companion
```

The first run builds WDA against your simulator's iOS runtime (~1–2 min). Result is cached under `~/Library/Application Support/Harness/wda-build/<iOS-version>/` and reused on subsequent runs.

Full setup: see [Build-and-Run on the Wiki](https://github.com/awizemann/harness/wiki/Build-and-Run).

## How to read this repo

- [`standards/INDEX.md`](standards/INDEX.md) — development, code, and architecture standards. Read these before adding code.
- [GitHub Wiki](https://github.com/awizemann/harness/wiki) — "where things live, why, and how to extend them." Maintained per PR alongside code.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — system architecture overview.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — build order and milestones.
- [`docs/PROMPTS/`](docs/PROMPTS/) — canonical agent prompts (loaded as a bundle resource at runtime).
- [`HarnessDesign/`](HarnessDesign/) — design system tokens, primitives, and screen layouts.

## Contributing

PRs welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) first — it covers setup, the architecture rules (MVVM-F, Swift 6 strict concurrency, single subprocess actor), and the **public-surfaces sync rule** (code changes that affect README / wiki / site update them in the same PR).

## License

MIT — see [`LICENSE`](LICENSE).
