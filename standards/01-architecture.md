# 01 — Architecture Standard

Applies to: **Harness**
Swift 6 / SwiftUI / macOS-native (single-platform, non-sandboxed dev tool)

---

## 1. MVVM-F (MVVM-Feature) Pattern

Every feature is a self-contained module that owns its **Models**, **ViewModels**, and **Views**.

```
Features/
  GoalInput/
    Models/
    ViewModels/
    Views/
  RunSession/
    Models/
    ViewModels/
    Views/
  RunHistory/
    Models/
    ViewModels/
    Views/
  RunReplay/
    Models/
    ViewModels/
    Views/
```

Rules:
- Feature modules never import or reference another feature's ViewModel directly.
- Cross-feature communication goes through **shared services** injected into each feature.
- A feature may depend on `Core/` and `Services/` but never on a sibling feature.

---

## 2. AppCoordinator

`AppCoordinator` is the **single source of truth** for all navigation state.

```swift
@Observable
final class AppCoordinator {
    var selectedSection: SidebarSection = .newRun
    var selectedRunID: UUID?
    var isReplayOpen: Bool = false
    var isSettingsOpen: Bool = false
    // ... all navigation-related state lives here
}
```

Rules:
- `AppCoordinator` is `@Observable` and injected via `.environment()` at the app root.
- All navigation mutations flow through `AppCoordinator` methods.
- Leaf views **read** coordinator state but never own independent navigation state.
- Never deep-nest `NavigationStack` inside leaf views. One `NavigationSplitView` at the top level, driven by the coordinator.

---

## 3. AppState vs AppCoordinator

These are **separate concerns**. Do not merge them.

| Concern | Owner | Examples |
|---|---|---|
| Navigation | `AppCoordinator` | `selectedSection`, `selectedRunID`, `isReplayOpen`, modal presentation flags |
| Cross-section shared state | `AppState` | API key presence, default model, default simulator, idb health, feature flags |

Rules:
- Never duplicate a navigation property in both `AppCoordinator` and `AppState`.
- `AppState` does not drive navigation. `AppCoordinator` does not hold domain data.
- Both are `@Observable` and injected via `.environment()`.

---

## 4. Directory Layout

Standard layout for Harness. Single Mac target.

```
Harness/
  App/              — App entry point, AppCoordinator, AppState, first-run wizard
  Core/             — Models, Utilities, common types (Run, Step, Action, Friction, Verdict)
  Services/         — ProcessRunner, ToolLocator, XcodeBuilder, SimulatorDriver, ClaudeClient, RunLogger, RunHistoryStore
  Features/         — GoalInput/, RunSession/, RunHistory/, RunReplay/, FrictionReport/, Settings/
  Tools/            — AgentTools.swift (the model-facing tool schema)
  Domain/           — RunCoordinator (orchestrator actor), AgentLoop
  Shared/           — Reusable components, Extensions
  Resources/        — Assets, Localizations (none initially), prompt strings (build-script-injected)
```

Each feature directory mirrors MVVM-F internally:

```
Features/
  RunSession/
    Models/         — Feature-specific data types
    ViewModels/     — Feature logic, @Observable / @MainActor
    Views/          — SwiftUI views (compose from HarnessDesign primitives)
```

---

## 5. Service Orchestration

Use the **Coordinator Pattern** to decouple UI state from background processing. The central orchestrator for one run is `RunCoordinator` — an `actor` that owns build → boot → loop → log lifecycle.

```swift
actor RunCoordinator {
    private let builder: XcodeBuilding
    private let driver: SimulatorDriving
    private let agent: AgentLooping
    private let logger: RunLogging

    init(builder: XcodeBuilding, driver: SimulatorDriving, agent: AgentLooping, logger: RunLogging) {
        self.builder = builder
        self.driver = driver
        self.agent = agent
        self.logger = logger
    }

    func run(_ goal: GoalRequest) async throws -> RunOutcome { ... }
}
```

Rules:
- Services are **injected** via initializer or environment — never accessed as global singletons.
- Background processing is orchestrated by dedicated service classes / actors, not by ViewModels.
- ViewModels call coordinator methods; they do not manage process lifecycles directly.
- Long-running operations report progress through an `AsyncThrowingStream<RunEvent, Error>` exposed by the coordinator.

---

## 6. Protocol-Driven Design

All engines and services expose **protocol interfaces**, not concrete types.

```swift
protocol XcodeBuilding: Sendable {
    func build(project: URL, scheme: String, simulator: SimulatorRef) async throws -> URL
}

protocol SimulatorDriving: Sendable {
    func boot(_ ref: SimulatorRef) async throws
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws
    func screenshot(_ ref: SimulatorRef) async throws -> NSImage
    func tap(at point: CGPoint, on ref: SimulatorRef) async throws
    // ...
}

protocol AgentLooping: Sendable {
    func step(state: LoopState) async throws -> AgentDecision
}
```

Rules:
- Define a protocol for every service boundary (process, AI, simulator, logging).
- ViewModels and orchestrators depend on protocols, not concrete implementations.
- Test suites swap real services for **protocol-conforming mocks**.
- This enables backend swappability (e.g., real `ClaudeClient` vs `RecordedClaudeClient` for replay tests).

---

## 7. @Observable Architecture

Use the `@Observable` macro exclusively. Do **not** use `ObservableObject` / `@Published` / Combine.

```swift
@Observable
final class AppState {
    var apiKeyPresent: Bool = false
    var idbHealthy: Bool = false
    var defaultSimulatorUDID: String?
}

// Injection at app root
@main struct HarnessApp: App {
    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(coordinator)
        }
    }
}
```

Rules:
- Root state objects (`AppState`, `AppCoordinator`) are injected via `.environment()`.
- Domain services are `@Observable` classes or actors.
- Views read state directly from environment objects — no Combine bindings.
- All mutations go through service or coordinator methods, not direct property writes from views.
- No Combine. Use `@Observable` + `async/await` for reactive patterns.

---

## 8. Navigation Rules

All navigation is driven by `AppCoordinator`.

```swift
NavigationSplitView {
    Sidebar(coordinator: coordinator)
} detail: {
    switch coordinator.selectedSection {
    case .newRun: GoalInputView()
    case .activeRun: RunSessionView()
    case .history: RunHistoryView()
    }
}
```

Rules:
- Use `NavigationSplitView` for the sidebar / detail layout.
- **One** `NavigationSplitView` at the top level. Never nest additional stacks inside feature views.
- Modal flows (sheets, alerts, inspectors) are presented via boolean flags on `AppCoordinator`.
- The Replay view opens as a sheet when a history row is double-clicked; flag lives on the coordinator.

---

## 9. Sandbox Status

Harness is **non-sandboxed**. App Sandbox blocks `Process` invocation of `xcodebuild`, `simctl`, and `idb` — all required. Distribute via Developer ID + notarytool, not the App Store. See `03-subprocess-and-filesystem.md` for the contract this places on subprocess handling.
