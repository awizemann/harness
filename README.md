# Harness

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Status: alpha](https://img.shields.io/badge/status-alpha-orange)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

> A native macOS developer tool that drives an iOS Simulator with an AI agent so you can run **user tests** against an in-development iOS app — not scripted UI tests, but real-user simulation.

You write a goal in plain language ("I want to sign up and create my first list", "delete my account", "find a vegetarian restaurant near me and save it") and a persona ("first-time user, never seen this app"). Harness builds your iOS project, boots the simulator, and an LLM agent reads screenshots, taps/swipes/types, and pursues the goal — narrating what it sees, flagging UX friction (dead ends, ambiguous labels, unresponsive controls), and stopping when it succeeds, fails, or would give up.

Three artifacts come out of every run:

1. **Did the goal complete?** — success / failure / blocked + summary
2. **What was the path?** — replayable sequence of screens + actions
3. **Where was the friction?** — timestamped events the agent flagged as confusing

> **Status:** Alpha. The foundation, standards, and design system are in place; application code is landing in phases per the public roadmap. Expect rough edges. See [`docs/ROADMAP.md`](docs/ROADMAP.md).

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
