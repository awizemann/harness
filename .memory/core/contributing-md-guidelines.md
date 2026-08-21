---
title: CONTRIBUTING.md Guidelines
type: note
permalink: harness/core/contributing-md-guidelines
tags: [contribution, rules]
status: deprecated
source_paths: [CONTRIBUTING.md]
source_sha: a2d97403b48b392aace75e62c1724ec04c4a2562
created: 2026-06-15
updated: 2026-07-21
reviewed: 2026-06-24
reviewed_by: human
---

## Observations
- [setup] Requirements: macOS 14+, Xcode 16+, Homebrew, idb_companion, Anthropic API key. First clone: git submodule update --init --recursive (vendors WebDriverAgent), xcodegen generate, open Harness.xcodeproj. Xcode project is gitignored; regenerated from project.yml on pull with source/resource changes. #build #setup
- [standards_enforcement] Before writing code, read standards/INDEX.md (full list), standards/01-architecture.md (module rules), and standards/AUDIT_CHECKLIST.md (run before PR). Every PR must pass `xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug build` and `xcodebuild test -project Harness.xcodeproj -scheme Harness`. For non-trivial changes, confirm audit checklist in the PR. #review #process
- [code_review_sync_rule] Public-surfaces sync rule: code changes that affect a public surface MUST update that surface in the same PR. Reviewers reject PRs touching code in column 1 without updating surfaces in column 2. Surfaces: wiki pages (Core-Services, Adding-a-Feature, Tool-Schema, Run-Replay-Format, Standards-Index), standards docs, README hero, site/landing/index.html, version bump. Skip for: bug fixes (no contract change), pure refactors, typos, test-only changes. #sync_rule #review
- [pr_format] One topic per PR. Title in conventional-commit style: feat:, fix:, chore:, refactor:, docs:, test:. Body names standards touched, e.g., 'Standards: 03, 13, 14'. PR template includes 'Public surfaces touched' checklist. #process
- [wiki_workflow] Wiki lives in wiki/ (in-repo) and is managed by Memophant. Edit the Markdown there; committing the wiki/ tier via Memophant runs a secret-scan and publishes to the GitHub Wiki (docs(wiki): sync from wiki/ commits). wiki/ is the single source of truth; the live Wiki is a pure mirror — never edit the published copy directly. There is no wiki.sh / .wiki-worktree pipeline anymore. #wiki #workflow

## Relations
- governs [[Architecture & Design Decisions]]
- governs [[Standards Index]]
