---
title: Contributing Rules & Public Surfaces Sync
type: note
permalink: harness/core/contributing-rules-public-surfaces-sync
tags: [contributing, review, process]
source_paths: [CONTRIBUTING.md]
source_sha: 0f314a201100eb3e00b943712ea5906fa4cf9d24
created: 2026-06-16
updated: 2026-07-21
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] Code changes affecting a public surface MUST update that surface in the same PR. Reviewers reject PRs that touch a code path without updating its public surface. #process
- [rule] Public surface sync table: (1) New service in Harness/Services/ → wiki Core-Services page. (2) New feature module → wiki Adding-a-Feature examples. (3) Agent tool schema change (AgentTools.swift) → wiki Tool-Schema (same commit). (4) Run-log JSONL format change → bump schemaVersion in standards/14-run-logging-format.md + wiki Run-Replay-Format. (5) New friction kind → five touchpoints. (6) User-visible feature, screenshot-affecting UI, version bump → site/landing/index.html + README.md hero. (7) New top-level capability or major feature → README 'What's new' / status. (8) Standard amended → standards/<file>.md + wiki Standards-Index. #surfaces
- [rule] Skip public surface sync for: bug fixes with no observable contract change, pure refactors, typos, internal cleanups, test-only changes. #exceptions
- [rule] PR guidelines: one topic per PR. Title in conventional-commit style (feat:, fix:, chore:, refactor:, docs:, test:). Body names standards touched (e.g., 'Standards: 03, 13, 14'). Build + tests must pass. For non-trivial changes, run standards/AUDIT_CHECKLIST.md and confirm in PR. #pr-process
- [rule] Swift 6 strict concurrency. No synchronous file I/O on @MainActor. One subprocess actor: all Process() goes through ProcessRunner. Design tokens only (no magic numbers). Logging via os.Logger (no print() in production). Swift Testing framework (@Suite/@Test), no timing-dependent tests. #code-style
- [workflow] Wiki lives in wiki/ (in-repo), managed by Memophant. Edit pages there; committing the wiki/ tier via Memophant secret-scans and publishes to the GitHub Wiki. wiki/ is the single source of truth; never edit the published copy directly. (No wiki.sh / .wiki-worktree pipeline.) #wiki

## Relations
- relates_to [[Standards Index]]
- relates_to [[Architecture & Design Decisions]]
