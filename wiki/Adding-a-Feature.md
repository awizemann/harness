# Adding a Feature

A feature is a self-contained MVVM-F module under `Harness/Features/<Name>/`. Per [`../standards/01-architecture.md`](../standards/01-architecture.md), it owns its own Models, ViewModels, Views and never imports a sibling feature.

## Recipe

### 1. Decide if it's actually a feature

A feature is a user-visible surface that has its own ViewModel + lifecycle. If it's a single primitive used in another screen, it belongs in `HarnessDesign/`, not `Features/`. If it's a service (no UI), it belongs in `Harness/Services/`.

### 2. Lay out the directory

```
Harness/Features/<Name>/
├── Models/
│   └── <Name>Model.swift          // feature-only types
├── ViewModels/
│   └── <Name>ViewModel.swift      // @MainActor, @Observable
└── Views/
    ├── <Name>View.swift           // top-level entry view
    └── <Name>SubView.swift        // optional, if extracted for size
```

### 3. Wire navigation

Add a case to `SidebarSection` (or to the parent feature's nav state, if it's a sub-flow). Update `AppCoordinator` only if the navigation surface changes — most features just react to existing coordinator state.

### 4. Inject dependencies

Services come in via initializer or `@Environment`. **Never** import a sibling feature; if you need data from "another feature," route it through a service in `Harness/Services/`.

### 5. View body discipline

- Compose from `HarnessDesign` primitives.
- View body never touches the filesystem or spawns subprocesses.
- `@State` count ≤ ~10 per view — extract sub-views if approaching the limit.

### 5a. Token discipline

Read [`Design-System.md`](Design-System.md) for the full primitive table. Hard rules:

- **No magic numbers.** Use `Theme.spacing.{xs/s/m/l/xl/xxl}` (4/8/12/16/24/32) and `Theme.radius.{chip/pill/button/input/panel/card/sheet/window}`. If you need a value the tokens don't cover, extend `Theme` rather than hardcoding.
- **No system colors for chrome.** `.red`/`.green`/`.orange`/`.yellow` literals leak through appearance switches. Use `Color.harnessFailure`/`harnessSuccess`/`harnessWarning`/`harnessBlocked` for verdict semantics, `Color.harnessText{2,3,4}` for grey text, `Color.harnessLine` for hairlines.
- **Prefer the primitive.** Re-rolling a panel? It's `PanelContainer`. Re-rolling an empty state? `EmptyStateView`. Re-rolling a status indicator? `StatusChip`. Re-rolling a tool-call render? `ToolCallChip`.
- **Map production types at the boundary.** Feature views touch real `Verdict`/`ToolCall`/`FrictionKind` — primitives consume `Preview*` shapes. The mappers in `Harness/Domain/Mappers.swift` bridge the two; extend that file rather than duplicating mapping inline.
- **Font tokens.** `HFont.{title1/title2/title3/headline/headlineMono/body/bodyMuted/caption/captionMono/micro/mono}`. `.font(.system(size:))` is a smell — use a token or extend `HFont`.

### 6. Tests

- View-model unit tests: state transitions, error mapping. No UI.
- Snapshot tests are optional; pixel tests are not used.
- If the feature consumes the agent loop, add at least one replay-fixture test.

### 7. Wiki update

If the feature introduces a new pattern or surface, **add a row** to [Core-Services](Core-Services.md) (if a service was added) and update this page's "real examples" section below.

### 8. Audit

Run [`../standards/AUDIT_CHECKLIST.md`](../standards/AUDIT_CHECKLIST.md) over the diff before requesting review.

---

## Real examples

- `GoalInput/` — **Goal-led composer** (redesigned 2026-05). Section header bar with breadcrumb + preflight `Pill`. Body sections in order: run name row (auto-name placeholder when blank), hero heading, goal card (`SegmentedToggle<RunSource>` action/chain header + `TextEditor` middle + TRY example chips footer; chain mode swaps the textarea for a per-leg notice), context strip (three readonly `ContextCell`s — Application / Simulator / Persona), persona preview (avatar + voice quote), Source picker panel (Action or Chain) with inline ordered chain preview, Persona picker panel, Run-mode strip (two equal `ModeCell`s with radio dot + subtitle + `KbdKey` shortcut hints), Advanced disclosure (Model `SegmentedToggle<AgentModel>` + Step-budget `Stepper` with `INHERITS APP` badges when defaults are unmodified). Sticky footer pins preflight status + "Save as Action" + Start Run (`AccentButtonStyle` + ⌘↵). Save-as-Action calls `runHistory.upsert(_ snapshot: ActionSnapshot)` directly and flashes "Saved to Actions" for ~1.5s. Data flow unchanged from Phase E — VM still hydrates Personas / Actions / Chains and synthesizes a `RunRequest`; hand-off through `AppContainer.stagePendingRun(_:)`.
- `RunSession/` — Three-pane HSplitView: LeftRail (status block + meta), centered `SimulatorMirrorView` with a `StatusChip` overlay and `ApprovalCardWrapper` rising from the bottom, right-rail step feed. Consumes `AsyncThrowingStream<RunEvent>` from `RunCoordinator.run(_:approvals:)`.
- `RunHistory/` — `List` + `.searchable` + `SegmentedToggle<VerdictFilter>` toolbar. Empty states use `EmptyStateView`. Right-click → "Export Run…" zips the run dir via `ProcessRunner`-spawned `/usr/bin/zip` to an `NSSavePanel` destination.
- `RunReplay/` — `PanelContainer`-wrapped screenshot pane + step-detail pane. Tool-call → `ToolCallChip`, friction → `FrictionTag`. Multi-step runs scrub via `TimelineScrubber`; single-step runs fall back to a simple counter (the primitive divides by `stepCount - 1`). **Phase E** added `RunReplayViewModel.legs: [LegView]` (built by `RunLogParser.legViews(from:)`) plus `legBoundaryIndices: Set<Int>` that the scrubber renders as accent-colored ticks at each leg-start.
- `Settings/` — Native `Form` + `Section`. Health rows render as `StatusChip`s mapped via `wdaStatusKind`. Defaults section is plain `Picker` / `Stepper` / `Toggle`.
- `FrictionReport/` — Friction-only timeline for the selected run. Top summary band + per-event `FrictionReportCard` (screenshot left, agent metadata + detail + observation quote right). Toolbar `SegmentedToggle<FrictionKindFilter>` collapses the production friction taxonomy into `All / Ambiguous / Missing / Dead-ends`. "Jump to step" sets `coordinator.replayJumpToStep`, `RunReplayViewModel.anchorStep` reads it once on load and seeks `currentStepIndex`. PDF / Markdown / Share toolbar items are stubs — see [`docs/DESIGN_BACKLOG.md`](../docs/DESIGN_BACKLOG.md).
- `Personas/` — Library list/detail HSplitView for the saved persona prompts. `PersonasViewModel` owns `[PersonaSnapshot]` against `RunHistoryStoring`; built-ins are read-only with a "Duplicate to edit" CTA. `PersonaCreateView` sheet supports prefilling from a starter (typically a built-in).
- `Actions/` — Two-tab library (`SegmentedToggle<ActionsTab>` in `.principal`) backing both Actions and Action Chains in one `ActionsViewModel`. `ChainDetailView` renders an editable, drag-to-reorder step list with per-step `preservesState` toggles; chains with zero steps render an amber draft banner; steps whose referenced Action was deleted render a `FrictionTag(kind: .deadEnd)` row and gate the (future) Run affordance. `vm.brokenStepCount(in:)` + `vm.chainsReferencing(actionID:)` surface the cross-reference state.

For the agent-loop primer that ties the run lifecycle together, see [Agent-Loop.md](Agent-Loop.md).

---

_Last updated: 2026-05-04 — Phase D added the Actions/Chains library; Phase C added the Personas library._
