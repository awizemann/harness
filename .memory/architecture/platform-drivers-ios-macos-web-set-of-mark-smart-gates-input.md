---
title: Platform Drivers: iOS, macOS, Web — Set-of-Mark, Smart Gates, Input
type: note
permalink: harness/architecture/platform-drivers-ios-macos-web-set-of-mark-smart-gates-input
tags:
- drivers
- platforms
source_sha: a2d97403b48b392aace75e62c1724ec04c4a2562
source_paths: Harness/Services/SimulatorDriver.swift, Harness/Platforms/Web/WebPlatformAdapter.swift, Harness/Platforms/iOS/IOSPlatformAdapter.swift, Harness/Services/WDARunner.swift
reviewed: 2026-06-24
reviewed_by: human
created: 2026-06-16
updated: 2026-06-16
---

## Observations
- [driver] iOS: xcodebuild → build app, simctl → boot/install/launch, WebDriverAgent (xcodebuild test-without-building) → input + AX probes. WDA cached per iOS version under ~/Library/Application Support/Harness/wda-build/<iOS-version>/ after submodule SHA. WDA waitForReady timeout 120s (bumped from 45s for iOS 26.2+). Phase 5 idb→WDA migration: idb_companion is no longer required (SimulatorDriver.swift:17 'WDA replaced idb in Phase 5 because idb's HID injection on iOS 26+ …'). #ios
- [driver] iOS Set-of-Mark: probes WebDriverAgent /source?format=json AX tree. Returns accessibility elements with id + label. Agent calls tap_mark(id). iOS Cell labels roll up child StaticText/Image so agent sees 'Settings — General — About' instead of '(unlabeled)'. #marking
- [driver] macOS: NSWorkspace launch (pre-built .app or xcodebuild macOS scheme). CGEvent for input. CGWindowListCreateImage for capture. AXUIElementCreateApplication for Set-of-Mark probes. #macos
- [driver] macOS Set-of-Mark: probes AX tree via AXUIElementCreateApplication, walks role + enabled state to filter interactive elements. #marking
- [driver] Web: embedded WKWebView at configurable viewport (default 1280×1600 tall desktop or 375×812 mobile). JS-synthesized DOM events. WKWebView.takeSnapshot for capture. Non-persistent WKWebsiteDataStore (reproducible runs, 'what a fresh user sees'). Mirror shows flat browser chrome (no device bezel). #web
- [driver] Web Set-of-Mark: overlays numbered green badges on focusable elements. Probes pierce open shadow roots for modern signin/payment widgets. Agent calls tap_mark(id). #marking
- [gate] Smart settle gates on iOS/macOS: replace fixed sleep timers with dHash screenshot stability polling. Per-tool profiles: tap = idle 250ms / max 2s; swipe = idle 400ms / max 3s. Accepts gate once two consecutive captures within Hamming-distance 5. #stability
- [gate] Web settle gate: MutationObserver-based DOM-quietness with requireChildListMutation flag for SPA route transitions. React Suspense keeps old DOM mounted on route change, so 'idle 200ms' needed requireChildListMutation to avoid stale-page captures. #stability
- [fix] WebDriver per-step timeouts (v0.6, post-MCP hardening): EVERY per-step WKWebView await is bounded via WebDriver.raceAgainstTimeout — settle, probe, runJS, runJSAndReturn, captureSnapshot. Implementation uses unstructured Task + one-shot RaceBox continuation (a withTaskGroup awaits all children, defeating the purpose). captureSnapshot ferries a CGImage + original POINT size (not a TIFF round-trip, which can misplace Set-of-Mark badges). #fix
- [fix] simctl screenshot exit-code flakes tolerated when PNG is on disk. WebContent log flood silenced: window placed at (0,0) with alphaValue=0, level=.normal-1 so WebKit sees real on-screen window without freeing layers. Live-mirror poller cadence dropped 3fps → 1fps. #fixes

## Relations
- supersedes [[Platform Drivers: iOS, macOS, Web]]
- relates_to [[Run Lifecycle & Orchestration — RunCoordinator Actor]]
