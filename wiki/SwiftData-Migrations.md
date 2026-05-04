# SwiftData Migrations

The canonical rules live in [`../standards/02-swiftdata.md`](../standards/02-swiftdata.md). This page is the developer-facing checklist for "I want to add a column to a SwiftData model — what do I actually do?"

The shipped failure mode (May 2026) was modifying file-scope `@Model` classes twice in a row without bumping the schema version. SwiftData tolerates a single additive-optional change at runtime, so the bug stayed invisible until a user upgraded across two deltas at once. The on-disk store then refused to open, `AppContainer.init` silently fell through to an in-memory store, and the user lost every saved Application / Persona / Action / run on relaunch.

The discipline below makes that class of failure structural rather than vigilant.

---

## Quick decision tree

You want to:

| Change | What to do |
|---|---|
| Add a stored property to an existing `@Model` | New `VersionedSchema` + lightweight stage. |
| Drop a stored property | New `VersionedSchema` + lightweight stage. |
| Rename a stored property | New `VersionedSchema` + custom `didMigrate` (copy old → new, then drop old). |
| Change a property's type | New `VersionedSchema` + custom `didMigrate` (with explicit transform). |
| Change a property's optionality | New `VersionedSchema` + custom `didMigrate` (backfill defaults). |
| Add a new `@Model` entity | New `VersionedSchema` listing it; lightweight stage. |
| Drop an entity | New `VersionedSchema` *not* listing it — SwiftData drops the table. |

**Never** modify the file-scope `@Model` class directly without a new `VersionedSchema`. Even if it "appears to work" once.

---

## The eight-step workflow

Concrete: you want to add `RunRecord.legsJSON: String?`. The current active schema is V2 with the file-scope `@Model class RunRecord`.

### 1. Move the current shape into a versioned namespace

Add `HarnessSchemaV2.RunRecord` as a nested `@Model class` inside `enum HarnessSchemaV2`. The class body is whatever V2 has *today* — copy it. Don't add the new column here.

```swift
enum HarnessSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [RunRecord.self, /* ... */]
    }

    @Model
    final class RunRecord {
        @Attribute(.unique) var id: UUID
        // ...every property V2 ships today, no more, no less
    }
}
```

**Do not rename the class.** SwiftData defaults the CoreData entity name to the simple class name, so `HarnessSchemaV2.RunRecord` and the file-scope `RunRecord` both map to the entity literally named `"RunRecord"` — the same SQLite table continues across the version, and additive lightweight migration applies the column delta automatically.

### 2. Author the new shape at file scope

Edit the file-scope `@Model class RunRecord` to add `var legsJSON: String? = nil`. Production code keeps importing it unqualified — every callsite (`Harness/Features/...`, `RunHistoryStore`, etc.) compiles unchanged because the file-scope name still resolves.

### 3. Define `HarnessSchemaV3`

```swift
enum HarnessSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [RunRecord.self, /* file-scope types */]
    }
}
```

Every entry in `models` must be a distinct Swift type identity from what previous schemas list. The runtime computes a per-stage checksum from these — reusing types across schemas trips `Duplicate version checksums across stages detected` and the migration plan refuses to load.

### 4. Add a `MigrationStage`

```swift
static let v2ToV3 = MigrationStage.lightweight(
    fromVersion: HarnessSchemaV2.self,
    toVersion: HarnessSchemaV3.self
)
```

Lightweight is enough for additive-optional columns. Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` only when you need to transform existing rows (rename → backfill, type change → re-encode, new required field → fill defaults).

### 5. Update `HarnessMigrationPlan.schemas` and `.stages`

```swift
static var schemas: [any VersionedSchema.Type] {
    [HarnessSchemaV1.self, HarnessSchemaV2.self, HarnessSchemaV3.self]
}
static var stages: [MigrationStage] {
    [v1ToV2, v2ToV3]
}
```

### 6. Point the production store at the new schema

In [`Harness/Services/RunHistoryStore.swift`](../Harness/Services/RunHistoryStore.swift):

```swift
let schema = Schema(versionedSchema: HarnessSchemaV3.self)
```

Both the on-disk init path and `RunHistoryStore.inMemory()` need this.

### 7. Custom `didMigrate` reads through the *target* schema's nested types

If your stage is `.custom(...)`, the closure's `ModelContext` is bound to the schema you're migrating *to*. When the V1→V2 backfill fetches `RunRecord`, that fetch must use `HarnessSchemaV2.RunRecord.self`, not the file-scope one (which is V3 now). Apple's docs call this out tersely — easy to miss until your custom step silently fetches zero rows.

### 8. Add a migration test

Mirror [`Tests/HarnessTests/SwiftDataMigrationTests.swift`](../Tests/HarnessTests/SwiftDataMigrationTests.swift):

- Seed a V(N) on-disk store with the previous shape using a V(N)-only migration plan.
- Open the same URL via `RunHistoryStore(url: storeURL)` (routes through the production migration plan).
- Assert: the new fields exist with their expected defaults / backfilled values, the entity-name continuity preserved every row.

Tests construct stores with `resetOnMigrationFailure: false` so a real migration bug throws loudly instead of nuking the test fixture (the production no-arg path resets on failure, which would silently mask a broken migration).

---

## Recovery policy (pre-release)

`RunHistoryStore.openDefault()` resets the on-disk store on migration failure: delete the SQLite file + WAL/SHM siblings, retry once. Acceptable while we iterate; data loss is preferable to silently falling through to an in-memory store that *appears* to work but loses everything on relaunch.

When we get closer to ship, graduate the rescue to archive-and-warn: rename the corrupted file to `history.store.broken-<iso8601>` and surface the recovery to the user via an `AppState` flag the sidebar reads.

---

## Cross-references

- [`../standards/02-swiftdata.md §10`](../standards/02-swiftdata.md) — canonical version of the workflow.
- [`../Harness/Services/HarnessSchema.swift`](../Harness/Services/HarnessSchema.swift) — `HarnessSchemaV1` / `HarnessSchemaV2` / `HarnessSchemaV3` + `HarnessMigrationPlan`.
- [`../Harness/Services/RunHistoryStore.swift`](../Harness/Services/RunHistoryStore.swift) — `init(url:resetOnMigrationFailure:)` + `openDefault()`.
- [`../Tests/HarnessTests/SwiftDataMigrationTests.swift`](../Tests/HarnessTests/SwiftDataMigrationTests.swift) — V1→V2 round-trip; the template to copy when adding V(N+1) tests.

---

_Last updated: 2026-05-04 — V3 migration shipped after the silent-data-loss bug forced us to formalize the workflow._
