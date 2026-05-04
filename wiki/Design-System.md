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

Every primitive ships with a `#Preview`; the "Used by" column is the production wiring as of Phase 4. If you add a new feature view, prefer reusing a primitive over re-rolling one — the design-token discipline section in [`Adding-a-Feature.md`](Adding-a-Feature.md) lists the do/don'ts.

| Primitive | File | Used by (production) |
|---|---|---|
| `PanelContainer<Content>` | `HarnessDesign/Primitives/PanelContainer.swift` | GoalInput sections, RunReplay screenshot + step-detail panes |
| `StepFeedCell` | `HarnessDesign/Primitives/StepFeedCell.swift` | RunSession step feed |
| `ToolCallChip` | `HarnessDesign/Primitives/ToolCallChip.swift` | StepFeedCell, RunReplay step detail |
| `VerdictPill` | `HarnessDesign/Primitives/VerdictPill.swift` | RunHistory rows, RunReplay header |
| `FrictionTag` | `HarnessDesign/Primitives/FrictionTag.swift` | RunSession friction rows, RunReplay step detail, FrictionReport cards |
| `SimulatorMirrorView` | `HarnessDesign/Primitives/SimulatorMirrorView.swift` | RunSession (live mirror with last-tap dot) |
| `ApprovalCard` | `HarnessDesign/Primitives/ApprovalCard.swift` | RunSession (step mode, via `ApprovalCardWrapper`) |
| `PersonaGoalForm` | `HarnessDesign/Primitives/PersonaGoalForm.swift` | Available; GoalInput currently inlines the equivalent fields |
| `SegmentedToggle<T>` | `HarnessDesign/Primitives/SegmentedToggle.swift` | RunHistory verdict filter |
| `TimelineScrubber` | `HarnessDesign/Primitives/TimelineScrubber.swift` | RunReplay scrubber (multi-step runs) |
| `SidebarRow` | `HarnessDesign/Primitives/SidebarRow.swift` | RunHistory left rail (consumes `PreviewRun` via the `RunRecordSnapshot` adapter in `Mappers.swift`) |
| `FlowLayout` | `HarnessDesign/Primitives/FlowLayout.swift` | RunHistory detail "Path" panel — reusable chip flow |
| `EmptyStateView` | `HarnessDesign/Primitives/EmptyStateView.swift` | RunHistory (no runs / no matches / no selection), RunSession (idle), RunReplay (load error / no steps) |
| `StatusChip` | `HarnessDesign/Primitives/StatusChip.swift` | RunSession mirror overlay, Settings tooling rows, RunHistory detail header (in-progress runs) |

## Screens

The production feature views live under `Harness/Features/<Feature>/Views/` and consume the primitives above. The original mock-data screen drafts that shipped under `HarnessDesign/Screens/` were removed in Phase 3 (they collided with the real Features views by filename). Primitives + DesignSystem stay.

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

_Last updated: 2026-05-04 — RunHistory now uses the list/detail layout, FrictionReport shipped as the fourth sidebar section. Out-of-scope follow-ups tracked in [`docs/DESIGN_BACKLOG.md`](../docs/DESIGN_BACKLOG.md)._
