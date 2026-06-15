---
title: Project Overview & Targets
type: note
permalink: harness/core/project-overview-targets
tags:
- project
- overview
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: README.md, CONTRIBUTING.md
---

## Observations
- [project_charter] Harness is a native macOS developer tool (Swift 6, SwiftUI, non-sandboxed) that drives an iOS Simulator, macOS app, or web app with an AI agent to run real-user-style tests. Given a goal in plain language and a persona, an LLM agent reads screenshots, clicks/types/scrolls, narrates what it sees, flags UX friction, and reports success/failure. #core_mission
- [platform_targets] Three target kinds: iOS Simulator (xcodebuild + simctl + WebDriverAgent for input), macOS app (NSWorkspace launch + CGEvent input + CGWindowListCreateImage capture), Web app (embedded WKWebView at 1280×1600 or 375×812; JS-synthesized events; WKWebView.takeSnapshot). All three unified by Set-of-Mark targeting (numbered overlays on interactive elements; agent clicks by id, not pixel). Per-app setting at create time; agent tool schema and system-prompt context reshape per platform. #architecture #platforms
- [run_output] Three artifacts per run: (1) verdict (success/failure/blocked + summary), (2) replayable sequence of screens + actions, (3) timestamped friction events the agent flagged as confusing or blocking. #output
- [current_version] v0.5.0 (alpha). Released with local Mac inference via Ollama (Qwen3-VL 8B recommended; Gemma 4 Vision 9B; Llama 3.2 Vision 11B; custom local model field), Set-of-Mark on iOS/macOS/web, smart settle gates on iOS/macOS, harness-cli dev-time driver, and per-Application credential storage. Cloud providers: Anthropic (Opus 4.7 / Sonnet 4.6 / Haiku 4.5), OpenAI (GPT-5 Mini / GPT-4.1 Nano), Google Gemini (2.5 Flash / Flash Lite). 228 unit tests passing. #status #version #models
- [key_dependencies] macOS 14+, Xcode 16+, Swift 6 strict concurrency. Vendors appium/WebDriverAgent as git submodule under vendor/WebDriverAgent. Xcode project generated from project.yml via xcodegen. First run builds WDA against simulator's iOS runtime (~1–2 min); cached under ~/Library/Application Support/Harness/wda-build/<iOS-version>/. #build #dependencies

## Relations
- complements [[Architecture & Design Decisions]]
- complements [[Platform Drivers: iOS, macOS, Web]]
