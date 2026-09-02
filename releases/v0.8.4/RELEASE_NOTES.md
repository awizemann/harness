# Harness 0.8.4 — set_value, and type() stops lying about no-ops

A focused point release for one severe finding (WB-27 / W36): `act{type}` could not fill an `<input type="datetime-local">` behind a controlled React `onChange` — the field cleared and the create was silently dropped, while REST and Playwright both worked. Two failure modes hid behind it: reading `selectionStart` on a date/number/datetime-local input *throws* (aborting the whole insert), and a controlled component reverts any value not set the framework's way. Tool-surface change is additive.

## Highlights

### New `set_value(id, value)` web act

Addresses a Set-of-Mark id (the same parked registry `scroll_into_view` uses), focuses the element, drives the value through the native prototype setter — the React-value-tracker-correct path — dispatches `input` + `change`, blurs to commit, then **reads the value back** and reports whether it stuck. `<select>` matches by option value or visible label.

It's a distinct tool rather than a `value` argument on `type` because the contracts differ — keystroke-and-caret versus whole-value-and-verified — and a distinct tool advertises and refuses web-only cleanly. Wired end to end: the act vocabulary, `act_ui` schema, decoder, supervisor dispatch, settle profile, logging, replay, and previews. macOS/iOS refuse it explicitly for now — an AX value-set needs per-role verification, and a value-set that silently no-ops while reporting success is exactly the dishonesty this release is about.

### `type()` stops reporting no-ops as success

The typing JS now guards the `selectionStart` read and reports `{ had, changed }`: a no-op (no field focused, or a controlled/readonly field ignoring the insert) sets an honest driver detail pointing at `set_value`, instead of a clean "typed" over an unchanged screen. The mechanism is unchanged; it just stops lying. Best-effort by construction — a component that reverts on a *later* render still reads as changed here, which is why `set_value` exists. The JS returns only booleans, so the shared `fill_credential` path leaks no value.

### Verification

- **Suite 520 → 530 green.** New `WebValueEntryTests` runs the shipped JS against live-WKWebView fixtures: a controlled input that reverts a naive assignment but commits `set_value`'s, a datetime-local, a select by value and by label, the non-settable and stale paths, and the type no-op flag.
- **Live smoke** gains a set-value leg: the datetime persists through the controlled `onChange`, the select lands by label, and typing into a keystroke-ignoring field warns. Both smokes pass.
