---
title: Design System & HarnessDesign Package — Unified Tokens
type: note
permalink: harness/design/design-system-harnessdesign-package-unified-tokens
tags:
- design-system
- tokens
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: HarnessDesign/, Harness/Features/
---

## Observations
- [design] HarnessDesign: separate Swift Package included directly in main app target (not a separate product target). Contains: design system tokens (Theme.*, HFont.*, Color.harness*), primitive components (buttons, cards, pickers, lists), and screen layout abstractions. #package
- [rule] Every feature view consumes HarnessDesign primitives + Theme/HFont/Color tokens. No raw .padding(12) / cornerRadius: 8 / .red / .green literals. Enforced via design-system unification pass in Phase 4. #rule
- [primitive] Components: VerdictPill (success/failure/blocked badge), FrictionTag (friction kind badges), ApprovalCard (step-mode approval UX), TimelineScrubber (replay playhead), SimulatorMirrorView (live screenshot + coordinate overlay), StepFeedView (turn-by-turn step list). #components
- [design] NSAppearance binds to user's system Dark Mode preference (not host app appearance). Web mirror: flat browser chrome (URL pill, lock glyph, back/forward/refresh) fills full middle column. Default viewport 1280×1600 tall desktop or 375×812 mobile. #appearance

## Relations
- relates_to [[Architecture & Design Decisions]]
