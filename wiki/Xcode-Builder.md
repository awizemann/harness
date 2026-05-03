# Xcode Builder

Wraps `xcodebuild`. The build wrapper is small — a hundred lines or so — but the `xcodebuild` flag set is fiddly enough to deserve its own page.

Status: scaffold. Filled out as `Harness/Services/XcodeBuilder.swift` lands in Phase 1.

## Invocation shape (planned)

```bash
xcodebuild build \
  -project <user-project>.xcodeproj \
  -scheme <user-scheme> \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath <run-dir>/build/DerivedData-<run-id> \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=YES
```

Why each flag:

- `-destination 'generic/platform=iOS Simulator'` — build a universal simulator slice; we don't need to pre-pick a specific simulator at build time.
- `-derivedDataPath` — isolates per-run intermediate artifacts under the run dir. No cross-run cache pollution.
- `CODE_SIGNING_ALLOWED=NO` + `CODE_SIGN_IDENTITY=""` — simulator builds don't need signing; this avoids tripping on the user's project's expected signing identity (which they may not have configured).
- `ONLY_ACTIVE_ARCH=YES` — faster builds; we only need the architecture matching the host Mac (arm64 on Apple Silicon).

## Build artifact pickup

After a successful build, the `.app` lives at:

```
<derivedDataPath>/Build/Products/Debug-iphonesimulator/<TargetName>.app
```

The wrapper resolves the target name from the scheme's xcscheme (parsing `BlueprintIdentifier` → target). Failure to find the artifact at the expected path is `BuildFailure.artifactNotFound(searched: URL)`. We never `find` derived data.

## Bundle ID extraction

After resolving the `.app`, parse `<bundle>/Info.plist` for `CFBundleIdentifier`. The user does not supply a bundle ID manually — we read it from the build output.

## Error surface

| Condition | Error |
|---|---|
| Project file not found | `BuildFailure.projectNotFound(URL)` |
| Scheme name unknown | `BuildFailure.schemeNotFound(name)` |
| Build failed (non-zero exit) | `BuildFailure.compileFailed(exitCode, lastStderrSnippet, fullLogPath)` |
| Build succeeded but artifact path missing | `BuildFailure.artifactNotFound(searched: URL)` |
| Code signing required by project (configurable to fix) | `BuildFailure.signingRequired(detail)` — surfaces the override hint to the user |

The full `xcodebuild` log is streamed to disk under `<run-dir>/build/build.log` for diagnostic copy-paste. The `lastStderrSnippet` field on `compileFailed` carries the last 4 KB.

## Cross-references

- [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md) — `ProcessRunner` ownership rules.
- [Simulator-Driver](Simulator-Driver.md) — the downstream consumer of the `.app` bundle.
- [Build-and-Run](Build-and-Run.md) — instructions for running Harness against a local sample app.

---

_Last updated: 2026-05-03 — initial scaffolding._
