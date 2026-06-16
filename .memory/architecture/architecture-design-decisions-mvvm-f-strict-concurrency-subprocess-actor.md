---
title: Architecture & Design Decisions — MVVM-F, Strict Concurrency, Subprocess Actor
type: note
permalink: harness/architecture/architecture-design-decisions-mvvm-f-strict-concurrency-subprocess-actor
tags:
- architecture
- patterns
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: standards/01-architecture.md, standards/03-subprocess-and-filesystem.md, standards/04-swift-conventions.md, docs/ARCHITECTURE.md
---

## Observations
- [pattern] MVVM-F (Model-View-ViewModel + Features): no feature module imports sibling feature modules. Strict layering enforced by xcodegen target dependencies. Features communicate via AppState (@Observable) or through the AppCoordinator navigation. #architecture
- [pattern] @MainActor by default in views and view-models. Actors for RunCoordinator, ProcessRunner, RunLogger, RunHistoryStore, ClaudeClient. Reading/writing their state from @MainActor always goes through await. #concurrency
- [rule] Swift 6 strict concurrency: no synchronous file I/O on @MainActor. View bodies never spawn subprocesses or hit filesystem. #concurrency
- [rule] One subprocess actor: ProcessRunner. All Process() invocation must go through ProcessRunner. No exceptions. #subprocess
- [pattern] AsyncThrowingStream for run events, screenshot frames, process output streaming. #patterns
- [pattern] Cancellation propagates: cancelling run task cancels coordinator; coordinator cancels child tasks (loop, screenshot poller, Claude call). ProcessRunner catches cancellation and SIGTERMs child process. #cancellation
- [design] No singletons except ToolLocator (paths to external CLIs) and keychain accessor (cached API key). Everything else is injected. #di
- [design] Typed errors per layer: ProcessFailure, BuildFailure, SimulatorError, ClaudeError, LogWriteFailure. View-model layer maps to user-facing messages. #errors

## Relations
- supersedes [[Architecture & Design Decisions]]
- relates_to [[Run Lifecycle & Orchestration]]
