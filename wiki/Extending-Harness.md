# Extending Harness

Harness is designed for incremental extension. Before writing code, read the standards and understand the architecture. This guide covers the most common extension tasks.

## Adding a feature

**Location:** `Harness/Features/<FeatureName>/`

Features are self-contained, MVVM-F modules:

- **Models** — simple types, enums, computed properties. No logic.
- **ViewModels** — `@Observable` on macOS 14+; holds state and async tasks.
- **Views** — SwiftUI `View` types, only UI code and bindings; no business logic.
- **Services** — protocols for external dependencies (ProcessRunner, ToolLocator, etc.); injected via init.

### Rules

1. **Features do not import other features.** If you need to share types, move them to `Harness/Core/Models.swift` or `Harness/Domain/`.
2. **All external calls go through Services.** No `ProcessRunner` calls or file I/O directly in view-models; inject the service and call it.
3. **Testing is mandatory.** Every view-model has a test file that mocks all dependencies.

### Recipe: Add a new feature module

1. **Create the folder:**
   ```bash
   mkdir -p Harness/Features/MyFeature
   ```

2. **Add files:**
   ```
   Harness/Features/MyFeature/
     ├─ MyFeatureView.swift        # SwiftUI view
     ├─ MyFeatureViewModel.swift   # @Observable view-model
     ├─ MyFeatureModel.swift       # domain types (if needed)
     └─ MyFeatureDependencies.swift # protocol definitions
   ```

3. **Define the view-model:**
   ```swift
   import Foundation
   import Combine
   
   @Observable
   final class MyFeatureViewModel {
     let myService: MyServiceProtocol
     
     var state: MyFeatureState = .idle
     var error: Error?
     
     init(myService: MyServiceProtocol) {
       self.myService = myService
     }
     
     func performAction() async {
       state = .loading
       do {
         let result = try await myService.doSomething()
         state = .success(result)
       } catch {
         self.error = error
         state = .error
       }
     }
   }
   
   enum MyFeatureState {
     case idle
     case loading
     case success(Result)
     case error
   }
   ```

4. **Define the view:**
   ```swift
   import SwiftUI
   import HarnessDesign
   
   struct MyFeatureView: View {
     @State var viewModel: MyFeatureViewModel
     
     var body: some View {
       VStack(spacing: Theme.Spacing.medium) {
         switch viewModel.state {
         case .idle:
           Button("Start") { Task { await viewModel.performAction() } }
         case .loading:
           ProgressView()
         case .success(let result):
           Text(result.description)
         case .error:
           Text("Error: \(viewModel.error?.localizedDescription ?? "Unknown")").foregroundColor(.harness.danger)
         }
       }
       .padding(Theme.Spacing.large)
     }
   }
   ```

5. **Add tests:**
   ```bash
   mkdir -p tests/Features/MyFeature
   touch tests/Features/MyFeature/MyFeatureViewModelTests.swift
   ```

   ```swift
   import Testing
   import Foundation
   @testable import Harness
   
   @Suite("MyFeatureViewModel")
   struct MyFeatureViewModelTests {
     @Test func performActionSucceeds() async {
       let mockService = MockMyService()
       let viewModel = MyFeatureViewModel(myService: mockService)
       
       await viewModel.performAction()
       
       #expect(viewModel.state == .success(.someValue))
     }
   }
   
   class MockMyService: MyServiceProtocol {
     func doSomething() async throws -> Result {
       return .someValue
     }
   }
   ```

6. **Wire into the app:**
   - If it's a main screen (sidebar section, view in the split view), add it to `AppCoordinator` or the relevant view-model.
   - If it's a sheet / modal, add a flag to `AppCoordinator.activeSheet` and wire the presentation.
   - Update `project.yml` targets if you're adding a new Swift module (usually not needed — just add files to the main `Harness` target).
   - Test the feature manually in the Harness app.

## Adding a service

**Location:** `Harness/Services/<ServiceName>.swift`

Services are singletons (or actors for subprocess work) that are injected into view-models and other layers.

### Rules

1. **Define a protocol first.** This allows mocking in tests.
2. **Use an actor for any subprocess / filesystem / network work.** ProcessRunner is the *only* owner of `Process()`, but other I/O can be async functions in a protocol.
3. **Error types are typed.** Define a `service-specific error enum` per service (e.g., `XcodeBuilderError`, `SimulatorError`).

### Recipe: Add a new service

1. **Define the protocol:**
   ```swift
   protocol MyServiceProtocol: Sendable {
     func doSomething(with input: String) async throws -> String
   }
   ```

2. **Implement the concrete type:**
   ```swift
   actor MyService: MyServiceProtocol {
     private let logger = Logger(subsystem: "com.harness.app", category: "MyService")
     
     func doSomething(with input: String) async throws -> String {
       logger.info("Starting operation with input: \(input)")
       // Implementation
       return "result"
     }
   }
   
   enum MyServiceError: LocalizedError {
     case operationFailed(reason: String)
     
     var errorDescription: String? {
       switch self {
       case .operationFailed(let reason):
         return "Operation failed: \(reason)"
       }
     }
   }
   ```

3. **Inject it into the app:**
   - Add a property to `AppContainer` (the DI root in `Harness/App/AppContainer.swift`).
   - Pass it to view-models that need it.

   ```swift
   class AppContainer {
     let myService: MyServiceProtocol
     
     init() {
       self.myService = MyService()
     }
   }
   ```

4. **Test it:**
   ```swift
   @Suite("MyService")
   struct MyServiceTests {
     @Test func doSomethingSucceeds() async throws {
       let service = MyService()
       let result = try await service.doSomething(with: "input")
       #expect(result == "result")
     }
   }
   ```

## Adding a tool

Tools are actions the agent can invoke. They're defined in `Harness/Tools/AgentTools.swift`.

### Recipe: Add a new tool

1. **Update `AgentTools.toolDefinitions(...)`** to add a new tool definition:
   ```swift
   {
     "name": "my_new_tool",
     "description": "Does something specific to the platform.",
     "input_schema": {
       "type": "object",
       "properties": {
         "param1": { "type": "string", "description": "..." },
         "param2": { "type": "number", "description": "..." }
       },
       "required": ["param1"]
     }
   }
   ```

2. **Update the agent loop's tool execution** in `Harness/Domain/AgentLoop.swift`:
   ```swift
   case "my_new_tool":
     guard let param1 = toolCall.input["param1"] as? String else {
       // error handling
     }
     try await driver.myNewTool(param1, param2)
   ```

3. **Implement the tool on each platform driver:**
   - iOS: `SimulatorDriver` + `WDAClient` endpoint.
   - macOS: `MacAppDriver` + CGEvent / AX API.
   - Web: `WebDriver` + JS injection.

4. **Test the tool:**
   - Unit test per driver (mock the underlying API).
   - Integration test via a replay fixture (record a run, verify the tool was called).

5. **Update the wiki:** Wiki page [`Tool-Schema`](Tool-Schema) documents all tools; update it in the same PR.

## Adding friction detection

Friction kinds are tracked in `Harness/Core/Models.swift` (the `FrictionKind` enum). New kinds require updates in five places (tracked in an internal coordination doc; see CONTRIBUTING.md).

### Recipe: Add a friction kind

1. **Add to `FrictionKind` enum:**
   ```swift
   enum FrictionKind: String, Codable {
     // ...
     case myNewKind
   }
   ```

2. **Update the system prompt** (in `docs/PROMPTS/system-prompt.md`):
   ```markdown
   # Friction observations
   
   During the run, note friction using `note_friction(...)`. Examples:
   - `confusing_label` — ...
   - `myNewKind` — when [describe the condition].
   ```

3. **Update `standards/13-friction-kinds.md`** with the definition, when it's emitted, and examples.

4. **Update JSONL schema** in `standards/14-run-logging-format.md` if the event structure changes.

5. **Update wiki [`Glossary`](Glossary)** with the new kind.

## Updating standards

Standards live in `standards/` (12 numbered files). When you change a standard:

1. Edit the `.md` file (e.g., `standards/04-swift-conventions.md`).
2. Bump the date at the top (`Last updated: YYYY-MM-DD`).
3. Update the summary in `standards/INDEX.md`.
4. In your PR, reference the standard: "Standards: 04, 13".
5. In the same PR, update the wiki [`Standards-Index`](Standards-Index) page if the rule affects public surfaces.

## Updating the wiki

The wiki is a separate git repo (linked as a worktree). See [CONTRIBUTING.md](../CONTRIBUTING.md) "Working with the Wiki" for the workflow.

### Key sync rules

- **Code + wiki must sync.** If you add a tool, update `Tool-Schema`. If you add a friction kind, update the `Glossary`. If you change the JSONL format, update `Run-Replay-Format`. (See the public surfaces sync table in CONTRIBUTING.md.)
- **One topic per page.** Pages are long-form prose, not atomic facts; group related content.
- **Link across pages** using `[Page Name](Page-Name)` (dashes for spaces).
- **Version pages for clarity.** If a feature is v0.5+, note it: "(Added in v0.5)".

## Running tests

```bash
# All tests
xcodebuild test -project Harness.xcodeproj -scheme Harness

# Specific suite
xcodebuild test -project Harness.xcodeproj -scheme Harness -only-testing Harness/MyFeatureViewModelTests

# With verbose output
xcodebuild test -project Harness.xcodeproj -scheme Harness -verbose
```

## Common patterns

### Async task in a view-model

```swift
@Observable
final class MyViewModel {
  var myTask: Task<Void, Never>?
  
  func startAsyncWork() {
    myTask = Task {
      do {
        let result = try await service.doSomething()
        // Update state
      } catch {
        // Handle error
      }
    }
  }
  
  deinit {
    myTask?.cancel()
  }
}
```

### Testing with mocks

```swift
class MockService: ServiceProtocol {
  var didCallDoSomething = false
  var resultToReturn = "default"
  
  func doSomething() async throws -> String {
    didCallDoSomething = true
    return resultToReturn
  }
}

// In test:
let mock = MockService()
mock.resultToReturn = "custom"
let vm = MyViewModel(service: mock)
await vm.performAction()
#expect(mock.didCallDoSomething)
```

### Design token usage

```swift
import HarnessDesign

struct MyView: View {
  var body: some View {
    VStack(spacing: Theme.Spacing.medium) {
      Text("Title")
        .font(HFont.heading1)
        .foregroundColor(.harness.text)
      
      Button(action: {}) {
        Text("Action")
      }
      .padding(Theme.Spacing.large)
      .background(Color.harness.primary)
      .cornerRadius(Theme.BorderRadius.medium)
    }
  }
}
```

## Debugging

### View the logs

```bash
# Real-time log stream for the app
log stream --predicate 'subsystem == "com.harness.app"'

# Look for a specific category
log stream --predicate 'subsystem == "com.harness.app" and category == "ProcessRunner"'
```

### Access run files

```bash
# List all runs
open ~/Library/Application\ Support/Harness/runs/

# View a specific run's JSONL log
cat ~/Library/Application\ Support/Harness/runs/<run-id>/events.jsonl | jq .
```

### Use the CLI for iteration

The `harness-cli` tool shares the same source as the GUI app and runs against the same drivers. It's fast for iterating on prompts and agent logic without rebuilding the Mac app:

```bash
xcodebuild -project Harness.xcodeproj -scheme harness-cli build
./build/Release/harness-cli --goal "Sign up" --persona "First-time user"
```

See the [`HarnessCLI`](HarnessCLI) wiki page for details.