---
title: Design System & HarnessDesign Package — Unified Tokens
type: note
permalink: harness/design/design-system-harnessdesign-package-unified-tokens
tags: [design-system, tokens]
source_paths: [project.yml, HarnessDesign/README.md, Harness/Domain/Mappers.swift]
source_sha: 0f314a201100eb3e00b943712ea5906fa4cf9d24
created: 2026-06-16
updated: 2026-06-16
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [design] HarnessDesign is a directory of Swift sources (`HarnessDesign/`) pulled into the Harness app target via xcodegen `path: HarnessDesign` (see project.yml). Not a separate SwiftPM package and not a separate product target — its types are simply in-scope for the app. Excluded from HarnessCLI / HarnessMCP targets, so those tool binaries never link the SwiftUI presentation layer. #package
- [rule] Every feature view consumes HarnessDesign primitives + Theme/HFont/Color tokens. No raw .padding(12) / cornerRadius: 8 / .red / .green literals. Enforced via design-system unification pass in Phase 4. #rule
- [primitive] HarnessDesign/Primitives/: ApprovalCard, EmptyStateView, FlowLayout, FrictionTag, OriginBadge, PanelContainer, PendingStepCell, PersonaGoalForm, Pill, SegmentedToggle, SidebarRow, SimulatorMirrorView, StatusChip, StepFeedCell, TimelineScrubber, ToolCallChip, VerdictPill, WebMirrorView. OriginBadge was added with v0.6's Agent-runs visibility. #components
- [design] NSAppearance binds to user's system Dark Mode preference (not host app appearance). Web mirror: flat browser chrome (URL pill, lock glyph, back/forward/refresh) fills full middle column. Default viewport 1280×1600 tall desktop or 375×812 mobile. #appearance
- [adapter] Harness/Domain/Mappers.swift converts production Verdict / ToolKind / FrictionKind / ToolCall / RunRecordSnapshot to HarnessDesign's Preview* placeholder types so primitives stay decoupled from the domain model. Mappers.swift is excluded from CLI/MCP targets. #adapter

## Relations
- relates_to [[Architecture & Design Decisions — MVVM-F, Strict Concurrency, Subprocess Actor]]
