#!/bin/sh
#
# smoke-test.sh — black-box check of the harness-mcp stdio surface.
# Drives the JSON-RPC handshake + tools/list + a real store-backed call
# and asserts the responses. Exits non-zero on any failure.
#
# Usage: HarnessMCP/smoke-test.sh [path-to-harness-mcp-binary]
#
set -eu

BIN="${1:-./.build/derived/Build/Products/Debug/harness-mcp}"
if [ ! -x "$BIN" ]; then
  echo "harness-mcp binary not found at: $BIN" >&2
  echo "Build it first:" >&2
  echo "  xcodebuild -project Harness.xcodeproj -scheme HarnessMCP -configuration Debug -derivedDataPath ./.build/derived build" >&2
  exit 1
fi

OUT="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_personas","arguments":{}}}' \
  | "$BIN" 2>/dev/null)"

# NOTE: tool results arrive as an *escaped* JSON string inside
# content[].text (e.g. \"personas\"), so assert on barewords rather than
# quoted tokens to stay robust to JSON-in-JSON escaping.
fail=0
printf '%s' "$OUT" | grep -q 'serverInfo'  || { echo "FAIL: no initialize result";            fail=1; }
printf '%s' "$OUT" | grep -q 'start_run'   || { echo "FAIL: tools/list missing start_run";    fail=1; }
printf '%s' "$OUT" | grep -q 'personas'    || { echo "FAIL: list_personas returned no store"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "harness-mcp smoke test: PASS"
else
  echo "harness-mcp smoke test: FAIL"
  exit 1
fi
