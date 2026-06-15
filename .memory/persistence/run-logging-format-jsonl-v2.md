---
title: Run Logging Format (JSONL v2+)
type: note
permalink: harness/persistence/run-logging-format-jsonl-v2
tags:
- logging
- format
- persistence
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: standards/14-run-logging-format.md, Harness/Services/RunLogger.swift, Harness/Services/RunLogParser.swift
---

## Observations
- [jsonl_structure] Append-only JSONL log with per-row synchronize(). Row types: run_started / step_started / tool_call / tool_result / note_friction / step_completed / run_completed (and leg_started / leg_completed for v2). Each row is atomic; incomplete logs handled gracefully by RunLogParser. #format
- [v2_leg_support] v2 (new in Phase 6) adds leg_started(index, payload) / leg_completed(index, verdict) markers for multi-leg runs. Per-leg budget reset. schemaVersion field in standards/14-run-logging-format.md gates migration. Parser wraps v1 logs in one virtual leg for v2 reader; v1→v2 round-trip loses leg markers but data stays intact. #versioning #migration
- [meta_json] Snapshot written at run end: {applicationID, applicationName, personaID, personaName, payload, startedAt, endedAt, verdict, legs, frictionCount, toolCalls}. RunHistoryDetailView grid displays these fields. Separate from events.jsonl so replay logic is independent. #metadata
- [credential_redaction] Three credential-redaction invariants: (1) password bytes never in model context, (2) password bytes never in JSONL, (3) password bytes never in prompts. RunRequest.credentialLabel / credentialUsername recorded (decode-if-present for v1 compat); no password value ever written. #security #invariants
- [friction_inline] Inline frictions (noted during a step via note_friction tool calls) forwarded through AgentDecision.inlineFriction → JSONL note_friction rows with timestamp, kind, detail. Supports multi-tool emissions: one primary tool call + N note_friction calls. #friction #events

## Relations
- implements [[Run Lifecycle & Orchestration]]
- extends [[Workspace & Actions Chain System]]
