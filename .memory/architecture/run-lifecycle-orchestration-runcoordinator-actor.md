---
title: Run Lifecycle & Orchestration — RunCoordinator Actor
type: note
permalink: harness/architecture/run-lifecycle-orchestration-runcoordinator-actor
tags:
- orchestration
- lifecycle
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Domain/RunCoordinator.swift, Harness/Domain/ChainExecutor.swift, docs/ARCHITECTURE.md
---

## Observations
- [flow] RunCoordinator (actor in Harness/Domain/): run(_:approvals:) returns AsyncThrowingStream<RunEvent>. Orchestrates: build → boot → install → launch → startInputSession → loop → endInputSession → log → cleanup. endInputSession always runs (even on failure). #lifecycle
- [flow] Compose phase: User enters project + scheme + simulator + persona + goal + mode in GoalInputView. View-model assembles a RunRequest (formerly GoalRequest). #compose
- [flow] Start: User clicks Start. RunSessionViewModel calls RunCoordinator.run(_:) injecting approvals AsyncStream for step-mode gate. #start
- [flow] Build: XcodeBuilder.build(...) → spawns xcodebuild via ProcessRunner with derived data isolated under run dir → returns .app bundle URL. #build
- [flow] Sim setup: SimulatorDriver.boot(...), install(_:), launch(bundleID:). Status bar overrides applied. #sim-setup
- [flow] Input session: startInputSession() initializes WebDriverAgent (iOS) or CGEvent (macOS) or WKWebView (web). endInputSession() cleans up. #input
- [flow] Loop: AgentLoop runs (per 13-agent-loop.md): screenshot → ClaudeClient.step() → (step mode) await approval → execute tool → RunLogger appends events → loop until mark_goal_done / cancel / budget. #loop
- [flow] Wrap-up: Final run_completed row written. meta.json snapshot written. SwiftData RunRecord saved by RunHistoryStore. Coordinator emits RunEvent.completed(verdict:) and stream finishes. #wrap
- [flow] Chain runs (multi-leg): ChainExecutor orchestrates per-leg AgentLoop reset and aggregate verdict. Per-leg JSONL leg_started/leg_completed rows. preservesState toggle controls reinstall between legs. #chains

## Relations
- relates_to [[Agent Loop Core Mechanism]]
- relates_to [[Workspace & Actions Chain System — SwiftData V2]]
- relates_to [[Platform Drivers: iOS, macOS, Web]]
