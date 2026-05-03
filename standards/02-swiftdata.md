# 02 — SwiftData (scoped: Run history index only)

Applies to: **Harness**

Harness uses SwiftData for **only** the Run history index — the small, queryable record of "I ran this goal at this time against this project; verdict was X." The per-step event stream is **JSONL on disk** (cheap, append-only, replay-friendly) and is **not** modeled in SwiftData. See `14-run-logging-format.md` for the JSONL contract.

This split is deliberate: SwiftData is great for indexed lookups across many small records; it's a poor fit for streaming append of thousands of events with embedded screenshots. We use the right tool for each.

---

## 1. What lives in SwiftData

| Model | Purpose |
|---|---|
| `RunRecord` | One row per run: id, createdAt, completedAt, projectPath, scheme, simulatorRef, goalText, personaText, model, mode (step / autonomous), verdict, friction count, step count, tokensUsed, runDirectoryURL. |
| `ProjectRef` | Cached references to Xcode projects the user has aimed Harness at, so the picker has a recents list. id, path, lastUsedAt, displayName, defaultScheme, defaultSimulatorUDID. |

Everything else — per-step screenshots, observations, intents, tool calls, friction events — lives in `<runDirectoryURL>/events.jsonl` + `step-NNN.png` files. `RunRecord.runDirectoryURL` points at it.

---

## 2. Schema Versioning

Every SwiftData model change goes through `VersionedSchema` + `SchemaMigrationPlan`. No exceptions.

| Rule | Detail |
|------|--------|
| Always version | Every model or stored-property addition, removal, or rename requires a new `VersionedSchema` enum and a corresponding `MigrationStage` in the migration plan. |
| Never modify existing versions | Once a `VersionedSchema` is shipped, treat it as immutable. Create a new version instead. |
| List ALL active models | Each `VersionedSchema.models` array must contain every model that should exist after that version. Omitting a model drops its table on migration. |
| No unversioned schemas | Never pass `Schema([...])` directly to `ModelContainer`. Always use `Schema(versionedSchema:)` with `migrationPlan:`. |

```swift
// Correct
let schema = Schema(versionedSchema: HarnessSchemaV1.self)
let config = ModelConfiguration(schema: schema)
let container = try ModelContainer(
    for: schema,
    migrationPlan: HarnessMigrationPlan.self,
    configurations: [config]
)
```

Use **lightweight** stages for structural changes. Harness has no CloudKit sync today — that constraint is dormant — but stay lightweight-compatible so we keep the option open.

---

## 3. Indexing

Add `#Index` on fields that appear in predicates, sort descriptors, or frequent lookups.

| Entity | Indexed fields |
|--------|---------------|
| `RunRecord` | `createdAt`, `verdict`, `projectPath` |
| `ProjectRef` | `lastUsedAt` |

The history view sorts by `createdAt desc` and filters by verdict / project; both must be indexed.

---

## 4. Query Patterns

### Use a background actor for queries

Views must not run synchronous `@Query` for production data. Use a `RunHistoryStore` actor.

```swift
let recent = try await runHistoryStore.fetchRecentRuns(limit: 50)
await MainActor.run { self.runs = recent }
```

### Database-level filtering only

```swift
let predicate = #Predicate<RunRecord> { $0.verdict == "success" }
let descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
let results = try modelContext.fetch(descriptor)
```

In-memory filtering is forbidden for the history view — verdict / project / persona filters all map to predicates.

---

## 5. Safe Fetch

Never use bare `try?` on `modelContext.fetch()`. Use a `safeFetch` wrapper that logs and returns an empty array on failure.

```swift
let runs = runHistoryStore.safeFetch(descriptor, operation: "loading recent runs")
```

---

## 6. Data Modeling Conventions

### Primary keys

```swift
@Attribute(.unique) var id: UUID = UUID()
```

### Timestamps

```swift
var createdAt: Date = Date()
var completedAt: Date?
```

`completedAt` is set when the run finishes; absent runs are "still running" or "crashed."

### No soft delete

Run records are not auditable in the legal sense; users can hard-delete a run from the history UI. Hard delete removes the SwiftData row AND the on-disk run directory.

### URLs, not paths

Store filesystem references as `URL` (file URL), not `String`. `RunRecord.runDirectoryURL: URL`. Round-trip via security-scoped bookmarks if the project path is outside the app container — but Harness is non-sandboxed so this is not required initially.

---

## 7. Logger in @Model classes

`@Model` classes are actor-isolated, but `Logger` is not `Sendable`. Declare the logger at file scope with `nonisolated(unsafe)`:

```swift
private nonisolated(unsafe) let logger = Logger(
    subsystem: "com.harness.app",
    category: "RunRecord"
)

@Model
final class RunRecord {
    // Use `logger` freely inside the class
}
```

---

## 8. Error Handling

### `modelContext.save()`

Always wrap saves in `do/try/catch`. Save failures indicate constraint violations or disk problems.

```swift
do {
    try modelContext.save()
} catch {
    logger.error("Save failed: \(error)")
}
```

### Encode / decode

If a model encodes JSON-serializable enrichments (e.g., a structured `summary` blob), never use `try?` on encode/decode. Log the error and provide an explicit fallback.

---

## 9. What NOT to put in SwiftData

- Per-step events (use JSONL).
- Screenshots (PNGs on disk).
- Tool-call payloads (JSONL).
- Logs from `xcodebuild`, `simctl`, `idb` (write to disk under the run directory; SwiftData stores only a path).
- Anything that grows linearly with run length. SwiftData is for the **index**, not the data.
