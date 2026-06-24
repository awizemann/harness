---
title: Workspace & Actions Chain System
type: note
permalink: harness/features/workspace-actions-chain-system
tags:
- chains
- actions
- workspace
source_sha: a2d97403b48b392aace75e62c1724ec04c4a2562
source_paths: Harness/Domain/ChainExecutor.swift, Harness/Core/Models.swift, Harness/Features/Actions/, standards/14-run-logging-format.md
status: deprecated
reviewed: 2026-06-24
reviewed_by: human
created: 2026-06-15
updated: 2026-06-18
---

## Observations
- [action_and_chain_models] SwiftData V2 models: Action = (name, prompt, notes). ActionChain = (name, steps: ActionChainStep[]). ActionChainStep = (actionID, preservesState: Bool). Actions listed in tab 1 with 'used in N chains' badge. Chains listed in tab 2 with drag-to-reorder editable steps. Draft warning for zero-step chains. Broken-link FrictionTag rows highlight steps pointing at deleted Actions. #model #library
- [chain_executor] ChainExecutor (new in v0.5) orchestrates multi-leg runs: per-leg AgentLoop reset (cycle detector + step budget reset), per-leg JSONL leg_started/leg_completed rows. preservesState toggle controls reinstall between legs (false = fresh state). Aggregate verdict: all-success → success; any failure/blocked → abort + skip remaining legs. TimelineScrubber gains optional leg-boundary ticks. RunHistoryDetailView summary grid shows 'Legs' cell when legs.count > 1. FrictionReportView groups friction cards by leg. #orchestration #multi_leg
- [run_payload] GoalRequest renamed to RunRequest with (name, applicationID, personaID, payload: RunPayload). RunPayload is enum: .singleAction(actionID) / .chain(chainID) / .ad_hoc(goal). Compose Run UI branches on payload kind. JSONL v2 tags each step with payload type. #model #logging
- [jsonl_v2_compat] Run-log bumped to v2 with leg support. Parser stays tolerant of v1 logs (wraps them in one virtual leg for v2 reader). schemaVersion field in standards/14-run-logging-format.md governs migration. #logging #migration

## Relations
- extends [[Per-Application Credentials & Persona Library]]
- implements [[Run Lifecycle & Orchestration]]
