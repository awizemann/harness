# Architecture Overview

The block diagram, data flow per run, and the "where does X live" lookup table all live in [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md). That document is the canonical version. This wiki page exists so an agent looking for "architecture" via the wiki finds it; consider this a redirect.

Read [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) first. Then drill into:

- [Core-Services](Core-Services.md) — table of every service with file path + isolation + purpose
- [Agent-Loop](Agent-Loop.md) — the loop in prose
- [Tool-Schema](Tool-Schema.md) — the model-facing contract
- [Run-Replay-Format](Run-Replay-Format.md) — JSONL schema reference

Concurrency model, state ownership, and the core lookup table are not duplicated here — keeping one source of truth means they don't drift.

---

## Workspace shape (Phase 6, 2026-05-04)

Harness has two concentric models the architecture docs don't fully cover yet:

- **Library entities** (`Application`, `Persona`, `Action`, `ActionChain`) — saved on disk in SwiftData, scoped per user. Always visible in the sidebar.
- **Workspace sections** (`New Run`, `Active Run`, `History`, `Friction`) — gated on the user having selected an active `Application` via `coordinator.selectedApplicationID`.

`SidebarSection.category` (`.library` vs `.workspace`) drives the sidebar's two-tier render. `selectedApplicationID` is persisted in `~/Library/Application Support/Harness/settings.json` and validated against the live store on launch.

A run is composed of: an active Application (project + scheme + simulator + run defaults), one Persona, and either a single Action or an Action Chain. Single-action runs have one Leg implicitly. Chain runs have N Legs — each Leg gets its own AgentLoop with cycle-detector + step-budget reset; the `preservesState` toggle on each chain step controls whether the simulator reinstalls the app between legs. JSONL schema v2 ships `leg_started` / `leg_completed` row kinds; v1 logs (pre-Phase 6) parse as one virtual leg.

For per-feature wiring (Compose Run form, Replay leg sections, etc.) see [Adding-a-Feature.md](Adding-a-Feature.md)'s "real examples" section.

---

_Last updated: 2026-05-04 — added Workspace shape section after Phase 6 (Applications / Personas / Actions / Chains / Named runs)._
