---
title: Workspace & Actions Chain System — SwiftData V2
type: note
permalink: harness/features/workspace-actions-chain-system-swiftdata-v2
tags:
- workspace
- actions
- chains
- swiftdata
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Domain/ChainExecutor.swift, Harness/Features/Applications/, Harness/Features/ActionsChains/
---

## Observations
- [model] SwiftData V2 (@Model): Application (projectPath, scheme, kind, credentials), Persona (name, prompt, notes, isBuiltIn flag), Action (name, prompt, notes), ActionChain (name, steps: ActionChainStep[]), ActionChainStep (actionID, preservesState: Bool). V1→V2 migration backfills one Application per distinct (projectPath, scheme) tuple from run history. #schema
- [feature] Sidebar LIBRARY / WORKSPACE sections. LIBRARY always shows. WORKSPACE gated on selectedApplicationID (persisted in settings.json; stale ids cleared on launch). Active Application card between them. #ui
- [feature] Applications module: full CRUD, create/edit sheets, recent-runs panel. ProjectPicker extracted to Harness/Services/ so both Applications and run form share it. #crud
- [feature] Personas library: list/detail UI, create/duplicate/edit/archive. Built-in personas seeded idempotently from docs/PROMPTS/persona-defaults.md via PromptLibrary.parseMarkdownSections. Built-ins read-only with 'Duplicate to edit' CTA. #personas
- [feature] Actions & Action Chains: two-tab ActionsView with single ActionsViewModel. Actions: name/prompt/notes/'used in N chains' badge. Chains: drag-to-reorder editable steps, per-step preservesState toggle, draft warning for zero-step chains, broken-link FrictionTag rows for deleted actions. #actions
- [feature] Chain executor (Harness/Domain/ChainExecutor.swift): multi-leg runs. Per-leg AgentLoop reset (cycle detector + step budget). Per-leg JSONL leg_started/leg_completed rows. preservesState toggle controls reinstall between legs. Aggregate verdict: all-success → success, any failure/blocked → abort remaining. #executor
- [file] RunRequest (renamed from GoalRequest in v0.6): name / applicationID / personaID / payload: RunPayload (.singleAction / .chain / .ad_hoc). Compose Run pairs Persona + Credential side-by-side (both answer 'who's running this'). #request
- [ui] TimelineScrubber gains optional leg-boundary ticks. RunHistoryDetailView summary grid includes 'Legs' cell when legs.count > 1. FrictionReportView groups cards by leg for chain runs. #replay

## Relations
- supersedes [[Workspace & Actions Chain System]]
- relates_to [[Per-Application Credentials & Persona Library]]
- relates_to [[Run Logging Format (JSONL v2+)]]
