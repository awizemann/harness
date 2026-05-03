# 09 — Performance

Patterns for keeping SwiftUI views responsive, agent loops cheap, and memory bounded.

---

## 1. Component Extraction Pattern

### Problem

SwiftUI views with high complexity (1000+ lines, dozens of `@State` variables) cause slow task scheduling and expensive view reconciliation. The `RunSessionView` is the most at-risk surface (live mirror + step feed + approval card + status chips, all updating concurrently).

### Solution: Isolated Components

Break monolithic views into isolated child components. The parent becomes a lightweight coordinator with minimal state. Each child owns its section-specific state locally.

```
RunSessionView (minimal state — coordinator + viewmodel)
  |- RunMetadataPane (left rail; reads goal/persona/status)
  |- SimulatorMirrorView (center; owns screenshot @State + last-tap dot)
  |- StepFeedView (right rail; owns scroll/selection state)
  `- ApprovalCard (overlay; owns its own focus/keyboard state)
```

Each is a separate file in `Features/RunSession/Views/`.

### Implementation Steps

1. **Identify state to extract** (section-specific): scroll position, last-rendered screenshot, animation state for the tap dot.

2. **Keep in parent** (shared across sections): the active `RunSessionViewModel`, navigation flags.

3. **Create a dedicated view file** for each region:
   - Receive view-model from environment or initializer
   - Use local `@State` for section-specific state
   - Use callbacks for parent actions (`onApprove`, `onReject`)

4. **`.task(id:)` must include ALL dependencies:**
   ```swift
   .task(id: "\(runID)-\(stepIndex)-\(mode)") {
       await refreshFromCoordinator()
   }
   ```
   Forgetting any dependency means changing it will not trigger a reload.

5. **Use `@ViewBuilder` computed properties** for complex toolbars and conditional layouts to prevent SwiftUI type-checker timeouts.

---

## 2. State Ownership Matrix

| Owner | State |
|-------|-------|
| **Component owns** | Scroll positions, animation state, hover/focus state, debounce timers |
| **Parent owns** | The `RunSessionViewModel`, `AppCoordinator` flags, currently-selected run |
| **Pass as bindings** | Search text, filter dimension shared across multiple history sections |
| **Pass as callbacks** | Approval / rejection / stop actions |

Target: ~10 `@State` variables per view. If a view exceeds this, it's a candidate for extraction.

---

## 3. Background Work Patterns

All views should use background actor work instead of synchronous data store calls.

```swift
// Background actor query
let runs = try await runHistoryStore.fetchRecentRuns(limit: 50)
// Main thread state update
await MainActor.run { self.runs = runs }
```

For run streaming, the `RunCoordinator` exposes an `AsyncThrowingStream<RunEvent, Error>` consumed by the view-model with `for await event in stream`. The view-model maps `RunEvent` to view state on `@MainActor`.

---

## 4. View Complexity Limits

| Metric | Guideline |
|--------|-----------|
| `@State` variables per view | ~10 (target) |
| Service file size | ~1,000 lines max |
| View file size | ~800 lines max |
| ViewModel file size | ~600 lines max |

When the Swift type-checker times out on a view body, extract sub-expressions into `@ViewBuilder` computed properties or separate files.

---

## 5. Memory Management

- **`autoreleasepool`** in any loop processing screenshots or PNG data. Synchronous only — no `await` inside the pool.
- **No `Date()` allocations in hot paths** without `#if DEBUG`. Use `os_signpost` intervals for production performance measurement.
- **Cap screenshot dimensions** before sending to Claude. Downscale to ≤1024px on the long edge in `ClaudeClient` — see `13-agent-loop.md` for the cost rationale.
- **Never cache full screenshot history in memory.** The replay view loads PNGs lazily by step index; only the visible screenshots are resident.
- **Drop the screenshot poller's previous frame** before storing the new one; never accumulate.

---

## 6. Agent Loop Cost Patterns

Distinct from view performance — this is about token + latency cost per run.

| Pattern | Detail |
|---|---|
| Screenshot downscale | 1024px long edge, JPEG q=0.85 (`ImageEncoder` style). Cuts Claude image-token cost by ~4x vs native retina. |
| Prompt caching | System prompt + persona + goal are cached on the first call; per-step calls only pay for the new screenshot + last few turns. See `07-ai-integration.md`. |
| History truncation | Keep last 6 (observation, intent, action, screenshot) tuples; older screenshots dropped first; older text reasoning retained until a token budget threshold is hit. |
| Step budget | Default 40 steps per run. Configurable. Hard ceiling 200. |
| Cycle detector | If the perceptual hash of the screenshot is unchanged across 3 consecutive steps and the model emits the same tool call, force `mark_goal_done(blocked, "stuck — no UI progress")`. |
| Token budget | Per-run cap (default 250k input tokens for Opus, 1M for Sonnet). Loop short-circuits with `mark_goal_done(blocked, "token budget exhausted")`. |

---

## 7. Live Mirror Polling

The simulator mirror polls `xcrun simctl io booted screenshot` at ~3 fps. Higher rates noticeably load the simulator without improving the experience.

- Poll on a `Task.detached` loop with `Task.sleep(for: .milliseconds(333))` between frames.
- Cancel the poller when the run ends or the view disappears.
- Skip a frame if the previous PNG decode is still in flight (drop, don't queue).
- Cache the last `NSImage` in the view-model; the view binds to it via `@Observable`.

---

## 8. Refactoring Priority Matrix

```
HIGH IMPACT + LOW RISK = DO FIRST
|- Extract shared components (StepFeedCell, ToolCallChip, etc. live in HarnessDesign)
|- Centralize ProcessRunner so cancellation propagates uniformly
`- Async screenshot poller off MainActor

HIGH IMPACT + MEDIUM RISK = DO NEXT
|- Prompt caching wiring in ClaudeClient
|- History compaction strategy in AgentLoop
`- Cycle detector

MEDIUM IMPACT + MEDIUM RISK = DO LATER
|- Replay-time perceptual diff overlay
`- Multi-screenshot batching for sub-second sequences
```

### Metrics to Track

| Metric | Target |
|--------|--------|
| RunSessionView re-render cost during streaming | < 16ms / frame |
| Screenshot poll → mirror update latency | < 400ms |
| Per-step Claude latency (Sonnet, cached) | < 4s p50 |
| Per-step Claude latency (Opus, cached) | < 8s p50 |
| Tokens per step (cached) | < 5k input |
| Memory resident during a 40-step run | < 250 MB |
