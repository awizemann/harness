# Build and Run

How to build Harness from source.

## Prerequisites

| Requirement | How to install |
|---|---|
| macOS 14+ | System update |
| Xcode 16+ (Xcode 26 recommended) | App Store / Apple Developer |
| Command Line Tools | `xcode-select --install` |
| Homebrew | https://brew.sh |
| `xcodegen` | `brew install xcodegen` — used to generate `Harness.xcodeproj` from `project.yml` |
| `idb` + `idb_companion` | `brew tap facebook/fb && brew install idb-companion && pip3 install fb-idb` |
| Anthropic API key | https://console.anthropic.com — added via the first-run wizard (lands Phase 3); for Phase 1 dev, set via `security add-generic-password -s com.harness.anthropic -a default -w <key>` |

The first-run wizard (Phase 3) checks all of the above on launch and surfaces actionable errors with copy-pasteable install commands when something's missing.

## One-time setup

```bash
git clone <repo-url> harness
cd harness
xcodegen generate
open Harness.xcodeproj
```

`project.yml` is the source of truth for project structure; `Harness.xcodeproj` is regenerated from it. **Don't hand-edit `Harness.xcodeproj/project.pbxproj`** — those edits won't survive the next `xcodegen generate`. Add files / change settings via `project.yml`.

## Build

```bash
xcodebuild \
  -project Harness.xcodeproj \
  -scheme Harness \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Or open `Harness.xcodeproj` in Xcode and ⌘R.

The first build takes ~15s. Subsequent builds are sub-second thanks to incremental compilation.

## Test

```bash
xcodebuild \
  -project Harness.xcodeproj \
  -scheme Harness \
  -destination 'platform=macOS' \
  test
```

Phase 1 tests cover: HarnessPaths math, ProcessRunner cancellation + streaming, KeychainStore round-trip, SimulatorDriver coordinate scaling + simctl JSON parsing, AgentTools schema invariants. ~28 tests, runs in <1s.

Simulator-integration tests (full sim boot + screenshot + idb) are gated behind a `requiresSimulator` tag — opt in via `-only-testing:HarnessTests/RequiresSim/...`.

## Run against a sample app

Available Phase 3 — once the agent loop is wired and the goal-input UI is built:

1. Open Harness.
2. ⌘N (New Run).
3. Pick an Xcode project (e.g., the in-tree `samples/TodoSample.xcodeproj` once it exists).
4. Pick a scheme.
5. Pick a simulator.
6. Pick or write a persona ("first-time user, never seen this app").
7. Write a goal ("I want to add 'milk' to my list and mark it as done.").
8. Pick mode (Step-by-step recommended for first runs).
9. Click Start.

Watch the live mirror; approve actions in step mode (Space). After the run, the replay opens automatically.

## Adding files to the project

1. Drop the file into `Harness/<Subdir>/` or `HarnessDesign/<Subdir>/`.
2. Run `xcodegen generate`.
3. Rebuild.

The project uses Xcode's modern file-system-synchronized groups (via xcodegen's `path:` directives), so no manual project file editing is needed.

## Common errors

| Error | Likely cause | Fix |
|---|---|---|
| "xcodegen: command not found" | Tooling not installed | `brew install xcodegen` |
| "idb_companion not found" | Homebrew install missing | Run the brew install command above |
| "Failed to boot simulator" | Sim already booted in Xcode and grabbing focus | Quit Simulator.app, retry — though `SimulatorDriver.boot` is idempotent and tolerates the already-booted state |
| "Build failed: signing required" | Project's xcconfig requires a dev team | `XcodeBuilder` passes `CODE_SIGNING_ALLOWED=NO` and surfaces a typed `BuildFailure.signingRequired`. See [Xcode-Builder](Xcode-Builder.md). |
| "Authentication failed" from Claude | API key bad/expired or absent | Settings → API Key (Phase 3) or `security add-generic-password -s com.harness.anthropic -a default -w <key>` for Phase 1 dev |
| Test target fails to build with "ambiguous type lookup" | Naming collision between Harness and HarnessDesign — most likely your new type collides with a `Preview*` placeholder | Rename the placeholder, not the production type. See `HarnessDesign/Mocks/PreviewData.swift` for examples. |

## Project layout (Phase 1)

```
Harness/
├── App/HarnessApp.swift          minimal scaffold; full app shell lands Phase 3
├── Core/
│   ├── HarnessPaths.swift        every filesystem path constant
│   └── Models.swift              domain types (Run, Step, ToolCall, FrictionKind, etc.)
├── Services/
│   ├── ProcessRunner.swift       the only owner of Process()
│   ├── ToolLocator.swift         resolves xcrun/idb/brew paths
│   ├── KeychainStore.swift       Anthropic API key store
│   ├── XcodeBuilder.swift        xcodebuild wrapper
│   ├── SimulatorDriver.swift     simctl + idb wrapper, coord scaling
│   └── ClaudeClient.swift        Anthropic API wrapper, single-shot
├── Tools/AgentTools.swift        tool schema (model-facing contract)
└── Resources/Harness.entitlements
```

Tests at `Tests/HarnessTests/`. Design system + screen drafts at `HarnessDesign/`.

## Cross-references

- [Simulator-Driver](Simulator-Driver.md) — `idb` install + daemon detail.
- [Xcode-Builder](Xcode-Builder.md) — `xcodebuild` flag set.
- [Testing](Testing.md) — test-running specifics.
- [`../docs/ROADMAP.md`](../docs/ROADMAP.md) — what's available to run when.

---

_Last updated: 2026-05-03 — Phase 1 build green; all 28 tests pass._
