---
title: Release Signing, Notarization & Sparkle Keys
type: note
permalink: harness/core/release-signing-notarization-sparkle-keys
---

## Observations
- [pipeline] `scripts/release.sh <version> [--draft]` is the release path: bump MARKETING_VERSION + CURRENT_PROJECT_VERSION → archive (Release, universal) → Developer ID sign → notarize → staple → zip → (live) tag `main` + push + `gh release` → `scripts/appcast.sh` publishes the Sparkle appcast. Must run on `main` with a clean tree; needs `releases/v<version>/RELEASE_NOTES.md`. #release
- [signing] Code-signing identity: "Developer ID Application", Apple Team **3Q6X2L86C4**, in the login Keychain. `ENABLE_HARDENED_RUNTIME: YES`; entitlements `Harness/Resources/Harness.entitlements` (app-sandbox=false). #signing
- [notary] notarytool uses a Keychain **profile** referenced by `--keychain-profile`. release.sh defaults to `harness-notary` (override with `HARNESS_NOTARY_PROFILE=<name>`). Dedicated to Harness (not shared with other apps, per Alan). Created once via an App Store Connect API key:
  `xcrun notarytool store-credentials "harness-notary" --key AuthKey_<KEYID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>`
  The `AuthKey_*.p8` is a ONE-TIME download from App Store Connect → Users and Access → Integrations → App Store Connect API (Developer role). Verify: `xcrun notarytool history --keychain-profile "harness-notary"`. #notary #gotcha
- [sparkle-key] Sparkle signs updates with an **EdDSA (ed25519)** key. PUBLIC key `sxHR0OGLmx9I4Fyx1GdPANR9WUiVAz/rI38x3cLYnMU=` lives in `Harness/Resources/Info.plist` (SUPublicEDKey) + the `sparkle-public-key` Memophant vendor record. PRIVATE key is in the login Keychain, **shared across this machine's Sparkle apps** — losing it breaks updates for ALL of them. Back up: `generate_keys -x <file>`; restore: `generate_keys -f <file>`. The Sparkle tools live at `.build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/` after a build. #sparkle #gotcha
- [appcast] `scripts/appcast.sh <version>` runs `generate_appcast` (signs the zip with the Keychain EdDSA key) and publishes `appcast.xml` to the `gh-pages` branch → served at the app's SUFeedURL `https://awizemann.github.io/harness/appcast.xml`. Disjoint from `scripts/site.sh`'s OWNED_ROOT_FILES so the two publishers never collide. #appcast
- [recovery] To cut a release on a fresh machine you need: the Developer ID Application cert, the `harness-notary` notarytool profile (re-create from the backed-up .p8 + key-id + issuer), and the Sparkle EdDSA private key (re-import the backup). All three are independent; back each up.

## Relations
- relates_to [[HarnessMCP: Stdio MCP Server to Drive Harness from Agents]]
- relates_to [[HarnessCLI: Development-Time Driver — Shared Source, Same Artifacts]]
