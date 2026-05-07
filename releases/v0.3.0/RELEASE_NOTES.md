# Harness 0.3.0 — Credentials, Set-of-Mark targeting, and a web mirror that fills the column

0.2 cracked the model path open across three providers. 0.3 cracks the **agent's targeting and authentication** open: pre-stage credentials against any Application, click form elements by numbered badge instead of pixel, and watch the live mirror render the full middle pane instead of an iPad-shaped device bezel.

## Highlights

### Per-Application credential storage

Pre-stage one or more `(label, username, password)` triples against an Application from its detail panel. Pick a credential at run time on Compose Run; the agent gets a new tool — `fill_credential(field: "username" | "password")` — on iOS, macOS, and web.

The contract on password handling, with no escape hatches:

- **No password in the JSONL.** The agent's `tool_call.input` for `fill_credential` is exactly `{"field": "password"}` — never the value. The driver synthesises the typed text from a `CredentialBinding` it caches in memory and never serialises.
- **No password in the model's context.** The system prompt's new `{{CREDENTIALS}}` block lists `label + username` only. The agent knows the credential exists and how to fill it; the password is invisible to it.
- **Screenshots rely on platform secure-text-entry.** iOS `SecureField`, macOS `NSSecureTextField`, and HTML `<input type="password">` all mask the value visually. We accept that an unusual SUT not using secure-text-entry could leak a password into a captured PNG; the create-credential UI documents the limit.

Storage split: SwiftData rows carry `(id, applicationID, label, username, createdAt)`; passwords sit in macOS Keychain under `service: "com.harness.credentials"`, account `"<applicationID>:<credentialID>"`, via existing `KeychainStoring` extensions. Even an unencrypted backup of `history.store` carries no secret material.

New friction kind: `auth_required`. The agent emits this when it hits a login wall and has nothing to fill — the friction report sections it distinctly from `dead_end` so a "this surface needs auth-bypass" run is visible at a glance.

### Set-of-Mark targeting (web)

Vision-language models miss small click targets by a handful of pixels. Inputs are typically 50px tall; the model picks y=228 when the input is at y=242–290; nothing happens; the agent retries; the run burns steps re-targeting.

Every screenshot now overlays a small numbered badge on each focusable element currently visible in the viewport — form fields, action buttons, dropdowns, checkboxes, custom-role widgets. The agent calls `tap_mark(id)` and the WebDriver resolves to the element's center via a cached `(id → rect)` map. Pixel guesswork eliminated for marked targets.

Selection is deliberately tight: marks go on **things where pixel precision matters** — not every link or generic `[tabindex]` element. Plain text links (`<a href>`) are skipped because they're typically large enough that coordinate-only tapping is reliable; the homepage doesn't need 60 numbered boxes.

Probe pierces open shadow roots so inputs nested inside custom elements (modern signin / payment widgets) get marks. Closed shadow roots and cross-origin iframes stay invisible; that's a platform limit.

The PNG saved to disk *is* the marked-up image — replay shows the agent's view exactly. A run is now readable by element identity (*"agent tapped mark 4 → Small radio"*) instead of coordinate triangulation.

iOS and macOS get the same treatment via accessibility-tree probes (WDA and AX respectively) in a follow-up; tracked on the [wiki Roadmap](https://github.com/awizemann/harness/wiki/Roadmap).

### Web mirror — full-column rendering

Web runs no longer render inside an iPad-shaped device bezel. The mirror now shows a flat browser chrome at the top — URL pill, lock glyph, back / forward / refresh affordances, loading spinner — and the screenshot fills the rest of the column.

Two related changes lower per-run API spend:

- **Default viewport bumped to 1280×1600.** Taller snapshots mean fewer scrolls per goal — measurable reduction in agent turns on long pages.
- **Dynamic viewport-height-to-canvas-aspect.** The configured 1280 CSS-pixel width stays as the layout trigger (so the page renders desktop-wide), but the height scales to the canvas aspect at run time so the snapshot fills the column without letterbox AND without forcing a narrow / mobile responsive layout.

Both happen via a tiny MainActor `LiveWebMirror` registry — the live `WebMirrorView` measures its canvas, the `WebDriver` resizes the WKWebView to match. Replay reads the saved snapshot and renders it 1:1 in the chrome.

## Loop & form correctness

Three classes of "the typed value disappeared" / "the run wedged" failure are gone:

- **React-aware `dispatchType`.** Setting `el.value = ...` directly bypasses React's value tracker; React re-renders to its own internal state and the typed text vanishes. WebDriver now resolves the native setter via `Object.getOwnPropertyDescriptor(prototype, 'value').set` and calls it with `.call(el, value)` — the standard pattern every browser test framework uses to drive React inputs. Same fix applies to `fill_credential`.
- **Click-target focus routing.** `document.elementFromPoint` returns the topmost element, which on modern signin forms is usually a wrapper `<div>` or styled `<label>` — not the `<input>`. `div.focus()` is a no-op; `label.focus()` doesn't focus the associated input. After dispatching click events, we now walk the click target to find the focusable input (direct match → `<label>` via `htmlFor`/contained input → `querySelector` descendant → `closest()` ancestor) and focus it explicitly. Subsequent `type` / `fill_credential` writes to the right `activeElement`.
- **Multi-tool emissions accepted.** The system prompt always read *"exactly one tool call ... optionally accompanied by one or more `note_friction` calls"*; the three LLM-client parsers were rejecting any `blocks.count > 1`. Each parser now splits action vs `note_friction`, requires one action, and forwards frictions through `LLMStepResponse.inlineFriction` → `AgentDecision.inlineFriction` → `RunCoordinator` (which logs each one as a friction row). Cheaper models that naturally pair "I'm flagging this" with "and trying X" no longer wedge the run.

## Architecture

- **SwiftData V5.** New `@Model Credential` with `@Relationship(deleteRule: .cascade) var credentials: [Credential]` on `Application`. V4 frozen by copying its file-scope `@Model` types into the `HarnessSchemaV4` enum's nested types — the established convention for a shape change. Lightweight v4→v5 migration; existing V4 stores reopen with `credentials == []`.
- **`RunHistoryStore` → `@ModelActor`.** The actor was constructing `ModelContext(container)` from a sync init, which Swift's strict concurrency correctly flagged at runtime: *"ModelContexts are not Sendable. Consider using a ModelActor."* The macro now generates a `nonisolated let modelExecutor: any ModelExecutor` and binds the actor's `unownedExecutor` to it, so every isolated method runs on the queue the `ModelContext` was created on. Migration-failure recovery (delete-and-retry) lifted to a private static helper outside the actor.
- **Run-log schema v3.** `RunStartedPayload` gains optional `credentialLabel` + `credentialUsername` (decodeIfPresent so v2 logs round-trip cleanly). `tool_call.input` shape for `fill_credential` and `tap_mark` documented. Parser accepts v1, v2, v3.
- **Friction taxonomy.** New `FrictionKind.authRequired` synced across the five sites the [friction-vocab standard](https://github.com/awizemann/harness/blob/main/docs/PROMPTS/friction-vocab.md) requires.

## Tests

223 unit tests passing (was 218 in 0.2). New / extended suites:

- `SwiftDataMigrationTests` — V4→V5 migration test (Applications gain empty `credentials` relation), V5 round-trip with two staged credentials, V5 cascade-delete from Application removes credentials.
- `KeychainStoreTests` — credential password round-trip uses per-credential `(applicationID:credentialID)` account keying, empty / whitespace password write rejected.
- `AgentToolsSchemaTests` — extended for `fill_credential` and `tap_mark` membership in iOS / web tool sets.
- `RunLogParserV2Tests` — parser now accepts v3, throws `schemaVersionUnsupported` for v4+.

## Known limits

- **Set-of-Mark is web-only today.** iOS and macOS still rely on coordinate-only `tap(x, y)`. Tracked on the wiki Roadmap as "Set-of-Mark targeting on iOS + macOS".
- **2FA / human-in-the-loop interrupts are unsupported.** Runs that hit SMS verification, CAPTCHAs, or push-approval flows block at that screen. The recommended path is to use test accounts without 2FA. Tracked on the Roadmap as a generic `request_user_input(reason, secret)` tool.
- **eBay-style hostile DOMs may still defeat probe-based marking.** Closed shadow roots and cross-origin auth iframes are platform-impossible to introspect; the agent falls back to coordinate-based targeting in those cases.
- **Web is still WebKit-only.** Chrome / CDP support remains on the roadmap.
- **macOS still needs Screen Recording permission.** First run prompts; subsequent runs are silent.

## Compatibility

- macOS 14+
- Apple Silicon (universal)
- Notarized + signed with Developer ID
- Existing 0.2 run records, Applications, Personas, and Action chains load unchanged. V5 migration runs once at first launch (one-shot, transparent).
