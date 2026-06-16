---
title: Project Overview & v0.5 Status
type: note
permalink: harness/core/project-overview-v0-5-status
tags:
- project
- status
- version
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: README.md, project.yml
---

## Observations
- [status] Harness v0.5.0 (alpha). Native macOS dev tool (Swift 6, SwiftUI, non-sandboxed) that drives iOS Simulator, macOS app, or web app with AI agent to run real-user tests. Three platforms fully wired with Set-of-Mark targeting, local Ollama inference, and per-application credential storage. #release #platforms
- [capability] Supported AI providers: Anthropic (Opus 4.7, Sonnet 4.6, Haiku 4.5), OpenAI (GPT-5 Mini, GPT-4.1 Nano), Google Gemini (2.5 Flash, Flash Lite), and Local Mac via Ollama (Qwen3-VL 8B, Gemma 4 Vision 9B, Llama 3.2 Vision 11B, custom models). #ai-models #inference
- [capability] iOS Simulator driver: xcodebuild to build, simctl to boot/install/launch, WebDriverAgent (xcodebuild test-without-building) for input. WDA cached per iOS version under ~/Library/Application Support/Harness/wda-build/<iOS-version>/. #ios-driver
- [capability] macOS app driver: NSWorkspace launch (pre-built .app or xcodebuild scheme), CGEvent for input, CGWindowListCreateImage for capture, AXUIElementCreateApplication for Set-of-Mark probes. #macos-driver
- [capability] Web app driver: embedded WKWebView at configurable viewport (default 1280×1600 tall desktop or 375×812 mobile). JS-synthesized events for input, WKWebView.takeSnapshot for capture. Marked image (with badges) routed in-memory only; disk PNG stays clean. #web-driver
- [feature] Set-of-Mark targeting on all three platforms: iOS probes WebDriverAgent /source AX tree, macOS probes AXUIElementCreateApplication, web overlays badges on focusable elements. Agent calls tap_mark(id) instead of tap(x,y). Marked scaffolding never appears in on-disk artifacts. #targeting
- [feature] Smart settle gates on iOS and macOS: replace fixed sleep timers with dHash screenshot stability polling. Per-tool profiles: tap = idle 250ms/max 2s, swipe = idle 400ms/max 3s. Web uses MutationObserver + DOM-quietness gate with requireChildListMutation flag for SPA transitions. #stability
- [feature] Per-Application credential storage (new v0.3): pre-stage username/password pairs against an Application; pick one per run in Compose Run. Agent has fill_credential(field: 'username'|'password') tool. Password bytes never enter model context, JSONL log, or prompts. #credentials
- [feature] Local Mac inference via Ollama (new v0.5): screenshots never leave machine, runs cost $0, work offline. Native /api/chat endpoint honors options.num_ctx. Curated picker with Qwen3-VL 8B, Gemma 4 Vision 9B, Llama 3.2 Vision 11B. Trade-offs documented: ~5-10× slower per step, lower friction-event quality than cloud. #local-inference
- [feature] HarnessCLI (new v0.5): development-time tool binary sharing entire Harness/ source with GUI app. Runs against WebDriver/IOSPlatformAdapter/MacAppDriver end-to-end. Same RunCoordinator, same event stream, same on-disk artifacts. Cloud credentials from env vars or Keychain fallback. Development-only, not Developer-ID signed. #tooling
- [metric] 228 unit tests passing across 12 test suites (was 223 in v0.4). #testing

## Relations
- supersedes [[Project Overview & Targets]]
- relates_to [[Run Lifecycle & Orchestration]]
- relates_to [[Platform Drivers: iOS, macOS, Web]]
- relates_to [[AI Integration: Models, Providers, and Inference]]
