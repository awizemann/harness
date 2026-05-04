# Workspace

The "workspace" is Harness's organizing model after Phase 6 (2026-05-04). Where v1 made the user re-pick the project / re-type the persona / re-type the goal every run, Phase 6 introduces curated library entities and a scope-aware sidebar that makes runs cheap to compose.

This page is the one-stop reference for the workspace model. For per-entity details see the canonical sources listed at the bottom.

---

## The two tiers

```
LIBRARY                    (always visible)
├── Applications           ⌘1
├── Personas               ⌘2
└── Actions                ⌘3

[Active Application card — only when selectedApplicationID != nil]

WORKSPACE                  (only when an Application is selected)
├── New Run                ⌘N
├── Active Run             (only when activeRunID != nil)
├── History
└── Friction

HEALTH                     (always)
```

`SidebarSection.category` (`.library` vs `.workspace`) drives the conditional render in [`Harness/App/SidebarView.swift`](../Harness/App/SidebarView.swift). When `coordinator.selectedApplicationID` is nil, the workspace sections are hidden entirely; when set, they render against that Application's saved project + scheme + simulator + run defaults.

The active id is persisted in `~/Library/Application Support/Harness/settings.json` and re-validated against the live store on launch (stale ids — pointing at a deleted Application — get cleared in `HarnessApp.bootstrapPersistedScope()`).

---

## Library entities

| Entity | Purpose | File |
|---|---|---|
| **`Application`** | Saved per-project workspace: Xcode project + scheme + default simulator + per-app run defaults. One Application per project the user wants to test. | [`Harness/Services/HarnessSchema.swift`](../Harness/Services/HarnessSchema.swift) |
| **`Persona`** | Reusable persona prompt. Built-ins seed idempotently from `docs/PROMPTS/persona-defaults.md` on every launch. Built-ins are read-only ("Duplicate to edit"). | same |
| **`Action`** | Reusable user-prompt (the "goal" text the agent receives at `{{GOAL}}`). One Action = one goal. | same |
| **`ActionChain`** + **`ActionChainStep`** | Ordered sequence of Actions executed as one Run. Each step has a `preservesState: Bool` toggle controlling whether the simulator reinstalls the app between legs. | same |

All four entities round-trip through Sendable `*Snapshot` value types; views never touch `@Model` instances directly. See [`Harness/Domain/Mappers.swift`](../Harness/Domain/Mappers.swift) for the production → preview type adapters that feed `SidebarRow` and other primitives.

`RunRecord` carries optional refs (`application`, `persona_`, `action`, `actionChain`) plus mirrored `*LookupID` columns. The lookup-IDs exist because SwiftData's `.nullify` cascade can leave the in-memory relationship pointing at an invalidated backing record after the parent is deleted in the same context — touching `row.application?.id` then crashes. Snapshots read the stored UUID instead, which our delete methods clear explicitly.

---

## Composing a run

`Harness/Features/GoalInput/Views/GoalInputView.swift` — the Compose Run form. Required inputs:

1. **Active Application** — inherited from the sidebar scope. Empty state if none picked.
2. **Persona** — picked from the library (or created inline via `PersonaCreateView` sheet).
3. **Source** — `SegmentedToggle<RunSource>` between Single Action and Action Chain. Below: the matching library picker with an inline preview.
4. **Run name** (optional) — auto-fills from the chosen action / chain name + date when blank.
5. **Run options** — collapsed under "Override defaults". Inherits from the Application's `defaultModelRaw` / `defaultModeRaw` / `defaultStepBudget`.

`GoalInputViewModel.buildRequest(simulator:)` produces a `RunRequest` (renamed from `GoalRequest`; `typealias` retained for back-compat). `RunRequest.payload` is one of:

- `.singleAction(actionID, goal)` — one-Leg run.
- `.chain(chainID, [ChainLeg])` — N-Leg run (each `ChainLeg` carries `actionID`, `actionName`, `goal`, `preservesState`).
- `.ad_hoc(goal)` — fallback for tests / pre-Phase-6 paths that don't reference the library.

---

## Chain execution

[`Harness/Domain/ChainExecutor.swift`](../Harness/Domain/ChainExecutor.swift) holds the pure helpers (leg expansion + verdict aggregation). The side-effecting leg loop lives in [`Harness/Domain/RunCoordinator.swift`](../Harness/Domain/RunCoordinator.swift) because it owns the simulator driver lifecycle + JSONL writes.

Per-leg flow:

1. Append `leg_started` row to the JSONL (with `leg`, `actionName`, `goal`, `preservesState`).
2. If `leg.index > 0` AND prev leg's `preservesState` is false: `terminate → install → launch` to reset the app.
3. Drive the agent loop with `goal = leg.goal`. Cycle detector + step budget reset per leg. Token budget is the per-run total.
4. Wait for `mark_goal_done(verdict, summary)`. Append `leg_completed`.
5. On `failure` or `blocked`: synthesize skipped `leg_completed` rows for the remaining legs and short-circuit. The run's aggregate verdict is the worst leg's verdict (any failure → failure; any blocked → blocked; otherwise success).

Single-action and ad-hoc runs go through the same code path with one synthesized leg — no special-case branches downstream.

---

## JSONL v2

Phase E bumped the run-log schema to **v2**. New row kinds:

- `leg_started` — `{ "leg": Int, "actionName": String, "goal": String, "preservesState": Bool }`
- `leg_completed` — `{ "leg": Int, "verdict": String, "summary": String }`

The parser stays tolerant of v1 logs (no leg rows). `RunLogParser.legViews(_:)` synthesizes one virtual leg around all step rows for v1, so consumers (`RunReplayViewModel`, `FrictionReportViewModel`) never branch on schema version. v3+ throws `schemaVersionUnsupported`.

Full schema reference: [`standards/14-run-logging-format.md`](../standards/14-run-logging-format.md).

---

## How surfaces consume the new shape

| Surface | Phase 6 change |
|---|---|
| [`Harness/Features/RunHistory/`](../Harness/Features/RunHistory) | `filteredRuns(applicationID:)` defaults to scoping by the active Application. `SidebarRow`'s primary line is the run's `name` (then first-leg actionName, then goal text). Detail summary grid grows a "Legs" cell when `legs.count > 1`. |
| [`Harness/Features/RunReplay/`](../Harness/Features/RunReplay) | VM exposes `legs: [LegView]` + `legBoundaryIndices: Set<Int>`. `TimelineScrubber` gained an optional `legBoundaries:` parameter that renders thicker accent ticks at leg-start indices. |
| [`Harness/Features/FrictionReport/`](../Harness/Features/FrictionReport) | Multi-leg runs render cards under per-leg `Section` headers. Single-leg runs and v1 logs render as a flat list (unchanged). |
| [`Harness/Features/Applications/`](../Harness/Features/Applications) | New module — list/detail HSplitView. `ActiveApplicationCard` is the sidebar header chip with a Switch menu over other Applications. |
| [`Harness/Features/Personas/`](../Harness/Features/Personas) | New module — built-ins are read-only with a "Duplicate to edit" CTA. |
| [`Harness/Features/Actions/`](../Harness/Features/Actions) | New module — two-tab segmented view over Actions and Chains in one VM. Chain editing supports drag-to-reorder and per-step `preservesState` toggle. Broken-step rows render `FrictionTag(kind: .deadEnd)`. |

---

## Cross-references

- [`docs/ROADMAP.md`](../docs/ROADMAP.md) §Phase 6 — checklist of what shipped.
- [`docs/DESIGN_BACKLOG.md`](../docs/DESIGN_BACKLOG.md) — Phase 6 follow-ups (cross-app reports, variable substitution, branching chains, edit history).
- [Glossary](Glossary.md) — canonical definitions of Application / Persona / Action / Action Chain / Leg / Step / Tool call / Goal.
- [Adding-a-Feature](Adding-a-Feature.md) — "real examples" gain entries for the new modules.
- [Run-Replay-Format](Run-Replay-Format.md) — JSONL v2 schema with leg row kinds.
- [`standards/02-swiftdata.md`](../standards/02-swiftdata.md) — V1→V2 migration rationale, V2 model table.
- [`standards/13-agent-loop.md`](../standards/13-agent-loop.md) — leg semantics + per-leg cycle detector reset.
- [`standards/14-run-logging-format.md`](../standards/14-run-logging-format.md) — v2 schema + v1→v2 reader migration semantics.

---

_Last updated: 2026-05-04 — Phase 6 (workspace rework) shipped._
