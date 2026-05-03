# Build and Run

How to build Harness and how to run it against a sample iOS app.

Status: scaffold. Filled out as the Xcode project lands in Phase 1.

## Prerequisites

| Requirement | How to install |
|---|---|
| macOS 15+ | System update |
| Xcode 16+ | App Store / Apple Developer |
| Command Line Tools | `xcode-select --install` |
| Homebrew | https://brew.sh |
| `idb` + `idb_companion` | `brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb` |
| Anthropic API key | https://console.anthropic.com — added to Harness via the first-run wizard (stored in Keychain). |

The first-run wizard checks all of the above on launch and surfaces actionable errors with copy-pasteable install commands when something's missing.

## Build

```bash
cd /Users/alanwizemann/Development/harness
xcodebuild \
  -project Harness.xcodeproj \
  -scheme Harness \
  -configuration Debug \
  build
```

Or open `Harness.xcodeproj` in Xcode and ⌘R.

## Run against a sample app

Phase 2+ — once the agent loop is wired:

1. Open Harness.
2. ⌘N (New Run).
3. Pick an Xcode project (e.g., the in-tree `samples/TodoSample.xcodeproj` once it exists).
4. Pick a scheme (`TodoSample`).
5. Pick a simulator (`iPhone 16 Pro · iOS 18.4`).
6. Pick or write a persona ("first-time user, never seen this app").
7. Write a goal ("I want to add 'milk' to my list and mark it as done.").
8. Pick mode (Step-by-step recommended for first runs).
9. Click Start.

Watch the live mirror; approve actions in step mode (Space). After the run, the replay opens automatically.

## Testing

```bash
xcodebuild \
  -project Harness.xcodeproj \
  -scheme Harness \
  -destination 'platform=macOS' \
  test
```

Replay-based agent tests + ProcessRunner integration tests run by default. Simulator-integration tests are gated behind a `requiresSimulator` tag — opt-in via `-only-testing:HarnessTests/...`.

## Common errors

| Error | Likely cause | Fix |
|---|---|---|
| "idb_companion not found" | Homebrew install missing | Run the brew install command above |
| "Failed to boot simulator" | Sim already booted in Xcode and grabbing focus | Quit Simulator.app, retry |
| "Build failed: signing required" | Project's xcconfig requires a dev team | The wrapper passes `CODE_SIGNING_ALLOWED=NO`; if the project still fails, see [Xcode-Builder](Xcode-Builder.md) |
| "Authentication failed" from Claude | API key bad or expired | Settings → API Key |

## Cross-references

- [Simulator-Driver](Simulator-Driver.md) — `idb` install + daemon detail.
- [Xcode-Builder](Xcode-Builder.md) — `xcodebuild` flag set.
- [Testing](Testing.md) — test-running specifics.
- [`../docs/ROADMAP.md`](../docs/ROADMAP.md) — what's available to run when.

---

_Last updated: 2026-05-03 — initial scaffolding._
