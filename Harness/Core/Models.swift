//
//  Models.swift
//  Harness
//
//  Core domain types used across services and features. Plain values; Sendable
//  by construction. Naming matches `wiki/Glossary.md` exactly.
//
//  These are NOT the SwiftData @Model types (those live in
//  Harness/Services/RunHistoryStore.swift when that lands). These are the
//  in-memory representations passed across actor boundaries.
//

import Foundation

// MARK: - Run setup

/// What the user configures on the goal-input screen and hands to RunCoordinator.
struct GoalRequest: Sendable, Hashable, Codable {
    let id: UUID
    let goal: String
    let persona: String
    let project: ProjectRequest
    let simulator: SimulatorRef
    let model: AgentModel
    let mode: RunMode
    let stepBudget: Int
    let tokenBudget: Int

    init(
        id: UUID = UUID(),
        goal: String,
        persona: String,
        project: ProjectRequest,
        simulator: SimulatorRef,
        model: AgentModel = .opus47,
        mode: RunMode = .stepByStep,
        stepBudget: Int = 40,
        tokenBudget: Int = 250_000
    ) {
        self.id = id
        self.goal = goal
        self.persona = persona
        self.project = project
        self.simulator = simulator
        self.model = model
        self.mode = mode
        self.stepBudget = stepBudget
        self.tokenBudget = tokenBudget
    }
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

enum AgentModel: String, Sendable, Hashable, Codable, CaseIterable {
    case opus47 = "claude-opus-4-7"
    case sonnet46 = "claude-sonnet-4-6"

    var displayName: String {
        switch self {
        case .opus47: return "Opus 4.7"
        case .sonnet46: return "Sonnet 4.6"
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

enum ToolKind: String, Sendable, Hashable, Codable, CaseIterable {
    case tap, doubleTap, swipe, type, pressButton, wait, readScreen
    case noteFriction, markGoalDone
}

/// Tagged-union payload for any tool. Field names match `wiki/Tool-Schema.md`.
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
/// HarnessDesign's friction styling, and `wiki/Agent-Loop.md`.
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
    let completedAt: Date
}

// MARK: - Run events (internal stream type)

/// What `RunCoordinator.run(_:)` emits on its `AsyncThrowingStream`.
/// Maps onto JSONL row kinds, but typed for in-process consumers.
enum RunEvent: Sendable {
    case runStarted(GoalRequest)
    case buildStarted
    case buildCompleted(appBundle: URL, bundleID: String)
    case simulatorReady(SimulatorRef)
    case stepStarted(step: Int, screenshotPath: String, screenshot: URL)
    case toolProposed(step: Int, toolCall: ToolCall)
    case awaitingApproval(step: Int, toolCall: ToolCall)
    case toolExecuted(step: Int, toolCall: ToolCall, result: ToolResult)
    case frictionEmitted(FrictionEvent)
    case stepCompleted(step: Int, durationMs: Int, tokensInput: Int, tokensOutput: Int)
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
