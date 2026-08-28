# Harness 0.8.0 — macOS UI sessions arrive contained, and observations go structured

0.7 let agents drive a **web or iOS** target step by step through `harness-mcp`, with macOS deferred. 0.8 delivers that third tier — an agent can now drive a **Mac app** the same way, through a **contained input backend that never touches your pointer, focus, or any app but the target**. And the step tools stop throwing away what they know: `observe_ui` / `act_ui` now return **machine-readable structured results** — element geometry and (on web) the page's visible text — alongside the marked screenshot.

## Highlights

### macOS UI sessions — drive a Mac app without losing your desktop

`start_ui_session` accepts `platform: "macos"` with either a **prebuilt `app_path`** (the preferred QA flow — no Xcode preflight) or `project_path` + `scheme` (falls back to `xcodebuild`). What makes it safe to run on a machine you're actively using:

- **Contained input by default.** Actions go **AX-first** (`AXPress` on the hit-tested element; focus + `AXSetValue` for text), then `CGEvent.postToPid` scoped to the target — the real pointer never moves, focus is never stolen, the app is never foregrounded (`activates: false`). No path falls back to global HID; if the ladder is exhausted you get a precise `unactuatable` error naming what was attempted. Legacy global-HID behavior survives only behind `HARNESS_MACOS_INPUT=hid`.
- **Pid-scoped, stranger-proof.** Every operation on the target — input, window lookup, teardown — resolves via the **launched process id**, never the bundle id. Running your own copy of the same app alongside a session can no longer get it force-quit or clicked on.
- **Clean teardown, always.** `end_ui_session` terminates the target app (unlike GUI runs, which leave it open), a failed start quits it too, and `harness-mcp` now tears down **all** sessions on `SIGTERM`/`SIGINT` — a parent kill or Ctrl-C no longer orphans an app on your desktop.
- **Honest errors.** Capture failures no longer blame Screen Recording permission unconditionally: the message reflects whether access is actually granted, and notes that on macOS the grant may attach to the parent app that launched `harness-mcp`.
- TCC needed: **Accessibility** (input) and **Screen Recording** (capture). macOS start timeout defaults to 600s (`HARNESS_UI_SESSION_START_TIMEOUT_SECONDS` overrides).

### Structured observation — `structuredContent` on `observe_ui` / `act_ui`

The Set-of-Mark table was prose written for a vision model; the rects the badges were drawn from were discarded at the MCP boundary. Both tools now also return an MCP **`structuredContent`** object — and declare a matching **`outputSchema`** in `tools/list`:

```json
{
  "session_id": "…", "step": 1,
  "point_size": { "width": 1280, "height": 800 },
  "marks": [
    { "id": 1, "label": "name field", "role": "input",
      "rect": { "x": 40, "y": 116, "width": 264, "height": 41 } }
  ],
  "page_text": "Harness UI Session Smoke Fixture\n\nFocus the field, type…"
}
```

- **Rects are in point space** — CSS pixels / simulator points / window points, the same space `tap(x, y)` takes — and come from the **same** mark list that draws the badges and renders the table: same ids, same order, no drift. That's enough for callout annotation, element-scoped visual diffs, and geometric target resolution without OCR'ing badge numbers off a PNG.
- **`page_text`** (web only): the frame's visible text via a bounded 2s `innerText` probe in the same pre-snapshot window as the marks — whitespace-normalized, capped at 20 000 chars. iOS/macOS omit the key ("not available" is deliberately distinct from "no text").
- **Strictly additive.** The image and text blocks are byte-identical to 0.7; clients that don't know `structuredContent` ignore it. A failed `act_ui` still carries it alongside `isError`, so you see current state as well as the failure.

### Run a User Test — a Scarf mini-app

A small cockpit panel that collects a goal, persona, and target and asks the agent to drive a `harness-cli` user-test run, streaming its output back into the panel.

### Under the hood

- The manual `wiki.sh` publishing pipeline is retired; `wiki/` is the single source of truth and Memophant publishes it, eliminating the drift the old pipeline caused.
- UI-session tests now inject per-test temporary artifact roots — a full suite run writes zero entries into the real `~/Library/Application Support/Harness/runs`.
- **326 unit tests in 62 suites passing** (275 at 0.7.0), plus the live `harness-mcp` web smoke extended to assert `structuredContent`, in-viewport rects, `page_text`, and the declared `outputSchema`s end-to-end against a real WKWebView.

---

Architecture notes, gotchas, and the full tool schema live in the repo's memory tier and the [wiki](https://github.com/awizemann/harness/wiki).
