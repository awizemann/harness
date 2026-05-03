# Harness

A native macOS developer tool that drives an iOS Simulator with an AI agent so you can run **user tests** against an in-development iOS app — not scripted UI tests, but real-user simulation.

You write a goal in plain language ("I want to sign up and create my first list", "delete my account", "find a vegetarian restaurant near me and save it") and a persona ("first-time user, never seen this app"). Harness builds your iOS project, boots the simulator, and an LLM agent reads screenshots, taps/swipes/types, and pursues the goal — narrating what it sees, flagging UX friction (dead ends, ambiguous labels, unresponsive controls), and stopping when it succeeds, fails, or would give up.

Three artifacts come out of every run:

1. **Did the goal complete?** (success / failure / blocked + summary)
2. **What was the path?** (replayable sequence of screens + actions)
3. **Where was the friction?** (timestamped events the agent flagged as confusing)

## How to read this repo

- [`CLAUDE.md`](CLAUDE.md) — project root instructions for any agent working in this codebase.
- [`standards/INDEX.md`](standards/INDEX.md) — development, code, and architecture standards. Read these before adding code.
- [`wiki/Home.md`](wiki/Home.md) — internal reference for "where does X live, what's it for, how do I extend it." Maintained per PR alongside code.
- [`docs/`](docs/) — product spec material: PRD, architecture overview, roadmap, and the canonical prompt library.
- [`HarnessDesign/`](HarnessDesign/) — design system tokens, primitives, and screen layouts (the SwiftUI building blocks).

## Status

Pre-implementation. Foundation, standards, and wiki scaffolding land in this commit; application code follows in subsequent phases. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the build order.

## License

Private. Not yet published.
