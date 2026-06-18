---
title: CONTRIBUTING.md Guidelines
type: note
permalink: harness/core/contributing-md-guidelines
tags:
- contribution
- rules
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: CONTRIBUTING.md
status: deprecated
---

## Observations
- [setup] Requirements: macOS 14+, Xcode 16+, Homebrew, idb_companion, Anthropic API key. First clone: git submodule update --init --recursive (vendors WebDriverAgent), xcodegen generate, open Harness.xcodeproj. Xcode project is gitignored; regenerated from project.yml on pull with source/resource changes. #build #setup
- [standards_enforcement] Before writing code, read standards/INDEX.md (full list), standards/01-architecture.md (module rules), and standards/AUDIT_CHECKLIST.md (run before PR). Every PR must pass `xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug build` and `xcodebuild test -project Harness.xcodeproj -scheme Harness`. For non-trivial changes, confirm audit checklist in the PR. #review #process
- [code_review_sync_rule] Public-surfaces sync rule: code changes that affect a public surface MUST update that surface in the same PR. Reviewers reject PRs touching code in column 1 without updating surfaces in column 2. Surfaces: wiki pages (Core-Services, Adding-a-Feature, Tool-Schema, Run-Replay-Format, Standards-Index), standards docs, README hero, site/landing/index.html, version bump. Skip for: bug fixes (no contract change), pure refactors, typos, test-only changes. #sync_rule #review
- [pr_format] One topic per PR. Title in conventional-commit style: feat:, fix:, chore:, refactor:, docs:, test:. Body names standards touched, e.g., 'Standards: 03, 13, 14'. PR template includes 'Public surfaces touched' checklist. #process
- [wiki_workflow] Wiki is a separate git repo. Clone as worktree once: git worktree add .wiki-worktree git@github.com:awizemann/harness.wiki.git. Edit pages in .wiki-worktree/, push via scripts/wiki.sh (runs secret-scan first). #wiki #workflow

## Relations
- governs [[Architecture & Design Decisions]]
- governs [[Standards Index]]
