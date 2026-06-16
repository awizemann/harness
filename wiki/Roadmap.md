# Roadmap — Ideas

A living list of ideas Harness might pursue. Not a commitment, not prioritized — the page exists so a thought worth keeping doesn't get lost between PRs. The phase-by-phase shipping log lives in [`docs/ROADMAP.md`](https://github.com/awizemann/harness/blob/main/docs/ROADMAP.md); this page is the forward end of the timeline.

## How to add an idea

Drop a new `### Title` under **Ideas** with the following fields. Keep it tight — enough that someone picking it up has a starting point, not so much it becomes a spec.

- **Status:** 📝 idea | 🔍 exploring | 🛠 in progress | ✅ shipped | ❄ shelved
- **Summary:** 1–2 sentences.
- **Why it matters:** the user pain or capability it unlocks.
- **Sketch:** where it would live, what shifts, open questions.
- **Related:** links to standards / wiki pages / code.

When an idea graduates to 🛠 / ✅, mirror the move into `docs/ROADMAP.md` as a phase line — that's still the source of truth for what shipped.

---

## Ideas

### Per-project credential store

**Status:** ✅ shipped

**Summary:** Per-Application username/password storage so the agent can sign in to gated experiences during a Run. Passwords live in Keychain; metadata (label, username, applicationID) lives in SwiftData alongside the Application.

**Why it matters:** Today every Run starts from a logged-out app — paywalled, post-login, or behind-onboarding screens are unreachable, and the friction report misses entire surfaces. Letting the user pre-stage a test account per Application closes the gap without ever putting credentials in plain text on disk or in a screenshot.

**Sketch:**
- New `@Model Credential { id, applicationID, label, username, createdAt }` in `Harness/Services/HarnessSchema.swift` (SwiftData V→V+1 with the schema bump + migration test).
- Password lives in Keychain via existing `KeychainStore` — service `com.harness.credentials`, account `<applicationID>:<credentialID>`. Re-uses the `SecItem*` wrapper, no new crypto.
- Application detail gets a "Credentials" subsection (CRUD; show username but never the password value in any UI).
- Agent surface: extend the system prompt with a `{{CREDENTIALS}}` block (label + username only, never the password) so the model knows what's available. Add a tool — likely `fill_credential(label, field: .username|.password)` — that types the stored value into the focused input via WDA. Password bytes never enter the model's context window or the JSONL log.
- Run-log redaction: `RunLogger` writes `<<credential:label>>` placeholders for password fills; same for screenshots if WDA reflects the typed text (consider tapping Hide Password before screenshotting, or relying on iOS's secure-text-entry masking).
- Friction kind: maybe new `auth-required` if the agent encounters a login wall with no credential staged — or reuse `blocked`.

**Open questions:**
- One credential per Application or many (e.g. "free user" vs "paid user" personas)? Probably many — keying by `label` allows the model to pick.
- Should chains be able to start mid-flow (already-logged-in state) by having a "log in" Action chain step that runs once and persists via `preservesState: true`?
- Web platform (WKWebView) credential autofill story is different from iOS — defer until iOS ships.

**Related:** [Core-Services](Core-Services) (KeychainStore row), [Tool-Schema](Tool-Schema) (new tool), [Agent-Loop](Agent-Loop) (system prompt template), [`standards/14-run-logging-format.md`](https://github.com/awizemann/harness/blob/main/standards/14-run-logging-format.md) (redaction rule).

### Set-of-Mark targeting on iOS + macOS

**Status:** ✅ shipped in v0.5.0 (2026-05-21)

**Summary:** The web platform got numbered "Set-of-Mark" overlays on every interactive element so the agent can call `tap_mark(id)` instead of guessing pixel coordinates. iOS and macOS still rely on coordinate-only `tap(x, y)` and hit the same vision-targeting limits — small inputs, dense controls, and label-vs-input misses. Bring the same SOM scaffolding to both desktop and simulator.

**What shipped:** iOS probe via WebDriverAgent's `/source?format=json` AX tree (parallel `actionableIOSRolesShort` + `Long` sets to cover WDA 12.x's mixed short/long role names; Cell label rollup walks up to 3 levels of StaticText/Image descendants and joins with " — "). macOS probe via `AXUIElementCreateApplication` walking the AX tree with bounded depth (24) and node cap (1500), filtered to actionable AX roles (`kAXButtonRole`, `kAXTextFieldRole`, `kAXLinkRole`, etc.). Coordinates convert from global screen → window-local by subtracting `windowOrigin`. Shared `MarkRenderer` at `Harness/Platforms/MarkRenderer.swift` is one annotation pipeline across iOS, macOS, and web. `tap_mark` added to the tool schema for all three platforms; cycle detector gained equivalence rules. Smart settle gates ride along — screenshot-stability dHash on iOS/macOS, MutationObserver with `requireChildListMutation` for SPA route transitions on web. See [iOS-Driver](iOS-Driver) and [macOS-Driver](macOS-Driver).

**Why it matters:** The web release of SOM eliminated a whole class of "agent tapped just above the input" failures. iOS forms and macOS apps with dense control bars suffer the same imprecision; without SOM, every misclick burns a step + an LLM round-trip. SOM also makes runs more replayable — saved screenshots carry the same numbered scaffolding the agent saw, so a human reviewer can read the run by element identity rather than tracking shifting coordinates.

**Sketch:**
- iOS probe: walk the WebDriverAgent accessibility tree (already running for taps) per step. Filter to controls that have a non-empty `label` or `identifier` and a non-zero rect. Resolve element rects via WDA's `/wda/screenshot` + element snapshot APIs.
- macOS probe: walk the AX (Accessibility) tree from `MacAppDriver` — `AXUIElementCopyAttributeValues` on `kAXChildrenAttribute` recursively, filter by `kAXRoleAttribute` ∈ {AXButton, AXTextField, AXLink, AXCheckBox, AXRadioButton, AXMenuButton}, resolve frames via `kAXFrameAttribute`.
- Shared overlay path: extract the per-element `(rect, accessible-name)` list to a Sendable `[InteractiveMark]` struct, hand to the same `markScreenshot(image:marks:)` helper the web driver uses.
- Tool surface: `tap_mark(id:)` already exists on web; extend the canonical tool set + per-platform name list to include it for iOS / macOS.
- Driver dispatch: iOS resolves `id → cached element` → call WDA's `tap` at element center (or the element's `tap` action directly when the AX tree exposes it). macOS resolves to `(centerX, centerY)` → existing CGEvent click path.

**Open questions:**
- WDA's snapshot of the accessibility tree can be slow on heavy iOS screens (200+ controls). Cap to N most-prominent elements? Filter to "in-viewport"?
- macOS AX requires Screen Recording AND Accessibility permission. We already have Screen Recording for screenshot capture; AX is a second prompt. Surface that in the first-run wizard if iOS isn't enabled there yet.
- Reading order — both AX trees are roughly DOM-like but not always top-to-bottom. Sort by `(rect.y, rect.x)` like web does, or trust the AX tree order?

**Related:** [Tool-Schema](Tool-Schema) (tap_mark row, web today), [Agent-Loop](Agent-Loop), `Harness/Platforms/iOS/IOSPlatformAdapter.swift`, `Harness/Platforms/MacOS/MacAppDriver.swift`, `Harness/Platforms/Web/WebDriver.swift` (web reference implementation).

### Human-in-the-loop interrupts (2FA, CAPTCHA, security questions, biometric prompts)

**Status:** 📝 idea

**Summary:** A new tool — `request_user_input(reason, secret)` — that pauses an in-flight run, surfaces a sheet asking the user for whatever piece of info the agent can't supply itself (a 6-digit SMS code, a CAPTCHA solution, a security-question answer, "press the prompt on your phone" acknowledgement), then types the submitted value into the focused field via the same `dispatchType` path credential fills already use. Generic answer to "the run hit something only a human can resolve" so we don't fork per challenge type.

**Why it matters:** With credentials + Set-of-Mark + React-aware form fill all working, the next failure mode every run hits is the **second** authentication factor. eBay sign-in (and most modern services with real-user accounts) demands an SMS code after the password lands. Today the run blocks: the agent has no tool that maps to "I need a piece of info from you," so it either emits `auth_required` friction (correct, useful, but ends the run) or — for smaller models — gives up by returning prose, which the parse-retry cap exhausts as `agent_blocked`. The same shape recurs for CAPTCHAs, "what's the answer to your security question," "tap the prompt that just appeared on your other device," and any cookie banner that demands an interactive choice the agent can't reasonably make on the user's behalf.

The standard QA workaround — *use a test account without 2FA* — works for many cases but isn't always available, and a generic interrupt mechanism unblocks **all** these scenarios at once instead of building per-challenge integrations (TOTP libraries, SMS-to-API gateways, CAPTCHA solver vendors).

**Sketch:**
- New tool `request_user_input(reason: string, secret: bool, observation, intent)` — advertised on every platform that can type into the focused field (iOS / macOS / web). The agent calls it whenever it sees a screen requesting a piece of info it doesn't have.
- New `RunStatus` case `.awaitingUserInput(reason, secret, step)` distinct from `.awaitingApproval` — different UI semantics (input field vs. approve/skip/reject buttons).
- `RunSessionViewModel` exposes a `pendingInput: PendingInputRequest?` and a `provideUserInput(_:)` method. `RunCoordinator.runLeg` pauses the leg loop until either input arrives or the user cancels (→ `auth_required` friction → run end).
- New primitive `UserInputCard` in HarnessDesign — modeled on `ApprovalCard` but with a single `TextField` (or `SecureField` when `secret: true`), a "Submit" button, a "Cancel" button (treated as cancel-the-run), the agent's reason as the heading. Lives in the same `ZStack(alignment: .bottom)` overlay slot the `ApprovalCardWrapper` uses.
- Driver dispatch: identical to `fill_credential` — type the user-supplied text into `document.activeElement` (web) / focused field (iOS / macOS) via the React-aware setter path.
- **Redaction parity with credentials.** When `secret: true`:
  - JSONL `tool_call.input` records `{"reason": "...", "secret": true}` only — never the supplied value (same rule passwords already follow).
  - The model's context never sees the value: the driver injects it directly; the agent's next screenshot shows the post-fill DOM, that's it.
  - When `secret: false` (a CAPTCHA answer, a non-secret security-question response), the value IS recorded so replay can reconstruct it.
- Prompt update — `docs/PROMPTS/system-prompt.md` (or per-platform context) gets a section: *"When you need a piece of information you don't have — an SMS code, a CAPTCHA answer, a fingerprint scan acknowledgement — call `request_user_input(reason)`. Be specific in `reason` so the user knows what to enter. Mark `secret: true` for codes / passwords; `secret: false` for visible answers like CAPTCHA solutions."*
- Run-log schema bump v3 → v4 to add the new tool's input shape and a `user_input_provided` row kind that records when (and how long) the run waited.

**Open questions:**
- **Timeout policy.** SMS codes are time-bound (often expire in 5–10 minutes); TOTPs in 30 seconds. Do we cap the wait at N minutes after which the run auto-fails with `auth_required`? User-configurable per-Application?
- **Replay determinism.** With user-supplied values mid-run, replay needs to either re-prompt (interactive replay) or replay the recorded value (only possible for `secret: false`). Worth being explicit in the standards doc.
- **Step budget accounting.** Should "waiting for human input" count as a step? Probably no — the agent didn't act, it asked.
- **Token budget while paused.** Same story — token meter pauses while waiting? Or charge per re-prompt? The simplest answer is "no LLM call happens during the wait, so naturally no tokens".
- **Notification.** If the user walked away, surface a system notification when input is requested — otherwise the user won't know to come back. Reuses macOS user notifications; minimal new surface.

**Out of scope (intentional):**
- TOTP code generation. Storing TOTP secrets per-credential and computing codes on the user's behalf is a meaningfully different feature (different storage shape, RFC 6238 implementation, secret-rotation UX). It would slot in as a `fill_totp_code()` extension to credentials later, but the human-in-the-loop story should ship first because it covers the broader interrupt category.
- CAPTCHA solver integrations (third-party APIs that solve image / audio CAPTCHAs). Adds dependency, cost, ToS-questionable for many sites. Generic human input handles the case fine — the user solves the CAPTCHA in their head, types the answer.
- Push-notification approvals (e.g., "approve from your iPhone"). The user just dismisses on their phone and clicks Submit on the empty input; the agent retakes the screenshot and continues.

**Related:** [Tool-Schema](Tool-Schema), [Agent-Loop](Agent-Loop), [`Harness/Platforms/Web/WebDriver.swift`](https://github.com/awizemann/harness/blob/main/Harness/Platforms/Web/WebDriver.swift) (dispatchType — reuse for typing the supplied value), [`HarnessDesign/Primitives/ApprovalCard.swift`](https://github.com/awizemann/harness/blob/main/HarnessDesign/Primitives/ApprovalCard.swift) (visual precedent), [`standards/14-run-logging-format.md`](https://github.com/awizemann/harness/blob/main/standards/14-run-logging-format.md) (redaction rule for `secret: true` mirrors the password rule).

### Hide Set-of-Mark badges from human-visible surfaces

**Status:** ✅ shipped (v0.3.1)

**Summary:** Saved the raw unmarked snapshot to disk; render the numbered SOM badges only on an in-memory copy when constructing the LLM payload. Replay, friction reports, exported screenshots, and share-with-stakeholder workflows all show the clean rendered page — the agent still gets its scaffolding, but it stays out of human-visible surfaces.

**What landed:**
- `WebDriver.screenshot(into:)` writes the unmarked PNG to disk; the marked copy is rendered in-memory and returned via the new `ScreenshotMetadata.markedImageData` field.
- `RunCoordinator` substitutes those bytes for the disk PNG when building the LLM payload; everything else (replay, friction report, exports) keeps reading the clean disk artifact.
- `lastMarks` cache for `tap_mark` dispatch stayed as-is.
- iOS / macOS leave `markedImageData` nil today — the same split applies the moment they grow accessibility-tree probes (tracked under [Set-of-Mark targeting on iOS + macOS](#set-of-mark-targeting-on-ios--macos)).
- Standard 14 §6 documents the new "no agent scaffolding on disk" invariant.

**Deferred:** the optional Settings toggle "Show agent scaffolding in replay" + sidecar `step-NNN-marks.json` would let replay re-render marks on demand for debugging / agent-loop tuning. Not yet shipped — open if and when a debugging need surfaces.

**Related:** [`Harness/Platforms/Web/WebDriver.swift`](https://github.com/awizemann/harness/blob/main/Harness/Platforms/Web/WebDriver.swift), [`Harness/Platforms/UXDriving.swift`](https://github.com/awizemann/harness/blob/main/Harness/Platforms/UXDriving.swift), [`Harness/Domain/RunCoordinator.swift`](https://github.com/awizemann/harness/blob/main/Harness/Domain/RunCoordinator.swift), [`standards/14-run-logging-format.md`](https://github.com/awizemann/harness/blob/main/standards/14-run-logging-format.md).

### Two-column layout for Persona + Credential on Compose Run

**Status:** ✅ shipped (v0.3.1)

**Summary:** Persona and Credential sit side-by-side in Compose Run. They're conceptually the "who's running this?" pair; pairing them visually shortens the form and groups related choices.

**What landed:**
- `GoalInputView.content(vm:)` now wraps `PersonaSection` + `CredentialSection` in a new `personaCredentialPair(vm:)` helper.
- `ViewThatFits(in: .horizontal)` chooses between an HStack (equal-width, top-aligned) and a VStack fallback for narrow windows.
- `CredentialSection` keeps self-hiding when `vm.credentials.isEmpty`; Persona's `.frame(maxWidth: .infinity)` lets it expand to fill the row in that case.
- All within existing Theme tokens — no new design.

**Related:** [`Harness/Features/GoalInput/Views/GoalInputView.swift`](https://github.com/awizemann/harness/blob/main/Harness/Features/GoalInput/Views/GoalInputView.swift), [Design-System](Design-System).

### Import GitHub issues as Actions

**Status:** 📝 idea

**Summary:** Connect an Application to its GitHub repo and pull UX-themed issues directly into the Actions library — each issue becomes a ready-to-run Action whose `promptText` is derived from the issue body. The user picks an issue from a list, hits Run, and the agent attempts to reproduce the reported experience.

**Why it matters:** The bottleneck on running Harness regularly isn't the agent — it's writing the prompts. Every team already has a backlog of "this onboarding feels off", "checkout button is hard to find", "I couldn't figure out how to cancel" issues sitting in GitHub. Treating those as the Action queue means Harness slots into existing workflow instead of asking the user to translate twice (once into the issue, once into a Harness prompt).

**Sketch:**
- Add `githubRepo: String?` (owner/name) + `githubIssueLabels: [String]` (default `["ux", "user-experience"]`) to `Application` via SwiftData V→V+1.
- New `Harness/Services/GitHubClient.swift` — actor; URLSession against the GitHub REST API (`/repos/{owner}/{repo}/issues?labels=…&state=open`). Optional GraphQL upgrade later if pagination/cost matters. Handles ETag caching + rate-limit headers.
- Auth: GitHub Personal Access Token in Keychain — `KeychainStore` service `com.harness.github`, account `default`. Settings sheet gains a "GitHub token" field next to the Anthropic key. Public repos work without a token (rate-limited); private repos require one.
- New "Issues" tab inside the Actions feature, filtered to the active Application's repo. Row shows title + labels + `#123` link. Single click previews body; "Import as Action" creates a draft Action with `name: "[#123] {title}"` and `promptText: <issue body, lightly preprocessed>`.
- Preprocessing options:
  - **Verbatim:** drop the issue body straight in. Cheapest. Risk: noise (env tables, stack traces, screenshots) confuses the agent.
  - **AI-summarized:** one-shot Claude call to extract the user-facing problem into a goal sentence; show the proposed prompt in a diff view before save. Better signal, costs a token round-trip per import.
  - Likely both: verbatim by default, "Refine with Claude" button on the import sheet.
- Optional: a `githubIssueNumber: Int?` field on `Action` so we can show "Source: #123" badges and (later) link runs back to the issue.

**Open questions:**
- Auth model: PAT vs OAuth app vs piggyback on the user's `gh` CLI auth? PAT is simplest and matches the Anthropic-key precedent; `gh` piggyback is friendlier UX (no extra setup) but couples us to a tool the user might not have. Probably ship PAT first, add `gh` detection as a follow-up.
- Filtering: label-driven (configurable per Application — already in the schema sketch) or AI-classified ("read all open issues, flag the UX ones")? Label-driven is cheaper, predictable, and respects how teams already triage. AI classification is a deferred mode.
- Bidirectional? Posting a Run's verdict + friction summary back as an issue comment is tempting but a separate concern — track as its own idea ("Round-trip Run verdicts to GitHub") if/when this lands.
- Stale-issue hygiene: if an issue closes upstream after we've imported it, does the local Action archive automatically, or just show a "closed upstream" badge? Probably the badge — closing locally would silently drop history.
- Does this generalize? Linear, Jira, Notion all have similar surfaces. Don't over-abstract on idea #1 — ship GitHub, refactor to a `IssueProvider` protocol when the second one shows up.

**Related:** [Core-Services](Core-Services) (new GitHubClient row), [Adding-a-Service](Adding-a-Service) (recipe), [Workspace](Workspace) (Application + Action models), `Harness/Services/HarnessSchema.swift` (V→V+1 migration).

---

P26-05-06 — page added; GitHub-issue idea appended_
