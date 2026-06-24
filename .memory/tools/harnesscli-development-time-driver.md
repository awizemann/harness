---
title: HarnessCLI: Development-Time Driver
type: note
permalink: harness/tools/harnesscli-development-time-driver
tags:
- cli
- dev_tool
- tooling
source_sha: a2d97403b48b392aace75e62c1724ec04c4a2562
source_paths: HarnessCLI/, README.md
status: deprecated
reviewed: 2026-06-24
reviewed_by: human
created: 2026-06-15
updated: 2026-06-18
---

## Observations
- [harness_cli_role] New in v0.5. A tool binary (harness-cli) that shares the entire Harness/ source root with the GUI app and runs against WebDriver / IOSPlatformAdapter / MacAppDriver end-to-end. Same RunCoordinator, same event stream, same on-disk artifacts the GUI produces — minus the SwiftUI shell. Iterate on prompts, models, agent loop without rebuilding the Mac app. Development-only; not Developer-ID signed. #cli #iteration
- [cli_credentials] Cloud credentials come from env vars (ANTHROPIC_API_KEY / OPENAI_API_KEY / GOOGLE_API_KEY) with system Keychain fallback so the GUI's saved keys work for the CLI binary too. #credentials #config
- [cli_build] New xcodegen target produces harness-cli. Shares Harness/Core, Harness/Domain, Harness/Services, Harness/Tools source; excludes SwiftUI Features and App. Result is a lightweight binary suitable for GitHub Actions / CI / local iteration. #build #distribution

## Relations
- implements [[Project Overview & Targets]]
- related_to [[Run Lifecycle & Orchestration]]
