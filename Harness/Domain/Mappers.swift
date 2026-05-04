//
//  Mappers.swift
//  Harness
//
//  Adapters between production types in `Core/Models.swift` and the
//  `Preview*` placeholder types HarnessDesign primitives accept.
//
//  Rationale: the design system was authored with mock data in `PreviewData.swift`
//  (PreviewVerdict, PreviewToolKind, PreviewToolCall, PreviewStep, PreviewRun, ...).
//  Rather than mass-edit the design package, we map at the binding layer. Cheap
//  conversions; no architectural risk; lets the design files evolve independently.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Verdict

extension PreviewVerdict {
    init(_ verdict: Verdict) {
        switch verdict {
        case .success: self = .success
        case .failure: self = .failure
        case .blocked: self = .blocked
        }
    }
}

// MARK: - Tool kind

extension PreviewToolKind {
    /// Map the production `ToolKind` to the smaller preview enum the chip
    /// already styles. Tools that have no preview equivalent fall back to
    /// `.complete` (renders generically).
    init(_ kind: ToolKind) {
        switch kind {
        case .tap, .doubleTap: self = .tap
        case .type:            self = .type
        case .swipe:           self = .swipe
        case .wait, .readScreen: self = .wait
        case .pressButton, .noteFriction, .markGoalDone:
            self = .complete
        }
    }
}

// MARK: - Tool call

extension PreviewToolCall {
    /// Render a real `ToolCall` as the chip-shaped value. The `arg` string is
    /// human-friendly: `(124, 480)`, `"milk"`, `300ms`, `← (180, 218)`.
    init(_ call: ToolCall) {
        let kind = PreviewToolKind(call.tool)
        let arg = Self.argString(for: call.input)
        self.init(kind: kind, arg: arg)
    }

    static func argString(for input: ToolInput) -> String? {
        switch input {
        case .tap(let x, let y), .doubleTap(let x, let y):
            return "(\(x), \(y))"
        case .swipe(let x1, let y1, let x2, let y2, _):
            // Direction arrow + endpoint.
            let dx = x2 - x1, dy = y2 - y1
            let arrow: String
            if abs(dx) >= abs(dy) {
                arrow = dx > 0 ? "→" : "←"
            } else {
                arrow = dy > 0 ? "↓" : "↑"
            }
            return "\(arrow) (\(x2), \(y2))"
        case .type(let text):
            // Quote and truncate long strings.
            let quoted = "\"\(text)\""
            return quoted.count > 32 ? String(quoted.prefix(31)) + "…\"" : quoted
        case .pressButton(let button):
            return button.rawValue
        case .wait(let ms):
            return "\(ms)ms"
        case .readScreen:
            return nil
        case .noteFriction(let kind, _):
            return kind.rawValue
        case .markGoalDone(let verdict, _, _, _):
            return verdict.rawValue
        }
    }
}

// MARK: - Friction kind

extension PreviewFrictionKind {
    /// The preview palette uses different rawValues from production. Map by
    /// semantic intent. The `agent_blocked` synthesized kind has no direct
    /// preview equivalent; fall back to dead-end for visual styling.
    init(_ kind: FrictionKind) {
        switch kind {
        case .deadEnd:         self = .deadEnd
        case .ambiguousLabel:  self = .ambiguousLabel
        case .unresponsive:    self = .unresponsive
        case .confusingCopy:   self = .ambiguousLabel  // closest preview palette
        case .unexpectedState: self = .missingUndo     // closest preview palette
        case .agentBlocked:    self = .deadEnd
        }
    }
}

// MARK: - Run record snapshot (production → preview shape, for SidebarRow)

extension PreviewRun {
    /// Adapt a `RunRecordSnapshot` to the shape `SidebarRow` consumes. The
    /// row only needs counts + identity + verdict, so steps/friction arrays
    /// stay empty here — the right pane parses the events.jsonl on demand.
    ///
    /// Phase E shifted the primary line: `goal` now contains the
    /// user-supplied run name (or the fallback action / chain name) so
    /// scanning the history list reads as "what I was testing" rather
    /// than the underlying prompt text. The original goal text moves
    /// into the second line via `persona`'s slot when needed.
    init(_ snapshot: RunRecordSnapshot) {
        let elapsed: String
        if let completedAt = snapshot.completedAt {
            let s = max(0, Int(completedAt.timeIntervalSince(snapshot.createdAt)))
            elapsed = String(format: "%02d:%02d", s / 60, s % 60)
        } else {
            elapsed = "—"
        }
        let mappedVerdict: PreviewVerdict = snapshot.verdict.map(PreviewVerdict.init) ?? .blocked
        // Synthesize a placeholder step entry per step so SidebarRow's
        // `run.steps.count` count renders correctly. The thumbnails / detail
        // are unused on the row.
        let stepStubs: [PreviewStep] = (0..<snapshot.stepCount).map { i in
            PreviewStep(
                n: i + 1,
                observation: "",
                intent: "",
                action: PreviewToolCall(kind: .tap, arg: nil),
                thumbnail: nil,
                friction: nil
            )
        }
        let frictionStubs: [PreviewFrictionEvent] = (0..<snapshot.frictionCount).map { i in
            PreviewFrictionEvent(
                timestamp: "",
                stepN: i + 1,
                kind: .deadEnd,
                title: "",
                detail: "",
                agentQuote: ""
            )
        }
        let modelLabel = AgentModel(rawValue: snapshot.modelRaw)?.displayName ?? snapshot.modelRaw
        let modeLabel: String = {
            switch RunMode(rawValue: snapshot.modeRaw) {
            case .stepByStep: return "Step-by-step"
            case .autonomous: return "Autonomous"
            case .none: return snapshot.modeRaw
            }
        }()
        // Primary label preference — user-supplied name first, then
        // the leg-zero action name (most recent context), then the
        // raw goal as the existing fallback.
        let primary: String = {
            if let name = snapshot.name, !name.isEmpty { return name }
            if let firstLeg = snapshot.legs.first, !firstLeg.actionName.isEmpty {
                return firstLeg.actionName
            }
            return snapshot.goal
        }()
        self.init(
            goal: primary,
            persona: snapshot.persona,
            model: modelLabel,
            mode: modeLabel,
            project: snapshot.displayName,
            scheme: "",
            device: snapshot.simulatorName,
            startedAt: "",
            elapsed: elapsed,
            stepBudget: max(snapshot.stepCount, 40),
            verdict: mappedVerdict,
            steps: stepStubs,
            friction: frictionStubs
        )
    }
}

// MARK: - Step (production → preview shape, for the StepFeedCell)

extension PreviewStep {
    /// Build a `PreviewStep` for one rendered step in the live or replay view.
    /// Thumbnails are not synthesized — pass nil if not available.
    static func make(
        n: Int,
        observation: String,
        intent: String,
        toolCall: ToolCall,
        thumbnail: NSImage? = nil,
        friction: FrictionEvent? = nil
    ) -> PreviewStep {
        PreviewStep(
            n: n,
            observation: observation,
            intent: intent,
            action: PreviewToolCall(toolCall),
            thumbnail: thumbnail,
            friction: friction.map {
                PreviewFriction(
                    kind: PreviewFrictionKind($0.kind),
                    note: $0.detail
                )
            }
        )
    }
}
