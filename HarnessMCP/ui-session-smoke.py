#!/usr/bin/env python3
"""
ui-session-smoke.py — LIVE end-to-end smoke for the step-level UI session
tools (`start_ui_session` / `observe_ui` / `act_ui` / `end_ui_session` /
`list_ui_sessions`) over the real stdio MCP surface.

Serves a local HTML fixture (button + text input + visible state change),
launches `harness-mcp`, and drives a REAL WKWebView session:

    start → observe → act tap_mark(input) → act type("hello") → observe
          → list_ui_sessions → end_ui_session

Asserts image content + marks are present on observe, that `structuredContent`
carries the same marks with real point-space rects plus the page's visible
text, that the typed text surfaces in BOTH the mark table and the structured
marks after the action (the state change), and that NO marked frame ever lands
on disk (the CLEAN-only invariant, standard 14 §6).

It then drives three more live proofs:

  * **Label priority (W1)** — a field with `<label for>` AND a placeholder
    must surface the LABEL text, with `label_source: "label"`; no mark may be
    labelled with the placeholder's sample data.
  * **Interactability + naming (W14/W15)** — a button inside an `[inert]`
    subtree must NOT be marked, no mark may carry an empty label, and an
    icon-only close button must surface as "Close" (`label_source: "glyph"`).
  * **Settle on a same-URL async swap (W3)** — `spa-settle-fixture.html`
    swaps its view 500ms after the click with no route change. The act's own
    auto-observe must already show the post-swap DOM.
  * **Session state** — inject a cookie + a localStorage item, export them
    back out, confirm neither value reaches `steps.jsonl`, and confirm a
    session started WITHOUT `session_state` inherits nothing.

Exits non-zero on any failure. No API key required.

Usage: ui-session-smoke.py [path-to-harness-mcp-binary] [absolute-fixture-dir]

The optional second argument is an ABSOLUTE path to the directory holding
`ui-session-fixture.html`. It defaults to this script's sibling `fixtures/`.
Passing it lets the standalone-packaging proof point a RELOCATED binary
(copied outside the checkout, run from a non-repo cwd) at a fixture that is
likewise outside the repo — proving the binary carries no repo assumptions.
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
SETTLE_FIXTURE_NAME = "spa-settle-fixture.html"
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


def structured_mark(result, label):
    """The structuredContent mark whose label contains `label`, or None."""
    for m in result.get("structuredContent", {}).get("marks", []):
        if label in m.get("label", ""):
            return m
    return None


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
    if "structuredContent" in result:
        sc = dict(result["structuredContent"])
        if isinstance(sc.get("page_text"), str):
            sc["page_text"] = sc["page_text"][:120] + ("…" if len(sc["page_text"]) > 120 else "")
        out["structuredContent"] = sc
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

    fixture_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else FIXTURE_DIR
    if not os.path.isfile(os.path.join(fixture_dir, FIXTURE_NAME)):
        print("fixture %s not found under: %s" % (FIXTURE_NAME, fixture_dir), file=sys.stderr)
        return 1

    print("binary : %s" % binary)
    print("fixture: %s" % os.path.join(fixture_dir, FIXTURE_NAME))
    print("cwd    : %s" % os.getcwd())

    signal.alarm(240)   # hard wall-clock guard so a wedge never hangs CI

    port = free_port()
    httpd = serve(fixture_dir, port)
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
        for t in ["start_ui_session", "observe_ui", "act_ui", "end_ui_session",
                  "list_ui_sessions", "export_ui_session_state"]:
            check(t in names, "tools/list advertises %s" % t)
        by_name = {t["name"]: t for t in tools}
        for t in ["observe_ui", "act_ui"]:
            schema = by_name[t].get("outputSchema")
            check(isinstance(schema, dict) and schema.get("type") == "object",
                  "%s declares an outputSchema" % t)
            req = (schema or {}).get("required", [])
            check(set(["session_id", "step", "point_size", "marks"]).issubset(set(req)),
                  "%s outputSchema requires session_id/step/point_size/marks" % t)
        check("outputSchema" not in by_name["list_ui_sessions"],
              "tools with no structuredContent declare no outputSchema")

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

        sc1 = obs1.get("structuredContent")
        check(isinstance(sc1, dict), "observe returned structuredContent")
        check(sc1.get("session_id") == session_id, "structuredContent.session_id matches")
        check(sc1.get("step") == 1, "structuredContent.step is the 1st observation")
        ps = sc1.get("point_size") or {}
        check(ps.get("width") == 1280 and ps.get("height") == 800,
              "structuredContent.point_size is the desktop viewport (%s)" % ps)
        sm = structured_mark(obs1, "name field")
        check(sm is not None, "structuredContent has a mark for the input")
        if sm:
            r = sm.get("rect") or {}
            print("  input mark: %s" % json.dumps(sm))
            check(all(k in r for k in ("x", "y", "width", "height")), "mark rect has all four fields")
            check(r.get("width", 0) > 0 and r.get("height", 0) > 0, "mark rect has real dimensions")
            # Rects live in point space, so they must fit the point_size box.
            check(0 <= r.get("x", -1) and r["x"] + r["width"] <= ps.get("width", 0) + 1,
                  "mark rect sits inside the viewport horizontally")
            check(0 <= r.get("y", -1) and r["y"] + r["height"] <= ps.get("height", 0) + 1,
                  "mark rect sits inside the viewport vertically")
            check(sm.get("id") == find_mark_id(txt1, "name field"),
                  "structured mark id agrees with the prose mark table")
        # W1 — label priority: a properly-labelled field must surface its
        # <label for> text, NOT its placeholder, and must say which it used.
        email = structured_mark(obs1, "Your Email")
        check(email is not None, "labelled field's mark carries the <label for> text")
        if email:
            check(email.get("label_source") == "label",
                  "label_source names the associated <label> (got %r)" % email.get("label_source"))
        placeholder_labelled = [m for m in (sc1.get("marks") or [])
                                if "john@example.com" in m.get("label", "")]
        check(not placeholder_labelled,
              "no mark is labelled with the placeholder's sample data")
        aria = structured_mark(obs1, "name field")
        if aria:
            check(aria.get("label_source") == "aria-label",
                  "an aria-labelled field reports label_source 'aria-label' (got %r)"
                  % aria.get("label_source"))
        button = structured_mark(obs1, "waiting")
        if button:
            check(button.get("label_source") == "text",
                  "a button labelled by its own text reports label_source 'text' (got %r)"
                  % button.get("label_source"))

        # W15 — no mark may carry an empty label, and an icon-only close
        # button must be named from its glyph rather than left anonymous.
        empty_labelled = [m for m in (sc1.get("marks") or [])
                          if not (m.get("label") or "").strip()]
        check(not empty_labelled,
              "no mark carries an empty label (got %d)" % len(empty_labelled))
        close = structured_mark(obs1, "Close")
        check(close is not None, "the icon-only close button is named 'Close'")
        if close:
            check(close.get("label_source") == "glyph",
                  "the close glyph reports label_source 'glyph' (got %r)"
                  % close.get("label_source"))
        # W14 — an inert subtree is not actionable and must not be marked.
        check(structured_mark(obs1, "Inert Only") is None,
              "a button inside an [inert] subtree is filtered out of the mark table")
        check("Inert Only" not in txt1,
              "the prose mark table omits the inert button too")

        pt = sc1.get("page_text")
        check(isinstance(pt, str) and "Harness UI Session Smoke Fixture" in pt,
              "structuredContent.page_text carries the page's visible text")
        check("<button" not in (pt or "") and "<h1" not in (pt or ""),
              "page_text is visible text, not markup")

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
        check(structured_mark(act2, "typed: hello") is not None,
              "state change ALSO visible in structuredContent.marks")
        check("typed: hello" in (act2.get("structuredContent", {}).get("page_text") or ""),
              "state change ALSO visible in structuredContent.page_text")
        check((act2.get("structuredContent") or {}).get("step") == 3,
              "act's auto-observe advances structuredContent.step")

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

        # ------------------------------------------------------------------
        # W3 — SAME-URL async state swap. The button's handler returns
        # immediately and swaps the view 500ms later (no route change), the
        # shape that used to return the PRE-action frame at ~481ms. The act's
        # own auto-observe must already show the post-swap DOM.
        # ------------------------------------------------------------------
        print("\n--- act_ui on the async-swap fixture (W3 settle proof) ---")
        settle_dir = tempfile.mkdtemp(prefix="harness-ui-settle-")
        settle_url = "http://127.0.0.1:%d/%s" % (port, SETTLE_FIXTURE_NAME)
        s2 = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": settle_url, "artifact_dir": settle_dir})))
        sid2 = s2.get("session_id")
        check(bool(sid2), "started the settle-fixture session")
        obs_pre = mcp.tool("observe_ui", {"session_id": sid2})
        pre_text = (obs_pre.get("structuredContent", {}) or {}).get("page_text") or ""
        check("SWAP-COMPLETE" not in pre_text, "pre-action frame does NOT show the swap")
        go_id = find_mark_id(content_text(obs_pre), "Send Message")
        check(go_id is not None, "resolved the swap button's mark id (%s)" % go_id)

        t0 = time.time()
        act_swap = mcp.tool("act_ui", {"session_id": sid2, "tool": "tap_mark", "id": go_id})
        elapsed_ms = int((time.time() - t0) * 1000)
        swap_text = (act_swap.get("structuredContent", {}) or {}).get("page_text") or ""
        print("  act_ui round trip: %dms" % elapsed_ms)
        print("  post-act page_text: %r" % swap_text[:120])
        check("SWAP-COMPLETE" in swap_text,
              "act_ui's own frame shows the POST-swap state (settle waited for the 500ms swap)")
        check(elapsed_ms >= 500,
              "the settle actually waited for the pending timer (%dms)" % elapsed_ms)
        check(elapsed_ms < 8000, "…and did not stall near the ceiling (%dms)" % elapsed_ms)
        check(structured_mark(act_swap, "Send another") is not None,
              "the post-swap DOM's new button is in structuredContent.marks")
        _ = mcp.tool("end_ui_session", {"session_id": sid2})

        # ------------------------------------------------------------------
        # Session-state injection + export round trip. The injected cookie
        # value is a stand-in for a real auth cookie: it must come back out of
        # export_ui_session_state, and must NOT appear in steps.jsonl.
        # ------------------------------------------------------------------
        print("\n--- session_state injection + export_ui_session_state ---")
        state_dir = tempfile.mkdtemp(prefix="harness-ui-state-")
        secret = "SMOKE-COOKIE-VALUE-9137"
        storage_secret = "SMOKE-LOCALSTORAGE-VALUE-4471"
        origin = "http://127.0.0.1:%d" % port
        s3 = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": url, "artifact_dir": state_dir,
            "session_state": {
                "cookies": [{"name": "harness_smoke_sid", "value": secret,
                             "domain": "127.0.0.1", "path": "/"}],
                "origins": [{"origin": origin,
                             "localStorage": [{"name": "harness_smoke_token",
                                               "value": storage_secret}]}]
            }})))
        sid3 = s3.get("session_id")
        check(bool(sid3), "started a session WITH session_state")
        check(secret not in json.dumps(s3),
              "start_ui_session's own result never echoes a cookie value")

        exported = json.loads(content_text(mcp.tool("export_ui_session_state", {"session_id": sid3})))
        names = [c.get("name") for c in exported.get("cookies", [])]
        values = [c.get("value") for c in exported.get("cookies", [])]
        print("  exported cookies: %s" % names)
        check("harness_smoke_sid" in names, "the injected cookie survives into the live session")
        check(secret in values, "export returns the cookie's value (the tool's whole purpose)")
        check(exported.get("sensitive") is True, "export result is flagged sensitive")
        ls = []
        for o in exported.get("origins", []):
            ls += [i.get("value") for i in o.get("localStorage", [])]
        check(storage_secret in ls, "the injected localStorage item is exported back")

        state_jsonl = os.path.join(state_dir, "steps.jsonl")
        state_rows = open(state_jsonl).read() if os.path.isfile(state_jsonl) else ""
        check(secret not in state_rows and storage_secret not in state_rows,
              "NO injected secret ever reaches steps.jsonl")
        _ = mcp.tool("end_ui_session", {"session_id": sid3})

        # A fresh session with NO session_state must still be a fresh user.
        print("\n--- fresh-user invariant (no session_state) ---")
        fresh_dir = tempfile.mkdtemp(prefix="harness-ui-fresh-")
        s4 = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": url, "artifact_dir": fresh_dir})))
        fresh_export = json.loads(content_text(
            mcp.tool("export_ui_session_state", {"session_id": s4["session_id"]})))
        fresh_names = [c.get("name") for c in fresh_export.get("cookies", [])]
        check("harness_smoke_sid" not in fresh_names,
              "a session started without session_state inherits NOTHING (fresh-user invariant)")
        _ = mcp.tool("end_ui_session", {"session_id": s4["session_id"]})

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
