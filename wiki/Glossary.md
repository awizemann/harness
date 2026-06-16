# Glossary

Canonical definitions of every term used in Harness. When a doc, comment, or commit message uses one of these words, it means **exactly** what's defined here. Disagreement = a wiki edit, not a redefinition in code.

---

### Run
A single end-to-end agent session against one app build for one or more goals. Has a UUID, a directory under `~/Library/Application Support/Harness/runs/<id>/`, and exactly one final `Verdict`. Bounded by `run_started` and `run_completed` rows in `events.jsonl`. Phase 6 added optional refs to the library entities (`applicationID`, `personaID`, `actionID`, `actionChainID`) and a user-supplied `name`. Single-goal runs have one Leg; chain runs have N Legs (see Leg below).

### Application
A saved per-project workspace: an Xcode project + scheme + default simulator + per-application run defaults. The user picks an Application once via the sidebar; all subsequent runs inherit its setup. SwiftData `@Model` defined in `Harness/Services/HarnessSchema.swift`. Persisted active id at `~/Library/Application Support/Harness/settings.json`.

### Persona
A plain-language description of who the agent is pretending to be. Curated in the Personas library (a `@Model` in with `name`, `blurb`, `promptText`, `isBuiltIn`). Built-ins seed idempotently from `docs/PROMPTS/persona-defaults.md` on every launch. Concatenated into the system prompt at `{{PERSONA}}` for each run.

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
The vocabulary the agent has at its disposal: `tap`, `double_tap`, `swipe`, `type`, `fill_credential`, `press_button`, `wait`, `read_screen`, `note_friction`, `mark_goal_done`. Defined in `wiki/Tool-Schema.md` and `Harness/Tools/AgentTools.swift`.

### Goal
The plain-language text substituted into the system prompt at `{{GOAL}}`. For single-action runs this comes from the chosen Action's `promptText`. For chain runs each Leg's goal comes from its Action. For ad-hoc / pre-Phase-6 runs the goal is the literal text the user typed.

### Friction (event)
A `note_friction` emitted by the agent (or synthesized by the loop) flagging a user-experience problem. Has a `kind` (one of the taxonomy in `docs/PROMPTS/friction-vocab.md`) and a `detail` written in the persona's voice. Renders as an amber-tinted entry in the step feed and the Friction Report. Examples: "The button just says 'Go' — I'm not sure what it does until I tap it" (ambiguous_label), "I tried to search but nothing happened" (unresponsive_control).

### Verdict
The final outcome of a Run. One of:
- `success` — agent emitted `mark_goal_done`.
- `failure` — agent gave up, or the agent's reasoning led to a dead end (e.g., "I can't find the sign-up button anywhere").
- `blocked` — cycle detector tripped, or step/token budgets exhausted, or platform error.

### Set-of-Mark
Number-badged overlays on every interactive element in a screenshot. The agent calls `tap_mark(id)` instead of guessing pixel coordinates. Probe reimplemented per platform (JS walk on web, AX tree on macOS, WDA `/source` on iOS). Disk PNGs stay clean — the marked-up image is in-memory only, for the LLM.

### ModelProvider
One of: `anthropic`, `openai`, `google`, `local_mac` (Ollama). Routes to the appropriate `LLMClient` impl at `step()` time.

### RunRequest
The user's composed run parameters: project + scheme + simulator + persona + source (single action or chain) + optional run name + optional per-run overrides (model, mode, step budget, credential). Produced by `GoalInputViewModel.buildRequest(simulator:)` and handed to `RunCoordinator.run(_:)`.

### RunRecord
The on-disk summary of a completed Run, written to `~/Library/Application Support/Harness/runs/<id>/meta.json` and indexed by `RunHistoryStore`. Carries: verdict, summary, friction count, step count, token usage, start/end time, and optional refs to the library entities (applicationID, personaID, actionID, actionChainID).

