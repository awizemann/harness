# Harness 0.8.2 — marks you can trust, credentials in step-level sessions, and no secrets in error bodies

A point release from putting the step-level UI session tools to work in a consuming product (walkabout). Two engine gaps in the web Set-of-Mark probe with production evidence, the missing credential story for step-level sessions, and a credential-leak fix in the WDA client. All tool-surface changes are additive — existing tools keep their names and shapes.

## Highlights

### Only mark what's actionable, and never ship an empty label

With a modal dialog open, the dimmed page behind it stayed in the mark table — including a background button whose label collided with the modal's own, so a resolver keyed on that label matched two elements and the run died at step 0. The web probe's `consider()` now filters for actual interactability: `pointer-events: none` (inherited, so ancestors count), `[inert]` subtrees, and a hit-test probe (`elementFromPoint` at up to seven points of the element's viewport-clipped rect, accepting the element, a descendant, or an ancestor). Separately, no mark ships with an empty label any more — a mark is a promise that `tap_mark(id)` will do something and that its label can key a resolver, and both halves of that promise are now enforced. The probe itself moved into its own `WebMarkProbe.swift` with a dedicated ~500-line test suite.

### Staged credentials in UI sessions, and honest fill failures

`fill_credential` was a silent no-op in step-level sessions: nothing carried a credential id into the session, and the drivers logged the step "ok" while doing nothing — a caller could believe it had logged in and see an unchanged screen with nothing to explain it. Now:

- **`start_ui_session` takes `credential_id`**, validated at start (unknown id and missing-Keychain-password each get their own actionable error) and echoed back as label + username only. It resolves against the shared on-disk store where `stage_credential` writes.
- **New `list_credentials`**: id + label + username per Application — the snapshot type has no password field, so the password *can't* appear.
- **`act_ui` takes `field`**, and `fill_credential` is no longer described as macOS-only — it works on web, iOS, and macOS.
- **No staged credential now fails the step** (`credentialUnavailable`) on all three platforms instead of silently succeeding, and a fill failure's message is scrubbed of the password — raw, JS-escaped, and per-character renderings — before it can be thrown.
- **Secure fields never leak through labels**: an unlabelled `<input type="password">` used to fall through to the `value` label fallback, where `el.value` is the plaintext. It now reports "Password" with `label_source: "secure-field"`.
- `HARNESS_MCP_STORE_PATH` lets the live smoke stage a real credential without touching the user's library.

### WDA error bodies redacted for text-bearing endpoints

A failing `/wda/keys` request on iOS could echo the typed text — including a credential filled via `fill_credential` — back in the HTTP error body, which then reached `os_log` at privacy `.public` through the retry-exhausted path. The body is now redacted where the error is constructed, so every downstream sink is covered; status, endpoint, and retry diagnostics are unchanged, and non-text endpoints keep their full body.

### Verification

- **391 unit tests passing** (376 at 0.8.1): the mark probe's interactability filters and label rules, credential resolution and start-time validation, the secure-field label rule, fill-failure scrubbing, and WDA redaction.
- **Live smoke** extended: stages a credential, fills both slots through a real WKWebView (proving the password by length + checksum, never printing it), asserts the no-credential case errors, and asserts no password material in any response, artifact, or log.
