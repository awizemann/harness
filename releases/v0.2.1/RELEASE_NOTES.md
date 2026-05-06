# Harness 0.2.1 — First-run WebDriverAgent build works for everyone

A patch release that fixes the first issue filed against Harness on GitHub: **the first-run WebDriverAgent build pointed at `/Users/alanwizemann/...`** on every machine that wasn't mine. Thanks to [@impiri](https://github.com/impiri) for the report ([#1](https://github.com/awizemann/harness/issues/1)).

## Fix

`HarnessPaths.wdaSourceURL` was resolved from a `$SRCROOT` path baked into the binary at build time. That works on the developer's own Mac and nowhere else — for everyone who installed from the 0.2.0 release zip, the first-run wizard's "Build WebDriverAgent" button errored out with a path that didn't exist on their disk.

0.2.1 ships the WebDriverAgent submodule **inside the .app bundle** (`Contents/Resources/WebDriverAgent`) and resolves it from `Bundle.main.resourceURL` first, falling back to the `$SRCROOT` path only for dev-mode runs from Xcode. The bundled WDA snapshot SHA is baked at app build time so the on-disk build cache stays valid across launches without needing `git` to resolve a HEAD on the user's machine.

Net effect for users:

- First-run "Build WebDriverAgent" button works immediately after install.
- Cache hits on the second launch — first-build cost is paid once per Harness app version, not once per launch.
- No public API or contract changes; existing run records load unchanged.

## Compatibility

- macOS 14+
- Apple Silicon (universal)
- Notarized + signed with Developer ID
- Existing 0.2 run records, Applications, Personas, and Action chains load unchanged.
