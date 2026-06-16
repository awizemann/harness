---
title: HarnessMCP: Adding Run Screenshots and Live Mirror (future work)
type: note
permalink: harness/tools/harnessmcp-adding-run-screenshots-and-live-mirror-future-work
tags:
- mcp
- screenshots
- roadmap
- tooling
---

## Observations
- [context] Deferred feature, captured for later: surface a run's screenshots — either streamed live in the GUI during an MCP-driven run (the "during" experience), or richer screenshot access over MCP. Not yet built. #roadmap #screenshots
- [storage] Per-step screenshots are written to disk at `HarnessPaths.screenshot(for: runID, step:)` = `~/Library/Application Support/Harness/runs/<runID>/step-NNN.png` (NNN = zero-padded 3-digit, 1-based step). The on-disk PNG is the UNMARKED rendering; the Set-of-Mark "marked" copy (numbered badges) is in-memory only, sent to the LLM, never written to disk. #storage
- [events] `RunCoordinator.run(...)` emits on its `AsyncThrowingStream<RunEvent>`: `.stepStarted(step, screenshotPath, screenshot: URL)` (per-step PNG now on disk) and `.previewSnapshot(jpeg: Data)` (~1 fps live mirror frame, web today, fired between steps). CRITICAL: `.previewSnapshot` is transient/in-memory — NOT persisted to disk or events.jsonl. #events
- [cross-process] The GUI and harness-mcp are SEPARATE processes; the GUI cannot see harness-mcp's in-memory `RunEvent`s (incl. `.previewSnapshot`). Anything the GUI shows for an MCP run must come via DISK: the run dir, `events.jsonl`, and the `step-NNN.png` files. #cross-process
- [mcp-now] The MCP server already exposes `get_step_screenshot(run_id, step)` → returns the step PNG as MCP image content (reads `HarnessPaths.screenshot`). Easy adds later: a `get_latest_screenshot(run_id)` convenience (resolve current step from `RunSupervisor` status, return that PNG), and/or optionally embed the latest screenshot inline in `get_run_status`. #mcp
- [live-mirror-plan] To show MCP runs live IN THE GUI: a lightweight watcher tails `<run-dir>/events.jsonl` for new `step_started` rows and loads each `step-NNN.png` as it lands, rendering with the existing RunReplay machinery (Features/RunReplay already reads a run dir's JSONL + PNGs). Per-step live mirror with zero new persistence. #plan
- [smooth-frames] Per-step PNGs only refresh on step boundaries (~5–30s cloud, minutes on local). For a smoother between-steps mirror, have harness-mcp persist the latest `.previewSnapshot` JPEG atomically to a known path (e.g. `<run-dir>/live.jpg`) on each preview tick; the GUI watches that file. This is the ONLY way to get the ~1fps web mirror cross-process, since previewSnapshot is otherwise in-memory. #enhancement
- [integration] Dovetails with the planned MCP-activity indicator (active-session marker file the GUI watches): the same marker/run dir is where a "view live" affordance would open the mirror. #integration

## Relations
- relates_to [[HarnessMCP: Stdio MCP Server to Drive Harness from Agents]]
- relates_to [[Run Logging Format — JSONL v2 (append-only, legs, credentials)]]
- relates_to [[Platform Drivers — iOS, macOS, Web]]
