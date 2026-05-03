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

(Filled in as features land in Phase 3.)

- `GoalInput/` — TBD
- `RunSession/` — TBD
- `RunHistory/` — TBD
- `RunReplay/` — TBD
- `FrictionReport/` — TBD
- `Settings/` — TBD

---

_Last updated: 2026-05-03 — initial scaffolding._
