---
title: Standards Index
type: note
permalink: harness/standards/standards-index
tags:
- standards
- reference
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: standards/INDEX.md, CONTRIBUTING.md
---

## Observations
- [standards_summary] 12 numbered files + INDEX + AUDIT_CHECKLIST covering development, code, and architecture standards. Mandatory reading before contributing. Located at standards/INDEX.md. #reference
- [key_standards] 01-architecture.md (module rules; features never import siblings), 03-subprocess-and-filesystem.md (ProcessRunner is the only owner of Process()), 04-swift-conventions.md (Swift 6 strict concurrency, no sync I/O on @MainActor), 05-design-system.md (design tokens only, no magic numbers), 10-testing.md (Swift Testing, no timing-dependent tests), 13-agent-loop.md (loop orchestration + step budget + cycle detection), 14-run-logging-format.md (JSONL v2+ with run-log-schema versioning). #core_standards
- [audit_checklist] Run standards/AUDIT_CHECKLIST.md before requesting review on non-trivial changes. Checks: module import graph, subprocess usage, @MainActor boundaries, design-token usage, test coverage, JSONL format invariants. #review #process

## Relations
- referenced_by [[CONTRIBUTING.md Guidelines]]
- governs [[Architecture & Design Decisions]]
