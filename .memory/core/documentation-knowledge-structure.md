---
title: Documentation & Knowledge Structure
type: note
permalink: harness/core/documentation-knowledge-structure
tags:
- docs
- reference
- knowledge
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: standards/INDEX.md, docs/ARCHITECTURE.md, docs/ROADMAP.md, docs/PROMPTS/, README.md, CONTRIBUTING.md
---

## Observations
- [doc_locations] standards/INDEX.md — mandatory before code (12 numbered files + checklist). docs/ARCHITECTURE.md — system architecture block diagram + data flow. docs/ROADMAP.md — build order + Phase 0–6 status (Phase 6 shipped). docs/PROMPTS/ — canonical agent prompts (loaded as bundle resources at runtime; structure: system-prompt + persona-defaults + friction-vocab). GitHub Wiki — 'where things live, why, how to extend'; maintained per PR alongside code. README.md — hero + targets + status + 'what's new' + first-clone + 'how to read'. #reference #navigation
- [wiki_canonical] Wiki is the canonical 'deeper why does this live here, how do I extend it' reference. Key pages: Architecture-Overview, Core-Services, Adding-a-Feature, Tool-Schema, Run-Replay-Format, iOS-Driver, macOS-Driver, Local-vs-Cloud-Models, HarnessCLI, Standards-Index. Maintained as a separate git repo (git worktree .wiki-worktree); pushed via scripts/wiki.sh (secret-scan first). Updated per PR for any code change affecting public surfaces. #wiki #maintenance
- [standards_canon] Standards at standards/<number>-<title>.md are the binding development rules. Amended standards must update both the .md file and the wiki Standards-Index. New friction kind must update five touchpoints per CONTRIBUTING.md 'Public surfaces' table. #standards #rules
- [prompt_library] docs/PROMPTS/ contains (1) system-prompt.md (full agent context, tool schema, per-platform behavior notes), (2) persona-defaults.md (built-in personas seeded into the library), (3) friction-vocab.md (canonical friction kinds + trigger descriptions). PromptLibrary loads from Bundle.main; AgentLoop caches system prompt after first load. Changes to prompts do NOT require version bump; treated as runtime tuning. #prompts #ai

## Relations
- governs [[CONTRIBUTING.md Guidelines]]
- complements [[Architecture & Design Decisions]]
