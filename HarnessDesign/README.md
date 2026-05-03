# Harness — SwiftUI Design Package

A native macOS developer tool that drives an iOS Simulator with an AI agent so you can run scripted "user tests" against an in-development iOS app.

This package is the **presentation layer only** — Swift files for design tokens, primitives, screen layouts, and preview mocks. There is no agent code, no networking, no real run state.

## Aesthetic direction

Modern developer-tool polish in the tradition of Linear, Raycast, Things, Cursor, TablePlus. Native macOS chrome (NavigationSplitView, ToolbarItem, sheets, materials), full dark and light mode via `Color(light:dark:)` semantic tokens, and SF Pro Text + SF Mono throughout.

The accent is **mint** (`#3DDC97` in dark, `#12936A` in light) — chosen so the agent's voice (tap dot, primary buttons, current-step rail) reads as friendly and distinct from system blue. Friction is **amber** with a triangle glyph; verdicts are **green / amber / red** pills. Tool calls are **color-coded by kind**: tap (blue), type (green), swipe (purple), scroll (pink), wait (gray), complete (mint).

Information density is tuned tight (11/12/13pt UI) but never cramped — generous gaps, hairline rules, and breathable section padding.

## File map

```
HarnessDesign/
├── DesignSystem/
│   ├── Theme.swift          spacing / radii / motion / font tokens
│   ├── Colors.swift         semantic colors with light + dark variants
│   ├── Typography.swift     SF Pro / SF Mono font tokens
│   ├── ButtonStyles.swift   Accent, Secondary, Ghost button styles
│   └── Materials.swift      .regularMaterial / .thinMaterial helpers
├── Primitives/
│   ├── PanelContainer.swift
│   ├── StepFeedCell.swift
│   ├── ToolCallChip.swift
│   ├── VerdictPill.swift
│   ├── FrictionTag.swift
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
    └── PreviewData.swift    placeholder Run / Step / Friction structs
```

Every primitive ships with `#Preview` blocks. Every screen accepts its data via a `@StateObject` view-model stub you can replace with a real one.

## Constraints honored

- SwiftUI on macOS 15+, Swift 6, strict concurrency-friendly (`@MainActor` on view models).
- No third-party UI libraries. AppKit interop only via `NSColor` for `Color(light:dark:)`.
- All custom controls are `.accessibilityLabel`-ed with `.accessibilityHint`s where useful.
- Keyboard shortcuts wired up: ⌘N New Run, ⌘. Stop, ⌘P Pause, Space Approve, ⇧Space Reject, S Skip.
- Files kept under ~250 lines; sub-views extracted aggressively to keep the SwiftUI type-checker fast.

## Drop-in instructions

1. Add the `HarnessDesign` folder to your Xcode project (Create groups, Copy items if needed).
2. Make sure your target's deployment is **macOS 15.0+** and Swift 6.
3. The `PreviewData.swift` structs are placeholders — replace `PreviewRun`, `PreviewStep`, `PreviewFrictionEvent` with your real models. The screens consume them through view-models, so changes are localized.
4. Wire up real screenshots to `RunSessionViewModel.currentImage` / `RunReplayViewModel.image` (`@Published var image: NSImage?`).
5. Wire `lastTapPoint` whenever the agent emits a tap action — `SimulatorMirrorView` will fade a dot at that coordinate over ~800ms.

## Visual reference

A side-by-side HTML comp of every screen in light + dark sits at the project root:

- `Harness Design.html` — the canonical visual reference. Open it for pixel-level design intent.

## What is intentionally out of scope

- The agent backend, Anthropic SDK calls, screenshot polling, idb_companion shelling.
- Real persistence — no Core Data, no SwiftData. Runs are in-memory mocks.
- The first-run setup wizard sheet (specced in the brief, not implemented in this pass).
- The Settings sheet body (the design HTML shows it; Swift implementation can follow the same field-row pattern using `Form` + `Section`).
