---
title: Platform Drivers: iOS, macOS, Web
type: note
permalink: harness/architecture/platform-drivers-ios-macos-web
tags:
- drivers
- platforms
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: Harness/Services/SimulatorDriver.swift, Harness/Services/WDABuilder.swift, Harness/Services/WDAClient.swift, standards/07-ai-integration.md
---

## Observations
- [ios_simulator_driver] iOS Simulator driven via (1) xcodebuild to build the app, (2) simctl to boot/install/launch, (3) WebDriverAgent (xcodebuild test-without-building) for input, (4) simctl screenshot for capture. WDABuilder builds + caches .xctestrun per iOS version under ~/Library/Application Support/Harness/wda-build/iOS-<ver>/. WDAClient is URLSession HTTP client for WDA's W3C + /wda/* endpoints; retries 5xx + connection-refused. Accessibility tree probed via WebDriverAgent /source?format=json for Set-of-Mark badges. Smart settle gates poll screenshot stability via dHash (idle 250ms / max 2s for taps; 400ms / 3s for swipes). #ios #wda #settle_gates
- [macos_app_driver] macOS app driven via (1) NSWorkspace launch (pre-built .app or xcodebuild macOS scheme), (2) CGEvent for input (taps, types, key shortcuts), (3) CGWindowListCreateImage for capture. Accessibility tree probed via AXUIElementCreateApplication for Set-of-Mark badges. Smart settle gates same as iOS (dHash + Hamming distance 5). Agent tool schema includes keyboard shortcuts (⌘-specific) alongside tap/swipe. #macos #axa #settle_gates
- [web_app_driver] Web app driven via embedded WKWebView at configurable viewport (default 1280×1600 tall desktop or 375×812 mobile). JS-synthesized events for input (click, type, scroll). WKWebView.takeSnapshot for capture. DOM probed for Set-of-Mark badges via piercing shadow roots (modern signin/payment widgets supported). Mirror shows flat browser chrome (no device bezel) so screenshots fill pane. DOM-quietness gate uses MutationObserver with optional requireChildListMutation flag for SPA route transitions. WKWebsiteDataStore is non-persistent (reproducible runs). #web #webkit #shadow_dom
- [set_of_mark_targeting] All three platforms overlay numbered green badges on interactive elements at agent-decision time (in-memory only, not on disk). Agent calls tap_mark(id) instead of tap(x, y) on all three. Eliminates pixel guesswork. iOS Cell labels roll up child StaticText/Image labels (agent sees 'Settings — General — About' instead of '(unlabeled)'). Disk PNGs stay clean; marked image routed only to LLM call (no agent scaffolding on disk invariant). #targeting #accessibility
- [platform_neutral_tools] Run history, replay, and friction reporting are platform-neutral. System-prompt context block re-shapes per platform; agent tool schema (clicks vs swipes vs key shortcuts vs navigate) changes per platform. Same artifact types (verdict, step sequence, friction events) across all three. #abstraction

## Relations
- implements [[Project Overview & Targets]]
- detailed_in [[docs/ARCHITECTURE.md]]
