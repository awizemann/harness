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

`SidebarSection.category` (`.library` vs `.workspace`) drives the conditional render in [`Harness/App/SidebarView.swift`](https://github.com/awizemann/harness/blob/main/Harness/App/SidebarView.swift). When `coordinator.selectedApplicationID` is nil, the workspace sections are hidden entirely; when set, they render against that Application's saved project + scheme + simulator + run defaults.

The active id is persisted in `~/Library/Application Support/Harness/settings.json` and re-validated against the live store on launch (stale ids — pointing at a deleted Application — get cleared in `HarnessApp.bootstrapPersistedScope()`).

---

## Library entities

| Entity | Purpose | File |
|---|---|---|
| **`Application`** | Saved per-project workspace: Xcode project + scheme + default simulator + per-app run defaults. One Application per project the user wants to test. | [`Harness/Services/HarnessSchema.swift`](https://github.com/awizemann/harness/blob/main/Harness/Services/HarnessSchema.swift) |
| **`Persona`** | Reusable persona prompt. Built-ins seed idempotently from `docs/PROMPTS/persona-defaults.md` on every launch. Built-ins are read-only ("Duplicate to edit"). | same |
| **`Action`** | Reusable user-prompt (the "goal" text the agent receives at `{{GOAL}}`). One Action = one goal. | same |
| **`ActionChain`** + **`ActionChainStep`** | Ordered sequence of Actions executed as one Run. Each step has a `preservesState: Bool` toggle controlling whether the simulator reinstalls the app between legs. | same |

All four entities round-trip through Sendable `*Snapshot` value types; views never touch `@Model` instances directly. See [`Harness/Domain/Mappers.swift`](https://github.com/awizemann/harness/blob/main/Harness/Domain/Mappers.swift) for the production → preview type adapters that feed `SidebarRow` and other primitives.

`RunRecord` carries optional refs (`application`, `persona_`, `action`, `actionChain`) plus mirrored `*LookupID` columns. The lookup-IDs exist because SwiftData's `.nullify` cascade can leave the in-memory relationship pointing at an invalidated backing record after the parent is deleted in the same context — touching `row.application?.id` then crashes. Snapshots read the stored UUID instead, which our delete methods clear explicitly.

---

## Composing a run

`Harness/Features/GoalInput/Views/GoalInputView.swift` — the Compose Run form. Required inputs:

1. **Active Application** — inherited from the sidebar scope. Empty state if none picked.
2. **Persona** — picked from the library (or created inline via `PersonaCreateView` sheet).
3. **Source** — `SegmentedToggle<RunSource>` between Single Action and Action Chain. Below: the matching library picker with an inline preview.
4. **Run name** (optional) — auto-fills from the chosen action / chain name + date when blank.
5. **Run options** — collapsed under "Override defaults". Inherits from the Application's `defaultModelRaw` / `defaultModeRaw` / `defaultStepBudget`.

`GoalInputViewModel.buildRequest(simulator:)` produces a `RunRequest` (renamed from `GoalRequest`; `typealias` retained for back-compat). `RunRequest` carries all five inputs plus optional per-run credential label. The request is either a single-action (`RunPayload.action`) or a chain-run (`RunPayload.chain`).

---

## Chain runs and legs

A chain run comprises N `ActionChainStep`s. Execution:

1. **Leg 0:** Execute step[0].action with the app freshly installed + launched.
2. **Leg 1:** Check step[1].preservesState.
   - If `true`: Keep the simulator's state (app running, any data created in leg 0). Execute step[1].action.
   - If `false`: Reinstall + relaunch the app from scratch. Execute step[1].action.
3. **Aggregate verdict:** All-success → success. First failure/blocked → aborts all remaining legs and chains at "blocked".

Each leg's AgentLoop instance gets a fresh cycle detector + step budget reset. The `leg_started` / `leg_completed` JSONL row pair wraps each leg's step rows; the replay UI sections the timeline and friction report by leg.

See [Glossary](Glossary) for leg / step / run / action chain definitions.

---

## Per-Application run defaults

When the user creates an Application, they set once:

- `defaultModelRaw: String` — provider + model, e.g. "anthropic:opus-4-1"
- `defaultModeRaw: String` — "stepByStep" or "autonomous"
- `defaultStepBudget: Int` — default max steps per run (configurable per run; unlimited if 0)

These populate the "Override defaults" section in Compose Run. If the user picks a different model / mode / step count for a single run, those values are recorded in the `RunRequest` but do not persist back to the Application.

Built-in persona + action-chain templates ship `isBuiltIn: true` (read-only). Users can duplicate a built-in to a custom version and edit it.

