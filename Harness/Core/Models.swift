//
//  Models.swift
//  Harness
//
//  Core domain types used across services and features. Plain values; Sendable
//  by construction. Naming matches `https://github.com/awizemann/harness/wiki/Glossary` exactly.
//
//  These are NOT the SwiftData @Model types (those live in
//  Harness/Services/RunHistoryStore.swift when that lands). These are the
//  in-memory representations passed across actor boundaries.
//

import Foundation

// MARK: - Run setup

/// What the user configures on the Compose-Run screen and hands to
/// `RunCoordinator`. Phase E renamed this from `GoalRequest` and grew
/// it with library-entity refs + a payload that distinguishes a single-action
/// run from a chain run.
///
/// `goal` and `persona` are denormalized snapshots: for a single-action
/// payload, `goal` mirrors the action's prompt; for a chain payload,
/// `goal` mirrors `legs.first?.goal ?? ""`. Keeping them on the request
/// means everything downstream (JSONL `run_started`, `RunRecord`'s
/// durable snapshot, single-leg history rendering, AgentLoop's existing
/// `{{GOAL}}` substitution) keeps working without conditionals.
struct RunRequest: Sendable, Hashable, Codable {
    let id: UUID
    let name: String
    let goal: String
    let persona: String
    let applicationID: UUID?
    let personaID: UUID?
    let payload: RunPayload
    let project: ProjectRequest
    let simulator: SimulatorRef
    let model: AgentModel
    let mode: RunMode
    let stepBudget: Int
    let tokenBudget: Int
    /// V4: which platform this run targets. Optional in the Codable shape so
    /// historical request blobs (none on disk today, but keep room) and
    /// any test that omits the field decode cleanly. `platformKind`
    /// resolves nil to `.iosSimulator` — phase 1 ships only iOS.
    let platformKindRaw: String?

    /// Phase 2: pre-built macOS .app path for `.macosApp` runs (optional —
    /// when nil, the macOS adapter falls back to xcodebuild + `project`).
    let macAppBundlePath: String?

    /// Phase 3: web start URL + viewport for `.web` runs.
    let webStartURL: String?
    let webViewportWidthPt: Int?
    let webViewportHeightPt: Int?

    /// V5: optional pointer to a `Credential` the user pre-staged for this
    /// run. `nil` means the run starts logged-out and the agent has no
    /// credential to fill. The actual password lives in Keychain — only
    /// the id travels in the request, and the resolution to a real
    /// `CredentialBinding` happens in `RunCoordinator.execute` once the
    /// run actually starts.
    let credentialID: UUID?

    /// Resolved platform kind for this run.
    var platformKind: PlatformKind { PlatformKind.from(rawValue: platformKindRaw) }

    init(
        id: UUID = UUID(),
        name: String = "",
        goal: String,
        persona: String,
        applicationID: UUID? = nil,
        personaID: UUID? = nil,
        payload: RunPayload = .ad_hoc,
        project: ProjectRequest,
        simulator: SimulatorRef,
        model: AgentModel = .opus47,
        mode: RunMode = .stepByStep,
        stepBudget: Int = 40,
        tokenBudget: Int = 250_000,
        platformKindRaw: String? = nil,
        macAppBundlePath: String? = nil,
        webStartURL: String? = nil,
        webViewportWidthPt: Int? = nil,
        webViewportHeightPt: Int? = nil,
        credentialID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.persona = persona
        self.applicationID = applicationID
        self.personaID = personaID
        self.payload = payload
        self.project = project
        self.simulator = simulator
        self.model = model
        self.mode = mode
        self.stepBudget = stepBudget
        self.tokenBudget = tokenBudget
        self.platformKindRaw = platformKindRaw
        self.macAppBundlePath = macAppBundlePath
        self.webStartURL = webStartURL
        self.webViewportWidthPt = webViewportWidthPt
        self.webViewportHeightPt = webViewportHeightPt
        self.credentialID = credentialID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, goal, persona
        case applicationID, personaID, payload, project, simulator
        case model, mode, stepBudget, tokenBudget, platformKindRaw
        case macAppBundlePath, webStartURL, webViewportWidthPt, webViewportHeightPt
        case credentialID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.goal = try c.decode(String.self, forKey: .goal)
        self.persona = try c.decode(String.self, forKey: .persona)
        self.applicationID = try c.decodeIfPresent(UUID.self, forKey: .applicationID)
        self.personaID = try c.decodeIfPresent(UUID.self, forKey: .personaID)
        self.payload = try c.decodeIfPresent(RunPayload.self, forKey: .payload) ?? .ad_hoc
        self.project = try c.decode(ProjectRequest.self, forKey: .project)
        self.simulator = try c.decode(SimulatorRef.self, forKey: .simulator)
        self.model = try c.decode(AgentModel.self, forKey: .model)
        self.mode = try c.decode(RunMode.self, forKey: .mode)
        self.stepBudget = try c.decode(Int.self, forKey: .stepBudget)
        self.tokenBudget = try c.decode(Int.self, forKey: .tokenBudget)
        // V4: optional in the Codable shape; missing → nil → defaults to iOS.
        self.platformKindRaw = try c.decodeIfPresent(String.self, forKey: .platformKindRaw)
        self.macAppBundlePath = try c.decodeIfPresent(String.self, forKey: .macAppBundlePath)
        self.webStartURL = try c.decodeIfPresent(String.self, forKey: .webStartURL)
        self.webViewportWidthPt = try c.decodeIfPresent(Int.self, forKey: .webViewportWidthPt)
        self.webViewportHeightPt = try c.decodeIfPresent(Int.self, forKey: .webViewportHeightPt)
        self.credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID)
    }
}

/// Phase E renamed `GoalRequest` to `RunRequest`. The typealias keeps
/// pre-rework tests / call-sites compiling while we migrate them.
/// New code should use `RunRequest` directly.
typealias GoalRequest = RunRequest

extension RunRequest {
    /// Sentinel value on `stepBudget` meaning "no step cap — only the
    /// token budget gates the run." Picked as `0` rather than `Int.max`
    /// so on-disk JSONL stays human-readable. The Stepper UI minimum is
    /// 5, so a user can never land on this value except via the explicit
    /// "Unlimited" toggle in Settings / Compose Run / Application
    /// defaults.
    static let unlimitedStepBudget: Int = 0

    /// True when the run has a finite step budget. AgentLoop and
    /// RunCoordinator gate their step-budget short-circuit on this so a
    /// run with `stepBudget == .unlimitedStepBudget` runs until
    /// `mark_goal_done`, the token budget exhausts, or the cycle
    /// detector trips.
    var hasStepBudget: Bool { stepBudget > 0 }
}

extension AgentModel {
    /// Default per-run input-token cap. Picked per-model so every model
    /// has a reasonable headroom proportional to its dollar cost — Opus
    /// is the only model where 250k tokens is genuinely expensive ($3.75
    /// at the published rate); cheaper tiers can afford more tokens of
    /// runway before the budget rail trips.
    ///
    /// Replaces the legacy `model == .opus47 ? 250_000 : 1_000_000`
    /// ternary that lumped GPT-4.1 Nano (~$0.04/M cached) in with
    /// Sonnet 4.6 ($0.30/M cached) at the same 1M cap.
    var defaultTokenBudget: Int {
        switch self {
        case .opus47:            return 250_000      // ≤ ~$3.75 raw
        case .sonnet46:          return 1_000_000    // ≤ ~$3 raw
        case .haiku45:           return 2_000_000    // ≤ ~$2 raw, ~$0.20 cached
        case .gpt5Mini:          return 2_000_000    // ≤ ~$0.50 raw
        case .gpt41Nano:         return 2_000_000    // ≤ ~$0.20 raw
        case .gemini25Flash:     return 2_000_000    // ≤ ~$0.60 raw
        case .gemini25FlashLite: return 2_000_000    // ≤ ~$0.20 raw
        }
    }

    /// Hard ceiling for a per-run token budget. The Stepper UI clamps to
    /// this. Lets the user dial up cheap models substantially while
    /// keeping Opus from accidentally running away.
    var maxTokenBudget: Int {
        switch self {
        case .opus47:            return 1_000_000    // ~$15 raw absolute max
        case .sonnet46:          return 3_000_000    // ~$9 raw absolute max
        case .haiku45,
             .gpt5Mini, .gpt41Nano,
             .gemini25Flash, .gemini25FlashLite:
            return 10_000_000                         // ≤ ~$3 raw on the most expensive of these
        }
    }
}

/// Discriminator for what the agent should drive: one Action's prompt
/// (single leg) or an ordered list of legs (chain). The `.ad_hoc`
/// fallback covers tests and any pre-Phase-E call site that doesn't yet
/// pass through the Compose Run form — equivalent to a single anonymous
/// leg whose goal is `RunRequest.goal`.
enum RunPayload: Sendable, Hashable, Codable {
    case singleAction(actionID: UUID, goal: String)
    case chain(chainID: UUID, legs: [ChainLeg])
    /// Test / legacy entrypoint with no library-entity refs. The
    /// coordinator treats this as one leg whose goal is the request's
    /// `goal` field, keeping pre-rework call sites working.
    case ad_hoc

    /// Number of distinct legs the executor will run. Single-action and
    /// ad-hoc both produce one leg; chains report their step count.
    var legCount: Int {
        switch self {
        case .singleAction, .ad_hoc: return 1
        case .chain(_, let legs): return legs.count
        }
    }
}

/// One leg of a chain run. Each leg ends when the agent emits
/// `mark_goal_done(...)`. The cycle detector + step budget reset between
/// legs; the token budget is per-run total.
struct ChainLeg: Sendable, Hashable, Codable, Identifiable {
    /// Stable per-leg id — used as the `LegRecord.id` and as a join key
    /// between the JSONL `leg_started`/`leg_completed` rows and the
    /// in-memory `LegRecord`.
    let id: UUID
    /// 0-based ordering. Always equals the leg's position in
    /// `RunPayload.chain(_, legs:)`.
    let index: Int
    /// Original `Action.id` this leg was built from. `nil` is reserved
    /// for synthesized legs (e.g. a chain step whose action got deleted
    /// — the executor refuses such chains pre-flight, so this should
    /// stay populated for v1 chains).
    let actionID: UUID?
    /// Denormalized at request-build time so a deleted Action doesn't
    /// break log rendering.
    let actionName: String
    /// The leg's prompt, injected into `{{GOAL}}`.
    let goal: String
    /// `false` reinstalls + relaunches the Application before this leg's
    /// agent loop starts. `true` keeps the simulator state. Always
    /// `false` for the first leg (since the install happens before any
    /// leg runs).
    let preservesState: Bool
}

/// Persisted leg record on `RunRecord.legsJSON`. One per executed (or
/// skipped) leg in a chain run. Not written for single-action runs —
/// `legsJSON` stays nil there.
struct LegRecord: Sendable, Hashable, Codable, Identifiable {
    let id: UUID
    let index: Int
    let actionName: String
    let goal: String
    let preservesState: Bool
    /// `nil` while the leg is still running. After the leg ends, one of
    /// `"success" | "failure" | "blocked" | "skipped"`. Skipped legs
    /// happen when an earlier leg failed/blocked and the executor
    /// short-circuits remaining legs (we still emit a `leg_completed`
    /// row so the replay shape stays predictable).
    let verdictRaw: String?
    let summary: String?

    var verdict: Verdict? { verdictRaw.flatMap(Verdict.init(rawValue:)) }
    /// Convenience: skipped legs carry verdictRaw == "skipped".
    var wasSkipped: Bool { verdictRaw == "skipped" }
}

struct ProjectRequest: Sendable, Hashable, Codable {
    /// Absolute path to the .xcodeproj or .xcworkspace.
    let path: URL
    let scheme: String
    let displayName: String
}

enum RunMode: String, Sendable, Hashable, Codable, CaseIterable {
    case stepByStep
    case autonomous
}

/// Which vendor hosts a model. Drives client dispatch (`LLMClientFactory`),
/// per-provider Keychain entries, and the two-step provider→model picker
/// in Settings / Compose Run.
enum ModelProvider: String, Sendable, Hashable, Codable, CaseIterable {
    case anthropic
    case openai
    case google

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .google:    return "Google"
        }
    }
}

enum AgentModel: String, Sendable, Hashable, Codable, CaseIterable {
    // Anthropic
    case opus47            = "claude-opus-4-7"
    case sonnet46          = "claude-sonnet-4-6"
    case haiku45           = "claude-haiku-4-5"
    // OpenAI
    case gpt5Mini          = "gpt-5-mini"
    case gpt41Nano         = "gpt-4.1-nano"
    // Google
    case gemini25Flash     = "gemini-2.5-flash"
    case gemini25FlashLite = "gemini-2.5-flash-lite"

    var displayName: String {
        switch self {
        case .opus47:            return "Opus 4.7"
        case .sonnet46:          return "Sonnet 4.6"
        case .haiku45:           return "Haiku 4.5"
        case .gpt5Mini:          return "GPT-5 Mini"
        case .gpt41Nano:         return "GPT-4.1 Nano"
        case .gemini25Flash:     return "Gemini 2.5 Flash"
        case .gemini25FlashLite: return "Gemini 2.5 Flash Lite"
        }
    }

    /// Which vendor hosts this model — drives the per-run `LLMClient`
    /// the factory hands back and which Keychain key the request reads.
    var provider: ModelProvider {
        switch self {
        case .opus47, .sonnet46, .haiku45:           return .anthropic
        case .gpt5Mini, .gpt41Nano:                   return .openai
        case .gemini25Flash, .gemini25FlashLite:      return .google
        }
    }
}

// MARK: - Simulator

/// Typed handle for "this iOS simulator." Resolved via `simctl list devices --json`.
/// Never inferred from a name string at call time — UDIDs are the source of truth.
struct SimulatorRef: Sendable, Hashable, Codable {
    let udid: String
    let name: String
    let runtime: String
    let pointSize: CGSize
    let scaleFactor: CGFloat

    /// Pixel-space size of screenshots (`pointSize × scaleFactor`). Convenience.
    var pixelSize: CGSize {
        CGSize(width: pointSize.width * scaleFactor, height: pointSize.height * scaleFactor)
    }
}

enum SimulatorButton: String, Sendable, Hashable, Codable, CaseIterable {
    case home, lock, side, siri
}

// MARK: - Steps and actions

/// One step in a run. The `step` index is 1-based and gap-free.
struct Step: Sendable, Hashable, Codable, Identifiable {
    var id: Int { step }
    let step: Int
    let startedAt: Date
    let screenshotPath: String       // relative to run dir, e.g. "step-003.png"
    let observation: String?
    let intent: String?
    let toolCall: ToolCall?
    let toolResult: ToolResult?
    let frictionEvents: [FrictionEvent]
    let completedAt: Date?
    let tokensInput: Int?
    let tokensOutput: Int?
}

/// One tool call emitted by the model.
struct ToolCall: Sendable, Hashable, Codable {
    let tool: ToolKind
    let input: ToolInput
    let observation: String
    let intent: String
}

/// The model-facing tool vocabulary. **Raw values are the snake_case names
/// that match `https://github.com/awizemann/harness/wiki/Tool-Schema` and `Harness/Tools/AgentTools.swift`** —
/// these are what Claude emits in `tool_use.name` and what we encode in
/// JSONL `tool` fields. Bug fixed in commit a08b2a6+1: defaults to Swift
/// identifiers (`noteFriction`, `doubleTap`, etc.) silently broke 5 of 9
/// tools because the model called them by snake_case names that
/// `ToolKind(rawValue:)` rejected.
enum ToolKind: String, Sendable, Hashable, Codable, CaseIterable {
    // Universal (every platform).
    case tap            = "tap"
    case doubleTap      = "double_tap"
    case type           = "type"
    case wait           = "wait"
    case readScreen     = "read_screen"
    case noteFriction   = "note_friction"
    case markGoalDone   = "mark_goal_done"
    // iOS-specific.
    case swipe          = "swipe"
    case pressButton    = "press_button"
    // macOS / web — Phase 2 + 3.
    case rightClick     = "right_click"
    case keyShortcut    = "key_shortcut"
    case scroll         = "scroll"
    // Web-only.
    case navigate       = "navigate"
    case back           = "back"
    case forward        = "forward"
    case refresh        = "refresh"
    // V5 — universal across platforms that have a focused-text-field
    // concept (iOS / macOS / web). Types the run's pre-staged credential.
    case fillCredential = "fill_credential"
}

/// Tagged-union payload for any tool. Field names match `https://github.com/awizemann/harness/wiki/Tool-Schema`.
///
/// Variants are partitioned by platform:
///   - `tap` / `doubleTap` / `type` / `wait` / `readScreen` / `noteFriction`
///     / `markGoalDone` — universal.
///   - `swipe` / `pressButton` — iOS-only.
///   - `rightClick` / `keyShortcut` / `scroll` — macOS / web.
///   - `navigate` / `back` / `forward` / `refresh` — web-only.
///
/// A `PlatformAdapter` advertises only its subset via
/// `toolDefinitions(...)`, so the model never emits a variant the active
/// driver can't execute. If it ever does, `UXDriverError.unsupportedTool`
/// surfaces the bug at the boundary.
enum ToolInput: Sendable, Hashable, Codable {
    case tap(x: Int, y: Int)
    case doubleTap(x: Int, y: Int)
    case swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int)
    case type(text: String)
    case pressButton(button: SimulatorButton)
    case wait(ms: Int)
    case readScreen
    case noteFriction(kind: FrictionKind, detail: String)
    case markGoalDone(verdict: Verdict, summary: String, frictionCount: Int, wouldRealUserSucceed: Bool)
    // macOS / web extensions:
    case rightClick(x: Int, y: Int)
    /// Modifier-key combination + final key. e.g. `["cmd", "shift", "n"]`.
    case keyShortcut(keys: [String])
    /// Scroll wheel — positive `dy` = scroll down, positive `dx` = scroll right.
    case scroll(x: Int, y: Int, dx: Int, dy: Int)
    // Web-only:
    case navigate(url: String)
    case back
    case forward
    case refresh
    /// V5: Type the run's pre-staged credential (username or password)
    /// into the focused text field. The actual value comes from the
    /// driver's cached `CredentialBinding`, NOT from the agent — the
    /// password value never enters the model's context window or the
    /// JSONL log. The agent picks the field; the run picks the credential.
    case fillCredential(field: CredentialField)
}

/// Which slot of a stored credential `fill_credential` should type.
/// String-backed so it serialises cleanly into the tool's `input` JSON
/// in the agent's tool call.
enum CredentialField: String, Sendable, Hashable, Codable, CaseIterable {
    case username
    case password
}

/// A run-time, fully-resolved credential. Built once at run start by
/// `RunCoordinator` (DB lookup + Keychain read) and handed to the active
/// platform driver, which uses it to satisfy `fill_credential` tool calls.
///
/// **Containment rules**:
/// - `password` lives only here, on the driver, for the run's duration.
/// - It is never logged, never put in `tool_call.input`, never substituted
///   into prompt templates, never emitted on a `RunEvent`.
/// - When the run ends, the binding is dropped along with the driver.
struct CredentialBinding: Sendable {
    let id: UUID
    let label: String
    let username: String
    let password: String
}

/// Builds the multi-line text injected into the system prompt's
/// `{{CREDENTIALS}}` slot. Pure function so it's trivially testable and
/// callable from any actor / queue. The two surfaces it serves:
///
/// - `(label, username)` provided → a 5-line block describing the staged
///   credential and how to use `fill_credential`.
/// - both nil → a one-line "no credential" note that pre-emptively
///   instructs the agent to emit `auth_required` if it hits a login wall.
///
/// Critically, **the password is never an input** — the binding's
/// `password` field is only on the driver, and the agent never sees it.
enum CredentialPromptBlock {
    static func render(label: String?, username: String?) -> String {
        guard let label, let username else {
            return """
            No credential is staged for this run. If you encounter a login wall, you cannot proceed past it — emit `note_friction(kind: "auth_required", detail: "...")` and continue exploring whatever public surfaces you can reach.
            """
        }
        return """
        You have one credential staged for this run:
          - Label: "\(label)"
          - Username: "\(username)"
          - Password: (not shown — never visible to you)

        When you encounter a login form, tap/click the relevant text field to focus it, then call `fill_credential(field: "username")` or `fill_credential(field: "password")`. The runtime will type the staged value into the focused field; the password value never enters your context. After both fields are filled, submit the form like a real user would.

        If the staged credential turns out to be wrong (e.g. the app rejects it), emit `note_friction(kind: "auth_required", detail: "staged credential rejected")` and stop retrying.
        """
    }
}

struct ToolResult: Sendable, Hashable, Codable {
    let success: Bool
    let durationMs: Int
    let error: String?
    let userDecision: UserDecision?
    let userNote: String?

    init(
        success: Bool,
        durationMs: Int,
        error: String? = nil,
        userDecision: UserDecision? = nil,
        userNote: String? = nil
    ) {
        self.success = success
        self.durationMs = durationMs
        self.error = error
        self.userDecision = userDecision
        self.userNote = userNote
    }
}

enum UserDecision: String, Sendable, Hashable, Codable, CaseIterable {
    case approved
    case skipped
    case rejected
}

// MARK: - Friction

/// A flagged UX problem, emitted by the agent or synthesized by the loop.
struct FrictionEvent: Sendable, Hashable, Codable, Identifiable {
    let id: UUID
    let step: Int
    let kind: FrictionKind
    let detail: String
    let occurredAt: Date

    init(id: UUID = UUID(), step: Int, kind: FrictionKind, detail: String, occurredAt: Date = Date()) {
        self.id = id
        self.step = step
        self.kind = kind
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

/// Closed taxonomy. Matches `docs/PROMPTS/friction-vocab.md` exactly.
/// Adding a kind requires updating: this enum, the markdown, the system prompt,
/// HarnessDesign's friction styling, and `https://github.com/awizemann/harness/wiki/Agent-Loop`.
enum FrictionKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Tried a path; nothing happened or backed out.
    case deadEnd = "dead_end"

    /// A button or label's purpose was unclear from its text alone.
    case ambiguousLabel = "ambiguous_label"

    /// Tapped/interacted; no visible response within a reasonable time.
    case unresponsive

    /// Body / alert / error copy was hard to interpret.
    case confusingCopy = "confusing_copy"

    /// Saw a state the agent didn't expect from its last action.
    case unexpectedState = "unexpected_state"

    /// V5: hit a login wall the run can't proceed past — typically because
    /// no credential was staged. Distinct from `dead_end` so the friction
    /// report can surface "this run needs a stored credential to fully
    /// exercise" as its own bucket.
    case authRequired = "auth_required"

    /// Loop-synthesized. Step/token budget exhausted, cycle detected, parse-retry exhausted.
    /// NOT in the model's tool vocabulary — only the runtime emits this.
    case agentBlocked = "agent_blocked"
}

// MARK: - Verdict

enum Verdict: String, Sendable, Hashable, Codable, CaseIterable {
    case success
    case failure
    case blocked
}

// MARK: - Run summary

/// What `run_completed` carries — and what `mark_goal_done` reports.
struct RunOutcome: Sendable, Hashable, Codable {
    let verdict: Verdict
    let summary: String
    let frictionCount: Int
    let wouldRealUserSucceed: Bool
    let stepCount: Int
    let tokensUsedInput: Int
    let tokensUsedOutput: Int
    /// Cache-read tokens (≈90% off the input rate) accumulated across the
    /// run. Optional in the Codable shape so historical JSONL / decoded
    /// outcomes from before this field landed parse cleanly as 0.
    let tokensUsedCacheRead: Int
    /// Cache-creation tokens (≈1.25× input rate, the 5-minute ephemeral
    /// cache write). Same backwards-compat note as cache-read.
    let tokensUsedCacheCreation: Int
    let completedAt: Date

    init(
        verdict: Verdict,
        summary: String,
        frictionCount: Int,
        wouldRealUserSucceed: Bool,
        stepCount: Int,
        tokensUsedInput: Int,
        tokensUsedOutput: Int,
        tokensUsedCacheRead: Int = 0,
        tokensUsedCacheCreation: Int = 0,
        completedAt: Date
    ) {
        self.verdict = verdict
        self.summary = summary
        self.frictionCount = frictionCount
        self.wouldRealUserSucceed = wouldRealUserSucceed
        self.stepCount = stepCount
        self.tokensUsedInput = tokensUsedInput
        self.tokensUsedOutput = tokensUsedOutput
        self.tokensUsedCacheRead = tokensUsedCacheRead
        self.tokensUsedCacheCreation = tokensUsedCacheCreation
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case verdict, summary, frictionCount, wouldRealUserSucceed
        case stepCount, tokensUsedInput, tokensUsedOutput
        case tokensUsedCacheRead, tokensUsedCacheCreation
        case completedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.verdict = try c.decode(Verdict.self, forKey: .verdict)
        self.summary = try c.decode(String.self, forKey: .summary)
        self.frictionCount = try c.decode(Int.self, forKey: .frictionCount)
        self.wouldRealUserSucceed = try c.decode(Bool.self, forKey: .wouldRealUserSucceed)
        self.stepCount = try c.decode(Int.self, forKey: .stepCount)
        self.tokensUsedInput = try c.decode(Int.self, forKey: .tokensUsedInput)
        self.tokensUsedOutput = try c.decode(Int.self, forKey: .tokensUsedOutput)
        self.tokensUsedCacheRead = try c.decodeIfPresent(Int.self, forKey: .tokensUsedCacheRead) ?? 0
        self.tokensUsedCacheCreation = try c.decodeIfPresent(Int.self, forKey: .tokensUsedCacheCreation) ?? 0
        self.completedAt = try c.decode(Date.self, forKey: .completedAt)
    }
}

// MARK: - Run events (internal stream type)

/// What `RunCoordinator.run(_:)` emits on its `AsyncThrowingStream`.
/// Maps onto JSONL row kinds, but typed for in-process consumers.
enum RunEvent: Sendable {
    case runStarted(RunRequest)
    case buildStarted
    case buildCompleted(appBundle: URL, bundleID: String)
    case simulatorReady(SimulatorRef)
    /// Emitted at the top of a new chain leg. For single-action runs,
    /// one `legStarted` is still emitted at the top of the loop so
    /// downstream consumers can treat every run as having ≥1 leg.
    case legStarted(index: Int, actionName: String, goal: String, preservesState: Bool)
    case stepStarted(step: Int, screenshotPath: String, screenshot: URL)
    case toolProposed(step: Int, toolCall: ToolCall)
    case awaitingApproval(step: Int, toolCall: ToolCall)
    case toolExecuted(step: Int, toolCall: ToolCall, result: ToolResult)
    case frictionEmitted(FrictionEvent)
    case stepCompleted(step: Int, durationMs: Int, tokensInput: Int, tokensOutput: Int)
    /// Emitted when a leg ends, before any subsequent `legStarted` or
    /// `runCompleted`. `verdict` is one of `success | failure | blocked`
    /// for executed legs; chains synthesize `nil` here when a leg got
    /// skipped (downstream consumers read the `summary == "skipped"`
    /// string).
    case legCompleted(index: Int, verdict: Verdict?, summary: String)
    case runCompleted(RunOutcome)
}

// MARK: - User approval (step mode)

/// What the UI sends back to the loop on the approval gate.
enum UserApproval: Sendable, Hashable {
    case approve
    case skip
    case reject(note: String)
    case stop
}

// MARK: - Library snapshots
//
// Sendable value-type mirrors of the SwiftData `@Model`s under
// `Harness/Services/HarnessSchema.swift`. Views and view-models read these,
// not the `@Model`s — the `@Model` types are not `Sendable` and SwiftData
// objects must stay on the actor that owns their `ModelContext`.
//

/// Sendable mirror of the `Application` `@Model`. The `archived` flag
/// surfaces `archivedAt != nil` for view consumption.
///
/// V4 added `platformKindRaw` plus per-platform optional fields (macOS
/// .app path, web start URL + viewport). The optional fields are
/// interpreted only when `platformKind` matches; ignore them otherwise.
struct ApplicationSnapshot: Sendable, Hashable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let lastUsedAt: Date
    let archivedAt: Date?
    /// V4: platform discriminator. `nil` decodes to `.iosSimulator` via
    /// `PlatformKind.from(rawValue:)`.
    let platformKindRaw: String?
    let projectPath: String
    let projectBookmark: Data?
    let scheme: String
    let defaultSimulatorUDID: String?
    let defaultSimulatorName: String?
    let defaultSimulatorRuntime: String?
    /// V4 macOS app fields (interpreted only when `platformKind == .macosApp`).
    let macAppBundlePath: String?
    let macAppBundleBookmark: Data?
    /// V4 web app fields (interpreted only when `platformKind == .web`).
    let webStartURL: String?
    let webViewportWidthPt: Int?
    let webViewportHeightPt: Int?
    let defaultModelRaw: String
    let defaultModeRaw: String
    let defaultStepBudget: Int

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        lastUsedAt: Date,
        archivedAt: Date? = nil,
        platformKindRaw: String? = nil,
        projectPath: String,
        projectBookmark: Data? = nil,
        scheme: String,
        defaultSimulatorUDID: String? = nil,
        defaultSimulatorName: String? = nil,
        defaultSimulatorRuntime: String? = nil,
        macAppBundlePath: String? = nil,
        macAppBundleBookmark: Data? = nil,
        webStartURL: String? = nil,
        webViewportWidthPt: Int? = nil,
        webViewportHeightPt: Int? = nil,
        defaultModelRaw: String,
        defaultModeRaw: String,
        defaultStepBudget: Int
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
        self.platformKindRaw = platformKindRaw
        self.projectPath = projectPath
        self.projectBookmark = projectBookmark
        self.scheme = scheme
        self.defaultSimulatorUDID = defaultSimulatorUDID
        self.defaultSimulatorName = defaultSimulatorName
        self.defaultSimulatorRuntime = defaultSimulatorRuntime
        self.macAppBundlePath = macAppBundlePath
        self.macAppBundleBookmark = macAppBundleBookmark
        self.webStartURL = webStartURL
        self.webViewportWidthPt = webViewportWidthPt
        self.webViewportHeightPt = webViewportHeightPt
        self.defaultModelRaw = defaultModelRaw
        self.defaultModeRaw = defaultModeRaw
        self.defaultStepBudget = defaultStepBudget
    }

    var archived: Bool { archivedAt != nil }
    var defaultModel: AgentModel? { AgentModel(rawValue: defaultModelRaw) }
    var defaultMode: RunMode? { RunMode(rawValue: defaultModeRaw) }
    var projectURL: URL { URL(fileURLWithPath: projectPath) }
    /// Resolved platform kind. Reads `platformKindRaw` and falls back to
    /// `.iosSimulator` for legacy snapshots / nil values.
    var platformKind: PlatformKind { PlatformKind.from(rawValue: platformKindRaw) }
}

struct PersonaSnapshot: Sendable, Hashable, Equatable {
    let id: UUID
    let name: String
    let blurb: String
    let promptText: String
    let isBuiltIn: Bool
    let createdAt: Date
    let lastUsedAt: Date
    let archivedAt: Date?

    var archived: Bool { archivedAt != nil }
}

struct ActionSnapshot: Sendable, Hashable, Equatable {
    let id: UUID
    let name: String
    let promptText: String
    let notes: String
    let createdAt: Date
    let lastUsedAt: Date
    let archivedAt: Date?

    var archived: Bool { archivedAt != nil }
}

/// Sendable mirror of an `ActionChainStep`. `actionID == nil` means the
/// step's referenced Action was deleted (the chain shows a broken-link
/// state in Phase D's UI).
struct ActionChainStepSnapshot: Sendable, Hashable, Equatable {
    let id: UUID
    let index: Int
    let actionID: UUID?
    let preservesState: Bool
}

struct ActionChainSnapshot: Sendable, Hashable, Equatable {
    let id: UUID
    let name: String
    let notes: String
    let createdAt: Date
    let lastUsedAt: Date
    let archivedAt: Date?
    /// Ordered ascending by `index`.
    let steps: [ActionChainStepSnapshot]

    var archived: Bool { archivedAt != nil }
}
