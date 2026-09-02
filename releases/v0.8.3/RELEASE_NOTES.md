# Harness 0.8.3 — macOS sessions grow up, undeclared modals count, and taps mean what marks mean

A larger point release from two acceptance waves: the drop-help web re-shakedown (WB-17) and the first real-app macOS pass against Scarf (WB-17/23/25). The theme across all of it: the engine now tells a client what is true of the *screen*, not merely of the DOM or the AX tree. All tool-surface changes are additive.

## Highlights

### macOS mark probe rebuilt — named, deduplicated, scoped, and honest

The macOS AX walk moves out of the driver into a pure `MacMarkProbe` over a snapshotted tree — which is what makes it testable (38 fixture-tree tests plus a live suite against a real SwiftUI app). What it fixes:

- **Labels**: SwiftUI form fields whose label is an unassociated sibling `Text` came back as `label: ""`. The probe now resolves an accessible name through an ordered rule chain, reports which rule won as `label_source` (mirroring web's enum), and never ships an empty label. Adjacent-text association only speaks when the app said nothing, and refuses on ties, second claimants, intervening controls, and section boundaries — a wrong label is worse than an honest `unlabelled textField`.
- **One mark per element**, however many paths the AX graph offers to it (menus used to appear twice).
- **`page_text` on macOS**: the front frame's static text in reading order, from the same scoped subtree the marks come from.
- **Frame scoping**: a front sheet, popover, or menu owns the mark table; the window behind it does not, and every rect is in the frame's own space. No plausible root → an empty table, never a background window clipped into the frame.
- **Small controls are marked**: the 16pt minimum extent silently dropped SwiftUI controls whose AX extent is the *text*, not the hit region (an 11×11 add button, a 12×11 toggle). The floor is now 4pt — degenerate geometry, not merely small — and the candidate cap rises to 400.
- **Dead sessions read differently from ids that never existed**, on observe/act/export and cancel_run, naming the engine process since a harness-mcp restart takes every session with it.

### `tap_mark` means what the mark's role means (macOS)

A press on a text field or table row either isn't advertised or does nothing in AX, so the engine reported landed taps that changed nothing. A tap on a text-entry role now *focuses* (verified by read-back), a row or cell is *selected* (never pressed — press on a row means activate, which cannot be authored against), and everything else presses as before. Each intent falls back to one targeted click at the mark's centre, and when neither lands the step fails honestly. The intent is a pure function of the published short role, pinned by a test so the vocabularies cannot drift.

### Undeclared modals count as modals (web)

A plain React portal — `fixed inset-0 bg-black/50` around a card, no role, no `aria-modal` — kept every background mark while a declared dialog filtered correctly. The probe now recognises the *shape*, with five guardrails (no declared modal present, fixed positioning, ≥90% viewport coverage, translucent dimming, a centred opaque content box holding a live control), each pinned by a negative fixture — and the dimming test reads alpha out of any CSS colour notation, including Tailwind v4's `color-mix`. `page_text` is scoped by the same modal rule as the mark table, from one shared prelude, so the two cannot drift.

### The rest of the web/session surface

- **`scroll_into_view(id)`** (web): scroll a mark to centre without clicking it, letting the re-probe surface what was below the fold. macOS/iOS refuse honestly rather than no-op.
- **`delete_credential`**: staging finally has an inverse — removes the row and the Keychain password in the mirror of stage's ordering, and an unknown id is an error, not a "success".
- **`frame_url` on web observations**: a redirect to an identity provider now surfaces the origin change — with userinfo, query, and fragment *dropped*, not truncated (a prefix of a token is still token material). The same reduction covers the post-click URL in the unified log, which was writing OAuth `?code=…` callbacks at `.public`.
- **Synthesized labels are discriminated** on both platforms: an icon-only control takes its nearest deliberate ancestor name as a parenthetical, and remaining collisions get a reading-order rank — so "unlabelled button" can no longer name two things at once.
- **`env` / `launch_args` on macOS sessions**: the macOS counterpart of web's `session_state` — point the app at fixture data, not the user's real data. No shell on the path, so nothing is expanded or interpolated; rejections name the key, never the value; rejected loudly on web/iOS rather than dropped.
- **Settle on stable geometry** (macOS): the gate now also requires two consecutive equal samples of scoped AX geometry, catching sub-perceptual animation (a button settling x=395 → x=400) that flipped the staleness net one run in three. Unreadable accessibility falls back to pixel-only rather than burning the budget.
- **Launch reliability under rapid re-runs**: the window wait needs two agreeing readings, a fresh app instance is forced wherever the run owns the app's lifecycle (so LaunchServices can't hand back a dying predecessor), a bounded retry handles starting while the last instance is still quitting, and timeouts name which wait ran out.
- **Menu auto-dismiss (~7s) is documented** on `act_ui`/`observe_ui`, so flows are written around the fact instead of debugging it.

### Verification

- **Suite 391 → 520 green** across the wave: fixture trees for every macOS probe rule, negative fixtures for every modal guardrail, a 4000-node document, a semantics-free confirm dialog, and a click-through portal.
- **Two live smokes pass**: `ui-session-smoke.py` drives the new web behaviours end to end; the new `macos-session-smoke.py` drives a purpose-built SwiftUI app through the real MCP surface — the macOS smoke over nine consecutive runs. Verified against Scarf live: all band controls marked, fixture env takes, focus and selection land where aimed.
