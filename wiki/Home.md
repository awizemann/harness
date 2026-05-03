# Harness — Internal Wiki

A native macOS developer tool that drives an iOS Simulator with an AI agent so you can run real-user-style tests against an in-development iOS app. Goal in plain language; persona; an agent that reads screenshots and acts; a replayable log of what happened and where the experience fell down.

This wiki is the in-tree reference for **where things live, why they work that way, and how to extend them**. It's maintained per-PR alongside code. For the philosophy and "what it is for whom," see `docs/PRD.md`. For development standards, see `standards/INDEX.md`.

## Quick links

### Map of the codebase
- [Architecture-Overview](Architecture-Overview.md) — block diagram + lookup table
- [Core-Services](Core-Services.md) — every service in one row, with file path and purpose
- [Design-System](Design-System.md) — HarnessDesign tokens + primitives index
- [Glossary](Glossary.md) — Run / Step / Action / Friction / Persona / Verdict / Budget definitions
- [Standards-Index](Standards-Index.md) — index of `standards/` with descriptions

### How the agent works
- [Agent-Loop](Agent-Loop.md) — the loop, prose walkthrough
- [Tool-Schema](Tool-Schema.md) — the model-facing tool contract
- [Run-Replay-Format](Run-Replay-Format.md) — JSONL schema reference

### Per-service deep dives
- [Simulator-Driver](Simulator-Driver.md) — `simctl` + `idb` specifics
- [Xcode-Builder](Xcode-Builder.md) — `xcodebuild` flags + derived-data math
- [Claude-Client](Claude-Client.md) — Anthropic SDK wrapper, prompt caching, history compactor
- [Run-Logger](Run-Logger.md) — JSONL writer + screenshot dump

### Working in the codebase
- [Build-and-Run](Build-and-Run.md) — prerequisites, `xcodebuild`, smoke tests
- [Adding-a-Feature](Adding-a-Feature.md) — recipe for a new feature module
- [Adding-a-Service](Adding-a-Service.md) — recipe for a new service
- [Testing](Testing.md) — Swift Testing patterns specific to Harness

## Status

Phase 0 — foundation and scaffolding. Application code lands in subsequent phases per `docs/ROADMAP.md`. Most pages on this wiki are scaffolds today and fill out as the corresponding code lands.

---

_Last updated: 2026-05-03 — initial scaffolding._
