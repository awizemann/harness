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

Both V1 and V2 expose a class named `RunRecord` (V1 nested under `HarnessSchemaV1`, V2 nested under `HarnessSchemaV2`). The shared simple class name lets SwiftData's lightweight migration extend the existing `ZRUNRECORD` table in place rather than dropping and rebuilding it. The Persona seeding from `docs/PROMPTS/persona-defaults.md` runs in `RunHistoryStore.seedBuiltInPersonasIfNeeded(from:)` — invoked from the migration as well as on every app launch so future built-ins propagate forward.

### V2 → V3 (run-log enrichments)

V3 adds three optional columns to `RunRecord`:

- `legsJSON: String?` — JSON-encoded `[LegRecord]` for chain runs (added by Phase E).
- `tokensUsedCacheRead: Int?` — Anthropic API cache-read tokens (added by cost tracking).
- `tokensUsedCacheCreation: Int?` — Anthropic API cache-creation tokens (added by cost tracking).

Migration is **lightweight** — `MigrationStage.lightweight(fromVersion: V2, toVersion: V3)`. Existing rows pick up `nil` defaults; nothing to backfill.

V2's `@Model` types live nested under `HarnessSchemaV2`; V3's used to live at file scope but were moved nested under `HarnessSchemaV3` when V4 landed (see V3→V4 below — the same nesting trick V2→V3 used). Each schema's checksum derives from the *Swift class identity* of its `models` array — two schemas listing the same Swift type collide with `Duplicate version checksums across stages detected` and the migration plan refuses to load. **Every new schema version must list a fresh set of nested `@Model` types**; see §10 below for the workflow.

### V3 → V4 (platform discriminator)

V4 adds the multi-platform foundation: every Application now declares whether it's an iOS Simulator app (today's only working option), a macOS app (Phase 2), or a web app (Phase 3). Per-platform optional fields land on the `Application` row alongside, so the schema doesn't need to grow again when Phase 2 / 3 ship the driver implementations.

`Application` gains:

- `platformKindRaw: String?` — discriminator. `nil` resolves to `.iosSimulator` via `PlatformKind.from(rawValue:)`.
- `macAppBundlePath: String?`, `macAppBundleBookmark: Data?` — pre-built `.app` mode for macOS (Phase 2 wires the launcher).
- `webStartURL: String?`, `webViewportWidthPt: Int?`, `webViewportHeightPt: Int?` — Phase 3 wires the embedded WebKit driver.

`RunRecord` gains:

- `platformKindRaw: String?` — which platform a run drove. `nil` on legacy V3 rows; `RunRecord.platformKind` resolves nil to `.iosSimulator`.

Migration is **lightweight** — `MigrationStage.lightweight(fromVersion: V3, toVersion: V4)`. All new columns are optional with `nil` defaults; existing rows decode cleanly and resolve to iOS at read time. Nothing to backfill.

V3's nested types: `HarnessSchemaV3.RunRecord`, `HarnessSchemaV3.Application`, etc. — each with V3-namespaced `@Relationship` types (e.g. `var application: HarnessSchemaV3.Application?`). V4's `@Model` types are now at file scope; production code references `Application` / `RunRecord` unqualified and reads the V4 shape.

The migration test that goes with this stage lives in `Tests/HarnessTests/SwiftDataMigrationTests.swift` — the `seedV3` helper stamps a fresh on-disk store with V3 only, then the test reopens through the full `HarnessMigrationPlan` and asserts that legacy Applications resolve to `.iosSimulator` and that V4 round-trips preserve the explicit value.

### Recovery policy (pre-release)

Today `RunHistoryStore.openDefault()` opens the production store with `resetOnMigrationFailure: true`: if `ModelContainer(for:migrationPlan:configurations:)` throws, we delete the SQLite file + WAL/SHM siblings and retry once against a clean slot. Data loss is acceptable while we iterate; the previous behavior — silently falling through to an in-memory store — is what hid the V2→V3 migration bug behind a "saved Applications disappeared on relaunch" symptom. When we get closer to ship, graduate the rescue to archive-and-warn (rename the corrupted file, surface the recovery to the user via `AppState`).

Tests construct stores via `RunHistoryStore(url: ..., resetOnMigrationFailure: false)` so a real migration bug throws loudly instead of nuking the test fixture.

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

---

## 10. Adding a column / new entity (the only correct workflow)

The bug we hit at the V2→V3 boundary was modifying the file-scope `@Model` classes in place, twice, without bumping the schema version. SwiftData *appeared* to keep working — the runtime tolerates additive optional columns once or twice — until a user upgraded across both deltas at once and the on-disk hash no longer matched any stage in the migration plan. The on-disk store then refused to open; `try?` in `AppContainer.init` swallowed the error; the user dropped to an in-memory store and lost everything saved.

**Never modify a shipped `@Model` class in place.** When you need to add, remove, or rename a stored property, do this:

1. **Move the current shape into a versioned namespace.** If the class is at file scope today, nest it inside a fresh `enum HarnessSchemaVN: VersionedSchema` and add the previously file-scope class as a nested `@Model class` inside that enum. The CoreData entity name (defaults to the simple class name) stays the same — `HarnessSchemaVN.RunRecord` and the new file-scope `RunRecord` both map to the entity literally named `"RunRecord"`. SwiftData treats them as evolving the same SQLite table. **Do not rename the entity.**

2. **Author the new shape at file scope.** Edit the file-scope `@Model class` (or add a new one) with the property you want. Production code keeps importing it unqualified.

3. **Define `HarnessSchemaV(N+1)`** with `versionIdentifier: .init(N+1, 0, 0)` and `models: [...]` listing the file-scope types. Every entry in this array must be a *distinct Swift type identity* from what previous schemas list — that's how the runtime computes the per-stage checksum. Reusing the same type across two `VersionedSchema`s triggers `Duplicate version checksums across stages detected`.

4. **Add a `MigrationStage`** to `HarnessMigrationPlan.stages`. Lightweight is enough for column-add or column-drop on optional fields with `nil` defaults; use `.custom(...)` only when you need a `didMigrate` to backfill data (e.g. the V1→V2 backfill that emits one Application per `(projectPath, scheme)` tuple).

5. **Update `HarnessMigrationPlan.schemas`** to include the new schema in declaration order.

6. **Point the production store at the new schema.** `Schema(versionedSchema: HarnessSchemaV(N+1).self)` in both `RunHistoryStore.init(url:resetOnMigrationFailure:)` and `RunHistoryStore.inMemory()`.

7. **Custom `didMigrate` reads through V(N)'s nested types** — the context in a custom stage's closure is bound to the *target* schema, so when migrating V1 → V2, fetch via `HarnessSchemaV2.RunRecord` etc. (Apple's docs call this out tersely; it's easy to miss.)

8. **Add a migration test.** Mirror `Tests/HarnessTests/SwiftDataMigrationTests.swift` — seed a V(N) on-disk store with the previous shape, open it via `RunHistoryStore(url:)` (which routes through the migration plan), and assert the new fields land with correct defaults / backfilled values.

9. **Bump the doc.** Add a `### V(N) → V(N+1)` subsection above with the same shape as the existing ones — what columns moved, lightweight vs custom, what the `didMigrate` does if anything.

The discipline is annoying but the failure mode is silent data loss across a user's library, so the discipline is the price of admission.

A corollary: **don't** change a column's type, rename it, or change its optionality without graduating to a new schema version with an explicit stage. Lightweight migration handles additive optional columns; everything else is a hand-written stage.
