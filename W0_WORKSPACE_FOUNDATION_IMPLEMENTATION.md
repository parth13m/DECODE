# W0: Workspace Foundation — Detailed Engineering Specification

## Milestone W0 of WORKSPACE_MODE_IMPLEMENTATION_PLAN.md

**Status:** Ready for implementation
**Created:** 2026-07-27
**Parent:** WORKSPACE_MODE_IMPLEMENTATION_PLAN.md (approved)
**Scope:** Domain model + database migration + database record. Zero behavioural changes.

---

## Milestone Objective

Introduce the `Workspace` domain model, `WorkspaceKind` enum, `WorkspaceRecord` GRDB record, and `v2_workspaces` database migration. This is the **data foundation** upon which all subsequent Workspace Mode milestones build.

After W0 completes:
- The `Workspace` type exists and is fully tested.
- The `workspaces` table exists in the database.
- The `WorkspaceRecord` maps bidirectionally between domain and persistence.
- **Nothing else changes.** Session Mode continues to work identically. No code outside W0's new files is modified except `DatabaseMigrator.swift` (additive migration).

---

## Task Breakdown

---

### T0.1 — WorkspaceKind Enum

**Objective:** Define the `WorkspaceKind` enum that distinguishes single-file workspaces from directory workspaces.

**Why this task exists:** Every subsequent type (`Workspace`, `WorkspaceRecord`, `ManagedWorkspace` in W1) depends on `WorkspaceKind` to branch behaviour. It must exist as an independent, testable type before `Workspace` can reference it.

**Dependencies:** None (leaf task).

**Files to create:**

| File | Purpose |
|------|---------|
| `Decode/Domain/Models/WorkspaceKind.swift` | `WorkspaceKind` enum definition |

**Files to modify:** None.

**Public API changes:**

```swift
/// Distinguishes how a workspace tracks its root target.
///
/// - `.file`: tracks a single source file (degenerate case, identical to
///   today's Session). `Workspace.rootPath` is the file path.
/// - `.directory`: tracks an entire project directory with full indexing.
///   `Workspace.rootPath` is the directory path.
enum WorkspaceKind: String, Sendable, Codable, Hashable {
    case file
    case directory
}
```

**Internal implementation notes:**
- Raw type is `String` so it persists directly as TEXT in SQLite via GRDB `Codable` synthesis.
- `String` raw values: `"file"`, `"directory"`. These are the canonical database values — they must never change after shipping.
- No computed properties or methods. This is a pure discriminator.
- Placement: `Decode/Domain/Models/` — same directory as `Session.swift`. Domain layer, no imports beyond `Foundation`.

**Expected tests:**

| Test | Description |
|------|-------------|
| `testWorkspaceKindRawValues` | Assert `.file.rawValue == "file"`, `.directory.rawValue == "directory"`. Guards against accidental rename. |
| `testWorkspaceKindCodableRoundTrip` | Encode `.file` to JSON, decode, assert equality. Same for `.directory`. |
| `testWorkspaceKindHashable` | Assert `Set([.file, .directory]).count == 2`. |
| `testWorkspaceKindInitFromRawValue` | Assert `WorkspaceKind(rawValue: "file") == .file`, unknown string returns `nil`. |

**Regression risks:** None. New file, no existing code modified.

**Verification steps:**
1. Build succeeds.
2. All 4 tests pass.
3. No other file imports `WorkspaceKind` yet (grep verification).

**Definition of Done:**
- [ ] `WorkspaceKind.swift` exists in `Decode/Domain/Models/`.
- [ ] Enum has exactly two cases: `.file`, `.directory`.
- [ ] Conforms to `String`, `Sendable`, `Codable`, `Hashable`.
- [ ] Raw values are `"file"` and `"directory"`.
- [ ] Only imports `Foundation`.
- [ ] 4 unit tests pass.
- [ ] Build succeeds with strict concurrency.

---

### T0.2 — Workspace Domain Model

**Objective:** Define the `Workspace` struct — the aggregate root that will replace `Session` as Decode's primary tracked context.

**Why this task exists:** `Workspace` is the central domain type for the entire Workspace Mode epic. Every milestone from W1 through W7 depends on it. It must be defined precisely, with the correct fields, conformances, and documentation, before any manager, record, or migration can reference it.

**Dependencies:** T0.1 (WorkspaceKind).

**Files to create:**

| File | Purpose |
|------|---------|
| `Decode/Domain/Models/Workspace.swift` | `Workspace` struct definition |

**Files to modify:** None.

**Public API changes:**

```swift
/// The aggregate root for a tracked context in Workspace Mode.
///
/// A workspace tracks either a single source file (`.file` kind, identical
/// to today's `Session`) or an entire project directory (`.directory` kind,
/// with full indexing and multi-file intelligence).
///
/// ## Relationship to Session
/// `Workspace` is the successor to `Session`. During the migration period
/// (W0–W2), both types coexist. After W3, `Session` is removed and
/// `Workspace` is the sole aggregate root.
///
/// ## Canonical vs Derived State
/// `Workspace` stores only canonical state — identity, root location,
/// bookmark, timestamps, summary. All derived state (parsed entities,
/// file intelligence, module list, DIR content) lives in `ManagedWorkspace`
/// (W1) and is recomputable from the understanding pipeline.
///
/// Maps to the `workspaces` table in the database.
struct Workspace: Identifiable, Sendable, Codable, Hashable {

    let id: UUID
    let kind: WorkspaceKind
    let createdAt: Date
    var updatedAt: Date

    /// Security-scoped bookmark data for file system access across app restarts.
    var bookmarkData: Data

    /// Canonical root path.
    /// - `.file`: absolute path to the tracked file
    ///   (e.g., `/Users/dev/project/Sources/Foo.swift`)
    /// - `.directory`: absolute path to the tracked directory
    ///   (e.g., `/Users/dev/project`)
    var rootPath: String

    /// Display name derived from the root path.
    /// - `.file`: file name (e.g., `Foo.swift`)
    /// - `.directory`: directory name (e.g., `project`)
    var rootFileName: String

    /// AI-generated high-level description of the workspace's purpose.
    var summaryText: String

    /// Whether the workspace's database records are known to be corrupted.
    var isCorrupted: Bool
}
```

**Internal implementation notes:**
- **No `fileSize`, `fileModifiedAt`, `fileHash` fields.** These are per-file metadata that belong in `ManagedWorkspace` (W1) for `.file` workspaces and in per-file tracking for `.directory` workspaces. `Session` stored them because it was always single-file. `Workspace` is kind-agnostic at the domain level.
- **`kind` is `let`, not `var`.** A workspace's kind is immutable after creation. You cannot convert a file workspace into a directory workspace.
- **`id` and `createdAt` are `let`.** Identity and creation timestamp are immutable.
- **`bookmarkData`** is `var` because bookmarks can be refreshed when the file system changes.
- Placement: `Decode/Domain/Models/` alongside `Session.swift`.
- Only imports `Foundation`.

**Expected tests:**

| Test | Description |
|------|-------------|
| `testWorkspaceIdentifiable` | Create workspace, assert `id` is accessible and stable. |
| `testWorkspaceSendable` | Compile-time verification (struct with all Sendable fields). No runtime test needed — build is the test. |
| `testWorkspaceCodableRoundTrip_file` | Create `.file` workspace, encode to JSON, decode, assert all fields equal. |
| `testWorkspaceCodableRoundTrip_directory` | Create `.directory` workspace, encode to JSON, decode, assert all fields equal. |
| `testWorkspaceHashable` | Two workspaces with different IDs hash differently. Same ID hashes equally. |
| `testWorkspaceEquality` | Two workspaces with same ID are equal regardless of mutable field values (if using synthesised conformance — verify this matches `Session` semantics). |
| `testWorkspaceKindImmutable` | Verify `kind` is `let` (compile-time — attempting `workspace.kind = .directory` should not compile). Document as a design constraint, not a runtime test. |

**Regression risks:** None. New file, no existing code modified.

**Verification steps:**
1. Build succeeds with strict concurrency.
2. All tests pass.
3. `Workspace` does not import anything beyond `Foundation`.
4. `Workspace` does not reference `Session`, `SessionManager`, or any Application/Infrastructure type.

**Definition of Done:**
- [ ] `Workspace.swift` exists in `Decode/Domain/Models/`.
- [ ] Struct conforms to `Identifiable`, `Sendable`, `Codable`, `Hashable`.
- [ ] Fields match the API specification exactly (10 fields, 4 `let` + 6 `var`).
- [ ] No per-file metadata fields (`fileSize`, `fileModifiedAt`, `fileHash`).
- [ ] Only imports `Foundation`.
- [ ] 5+ unit tests pass (Codable round-trip, Hashable, Identifiable).
- [ ] Build succeeds with strict concurrency.

---

### T0.3 — WorkspaceRecord GRDB Record

**Objective:** Define the `WorkspaceRecord` that maps between the `Workspace` domain model and the `workspaces` database table.

**Why this task exists:** The database migration (T0.4) creates the table schema. `WorkspaceRecord` bridges domain ↔ persistence. Without it, `DatabaseService` cannot read or write workspaces. Defining the record before the migration ensures the record's field expectations match the table schema exactly.

**Dependencies:** T0.2 (Workspace model — needed for `init(from:)` and `toDomain()` mapping).

**Files to create:**

| File | Purpose |
|------|---------|
| `Decode/Infrastructure/Database/Records/WorkspaceRecord.swift` | GRDB record for the `workspaces` table |

**Files to modify:** None.

**Public API changes:**

```swift
/// GRDB record type for the `workspaces` table.
///
/// Maps between the Domain `Workspace` model and the database row.
/// Uses `uuidString` for the primary key since GRDB stores UUIDs as TEXT.
///
/// Follows the same pattern as `SessionRecord`.
struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workspaces"

    var id: String           // UUID as TEXT
    var kind: String         // WorkspaceKind raw value
    var createdAt: Date
    var updatedAt: Date
    var bookmarkData: Data
    var rootPath: String
    var rootFileName: String
    var summaryText: String
    var isCorrupted: Bool

    init(from workspace: Workspace)
    func toDomain() -> Workspace?
}
```

**Internal implementation notes:**
- **Follows `SessionRecord` pattern exactly.** Same structure: stored properties matching table columns, `init(from:)` converting domain → record, `toDomain()` converting record → domain with `nil` return on invalid data.
- **`kind` stored as `String`**, not as `WorkspaceKind` directly. This mirrors how `EntityRecord` stores `entityType` as `String` and converts via `rawValue` in `toDomain()`. Keeps the record a plain GRDB `Codable` type without needing GRDB to understand `WorkspaceKind`.
- **`toDomain()` returns `nil`** if `UUID(uuidString:)` fails or `WorkspaceKind(rawValue:)` fails. Consistent with `SessionRecord.toDomain()` and `EntityRecord.toDomain()`.
- **`databaseTableName = "workspaces"`** — must match the table name in the migration (T0.4).
- Placement: `Decode/Infrastructure/Database/Records/` alongside `SessionRecord.swift`.
- Imports: `Foundation`, `GRDB`.

**Expected tests:**

| Test | Description |
|------|-------------|
| `testWorkspaceRecordFromDomain_file` | Create `.file` `Workspace`, convert to `WorkspaceRecord`, assert all fields mapped correctly (`id` as uuidString, `kind` as "file", etc.). |
| `testWorkspaceRecordFromDomain_directory` | Same for `.directory` workspace. |
| `testWorkspaceRecordToDomain_file` | Create `WorkspaceRecord` with valid data, call `toDomain()`, assert `Workspace` fields match. |
| `testWorkspaceRecordToDomain_directory` | Same for directory kind. |
| `testWorkspaceRecordToDomain_invalidUUID` | Create record with invalid UUID string, assert `toDomain()` returns `nil`. |
| `testWorkspaceRecordToDomain_invalidKind` | Create record with `kind = "unknown"`, assert `toDomain()` returns `nil`. |
| `testWorkspaceRecordRoundTrip` | Workspace → WorkspaceRecord → toDomain() → assert equal to original. |
| `testWorkspaceRecordTableName` | Assert `WorkspaceRecord.databaseTableName == "workspaces"`. |

**Regression risks:** None. New file, no existing code modified. Does not touch `SessionRecord`.

**Verification steps:**
1. Build succeeds with strict concurrency.
2. All 8 tests pass.
3. `WorkspaceRecord.databaseTableName` matches the table name that T0.4 will create.
4. Field names in `WorkspaceRecord` match column names that T0.4 will define.

**Definition of Done:**
- [ ] `WorkspaceRecord.swift` exists in `Decode/Infrastructure/Database/Records/`.
- [ ] Conforms to `Codable`, `FetchableRecord`, `PersistableRecord`.
- [ ] `databaseTableName` is `"workspaces"`.
- [ ] `init(from:)` maps all 10 `Workspace` fields correctly.
- [ ] `toDomain()` returns `nil` for invalid UUID or invalid kind.
- [ ] Imports only `Foundation` and `GRDB`.
- [ ] 8 unit tests pass.
- [ ] Build succeeds with strict concurrency.

---

### T0.4 — Database Migration v2_workspaces

**Objective:** Register database migration `v2_workspaces` that creates the `workspaces` table. The migration is purely additive — it does not modify, drop, or alter the existing `sessions` or `entities` tables.

**Why this task exists:** The `workspaces` table must exist before any workspace can be persisted. The migration is the prerequisite for workspace CRUD in W1. Separating it from the record (T0.3) ensures the schema definition is reviewed independently from the mapping logic.

**Dependencies:** T0.3 (WorkspaceRecord — defines the expected column names and types. The migration must create columns that match the record's `Codable` synthesis expectations).

**Files to create:** None.

**Files to modify:**

| File | Change |
|------|--------|
| `Decode/Infrastructure/Database/DatabaseMigrator.swift` | Add `v2_workspaces` migration after `v1_initial` |

**Public API changes:** None (migration is internal infrastructure).

**Internal implementation notes:**

The migration adds a single block to `DecodeDatabaseMigrator.migrate(_:)`:

```swift
migrator.registerMigration("v2_workspaces") { db in
    try db.create(table: "workspaces") { t in
        t.primaryKey("id", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("bookmarkData", .blob).notNull()
        t.column("rootPath", .text).notNull()
        t.column("rootFileName", .text).notNull()
        t.column("summaryText", .text).notNull().defaults(to: "")
        t.column("isCorrupted", .boolean).notNull().defaults(to: false)
    }

    // Index for fast lookup by root path (used by duplicate detection in W1).
    try db.create(
        index: "idx_workspaces_rootPath",
        on: "workspaces",
        columns: ["rootPath"],
        unique: true
    )
}
```

**Key design decisions:**

1. **`rootPath` has a unique index.** Prevents creating two workspaces for the same file or directory. `SessionManager.createSession(url:)` already checks for duplicates in-memory; the unique index provides a database-level guarantee.

2. **`summaryText` defaults to `""`** — matches `sessions` table convention.

3. **`isCorrupted` defaults to `false`** — matches `sessions` table convention.

4. **No foreign key from `entities` to `workspaces` yet.** The `entities` table currently has `sessionId` referencing `sessions`. Re-pointing this FK is a W3 concern (session removal). Adding a second FK column (`workspaceId`) now would be premature — W0 does not create or manage entities via workspaces.

5. **No `fileSize`, `fileModifiedAt`, `fileHash` columns.** These are per-file metadata absent from the `Workspace` domain model (see T0.2 rationale).

6. **`kind` is TEXT, not an enum constraint.** SQLite has no native enum type. Validation happens in `WorkspaceRecord.toDomain()` via `WorkspaceKind(rawValue:)`.

7. **Migration name `v2_workspaces`** follows the existing convention (`v1_initial`). GRDB's migrator ensures migrations run in registration order exactly once.

8. **`eraseDatabaseOnSchemaChange = true` in DEBUG** (already configured in `v1_initial` block) means any schema change in development wipes and recreates the DB. This is acceptable at alpha scale and actually simplifies iteration.

**Expected tests:**

| Test | Description |
|------|-------------|
| `testMigrationV2CreatesWorkspacesTable` | Open an in-memory DB, run migrator, assert `workspaces` table exists with correct columns. |
| `testMigrationV2PreservesSessionsTable` | Open an in-memory DB, insert a session row, run migrator (which includes v1 + v2), assert the session row survives. |
| `testMigrationV2UniqueRootPathIndex` | After migration, insert two workspace records with the same `rootPath`, assert the second insert throws a GRDB constraint error. |
| `testMigrationV2WorkspaceRecordInsertAndFetch` | After migration, insert a `WorkspaceRecord`, fetch it back, assert all fields match. This is the integration test proving T0.3 + T0.4 work together. |

**Regression risks:**
- **Moderate:** This is the only task that modifies an existing file (`DatabaseMigrator.swift`). The change is purely additive (appending a new migration registration), but a typo in the migration block could break the migrator for the entire database.
- **Mitigated by:** DEBUG `eraseDatabaseOnSchemaChange`, in-memory DB tests, and the fact that GRDB migrations are append-only (existing `v1_initial` is not touched).

**Verification steps:**
1. Build succeeds.
2. All 4 migration tests pass.
3. Existing `v1_initial` migration code is **unchanged** (diff shows only additions).
4. Manual verification: launch app in DEBUG, confirm no crash on startup (migrator runs during `DatabaseService.init()`).
5. `grep -n "v2_workspaces" Decode/Infrastructure/Database/DatabaseMigrator.swift` returns exactly 1 line (the registration).

**Definition of Done:**
- [ ] `v2_workspaces` migration registered in `DatabaseMigrator.swift`.
- [ ] `workspaces` table has 9 columns matching `WorkspaceRecord` fields.
- [ ] Unique index on `rootPath`.
- [ ] `sessions` table is not modified (no ALTER, no DROP, no new columns).
- [ ] `entities` table is not modified.
- [ ] 4 migration tests pass (table creation, session preservation, unique constraint, record round-trip).
- [ ] Build succeeds with strict concurrency.
- [ ] App launches without crash in DEBUG.

---

### T0.5 — Test File Creation and Organisation

**Objective:** Create the test file that houses all W0 unit tests, with proper organisation and test helpers.

**Why this task exists:** Tests for T0.1–T0.4 need a home. Creating the test file as an explicit task ensures test infrastructure is reviewed independently from the code it tests. This also establishes the naming convention for the workspace test file hierarchy.

**Dependencies:** T0.1, T0.2, T0.3, T0.4 (all types and migration must exist for tests to compile).

**Files to create:**

| File | Purpose |
|------|---------|
| `DecodeTests/WorkspaceFoundationTests.swift` | All W0 unit tests: WorkspaceKind, Workspace, WorkspaceRecord, v2 migration |

**Files to modify:** None.

**Public API changes:** None (test-only file).

**Internal implementation notes:**

The test file is organised into sections matching the tasks:

```
// MARK: - T0.1: WorkspaceKind Tests
// MARK: - T0.2: Workspace Model Tests
// MARK: - T0.3: WorkspaceRecord Tests
// MARK: - T0.4: Migration Tests
```

**Test helpers needed:**

1. **`makeFileWorkspace()`** — factory that creates a `.file` `Workspace` with sensible defaults. Reduces boilerplate across tests.
2. **`makeDirectoryWorkspace()`** — factory for `.directory` workspace.
3. **In-memory GRDB database** — for migration and record tests. Pattern: `try DatabaseQueue()` (no path = in-memory). Run `DecodeDatabaseMigrator.migrate(db)` before each test that needs the schema.

**Test pattern for migration tests** follows the existing `DecodeTests/` conventions:

```swift
import XCTest
import GRDB
@testable import Decode

final class WorkspaceFoundationTests: XCTestCase {
    // ...
}
```

**Expected tests:** All tests listed in T0.1, T0.2, T0.3, and T0.4. Total: ~21 tests.

| Section | Count |
|---------|-------|
| WorkspaceKind | 4 |
| Workspace model | 5 |
| WorkspaceRecord | 8 |
| Migration | 4 |
| **Total** | **21** |

**Regression risks:** None. New test file, no existing tests modified.

**Verification steps:**
1. Build succeeds (test target).
2. All 21 tests pass.
3. Test file is discovered by the `DecodeTests` scheme.
4. No existing test file is modified.

**Definition of Done:**
- [ ] `WorkspaceFoundationTests.swift` exists in `DecodeTests/`.
- [ ] Contains all 21 tests from T0.1–T0.4.
- [ ] Uses `@testable import Decode` and `import GRDB`.
- [ ] Test helpers (`makeFileWorkspace`, `makeDirectoryWorkspace`) reduce boilerplate.
- [ ] Migration tests use in-memory GRDB database.
- [ ] All 21 tests pass.
- [ ] No existing test file modified.

---

## 3. Implementation Order

```
T0.1 (WorkspaceKind)          ← implement first — leaf dependency, zero risk
  │
  └──→ T0.2 (Workspace)       ← implement second — depends on T0.1
         │
         └──→ T0.3 (WorkspaceRecord)  ← implement third — depends on T0.2
                │
                └──→ T0.4 (Migration)  ← implement fourth — depends on T0.3 for column alignment
                       │
                       └──→ T0.5 (Tests)  ← implement last — depends on all above
```

**Critical path:** T0.1 → T0.2 → T0.3 → T0.4 → T0.5 (strictly sequential).

**No parallelism is possible** within W0: each task's output is the next task's input. This is expected for a foundation milestone.

**Start with T0.1.** It is the leaf dependency with zero risk (new file, no modifications, 15 lines of code, 4 tests). It validates that the build system picks up new files in `Decode/Domain/Models/` and establishes the WorkspaceKind contract that everything else depends on.

---

## 4. Files Touched Summary

| Action | File | Task |
|--------|------|------|
| **Create** | `Decode/Domain/Models/WorkspaceKind.swift` | T0.1 |
| **Create** | `Decode/Domain/Models/Workspace.swift` | T0.2 |
| **Create** | `Decode/Infrastructure/Database/Records/WorkspaceRecord.swift` | T0.3 |
| **Modify** | `Decode/Infrastructure/Database/DatabaseMigrator.swift` | T0.4 |
| **Create** | `DecodeTests/WorkspaceFoundationTests.swift` | T0.5 |

**Total:** 4 new files, 1 modified file, 0 deleted files.

**Files NOT touched (frozen):**
- All understanding pipeline modules (DIRCore, ProducerRuntime, etc.)
- All reasoning engines
- All composition passes
- `UnderstandingSystem.swift`
- `PipelineQueryService.swift`
- `Session.swift` (unchanged — coexists until W3)
- `SessionManager.swift` (unchanged)
- `SessionRecord.swift` (unchanged)
- `DatabaseService.swift` (unchanged — workspace CRUD added in W1)
- `DatabaseServiceProtocol.swift` (unchanged — workspace methods added in W1)
- `AppDependencies.swift` (unchanged — workspace wiring added in W1/W2)
- `project.yml` (unchanged — xcodegen auto-discovers new Swift files in source directories)

---

## 5. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Migration breaks existing database | Low | High | Additive-only migration. `eraseDatabaseOnSchemaChange` in DEBUG. In-memory test. |
| `WorkspaceKind` raw values don't survive encoding | Very Low | Medium | Explicit raw value test in T0.1. |
| `WorkspaceRecord` field names don't match migration columns | Low | Medium | T0.4 integration test inserts and fetches a record. Compile-time Codable synthesis catches mismatches. |
| xcodegen doesn't pick up new files | Very Low | Low | `project.yml` sources `path: Decode` recursively. Verified by build. Run `xcodegen generate` if needed. |

---

## 6. Post-W0 Verification Gate

Before W1 begins, all of the following must be true:

1. Build succeeds (main target + test target) with `SWIFT_STRICT_CONCURRENCY = complete`.
2. All 21 W0 tests pass.
3. All existing tests pass (no regressions).
4. App launches without crash in DEBUG.
5. `grep -r "import.*Workspace" Decode/` returns only `WorkspaceRecord.swift` (no premature coupling).
6. `Session.swift` is byte-identical to its pre-W0 state.
7. `SessionManager.swift` is byte-identical to its pre-W0 state.

---

## Appendix: Relationship to Session Model

For reference, here is the field mapping between the existing `Session` and the new `Workspace`:

| Session field | Workspace field | Notes |
|---------------|----------------|-------|
| `id: UUID` | `id: UUID` | Same semantics |
| `createdAt: Date` | `createdAt: Date` | Same |
| `updatedAt: Date` | `updatedAt: Date` | Same |
| `bookmarkData: Data` | `bookmarkData: Data` | Same |
| `filePath: String` | `rootPath: String` | Generalised: file path or directory path |
| `fileName: String` | `rootFileName: String` | Generalised: file name or directory name |
| `fileSize: Int` | *(removed)* | Per-file metadata → `ManagedWorkspace` (W1) |
| `fileModifiedAt: Date` | *(removed)* | Per-file metadata → `ManagedWorkspace` (W1) |
| `fileHash: String` | *(removed)* | Per-file metadata → `ManagedWorkspace` (W1) |
| `summaryText: String` | `summaryText: String` | Same |
| `isCorrupted: Bool` | `isCorrupted: Bool` | Same |
| *(none)* | `kind: WorkspaceKind` | **New.** Discriminator for workspace behaviour. |

**Key difference:** `Session` embeds per-file metadata (size, hash, modification date) directly because it is always single-file. `Workspace` omits these because they are kind-dependent derived state. For `.file` workspaces, this metadata will live in `ManagedWorkspace` (W1). For `.directory` workspaces, per-file metadata is tracked per indexed file.

---

*This document is the detailed engineering specification for Milestone W0 only. It does not authorise implementation of any other milestone. Refer to WORKSPACE_MODE_IMPLEMENTATION_PLAN.md for the full epic scope.*
