---
title: HarnessCLI: Development-Time Driver — Shared Source, Same Artifacts
type: note
permalink: harness/tools/harnesscli-development-time-driver-shared-source-same-artifacts
tags:
- cli
- tooling
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: HarnessCLI/, project.yml
---

## Observations
- [tool] HarnessCLI (new v0.5): development-time tool binary sharing entire Harness/ source with GUI app. Runs against WebDriver / IOSPlatformAdapter / MacAppDriver end-to-end. #cli
- [capability] Same RunCoordinator, same event stream, same on-disk artifacts (events.jsonl + meta.json + screenshots) as GUI. Minus the SwiftUI shell. #compatibility
- [credential] Cloud credentials from env vars (ANTHROPIC_API_KEY / OPENAI_API_KEY / GOOGLE_API_KEY) with system Keychain fallback. GUI's saved keys work for CLI binary. #credentials
- [usage] Iterate on prompts, models, agent loop without rebuilding Mac app. Key development workflow for hypothesis testing. #workflow
- [status] Development-only; not Developer-ID signed. Xcodegen target produces harness-cli. #distribution

## Relations
- relates_to [[Run Lifecycle & Orchestration]]
