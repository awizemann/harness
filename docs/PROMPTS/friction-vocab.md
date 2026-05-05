# Friction Vocabulary

The fixed taxonomy the agent uses when emitting `note_friction(kind: ..., detail: "...")`. **Single source of truth** — referenced by:

- `docs/PROMPTS/system-prompt.md` (the model is told these kinds and what they mean)
- `Harness/Core/Models.swift` (the `FrictionEvent.Kind` enum mirrors this list)
- `HarnessDesign/` `FrictionPill` styling (one color per kind)
- [Agent-Loop](https://github.com/awizemann/harness/wiki/Agent-Loop) (human-facing friction reference)

Adding or renaming a kind requires updating all four.

---

## User-emitted kinds (the agent calls these)

### `dead_end`
The user tried a path and nothing happened, or they backed out without progress.
- *Example*: "Tapped the menu icon expecting settings; got a list of names instead. Backed out."
- *Looks like*: tapping → screen → backing out → trying somewhere else.

### `ambiguous_label`
A button or label's purpose was unclear from the text alone. The user had to tap it (or hover near it) to find out what it does.
- *Example*: "The button just says 'Go' — I can't tell from the screen what it goes to."
- *Looks like*: pausing on a screen, asking "what does this mean?", then tapping anyway.

### `unresponsive`
The user interacted with something and nothing changed visually within a reasonable time. Could be a real bug or could be slow feedback.
- *Example*: "Tapped 'Save' twice but nothing happened. Is this saving in the background?"
- *Looks like*: tapping → no change → tapping again → still nothing.

### `confusing_copy`
Body text, alert copy, error messages, or instructions were hard to interpret in context.
- *Example*: "The error says 'Operation could not be completed (NSURLErrorDomain -1009).' I have no idea what to do with that."
- *Looks like*: reading something, then proceeding cautiously or going somewhere else to figure out what was meant.

### `unexpected_state`
The user saw a state they didn't expect from their last action.
- *Example*: "I tapped 'Add' but the input field still has 'milk' in it. Did it save?"
- *Looks like*: action → unexpected screen state → confusion → re-trying or seeking confirmation.

---

## System-emitted kind (the loop synthesizes)

### `agent_blocked`
Not in the model's vocabulary — the loop emits this when it short-circuits on:

- Step budget exhausted.
- Token budget exhausted.
- Cycle detector tripped (3 turns of identical state).
- Parse-failure retry exceeded (model can't emit a valid tool call).

The replay UI styles this kind in muted gray with a wrench icon to distinguish it from user-friction events.

---

## What's NOT a friction kind

Things we deliberately don't have a kind for:

- **`accessibility_failure`** — we don't pretend to be VoiceOver. The accessibility-needs persona expresses these as `dead_end` or `unresponsive` in the user's voice.
- **`crash`** — if the app crashes, the simulator dies; the loop catches `SimulatorError.appNotResponding` and ends the run with `failure` verdict. Not a friction event.
- **`bug`** — too generic. Bugs manifest as one of the kinds above; categorize by user perception, not by developer diagnosis.
- **`slow`** — the agent can't reliably tell "intentional pause" from "performance issue." If it feels slow to the user, that's `unresponsive`. If it's fine, no friction.

---

## Detail copy guidelines

The `detail` field should:

- Be one or two sentences.
- Be in the persona's voice ("I tapped..." not "User tapped...").
- Describe what's confusing, not how to fix it ("the button doesn't say what it does" not "rename the button to 'Submit'").
- Avoid developer jargon (no "view controller", "modal sheet", "tab item index"). The agent doesn't know those terms.

The friction report UI groups by `kind` and orders by step number. Good detail copy is what makes the report readable.
