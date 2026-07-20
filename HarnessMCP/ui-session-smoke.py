#!/usr/bin/env python3
"""
ui-session-smoke.py — LIVE end-to-end smoke for the step-level UI session
tools (`start_ui_session` / `observe_ui` / `act_ui` / `end_ui_session` /
`list_ui_sessions`) over the real stdio MCP surface.

Serves a local HTML fixture (button + text input + visible state change),
launches `harness-mcp`, and drives a REAL WKWebView session:

    start → observe → act tap_mark(input) → act type("hello") → observe
          → list_ui_sessions → end_ui_session

Asserts image content + marks are present on observe, that the typed text
surfaces in the mark table after the action (the state change), and that
NO marked frame ever lands on disk (the CLEAN-only invariant, standard
14 §6). Exits non-zero on any failure. No API key required.

Usage: ui-session-smoke.py [path-to-harness-mcp-binary]
"""

import base64
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(HERE, "fixtures")
FIXTURE_NAME = "ui-session-fixture.html"
DEFAULT_BIN = os.path.join(HERE, "..", ".build", "derived", "Build", "Products", "Debug", "harness-mcp")


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def serve(directory, port):
    handler = partial(SimpleHTTPRequestHandler, directory=directory)
    httpd = HTTPServer(("127.0.0.1", port), handler)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd


class MCP:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,   # protocol channel is stdout only
            bufsize=0,
        )
        self._id = 0

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def call(self, method, params=None):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("server closed stdout (no response to %s)" % method)
        return json.loads(line.decode())

    def tool(self, name, arguments):
        resp = self.call("tools/call", {"name": name, "arguments": arguments})
        if "error" in resp:
            raise RuntimeError("protocol error for %s: %s" % (name, resp["error"]))
        return resp["result"]

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def content_image(result):
    for c in result.get("content", []):
        if c.get("type") == "image":
            return c
    return None


def content_text(result):
    for c in result.get("content", []):
        if c.get("type") == "text":
            return c.get("text", "")
    return ""


def find_mark_id(mark_text, label):
    # Lines look like:  `  3 → "name field" (input)`
    for line in mark_text.splitlines():
        if '"%s"' % label in line:
            head = line.strip().split("→")[0].strip()   # before the → arrow
            if head.isdigit():
                return int(head)
    return None


def redact(result):
    """A copy with image bytes summarized, for readable evidence."""
    out = {"isError": result.get("isError", False), "content": []}
    for c in result.get("content", []):
        if c.get("type") == "image":
            out["content"].append({"type": "image", "mimeType": c.get("mimeType"),
                                    "data": "<%d base64 chars of PNG>" % len(c.get("data", ""))})
        else:
            out["content"].append(c)
    return out


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BIN
    binary = os.path.abspath(binary)
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        print("harness-mcp binary not found/executable at: %s" % binary, file=sys.stderr)
        print("Build it first: xcodebuild -project Harness.xcodeproj -scheme HarnessMCP "
              "-configuration Debug -derivedDataPath ./.build/derived build", file=sys.stderr)
        return 1

    signal.alarm(120)   # hard wall-clock guard so a wedge never hangs CI

    port = free_port()
    httpd = serve(FIXTURE_DIR, port)
    url = "http://127.0.0.1:%d/%s" % (port, FIXTURE_NAME)
    artifact_dir = tempfile.mkdtemp(prefix="harness-ui-smoke-")

    mcp = MCP(binary)
    failures = []

    def check(cond, msg):
        status = "ok  " if cond else "FAIL"
        print("  [%s] %s" % (status, msg))
        if not cond:
            failures.append(msg)

    try:
        init = mcp.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})
        mcp.notify("notifications/initialized")
        check("serverInfo" in init.get("result", {}), "initialize handshake")

        tools = mcp.call("tools/list")["result"]["tools"]
        names = {t["name"] for t in tools}
        for t in ["start_ui_session", "observe_ui", "act_ui", "end_ui_session", "list_ui_sessions"]:
            check(t in names, "tools/list advertises %s" % t)

        print("\n--- start_ui_session ---")
        start = mcp.tool("start_ui_session", {"platform": "web", "url": url, "artifact_dir": artifact_dir})
        start_json = json.loads(content_text(start))
        session_id = start_json.get("session_id")
        print(json.dumps(start_json, indent=2))
        check(bool(session_id), "start returned a session_id")
        check(start_json.get("platform") == "web", "platform is web")

        print("\n--- observe_ui (initial) ---")
        obs1 = mcp.tool("observe_ui", {"session_id": session_id})
        img1 = content_image(obs1)
        txt1 = content_text(obs1)
        check(img1 is not None and len(img1.get("data", "")) > 1000, "observe returned PNG image content")
        check("name field" in txt1, "mark table lists the input ('name field')")
        check("waiting" in txt1, "mark table lists the button ('waiting')")
        print(json.dumps(redact(obs1), indent=2)[:1400])
        # First few PNG bytes prove it's a real image.
        if img1:
            sig = base64.b64decode(img1["data"])[:8]
            check(sig[:4] == b"\x89PNG", "image bytes carry the PNG signature")

        input_id = find_mark_id(txt1, "name field")
        check(input_id is not None, "resolved the input's mark id (%s)" % input_id)

        print("\n--- act_ui tap_mark(%s) → focus input ---" % input_id)
        act1 = mcp.tool("act_ui", {"session_id": session_id, "tool": "tap_mark", "id": input_id})
        check(content_image(act1) is not None, "act tap_mark auto-observed with an image")

        print("\n--- act_ui type('hello') ---")
        act2 = mcp.tool("act_ui", {"session_id": session_id, "tool": "type", "text": "hello"})
        txt_act2 = content_text(act2)
        print(json.dumps(redact(act2), indent=2)[:1400])
        check("typed: hello" in txt_act2,
              "state change visible in the mark table after type ('typed: hello')")

        print("\n--- observe_ui (after action) ---")
        obs2 = mcp.tool("observe_ui", {"session_id": session_id})
        check("typed: hello" in content_text(obs2), "re-observe still shows 'typed: hello'")

        print("\n--- list_ui_sessions ---")
        listed = json.loads(content_text(mcp.tool("list_ui_sessions", {})))
        print(json.dumps(listed, indent=2))
        check(listed.get("count") == 1, "one open session listed")
        check(listed["sessions"][0]["session_id"] == session_id, "listed session id matches")

        print("\n--- end_ui_session ---")
        ended = json.loads(content_text(mcp.tool("end_ui_session", {"session_id": session_id})))
        print(json.dumps(ended, indent=2))
        check(ended.get("closed") is True, "session closed")
        # Idempotent: ending again is calm.
        ended2 = json.loads(content_text(mcp.tool("end_ui_session", {"session_id": session_id})))
        check(ended2.get("status") == "already closed", "end is idempotent ('already closed')")

        # Invariant: CLEAN frames on disk, marked frames NEVER.
        steps_dir = os.path.join(artifact_dir, "steps")
        pngs = sorted(f for f in os.listdir(steps_dir)) if os.path.isdir(steps_dir) else []
        marked = [f for f in pngs if "marked" in f]
        jsonl = os.path.join(artifact_dir, "steps.jsonl")
        rows = open(jsonl).read().strip().splitlines() if os.path.isfile(jsonl) else []
        print("\n--- artifacts at %s ---" % artifact_dir)
        print("  steps/:", pngs)
        print("  steps.jsonl rows:", len(rows))
        check(len(pngs) >= 3, "CLEAN step PNGs written (>=3)")
        check(len(marked) == 0, "NO marked frame on disk (standard 14 §6)")
        check(len(rows) >= 3, "steps.jsonl has a row per observation")

    finally:
        mcp.close()
        httpd.shutdown()

    print("\n================ %s ================" %
          ("ui-session smoke: PASS" if not failures else "ui-session smoke: FAIL"))
    if failures:
        for f in failures:
            print("  - " + f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
