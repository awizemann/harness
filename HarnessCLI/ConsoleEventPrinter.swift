//
//  ConsoleEventPrinter.swift
//  HarnessCLI
//
//  Pretty-prints `RunEvent`s to stdout for the inner dev loop. Designed
//  to be skim-readable in a terminal while still showing the per-step
//  shape (tool call → executed → friction → completed) the GUI's
//  StepFeed shows.
//
//  Stripped of color codes / unicode that fights interactive shells.
//  PNG screenshots are written by `RunLogger` via the
//  `HarnessPaths.runsRootOverride` redirect — the printer only echoes
//  their relative filenames.
//

import Foundation

struct ConsoleEventPrinter {
    let outputDir: URL

    func print(_ event: RunEvent) {
        switch event {
        case .runStarted(let req):
            log("[run] started — model=\(req.model.rawValue) provider=\(req.model.provider.rawValue) goal=\"\(req.goal)\" persona=\"\(short(req.persona))\" budget=\(req.stepBudget) steps / \(req.tokenBudget) tokens")
        case .buildStarted:
            log("[run] buildStarted")
        case .buildCompleted(let appBundle, let bundleID):
            log("[run] buildCompleted bundle=\(bundleID) at \(appBundle.path)")
        case .simulatorReady(let ref):
            log("[run] web target ready: \(ref.name) \(Int(ref.pointSize.width))×\(Int(ref.pointSize.height))pt")
        case .legStarted(let index, _, let goal, _):
            log("[leg \(index)] started goal=\"\(short(goal))\"")
        case .stepStarted(let step, let screenshotPath, _):
            log("[step \(step)] capture=\(screenshotPath)")
        case .stepProgress(let step, let phase, _):
            log("[step \(step)] phase=\(phase.rawValue)")
        case .previewSnapshot:
            // High-frequency UI-only signal — skip in CLI output.
            break
        case .toolProposed(let step, let toolCall):
            let obs = short(toolCall.observation, limit: 120)
            let intent = short(toolCall.intent, limit: 120)
            log("[step \(step)] tool=\(toolCall.tool.rawValue) input=\(describe(toolCall.input))")
            if !obs.isEmpty { log("            obs: \(obs)") }
            if !intent.isEmpty { log("            intent: \(intent)") }
        case .awaitingApproval(let step, _):
            log("[step \(step)] awaiting approval (autonomous mode shouldn't hit this)")
        case .toolExecuted(let step, let toolCall, let result):
            let mark = result.success ? "ok" : "FAIL"
            let err = result.error.map { " err=\"\($0)\"" } ?? ""
            log("[step \(step)] executed \(toolCall.tool.rawValue) → \(mark) (\(result.durationMs)ms)\(err)")
        case .frictionEmitted(let f):
            log("[step \(f.step)] friction kind=\(f.kind.rawValue) detail=\"\(short(f.detail, limit: 200))\"")
        case .stepCompleted(let step, let durationMs, let tokensInput, let tokensOutput):
            log("[step \(step)] completed in \(durationMs)ms (in=\(tokensInput), out=\(tokensOutput))")
        case .legCompleted(let index, let verdict, let summary):
            let v = verdict?.rawValue ?? "skipped"
            log("[leg \(index)] completed verdict=\(v) summary=\"\(short(summary, limit: 200))\"")
        case .runCompleted(let outcome):
            log("[run] completed verdict=\(outcome.verdict.rawValue) steps=\(outcome.stepCount) friction=\(outcome.frictionCount) tokens=\(outcome.tokensUsedInput)in/\(outcome.tokensUsedOutput)out")
            log("[run] summary: \(outcome.summary)")
            log("[run] output: \(outputDir.path)")
        }
    }

    // MARK: Helpers

    private func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func short(_ s: String, limit: Int = 100) -> String {
        let trimmed = s.replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= limit { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<endIndex]) + "…"
    }

    private func describe(_ input: ToolInput) -> String {
        switch input {
        case .tap(let x, let y):                         return "tap(\(x),\(y))"
        case .doubleTap(let x, let y):                   return "double_tap(\(x),\(y))"
        case .swipe(let x1, let y1, let x2, let y2, let ms):
            return "swipe((\(x1),\(y1))→(\(x2),\(y2)), \(ms)ms)"
        case .type(let text):                            return "type(\"\(short(text, limit: 80))\")"
        case .pressButton(let button):                   return "press_button(\(button.rawValue))"
        case .wait(let ms):                              return "wait(\(ms)ms)"
        case .readScreen:                                return "read_screen"
        case .noteFriction(let kind, let detail):        return "note_friction(\(kind.rawValue), \"\(short(detail, limit: 80))\")"
        case .markGoalDone(let v, let s, let f, let wrus):
            return "mark_goal_done(\(v.rawValue), friction=\(f), wrus=\(wrus), \"\(short(s, limit: 80))\")"
        case .rightClick(let x, let y):                  return "right_click(\(x),\(y))"
        case .keyShortcut(let keys):                     return "key_shortcut(\(keys.joined(separator: "+")))"
        case .scroll(let x, let y, let dx, let dy):      return "scroll((\(x),\(y)), dx=\(dx), dy=\(dy))"
        case .navigate(let url):                         return "navigate(\(url))"
        case .back:                                      return "back"
        case .forward:                                   return "forward"
        case .refresh:                                   return "refresh"
        case .fillCredential(let field):                 return "fill_credential(\(field.rawValue))"
        case .tapMark(let id):                           return "tap_mark(\(id))"
        }
    }
}
