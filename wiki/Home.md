# Harness — Wiki

A native macOS developer tool that drives an **iOS Simulator, a macOS app, or a web app** with an AI agent so you can run real-user-style tests against in-development software. Goal in plain language; persona; an agent that reads the screen and acts; a replayable log of what happened and where the experience fell down.

> **v0.6.0 shipped 2026-06-16** — drive Harness from an agent via the new MCP server, agent-driven runs surfaced as first-class history, and Sparkle auto-update. See [the release](https://github.com/awizemann/harness/releases/tag/v0.6.0).

This wiki is the dev reference for **where things live, why they work that way, and how to extend them**. It's maintained per-PR alongside code. For development standards, see [`standards/`](https://github.com/awizemann/harness/tree/main/standards).

## Quick links

### Map of the codebase
- [Architecture-Overview](Architecture-Overview) — block diagram + lookup table
- [Core-Services](Core-Services) — every service in one row, with file path and purpose
- [Design-System](Design-System) — HarnessDesign tokens + primitives index
- [Glossary](Glossary) — Run / Step / Action / Friction / Persona / Verdict / Budget definitions
- [Standards-Index](Standards-Index) — index of `standards/` with descriptions

### How the agent works
- [Agent-Loop](Agent-Loop) — the loop, prose walkthrough
- [Tool-Schema](Tool-Schema) — the model-facing tool contract
- [Run-Replay-Format](Run-Replay-Format) — JSONL schema reference

### Per-service deep dives
- [Simulator-Driver](Simulator-Driver) — `simctl` + WebDriverAgent specifics
- [iOS-Driver](iOS-Driver) — WDA-driven, Set-of-Mark via the AX tree, screenshot-stability settle
- [macOS-Driver](macOS-Driver) — CGEvent + AX-based Set-of-Mark, screenshot-stability settle
- [Web-Driver](Web-Driver) — `WKWebView` host, Set-of-Mark probe, DOM-quietness settle gate
- [Xcode-Builder](Xcode-Builder) — `xcodebuild` flags + derived-data math
- [Claude-Client](Claude-Client) — Anthropic SDK wrapper, prompt caching, history compactor
- [Run-Logger](Run-Logger) — JSONL writer + screenshot dump

### Working in the codebase
- [Build-and-Run](Build-and-Run) — prerequisites, `xcodebuild`, smoke tests
- [HarnessCLI](HarnessCLI) — dev-time command-line driver for the web run path; iterate on prompts / models without rebuilding the Mac app
- [HarnessMCP](https://github.com/awizemann/harness/blob/main/HarnessMCP/README.md) — drive Harness from an agent: an MCP server that creates personas/applications, stages credentials, and starts/polls/cancels runs against the shared store
- [Adding-a-Feature](Adding-a-Feature) — recipe for a new feature module
- [Adding-a-Service](Adding-a-Service) — recipe for a new service
- [Testing](Testing) — Swift Testing patterns specific to Harness

### What's next
- [Roadmap](Roadmap) — forward-looking ideas with summaries (the phase-by-phase shipping log lives in [`docs/ROADMAP.md`](https://github.com/awizemann/harness/blob/main/docs/ROADMAP.md))

## Status

**v0.6.0 alpha.** All three target platforms wired end-to-end with feature-parity scaffolding for the agent. Highlights since 0.1:

- **Drive from an agent — MCP (0.6).** `harness-mcp`, a stdio MCP server built from the same source as the app, lets Claude (or any MCP client) create Applications / Personas / Actions, stage credentials, and start/poll/cancel runs against the same on-disk store the GUI uses. See [`HarnessMCP/README.md`](https://github.com/awizemann/harness/blob/main/HarnessMCP/README.md).
- **Agent runs are first-class (0.6).** Runs carry an origin — You / Agent / CLI. History badges and titles the non-you ones; a dedicated **Agent Sessions** view shows live sessions with a step counter plus recent agent runs; a global banner appears while an agent drives the app. Ad-hoc agent runs match-or-create an Application from their target, so they thread into per-app History.
- **Sparkle auto-update (0.6).** Check for Updates in the app menu plus scheduled checks; EdDSA-signed and delivered over the notarized, Developer-ID-signed release pipeline.
- **Local Mac inference (0.5).** New `Local Mac` provider runs a vision LLM on your Mac via Ollama. Curated picker (Qwen3-VL 8B recommended) plus a custom-model field. Screenshots never leave the machine. See [Local-vs-Cloud-Models](Local-vs-Cloud-Models) for a same-goal-same-site head-to-head with numbers.
- **Set-of-Mark on every platform (0.5).** iOS and macOS join web — numbered overlays on interactive elements, `tap_mark(id)` instead of `tap(x, y)`. Pixel guesswork eliminated for interactive elements. See [iOS-Driver](iOS-Driver), [macOS-Driver](macOS-Driver), [Web-Driver](Web-Driver).
- **Smart settle gates everywhere (0.5).** Screenshot-stability dHash polling on iOS/macOS; `MutationObserver` quietness with SPA-route-aware `requireChildListMutation` on web. Replaces fixed sleeps that captured screens mid-render.
- **`harness-cli` (0.5).** Development-time driver — same `RunCoordinator` and event stream as the GUI, no SwiftUI. See [HarnessCLI](HarnessCLI).
- **Per-Application credential storage (0.3).** Pre-stage username/password pairs against any Application; the agent gets a `fill_credential` tool. Passwords never enter the model's context or the JSONL log.
- **Multi-provider LLM support (0.2-0.3).** Anthropic, OpenAI, Google — seven cloud models across three providers, per-provider Keychain storage, per-run picker.

Known limits in v0.5: web is WebKit only (Chrome via CDP is a future opt-in); macOS needs Screen Recording + Accessibility permission; real iPhones still unsupported (Simulator only); 2FA / SMS / CAPTCHA interrupts unsupported (planned `request_user_input` tool on the [Roadmap](Roadmap)); local-model wall-clock is ~5-10× slower per step than cloud-class Sonnet.

---

_Last updated: 2026-06-16 — v0.6.0 release_