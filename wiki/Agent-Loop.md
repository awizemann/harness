# Agent Loop

The mechanical detail of the loop lives in [`../standards/13-agent-loop.md`](../standards/13-agent-loop.md). This wiki page is the prose walkthrough — read this for "what's happening here" intuition; read the standard for the load-bearing rules.

Status: scaffold. Will be filled in with a worked example from a real run after Phase 2 lands.

## Walkthrough (planned content)

A run of "I want to add 'milk' to my list and mark it as done" — first-time-user persona — narrated step by step:

1. **Step 1.** Agent sees the app's first screen (an empty list with a + button). Observation: "I see an empty list with a single + button at the bottom-right corner." Intent: "I'll tap + to add a new item." Tool: `tap(385, 880)`.
2. **Step 2.** Screen now shows a text input. Observation: "There's a text field with a 'New item' placeholder. The keyboard is up." Intent: "I'll type 'milk'." Tool: `type("milk")`.
3. ... continues until `mark_goal_done(success)`.

## Friction taxonomy

The full taxonomy lives in [`../docs/PROMPTS/friction-vocab.md`](../docs/PROMPTS/friction-vocab.md). Quick reference:

- `dead_end` — tried a path, nothing happened, backed out.
- `ambiguous_label` — couldn't tell what a control did from its text.
- `unresponsive` — interacted, no visible response.
- `confusing_copy` — body / alert / error text was hard to parse.
- `unexpected_state` — saw a state I didn't expect from my last action.
- `agent_blocked` (loop-synthesized) — budget exhausted or cycle detector tripped.

## Cross-references

- [Tool-Schema](Tool-Schema.md) — the model-facing tool contract.
- [Run-Replay-Format](Run-Replay-Format.md) — what each step writes to disk.
- [`../standards/13-agent-loop.md`](../standards/13-agent-loop.md) — the loop's invariants.
- [`../standards/07-ai-integration.md`](../standards/07-ai-integration.md) — call-pattern and prompt-caching guidance.
- [`../docs/PROMPTS/system-prompt.md`](../docs/PROMPTS/system-prompt.md) — the prompt itself.

---

_Last updated: 2026-05-03 — initial scaffolding._
