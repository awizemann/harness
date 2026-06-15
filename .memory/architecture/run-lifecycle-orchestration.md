---
title: Run Lifecycle & Orchestration
type: note
permalink: harness/architecture/run-lifecycle-orchestration
tags:
- orchestration
- run_loop
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: Harness/Domain/RunCoordinator.swift, Harness/Domain/AgentLoop.swift, Harness/Services/RunLogger.swift, Harness/Features/RunSession/, Harness/Features/RunReplay/, standards/13-agent-loop.md
---

## Observations
- [run_flow] User composes a run in GoalInputView (project + scheme + simulator + persona + goal + mode). Clicks Start. RunSessionViewModel calls RunCoordinator.run(_:) which returns AsyncThrowingStream<RunEvent>. Coordinator: (1) XcodeBuilder.build → .app bundle, (2) SimulatorDriver.boot/install/launch, (3) AgentLoop runs, (4) RunLogger appends events, (5) RunHistoryStore saves record, (6) final RunEvent.completed emitted. #flow #lifecycle
- [agent_loop] AgentLoop is an actor running until mark_goal_done / cancel / budget. Per iteration: screenshot via SimulatorDriver → ClaudeClient.step(context) → tool call → in step mode, await approval via AsyncStream<UserApproval> from view-model → execute tool via SimulatorDriver → RunLogger appends event → loop. HistoryCompactor keeps last 6 turns full, older screenshots dropped. Cycle detector via ScreenshotHasher dHash + tool-call equivalence. Parse-failure retry (max 2). Step + token budget short-circuits. #loop #termination
- [step_mode] Optional per-run mode: agent pauses after each step and waits for user approval via an ApprovalCard in RunSessionView. The coordination channel is AsyncStream<UserApproval> injected from RunSessionViewModel into AgentLoop. Approval gates the next step. Stop button (⌘.) cascades cancellation and emits .stop to break the gate. #approval_gate #ui_integration
- [run_cleanup] SimulatorDriver.endInputSession always runs, even on failure, to clean up WDA resources. RunCoordinator's full lifecycle is: cleanupWDA → boot → install → launch → startInputSession → loop → endInputSession. #cleanup #error_recovery
- [run_logger] RunLogger (actor) appends JSONL rows synchronously per step. Each row is one event: run_started / step_started / tool_call / tool_result / friction / step_completed / run_completed. meta.json written at end with run summary. Format versioned; parser is tolerant of v1 logs (wraps them in one virtual leg for v2 multi-leg support). #logging #persistence
- [replay] RunReplayView loads events.jsonl + meta.json from run directory. RunReplayViewModel parses via RunLogParser, scrubber + ←/→ keys navigate. Full reasoning visible per step: observation/intent/tool/friction. Legs demarcated for multi-leg runs. Crashes mid-row/mid-step tolerated; zero-step runs load without crash. #replay #recovery

## Relations
- implements [[Architecture & Design Decisions]]
- detailed_in [[docs/ARCHITECTURE.md]]
