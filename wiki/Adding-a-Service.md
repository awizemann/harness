# Adding a Service

Services live under `Harness/Services/`. They expose a protocol per [`../standards/01-architecture.md §6`](../standards/01-architecture.md) and are injected (never accessed as singletons, with the rare `ToolLocator` exception).

## Recipe

### 1. Define the protocol

```swift
protocol MyServicing: Sendable {
    func doThing() async throws -> ThingResult
}
```

### 2. Pick the isolation

| Strategy | Use when |
|---|---|
| `actor` | The service has internal mutable state that must be serialized (e.g., a `FileHandle`, an in-flight subprocess). |
| `Sendable struct` | Stateless. The work is purely composing inputs into outputs (e.g., a path resolver, a JSON encoder). |
| `@MainActor @Observable class` | The service is part of the UI lifecycle (e.g., an `UpdaterService` driving Sparkle from the menu bar). |

Most Harness services are `actor` or `Sendable struct`. View-models are `@MainActor`.

### 3. Implement it

```swift
struct DefaultMyService: MyServicing {
    private let processRunner: ProcessRunning
    init(processRunner: ProcessRunning) { self.processRunner = processRunner }
    func doThing() async throws -> ThingResult { ... }
}
```

- Subprocess invocation goes through `ProcessRunner` (per [`../standards/03-subprocess-and-filesystem.md`](../standards/03-subprocess-and-filesystem.md)).
- Filesystem reads stay off `@MainActor`.
- Errors are typed (`MyServiceError.someCondition`), not raw `URLError` / `ProcessFailure` at the public API.
- Logger uses `os.Logger` with subsystem `com.harness.app` and category matching the type name.

### 4. Mock for tests

```swift
struct MockMyService: MyServicing {
    var thingResult: ThingResult = .stub
    var thingCalls: [Void] = []
    func doThing() async throws -> ThingResult { thingResult }
}
```

Mocks live in `Tests/HarnessTests/Mocks/`.

### 5. Wire injection

If the service has app-wide lifetime, instantiate at the app root and inject via `.environment(...)` or directly into the type that needs it.

If the service is per-run, the `RunCoordinator` initializer takes it.

### 6. Wiki update

**Always** add a row to [Core-Services](Core-Services.md):

| Status | Service | File | Isolation | Purpose |

If the service is non-trivial (>200 lines, multiple responsibilities, complex CLI surface, or has subtle behavioral guarantees), give it its own deep-dive page — copy the shape of [Simulator-Driver](Simulator-Driver.md).

### 7. Audit

Run [`../standards/AUDIT_CHECKLIST.md`](../standards/AUDIT_CHECKLIST.md). Pay particular attention to standard 03 (subprocess invocation rules) and standard 04 (error handling).

---

## Examples in the codebase

(Filled in as services land in Phase 1.)

- `ProcessRunner` — TBD
- `ToolLocator` — TBD
- `XcodeBuilder` — TBD
- `SimulatorDriver` — TBD
- `ClaudeClient` — TBD
- `RunLogger` — TBD
- `RunHistoryStore` — TBD
- `KeychainStore` — TBD

---

_Last updated: 2026-05-03 — initial scaffolding._
