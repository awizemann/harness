---
title: Per-Application Credentials & Persona Library
type: note
permalink: harness/features/per-application-credentials-persona-library
tags:
- credentials
- personas
- workspace
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: Harness/Features/Applications/, Harness/Core/Models.swift, standards/14-run-logging-format.md
---

## Observations
- [credential_storage] New in v0.3: Per-Application credential storage. Pre-stage username/password pairs against an Application; pick one per run in Compose Run. Agent gets a new fill_credential(field: 'username'|'password') tool for iOS, macOS, and web. Password bytes never enter model context, JSONL log, or prompt template — tool_call.input for password fills records only {"field":"password"} with no value. New friction kind auth_required for 'agent hit login wall and has nothing to fill' case. Credentials encrypted at rest in SwiftData. #security #auth
- [persona_library] Personas library with list/detail UI. Create/duplicate/edit/archive flows. Built-in personas seeded idempotently from docs/PROMPTS/persona-defaults.md via PromptLibrary.parseMarkdownSections. Built-in personas read-only with 'Duplicate to edit' CTA. Each persona is a snapshot with name + description + key attributes (first-time user, power user, etc.). Persona is picked per run; system prompt context includes persona at decision time. #personas #library
- [application_model] SwiftData V2 model. Application = (projectPath, scheme, kind, credentials[], personas[]). Workspace sidebar shows active Application; runs scoped to it. Create/edit sheets handle project picker (extracted to Services). Recent-runs panel shows N recent runs from this Application. Application CRUD wired in Applications feature module. selectedApplicationID persisted in settings.json; stale IDs cleared on launch. #model #workspace

## Relations
- implements [[Run Lifecycle & Orchestration]]
- related_to [[Workspace & Actions Chain System]]
