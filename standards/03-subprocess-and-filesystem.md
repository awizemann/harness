# 03 — Subprocess & Filesystem

Applies to: **Harness**

Harness is a **non-sandboxed** developer tool. Most of its work is invoking external CLIs (`xcodebuild`, `xcrun simctl`, `idb`, `idb_companion`, `brew`) and writing artifacts to disk under `~/Library/Application Support/Harness/`. This standard defines how that's done safely, reproducibly, and cancelably.

---

## 1. Sandbox Status

App Sandbox is **off**. Distribute via Developer ID Application certificate + `xcrun notarytool`, not the App Store. Code-sign and notarize every build before sharing.

If we ever need a sandbox-friendly variant (e.g., for App Store distribution of a thinner subset), all subprocess functionality moves behind a build flag and is replaced with a "headless mode requires a CLI helper" UX. Don't build for that today.

---

## 2. Process Invocation Contract

All shell-outs go through one `ProcessRunner` **actor**. Calling `Process()` directly elsewhere in the codebase is forbidden.

```swift
struct ProcessSpec: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL?
    let standardInput: Data?
    let timeout: Duration?         // nil = no timeout
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let duration: Duration
}

actor ProcessRunner {
    func run(_ spec: ProcessSpec) async throws -> ProcessResult
    func runStreaming(_ spec: ProcessSpec) -> AsyncThrowingStream<ProcessChunk, Error>
}
```

Rules:
- The runner is the single owner of `Process` and `Pipe` lifecycle.
- Both `fileHandleForReading` and `fileHandleForWriting` on every `Pipe` are explicitly closed in `defer` blocks (per the global rule — fd leaks are real and we've been bitten).
- Non-zero exit codes are surfaced as a thrown `ProcessFailure` carrying `exitCode`, last 4 KB of stdout, last 4 KB of stderr. Never silently swallow.
- For long-running commands (e.g., `xcodebuild`), prefer `runStreaming` so the UI sees progress.

---

## 3. Cancellation

Every `ProcessRunner.run` invocation registers a cancellation handler:

1. Send `SIGTERM`.
2. Wait up to a 5-second grace period.
3. Send `SIGKILL` if the process is still alive.

Callers respect cooperative cancellation:

```swift
try Task.checkCancellation()
let result = try await runner.run(spec)
try Task.checkCancellation()
```

The agent loop, screenshot poller, and run coordinator all check cancellation at every loop iteration boundary.

---

## 4. Tool Discovery

External tools are located **once at app start** by a `ToolLocator` service:

| Tool | Strategy |
|---|---|
| `xcrun` | Always at `/usr/bin/xcrun`. |
| `xcodebuild` | Resolved via `xcrun --find xcodebuild`. |
| `simctl` | Always invoked as `xcrun simctl …` — never resolve a direct path. |
| `idb` | `which idb` after consulting `/opt/homebrew/bin`, `/usr/local/bin`. |
| `idb_companion` | Same as `idb`. Health-checked before each run. |
| `brew` | `which brew` after consulting `/opt/homebrew/bin`, `/usr/local/bin`. Used only to suggest install commands in errors — never invoked automatically. |

Missing tools surface as a single, actionable error in the first-run wizard with the exact `brew install` command to run. Never abort cryptically mid-run because `idb` was missing.

---

## 5. Working-Directory Hygiene

Every Harness run gets its own directory. Nothing pollutes the user's home or `/tmp`:

```
~/Library/Application Support/Harness/
├── runs/
│   └── <run-id>/                run-id is a UUID
│       ├── events.jsonl
│       ├── step-001.png
│       ├── step-002.png
│       ├── …
│       ├── build/               per-build derived data
│       │   └── DerivedData-<run-id>/
│       └── meta.json            redundant copy of RunRecord fields for offline replay
├── settings.json                non-secret app settings
└── tools.json                   ToolLocator cache (paths + last-verified timestamp)
```

- `xcodebuild` invocations always pass `-derivedDataPath <run-dir>/build/DerivedData-<run-id>` so different runs never share intermediate artifacts.
- The simulator is left in place between runs by default (so the user can iterate); an "erase between runs" toggle exists per project.
- All paths derive from `HarnessPaths.swift` constants. **Never hardcode `~/Library/Application Support/Harness` more than once.**

---

## 6. Path Constants

Centralized in `Harness/Core/HarnessPaths.swift`:

```swift
enum HarnessPaths {
    static let appSupport: URL = {
        try! FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
            .appendingPathComponent("Harness", isDirectory: true)
    }()

    static let runsDir = appSupport.appendingPathComponent("runs", isDirectory: true)
    static let settingsFile = appSupport.appendingPathComponent("settings.json")
    static let toolsCacheFile = appSupport.appendingPathComponent("tools.json")

    static func runDir(for id: UUID) -> URL { runsDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func eventsLog(for id: UUID) -> URL { runDir(for: id).appendingPathComponent("events.jsonl") }
    static func screenshot(for id: UUID, step: Int) -> URL {
        runDir(for: id).appendingPathComponent(String(format: "step-%03d.png", step))
    }
    static func derivedData(for id: UUID) -> URL {
        runDir(for: id)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("DerivedData-\(id.uuidString)", isDirectory: true)
    }
}
```

---

## 7. File I/O Rules

- **Never** read or write files from a `@MainActor` context (per the global rule).
- All filesystem reads in service code go through `Task.detached` if entered from a UI path; service-internal calls stay on their actor.
- View bodies never hit the filesystem. Probe once at init via `Task.detached`, store in `@State`, refresh on a meaningful trigger (per the global SwiftUI rule).
- JSONL append uses `FileHandle` with manual `seekToEndOfFile()` + `write(_:)` + `synchronize()` after each row. One writer per run; serialization is enforced by the `RunLogger` actor.

---

## 8. Output Handling

- Always close `Pipe.fileHandleForReading` AND `Pipe.fileHandleForWriting` in `defer` (global rule).
- Stream large stdout via `AsyncSequence` (`runStreaming`), not `Data` accumulation. `xcodebuild` emits hundreds of KB; we don't need it all in memory.
- For `simctl io booted screenshot`: write the PNG straight to the run dir (`xcrun simctl io booted screenshot <path>` — `simctl` writes to a path, not stdout). Read it back as `NSImage` from the screenshot view.

---

## 9. Permissions & Security-Scoped Bookmarks

Harness is non-sandboxed, so security-scoped bookmarks are not strictly required. They become required if/when we sandbox.

When the user picks an Xcode project via `NSOpenPanel`:

- Today: store the file URL directly. It's stable across launches because we're un-sandboxed.
- If sandboxed in the future: capture a security-scoped bookmark; resolve it before `xcodebuild` invocations; release on app quit. Wrap the bookmarking dance in a `ProjectAccessGrant` value type so call sites stay clean.

---

## 10. TOCTOU & Idempotency

Don't `fileExists` before idempotent operations. Let them fail and handle the error.

Bad:
```swift
if !FileManager.default.fileExists(atPath: derivedData.path) {
    try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
}
```

Good:
```swift
try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
// withIntermediateDirectories: true is idempotent — already-exists is a no-op
```

For destructive operations (e.g., `removeItem` before a fresh build), use bare `try?` with a comment, since a missing file is the desired state.

---

## 11. API Key & Keychain

The Anthropic API key is stored in the **macOS Keychain**:

- Service: `com.harness.anthropic`
- Account: `default`

A thin wrapper (`KeychainStore`) handles `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`. The key is fetched on `ClaudeClient` init and never persisted to disk. Logs never include the key (not even as `***` — we don't want it in any code path).

---

## 12. Audit Checklist

When reviewing subprocess / filesystem code:

- [ ] Is `Process()` invoked directly anywhere outside `ProcessRunner`?
- [ ] Are both `Pipe` file handles closed in `defer`?
- [ ] Is the call site cancellation-safe (`Task.checkCancellation()` before/after)?
- [ ] Does the working directory live under `HarnessPaths.runsDir`?
- [ ] Are external tool paths resolved via `ToolLocator` (not hardcoded)?
- [ ] Are non-zero exit codes thrown, not logged-and-continued?
- [ ] Does the View body avoid filesystem reads?
- [ ] Does any production code path call `print()` instead of `os.Logger`?
