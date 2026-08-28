# MCP structured observation — `structuredContent` on `observe_ui` / `act_ui`

**Status:** merged to `main`, targets the **next release** (no version bump in this change —
`MARKETING_VERSION` stays `0.8.0`; bump it with the release as usual).
**Scope:** `harness-mcp` step-level UI-session tools, the three platform drivers, and the
`ScreenshotMetadata` contract they share.

## What changed

The step-level UI-session tools returned their mark table **as prose only**:

```
MARKS — you MUST call `tap_mark(id)` …
  1 → "name field" (input)
  2 → "waiting" (button)
```

That line is written for a vision model. The geometry it was rendered from — the exact rects the
green badges are drawn around — existed on the driver and was **thrown away** at the MCP boundary.

`observe_ui` and `act_ui` now also return an MCP **`structuredContent`** object carrying those
rects, and (on web) the frame's visible text. Both tools declare a matching **`outputSchema`** in
`tools/list`.

## New result shape

```json
{
  "session_id": "77F248B2-8679-4CC2-9C39-45E36570276B",
  "step": 1,
  "point_size": { "width": 1280, "height": 800 },
  "marks": [
    { "id": 1, "label": "name field", "role": "input",
      "rect": { "x": 40, "y": 116, "width": 264, "height": 41 } },
    { "id": 2, "label": "waiting", "role": "button",
      "rect": { "x": 320, "y": 116, "width": 220, "height": 41 } }
  ],
  "page_text": "Harness UI Session Smoke Fixture\n\nFocus the field, type, and the button's label mirrors what you typed …"
}
```

(Verbatim from the live smoke run against the local fixture, image bytes elided.)

Contract details:

- **Coordinate space.** `rect` and `point_size` are in the platform's **point** space — CSS pixels
  for web, simulator points for iOS, window points for macOS — the same space `tap(x, y)` takes.
  **Not** the screenshot's pixel space, which differs by the device scale factor.
- **Same source as the badges.** `marks` is the identical `InteractiveMark` list that
  `MarkRenderer` draws the badges from and that `MarkRenderer.describe(_:)` renders as the table:
  same ids, same order, same labels. No second probe, no re-derivation, no drift.
- **`marks` is always present** — `[]` when the probe found nothing.
- **`label`** is always present, empty string when no accessible name resolved (so a consumer
  never branches on key presence for the common field).
- **`page_text`** — see platform coverage below. **Omitted, never null**, when unavailable.
- **Non-finite geometry** (NaN / ∞) collapses to `0` rather than failing `JSONSerialization`,
  which would otherwise take down the entire `tools/call` response, not just one mark.
- **`step`** matches the observation's `steps/NNN.png` artifact, so structured data and the
  on-disk bundle line up.

## `page_text` — platform coverage (honest)

| Platform | `page_text` | Why |
| --- | --- | --- |
| **web** | ✅ present | `document.body.innerText` via the existing bounded `evaluateJavaScript` path — visible text, respecting CSS visibility the way `textContent` does not. Whitespace-normalized (each line trimmed, blank runs collapsed to one separator, edges stripped) and capped at **20 000** characters with a trailing `…` marking truncation. |
| **iOS** | ❌ omitted | The WDA probe returns element geometry + labels, not a screen text roll-up. |
| **macOS** | ❌ omitted | Same: the AX probe yields per-element labels, not screen prose. |

No new accessibility-tree walking was added for this patch, by design. An **absent** `page_text`
key means "not available on this platform" — deliberately a different claim from "this screen has
no text", which is why the key is omitted rather than set to `null`.

The web probe is bounded at **2s** (tighter than the mark probe's 8s) because it runs on every web
capture including the autonomous run loop's — page text is a convenience and must never add a
second long stall to a step already waiting out a hung page. It runs in the same pre-snapshot
window as the mark probe, so text, rects, and pixels all describe one DOM state.

## Back-compatibility

**Strictly additive. No existing client is affected.**

- The `image` and `text` content blocks of `observe_ui` / `act_ui` are **unchanged** — same order,
  same formatting, same bytes.
- `structuredContent` is a sibling field on the `tools/call` result. Clients that don't know it
  ignore it, per the MCP result shape.
- `outputSchema` is emitted **only** for the two tools that actually return `structuredContent`;
  the other fourteen tool definitions are byte-identical to before. (Advertising an `outputSchema`
  on a tool that returns no structured content would make a strict client reject a good result.)
- A failed `act_ui` still returns `structuredContent` alongside `isError: true`, so a caller sees
  current state as well as the failure — matching the pre-existing behavior for the image + table.
- `ScreenshotMetadata`'s two new fields (`marks`, `pageText`) are defaulted, so every existing
  construction site and any out-of-tree driver conformance compiles unchanged.

## Why

Walkabout drives these tools and needs geometry the prose table cannot carry:

1. **Callout annotation** — drawing a labelled pointer at a specific element on a captured frame
   requires that element's rect, not its badge number.
2. **Element-scoped visual diffs** — comparing one component between two runs means cropping both
   frames to the same rect; without geometry the only option is whole-frame diffing, which every
   unrelated change defeats.
3. **Geometric resolution** — resolving "the button under the email field" needs positions, and
   re-deriving them by OCR'ing badge numbers off a downscaled PNG is both lossy and absurd when
   the driver already has the rects.
4. **Text assertions** — asserting a page contains (or no longer contains) some copy needs the
   page's text, not a vision model's paraphrase of a screenshot.

## Test evidence

**Unit suite: 303 → 326 tests, 62 suites, all passing.**

```
before:  ✔ Test run with 303 tests in 58 suites passed
after:   ✔ Test run with 326 tests in 62 suites passed
```

`xcodebuild test -project Harness.xcodeproj -scheme Harness`. 23 new tests:

- `Tests/HarnessTests/UIObservationPayloadTests.swift` (19) — mark round-trip with geometry and
  ordering; empty mark table; zero/degenerate geometry; non-finite geometry collapsing rather than
  breaking serialization; fractional geometry surviving as a number; `page_text` present /
  omitted / empty-treated-as-absent; normalization (blank-run collapse, edge trimming, single
  newlines kept); capping at and past the cap; the shipped 20k cap; `outputSchema` wire-legality;
  encoder ⇄ schema agreement in both directions (every required key is emitted, every emitted key
  is described, mark-item fields match exactly); `page_text` described but not required.
- `Tests/HarnessTests/UISessionSupervisorTests.swift` (4, new suite) — marks and page text reach
  the observation through `observe`; likewise through `act`'s auto-observe with an advancing step;
  the empty case yields a still-valid payload; and the legacy fallback where a driver supplies
  only the prose annotation still reports a mark count.

**Live proof.** `HarnessMCP/ui-session-smoke.sh` (real `harness-mcp` binary, real WKWebView, local
fixture over HTTP) was extended and passes with zero failures. It now asserts:

- `observe_ui` and `act_ui` each declare an `outputSchema` requiring
  `session_id`/`step`/`point_size`/`marks`, and `list_ui_sessions` declares none;
- `structuredContent` arrives with a matching `session_id`, `step`, and `point_size` of 1280×800;
- the input's mark has a rect with all four fields, non-zero dimensions, sitting inside the
  viewport in both axes, and an id agreeing with the prose table;
- `page_text` contains the page's visible copy and no markup;
- after `type("hello")` the state change appears in `structuredContent.marks` **and**
  `page_text`, and the step advances.

**Binary.** Rebuilt via the repo's standard invocation
(`xcodebuild -project Harness.xcodeproj -scheme HarnessMCP -configuration Debug
-derivedDataPath .build/derived build`) to
`.build/derived/Build/Products/Debug/harness-mcp`; `--version` → `harness-mcp 0.8.0`.

## Files touched

| File | Change |
| --- | --- |
| `Harness/Platforms/UXDriving.swift` | `ScreenshotMetadata` gains `marks` + `pageText` (both defaulted). |
| `Harness/Platforms/MarkRenderer.swift` | `InteractiveMark` `Equatable` → `Hashable` (so `ScreenshotMetadata` stays `Hashable`). |
| `Harness/Platforms/Web/WebDriver.swift` | Passes marks through; adds the bounded `probeVisibleText()` + `normalizePageText(_:cap:)`. |
| `Harness/Platforms/iOS/IOSPlatformAdapter.swift`, `Harness/Platforms/MacOS/MacAppDriver.swift` | Pass marks through (including on the image-decode fallback path). |
| `Harness/UISessions/UISessionSupport.swift` | `UIObservation` gains `marks` + `pageText`. |
| `Harness/UISessions/UISessionSupervisor.swift` | Threads both through `capture`; mark count now prefers structured marks. |
| `Harness/UISessions/UIObservationPayload.swift` | **New.** The `structuredContent` encoder + the `outputSchema`, kept together so they can't drift. In the `Harness` module because the test bundle links that, not the MCP tool target. |
| `HarnessMCP/MCPProtocol.swift`, `HarnessMCP/MCPServer.swift` | `MCPToolOutcome.structuredContent`; emitted on the result when present. |
| `HarnessMCP/ToolRegistry.swift` | Optional `outputSchema` on a tool definition; declared for the two session tools. |
| `HarnessMCP/UISessionTools.swift` | Attaches the payload to the shared observe/act outcome. |
| `HarnessMCP/ui-session-smoke.py` | Live assertions for `structuredContent` + `outputSchema`. |
| `HarnessMCP/README.md`, `wiki/HarnessMCP.md`, `README.md` | Public-surface sync (CONTRIBUTING's sync rule). |

## Notes for the release

- **Do not bump the version for this change alone** — it ships with whatever the next release is.
- The wiki page's new section is marked _"New in the next release"_; retitle it to the actual
  version at release time.
- `wiki/` is a Memophant-managed tier and is left uncommitted for the owner's own secret-scanned
  commit, per this repo's `git log` precedent (wiki changes land as `docs(wiki): Memophant update`,
  not inside code commits). This document likewise lives in the managed `documents/` tier and is
  deliberately not staged.
