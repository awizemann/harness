# Glossary

Canonical definitions of every term used in Harness. When a doc, comment, or commit message uses one of these words, it means **exactly** what's defined here. Disagreement = a wiki edit, not a redefinition in code.

---

### Run
A single end-to-end agent session against one app build for one or more goals. Has a UUID, a directory under `~/Library/Application Support/Harness/runs/<id>/`, and exactly one final `Verdict`. Bounded by `run_started` and `run_completed` rows in `events.jsonl`. Phase 6 added optional refs to the library entities (`applicationID`, `personaID`, `actionID`, `actionChainID`) and a user-supplied `name`. Single-goal runs have one Leg; chain runs have N Legs (see Leg below).

### Application
A saved per-project workspace: an Xcode project + scheme + default simulator + per-application run defaults. The user picks an Application once via the sidebar; all subsequent runs inherit its setup. SwiftData `@Model` defined in `Harness/Services/HarnessSchema.swift`. Persisted active id at `~/Library/Application Support/Harness/settings.json`.

### Persona
A plain-language description of who the agent is pretending to be. Curated in the Personas library (a `@Model` in V2 with `name`, `blurb`, `promptText`, `isBuiltIn`). Built-ins seed idempotently from `docs/PROMPTS/persona-defaults.md` on every launch. Concatenated into the system prompt at `{{PERSONA}}` for each run.

### Action
A reusable saved user-prompt — the human's plain-language description of what the agent should attempt. Stored as `name`, `promptText`, optional `notes`. Substituted into the system prompt at `{{GOAL}}` at run start. Distinct from `Tool call` below — Actions are the user's vocabulary; tool calls are the model's.

### Action Chain
An ordered sequence of Actions that runs as a single Run. Each step in the chain is a `Leg`. Chains have `name`, `notes`, and `[ActionChainStep]` carrying `index`, `action: Action?`, and `preservesState: Bool`. Execution rules: between legs, if `preservesState` is true the simulator state carries forward; otherwise the app reinstalls + relaunches. Aggregate verdict: all-success → success; first failure/blocked aborts remaining legs.

### Leg
One Action's worth of execution within a Run. A single-action run has one Leg implicitly. Chain runs have N Legs. Each Leg gets a fresh `AgentLoop` (cycle detector + step budget reset). JSONL row pair `leg_started` / `leg_completed` (schema v2). v1 logs (pre-Phase E) wrap all step rows in one virtual leg at parse time so consumers don't branch on schema version.

### Step
One iteration of the agent loop within a Leg. Comprises: a fresh screenshot, one Claude call, one tool call, the tool's execution, zero or more friction events, and a `step_completed` row. Steps are 1-indexed across the Run (not the Leg) and gap-free.

### Tool call
A model-emitted invocation of one tool (or `note_friction` / `mark_goal_done`). Carries the tool name, the typed input, and the agent's `observation` + `intent` reasoning fields. **Distinct from `Action`** above: an Action is the user-saved goal text; a tool call is what the model emits to drive the simulator on a single step.

### Tool
The vocabulary the agent has at its disposal: `tap`, `double_tap`, `swipe`, `type`, `press_button`, `wait`, `read_screen`, `note_friction`, `mark_goal_done`. Defined in `wiki/Tool-Schema.md` and `Harness/Tools/AgentTools.swift`.

### Goal
The plain-language text substituted into the system prompt at `{{GOAL}}`. For single-action runs this comes from the chosen Action's `promptText`. For chain runs each Leg's goal comes from its Action. For ad-hoc / pre-Phase-6 runs the goal is the literal text the user typed.

### Friction (event)
A `note_friction` emitted by the agent (or synthesized by the loop) flagging a user-experience problem. Has a `kind` (one of the taxonomy in `docs/PROMPTS/friction-vocab.md`) and a `detail` written in the persona's voice. Renders as an amber-tinted entry in the step feed and the friction report.

### Friction kind
One of: `dead_end`, `ambiguous_label`, `unresponsive`, `confusing_copy`, `unexpected_state` (user-emitted), or `agent_blocked` (loop-synthesized). Closed taxonomy. Adding a kind requires changes in five places — see `docs/PROMPTS/friction-vocab.md`.

### Verdict
One of `success`, `failure`, `blocked`. Emitted exactly once per run, by `mark_goal_done`. The verdict is the agent's read on what happened; `would_real_user_succeed` (a separate boolean on the same call) lets the agent disagree with itself when it succeeded by exhaustive search but a real user would have given up.

### Mode
One of `stepByStep` or `autonomous`. In step-by-step, the loop pauses between proposing and executing each action and waits for user approval. In autonomous, actions execute immediately. Set per-run on the goal-input screen; never changed mid-run.

### Approval Card
The bottom-rising UI element in `RunSessionView` that surfaces a proposed action in step-by-step mode. Has Approve / Skip / Reject-with-note / Stop affordances and keyboard shortcuts.

### Step budget
The maximum number of steps a run can take before the loop short-circuits with `mark_goal_done(blocked, "step budget exhausted")`. Default 40, range 5–200.

### Token budget
The maximum total input tokens a run can consume across all Claude calls. Default 250k for Opus, 1M for Sonnet, hard ceiling 2M. When exceeded, the loop short-circuits with `mark_goal_done(blocked, "token budget exhausted")` and emits an `agent_blocked` friction event.

### Cycle detector
The mechanism that watches the last 3 perceptual-hash + tool-call pairs and trips when all 3 match — meaning the agent is stuck looping on identical state. Tripping ends the run with `mark_goal_done(blocked)` and an `agent_blocked` friction.

### Replay
Reading a finished run's `events.jsonl` + screenshots back into memory and visualizing it via `RunReplayView`. Read-only. Idempotent. Doesn't require the simulator, the API key, or the network.

### Mirror (live mirror)
The center pane of `RunSessionView` showing the simulator's current state. Implemented as a polled screenshot at ~3 fps with a fading dot at the agent's last tap coordinate. Distinct from `Replay`, which shows past frames.

### Step feed
The right-rail list in `RunSessionView` (and `RunReplayView`) showing each step as a cell with reasoning + tool call + thumbnail. Friction events render inline as amber-tinted cells.

### SimulatorRef
The typed handle for "this simulator instance" — UDID, name, runtime, point size, scale factor. Resolved from `xcrun simctl list devices --json`. Never inferred from a name string at call time.

### Persona injection
The act of concatenating persona text into the system prompt (not the goal text) at the `{{PERSONA}}` substitution point. Shapes how the agent reasons; doesn't change the goal.

### Cycle
Distinct from `Cycle detector`: a "cycle" colloquially means one Claude call + one tool execution = one `Step`. We say "step" in code/UI; "cycle" only appears in this glossary entry.

### Run directory
The on-disk directory for a run: `<App Support>/Harness/runs/<run-id>/`. Contains `events.jsonl`, `meta.json`, `step-NNN.png`, and a `build/DerivedData-<run-id>/` subtree for the per-build derived data. Portable — copy or zip it and replay anywhere.

### `events.jsonl`
The append-only event stream for one run. Schema versioned (`schemaVersion: 1` today). Defined in `standards/14-run-logging-format.md`.

### `meta.json`
A redundant snapshot of the `RunRecord` SwiftData fields written at run end so a copied run directory can be replayed without the user's SwiftData store.

### `RunRecord`
The SwiftData entity representing one run in the user's history index. Fields: id, createdAt, completedAt, projectPath, scheme, simulator, goal, persona, model, mode, verdict, frictionCount, stepCount, tokensUsed, runDirectoryURL.

### `ProjectRef`
The SwiftData entity for "an Xcode project Harness has been pointed at." Fields: id, path, lastUsedAt, displayName, defaultScheme, defaultSimulatorUDID. Powers the recents picker on the goal input screen.

### `RunCoordinator`
The actor that orchestrates one run end-to-end: build → boot → install → launch → loop → log → cleanup. Returns `AsyncThrowingStream<RunEvent, Error>` consumed by the run-session view-model.

### `AgentLoop`
The protocol-conforming type that runs the iteration logic per `standards/13-agent-loop.md`. Owns the cycle detector, history compactor, parse-failure retry, and budget enforcement.

### `ProcessRunner`
The actor that owns every `Process()` invocation in Harness. Per `standards/03-subprocess-and-filesystem.md`, no other code spawns subprocesses directly.

### `ToolLocator`
The service that resolves external CLI paths (`xcrun`, `xcodebuild`, `brew`) at app launch and caches them in `tools.json`. Surfaces missing tools as actionable errors in the first-run wizard.

### WebDriverAgent (WDA)
Vendored at `vendor/WebDriverAgent` (submodule pinned to `appium/WebDriverAgent` v12.2.0). Drives the iOS Simulator's input via XCTest's `XCUICoordinate` APIs — events flow through the UIKit responder chain, unlike `idb`'s HID injection which iOS 26+ silently drops. Built into `~/Library/Application Support/Harness/wda-build/iOS-<ver>/` once per iOS major.minor.

### Step-mode / Autonomous-mode
Synonyms for `stepByStep` / `autonomous` modes (see `Mode`). Used colloquially in UI and docs; the canonical names are the camelCase forms.

### `HarnessDesign`
The local Swift package containing the visual design system: tokens, primitives, screen layouts. Lives at `HarnessDesign/`. Both the `Harness` app target and any future targets import it as a Swift Package.

### `HarnessPaths`
The single Swift type holding every filesystem-path constant for the app. No code outside `HarnessPaths.swift` should construct a hardcoded path.

### Approval gate
The pause point in step-by-step mode between "agent proposes action" and "tool executes." Implemented as `await` on an `AsyncStream<UserApproval>` injected into the agent loop by the view-model.

### `would_real_user_succeed`
A boolean field on `mark_goal_done` letting the agent disagree with its own verdict. The agent might `success` after extensive trial-and-error and still set this to `false` if the persona it's playing would have given up. The friction report shows this prominently.

---

_Last updated: 2026-05-03 — initial scaffolding._
