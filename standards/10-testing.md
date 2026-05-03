# 10 — Testing

Standards for writing reliable, deterministic, and maintainable tests in Harness.

---

## 1. Framework

Use the **Swift Testing** framework for all new tests:

- `@Suite` for test groupings
- `@Test` for individual test cases
- `#expect` and `#require` for assertions

Do not use XCTest for new tests.

---

## 2. Mocking

Use **protocol-oriented mocking**. Every Harness service exposes a protocol — see `01-architecture.md §6`. Tests inject mocks.

```swift
struct MockSimulatorDriver: SimulatorDriving {
    var screenshots: [NSImage] = []
    var taps: [CGPoint] = []
    func screenshot(_ ref: SimulatorRef) async throws -> NSImage { screenshots.removeFirst() }
    func tap(at point: CGPoint, on ref: SimulatorRef) async throws { taps.append(point) }
    // ...
}
```

The two highest-value mocks:

- `MockProcessRunner` — record-and-replay shell invocations, fail at specific exit codes, simulate timeouts.
- `MockClaudeClient` — return scripted tool calls in order, allowing the agent loop to be tested without network. Has a "record from real run" mode for replay-based tests (see §8).

---

## 3. Timing

**No timing-dependent tests.** Never rely on fixed `sleep` durations.

Use polling with early exit:

```swift
for _ in 0..<20 {
    if await coordinator.isComplete { break }
    try await Task.sleep(for: .milliseconds(100))
}
#expect(await coordinator.isComplete)
```

- Maximum 20 iterations at 100ms each (2s total timeout).
- Break as soon as the condition is met.
- Assert after the loop, not inside it.

---

## 4. Singleton Isolation

Shared state must be clean before each test:

1. Call the service's cleanup/reset method.
2. `await Task.yield()` to let pending work complete.
3. Then run assertions.

```swift
await ToolLocator.shared.reset()
await Task.yield()

await ToolLocator.shared.locateAll()
#expect(await ToolLocator.shared.idbPath != nil)
```

Reset shared state between tests to prevent ordering dependencies. Harness tries to avoid singletons, but `ToolLocator` and the API key keychain accessor are pragmatic exceptions.

---

## 5. Cooperative Cancellation

Verify that long-running tasks respond to `Task.isCancelled`. Particularly important for:

- The agent loop (must abort cleanly when the user clicks Stop)
- The screenshot poller (must stop when the run ends)
- `ProcessRunner` invocations (must SIGTERM the child on cancel)

```swift
let task = Task { try await coordinator.run(goal) }
try await Task.sleep(for: .milliseconds(50))
task.cancel()
let result = await task.result
// Expect cancellation, not partial state corruption
if case .failure(let error) = result {
    #expect(error is CancellationError)
}
```

---

## 6. Roundtrip Tests

**Required** for any change to the JSONL run-log format or the `RunRecord` SwiftData schema.

Every roundtrip test must:

1. Create a `Run` with all fields populated (no defaults).
2. Encode to JSONL via `RunLogger`.
3. Decode back via the replay parser.
4. Assert every field matches the original.

Do not skip optional fields — populate them with non-nil values to verify they survive the round trip. See `14-run-logging-format.md` for the schema invariants the test enforces.

---

## 7. Subprocess Integration Tests

Harness shells out to `xcodebuild`, `simctl`, and `idb`. For the `ProcessRunner` actor itself:

- Test the request/response cycle end-to-end against `/bin/echo`, `/bin/sleep`, and a fixture script in `Tests/Fixtures/`.
- Verify SIGTERM is sent on cancellation; SIGKILL after grace period.
- Verify stdout/stderr capture handles binary content (PNG bytes from screenshot).
- Verify env-var injection survives.

For `XcodeBuilder`, `SimulatorDriver`: integration tests run against a real simulator on CI/local. They are gated behind a `requiresSimulator` tag and skipped in PR builds.

---

## 8. Replay-Based Agent Tests

The most powerful test pattern in Harness: **record a real run, replay it deterministically.**

Mechanism:
1. `MockClaudeClient` records every (request, response) pair to a JSON fixture during a real run.
2. In tests, the same fixture replays — agent loop sees identical responses, takes identical actions.
3. Assertions are made on the resulting `RunOutcome`, friction count, step count, etc.

Use this for:
- Regression-testing prompt or schema changes (does the agent still solve the canonical "add milk to todo list" run?).
- Verifying friction tagging fires on UX-bug runs.
- Checking that history compaction doesn't change behavior at the truncation boundary.

Fixtures live at `Tests/HarnessTests/Fixtures/replays/<scenario>.json`. Don't store the raw screenshots inside the JSON — reference them by path; bundle the PNGs in `Resources/`.

---

## 9. Logging in Tests

**No `print()` in production code or test helpers.** Use `os.Logger`:

```swift
private let logger = Logger(subsystem: "com.harness.tests", category: "AgentLoopTests")
```

`print()` is only acceptable in `#Preview` blocks for quick debugging during development.

---

## 10. Coverage Targets

- **Pure logic** (history compaction, friction taxonomy mapping, coordinate scaling): >90% branch coverage.
- **Services** (ProcessRunner, ClaudeClient, SimulatorDriver wrappers): >70% via mocks.
- **ViewModels**: >60% — focus on state transitions, not view rendering.
- **Views**: smoke previews + a snapshot test on key states only. We don't pixel-test views.
- **Replay scenarios**: at minimum one happy-path + one blocked-path + one friction-heavy run kept green at all times.
