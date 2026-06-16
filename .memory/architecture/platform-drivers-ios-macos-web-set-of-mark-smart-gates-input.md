---
title: Platform Drivers: iOS, macOS, Web — Set-of-Mark, Smart Gates, Input
type: note
permalink: harness/architecture/platform-drivers-ios-macos-web-set-of-mark-smart-gates-input
tags:
- drivers
- platforms
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Services/SimulatorDriver.swift, Harness/Platform/, README.md
---

## Observations
- [driver] iOS: xcodebuild → build app, simctl → boot/install/launch, WebDriverAgent (xcodebuild test-without-building) → input + AX probes. WDA cached per iOS version under ~/Library/Application Support/Harness/wda-build/<iOS-version>/ after submodule SHA. WDA waitForReady timeout 120s (bumped from 45s for iOS 26.2+). #ios
- [driver] iOS Set-of-Mark: probes WebDriverAgent /source?format=json AX tree. Returns accessibility elements with id + label. Agent calls tap_mark(id). iOS Cell labels roll up child StaticText/Image so agent sees 'Settings — General — About' instead of '(unlabeled)'. #marking
- [driver] macOS: NSWorkspace launch (pre-built .app or xcodebuild macOS scheme). CGEvent for input. CGWindowListCreateImage for capture. AXUIElementCreateApplication for Set-of-Mark probes. #macos
- [driver] macOS Set-of-Mark: probes AX tree via AXUIElementCreateApplication, walks role + enabled state to filter interactive elements. #marking
- [driver] Web: embedded WKWebView at configurable viewport (default 1280×1600 tall desktop or 375×812 mobile). JS-synthesized DOM events. WKWebView.takeSnapshot for capture. Non-persistent WKWebsiteDataStore (reproducible runs, 'what a fresh user sees'). Mirror shows flat browser chrome (no device bezel). #web
- [driver] Web Set-of-Mark: overlays numbered green badges on focusable elements. Probes pierce open shadow roots for modern signin/payment widgets. Agent calls tap_mark(id). #marking
- [gate] Smart settle gates on iOS/macOS: replace fixed sleep timers with dHash screenshot stability polling. Per-tool profiles: tap = idle 250ms / max 2s; swipe = idle 400ms / max 3s. Accepts gate once two consecutive captures within Hamming-distance 5. #stability
- [gate] Web settle gate: MutationObserver-based DOM-quietness with requireChildListMutation flag for SPA route transitions. React Suspense keeps old DOM mounted on route change, so 'idle 200ms' needed requireChildListMutation to avoid stale-page captures. #stability
- [fix] simctl screenshot exit-code flakes tolerated when PNG is on disk. WebContent log flood silenced: window placed at (0,0) with alphaValue=0, level=.normal-1 so WebKit sees real on-screen window without freeing layers. Live-mirror poller cadence dropped 3fps → 1fps. #fixes

## Relations
- supersedes [[Platform Drivers: iOS, macOS, Web]]
- relates_to [[Run Lifecycle & Orchestration]]
