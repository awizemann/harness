#!/usr/bin/env bash
#
# build-fixture.sh — build the macOS AX fixture app.
#
# Produces `build/HarnessMacFixture.app` beside this script: a minimal
# SwiftUI app whose accessibility surface reproduces the shapes the macOS
# mark probe has to handle (unlabelled SwiftUI TextFields, a menu, a sheet,
# body text). `MacAXLiveProbeTests` drives it; the suite SKIPS when the app
# isn't built, so this is opt-in and no CI runner is forced to have it.
#
# No Xcode project on purpose — one swiftc invocation plus a hand-written
# bundle is faster to build, has nothing to keep in sync, and can't drift
# from the source the way a checked-in .pbxproj can.
#
# Usage:  ./build-fixture.sh          # build (idempotent)
#         ./build-fixture.sh --clean  # rebuild from scratch
#
# Then:   HARNESS_MACOS_FIXTURE_APP=<path>/build/HarnessMacFixture.app \
#           xcodebuild ... test -only-testing:HarnessTests/MacAXLiveProbeTests
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/HarnessMacFixture.app"

if [ "${1:-}" = "--clean" ]; then rm -rf "$BUILD"; fi

mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HarnessMacFixture</string>
    <key>CFBundleIdentifier</key><string>com.harness.macfixture</string>
    <key>CFBundleName</key><string>HarnessMacFixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xcrun swiftc \
    -target "$(uname -m)-apple-macosx14.0" \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -o "$APP/Contents/MacOS/HarnessMacFixture" \
    "$HERE/Sources/FixtureApp.swift"

# Ad-hoc signature so the app launches (and keeps a stable identity for TCC).
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
