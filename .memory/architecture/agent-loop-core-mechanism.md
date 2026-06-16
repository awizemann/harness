---
title: Agent Loop Core Mechanism
type: note
permalink: harness/architecture/agent-loop-core-mechanism
tags:
- agent-loop
- orchestration
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Domain/AgentLoop.swift, docs/PROMPTS/
---

## Observations
- [mechanism] AgentLoop.swift (Harness/Domain/): runs the core agent loop. Per turn: screenshot via SimulatorDriver → ClaudeClient.step(…) tool call → (if step-mode) await approval via AsyncStream<UserApproval> → execute tool via SimulatorDriver → RunLogger appends events. Loop terminates on mark_goal_done / user cancel / step budget / token budget / cycle detected. #loop #lifecycle
- [feature] HistoryCompactor: last 6 turns kept full, older screenshots dropped from history before Claude call. Reduces token usage on long-running goals. #optimization
- [feature] Cycle detection via ScreenshotHasher: dHash per screenshot + tool-call equivalence. If same action executed twice in a row yielding same screenshot, agent is looping — terminate with blocked verdict. #safety
- [feature] Parse-failure retry: if Claude response unparseable (multi-tool, no-tool, malformed JSON), retry up to 2 times with corrective hint to model before failing run. #robustness
- [feature] Per-turn behavior reminders: each LLM step prefixes reminders like 'tap a text field first to focus before calling type', 'prefer tap_mark when marks available'. #prompting

## Relations
- relates_to [[Run Lifecycle & Orchestration]]
- relates_to [[Tool Schema & Agent Tools]]
