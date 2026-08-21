---
title: Standards Index & Documentation Structure
type: note
permalink: harness/core/standards-index-documentation-structure
tags: [standards, documentation]
source_paths: [standards/INDEX.md, CONTRIBUTING.md, docs/PROMPTS]
source_sha: a2d97403b48b392aace75e62c1724ec04c4a2562
created: 2026-06-16
updated: 2026-07-21
reviewed: 2026-06-24
reviewed_by: human
---

## Observations
- [requirement] standards/ directory mandatory reading before contributing. 12 numbered files + INDEX.md + AUDIT_CHECKLIST.md covering development, code, and architecture standards. #mandatory
- [files] Standards files actually present: 01-architecture.md (MVVM-F, feature isolation), 02-swiftdata.md (SwiftData used only for Run history index; per-step data is JSONL on disk), 03-subprocess-and-filesystem.md (ProcessRunner rule), 04-swift-conventions.md (Swift 6 strict concurrency, os.Logger, no print in prod), 05-design-system.md (HarnessDesign tokens + primitives + screen drafts), 07-ai-integration.md (Claude defaults, prompt caching, history compaction, persona injection, cost budget, prompt-injection defense), 08-run-log-integrity.md (append-only JSONL invariants, atomic step boundaries), 09-performance.md (component extraction, agent loop cost patterns, mirror polling), 10-testing.md (Swift Testing, no timing-dependent tests, replay-based agent tests), 12-simulator-control.md (simctl + idb interfaces — historical, idb replaced by WDA in Phase 5 — SimulatorRef, coordinate space), 13-agent-loop.md (loop, cycle detector, step + token budgets, approval gate, friction taxonomy), 14-run-logging-format.md (JSONL row schema, screenshot conventions, versioning, replay invariants). 06 (editor-patterns) and 11 (multiplatform) are SKIPPED per standards/INDEX.md. #index
- [documentation] docs/ : ARCHITECTURE.md (block diagram + data flow), ROADMAP.md (phase-by-phase build order), PROMPTS/ (system-prompt.md, persona-defaults.md, friction-vocab.md, plus personas/ + platforms/ subdirs; loaded as bundle resources). #docs
- [documentation] wiki/ : reference pages per component/feature. Updated alongside code per PR (public-surfaces sync rule). Managed by Memophant — committing the wiki/ tier publishes to the GitHub Wiki; wiki/ is the single source of truth. #wiki
- [reference] README.md: hero section, quick download, three targets (iOS/macOS/web), v0.6 features, first clone, how to read repo, contributing link. #readme
- [reference] CONTRIBUTING.md: setup (macOS 14+, Xcode 16+, Homebrew, xcodegen, Anthropic API key — idb_companion is NO LONGER required; WDA replaced it in Phase 5), architecture at a glance, guidelines (Swift 6, ProcessRunner rule, design tokens, logging, testing), public-surfaces sync rule with table. #contributing

## Relations
- relates_to [[Contributing Rules & Public Surfaces Sync]]
