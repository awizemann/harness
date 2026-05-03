# Design System

Harness's visual language is the **HarnessDesign** source folder at [`../HarnessDesign/`](../HarnessDesign/), included directly in the main app target. The full canonical guidance is in [`../standards/05-design-system.md`](../standards/05-design-system.md). This page is the index — token + primitive names that match the actual code.

> **Note (Phase 1):** The standards originally framed HarnessDesign as a separate Swift Package. We pragmatically include the source files in the main target instead — the package framing required mass `public`-ifying every symbol with no architectural payoff for a single-target app. If we add a second target (e.g., a CLI), HarnessDesign graduates to a Package.

## Tokens — actual API

### Colors (`HarnessDesign/DesignSystem/Colors.swift`)

All colors are extensions on `Color` that resolve light/dark via a `Color(light:dark:)` initializer wrapping `NSColor(name:)`.

| Group | Tokens |
|---|---|
| Backgrounds | `Color.harnessBg`, `harnessBg2`, `harnessBg3`, `harnessPanel`, `harnessPanel2`, `harnessElevated`, `harnessWindow` |
| Lines | `harnessLine`, `harnessLineStrong`, `harnessLineSoft` |
| Text | `harnessText`, `harnessText2`, `harnessText3`, `harnessText4` |
| Accent (mint) | `harnessAccent`, `harnessAccentSecondary`, `harnessAccentForeground`, `harnessAccentSoft` |
| Verdict semantics | `harnessSuccess`, `harnessWarning` (friction), `harnessFailure`, `harnessBlocked` |
| Tool kinds (chip coding) | `harnessToolTap`, `harnessToolType`, `harnessToolSwipe`, `harnessToolScroll`, `harnessToolWait` |

### Spacing / radius / fonts (`HarnessDesign/DesignSystem/Theme.swift`)

| Token | Values |
|---|---|
| `Theme.spacing.xs/s/m/l/xl/xxl` | 4 / 8 / 12 / 16 / 24 / 32 |
| `Theme.radius.chip / pill / button / input / panel / sheet / window` | 4–10 |
| `Theme.shadow.*` | Material-aware drop shadows |

### Typography (`HarnessDesign/DesignSystem/Typography.swift`)

`HFont.*` constants:

- `.title1`, `.title2`, `.title3`
- `.headline`, `.headlineMono`
- `.body`, `.bodyMuted`
- `.caption`, `.captionMono`
- `.micro`
- `.mono`

Used as `.font(HFont.body)` etc.

### Materials (`HarnessDesign/DesignSystem/Materials.swift`)

`HarnessMaterial.*` enum + `View.harnessMaterial(_:)` modifier wrapping system materials.

## Primitives

| Primitive | File | Used by |
|---|---|---|
| `PanelContainer<Content>` | `HarnessDesign/Primitives/PanelContainer.swift` | Every screen |
| `StepFeedCell` | `HarnessDesign/Primitives/StepFeedCell.swift` | RunSession, RunReplay, FrictionReport |
| `ToolCallChip` | `HarnessDesign/Primitives/ToolCallChip.swift` | StepFeedCell |
| `VerdictPill` | `HarnessDesign/Primitives/VerdictPill.swift` | RunHistory, RunReplay header |
| `FrictionTag` | `HarnessDesign/Primitives/FrictionTag.swift` | FrictionReport, StepFeed |
| `SimulatorMirrorView` | `HarnessDesign/Primitives/SimulatorMirrorView.swift` | RunSession, RunReplay |
| `ApprovalCard` | `HarnessDesign/Primitives/ApprovalCard.swift` | RunSession (step mode) |
| `PersonaGoalForm` | `HarnessDesign/Primitives/PersonaGoalForm.swift` | GoalInput |
| `SegmentedToggle<T>` | `HarnessDesign/Primitives/SegmentedToggle.swift` | GoalInput, RunReplay |
| `TimelineScrubber` | `HarnessDesign/Primitives/TimelineScrubber.swift` | RunReplay |
| `SidebarRow` | `HarnessDesign/Primitives/SidebarRow.swift` | RunHistory |
| `EmptyStateView` | `HarnessDesign/Primitives/EmptyStateView.swift` | First-run, empty history, no friction |
| `StatusChip` | `HarnessDesign/Primitives/StatusChip.swift` | RunSession (top-right of mirror) |

## Screens

Layout drafts in `HarnessDesign/Screens/` — composed from primitives, bound to mock data:

- `GoalInputView`
- `RunSessionView`
- `RunHistoryView`
- `RunReplayView`
- `FrictionReportView`

Phase 3 wires real view-models in place of the mock data. The primitives themselves don't change.

## Mock data

`HarnessDesign/Mocks/PreviewData.swift` provides `Preview*` placeholder types:

- `PreviewVerdict`, `PreviewToolKind`, `PreviewFrictionKind` (renamed Phase 1 to avoid collisions with the production enums in `Harness/Core/Models.swift`)
- `PreviewToolCall`, `PreviewFriction`, `PreviewStep`, `PreviewFrictionEvent`, `PreviewRun`
- `.mocks` and `.mock` static fixtures

These are HarnessDesign-internal — production code uses the real domain types in `Harness/Core/Models.swift` (`Verdict`, `ToolKind`, `FrictionKind`, `ToolCall`, etc.).

## Don'ts

- Don't introduce new button styles — use the existing primary / secondary / ghost in `ButtonStyles.swift`.
- Don't use raw `Color(red:green:blue:)` literals in feature code.
- Don't bypass the type scale with `.font(.system(size:))` — use `HFont.*`.
- Don't add purple / violet — Harness's accent is the mint green in `Color.harnessAccent`.
- Don't override radii inline — extend `Theme.radius` if you need a new value.

## When the design changes

See [`../standards/05-design-system.md §10`](../standards/05-design-system.md). Briefly: edit `HarnessDesign/`, update affected feature views, update this index page.

## Cross-references

- [`../standards/05-design-system.md`](../standards/05-design-system.md) — canonical guidance.
- [`../design-prompt.md`](../design-prompt.md) — historical artifact: the brief that produced HarnessDesign.

---

_Last updated: 2026-05-03 — Phase 1 reconciled token names with the real code; HarnessDesign included in target rather than packaged._
