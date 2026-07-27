# WORKSPACE_MODE_IMPLEMENTATION_PLAN.md

## Canonical Implementation Specification — Workspace Mode Epic

**Status:** Active
**Created:** 2026-07-27
**Architecture:** Frozen (principal review complete)
**Predecessor:** SESSION_MODE_IMPLEMENTATION_STATUS.md (read-only reference)

---

## 1. Executive Summary

Workspace Mode replaces Session Mode as Decode's root interaction model. Today, a Session tracks a single file. A Workspace generalises this to track either a single file (`.file` kind — identical to today's Session) or an entire project directory (`.directory` kind — full codebase intelligence).

The core insight: Session is a degenerate single-file Workspace. Rather than maintaining two parallel systems (SessionManager + ProjectManager), Workspace Mode unifies them under a single ownership hierarchy. The understanding pipeline (DIR, all 8 modules, 6 composition passes) already processes N files natively — every caller currently passes single-element arrays. The gap is purely application-layer ingestion, file system observation, and UI.

**Guiding constraints:**
- Preserve the frozen intelligence architecture (DAS/DDS/IAG). No pipeline module changes.
- Preserve existing user functionality until intentionally replaced.
- Every milestone is independently shippable.
- Low implementation risk through incremental migration.

**Epic scope:** 8 milestones (W0–W7), estimated at ~4,200 lines of new/modified code across 25–30 files.

---

## 2. Milestone Breakdown

---

### W0: Domain Foundation

**Objective:** Introduce the `Workspace` domain model and database migration. No behavioural changes. Session continues to work exactly as before.

**Description:**
Define the `Workspace` struct that replaces `Session` as the aggregate root. Add `WorkspaceKind` enum (`.file`, `.directory`). Create database migration `v2_workspaces` adding the `workspaces` table. The `sessions` table remains untouched — W0 does not migrate data.

**Dependencies:** None (leaf milestone).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Domain/Models/Session.swift` | No change (preserved for backward compatibility until W3) |
| `Decode/Infrastructure/Database/DatabaseMigrator.swift` | Add `v2_workspaces` migration |

**New files:**

| File | Purpose |
|------|---------|
| `Decode/Domain/Models/Workspace.swift` | `Workspace` struct with `id`, `kind`, `rootPath`, `rootFileName`, `bookmarkData`, `createdAt`, `updatedAt`, `summaryText`, `isCorrupted` |
| `Decode/Infrastructure/Database/Records/WorkspaceRecord.swift` | GRDB `FetchableRecord`/`PersistableRecord` for the `workspaces` table |

**Public API changes:**
- New type: `Workspace: Identifiable, Sendable, Codable, Hashable`
- New type: `WorkspaceKind: String, Sendable, Codable, Hashable` with cases `.file`, `.directory`
- New table: `workspaces` with columns: `id TEXT PK`, `kind TEXT NOT NULL`, `rootPath TEXT NOT NULL`, `rootFileName TEXT NOT NULL`, `bookmarkData BLOB NOT NULL`, `createdAt DATETIME NOT NULL`, `updatedAt DATETIME NOT NULL`, `summaryText TEXT NOT NULL DEFAULT ''`, `isCorrupted BOOLEAN NOT NULL DEFAULT false`

**Risks:**
- Migration must not break the existing `sessions` table. Mitigated by additive-only migration (new table, no ALTER on sessions).
- `eraseDatabaseOnSchemaChange = true` in DEBUG will wipe data on schema change. Acceptable at alpha scale.

**Verification strategy:**
1. Build succeeds with strict concurrency.
2. Unit test: `Workspace` round-trips through `WorkspaceRecord` encoding/decoding.
3. Unit test: `v2_workspaces` migration runs cleanly after `v1_initial`.
4. Existing Session tests pass unchanged.

**Acceptance criteria:**
- [ ] `Workspace` struct compiles with `Sendable`, `Codable`, `Hashable` conformance.
- [ ] `WorkspaceRecord` maps bidirectionally between `Workspace` and DB row.
- [ ] Migration `v2_workspaces` creates table with correct schema.
- [ ] All existing tests pass.

---

### W1: WorkspaceManager — Lifecycle

**Objective:** Implement `WorkspaceManager` with full lifecycle for `.file` workspaces. This is a functional replacement for `SessionManager` for the single-file case.

**Description:**
`WorkspaceManager` manages `ManagedWorkspace` instances. For `.file` workspaces, behaviour is identical to `SessionManager`: create from URL, activate, pin, close, persist to DB, start file watcher. The manager uses the existing `FileWatcherService` for `.file` workspaces. `.directory` workspace support is deferred to W4.

`ManagedWorkspace` replaces `ManagedSession`: owns `Workspace`, `parsedEntities: [ParsedEntity]`, `fileIntelligence: FileIntelligence?`, `fileWatcher: FileWatcherService`, `watcherTask: Task?`.

**Dependencies:** W0 (Workspace model).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Domain/Protocols/DatabaseServiceProtocol.swift` | Add workspace CRUD methods |
| `Decode/Infrastructure/Database/DatabaseService.swift` | Implement workspace CRUD |

**New files:**

| File | Purpose |
|------|---------|
| `Decode/Application/WorkspaceManager.swift` | `@Observable @MainActor` manager: create, activate, pin, close, restore `.file` workspaces |
| `DecodeTests/WorkspaceManagerTests.swift` | Unit tests for `.file` workspace lifecycle |

**Public API changes:**
- `WorkspaceManager.createWorkspace(url: URL) async` — creates `.file` workspace from file URL
- `WorkspaceManager.activateWorkspace(id: UUID)` — sets active workspace
- `WorkspaceManager.pinWorkspace(id: UUID)` / `unpinWorkspace()`
- `WorkspaceManager.closeWorkspace(id: UUID) async` — stops watcher, removes from memory
- `WorkspaceManager.restoreWorkspaces() async` — loads all workspaces from DB
- `WorkspaceManager.activeWorkspace: ManagedWorkspace?`
- `WorkspaceManager.orderedWorkspaces: [ManagedWorkspace]`
- `WorkspaceManager.onFileChanged: ((_ filePath: String, _ kind: FileChangeKind) -> Void)?`
- `DatabaseServiceProtocol`: `saveWorkspace(_:)`, `fetchAllWorkspaces()`, `deleteWorkspace(id:)`

**Risks:**
- Code duplication with `SessionManager`. Acceptable — W3 removes `SessionManager` entirely.
- `onFileChanged` bridge must work identically. Mitigated by copying the proven pattern.

**Verification strategy:**
1. Build succeeds.
2. Unit tests: create → activate → pin → close lifecycle for `.file` workspace.
3. Unit test: DB round-trip (save, fetch, delete).
4. Unit test: `orderedWorkspaces` sorting by `updatedAt`.
5. Existing Session tests pass unchanged.

**Acceptance criteria:**
- [ ] `WorkspaceManager` compiles with `@Observable @MainActor`, strict concurrency clean.
- [ ] `.file` workspace lifecycle matches `SessionManager` behaviour.
- [ ] Database CRUD works for workspaces.
- [ ] File watcher starts on create, stops on close.
- [ ] `onFileChanged` bridge fires on file modification.
- [ ] All existing tests pass.

---

### W2: Application Integration — Swap Workspace for Session

**Objective:** Wire `WorkspaceManager` into `AppDependencies`, route the `openSession` hotkey to create `.file` workspaces, and update coordinators to resolve against workspaces instead of sessions.

**Description:**
`AppDependencies` creates `WorkspaceManager` alongside `SessionManager` (dual-stack). The `openSession` hotkey creates a `.file` workspace via `WorkspaceManager`. `SessionQuestionCoordinator` gains a `WorkspaceManager` dependency and resolves snippets against workspaces. `SessionResolver` is adapted (or a `WorkspaceResolver` introduced) to score workspaces.

During W2, both managers coexist. `SessionManager` handles legacy sessions. `WorkspaceManager` handles new workspaces. The question coordinator checks workspaces first, falls back to sessions.

**Dependencies:** W1 (WorkspaceManager).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/App/AppDependencies.swift` | Add `workspaceManager` property, wire in `performDeferredStartup()`, route `openSession` hotkey to `WorkspaceManager` |
| `Decode/Application/SessionQuestionCoordinator.swift` | Add `workspaceManager` dependency, resolve against workspaces first |
| `Decode/Application/SessionResolver.swift` | Adapt to accept `ManagedWorkspace` inputs (or introduce `WorkspaceResolver`) |

**New files:**

| File | Purpose |
|------|---------|
| `Decode/Application/WorkspaceResolver.swift` | Resolves snippets against open workspaces (mirrors `SessionResolver` logic) |

**Public API changes:**
- `AppDependencies.workspaceManager: WorkspaceManager?` (created in deferred startup)
- `WorkspaceResolver.resolve(snippet:workspaces:activeWorkspaceId:pinnedWorkspaceId:) -> ResolvedWorkspace?`

**Risks:**
- Dual-stack (SessionManager + WorkspaceManager) creates ambiguity during the transition. Mitigated by workspace-first resolution with session fallback.
- Hotkey routing change could break existing flow. Mitigated by keeping `SessionManager` functional as fallback.

**Verification strategy:**
1. Build succeeds.
2. Manual test: ⌃⇧O opens file picker, creates `.file` workspace, appears in dock.
3. Manual test: Double-tap Shift resolves snippet against workspace.
4. Unit test: `WorkspaceResolver` scoring matches `SessionResolver` for single-file case.
5. All existing tests pass.

**Acceptance criteria:**
- [ ] `AppDependencies` creates and owns `WorkspaceManager`.
- [ ] ⌃⇧O hotkey creates `.file` workspace.
- [ ] Snippet resolution works against workspaces.
- [ ] Legacy sessions still resolve as fallback.
- [ ] All existing tests pass.

---

### W3: Session Removal — Complete Migration

**Objective:** Remove `SessionManager`, `Session`, and all session-specific code. `WorkspaceManager` is now the sole owner of tracked file/directory contexts. Data migration converts existing sessions to `.file` workspaces.

**Description:**
Database migration `v3_migrate_sessions` copies rows from `sessions` to `workspaces` (kind = 'file'), then drops the `sessions` table. `SessionManager` is deleted. All references to `Session` are replaced by `Workspace`. `ManagedSession` is replaced by `ManagedWorkspace`. `SessionResolver` is replaced by `WorkspaceResolver`. `SessionQuestionCoordinator` is renamed to `WorkspaceQuestionCoordinator`. The `entities` table foreign key is re-pointed from `sessions.id` to `workspaces.id`.

This is the highest-risk milestone. It touches the most files but is the necessary consolidation step.

**Dependencies:** W2 (dual-stack operational).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Domain/Models/Session.swift` | **Delete** |
| `Decode/Application/SessionManager.swift` | **Delete** |
| `Decode/Application/SessionResolver.swift` | **Delete** (replaced by WorkspaceResolver) |
| `Decode/Application/SessionQuestionCoordinator.swift` | **Rename** to `WorkspaceQuestionCoordinator.swift`, update all `Session` → `Workspace` references |
| `Decode/Application/SessionContext.swift` | Rename internal references or keep as-is if struct name is still accurate |
| `Decode/App/AppDependencies.swift` | Remove `sessionManager`, `sessionViewModel` properties; `workspaceManager` becomes sole manager |
| `Decode/Presentation/Session/SessionViewModel.swift` | **Rename** to `WorkspaceViewModel.swift`, delegate to `WorkspaceManager` |
| `Decode/Presentation/Session/SessionView.swift` | Update references from Session to Workspace |
| `Decode/Presentation/Session/FloatingSessionDock.swift` | Update references |
| `Decode/Presentation/Session/SessionDockContentView.swift` | Update references |
| `Decode/Infrastructure/Database/DatabaseMigrator.swift` | Add `v3_migrate_sessions` migration |
| `Decode/Infrastructure/Database/DatabaseService.swift` | Remove session CRUD, keep workspace CRUD |
| `Decode/Infrastructure/Database/Records/SessionRecord.swift` | **Delete** |
| `Decode/Infrastructure/Database/Records/EntityRecord.swift` | Update FK from `sessionId` to `workspaceId` |
| `Decode/Domain/Protocols/DatabaseServiceProtocol.swift` | Remove session methods |
| `DecodeTests/SessionResolverTests.swift` | **Rename** to `WorkspaceResolverTests.swift`, adapt |
| `DecodeTests/SessionQuestionCoordinatorTests.swift` | Adapt to workspace types (if exists) |
| `project.yml` | Update file references after renames |

**New files:** None (renames only).

**Public API changes:**
- `Session` type removed. All consumers use `Workspace`.
- `SessionManager` removed. All consumers use `WorkspaceManager`.
- `SessionResolver` removed. All consumers use `WorkspaceResolver`.
- `activeSessionId` → `activeWorkspaceId` throughout.
- `pinnedSessionId` → `pinnedWorkspaceId` throughout.
- `SessionContext` may be preserved as-is (it describes snippet context, not file identity).

**Risks:**
- **High risk** — touches 15+ files simultaneously. Mitigated by W2 dual-stack proving workspace path works before session removal.
- Data migration could lose sessions. Mitigated by `v3_migrate_sessions` copying data before dropping table. DEBUG `eraseDatabaseOnSchemaChange` provides safety net.
- Renames break `project.yml` source lists. Mitigated by running `xcodegen generate` after all renames.

**Verification strategy:**
1. Build succeeds after all renames.
2. `xcodegen generate` produces valid project.
3. All renamed tests pass.
4. Manual test: existing `.file` workspaces survive app restart (DB migration).
5. Manual test: full flow (⌃⇧O → file → explain → follow-up → improve) works.
6. No references to `Session` remain in source (grep verification).

**Acceptance criteria:**
- [ ] Zero references to `SessionManager`, `Session` (the model), `SessionResolver`, `ManagedSession` in source.
- [ ] `v3_migrate_sessions` migration copies sessions → workspaces and drops sessions table.
- [ ] All user-facing flows work with workspace path.
- [ ] All tests pass.
- [ ] `xcodegen generate` succeeds.

---

### W4: Directory Workspace — Ingestion

**Objective:** Enable `.directory` workspaces. User selects a folder via ⌃⇧P. Decode scans the directory, discovers source files, and batch-ingests them through the understanding pipeline.

**Description:**
New hotkey `⌃⇧P` (openWorkspace) opens `NSOpenPanel` with `canChooseDirectories = true`, `canChooseFiles = false`. Creates a `.directory` workspace with `rootPath` set to the selected directory.

`IndexingCoordinator` is the new service responsible for batch ingestion:
1. **Manifest scan** — `FileManager.default.enumerator` discovers all source files (filtered by supported extensions: `.swift`, `.py`, `.js`, `.ts`, `.java`, `.c`, `.cpp`, `.cs`, `.html`, `.css`). Ignores hidden directories, `node_modules`, `.git`, `build`, `DerivedData`, `.xcodeproj`, `.xcworkspace`.
2. **Batch ingestion** — groups files into batches of 20. For each batch, creates `FileChangeEvent(.modified)` for each file and calls `UnderstandingSystem.processChanges()`. Pipeline handles N files natively.
3. **Progress tracking** — `IndexingCoordinator` publishes `IndexingState` (`.idle`, `.scanning`, `.indexing(processed: Int, total: Int)`, `.complete`).
4. **Progressive availability** — after each batch, the DIR contains partial intelligence. Queries can run against partially-indexed workspaces.

The `WorkspaceManager` creates an `IndexingCoordinator` for each `.directory` workspace.

**Dependencies:** W1 (WorkspaceManager), W3 (session removal — clean workspace-only codebase).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Domain/Protocols/HotkeyServiceProtocol.swift` | Add `.openWorkspace` case to `HotkeyAction` |
| `Decode/Infrastructure/Hotkey/HotkeyService.swift` | Register ⌃⇧P chord for `.openWorkspace` |
| `Decode/App/AppDependencies.swift` | Route `.openWorkspace` hotkey, pass `UnderstandingSystem` to `IndexingCoordinator` |
| `Decode/Application/WorkspaceManager.swift` | Handle `.directory` creation, own `IndexingCoordinator` per workspace |

**New files:**

| File | Purpose |
|------|---------|
| `Decode/Application/IndexingCoordinator.swift` | Manifest scan, batch ingestion, progress tracking |
| `DecodeTests/IndexingCoordinatorTests.swift` | Unit tests for scanning, filtering, batching |

**Public API changes:**
- `HotkeyAction.openWorkspace` — new hotkey action
- `IndexingCoordinator`: `@Observable @MainActor` class
  - `start(rootPath: String, pipeline: UnderstandingSystemProtocol) async`
  - `cancel()`
  - `state: IndexingState` (published)
- `IndexingState`: enum with `.idle`, `.scanning`, `.indexing(processed: Int, total: Int)`, `.complete`, `.failed(Error)`

**Risks:**
- Large repositories (10,000+ files) could overwhelm the pipeline. Mitigated by batch processing with 20 files per batch and `Task.yield()` between batches.
- File manifest could include binary/generated files. Mitigated by extension allowlist and directory exclusion list.
- Memory pressure from large DIRs. Mitigated by StorageEngine snapshots (already implemented) and deferred to performance optimisation if needed.

**Verification strategy:**
1. Build succeeds.
2. Unit test: manifest scan discovers correct files, excludes hidden/build directories.
3. Unit test: batching groups files correctly.
4. Unit test: progress state transitions (idle → scanning → indexing → complete).
5. Integration test: batch of 5 Swift files processes through pipeline, DIR contains entities from all files.
6. Manual test: ⌃⇧P opens folder picker, indexing begins, progress visible.

**Acceptance criteria:**
- [ ] ⌃⇧P opens `NSOpenPanel` for directory selection.
- [ ] `.directory` workspace created with correct `rootPath`.
- [ ] Manifest scan discovers source files, respects exclusion list.
- [ ] Batch ingestion feeds files through `UnderstandingSystem.processChanges()`.
- [ ] `IndexingState` publishes correct progress.
- [ ] Pipeline produces DIR with entities from all ingested files.
- [ ] All tests pass.

---

### W5: Directory Watching — FSEvents

**Objective:** Watch `.directory` workspaces for file changes using recursive FSEvents monitoring. Automatically re-index modified/added/deleted files.

**Description:**
New `DirectoryWatcherService` uses `FSEvents` API for recursive directory monitoring. Replaces the per-file `DispatchSource` approach used by `FileWatcherService` (which continues to serve `.file` workspaces).

Change detection flow:
1. FSEvents reports changed paths.
2. Debounce at 300ms per file, 500ms per batch, 2s max delay.
3. Classify each change: new file → `.modified` (triggers full parse), modified file → `.modified`, deleted file → `.deleted`.
4. Feed `[FileChangeEvent]` to `UnderstandingSystem.processChanges()`.
5. Pipeline incrementally updates the DIR (indexes, composition passes re-run as needed).

**Dependencies:** W4 (directory workspaces exist).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Application/WorkspaceManager.swift` | Start `DirectoryWatcherService` for `.directory` workspaces |
| `Decode/App/AppDependencies.swift` | Wire `onFileChanged` bridge for directory watchers |

**New files:**

| File | Purpose |
|------|---------|
| `Decode/Infrastructure/FileSystem/DirectoryWatcherService.swift` | FSEvents recursive directory watcher with debouncing |
| `Decode/Domain/Protocols/DirectoryWatcherProtocol.swift` | Protocol for directory watching: `startWatching(directoryURL:) -> AsyncStream<[FileChangeEvent]>`, `stopWatching()` |
| `DecodeTests/DirectoryWatcherServiceTests.swift` | Unit tests for debouncing, exclusion, event classification |

**Public API changes:**
- `DirectoryWatcherProtocol`: `startWatching(directoryURL: URL) -> AsyncStream<[FileChangeEvent]>`, `stopWatching()`
- `DirectoryWatcherService`: `@unchecked Sendable` implementation using `FSEventStream`

**Risks:**
- FSEvents API is C-based, requires careful memory management. Mitigated by wrapping in a clean Swift class with `DispatchQueue` serialisation.
- High-frequency saves (e.g., auto-save editors) could flood the pipeline. Mitigated by multi-level debouncing (file-level, batch-level, max delay).
- Watching `node_modules` or `.git` could generate noise. Mitigated by reusing the exclusion list from W4's manifest scan.

**Verification strategy:**
1. Build succeeds.
2. Unit test: debounce coalesces rapid changes to same file.
3. Unit test: exclusion list filters ignored directories.
4. Unit test: change classification (new/modified/deleted) correct.
5. Manual test: modify a file in a `.directory` workspace, observe re-indexing.
6. Manual test: add a new file, observe it appears in workspace intelligence.
7. Manual test: delete a file, observe cleanup.

**Acceptance criteria:**
- [ ] `DirectoryWatcherService` compiles, strict concurrency clean.
- [ ] Recursive watching detects changes in subdirectories.
- [ ] Debouncing prevents duplicate processing.
- [ ] Excluded directories are never reported.
- [ ] `FileChangeEvent` array routed to `UnderstandingSystem.processChanges()`.
- [ ] All tests pass.

---

### W6: Workspace UI — Navigation and Project Explorer

**Objective:** Extend the Session View (now Workspace View) to display `.directory` workspace contents. Add a project explorer tree view in the left sidebar. Enable file/entity navigation within a workspace.

**Description:**
The left sidebar of the Knowledge Inspector (currently a flat list of sessions/workspaces) gains a tree view for `.directory` workspaces showing the file hierarchy. Selecting a file in the tree sets it as the active file within the workspace. The center column shows the selected file's intelligence (entities, relationships, purpose, etc.). The entity detail panel shows the selected entity.

`NavigationState` tracks the active file and entity within a workspace:
- `activeFilePathInWorkspace: String?` — which file the user is viewing
- `activeEntityId: String?` — which entity is selected

For `.file` workspaces, the tree view is hidden and behaviour matches today's Session View exactly.

The floating dock pills show a folder icon for `.directory` workspaces (vs document icon for `.file`). Context menu adds "Reveal in Finder" for directories.

**Dependencies:** W4 (directory workspaces with indexed content).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Presentation/Session/SessionView.swift` | Rename to `WorkspaceView.swift`. Add tree view sidebar for `.directory` workspaces. Conditionally show file list or knowledge content based on workspace kind. |
| `Decode/Presentation/Session/SessionViewModel.swift` | (Already renamed in W3) Add `NavigationState`, file selection, entity selection |
| `Decode/Presentation/Session/FloatingSessionDock.swift` | Rename to `FloatingWorkspaceDock.swift`. Show folder/document icon per workspace kind. |
| `Decode/Presentation/Session/SessionDockContentView.swift` | Rename to `WorkspaceDockContentView.swift`. Display `rootFileName` for workspaces. |
| `project.yml` | Update source file references |

**New files:**

| File | Purpose |
|------|---------|
| `Decode/Presentation/Session/ProjectExplorerView.swift` | Tree view of files in a `.directory` workspace, grouped by subdirectory |
| `Decode/Application/NavigationState.swift` | `@Observable` class tracking active file/entity within a workspace |

**Public API changes:**
- `NavigationState.activeFilePath: String?`
- `NavigationState.activeEntityId: String?`
- `NavigationState.selectFile(path:)`, `selectEntity(id:)`

**Risks:**
- Tree view for large projects could have performance issues. Mitigated by lazy loading (only expand directories on click) and limiting initial display to top-level.
- Renaming Presentation files in W3 + W6 creates churn. Mitigated by doing all renames in W3 and only adding new views in W6.

**Verification strategy:**
1. Build succeeds.
2. Manual test: `.file` workspace shows identical UI to current Session View.
3. Manual test: `.directory` workspace shows tree view in left sidebar.
4. Manual test: selecting a file in tree updates center column with file intelligence.
5. Manual test: selecting an entity updates right panel.
6. Manual test: dock shows correct icon for each workspace kind.

**Acceptance criteria:**
- [ ] `.file` workspaces render identically to current Session View.
- [ ] `.directory` workspaces show project explorer tree.
- [ ] File selection navigates to file intelligence.
- [ ] Entity selection navigates to entity detail.
- [ ] Dock distinguishes workspace kinds visually.
- [ ] All tests pass.

---

### W7: Workspace Question Resolution — Multi-File

**Objective:** Enable the Double-tap Shift question flow to resolve snippets against any file within a `.directory` workspace. The user works in their IDE; Decode identifies which workspace file the snippet belongs to.

**Description:**
Today, `SessionResolver` scores snippets against open sessions (each tracking one file). `WorkspaceResolver` (introduced in W2) must now also search within `.directory` workspaces: score the snippet against the parsed entities of every indexed file in the workspace.

Resolution priority (unchanged from Session Mode):
1. Pinned workspace → unconditional override
2. Entity containment match (100 pts per entity name match in snippet)
3. File content match (60 pts for normalised content overlap)
4. Recency bonus (up to 20 pts for recently active workspace)
5. Active workspace bonus (10 pts)

For `.directory` workspaces, entity containment checks span all files. A match within any file of the workspace resolves to that workspace + that file. `NavigationState` is updated to the matched file.

`WorkspaceQuestionCoordinator` passes the resolved file path to `PipelineQueryService.query()` (unchanged API — it already accepts arbitrary file paths).

**Dependencies:** W2 (WorkspaceResolver), W4 (directory workspaces with indexed entities).

**Affected files:**

| File | Change |
|------|--------|
| `Decode/Application/WorkspaceResolver.swift` | Extend to search within `.directory` workspace file entities |
| `Decode/Application/WorkspaceQuestionCoordinator.swift` | (Renamed in W3) Set `NavigationState.activeFilePath` on resolution |
| `Decode/Application/WorkspaceManager.swift` | Expose `parsedEntitiesByFile: [String: [ParsedEntity]]` for `.directory` workspaces |

**New files:**

| File | Purpose |
|------|---------|
| `DecodeTests/WorkspaceResolverMultiFileTests.swift` | Tests for multi-file resolution within directory workspaces |

**Public API changes:**
- `WorkspaceResolver.resolve()` now searches within directory workspace files
- `ManagedWorkspace.parsedEntitiesByFile: [String: [ParsedEntity]]` — per-file entity map for directory workspaces

**Risks:**
- Large workspaces (1,000+ files) could make resolution slow. Mitigated by early-exit on high-confidence match (score > threshold) and limiting entity search to files with matching language.
- Ambiguous resolution across workspace files. Mitigated by same ambiguity threshold (10 points) used in SessionResolver.

**Verification strategy:**
1. Build succeeds.
2. Unit test: snippet containing entity from file A in directory workspace resolves to that workspace + file A.
3. Unit test: snippet not matching any workspace returns nil.
4. Unit test: pinned workspace overrides.
5. Manual test: open directory workspace, work in IDE, Double-tap Shift explains code from a file within the workspace.

**Acceptance criteria:**
- [ ] Snippet resolution works across all files in a `.directory` workspace.
- [ ] Resolved file path passed correctly to `PipelineQueryService`.
- [ ] `NavigationState` updated to matched file.
- [ ] Pinned workspace override works for directory workspaces.
- [ ] All tests pass.

---

## 3. Dependency Graph

```
W0 (Domain Foundation)
 │
 ├──→ W1 (WorkspaceManager)
 │     │
 │     ├──→ W2 (Application Integration)
 │     │     │
 │     │     ├──→ W3 (Session Removal)
 │     │     │     │
 │     │     │     ├──→ W4 (Directory Ingestion)
 │     │     │     │     │
 │     │     │     │     ├──→ W5 (Directory Watching)
 │     │     │     │     │
 │     │     │     │     ├──→ W6 (Workspace UI)
 │     │     │     │     │
 │     │     │     │     └──→ W7 (Multi-File Resolution)
```

**Critical path:** W0 → W1 → W2 → W3 → W4 → W5/W6/W7 (parallel)

**Parallel opportunities:**
- W5, W6, W7 are independent once W4 completes.
- W5 and W6 have zero code overlap.
- W7 depends on W2 (WorkspaceResolver) + W4 (indexed content) but not W5 or W6.

---

## 4. File Migration Plan

### Files to Create (8 new files)

| Milestone | File | Lines (est.) |
|-----------|------|-------------|
| W0 | `Decode/Domain/Models/Workspace.swift` | ~40 |
| W0 | `Decode/Infrastructure/Database/Records/WorkspaceRecord.swift` | ~55 |
| W1 | `Decode/Application/WorkspaceManager.swift` | ~650 |
| W2 | `Decode/Application/WorkspaceResolver.swift` | ~350 |
| W4 | `Decode/Application/IndexingCoordinator.swift` | ~250 |
| W5 | `Decode/Infrastructure/FileSystem/DirectoryWatcherService.swift` | ~200 |
| W5 | `Decode/Domain/Protocols/DirectoryWatcherProtocol.swift` | ~25 |
| W6 | `Decode/Presentation/Session/ProjectExplorerView.swift` | ~200 |
| W6 | `Decode/Application/NavigationState.swift` | ~50 |

### Files to Delete (W3)

| File | Replacement |
|------|-------------|
| `Decode/Domain/Models/Session.swift` | `Workspace.swift` |
| `Decode/Application/SessionManager.swift` | `WorkspaceManager.swift` |
| `Decode/Application/SessionResolver.swift` | `WorkspaceResolver.swift` |
| `Decode/Infrastructure/Database/Records/SessionRecord.swift` | `WorkspaceRecord.swift` |

### Files to Rename (W3 + W6)

| Original | New Name |
|----------|----------|
| `SessionQuestionCoordinator.swift` | `WorkspaceQuestionCoordinator.swift` |
| `SessionViewModel.swift` | `WorkspaceViewModel.swift` |
| `SessionView.swift` | `WorkspaceView.swift` |
| `FloatingSessionDock.swift` | `FloatingWorkspaceDock.swift` |
| `SessionDockContentView.swift` | `WorkspaceDockContentView.swift` |

### Files Modified (not renamed)

| File | Milestones |
|------|-----------|
| `AppDependencies.swift` | W1, W2, W3, W4, W5 |
| `DatabaseMigrator.swift` | W0, W3 |
| `DatabaseService.swift` | W1, W3 |
| `DatabaseServiceProtocol.swift` | W1, W3 |
| `HotkeyServiceProtocol.swift` | W4 |
| `HotkeyService.swift` | W4 |
| `EntityRecord.swift` | W3 |
| `project.yml` | W3, W4, W6 |

### Files NOT Modified (frozen)

All understanding pipeline modules, reasoning engines, composition passes, context strategies, frontends, and `UnderstandingSystem` remain untouched. The pipeline is consumed, not modified.

---

## 5. Testing Strategy

### Unit Tests (per milestone)

| Milestone | Test File | Tests (est.) |
|-----------|-----------|-------------|
| W0 | `WorkspaceModelTests.swift` | 5 (Codable, Hashable, record round-trip) |
| W1 | `WorkspaceManagerTests.swift` | 12 (lifecycle, DB, ordering, watcher) |
| W2 | `WorkspaceResolverTests.swift` | 10 (scoring, pinned, fallback) |
| W3 | Adapted from `SessionResolverTests.swift` | 10 (same tests, workspace types) |
| W4 | `IndexingCoordinatorTests.swift` | 10 (scan, filter, batch, progress) |
| W5 | `DirectoryWatcherServiceTests.swift` | 8 (debounce, exclusion, classification) |
| W7 | `WorkspaceResolverMultiFileTests.swift` | 8 (cross-file resolution) |

### Integration Tests

| Scope | Description |
|-------|-------------|
| W4 | Batch of 5 files → pipeline → DIR contains all entities |
| W7 | Snippet → workspace resolution → pipeline query → understanding |

### Manual Tests (per milestone)

Each milestone includes a manual test checklist in its acceptance criteria. The golden path for end-to-end validation:

1. **File workspace flow** (must work identically to today's Session):
   ⌃⇧O → select file → knowledge inspector → Double-tap Shift → explain → follow-up → improve

2. **Directory workspace flow** (new):
   ⌃⇧P → select folder → indexing progress → project explorer → select file → Double-tap Shift → explain

### Regression Guards

- All existing tests must pass at every milestone (enforced by acceptance criteria).
- `grep -r "SessionManager\|class Session " Decode/` returns zero matches after W3.
- Build with `SWIFT_STRICT_CONCURRENCY = complete` must be clean at every milestone.

---

## 6. Rollback Strategy

### Per-Milestone Rollback

Each milestone is independently shippable and revertable:

| Milestone | Rollback Method |
|-----------|----------------|
| W0 | Remove `Workspace.swift`, `WorkspaceRecord.swift`, remove `v2_workspaces` migration. No user-visible impact. |
| W1 | Remove `WorkspaceManager.swift`. No user-visible impact (Session still works). |
| W2 | Revert `AppDependencies` to Session-only. Remove `WorkspaceResolver`. Session path restored. |
| W3 | **Cannot independently roll back** — this is the point of no return. Rollback requires reverting W3+W2+W1+W0 together. Mitigated by thorough W2 validation before proceeding. |
| W4 | Remove `IndexingCoordinator`, `.openWorkspace` hotkey. `.file` workspaces continue working. |
| W5 | Remove `DirectoryWatcherService`. Directory workspaces work but don't live-update. |
| W6 | Revert UI changes. Directory workspaces indexed but not visually navigable. |
| W7 | Revert resolver extension. Double-tap Shift only resolves `.file` workspaces. |

### Database Rollback

- `eraseDatabaseOnSchemaChange = true` in DEBUG ensures clean slate on schema changes during development.
- Production: `v3_migrate_sessions` copies data before dropping. If rollback needed, restore from pre-migration backup (alpha scale — manual recovery acceptable).

### Critical Gate: W2 → W3

W3 (Session Removal) is irreversible. **W3 must not begin until:**
1. All W2 acceptance criteria pass.
2. `.file` workspace flow is manually verified end-to-end.
3. All existing tests pass against workspace path.
4. At least one full day of dogfooding with workspace dual-stack.

---

## 7. Definition of Done

### Per-Milestone Done

A milestone is complete when:
1. All acceptance criteria are checked off.
2. Build succeeds with `SWIFT_STRICT_CONCURRENCY = complete`.
3. All unit tests pass (existing + new).
4. `xcodegen generate` produces a valid project (if files were added/removed/renamed).
5. No `#if DEBUG`-gated `print()` statements added without justification.
6. Code follows layered architecture (Presentation → Application → Domain → Infrastructure).
7. No pipeline module imports added or changed.

### Epic Done

The Workspace Mode epic is complete when:
1. All 8 milestones (W0–W7) are complete.
2. The `Session` type no longer exists in the codebase.
3. `.file` workspaces provide identical UX to former Sessions.
4. `.directory` workspaces support: folder selection, batch indexing, progress tracking, recursive file watching, project explorer navigation, multi-file question resolution.
5. All tests pass (est. 60+ new tests across 7 test files).
6. `PROJECT_INTELLIGENCE_IMPLEMENTATION_STATUS.md` updated with Workspace Mode status.
7. `CLAUDE.md` updated to reflect workspace terminology and architecture.

---

## Appendix A: Workspace Model Schema

```swift
enum WorkspaceKind: String, Sendable, Codable, Hashable {
    case file       // Single file (degenerate case, matches today's Session)
    case directory  // Project directory with full indexing
}

struct Workspace: Identifiable, Sendable, Codable, Hashable {
    let id: UUID
    let kind: WorkspaceKind
    let createdAt: Date
    var updatedAt: Date

    /// Security-scoped bookmark for sandbox persistence.
    var bookmarkData: Data

    /// Canonical root path.
    /// - `.file`: the file path (e.g., `/Users/dev/project/Sources/Foo.swift`)
    /// - `.directory`: the directory path (e.g., `/Users/dev/project`)
    var rootPath: String

    /// Display name.
    /// - `.file`: file name (e.g., `Foo.swift`)
    /// - `.directory`: directory name (e.g., `project`)
    var rootFileName: String

    /// AI-generated summary of the workspace's purpose.
    var summaryText: String

    /// Whether the workspace's records are known to be corrupted.
    var isCorrupted: Bool
}
```

## Appendix B: IndexingState Schema

```swift
enum IndexingState: Sendable {
    case idle
    case scanning
    case indexing(processed: Int, total: Int)
    case complete
    case failed(Error)

    var isActive: Bool {
        switch self {
        case .scanning, .indexing: return true
        default: return false
        }
    }

    var progressFraction: Double? {
        guard case .indexing(let processed, let total) = self,
              total > 0 else { return nil }
        return Double(processed) / Double(total)
    }
}
```

## Appendix C: File Extension Allowlist

```swift
static let supportedExtensions: Set<String> = [
    "swift", "py", "js", "ts", "jsx", "tsx",
    "java", "c", "cpp", "h", "hpp", "cs",
    "html", "css"
]
```

## Appendix D: Directory Exclusion List

```swift
static let excludedDirectories: Set<String> = [
    ".git", ".svn", ".hg",
    "node_modules", "Pods", "Carthage",
    "build", "Build", "DerivedData",
    ".build", ".swiftpm",
    ".xcodeproj", ".xcworkspace",
    "__pycache__", ".pytest_cache",
    "dist", ".next", ".nuxt",
    "vendor", ".gradle",
    ".idea", ".vscode",
]
```

## Appendix E: 21 Single-File Assumptions to Address

Catalogued during architecture review. Each is resolved by the milestone indicated.

| # | Layer | Assumption | Resolution Milestone |
|---|-------|-----------|---------------------|
| 1 | Domain | `Session.filePath: String` (single file) | W0 (`Workspace.rootPath` + `kind`) |
| 2 | Domain | `Session.fileName: String` (single name) | W0 (`Workspace.rootFileName`) |
| 3 | Domain | `Session.fileHash: String` / `fileSize` / `fileModifiedAt` (single file metadata) | W0 (removed from Workspace — per-file metadata tracked in ManagedWorkspace) |
| 4 | Application | `SessionManager.createSession(url:)` single file | W1 (`WorkspaceManager.createWorkspace(url:)` handles both kinds) |
| 5 | Application | `ManagedSession.fileWatcher: FileWatcherService` single file | W1/W5 (`.file` uses `FileWatcherService`, `.directory` uses `DirectoryWatcherService`) |
| 6 | Application | `ManagedSession.parsedEntities: [ParsedEntity]` single file | W4 (`.directory` ManagedWorkspace has `parsedEntitiesByFile: [String: [ParsedEntity]]`) |
| 7 | Application | `SessionResolver` scores against single-file sessions | W2/W7 (`WorkspaceResolver` scores within directory files) |
| 8 | Application | `SessionQuestionCoordinator` resolves one session | W2 (resolves workspace + file within workspace) |
| 9 | Application | `ContextBuilderService` assumes single session file | No change needed (receives file path, works per-file) |
| 10 | Application | `SemanticEnrichmentService` per-file | No change needed (called per-file, workspace triggers per indexed file) |
| 11 | Application | `ImprovementService` assumes single file | No change needed (operates on snippet, file-agnostic) |
| 12 | Presentation | `SessionViewModel.openFile()` `canChooseDirectories = false` | W4 (separate `openWorkspace()` with `canChooseDirectories = true`) |
| 13 | Presentation | `SessionView` flat session list sidebar | W6 (tree view for `.directory` workspaces) |
| 14 | Presentation | `SessionDockContentView` shows `fileName` | W3/W6 (shows `rootFileName` with kind-appropriate icon) |
| 15 | Presentation | `FloatingSessionDock` document icon only | W6 (folder icon for `.directory`) |
| 16 | Presentation | Knowledge Inspector center column assumes single file | W6 (shows selected file's intelligence, switchable) |
| 17 | Presentation | Entity detail panel assumes single file entities | W6 (filtered to selected file's entities) |
| 18 | Presentation | "Coming Soon" placeholders for Module/Project Intelligence | W6 (populated with real module/project data) |
| 19 | Presentation | Context menu "Copy File Path" copies single path | W6 (copies selected file or root path) |
| 20 | Infrastructure | `FileWatcherService` watches one file's parent | W5 (`DirectoryWatcherService` for recursive watching) |
| 21 | Infrastructure | `HotkeyAction` has no workspace action | W4 (`.openWorkspace` added) |

---

*This document is the canonical implementation specification for the Workspace Mode epic. It does not modify any frozen architecture specification (DAS/DDS/IAG). All pipeline modules, reasoning engines, and composition passes are consumed unchanged.*
