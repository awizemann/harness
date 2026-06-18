---
title: Architecture & Design Decisions
type: note
permalink: harness/architecture/architecture-design-decisions
tags:
- architecture
- design
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: CONTRIBUTING.md, docs/ARCHITECTURE.md, standards/INDEX.md, standards/01-architecture.md, standards/03-subprocess-and-filesystem.md, standards/04-swift-conventions.md, standards/05-design-system.md, standards/10-testing.md
status: deprecated
---

## Observations
- [architecture_pattern] Harness follows MVVM-F (model-view-viewmodel + features). No feature module imports sibling feature modules. Strict layering enforced by xcodegen target dependencies. #mvvm #layering
- [concurrency_model] @MainActor by default in views and view-models. Actors for RunCoordinator, ProcessRunner, RunLogger, RunHistoryStore, ClaudeClient. Reading/writing actor state from @MainActor always goes through await. AsyncThrowingStream for run events, screenshot frames, and process output. Cancellation propagates: cancelling the run task cancels the coordinator; the coordinator cancels its child tasks. ProcessRunner catches cancellation and SIGTERMs the child process. #concurrency #swift_6
- [subprocess_rule] Single subprocess actor: all Process() invocation goes through ProcessRunner. No exceptions. This is a hard architectural rule; see standards/03-subprocess-and-filesystem.md. #subprocess #rule
- [design_system] All UI uses tokens from HarnessDesign/ package (separate package, included in main app target). No raw .padding(12) / cornerRadius: 8 / color literals. Design tokens: Theme.* / HFont.* / Color.harness*. See standards/05-design-system.md. #design_tokens #ui
- [logging] No print() in production code — use os.Logger with subsystem 'com.harness.app'. print() is fine in #Preview and test helpers. See standards/04-swift-conventions.md. #logging
- [state_ownership] AppCoordinator owns navigation state (sidebar selection, sheets, modal flags). AppState owns app-level cross-section state (API key presence, idb health, default sim). RunSessionViewModel owns per-run state (live screenshot, step feed, approval pending). RunCoordinator (actor) owns run orchestration (build/install/loop/log). RunRecord (SwiftData) persists run history. events.jsonl on disk persists per-step events. ProjectRef / Persona / Application (SwiftData) persist library items. No singletons except ToolLocator (path resolver) and Keychain accessor (cached API key). #state_management
- [testing_framework] Swift Testing framework (@Suite / @Test). No timing-dependent tests. Every protocol has a mock; agent loop has replay-based fixtures with MockLLMClient (scripted-sequence + lookup-closure modes) and FakeSimulatorDriver (synthesized solid-color PNGs). See standards/10-testing.md. #testing #mocks

## Relations
- referenced_by [[CONTRIBUTING.md Guidelines]]
- complements [[Project Overview & Targets]]
- detailed_in [[docs/ARCHITECTURE.md]]
