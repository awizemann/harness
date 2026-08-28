# Release 0.8.0 — runbook

**Date prepared:** 2026-08-27. **Scope:** everything on `main` since `v0.7.0` (16 commits).

## What ships (audit summary)

| Theme | Commits |
| --- | --- |
| macOS UI sessions un-deferred: contained input backend (AX-first + postToPid, no HID/foregrounding), teardown terminates SUT, pid-scoped SUT ops, SIGTERM/SIGINT session teardown, honest capture errors | ccc9cee, e6b9b33, 1dd2fae, 0f314a2 |
| Structured observation: `structuredContent` + `outputSchema` on `observe_ui`/`act_ui` (marks with rects, web `page_text`) | 7d42b6c — full brief: `documents/mcp-structured-observation.md` |
| Run a User Test Scarf mini-app + project dashboard | a6d329d, e78bd83, c98ebb5, 06b4eb4 |
| Wiki pipeline retirement (Memophant publishes `wiki/`), 0.7 landing-page copy | 5ce3dc9, 582ac94, 77ed019 |

Version: `MCPServerIdentity.version` is already **0.8.0** (`harness-mcp --version` prints it); `project.yml` still says 0.7.0 — `release.sh` bumps it (→ 0.8.0, `CURRENT_PROJECT_VERSION` 6 → 7). **Do not bump by hand.**

Test evidence at head: 326 tests / 62 suites green; live `ui-session-smoke` passes with the new structured assertions.

## Pre-flight (state as prepared)

- [x] `releases/v0.8.0/RELEASE_NOTES.md` written and **committed** (201a4b3).
- [x] `.scarf/project.json` gitignored (machine-local host bindings — never commit).
- [x] `wiki/HarnessMCP.md` section retitled "_New in the next release_" → "_New in 0.8.0_".
- [ ] **Alan: commit the managed tiers via Memophant** — `wiki/HarnessMCP.md` (modified) and `documents/` (this runbook + the structured-observation brief) are dirty, and `release.sh` refuses any dirt beyond the release-notes file itself.
- [ ] `gh auth status` OK; Developer ID cert in login Keychain; `harness-notary` notarytool profile present (`xcrun notarytool history --keychain-profile harness-notary`); Sparkle EdDSA private key in Keychain. (See memory note `core/release-signing-notarization-sparkle-keys`.)

## Cut

On `main`, clean tree:

```
./scripts/release.sh 0.8.0
```

Does everything: bumps versions, archives (Release, universal), Developer ID signs, notarizes + staples, zips, tags `main` + pushes, creates the GitHub release with `releases/v0.8.0/RELEASE_NOTES.md` as the body, then `scripts/appcast.sh` signs the zip and publishes the Sparkle appcast to `gh-pages`. Use `--draft` to hold the GitHub release and skip tagging.

Note: the live run **pushes the tag and gh-pages** — run it only when ready to publish.

## Post-cut verification

1. GitHub release `v0.8.0` shows the notes and `Harness-v0.8.0-Universal.zip`.
2. `https://awizemann.github.io/harness/appcast.xml` lists 0.8.0 with an EdDSA signature.
3. A 0.7.0 install offers the Sparkle update and launches after updating.
4. Unzipped app: `spctl -a -vv Harness.app` → accepted, notarized.
5. Bundled `harness-mcp --version` → `harness-mcp 0.8.0` (matches the `initialize` handshake).

## Rollback

`--draft` releases: just delete the draft. A published bad release: delete the GitHub release + tag, revert the appcast commit on `gh-pages` (0.7.0 entry becomes latest again), then re-cut as 0.8.1 — never reuse a version Sparkle has served.
