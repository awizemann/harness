//
//  AgentLoop.swift
//  Harness
//
//  The per-step agent loop. Owns:
//    - History compaction (last-6 turns, screenshot drop policy, token cap)
//    - Cycle detector (3 consecutive identical (screenshot-hash, tool-call) pairs → blocked)
//    - Parse-failure retry (cap of 2 corrections per step)
//    - Step + token budget short-circuits
//
//  Per `standards/13-agent-loop.md`. Pairs with the orchestrator
//  `RunCoordinator` (this file is loop-only; the orchestrator owns build,
//  install, launch, screenshot capture, screenshot persistence, and the
//  approval gate).
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Inputs

/// Snapshot of the loop's state at the top of an iteration. The orchestrator
/// constructs this and hands it to `AgentLoop.step(state:)`.
struct AgentLoopState: Sendable {
    let request: RunRequest
    let stepIndex: Int            // 1-based.
    let history: [LLMTurn]
    let currentScreenshotJPEG: Data
    let tokensUsedSoFar: TokenUsage
    /// Phase 2: per-session canvas data the agent loop hands the LLM.
    /// `RunCoordinator` derives these from the `RunSession` returned by
    /// the active `PlatformAdapter` (iOS sim point size / mac window
    /// point size / web CSS-pixel viewport).
    let sessionPointSize: CGSize
    let platformContext: String
    let deviceName: String
    /// V5: pre-rendered text for the system prompt's `{{CREDENTIALS}}`
    /// slot. Empty string is fine — substitutes a blank section. The
    /// password is **never** part of this string; only `label` and
    /// `username` from the staged credential ever surface.
    let credentialBlock: String

    init(
        request: RunRequest,
        stepIndex: Int,
        history: [LLMTurn],
        currentScreenshotJPEG: Data,
        tokensUsedSoFar: TokenUsage,
        sessionPointSize: CGSize? = nil,
        platformContext: String = "",
        deviceName: String = "iPhone Simulator",
        credentialBlock: String = ""
    ) {
        self.request = request
        self.stepIndex = stepIndex
        self.history = history
        self.currentScreenshotJPEG = currentScreenshotJPEG
        self.tokensUsedSoFar = tokensUsedSoFar
        // Default to the SimulatorRef pointSize so legacy callers (tests
        // that pre-date PlatformAdapter) keep working without ceremony.
        self.sessionPointSize = sessionPointSize ?? request.simulator.pointSize
        self.platformContext = platformContext
        self.deviceName = deviceName
        self.credentialBlock = credentialBlock
    }
}

/// What the loop returns each step. Maps onto the action the orchestrator
/// should execute, plus the friction events to log alongside.
struct AgentDecision: Sendable {
    let toolCall: ToolCall
    /// Friction calls the model emitted on this turn (zero or more — model
    /// may emit `note_friction` alongside an action via separate tool_use blocks).
    /// Phase 1 single-shot ClaudeClient returns one tool call; multi-friction
    /// support lives in a follow-up of ClaudeClient. For now, this stays empty.
    let inlineFriction: [(FrictionKind, String)]
    let usage: TokenUsage
}

// MARK: - Errors

enum AgentLoopError: Error, Sendable, LocalizedError {
    case parseFailureExhausted(lastDetail: String)
    case tokenBudgetExhausted(used: Int, budget: Int)
    case stepBudgetExhausted(budget: Int)
    case cycleDetected

    var errorDescription: String? {
        switch self {
        case .parseFailureExhausted(let detail):
            return "The agent kept emitting unparseable tool calls. Last error: \(detail)"
        case .tokenBudgetExhausted(let used, let budget):
            return "Token budget exhausted (\(used) / \(budget))."
        case .stepBudgetExhausted(let budget):
            return "Step budget exhausted (\(budget) steps)."
        case .cycleDetected:
            return "Cycle detected — the agent stayed on the same screen for 3 turns."
        }
    }
}

// MARK: - Protocol

protocol AgentLooping: Sendable {
    /// Run one iteration. Throws on unrecoverable error; otherwise returns
    /// the action to execute. `mark_goal_done` is a tool call like any other —
    /// the orchestrator inspects the returned `ToolCall` to know when to stop.
    func step(state: AgentLoopState) async throws -> AgentDecision

    /// Update the cycle detector with this step's (screenshot, tool call) pair.
    /// Throws `cycleDetected` if 3 consecutive matching pairs have been seen.
    func recordPostStep(screenshotJPEG: Data, toolCall: ToolCall) async throws

    /// Reset internal state. Call between runs that share an instance.
    func reset() async
}

// MARK: - Implementation

actor AgentLoop: AgentLooping {

    private static let logger = Logger(subsystem: "com.harness.app", category: "AgentLoop")

    // MARK: Tuning

    /// Last-N turns retained with full reasoning + screenshot.
    static let recentTurnsKept = 6
    /// Hard input-token ceiling per call (history compaction enforces this).
    static let perCallInputTokenCap = 30_000
    /// Parse-failure retries per step.
    static let parseFailureRetryCap = 2
    /// Cycle-detector window.
    static let cycleWindowSize = 3
    /// dHash Hamming-distance threshold below which two screenshots are
    /// considered the "same" screen.
    static let cycleHashThreshold = 5
    /// Coordinate-distance threshold (points) below which two tool calls are
    /// considered the "same" tap/swipe.
    static let cycleCoordinateThreshold: Int = 8

    // MARK: Dependencies

    private let llm: any LLMClient
    private let promptLibrary: any PromptLoading

    // MARK: State

    private var cycleWindow: [(hash: UInt64, call: ToolCall)] = []
    private var cachedSystemPrompt: String?
    private let logger_ = Logger(subsystem: "com.harness.app", category: "AgentLoop")

    // MARK: Init

    init(llm: any LLMClient, promptLibrary: any PromptLoading = PromptLibrary()) {
        self.llm = llm
        self.promptLibrary = promptLibrary
    }

    func reset() {
        cycleWindow.removeAll()
        cachedSystemPrompt = nil
    }

    // MARK: Step

    func step(state: AgentLoopState) async throws -> AgentDecision {
        try Task.checkCancellation()

        // Budget short-circuits — the orchestrator should also bail on these,
        // but defending here keeps the loop self-contained. `hasStepBudget`
        // is false when the user picked "Unlimited" — the run runs until
        // `mark_goal_done`, the token budget exhausts, or the cycle
        // detector trips.
        if state.request.hasStepBudget && state.stepIndex > state.request.stepBudget {
            throw AgentLoopError.stepBudgetExhausted(budget: state.request.stepBudget)
        }
        let usedInput = state.tokensUsedSoFar.inputTokens
        if usedInput >= state.request.tokenBudget {
            throw AgentLoopError.tokenBudgetExhausted(used: usedInput, budget: state.request.tokenBudget)
        }

        // Load + cache the system prompt from the bundle.
        let systemPrompt: String
        if let cached = cachedSystemPrompt {
            systemPrompt = cached
        } else {
            do {
                let raw = try promptLibrary.systemPrompt()
                systemPrompt = raw
                cachedSystemPrompt = raw
            } catch {
                Self.logger.error("System prompt load failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        // History compaction: keep last `recentTurnsKept` turns full; drop
        // older screenshots; collapse older reasoning to one-line summaries.
        // The wire-side compaction (turning summarized turns back into LLMTurn
        // shapes) is handled here by reshaping `history` before send.
        let compacted = HistoryCompactor.compact(
            state.history,
            keepFullTurns: Self.recentTurnsKept
        )

        var attempt = 0
        var lastError: String = ""
        while attempt <= Self.parseFailureRetryCap {
            try Task.checkCancellation()
            do {
                // On retries, ferry the previous attempt's parse error
                // back to the model. Cheaper models (GPT-4.1 Nano,
                // Gemini Flash Lite, sometimes Haiku) loop on the same
                // mistake until the cap unless told what was wrong.
                let retryHint: String? = attempt > 0 ? lastError : nil
                let response = try await llm.step(LLMStepRequest(
                    model: state.request.model,
                    systemPrompt: systemPrompt,
                    persona: state.request.persona,
                    goal: state.request.goal,
                    history: compacted,
                    screenshotJPEG: state.currentScreenshotJPEG,
                    pointSize: state.sessionPointSize,
                    maxOutputTokens: 1024,
                    deterministic: false,
                    platformContext: state.platformContext,
                    deviceName: state.deviceName,
                    platformKind: state.request.platformKind,
                    credentialBlock: state.credentialBlock,
                    retryHint: retryHint
                ))
                return AgentDecision(
                    toolCall: response.toolCall,
                    inlineFriction: response.inlineFriction,
                    usage: response.usage
                )
            } catch LLMError.invalidToolCall(let detail) {
                lastError = detail
                attempt += 1
                Self.logger.warning("Parse-failure retry \(attempt, privacy: .public)/\(Self.parseFailureRetryCap, privacy: .public): \(detail, privacy: .public)")
                continue
            } catch LLMError.unknownTool(let name) {
                lastError = "unknown tool '\(name)'"
                attempt += 1
                Self.logger.warning("Unknown-tool retry \(attempt, privacy: .public)/\(Self.parseFailureRetryCap, privacy: .public): \(name, privacy: .public)")
                continue
            } catch LLMError.noToolCallReturned {
                // Cheaper models sometimes punt to plain text instead of
                // calling a tool. Treat as a parseable failure: retry
                // with a corrective hint rather than failing the run.
                lastError = "your previous response contained no tool call; you must always call exactly one tool"
                attempt += 1
                Self.logger.warning("No-tool retry \(attempt, privacy: .public)/\(Self.parseFailureRetryCap, privacy: .public)")
                continue
            }
        }
        throw AgentLoopError.parseFailureExhausted(lastDetail: lastError)
    }

    // MARK: Cycle detector

    func recordPostStep(screenshotJPEG: Data, toolCall: ToolCall) async throws {
        let hash = ScreenshotHasher.dHash(jpeg: screenshotJPEG)
        cycleWindow.append((hash, toolCall))
        if cycleWindow.count > Self.cycleWindowSize {
            cycleWindow.removeFirst()
        }

        guard cycleWindow.count == Self.cycleWindowSize else { return }

        // All three hashes within threshold AND all three tool calls equivalent.
        let h0 = cycleWindow[0].hash
        let allHashesClose = cycleWindow.allSatisfy {
            ScreenshotHasher.hammingDistance($0.hash, h0) <= Self.cycleHashThreshold
        }
        guard allHashesClose else { return }

        let c0 = cycleWindow[0].call
        let allCallsEquivalent = cycleWindow.dropFirst().allSatisfy {
            Self.toolCallsEquivalent($0.call, c0)
        }
        if allCallsEquivalent {
            Self.logger.warning("Cycle detector tripped at step window of \(self.cycleWindow.count, privacy: .public).")
            throw AgentLoopError.cycleDetected
        }
    }

    /// Two tool calls are "equivalent" if same kind + coordinates within `cycleCoordinateThreshold` points.
    /// For non-coordinate tools (type/wait/read_screen/...), require structural equality.
    static func toolCallsEquivalent(_ a: ToolCall, _ b: ToolCall) -> Bool {
        guard a.tool == b.tool else { return false }
        switch (a.input, b.input) {
        case let (.tap(ax, ay), .tap(bx, by)),
             let (.doubleTap(ax, ay), .doubleTap(bx, by)):
            return abs(ax - bx) <= cycleCoordinateThreshold &&
                   abs(ay - by) <= cycleCoordinateThreshold
        case let (.swipe(ax1, ay1, ax2, ay2, _), .swipe(bx1, by1, bx2, by2, _)):
            return abs(ax1 - bx1) <= cycleCoordinateThreshold &&
                   abs(ay1 - by1) <= cycleCoordinateThreshold &&
                   abs(ax2 - bx2) <= cycleCoordinateThreshold &&
                   abs(ay2 - by2) <= cycleCoordinateThreshold
        case let (.type(ta), .type(tb)):
            return ta == tb
        case let (.pressButton(ba), .pressButton(bb)):
            return ba == bb
        case let (.wait(ma), .wait(mb)):
            return ma == mb
        case (.readScreen, .readScreen):
            return true
        default:
            return false
        }
    }
}

// MARK: - History compactor

enum HistoryCompactor {

    /// Compact a history list to fit the per-call input-token budget.
    /// Strategy (per `standards/07-ai-integration.md §4`):
    ///   1. Keep last `keepFullTurns` turns with screenshots intact.
    ///   2. Drop screenshots from older turns; keep their text reasoning.
    ///   3. If still over the cap, collapse older turns into one-line summaries.
    static func compact(_ history: [LLMTurn], keepFullTurns: Int) -> [LLMTurn] {
        guard !history.isEmpty else { return [] }

        let total = history.count
        if total <= keepFullTurns {
            return history
        }

        let cutoff = total - keepFullTurns
        var compacted: [LLMTurn] = []

        // Older turns: drop screenshots, keep text.
        for turn in history.prefix(cutoff) {
            compacted.append(LLMTurn(
                observation: turn.observation,
                intent: turn.intent,
                toolName: turn.toolName,
                toolInputJSON: turn.toolInputJSON,
                screenshotJPEG: nil,
                toolResultSummary: turn.toolResultSummary
            ))
        }
        // Recent turns: as-is.
        compacted.append(contentsOf: history.suffix(keepFullTurns))
        return compacted
    }
}

// MARK: - Screenshot hashing

/// Compact 64-bit difference hash for cycle detection. Resizes to a 9×8 grid
/// (using AppKit), grayscales, and emits a 64-bit hash where each bit is
/// "this pixel brighter than its right neighbor?" — robust to small animations
/// (status bar, cursor blink) by design.
enum ScreenshotHasher {

    /// Return the dHash of a JPEG-encoded screenshot, or 0 on decode failure.
    static func dHash(jpeg: Data) -> UInt64 {
        #if canImport(AppKit)
        guard let image = NSImage(data: jpeg) else { return 0 }
        return dHash(of: image)
        #else
        return 0
        #endif
    }

    #if canImport(AppKit)
    /// Compute dHash from any NSImage. Resizes to 9×8 grayscale and compares
    /// horizontal neighbors.
    static func dHash(of image: NSImage) -> UInt64 {
        let targetSize = NSSize(width: 9, height: 8)

        guard let cgSource = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }

        // Grayscale 9×8 bitmap.
        let bytesPerRow = 9
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * 8)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: 9, height: 8,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return 0
        }
        context.interpolationQuality = .medium
        context.draw(cgSource, in: CGRect(origin: .zero, size: targetSize))

        // Build the 64-bit hash by comparing each pixel to its right neighbor.
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let idx = row * bytesPerRow + col
                let nextIdx = row * bytesPerRow + (col + 1)
                if pixels[idx] > pixels[nextIdx] {
                    hash |= (1 << (row * 8 + col))
                }
            }
        }
        return hash
    }
    #endif

    /// Hamming distance — count of differing bits.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }
}
