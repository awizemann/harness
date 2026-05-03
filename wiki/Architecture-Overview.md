# Architecture Overview

The block diagram, data flow per run, and the "where does X live" lookup table all live in [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md). That document is the canonical version. This wiki page exists so an agent looking for "architecture" via the wiki finds it; consider this a redirect.

Read [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) first. Then drill into:

- [Core-Services](Core-Services.md) — table of every service with file path + isolation + purpose
- [Agent-Loop](Agent-Loop.md) — the loop in prose
- [Tool-Schema](Tool-Schema.md) — the model-facing contract
- [Run-Replay-Format](Run-Replay-Format.md) — JSONL schema reference

Concurrency model, state ownership, and the core lookup table are not duplicated here — keeping one source of truth means they don't drift.

---

_Last updated: 2026-05-03 — initial scaffolding._
