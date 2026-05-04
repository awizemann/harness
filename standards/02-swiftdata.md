# 02 — SwiftData (scoped: Run history index + workspace library)

Applies to: **Harness**

Harness uses SwiftData for the Run history index **and** the small library entities the workspace rework introduces (Applications, Personas, Actions, Action Chains). The per-step event stream stays as **JSONL on disk** (cheap, append-only, replay-friendly) and is **not** modeled in SwiftData. See `14-run-logging-format.md` for the JSONL contract.

This split is deliberate: SwiftData is great for indexed lookups across many small records; it's a poor fit for streaming append of thousands of events with embedded screenshots. We use the right tool for each.

---

## 1. What lives in SwiftData

| Model | Purpose |
|---|---|
| `RunRecord` | One row per run. Identity + timestamps; denormalized snapshot of the goal context (projectPath, scheme, simulator*, goal, persona text, modelRaw, modeRaw); outcome (verdictRaw, summary, stepCount, frictionCount, tokens*); on-disk `runDirectoryPath`. Plus optional refs (`application`, `persona_`, `action`, `actionChain`) that wire the run back to the library entities — all `.nullify` on referent delete so the denormalized snapshot fields keep history readable forever. Optional `name` is the user-supplied or auto-generated run name surfaced in History. |
| `Application` | A saved per-project workspace. id, name, createdAt, lastUsedAt, archivedAt?, projectPath, projectBookmark?, scheme, defaultSimulator{UDID,Name,Runtime}, defaultModelRaw, defaultModeRaw, defaultStepBudget. The user picks an Application once and runs against it indefinitely; defaults inherit into each `GoalRequest` unless explicitly overridden. |
| `Persona` | A reusable persona. id, name, blurb, promptText, isBuiltIn, createdAt, lastUsedAt, archivedAt?. Built-ins are seeded from `docs/PROMPTS/persona-defaults.md` and are not deletable from the UI. |
| `Action` | A reusable user prompt (goal text). id, name, promptText, notes, createdAt, lastUsedAt, archivedAt?. |
| `ActionChain` | An ordered sequence of Actions executed as one Run with multiple legs. id, name, notes, timestamps, archivedAt?, plus a `.cascade` relationship to `ActionChainStep`. |
| `ActionChainStep` | One leg in a chain. id, index (0-based ordering), `action: Action?` (.nullify), preservesState. Step survives Action delete in a "broken-link" state surfaced by the chain editor. |

Everything else — per-step screenshots, observations, intents, tool calls, friction events — lives in `<runDirectoryURL>/events.jsonl` + `step-NNN.png` files. `RunRecord.runDirectoryURL` points at it. **No per-step state moves into SwiftData.**

`ProjectRef` (V1's "recents-projects" cache) is **dropped**: every project is folded into an `Application` during the V1→V2 stage. See §2 for the migration shape.

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

### V1 → V2 (workspace library)

V2 adds `Application`, `Persona`, `Action`, `ActionChain`, `ActionChainStep`, grows `RunRecord` with optional refs to those entities (`application`, `persona_`, `action`, `actionChain`) and a nullable `name`, and **drops** `ProjectRef`.

The migration is mostly lightweight (column-add for the new RunRecord refs; new tables for the library entities; the V1 `ProjectRef` table is dropped because it's not in V2's `models` list). The custom `didMigrate` step backfills Applications:

1. Walk every surviving `RunRecord`.
2. Group by the `(projectPath, scheme)` tuple.
3. For each unique tuple, ensure an `Application` exists (insert if missing, naming it from the run's `displayName` and lifting the simulator triple from the run's saved values; defaults seed from `AgentModel.opus47` / `RunMode.stepByStep` / `stepBudget = 40`).
4. Set `runRecord.application` to the matching row.
5. Bump the Application's `lastUsedAt` to the most recent run's `completedAt ?? createdAt`.

Both V1 and V2 expose a class named `RunRecord` (V1 nested under `HarnessSchemaV1`, V2 at file scope). The shared simple class name lets SwiftData's lightweight migration extend the existing `ZRUNRECORD` table in place rather than dropping and rebuilding it. The Persona seeding from `docs/PROMPTS/persona-defaults.md` runs in `RunHistoryStore.seedBuiltInPersonasIfNeeded(from:)` — invoked from the migration as well as on every app launch so future built-ins propagate forward.

---

## 3. Indexing

Add `#Index` on fields that appear in predicates, sort descriptors, or frequent lookups when the deployment target supports it.

| Entity | Indexed fields |
|--------|---------------|
| `RunRecord` | `createdAt`, `verdict`, `projectPath` |
| `Application` | `lastUsedAt` |
| `Persona` | `lastUsedAt` |
| `Action` | `lastUsedAt` |
| `ActionChain` | `lastUsedAt` |

> Note: `#Index` requires macOS 15+. Harness still ships against macOS 14, so the `lastUsedAt` indexes above are documented intent and re-add when we move the floor to macOS 15. SortDescriptor-driven queries serve current store sizes acceptably without them.

The history view sorts by `createdAt desc` and filters by verdict / project; both must be indexed. Library list views sort by `lastUsedAt desc`.

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
