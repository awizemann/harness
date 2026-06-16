# Quick Start

Get Harness building and running in under 10 minutes.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6 strict concurrency)
- [Homebrew](https://brew.sh)
- `idb_companion` — install via `brew tap facebook/fb && brew install idb-companion`
- An [Anthropic API key](https://console.anthropic.com) (optional for first-run, but Harness works best with a key)

## Clone and generate

```bash
git clone https://github.com/awizemann/harness.git
cd harness
git submodule update --init --recursive    # vendors appium/WebDriverAgent
brew install xcodegen
xcodegen generate                            # regenerates Harness.xcodeproj
open Harness.xcodeproj
```

The Xcode project is generated from `project.yml` — `Harness.xcodeproj/` is gitignored. If you pull changes that touch sources or resources, re-run `xcodegen generate`.

## Build and run

In Xcode, select the **Harness** target (not `HarnessCLI` or test targets), then:

- **Product → Build** (⌘B) to build.
- **Product → Run** (⌘R) to launch the app.

On first run, the **First-Run Wizard** appears. It will:

1. Prompt for an Anthropic API key (save to Keychain).
2. Verify `xcodebuild`, Simulator, and WebDriverAgent setup.
3. Show you the simulator list.

Once the wizard completes, Harness is ready to drive an iOS Simulator.

## Run your first test

1. Open Xcode and build a simple test app (or use an existing project).
2. In Harness, select **Create Application** (or use an existing one).
3. Enter your project path, scheme, and simulator.
4. Write a goal: "Navigate to the settings screen and toggle dark mode."
5. Pick a persona: "First-time user, unfamiliar with the app."
6. Click **Start**.

Harness will:

- Build your app.
- Boot the simulator.
- Install the app.
- Launch it.
- Run the agent loop — you'll see live screenshots, the agent's reasoning, and friction events in the feed.
- Log the run to disk and save a `RunRecord` to the history.

When done, open **Run History** to replay the run, see the path taken, and review friction flagged by the agent.

## Useful commands

```bash
# Run the test suite
xcodebuild test -project Harness.xcodeproj -scheme Harness

# Build the harness-cli tool (development-time driver)
xcodebuild -project Harness.xcodeproj -scheme harness-cli build

# Open documentation
open https://awizemann.github.io/harness/

# View standards
open standards/INDEX.md
```

## Next steps

- **[Architecture Overview](Architecture-Overview)** — understand how Harness works end-to-end.
- **[Contributing](../CONTRIBUTING.md)** — code guidelines and PR workflow.
- **[Build and Run](Build-and-Run)** — detailed setup, simulator config, troubleshooting.
- **[Roadmap](Roadmap)** — what's shipped and what's planned.