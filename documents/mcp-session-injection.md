# Session injection, honest labels, and a settle that waits — release notes

**Status:** merged to `main`, targets the **next release** (no version bump in this change —
`MARKETING_VERSION` stays `0.8.0`; bump it with the release as usual).
**Scope:** `harness-mcp` step-level UI-session tools + the web driver.
**Follows:** [`mcp-structured-observation.md`](mcp-structured-observation.md) (`structuredContent`
on `observe_ui` / `act_ui`).

Three changes, all driven by a first real-app shakedown of the step-level session tools against a
product nobody had designed them for (a Vite + Hono + D1 app, `drop-help.com`, driven by
Walkabout). Each fixes something the shakedown caught with evidence.

---

## 1. Mark labels come from the label, not the placeholder (`label_source`)

**What broke.** A properly-labelled form field —

```html
<label for="name">Your Name *</label>
<input id="name" placeholder="John Doe">
```

— produced the mark label **"John Doe"**. The probe's accessible-name order put `placeholder`
second, ahead of the actual `<label>`. Two consequences: downstream resolvers keyed on **sample
data** (which moves whenever a designer edits a placeholder), and that sample text leaked into
published guide alt text.

**What it does now.** The web probe resolves an accessible name the way a screen reader would, and
reports which rule won:

| Order | Source | `label_source` |
|---|---|---|
| 1 | `aria-label` | `aria-label` |
| 2 | `aria-labelledby`, dereferenced to the referenced elements' text | `labelledby` |
| 3 | associated `<label for>` or wrapping `<label>` | `label` |
| 4 | `placeholder` | `placeholder` |
| 5 | `title` | `title` |
| 6 | `el.value` | `value` |
| 7 | the element's own visible text | `text` |
| 8 | the `name` attribute | `name` |
| — | nothing resolved | `none` |

`label_source` is a new field on each `structuredContent` mark and is declared in the
`outputSchema` (as an enum of exactly those values). **Web only** — iOS and macOS omit the key
entirely, because their accessibility probes resolve a name without recording where it came from
and inventing a provenance would be a guess. Shadow-root elements resolve `aria-labelledby` and
`label[for]` against their own root before falling back to `document`.

**Client guidance.** Prefer `aria-label` / `labelledby` / `label` for durable selectors. Treat
`placeholder` and `value` as weak — they are sample data.

**Compatibility.** The prose mark table's *format* is unchanged (`id → "label" (role)`); the label
*text* improves, which is the point. `label_source` is additive and optional.

---

## 2. `act_ui` settles on the DOM change, not just on navigation

**What broke.** In a UI session, a tap that caused a **same-URL** React state swap — a contact form
replaced by a success screen, landing ~500ms behind an awaited POST — returned the **pre-action**
frame; the settle finished at **481ms**. A route-changing tap in the same session settled correctly
at 6.5s. The rendered guide's final screenshot therefore contradicted its own caption.

**Root cause.** Harness already had a MutationObserver quietness gate, and the non-navigating
envelope (idle 250ms / ceiling 2s) was not obviously wrong. The defect was elsewhere:

1. the observer was armed **after** the click was dispatched, so every mutation the click handler
   itself made was invisible to it; and
2. its only exit test was "no mutations for `idleMs`" — which a page that has **not reacted yet**
   passes exactly like a page that never will.

The navigating case only looked healthy because it additionally required a `childList` mutation as
evidence.

**The fix.** For non-navigating actions (`tap`, `tap_mark`, `double_tap`, `right_click`, `scroll`,
`type`, `key_shortcut`, `fill_credential`), `WebDriver.execute` arms observation **before**
dispatch, and the gate waits for the page's own pending work to drain as well as for DOM quiet:

- tracked: `setTimeout` callbacks scheduled with delay ≤ 2000ms, in-flight `fetch`, in-flight
  `XMLHttpRequest`;
- **not** tracked: `setInterval`, `requestAnimationFrame`, and timers > 2000ms — a polling loop or
  an animation never drains, and gating on one would pin every settle to its ceiling.

Envelope: **idle 250ms, floor 250ms, ceiling 3000ms** (up from 2000ms), no `childList` requirement.

**Idle pages are not slowed down.** A tap that schedules nothing and fetches nothing has
`pending == 0` immediately and still returns at the 250ms floor. Requiring a mutation instead
(the navigating profile's approach) would have made every genuine no-op tap pay the full ceiling —
which is why it was not used here.

**Safety.** Arming disposes any previous state first and restores the page's original
`setTimeout` / `fetch` / `XHR.send` on dispose, so an `execute` that throws cannot leave a page
permanently wrapped. If the armed state has vanished when the settle looks (a hard navigation tore
down the JS context), the driver falls back to the historical post-hoc gate rather than skipping
the wait.

**Proof.** `HarnessMCP/fixtures/spa-settle-fixture.html` swaps its view 500ms after the click with
no route change. The live smoke asserts the pre-action frame does **not** show the swap, that the
`act_ui` call's own `page_text` **does**, that the wait was ≥ 500ms, and that it did not stall near
the ceiling. Measured: **970ms**, post-swap DOM captured. The policy itself lives in
`WebSettleProfile`, a pure value type with its own unit suite.

---

## 3. Session-state injection + export (the authenticated-app story)

**Why.** Web sessions run on a **non-persistent** `WKWebsiteDataStore` — a fresh user every time,
nothing inherited, nothing on disk. That is deliberate and it remains the default. It also means an
SSO-only B2B product is unreachable: there is no password for an agent to type, and per the
no-real-credentials rule there should not be. The shakedown ranked this **priority #1**: every
guide worth writing for such an app lives behind a login.

**The flow.**

1. `start_ui_session({ platform: "web", url, visible: true })` — the session's window comes on
   screen (titled, key, accepting real mouse + keyboard) instead of sitting off-view at
   `alphaValue = 0`. The MCP binary raises its activation policy from `.prohibited` to
   `.accessory` so the window can take key focus; still no Dock icon, still no menu bar.
2. A **human** logs in in that window — password, SSO redirect, MFA, whatever the product needs.
3. `export_ui_session_state({ session_id })` → the session's cookies plus the current origin's
   `localStorage`.
4. The client stores that in a secret manager or the macOS Keychain. Not a repo file, not a log,
   not a saved transcript.
5. Later, headless runs pass it straight back as `session_state`.

**Schemas.**

`start_ui_session` gains two optional web-only params:

```jsonc
{
  "visible": true,                       // show the window for a human
  "session_state": {
    "cookies": [
      { "name": "session", "value": "…", "domain": ".example.com", "path": "/",
        "expires": 1800000000, "secure": true, "httpOnly": true }
    ],
    "origins": [
      { "origin": "https://app.example.com",
        "localStorage": [ { "name": "auth.token", "value": "…" } ] }
    ]
  }
}
```

- Per cookie, only `name` / `value` / `domain` are required. `path` defaults to `/`; `expires` is
  epoch **seconds** (the Playwright/CDP convention) and omitting it makes a session cookie.
- `origins` is optional. Cookies are injected before the first navigation (so the very first
  request carries them); each `origins` entry costs one extra page load at start, because
  `localStorage` is only reachable from a document on that origin. A cookie-only state costs none.

`export_ui_session_state({ session_id })` returns **exactly the shape `session_state` accepts**,
plus `session_id`, `sensitive: true`, and a note — so an export round-trips into an injection with
no client-side transformation. Cookies come from the whole store; `localStorage` is necessarily
scoped to the origin the session is standing on.

**Secret handling — the guarantees.** Cookie and `localStorage` values are bearer credentials and
are treated the way `fill_credential`'s password is:

- **Never logged.** Log lines carry counts only:
  `injected session_state: 3 cookie(s), 2 localStorage item(s) — values redacted`. The value types
  override `description` to a redacted form (name + value *length*), so an accidental string
  interpolation in some future log line still cannot leak one.
- **Never in `steps.jsonl`.** The artifact writer records `act_ui` calls; `session_state` rides on
  `start_ui_session`, which appends no row at all, and `export_ui_session_state` appends none
  either (it is not an observation — no frame, no step, no disk write).
- **Never in a tool result** except `export_ui_session_state`'s, whose entire purpose is to return
  them and which flags itself `"sensitive": true` in the result and in its tool description.
- **Never on disk.** The data store stays non-persistent: injected state lives in memory and dies
  with the session.
- **Never in an error message.** `session_state` parse errors name the offending index and field
  (`session_state.cookies[0] is missing required field 'domain'`), never the value.
- **Not on `RunRequest`.** The state rides on the transient web *adapter*, not on the persisted run
  model, so it cannot reach the history store or a run row.

**The fresh-user invariant is untouched.** A session started without `session_state` inherits
nothing — not from the machine's browsers, not from a previous session, not from a sibling session
that injected state. The live smoke asserts exactly that as its last check.

**Platform scope.** `session_state`, `visible`, and `export_ui_session_state` are **web-only** and
are rejected with a clear error on `ios` / `macos` sessions rather than silently ignored — a client
that believes it injected an auth cookie and gets a logged-out session deserves the error.

---

## Tool-surface delta

| Surface | Change |
|---|---|
| `start_ui_session` | + `visible` (bool, web), + `session_state` (object, web) |
| `export_ui_session_state` | **new** — web only, sensitive result |
| `observe_ui` / `act_ui` | `structuredContent.marks[].label_source` (web only, optional), declared in `outputSchema` |
| `act_ui` | non-navigating settle now armed pre-dispatch + async-work aware; ceiling 2s → 3s |

The five original session tool names are unchanged; `export_ui_session_state` is additive, so a
client that does not know it simply never calls it.

## Verification

- **Unit suite: 326 → 359** tests, all green (`WebSettleProfile` policy, `WebSessionState`
  parsing / redaction / export round-trip / `HTTPCookie` mapping, `label_source` encoding + schema
  agreement, supervisor web-only gating and the "an export writes no artifact row" invariant).
- **Live smoke** (`HarnessMCP/ui-session-smoke.py`, real WKWebView over real stdio MCP): label
  priority and `label_source` on a labelled field, the 500ms same-URL swap captured by `act_ui`
  itself, cookie + `localStorage` injection → export round trip, no secret in `steps.jsonl`, and
  the fresh-user invariant for a session started without state.
- **Binary**: rebuilt at `./.build/derived/Build/Products/Debug/harness-mcp`, `--version` reports
  `harness-mcp 0.8.0`.

## Public surfaces touched

`HarnessMCP/README.md` (committed), `README.md` What's-new (committed),
`wiki/HarnessMCP.md` + `wiki/Web-Driver.md` (Memophant-managed tier — edited, left uncommitted),
this document (same).
