# 05 — Design System (HarnessDesign)

Applies to: **Harness**

All app UI uses the typed token bundle and primitive components in [`HarnessDesign/`](../HarnessDesign/). Reach for these tokens before inventing new colors, fonts, or spacings. The package was produced by Claude Design from the brief at [`design-prompt.md`](../design-prompt.md) and lives in-repo as the visual source of truth.

---

## 1. Where things live

```
HarnessDesign/
├── DesignSystem/
│   ├── Theme.swift          spacing, radius, shadow, corner constants
│   ├── Colors.swift         semantic + brand colors with light/dark variants
│   ├── Typography.swift     11 preset styles (.scarfStyle-equivalent)
│   ├── ButtonStyles.swift   AccentButtonStyle, SecondaryButtonStyle, etc.
│   └── Materials.swift      sidebar / toolbar material wrappers
├── Primitives/
│   ├── PanelContainer.swift
│   ├── StepFeedCell.swift
│   ├── ToolCallChip.swift
│   ├── VerdictPill.swift
│   ├── SimulatorMirrorView.swift
│   ├── ApprovalCard.swift
│   ├── PersonaGoalForm.swift
│   ├── SegmentedToggle.swift
│   ├── TimelineScrubber.swift
│   ├── SidebarRow.swift
│   ├── EmptyStateView.swift
│   └── StatusChip.swift
├── Screens/
│   ├── GoalInputView.swift
│   ├── RunSessionView.swift
│   ├── RunHistoryView.swift
│   ├── RunReplayView.swift
│   └── FrictionReportView.swift
└── Mocks/
    └── PreviewData.swift     mock structs for #Preview blocks
```

The `Screens/` files are **layout drafts** with mock data — the application target replaces the mock view-models with real ones; the layout remains.

---

## 2. Tokens, not literals

Hardcoded `.padding(12)` or `cornerRadius: 8` is a code smell. Use:

- **Spacing**: `HarnessSpace.s1...s10` (4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 56 / 80).
- **Radius**: `HarnessRadius.sm / md / lg / xl / xxl / pill`.
- **Shadow**: `.harnessShadow(.sm / .md / .lg / .xl)`.
- **Color**: `HarnessColor.accent`, `.foregroundPrimary / Muted / Faint`, `.backgroundPrimary / Secondary / Tertiary`, `.border / .borderStrong`, `.success / .danger / .warning / .info`, plus the semantic friction palette `.friction.deadEnd / .ambiguousLabel / .unresponsive / .confusingCopy / .unexpectedState`.
- **Type**: `.harnessStyle(.title2)`, `.harnessStyle(.body)`, `.harnessStyle(.captionUppercase)`, `.harnessStyle(.mono)`, etc. Eleven preset styles cover the type scale.

Adapt-to-system colors only — every color resolves from an asset catalog with explicit light/dark variants. No raw `Color(red:green:blue:)` literals in feature code.

---

## 3. Primitives are the API surface

Feature views compose from `HarnessDesign` primitives. They never:

- Reach into `HarnessDesign` private state.
- Reimplement a primitive that already exists.
- Override a primitive's tokens with hardcoded values to "tweak" the look.

If a primitive doesn't fit, **extend the primitive** (PR against `HarnessDesign/`) — don't fork it inline.

Primitive → screen mapping:

| Screen | Primitives used |
|---|---|
| `GoalInputView` | `PersonaGoalForm`, `SegmentedToggle`, `AccentButtonStyle`, `PanelContainer` |
| `RunSessionView` | `SimulatorMirrorView`, `StepFeedCell`, `ToolCallChip`, `StatusChip`, `ApprovalCard`, `PanelContainer` |
| `RunHistoryView` | `SidebarRow`, `VerdictPill`, `EmptyStateView` |
| `RunReplayView` | `TimelineScrubber`, `StepFeedCell`, `SimulatorMirrorView` |
| `FrictionReportView` | `StepFeedCell` (friction variant), `VerdictPill` |

---

## 4. Light + dark mode

- Dark mode is primary — Harness is a developer tool used long-session.
- Light mode is fully supported; every color, every primitive, every screen has a light variant in its `#Preview`.
- Use `Color(light:dark:)` extensions (defined in `HarnessDesign/DesignSystem/Colors.swift`); don't use `@Environment(\.colorScheme)` checks inside feature views to swap colors manually.
- System materials (`.regularMaterial`, `.thinMaterial`) for sidebar / toolbar backgrounds; they adapt automatically.

---

## 5. Native macOS conventions

- `NavigationSplitView` for the main shell.
- `Toolbar` with `ToolbarItem` for window-level actions.
- Sheets for modal flows (settings, first-run wizard, friction report export).
- `Menu` for option pickers.
- Keyboard shortcuts wired via `.keyboardShortcut`. Standard set (mirrors the design brief):
  - `⌘N` New Run
  - `⌘.` Stop active run
  - `Space` Approve next action (step mode)
  - `S` Skip
  - `⇧Space` Reject with note
  - `⌘,` Settings
  - `⌘⇧R` Open replay for selected run

---

## 6. Accessibility

Every custom control must be accessibility-labeled:

```swift
StatusChip(state: .running)
    .accessibilityLabel("Run status")
    .accessibilityValue("Running, step 12 of 40")
```

Dynamic Type respected up to `.xLarge` minimum. The chrome typography uses fixed sizes (status chips, monospace coordinate readouts) — body content respects user scaling.

---

## 7. Motion

Restrained.

- The last-tap dot fades over ~800ms (`HarnessMotion.tapDotFade`).
- Step feed cells slide in with `HarnessMotion.feedInsert` (~250ms ease-out).
- Approval card rises with a soft spring (`HarnessMotion.approvalSpring`).
- Status chip "Running" state pulses subtly.
- No emoji in chrome, no decorative animation. Motion communicates state changes; that's it.

---

## 8. Iconography

SF Symbols only. Custom assets are reserved for the app icon and any brand marks. Each primitive's SF Symbol choices are documented in its file header. When adding a new primitive, prefer an existing SF Symbol over commissioning artwork.

---

## 9. Don'ts

- Don't bypass the type scale with `.font(.system(size: 13.5))`.
- Don't introduce arbitrary brand colors. The accent is set; semantic colors are set.
- Don't ship terminal / syntax-highlight palettes through `HarnessColor` — those are content semantics, keep them inline (e.g., for the JSONL replay viewer's syntax coloring).
- Don't add a third button style. We have primary, secondary, ghost, destructive — that's enough.
- Don't override `cornerRadius` on `PanelContainer` without a token; if you need a new radius, add it to `HarnessRadius`.
- Don't hardcode `Color.gray` — use `HarnessColor.foregroundMuted` or `.borderStrong` depending on intent.

---

## 10. When the design changes

Updating tokens or primitives:

1. Open a PR against `HarnessDesign/`.
2. Update every `#Preview` to demonstrate the new state.
3. Update affected feature views to consume the new token or primitive variant.
4. Update [`wiki/Design-System.md`](../wiki/Design-System.md) — the wiki page is the human-facing index that links to each primitive's source file.
5. If the change is non-trivial, mention it in the PR description so the reviewer notices the visual diff.

The wiki page lists every token and primitive with one-line summaries; full source remains in `HarnessDesign/`.
