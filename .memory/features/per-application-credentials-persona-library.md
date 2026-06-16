---
title: Per-Application Credentials & Persona Library
type: note
permalink: harness/features/per-application-credentials-persona-library
tags:
- credentials
- personas
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Features/Applications/, Harness/Features/Personas/, docs/PROMPTS/persona-defaults.md
---

## Observations
- [feature] Per-Application credential storage (v0.3+): pre-stage username/password pairs in Application settings. Pick one per run in Compose Run. Agent gets fill_credential(field: 'username'|'password') tool. #credentials
- [security] Password security invariants: (1) Password bytes never enter model context. (2) tool_call.input for password fills records only {'field':'password'}, no value. (3) JSONL log never contains password values. (4) run_started row records optional credentialLabel + credentialUsername (for replay hints), never password. #invariants
- [feature] New friction kind: auth_required. Triggered when agent hits login wall and has no credential to fill. #friction
- [feature] Persona library: pre-built personas seeded from docs/PROMPTS/persona-defaults.md (idempotent seed on app launch). Personas: name, system-prompt text, notes. Built-in personas read-only; users duplicate to customize. #personas
- [ui] Compose Run: Persona + Credential sections paired side-by-side (both answer 'who's running'). Auto-falls back to single column on narrow windows via ViewThatFits. When no credentials staged, Persona expands to fill row. #ux

## Relations
- relates_to [[Workspace & Actions Chain System — SwiftData V2]]
- relates_to [[Tool Schema & Agent Tools]]
