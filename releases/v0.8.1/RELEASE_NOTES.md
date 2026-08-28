# Harness 0.8.1 — authenticated web sessions, honest mark labels, and a settle that waits for the swap

A point release driven by the first real-app shakedown of the step-level UI session tools against a production web app. Three engine gaps, each fixed with evidence from that run. All changes are additive on the tool surface — the five original session tools keep their names and shapes.

## Highlights

### Session-state injection + export — the authenticated-app story

Web sessions run on a non-persistent data store — a fresh user every time. That stays the default, but it put every SSO-only product out of reach: there is no password for an agent to type, and there shouldn't be. The new flow:

1. `start_ui_session({ platform: "web", url, visible: true })` — the session's window comes **on screen**, titled and accepting real input.
2. A **human** logs in — password, SSO redirect, MFA, whatever the product needs.
3. **`export_ui_session_state`** (new tool, web only) returns the session's cookies + current-origin `localStorage`, flagged `sensitive: true`.
4. The client stores that in a secret manager or Keychain; later headless runs pass it straight back as `session_state` — the export's shape round-trips with no transformation. Cookies inject **before the first navigation**, so even the first request is authenticated.

Cookie values are treated like `fill_credential`'s password: never logged (counts only, with redacted `description`s so even a stray interpolation can't leak one), never in `steps.jsonl`, never on disk, never in an error message, never on the persisted run model. A session started **without** `session_state` inherits nothing — the fresh-user invariant is untouched and live-smoke-asserted. All three capabilities (`visible`, `session_state`, the export) are rejected with a clear error on `ios`/`macos` rather than silently ignored.

### Mark labels come from the label, not the placeholder (`label_source`)

The web probe put `placeholder` ahead of the actual `<label>`, so a properly-labelled field was labelled with its sample data ("John Doe") — which downstream resolvers then keyed on. The probe now resolves an accessible name the way a screen reader would — `aria-label` → `aria-labelledby` → `<label>` → `placeholder` → `title` → `value` → visible text → `name` — and each structured mark reports which rule won as **`label_source`** (declared as an enum in the `outputSchema`; web only — iOS/macOS omit the key rather than invent a provenance). Prefer the first three for durable selectors; `placeholder` and `value` move with copy edits.

### `act_ui` settles on the DOM change, not just on navigation

A tap causing a **same-URL** React state swap (~500ms behind an awaited POST) returned the pre-action frame: the MutationObserver was armed *after* dispatch, so the click handler's own mutations were invisible, and "quiet for 250ms" is passed by a page that hasn't reacted *yet* exactly like one that never will. `execute` now arms observation **before** dispatching any non-navigating DOM-affecting action, and the gate also waits for the page's own pending work to drain — `setTimeout` ≤ 2s, in-flight `fetch`/XHR (`setInterval`/rAF/long timers deliberately untracked, since they never drain). Envelope: idle 250ms, floor 250ms, ceiling 3s. An idle page still returns at the floor; the fixture's 500ms swap is captured at a measured 970ms. Arming restores the page's original `setTimeout`/`fetch`/`XHR.send` on dispose, and a hard navigation falls back to the historical post-hoc gate.

### Verification

- **359 unit tests passing** (326 at 0.8.0): `WebSettleProfile` policy, `WebSessionState` parsing / redaction / export round-trip / `HTTPCookie` mapping, `label_source` encoding + schema agreement, and supervisor web-only gating including "an export writes no artifact row".
- **Live smoke** extended with three phases (64 checks green): label priority on a labelled field, the 500ms same-URL swap captured by `act_ui` itself, and the injection → export round trip with a `steps.jsonl` secret check plus the fresh-user assertion.

---

Architecture notes, gotchas, and the full tool schema live in the repo's memory tier and the [wiki](https://github.com/awizemann/harness/wiki).
