#!/usr/bin/env python3
"""
macos-session-smoke.py — LIVE end-to-end smoke for a **macOS** UI session over
the real stdio MCP surface, driving a real SwiftUI app.

`ui-session-smoke.py` covers the web surface. This one covers what only a
native AX session can prove, and what the Scarf shakedown found missing
(WB-17 Phase A):

  * **Labels from adjacent text (W19)** — the fixture's `Host` / `Port` /
    `Identity file` rows are plain SwiftUI `TextField`s with NO accessibility
    label, the shape that made every form guide unauthorable. Each must come
    back named, with `label_source: "adjacent-text"`, and the field the app
    DID name must keep the app's own name (`ax-description`).
  * **Never an empty label** — parity with the web probe's W15 guarantee.
  * **`page_text` (W20)** — a success state rendered as prose must be
    assertable, not silently degraded to a search over control labels.
  * **Rect space (W24)** — every mark rect must lie inside the reported
    `point_size`, i.e. the captured frame's own coordinate space.
  * **Front-frame scoping (W24)** — with the sheet open, the sheet's controls
    are addressable and the button that opened it (now behind the sheet) is
    not, and `page_text` is the sheet's text.
  * **No duplicate marks (W21)** — no two marks may share role + label + rect,
    which is what made every macOS menu item unaddressable.
  * **Session death (W32)** — acting on an ended session must say the session
    ENDED, not merely that no session was found.

WB-23 adds the actuation half — everything above proves the app is
*addressable*, and the Scarf acceptance run found that almost nothing but a
button was *operable*:

  * **tap_mark FOCUSES a field** — then `type` must land in THAT field, with
    the typed value readable back out of `page_text` and the neighbouring
    field untouched. `AXPress` on a text field is a no-op, so this used to
    report a landed tap and type into whatever had focus already.
  * **tap_mark SELECTS a row** — and the fixture's echo line names the row
    that got selected, so "it selected something" can't pass for "it selected
    the row I asked for".
  * **env / launch_args (W26)** — the fixture renders its own
    `HARNESS_FIXTURE_MODE` and argv, so a passthrough that silently dropped
    would fail here rather than in an app's real data.
  * **Synthesized-label uniqueness (W15)** — two unnameable icon buttons must
    not answer to the same string.
  * **Relaunch resilience** — ending a session and immediately starting
    another on the same bundle id must WORK; it used to fail with "launched
    but never showed a visible window" because the previous instance was
    still quitting.

Requires a built fixture app (`fixtures/macos-app/build-fixture.sh`) and the
Accessibility + Screen Recording grants for the process that runs this. Both
are checked up front and reported as a SKIP (exit 0) rather than a failure —
a missing grant is a machine fact, not a regression.

Exits non-zero on any real failure. No API key required.

Usage: macos-session-smoke.py [path-to-harness-mcp-binary] [path-to-fixture.app]
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BIN = os.path.join(HERE, "..", ".build", "derived", "Build", "Products", "Debug", "harness-mcp")
DEFAULT_APP = os.path.join(HERE, "fixtures", "macos-app", "build", "HarnessMacFixture.app")
BUILD_FIXTURE = os.path.join(HERE, "fixtures", "macos-app", "build-fixture.sh")


class MCP:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
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
            self.proc.wait(timeout=15)
        except Exception:
            self.proc.kill()


def marks(result):
    return result.get("structuredContent", {}).get("marks", [])


def mark_named(result, label):
    for m in marks(result):
        if m.get("label") == label:
            return m
    return None


def content_text(result):
    for c in result.get("content", []):
        if c.get("type") == "text":
            return c.get("text", "")
    return ""


def page_text(result):
    return result.get("structuredContent", {}).get("page_text") or ""


# A value the fixture can only be rendering because THIS run's env reached it.
FIXTURE_MODE = "smoke-%d" % os.getpid()


def main():
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BIN)
    app = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_APP)

    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        print("harness-mcp binary not found/executable at: %s" % binary, file=sys.stderr)
        print("Build it: xcodebuild -project Harness.xcodeproj -scheme HarnessMCP "
              "-configuration Debug -derivedDataPath ./.build/derived build", file=sys.stderr)
        return 2
    if not os.path.isdir(app):
        print("SKIP: fixture app not built at %s" % app)
        print("      Build it first: %s" % BUILD_FIXTURE)
        return 0

    failures = []

    def check(cond, label):
        print(("  ok   " if cond else "  FAIL ") + label)
        if not cond:
            failures.append(label)

    artifact_dir = tempfile.mkdtemp(prefix="harness-macos-smoke-")
    mcp = MCP(binary)
    try:
        mcp.call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "macos-session-smoke", "version": "1"}})
        mcp.notify("notifications/initialized")

        print("\n--- start_ui_session (macos, with env + launch_args) ---")
        try:
            start = mcp.tool("start_ui_session", {
                "platform": "macos", "app_path": app, "artifact_dir": artifact_dir,
                # W26 — the fixture renders both back into its window.
                "env": {"HARNESS_FIXTURE_MODE": FIXTURE_MODE},
                "launch_args": ["--harness-fixture-arg"],
            })
        except RuntimeError as e:
            print("SKIP: could not start a macOS session (%s)" % e)
            return 0
        if start.get("isError"):
            text = content_text(start)
            print("SKIP: macOS session did not start — %s" % text.strip()[:400])
            print("      This usually means the Accessibility and/or Screen Recording grant is")
            print("      missing for the process that launched harness-mcp.")
            return 0
        sid = json.loads(content_text(start))["session_id"]
        print("  session %s" % sid)

        print("\n--- observe: labels, page_text, rect space ---")
        obs = mcp.tool("observe_ui", {"session_id": sid})
        sc = obs.get("structuredContent", {})
        all_marks = marks(obs)
        check(len(all_marks) > 0, "the AX probe produced marks")

        # W19 — the whole point.
        for name in ["Host", "Port", "Identity file"]:
            m = mark_named(obs, name)
            check(m is not None, "field '%s' is addressable by label" % name)
            if m:
                check(m.get("label_source") == "adjacent-text",
                      "field '%s' is honestly sourced as inferred (got %r)" % (name, m.get("label_source")))
        named = mark_named(obs, "Server nickname")
        check(named is not None, "the app's OWN accessibility label survives")
        if named:
            check(named.get("label_source") == "ax-description",
                  "app-supplied name is sourced as ax-description (got %r)" % named.get("label_source"))
        check(mark_named(obs, "22") is None,
              "a field's typed content is NOT used as its label")

        # W15/W19 parity — never an empty label, always a provenance.
        check(all(m.get("label", "").strip() for m in all_marks),
              "no mark carries an empty label")
        check(all(m.get("label_source") for m in all_marks),
              "every mark carries label_source (macOS reported none before)")

        # W21 — nothing indistinguishable in the table.
        keys = ["%s|%s|%s|%s" % (m["role"], m["label"], m["rect"]["x"], m["rect"]["y"]) for m in all_marks]
        check(len(set(keys)) == len(keys), "no two marks share role + label + position")

        # W20.
        text = sc.get("page_text")
        check(isinstance(text, str) and "Fixture ready" in text,
              "page_text carries the window's visible prose")

        # W26 — the launch parameters reached the launched process.
        check("mode=%s" % FIXTURE_MODE in (text or ""),
              "env reached the app (looked for mode=%s in page_text)" % FIXTURE_MODE)
        check("--harness-fixture-arg" in (text or ""),
              "launch_args reached the app's argv")

        # W15 (macOS) — a synthesized label is a discriminator, not a
        # collision. The fixture's two icon buttons can be named by nothing.
        synth = [m["label"] for m in all_marks if m.get("label_source") == "synthesized"]
        check(len(set(synth)) == len(synth),
              "no two synthesized labels collide (got %s)" % synth)

        # WB-17 — `frame_url` is a WEB concept. A macOS window has no
        # location, and an absent key is the honest form of that; a null or
        # an empty string would invite a client to compare origins here.
        check("frame_url" not in sc,
              "no frame_url on macOS — the key is absent, not null")

        # W24 — rects live in the reported frame's space.
        ps = sc.get("point_size", {})
        off = [m for m in all_marks
               if m["rect"]["x"] < 0 or m["rect"]["y"] < 0
               or m["rect"]["x"] + m["rect"]["width"] > ps.get("width", 0) + 1
               or m["rect"]["y"] + m["rect"]["height"] > ps.get("height", 0) + 1]
        check(not off, "every rect is inside point_size %s (escapees: %s)"
              % (ps, [m["label"] for m in off]))

        print("\n--- act: open the menu, check de-duplication + menu-frame scoping ---")
        servers = mark_named(obs, "Servers")
        check(servers is not None, "the menu button is addressable")
        if servers:
            opened = mcp.tool("act_ui", {"session_id": sid, "tool": "tap_mark", "id": servers["id"]})
            menu_marks = marks(opened)
            labels = [m["label"] for m in menu_marks]
            for item in ["Open in new window", "ScarfBox", "Manage Servers…"]:
                check(labels.count(item) == 1,
                      "menu item '%s' is marked EXACTLY once (got %d in %s)"
                      % (item, labels.count(item), labels))
            mps = opened.get("structuredContent", {}).get("point_size", {})
            check(all(m["rect"]["x"] + m["rect"]["width"] <= mps.get("width", 0) + 1
                      and m["rect"]["y"] + m["rect"]["height"] <= mps.get("height", 0) + 1
                      for m in menu_marks),
                  "menu rects are in the MENU frame's space, not the window's")
            check(not any(m["label"] in ("Host", "Port", "Add server") for m in menu_marks),
                  "the window behind the open menu is not in the table")
            # Dismiss the menu so the sheet check starts from a clean screen.
            mcp.tool("act_ui", {"session_id": sid, "tool": "key_shortcut", "keys": ["escape"]})
            obs = mcp.tool("observe_ui", {"session_id": sid})

        print("\n--- WB-23: tap_mark FOCUSES a field, and type lands in it ---")
        host = mark_named(obs, "Host")
        check(host is not None, "the Host field is addressable")
        if host:
            focused = mcp.tool("act_ui", {"session_id": sid, "tool": "tap_mark", "id": host["id"]})
            check(not focused.get("isError"),
                  "tap_mark on a text field does not fail (%s)" % content_text(focused)[:200])
            typed = mcp.tool("act_ui", {"session_id": sid, "tool": "type", "text": "example.internal"})
            echo = page_text(typed)
            check("host=[example.internal]" in echo,
                  "the typed value landed in the field that was tapped (echo: %r)"
                  % [l for l in echo.split("\n") if l.startswith("echo ")])
            check("port=[22]" in echo,
                  "the NEIGHBOURING field is untouched — focus went where it was asked")
            obs = mcp.tool("observe_ui", {"session_id": sid})

        print("\n--- WB-23: tap_mark SELECTS a row ---")
        row = mark_named(obs, "Tidewater")
        check(row is not None, "a list row is addressable by its own text (%s)"
              % [m["label"] for m in marks(obs)])
        if row:
            check(row.get("role") in ("row", "cell"),
                  "the row is marked with a row-ish role (got %r)" % row.get("role"))
            selected = mcp.tool("act_ui", {"session_id": sid, "tool": "tap_mark", "id": row["id"]})
            check(not selected.get("isError"),
                  "tap_mark on a row does not fail (%s)" % content_text(selected)[:200])
            check("project=[Tidewater]" in page_text(selected),
                  "the row the tap named is the one that got selected (echo: %r)"
                  % [l for l in page_text(selected).split("\n") if l.startswith("echo ")])
            obs = mcp.tool("observe_ui", {"session_id": sid})

        print("\n--- act: open the sheet, then check front-frame scoping ---")
        add = mark_named(obs, "Add server")
        check(add is not None, "the sheet's opener is addressable")
        if add:
            after = mcp.tool("act_ui", {"session_id": sid, "tool": "tap_mark", "id": add["id"]})
            sheet_marks = marks(after)
            check(mark_named(after, "Cancel") is not None,
                  "the sheet's own controls are marked (got %s)" % [m["label"] for m in sheet_marks])
            check(mark_named(after, "Add server") is None,
                  "the control BEHIND the sheet is gone from the table")
            sheet_text = after.get("structuredContent", {}).get("page_text") or ""
            check("Add a remote server" in sheet_text,
                  "page_text is the sheet's text, not the window's behind it")
            ps2 = after.get("structuredContent", {}).get("point_size", {})
            off2 = [m for m in sheet_marks
                    if m["rect"]["x"] + m["rect"]["width"] > ps2.get("width", 0) + 1
                    or m["rect"]["y"] + m["rect"]["height"] > ps2.get("height", 0) + 1]
            check(not off2, "sheet rects are in the sheet frame's space (escapees: %s)"
                  % [m["label"] for m in off2])

        print("\n--- W32: a session that ENDED says so ---")
        mcp.tool("end_ui_session", {"session_id": sid})


        dead = mcp.tool("observe_ui", {"session_id": sid})
        msg = content_text(dead)
        check(dead.get("isError") is True, "observing an ended session is an error")
        check("closed" in msg and "end_ui_session" in msg,
              "the error names the CLOSURE, not just a missing id (%r)" % msg[:200])
        never = mcp.tool("observe_ui", {"session_id": "11111111-2222-3333-4444-555555555555"})
        never_msg = content_text(never)
        check("has ever been open" in never_msg,
              "an id that was never a session says so distinctly (%r)" % never_msg[:200])

        # WB-23 — and the NEXT session on the same bundle id starts, with no
        # pause here on purpose: the previous instance is still quitting, and
        # that is exactly the race that used to surface as "launched but never
        # showed a visible window".
        print("\n--- WB-23: a new session starts while the old app is still quitting ---")
        restart = mcp.tool("start_ui_session", {
            "platform": "macos", "app_path": app, "artifact_dir": artifact_dir,
            "env": {"HARNESS_FIXTURE_MODE": FIXTURE_MODE + "-again"},
        })
        check(not restart.get("isError"),
              "an immediate restart on the same app succeeds (%s)" % content_text(restart)[:300])
        if not restart.get("isError"):
            sid2 = json.loads(content_text(restart))["session_id"]
            again = mcp.tool("observe_ui", {"session_id": sid2})
            check("mode=%s-again" % FIXTURE_MODE in page_text(again),
                  "the restarted session is the NEW process (its own env is what's on screen)")
            mcp.tool("end_ui_session", {"session_id": sid2})

    finally:
        mcp.close()

    print("\n================ %s ================" %
          ("macos-session smoke: PASS" if not failures else "macos-session smoke: FAIL"))
    if failures:
        for f in failures:
            print("  - " + f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
