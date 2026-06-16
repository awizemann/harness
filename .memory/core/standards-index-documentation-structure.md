---
title: Standards Index & Documentation Structure
type: note
permalink: harness/core/standards-index-documentation-structure
tags:
- standards
- documentation
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: standards/INDEX.md, standards/AUDIT_CHECKLIST.md, docs/ARCHITECTURE.md, docs/ROADMAP.md, README.md, CONTRIBUTING.md
---

## Observations
- [requirement] standards/ directory mandatory reading before contributing. 12 numbered files + INDEX.md + AUDIT_CHECKLIST.md covering development, code, and architecture standards. #mandatory
- [files] Standards files: 01-architecture.md (MVVM-F, feature isolation), 02-codebase-structure.md, 03-subprocess-and-filesystem.md (ProcessRunner rule), 04-swift-conventions.md (strict concurrency, no print in prod), 05-design-system.md (tokens only), 06-app-lifecycle.md, 07-ai-integration.md (models, providers, prompt caching), 08-ui-platform-conventions.md, 09-simulator-and-driver-state.md, 10-testing.md (Swift Testing, no timing), 11-versioning-and-release.md, 12-gitflow-and-pr-process.md, 13-agent-loop.md, 14-run-logging-format.md. #index
- [documentation] docs/ : ARCHITECTURE.md (block diagram + data flow), ROADMAP.md (phase-by-phase build order), PROMPTS/ (system prompt, persona defaults, friction vocab, loaded as bundle resources). #docs
- [documentation] wiki/ : reference pages per component/feature. Updated alongside code per PR (public-surfaces sync rule). Clone as worktree: git worktree add .wiki-worktree git@github.com:awizemann/harness.wiki.git. #wiki
- [reference] README.md: hero section, quick download, three targets (iOS/macOS/web), v0.5 features, first clone, how to read repo, contributing link. #readme
- [reference] CONTRIBUTING.md: setup (macOS 14+, Xcode 16, idb_companion), architecture at a glance, guidelines (Swift 6, ProcessRunner rule, design tokens, logging, testing), public-surfaces sync rule with table. #contributing

## Relations
- relates_to [[Contributing Rules & Public Surfaces Sync]]
