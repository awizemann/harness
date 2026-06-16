---
title: Run Logging Format (JSONL v2+) — Append-Only, Legs, Credentials
type: note
permalink: harness/persistence/run-logging-format-jsonl-v2-append-only-legs-credentials
tags:
- logging
- format
- jsonl
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Services/RunLogger.swift, standards/14-run-logging-format.md
---

## Observations
- [design] Append-only JSONL log at runs/<run-id>/events.jsonl with per-row synchronize(). One row per event. Schema v2 (v0.3+) introduced leg_started / leg_completed rows and optional credentialLabel + credentialUsername in run_started. v0.5 unchanged. #format
- [design] Row types: run_started / leg_started / step_started / tool_call / tool_result / note_friction / step_completed / leg_completed / run_completed. Each row has timestamp + context keys. #rows
- [design] Password credentials never logged: tool_call.input for password fills records only {'field':'password'}, no value. run_started optionally records credentialLabel + credentialUsername (for playback hints), never password. #security
- [design] Chain runs (v0.6+): multiple legs per run. leg_started / leg_completed rows mark boundaries. Per-leg AgentLoop reset (cycle detector + step budget reset). Aggregate verdict: all-success → success, any failure/blocked → abort remaining. #chains
- [design] Smart settle gates recorded per step: dHash screenshot stability (iOS/macOS) or MutationObserver gate (web). Recorded in step_completed as settle_gate_details. #stability
- [file] Alongside events.jsonl: meta.json snapshot of run config (project, scheme, simulator, persona, goal, model, token budget, step budget). Updated at run completion. #metadata
- [file] One screenshot PNG per step at runs/<run-id>/screenshots/<step-id>.png. Stored clean (no agent scaffolding). Marked image exists only in-memory during agent processing. #screenshots

## Relations
- relates_to [[Run Lifecycle & Orchestration]]
- relates_to [[Per-Application Credentials & Persona Library]]
