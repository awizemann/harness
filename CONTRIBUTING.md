# Contributing to Harness

Thanks for the interest. Harness is a native macOS dev tool that drives an iOS Simulator with an AI agent so you can run real-user-style tests against an in-development iOS app. This doc covers what you need to build, contribute, and ship changes that fit the project.

## Getting started

**Requirements:**

- macOS 14 or later
- Xcode 16 or later (Swift 6 strict concurrency)
- [Homebrew](https://brew.sh)
- `idb_companion` — install via `brew tap facebook/fb && brew install idb-companion`
- An [Anthropic API key](https://console.anthropic.com) (Harness stores it in the macOS Keychain on first run)

**First clone:**

```bash
git clone https://github.com/awizemann/harness.git
cd harness
git submodule update --init --recursive    # vendors appium/WebDriverAgent
xcodegen generate                            # regenerates Harness.xcodeproj
open Harness.xcodeproj
```

The Xcode project is generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen) — `Harness.xcodeproj/` is gitignored. After pulling changes that touch sources or resources, re-run `xcodegen generate`.

The first run also builds WebDriverAgent against your simulator's iOS runtime (~1–2 min). Result is cached under `~/Library/Application Support/Harness/wda-build/<iOS-version>/`.

## Architecture at a glance

Harness is **MVVM-F** (model-view-viewmodel + features). Read these before writing code:

- [`standards/INDEX.md`](standards/INDEX.md) — full development, code, and architecture standards.
- [`standards/01-architecture.md`](standards/01-architecture.md) — module rules; **features never import sibling features**.
- [`standards/AUDIT_CHECKLIST.md`](standards/AUDIT_CHECKLIST.md) — run this before requesting review for non-trivial changes.

The deeper "why does this live here, how do I extend it" reference lives on the [GitHub Wiki](https://github.com/awizemann/harness/wiki). Start at [Architecture-Overview](https://github.com/awizemann/harness/wiki/Architecture-Overview).

## Guidelines

- **Swift 6 strict concurrency.** No synchronous file I/O on `@MainActor`. View bodies never spawn subprocesses or hit the filesystem. See [`standards/04-swift-conventions.md`](standards/04-swift-conventions.md).
- **One subprocess actor.** All `Process()` invocation goes through `ProcessRunner`. No exceptions. See [`standards/03-subprocess-and-filesystem.md`](standards/03-subprocess-and-filesystem.md).
- **Design tokens, not magic numbers.** All UI uses tokens from `HarnessDesign/`. No raw `.padding(12)` / `cornerRadius: 8`. See [`standards/05-design-system.md`](standards/05-design-system.md).
- **Logging.** No `print()` in production code — use `os.Logger`. `print()` is fine in `#Preview` and test helpers.
- **Tests.** Swift Testing framework (`@Suite` / `@Test`). No timing-dependent tests. See [`standards/10-testing.md`](standards/10-testing.md).

## Public surfaces — the sync rule

Code changes that affect a public surface MUST update that surface in the **same PR**. Reviewers reject PRs that touch a code path in column 1 without updating the corresponding surface in column 2.

| Code change | Update required |
|---|---|
| New service in `Harness/Services/` | wiki page `Core-Services` |
| New feature module in `Harness/Features/` | wiki `Adding-a-Feature` examples (if pattern shifts) |
| Agent tool schema (`Harness/Tools/AgentTools.swift`) | wiki `Tool-Schema` — same commit |
| Run-log JSONL format change | bump `schemaVersion` in [`standards/14-run-logging-format.md`](standards/14-run-logging-format.md) + wiki `Run-Replay-Format` |
| New friction kind | the five touchpoints listed in the project's internal coordination doc |
| User-visible feature, screenshot-affecting UI change, version bump | `site/landing/index.html` + `README.md` hero |
| New top-level capability or major feature | README "What's new" / status section |
| Standard amended | `standards/<file>.md` + wiki `Standards-Index` |

**Skip** for: bug fixes with no observable contract change, pure refactors, typos, internal cleanups, test-only changes.

The PR template includes a "Public surfaces touched" checklist.

## Working with the Wiki

The Wiki is its own git repo. Clone it as a worktree once:

```bash
git worktree add .wiki-worktree git@github.com:awizemann/harness.wiki.git
```

Edit pages in `.wiki-worktree/`, then push via `scripts/wiki.sh` (which runs a secret-scan first).

## Pull requests

- One topic per PR.
- Title in conventional-commit style: `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`.
- Body names the standards touched, e.g. `Standards: 03, 13, 14`.
- Build passes (`xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug build`).
- Tests pass (`xcodebuild test -project Harness.xcodeproj -scheme Harness`).
- For non-trivial changes, run [`standards/AUDIT_CHECKLIST.md`](standards/AUDIT_CHECKLIST.md) and confirm in the PR.

## Reporting issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include:

- macOS version, Xcode version
- Simulator + iOS runtime
- The goal you ran and the persona
- Run ID if applicable (find it under `~/Library/Application Support/Harness/runs/`)
- Expected vs actual

For UX / friction-detection edge cases, attach the run's `events.jsonl` if it doesn't contain anything sensitive.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
