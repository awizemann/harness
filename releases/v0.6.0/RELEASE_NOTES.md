# Harness 0.6.0 — Drive Harness from agents (MCP), agent-run visibility, and auto-update

0.5 gave Harness local inference and a dev-time CLI. 0.6 opens it up to **agents**: a new **MCP server** lets Claude (or any MCP client) create personas, stage credentials, and start/inspect runs against the same on-disk store the app uses — and the GUI now treats those agent-driven runs as **first-class history**, distinct from your own. Plus **Sparkle auto-update**, so the app keeps itself current.

## Highlights

### HarnessMCP — drive Harness from an agent

`harness-mcp` is a development-time stdio MCP server, built from the same `Harness/` source as the app (minus the SwiftUI surface). It speaks JSON-RPC 2.0 over stdio and exposes ~16 tools: list/create **Applications**, **Personas**, **Actions** & chains; stage per-app **credentials**; and **`start_run` / `get_run_status` / `get_run_result` / `cancel_run` / `list_runs`**. Runs execute asynchronously under a supervisor with an **idle watchdog** that auto-cancels a wedged run after N seconds of silence — the backstop the step budget can't be.

It opens the GUI's on-disk SwiftData store, so **anything an agent creates shows up in the app, and vice-versa**. Register it in your MCP client and point the agent at your app.

Shipped alongside it: **web-driver hardening** — every per-step WKWebView call (settle, probe, JS eval, snapshot) is now bounded by a timeout race, so a navigating click to a page that never finishes loading can no longer wedge a run.

### Agent runs are first-class in the GUI

Every run now carries an **origin** — You / Agent / CLI:

- **History badges** non-user runs (a green **✦ Agent** pill) and titles them by their goal.
- A new **Agent Sessions** section in the sidebar shows **live** agent sessions with a running step counter, plus recent agent runs.
- A **global banner** floats in while an agent is driving the app, so you always know when something else is at the wheel.

Agent runs **thread into the normal per-Application History**: an ad-hoc agent run (say, a raw URL) **matches or auto-creates an Application** for its target, so it lands in that app's History — badged, with the full summary / friction / action-path / replay — instead of living in a separate island. Because the app and the MCP server are separate processes sharing one store, the app watches a lightweight marker file the server writes per live run and refreshes History the moment a run finishes.

### Sparkle auto-update

Harness now updates itself. **Check for Updates…** is in the app menu, and the app checks an [appcast feed](https://awizemann.github.io/harness/appcast.xml) on a schedule (you're asked once whether to enable automatic checks). Updates are **EdDSA-signed** and delivered through the existing Developer-ID-signed, notarized pipeline; the release script signs each build and publishes the appcast to GitHub Pages automatically.

---

Architecture notes, gotchas, and the full tool schema live in the repo's memory tier and the [wiki](https://github.com/awizemann/harness/wiki).
