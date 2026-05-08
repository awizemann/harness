# Harness 0.3.1 — Clean replay screenshots and a paired Compose Run header

A point release that polishes two of the rough edges 0.3.0 left exposed.

## Highlights

### Set-of-Mark badges off-disk

0.3.0's web targeting overlay drew small green numbered badges over every focusable element in the screenshot — and saved that marked-up image to disk. The agent loved it (no more "tapped y=228 when the input was at y=242"). Everyone else had to explain the dev-tool clutter every time they shared a screenshot in a bug report or walked a designer through a run.

0.3.1 splits the pipeline:

- **Disk PNG = the clean rendered page.** Replay, friction reports, and any exported screenshot show what a real user would see.
- **Agent payload = the marked-up copy.** Rendered in-memory, never written to disk. The web driver returns the bytes via a new `ScreenshotMetadata.markedImageData` field; `RunCoordinator` routes them to the LLM call and only the LLM call.

The `lastMarks` cache (which `tap_mark(id)` resolves against) keeps doing its job — that's what makes id → element mapping possible across turns. iOS and macOS pass `markedImageData = nil` today and inherit the same split the moment they grow accessibility-tree-based SOM (tracked under "Set-of-Mark targeting on iOS + macOS" on the [wiki Roadmap](https://github.com/awizemann/harness/wiki/Roadmap)).

Standard 14 §6 documents the new invariant: **no agent scaffolding on disk**.

### Compose Run pairs Persona + Credential

Both sections answer the same question — *who's running this run?* — so they now sit side-by-side instead of stacked. The form is one row shorter, and the pairing makes it visually obvious that the credential picker is part of the persona-shaping decision rather than a separate concern.

`ViewThatFits` falls back to a single column on narrow windows automatically. When no credentials are staged for the active Application, the credential pane self-hides as before and Persona expands to fill the row via `.frame(maxWidth: .infinity)` — no special-case branching.

Everything stays inside the existing `HarnessDesign` token system: matching `PanelContainer` headers, `Theme.spacing.l` between columns, top-aligned so a long persona blurb doesn't drag the credential picker down.

## Maintenance

- `feat/web-mirror-redesign` (a now-abandoned stacked-PR attempt left over from 0.3.0) cleaned up.

## Compatibility

- macOS 14+
- Apple Silicon (universal)
- Notarized + signed with Developer ID
- Run-log schema version stays at 3 — the marked/unmarked split is purely a local-rendering concern and never lands in JSONL. Existing 0.3.0 run records, Applications, Personas, Action chains, and credentials load unchanged.
- SwiftData stays at V5.
