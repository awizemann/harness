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
  * **Credentials (WB-14)** — stage a credential, list it back (never the
    password), and drive `fill_credential` in a session: the staged username
    and password must actually land in the focused fields (proved via the
    fixture's echo + a password checksum, never by printing the secret), a
    session with NO credential must ERROR rather than log a silent "ok", and
    no password material may appear in any response, artifact, or log.
  * **Undeclared modals (W31)** — a confirm dialog with no dialog semantics
    must filter the page behind it out of BOTH the marks and `page_text`.
  * **frame_url (WB-17)** — every web observation reports the frame's
    location, redacted to scheme/host/port/path; a token in the query string
    reaches no result, no text block and no artifact.
  * **scroll_into_view (WB-17)** — a control below the fold is unmarked;
    scrolling a partially-visible mark into view makes it an ordinary mark
    in the same call's auto-observe.
  * **delete_credential (WB-17)** — removes the store row AND the Keychain
    item, and errors on an id that names nothing.
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
import uuid
import time
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(HERE, "fixtures")
FIXTURE_NAME = "ui-session-fixture.html"
SETTLE_FIXTURE_NAME = "spa-settle-fixture.html"
SCROLL_FIXTURE_NAME = "scroll-into-view-fixture.html"
SET_VALUE_FIXTURE_NAME = "set-value-fixture.html"
CONFIRM_FIXTURE_NAME = "confirm-dialog-fixture.html"
DEFAULT_BIN = os.path.join(HERE, "..", ".build", "derived", "Build", "Products", "Debug", "harness-mcp")


def pw_checksum(s):
    """Mirror of the fixture's JS checksum — lets the smoke prove the exact
    password was typed without ever printing it."""
    n = 0
    for ch in s:
        n = (n * 31 + ord(ch)) % 9973
    return n


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
    def __init__(self, binary, env=None):
        self.proc = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,   # protocol channel is stdout only
            bufsize=0,
            env=env,
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

    signal.alarm(360)   # hard wall-clock guard so a wedge never hangs CI

    port = free_port()
    httpd = serve(fixture_dir, port)
    url = "http://127.0.0.1:%d/%s" % (port, FIXTURE_NAME)
    artifact_dir = tempfile.mkdtemp(prefix="harness-ui-smoke-")

    # The credential leg stages a REAL credential (a store row + a Keychain
    # item), so point the server at a throwaway store: the user's Harness
    # library must not gain an Application they never made. The Keychain item
    # is deleted in `finally`.
    store_dir = tempfile.mkdtemp(prefix="harness-ui-smoke-store-")
    env = dict(os.environ)
    env["HARNESS_MCP_STORE_PATH"] = os.path.join(store_dir, "history.store")

    mcp = MCP(binary, env=env)
    failures = []
    keychain_accounts = []

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

        # WB-14 — the credential surface a client codes against.
        check("list_credentials" in names, "tools/list advertises list_credentials")
        check("delete_credential" in names, "tools/list advertises delete_credential (WB-17)")
        start_props = by_name["start_ui_session"]["inputSchema"]["properties"]
        check("credential_id" in start_props, "start_ui_session accepts credential_id")
        act_props = by_name["act_ui"]["inputSchema"]["properties"]
        check("field" in act_props, "act_ui accepts a `field` argument")
        check(act_props.get("field", {}).get("enum") == ["username", "password"],
              "act_ui's field is enumerated username|password")
        act_desc = by_name["act_ui"]["description"]
        check("fill_credential" in act_desc.split("web:")[1].split(";")[0],
              "act_ui's description no longer claims fill_credential is macOS-only")
        check("scroll_into_view" in act_desc.split("web:")[1].split(";")[0],
              "act_ui advertises scroll_into_view on web")
        check("set_value" in act_desc.split("web:")[1].split(";")[0],
              "act_ui advertises set_value on web")
        check("value" in act_props, "act_ui accepts a `value` argument (set_value)")
        obs_schema_props = by_name["observe_ui"]["outputSchema"]["properties"]
        check("frame_url" in obs_schema_props, "observe_ui's outputSchema describes frame_url")
        check("frame_url" not in by_name["observe_ui"]["outputSchema"].get("required", []),
              "frame_url is optional — iOS and macOS have no frame URL")

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

        # ------------------------------------------------------------------
        # WB-17 W31 — a confirm dialog with NO dialog semantics. The page
        # behind it must contribute neither marks nor page_text: the mark
        # filter and the text roll-up now share one modal decision, so a
        # `text_visible` assertion can no longer pass on copy the dialog
        # covers.
        # ------------------------------------------------------------------
        print("\n--- undeclared confirm dialog: marks AND page_text scoped (W31) ---")
        confirm_url = "http://127.0.0.1:%d/%s" % (port, CONFIRM_FIXTURE_NAME)
        confirm_dir = tempfile.mkdtemp(prefix="harness-ui-confirm-")
        sc_sess = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": confirm_url, "artifact_dir": confirm_dir})))
        sid_confirm = sc_sess["session_id"]
        obs_c = mcp.tool("observe_ui", {"session_id": sid_confirm})
        txt_c = content_text(obs_c)
        sc_c = obs_c.get("structuredContent") or {}
        labels_c = [m.get("label") for m in sc_c.get("marks", [])]
        print("  marks: %s" % labels_c)
        check("Delete site" in labels_c and "Keep site" in labels_c,
              "the dialog's own controls are marked")
        check("Add Site" not in labels_c and "Refresh" not in labels_c,
              "the dimmed background contributes NO marks (%s)" % labels_c)
        page_text_c = sc_c.get("page_text") or ""
        check("DIALOG-COPY-THE-USER-ACTUALLY-SEES" in page_text_c,
              "page_text carries the dialog's own copy")
        check("BACKGROUND-COPY-NOBODY-CAN-READ" not in page_text_c,
              "page_text does NOT carry copy hidden behind the dialog (W31a)")
        check("BACKGROUND-COPY-NOBODY-CAN-READ" not in txt_c,
              "…and neither does the text block")
        _ = mcp.tool("end_ui_session", {"session_id": sid_confirm})

        # ------------------------------------------------------------------
        # WB-17 — frame_url. Web observations report the frame's location,
        # redacted to scheme/host/port/path: the query and fragment are
        # DROPPED (they carry tokens) and only their existence is marked.
        # ------------------------------------------------------------------
        print("\n--- frame_url is reported and redacted ---")
        url_secret = "TOKEN-THAT-MUST-NEVER-BE-ECHOED-8812"
        tokened = "%s?token=%s#frag" % (url, url_secret)
        furl_dir = tempfile.mkdtemp(prefix="harness-ui-frameurl-")
        s_furl = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": tokened, "artifact_dir": furl_dir})))
        sid_furl = s_furl["session_id"]
        obs_f = mcp.tool("observe_ui", {"session_id": sid_furl})
        frame_url = (obs_f.get("structuredContent") or {}).get("frame_url")
        print("  frame_url: %r" % frame_url)
        check(frame_url == "http://127.0.0.1:%d/%s?…#…" % (port, FIXTURE_NAME),
              "frame_url is origin + path, with the query and fragment marked but dropped")
        check(url_secret not in json.dumps(obs_f),
              "the query-string token appears NOWHERE in the observation")
        furl_rows = open(os.path.join(furl_dir, "steps.jsonl")).read()
        check(url_secret not in furl_rows, "…and nowhere in steps.jsonl")
        check("URL: http://127.0.0.1" in content_text(obs_f),
              "the text block shows the frame URL too")
        _ = mcp.tool("end_ui_session", {"session_id": sid_furl})

        # ------------------------------------------------------------------
        # WB-17 W7/W34 — scroll_into_view. The mark table only covers what
        # intersects the viewport; this act is how an agent reaches what the
        # fold clipped. "Deep action" is below the fold and unmarked; after
        # scrolling the partially-visible "Load more" into view, the
        # auto-observe's re-probe must include it.
        # ------------------------------------------------------------------
        print("\n--- scroll_into_view reaches what the fold clipped ---")
        scroll_url = "http://127.0.0.1:%d/%s" % (port, SCROLL_FIXTURE_NAME)
        scroll_dir = tempfile.mkdtemp(prefix="harness-ui-scroll-")
        s_scroll = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": scroll_url, "artifact_dir": scroll_dir})))
        sid_scroll = s_scroll["session_id"]
        obs_s0 = mcp.tool("observe_ui", {"session_id": sid_scroll})
        labels0 = [m.get("label") for m in (obs_s0.get("structuredContent") or {}).get("marks", [])]
        print("  marks before: %s" % labels0)
        check("Load more" in labels0, "the partially-visible control is marked")
        check("Deep action" not in labels0,
              "a control below the fold is NOT marked (the viewport contract)")
        load_more_id = find_mark_id(content_text(obs_s0), "Load more")
        check(load_more_id is not None, "resolved 'Load more' to a mark id (%s)" % load_more_id)
        obs_s1 = mcp.tool("act_ui", {"session_id": sid_scroll,
                                     "tool": "scroll_into_view", "id": load_more_id})
        check(obs_s1.get("isError") is not True, "scroll_into_view executed")
        labels1 = [m.get("label") for m in (obs_s1.get("structuredContent") or {}).get("marks", [])]
        print("  marks after: %s" % labels1)
        check("Deep action" in labels1,
              "after scrolling, the previously-unreachable control is an ordinary mark (%s)" % labels1)
        check("scroll_into_view" in content_text(obs_s1),
              "the result reports what the scroll did")
        stale = mcp.tool("act_ui", {"session_id": sid_scroll, "tool": "scroll_into_view", "id": 999})
        check(stale.get("isError") is True, "an id that is not in the mark set is an ERROR")
        scroll_rows = open(os.path.join(scroll_dir, "steps.jsonl")).read()
        check('"scroll_into_view"' in scroll_rows, "the act is recorded in steps.jsonl")
        _ = mcp.tool("end_ui_session", {"session_id": sid_scroll})

        # ------------------------------------------------------------------
        # WB-27 — set_value lands a controlled datetime-local & a select
        # where a synthetic-keystroke `type` cannot, and `type` now flags its
        # own no-op instead of reporting a clean success. #checkin wears a
        # React-style value tracker that reverts a naive assignment; only the
        # native-setter path set_value uses commits, and #state proves it
        # persisted. #coupon ignores keystrokes, so `type` must warn.
        # ------------------------------------------------------------------
        print("\n--- set_value fills a controlled datetime-local & a select (WB-27) ---")
        sv_url = "http://127.0.0.1:%d/%s" % (port, SET_VALUE_FIXTURE_NAME)
        sv_dir = tempfile.mkdtemp(prefix="harness-ui-setvalue-")
        s_sv = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": sv_url, "artifact_dir": sv_dir})))
        sid_sv = s_sv["session_id"]
        obs_sv0 = mcp.tool("observe_ui", {"session_id": sid_sv})
        txt_sv0 = content_text(obs_sv0)
        checkin_id = find_mark_id(txt_sv0, "Check-in")
        room_id = find_mark_id(txt_sv0, "Room type")
        coupon_id = find_mark_id(txt_sv0, "Coupon")
        check(checkin_id is not None, "resolved the datetime-local's mark id (%s)" % checkin_id)
        check(room_id is not None, "resolved the select's mark id (%s)" % room_id)
        check(coupon_id is not None, "resolved the coupon field's mark id (%s)" % coupon_id)

        # set_value the datetime-local — the value must survive the controlled revert.
        act_ci = mcp.tool("act_ui", {"session_id": sid_sv, "tool": "set_value",
                                     "id": checkin_id, "value": "2026-09-10T15:00"})
        check(act_ci.get("isError") is not True, "set_value on the datetime-local executed")
        ci_page = (act_ci.get("structuredContent", {}) or {}).get("page_text") or ""
        check("check-in: 2026-09-10T15:00" in ci_page,
              "the datetime value PERSISTED through the controlled onChange (state shows it)")
        check("holds the value" in content_text(act_ci),
              "the act result confirms the value stuck")

        # set_value the select by its visible label.
        act_rm = mcp.tool("act_ui", {"session_id": sid_sv, "tool": "set_value",
                                     "id": room_id, "value": "Suite"})
        rm_page = (act_rm.get("structuredContent", {}) or {}).get("page_text") or ""
        check("room: ste" in rm_page,
              "set_value matched the select option by its visible label ('Suite' → 'ste')")

        # type on the keystroke-ignoring field must WARN, not lie.
        _ = mcp.tool("act_ui", {"session_id": sid_sv, "tool": "tap_mark", "id": coupon_id})
        act_cp = mcp.tool("act_ui", {"session_id": sid_sv, "tool": "type", "text": "SAVE20"})
        check("did not change" in content_text(act_cp),
              "type on a field that ignores keystrokes reports the no-op instead of a clean success")

        sv_rows = open(os.path.join(sv_dir, "steps.jsonl")).read()
        check('"set_value"' in sv_rows, "set_value is recorded in steps.jsonl")
        check('"value": "2026-09-10T15:00"' in sv_rows or '"value":"2026-09-10T15:00"' in sv_rows,
              "the set value is logged (model-authored, not a secret)")
        _ = mcp.tool("end_ui_session", {"session_id": sid_sv})

        # ------------------------------------------------------------------
        # WB-14 — fill_credential in a STEP-LEVEL SESSION. Stage a real
        # credential (store row + Keychain item), start a session bound to it,
        # and prove the staged values actually get typed — the username
        # verbatim, the password only via the fixture's length + checksum, so
        # the secret itself is never printed. Then prove the no-credential
        # case ERRORS instead of quietly logging "ok", and that the password
        # reaches no response, no artifact, and no log.
        # ------------------------------------------------------------------
        print("\n--- stage_credential + list_credentials ---")
        cred_user = "qa+smoke@harness.test"
        cred_password = "SMOKE-PASSWORD-VALUE-7734"
        app = json.loads(content_text(mcp.tool("create_application", {
            "name": "harness-ui-session-smoke", "platform": "web", "web_url": url})))
        app_id = app["created"]["id"]
        staged_raw = mcp.tool("stage_credential", {
            "application_id": app_id, "label": "smoke user",
            "username": cred_user, "password": cred_password})
        staged = json.loads(content_text(staged_raw))
        cred_id = staged["staged"]["credential_id"]
        keychain_accounts.append("%s:%s" % (app_id.upper(), cred_id.upper()))
        check(cred_password not in json.dumps(staged_raw),
              "stage_credential never echoes the password back")

        listed_creds_raw = mcp.tool("list_credentials", {"application_id": app_id})
        listed_creds = json.loads(content_text(listed_creds_raw))
        print(json.dumps(listed_creds, indent=2))
        check(listed_creds.get("count") == 1, "list_credentials returns the staged credential")
        row = listed_creds["credentials"][0]
        check(row.get("credential_id") == cred_id, "list_credentials reports the credential_id")
        check(row.get("label") == "smoke user" and row.get("username") == cred_user,
              "list_credentials reports label + username")
        check("password" not in json.dumps(listed_creds).lower(),
              "list_credentials NEVER returns password material")
        check(cred_password not in json.dumps(listed_creds_raw),
              "the staged password appears nowhere in list_credentials")

        # A credential_id that names nothing must fail AT START.
        bogus = mcp.tool("start_ui_session", {
            "platform": "web", "url": url, "credential_id": str(uuid.uuid4())})
        check(bogus.get("isError") is True, "an unknown credential_id is rejected at start")
        check("No staged credential" in content_text(bogus),
              "…with a message naming the fix (got %r)" % content_text(bogus)[:120])

        print("\n--- fill_credential WITHOUT a staged credential (must ERROR) ---")
        nocred_dir = tempfile.mkdtemp(prefix="harness-ui-nocred-")
        s5 = json.loads(content_text(mcp.tool("start_ui_session", {
            "platform": "web", "url": url, "artifact_dir": nocred_dir})))
        sid5 = s5["session_id"]
        obs5 = mcp.tool("observe_ui", {"session_id": sid5})
        pw_mark = find_mark_id(content_text(obs5), "password field")
        check(pw_mark is not None, "resolved the password field's mark id (%s)" % pw_mark)
        _ = mcp.tool("act_ui", {"session_id": sid5, "tool": "tap_mark", "id": pw_mark})
        nocred = mcp.tool("act_ui", {"session_id": sid5, "tool": "fill_credential",
                                     "field": "password"})
        nocred_text = content_text(nocred)
        check(nocred.get("isError") is True,
              "fill_credential with no staged credential is an ERROR, not a silent no-op")
        check("no credential is staged" in nocred_text,
              "…and says why (got %r)" % nocred_text[:160])
        nocred_rows = open(os.path.join(nocred_dir, "steps.jsonl")).read()
        check('"result":"ok"' not in nocred_rows,
              "the failed fill is NOT logged as an ok step")
        _ = mcp.tool("end_ui_session", {"session_id": sid5})

        print("\n--- fill_credential WITH a staged credential ---")
        cred_dir = tempfile.mkdtemp(prefix="harness-ui-cred-")
        start_raw = mcp.tool("start_ui_session", {
            "platform": "web", "url": url, "artifact_dir": cred_dir,
            "credential_id": cred_id})
        s6 = json.loads(content_text(start_raw))
        sid6 = s6["session_id"]
        print(json.dumps(s6, indent=2))
        check(bool(sid6), "started a session bound to the staged credential")
        check((s6.get("credential") or {}).get("label") == "smoke user",
              "start echoes the credential's label")
        check(cred_password not in json.dumps(start_raw),
              "start_ui_session never echoes the password")

        obs6 = mcp.tool("observe_ui", {"session_id": sid6})
        txt6 = content_text(obs6)
        user_mark = find_mark_id(txt6, "username field")
        pw_mark = find_mark_id(txt6, "password field")
        check(user_mark is not None and pw_mark is not None,
              "resolved both login field marks (%s / %s)" % (user_mark, pw_mark))

        _ = mcp.tool("act_ui", {"session_id": sid6, "tool": "tap_mark", "id": user_mark})
        fill_user = mcp.tool("act_ui", {"session_id": sid6, "tool": "fill_credential",
                                        "field": "username"})
        check(fill_user.get("isError") is not True, "fill_credential(username) succeeded")
        page = (fill_user.get("structuredContent", {}) or {}).get("page_text") or ""
        check("user: %s" % cred_user in page,
              "the STAGED username was actually typed into the focused field")

        _ = mcp.tool("act_ui", {"session_id": sid6, "tool": "tap_mark", "id": pw_mark})
        fill_pw = mcp.tool("act_ui", {"session_id": sid6, "tool": "fill_credential",
                                      "field": "password"})
        check(fill_pw.get("isError") is not True, "fill_credential(password) succeeded")
        page = (fill_pw.get("structuredContent", {}) or {}).get("page_text") or ""
        expected = "pw-len: %d · pw-sum: %d" % (len(cred_password), pw_checksum(cred_password))
        print("  login status expects: %r" % expected)
        check(expected in page,
              "the STAGED password was typed EXACTLY (length + checksum match; got %r)"
              % page[-80:])

        # An UNLABELLED password field: the probe's last-resort label is the
        # field's own value, and `el.value` on a password input is PLAINTEXT.
        # Fill that field and prove the mark names the SLOT, not the secret.
        bare_id = None
        for m in (fill_pw.get("structuredContent", {}) or {}).get("marks", []):
            if m.get("label_source") == "secure-field":
                bare_id = m.get("id")
        check(bare_id is not None, "an unlabelled password field is named from its type")
        if bare_id is not None:
            _ = mcp.tool("act_ui", {"session_id": sid6, "tool": "tap_mark", "id": bare_id})
            bare_fill = mcp.tool("act_ui", {"session_id": sid6, "tool": "fill_credential",
                                            "field": "password"})
            secure = [m for m in (bare_fill.get("structuredContent", {}) or {}).get("marks", [])
                      if m.get("label_source") == "secure-field"]
            check(bool(secure) and all(m.get("label") == "Password" for m in secure),
                  "a FILLED unlabelled password field is still labelled \"Password\"")
            check(cred_password not in json.dumps(bare_fill),
                  "the filled password NEVER reaches the mark table / structuredContent")

        # The whole point: none of that may leak anywhere.
        check(cred_password not in json.dumps(fill_pw) and cred_password not in json.dumps(fill_user),
              "NO password material in any act_ui response")
        leaked = []
        for root_dir, _dirs, files in os.walk(cred_dir):
            for f in files:
                path = os.path.join(root_dir, f)
                with open(path, "rb") as fh:
                    if cred_password.encode() in fh.read():
                        leaked.append(path)
        check(not leaked, "NO password material in ANY artifact file (%s)" % leaked)
        rows = open(os.path.join(cred_dir, "steps.jsonl")).read()
        check(cred_password not in rows, "NO password material in steps.jsonl")
        check('"field":"password"' in rows and '"field":"username"' in rows,
              "steps.jsonl records only the credential SLOT")
        _ = mcp.tool("end_ui_session", {"session_id": sid6})

        # ------------------------------------------------------------------
        # WB-17 — delete_credential. Staging writes a real Keychain item;
        # without a way to remove it, every automated run leaves one behind.
        # This must take BOTH halves: the store row and the Keychain item.
        # ------------------------------------------------------------------
        print("\n--- delete_credential removes the row AND the Keychain item ---")
        deleted_raw = mcp.tool("delete_credential", {"credential_id": cred_id})
        deleted = json.loads(content_text(deleted_raw))
        print(json.dumps(deleted, indent=2))
        check(deleted.get("deleted", {}).get("credential_id") == cred_id,
              "delete_credential reports the credential it removed")
        check(deleted.get("deleted", {}).get("keychain_item_removed") is True,
              "…and confirms the Keychain item is gone")
        check(cred_password not in json.dumps(deleted_raw),
              "delete_credential never echoes password material")
        after_delete = json.loads(content_text(
            mcp.tool("list_credentials", {"application_id": app_id})))
        check(after_delete.get("count") == 0, "the credential row is gone from the store")
        account = "%s:%s" % (app_id.upper(), cred_id.upper())
        found = subprocess.run(["security", "find-generic-password",
                                "-s", "com.harness.credentials", "-a", account],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        check(found.returncode != 0,
              "the Keychain item is ACTUALLY gone (no inert leftover per run)")
        again = mcp.tool("delete_credential", {"credential_id": cred_id})
        check(again.get("isError") is True,
              "deleting an id that names no credential is an ERROR, not a quiet success")
        # Already removed above; the finally-block sweep becomes a no-op.
        keychain_accounts.remove(account)

    finally:
        mcp.close()
        httpd.shutdown()
        # The staged password is a real Keychain item — take it back out.
        for account in keychain_accounts:
            subprocess.run(["security", "delete-generic-password",
                            "-s", "com.harness.credentials", "-a", account],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("\n================ %s ================" %
          ("ui-session smoke: PASS" if not failures else "ui-session smoke: FAIL"))
    if failures:
        for f in failures:
            print("  - " + f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
