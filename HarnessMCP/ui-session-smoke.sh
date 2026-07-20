#!/bin/sh
#
# ui-session-smoke.sh — LIVE end-to-end smoke for the step-level UI session
# tools (start_ui_session / observe_ui / act_ui / end_ui_session /
# list_ui_sessions). Serves a local HTML fixture and drives a REAL WKWebView
# session over the stdio MCP surface. No API key required.
#
# Usage: HarnessMCP/ui-session-smoke.sh [path-to-harness-mcp-binary] [absolute-fixture-dir]
#
# The optional second argument is an ABSOLUTE fixture directory (holding
# ui-session-fixture.html); it defaults to the sibling fixtures/. Pass it to
# drive a RELOCATED binary against an out-of-repo fixture (standalone proof).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HERE/../.build/derived/Build/Products/Debug/harness-mcp}"

if [ ! -x "$BIN" ]; then
  echo "harness-mcp binary not found at: $BIN" >&2
  echo "Build it first:" >&2
  echo "  xcodebuild -project Harness.xcodeproj -scheme HarnessMCP -configuration Debug -derivedDataPath ./.build/derived build" >&2
  exit 1
fi

exec /usr/bin/env python3 "$HERE/ui-session-smoke.py" "$BIN" ${2:+"$2"}
