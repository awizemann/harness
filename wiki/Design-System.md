# Design System

Harness's visual language is the **HarnessDesign** Swift package at [`../HarnessDesign/`](../HarnessDesign/). This wiki page is the index — one-line descriptions per token and primitive with file links. The full source is in the package; the canonical guidance is in [`../standards/05-design-system.md`](../standards/05-design-system.md).

## Tokens

All tokens are typed; no raw color/spacing/font literals in feature code.

### Colors

| Token | Use |
|---|---|
| `HarnessColor.accent` | Primary brand accent (filled buttons, focus rings, key highlights). |
| `HarnessColor.foregroundPrimary / Muted / Faint` | Body, secondary, tertiary text. |
| `HarnessColor.backgroundPrimary / Secondary / Tertiary` | Window background, panel, sub-panel. |
| `HarnessColor.border / borderStrong` | Hairline + emphasized borders. |
| `HarnessColor.success / danger / warning / info` | Verdict pills, alerts, banners. |
| `HarnessColor.friction.deadEnd / ambiguousLabel / unresponsive / confusingCopy / unexpectedState` | Friction-pill colors, one per kind in `docs/PROMPTS/friction-vocab.md`. |

All colors resolve light + dark via the asset catalog at `HarnessDesign/DesignSystem/Colors.swift`.

### Spacing / radius / shadow

| Token | Values |
|---|---|
| `HarnessSpace.s1 ... s10` | 4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 56 / 80 |
| `HarnessRadius.sm / md / lg / xl / xxl / pill` | 4 / 8 / 12 / 16 / 20 / 999 |
| `.harnessShadow(.sm / .md / .lg / .xl)` | Material-aware drop shadows. |

### Typography

`.harnessStyle(.title1 / .title2 / .title3 / .headline / .body / .bodyMuted / .caption / .captionUppercase / .mono / .monoSmall / .display)`. Eleven preset styles cover the type scale. Defined at `HarnessDesign/DesignSystem/Typography.swift`.

## Primitives

| Primitive | File | Used by |
|---|---|---|
| `PanelContainer` | `HarnessDesign/Primitives/PanelContainer.swift` | Every screen |
| `StepFeedCell` | `HarnessDesign/Primitives/StepFeedCell.swift` | RunSession, RunReplay, FrictionReport |
| `ToolCallChip` | `HarnessDesign/Primitives/ToolCallChip.swift` | StepFeedCell |
| `VerdictPill` | `HarnessDesign/Primitives/VerdictPill.swift` | RunHistory, RunReplay header |
| `SimulatorMirrorView` | `HarnessDesign/Primitives/SimulatorMirrorView.swift` | RunSession center pane, RunReplay center pane |
| `ApprovalCard` | `HarnessDesign/Primitives/ApprovalCard.swift` | RunSession (step mode) |
| `PersonaGoalForm` | `HarnessDesign/Primitives/PersonaGoalForm.swift` | GoalInput |
| `SegmentedToggle<T>` | `HarnessDesign/Primitives/SegmentedToggle.swift` | GoalInput (mode toggle), RunReplay (speed) |
| `TimelineScrubber` | `HarnessDesign/Primitives/TimelineScrubber.swift` | RunReplay |
| `SidebarRow` | `HarnessDesign/Primitives/SidebarRow.swift` | RunHistory |
| `EmptyStateView` | `HarnessDesign/Primitives/EmptyStateView.swift` | First-run, empty history, no friction in run |
| `StatusChip` | `HarnessDesign/Primitives/StatusChip.swift` | RunSession (top-right of mirror) |

## Screens

Layout drafts in `HarnessDesign/Screens/` — composed from primitives, bound to mock data:

- `GoalInputView`
- `RunSessionView`
- `RunHistoryView`
- `RunReplayView`
- `FrictionReportView`

When the application target imports `HarnessDesign`, real view-models replace the mock data. Layouts stay.

## When the design changes

See [`../standards/05-design-system.md §10`](../standards/05-design-system.md). Briefly: PR against `HarnessDesign/`, update affected feature views, update this index page.

## Don'ts

- No hardcoded colors / fonts / spacings in feature code.
- No new button styles — use primary / secondary / ghost / destructive.
- No `Color(red:green:blue:)` literals.
- No emoji in chrome.
- No purple / violet — Harness's accent is the one defined in `HarnessColor.accent`.

## Cross-references

- [`../standards/05-design-system.md`](../standards/05-design-system.md) — canonical guidance.
- [`../design-prompt.md`](../design-prompt.md) — historical artifact: the brief that produced HarnessDesign.

---

_Last updated: 2026-05-03 — initial scaffolding._
