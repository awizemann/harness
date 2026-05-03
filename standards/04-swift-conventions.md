# 04 — Swift Conventions

Applies to: **Harness**
Swift 6 / SwiftUI / macOS-native

---

## 1. Swift 6 Concurrency Rules

| Rule | Details |
|------|---------|
| Shared mutable state | Must be `@MainActor` or actor-isolated. No unprotected shared vars. |
| `@Sendable` closures | All closures in `Task`, `Task.detached`, and `withCheckedThrowingContinuation` must be `@Sendable`. |
| async/await | Prefer over callbacks and closures in all new code. |
| Progress reporting | Use `AsyncThrowingStream`, not callback-based progress handlers. The `RunCoordinator.run(_:)` API returns one. |
| DispatchQueue | Never use when Swift Concurrency works. No `DispatchQueue.main.async` — use `@MainActor` instead. |
| File I/O on @MainActor | Prohibited. Dispatch via `Task.detached { }.value` or an async file manager. View bodies never touch the filesystem (per your global rule). |
| Subprocess invocation | Prohibited on `@MainActor`. Goes through `ProcessRunner` actor only — see `03-subprocess-and-filesystem.md`. |
| Boolean flags | Use `os_unfair_lock` for thread-safe boolean flags (not `NSLock`). |
| Cancellation in long loops | Check `Task.isCancelled` (or `try Task.checkCancellation()`) at the top of each iteration. The agent loop and screenshot poller both follow this rule. |
| Logger in @Model classes | `private nonisolated(unsafe) let logger = Logger(...)` at file scope. Required because `@Model` classes are not Sendable. |

---

## 2. Logging Standard

**No `print()` in production code.** Use `os.Logger` exclusively.
`print()` is only acceptable in `#Preview` blocks and test helpers.

### Subsystem and Category

- **Subsystem**: `"com.harness.app"` — always a static string literal.
- **Category**: The type name (e.g., `"RunCoordinator"`, `"SimulatorDriver"`, `"AgentLoop"`).

### Declaration Patterns

| Context | Declaration | Access |
|---------|-------------|--------|
| Class or actor | `private let logger = Logger(subsystem: "com.harness.app", category: "ClassName")` | `logger` |
| Struct or SwiftUI view | `private static let logger = Logger(subsystem: "com.harness.app", category: "StructName")` | `Self.logger` |
| Nested struct | Declares its own `private static let logger`. Cannot reference the parent's `Self.logger`. | `Self.logger` |
| `@Model` class | `private nonisolated(unsafe) let logger = Logger(subsystem: "com.harness.app", category: "ModelName")` | `logger` |

### Enum Interpolation

`os.Logger` string interpolation requires types conforming to specific protocols. For enums and other non-conforming types:

```swift
logger.info("Verdict: \(String(describing: verdict))")
```

### Log Levels

| Level | Use |
|-------|-----|
| `.info` | Normal operational flow (run started, step N completed, tool dispatched) |
| `.warning` | Expected failures (idb daemon restart, screenshot retry, build cache miss) |
| `.error` | Unexpected failures (tool schema mismatch, JSONL write failure, assertion violation) |
| `.debug` | Verbose output (full Claude request bodies, raw stdout — debug builds only) |

### Never Log

- Anthropic API key, even partial.
- Full raw screenshots (path is fine; bytes are not).
- Anything from the user's project source unless explicitly requested for diagnostics.

---

## 3. Error Handling

### Catch Blocks

Every `catch` must do at least one of:

1. Log with `logger.error()` or `logger.warning()`
2. Re-throw
3. Return `Result.failure`

**No empty catch blocks.** Ever.

### Subprocess errors

`ProcessRunner` returns `ProcessResult` with `exitCode`. Treat non-zero exit as a thrown `ProcessFailure` carrying stdout/stderr; never silently swallow a non-zero exit.

### Bare try?

Acceptable only for truly ignorable operations:

- `try? await Task.sleep(...)`
- `try? FileManager.default.removeItem(...)` before an overwrite
- Other idempotent operations

**Always add a comment explaining why the error is ignorable.**

### Multi-Step Operations

Any operation with 3+ sequential steps that modify state (build → install → boot → launch) must:

- Implement rollback (e.g., terminate sim if launch fails after boot), **or**
- Be idempotent

Verification after the operation must throw on failure (not just log) so the caller can roll back.

---

## 4. File Size Limits

| File type | Max lines | Action when approaching limit |
|-----------|-----------|-------------------------------|
| Services | ~1,000 | Extract helper types |
| Views | ~800 | Extract sub-views into separate files; move single-use `@State` into the sub-view |
| ViewModels | ~600 | Split orchestration vs presentation logic |

### Extraction Pattern

Prefer `@MainActor enum HelperName` with static methods for stateless extraction:

```swift
@MainActor
enum FrictionFormatter {
    static func summary(for friction: [FrictionEvent]) -> String {
        // ...
    }
}
```

---

## 5. Anti-Patterns — What NOT to Do

| Anti-Pattern | Correct Approach |
|-------------|-----------------|
| Force unwrapping (`!`) | Use `guard let`, `if let`, or nil-coalescing. |
| `DispatchQueue.main.async` | Use `@MainActor` |
| Combine (`ObservableObject` / `@Published`) | Use `@Observable` macro + async/await |
| UIKit types | macOS uses AppKit: `NSImage`, `NSWorkspace`, etc. |
| Hardcoded paths | Centralize in `HarnessPaths.swift`. Never write `~/Library/Application Support/Harness` more than once. |
| Synchronous file I/O on main thread | Dispatch via `Task.detached` |
| Synchronous filesystem reads in View bodies | Probe once via `Task.detached`, store in `@State`, refresh on a meaningful trigger. |
| `print()` in production | Use `os.Logger` |
| Bare `try?` on important operations | Use `do/try/catch` with logging. |
| `Date()` allocations in hot paths | Use `os_signpost` or gate behind `#if DEBUG`. |
| `NSLock` for simple flags | `os_unfair_lock` |
| Calling `Process()` outside `ProcessRunner` | All shell invocation goes through the actor — see standard 03. |
| Embedding the system prompt as a Swift string literal | Load from `docs/PROMPTS/system-prompt.md` via build script. One source of truth. |

---

## 6. SwiftUI View Body Hygiene

Per the global rule and our reality: View bodies re-evaluate many times per second during streaming/animation. Each re-evaluation that hits the filesystem, spawns a `Process`, or reads from a network is a per-frame cost. Symptom: UI flickers blank during state updates.

- No `FileManager.fileExists` in a body.
- No `String(contentsOfFile:)` in a body.
- No `Process()` in a body.
- No computed property reading the filesystem from a body.
- Probe once at init via `Task.detached`, store the result in `@State` / a stored property, refresh on a meaningful trigger.

The same rule applies to ViewModel `load()` methods that any View body calls — wrap in `Task.detached { … } / await MainActor.run { … }`.

---

## 7. AppKit interop

Where SwiftUI gaps exist (window chrome, drag-and-drop of file URLs, system file pickers), use AppKit directly. Wrap in `NSViewRepresentable` only when SwiftUI cannot express the surface natively.

- File pickers: `NSOpenPanel` directly.
- Tool tips with rich content: AppKit `NSPopover` over a custom `NSViewRepresentable`.
- Screenshots displayed in `SimulatorMirrorView`: load as `NSImage` (PNG); render via `Image(nsImage:)`.
