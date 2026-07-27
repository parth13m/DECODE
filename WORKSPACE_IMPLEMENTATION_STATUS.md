# Workspace Mode Implementation Status

## Purpose

This file tracks the implementation state of the Workspace Mode epic (W0–W7). It serves as a handoff document for future Claude Code sessions. All milestones are complete. This document is read-only.

---

## Epic Summary

Workspace Mode replaces Session-first with Workspace-first application architecture. Users open files or directories as workspaces. All intelligence operations (Explain, Improve, Follow-up) resolve against workspaces instead of sessions.

**Status: Complete.** All 8 milestones implemented and verified.

---

## Milestones

| Milestone | Name | Status |
|-----------|------|--------|
| W0 | Domain model design | Complete |
| W1 | GRDB persistence layer | Complete |
| W2 | WorkspaceManager + dual-stack coordinator | Complete |
| W3 | Session → Workspace migration | Complete |
| W4 | Directory workspace + IndexingCoordinator | Complete |
| W5 | DirectoryWatcherService | Complete |
| W6 | Workspace UI (NavigationState, ProjectExplorerView) | Complete |
| W7 | Multi-file resolution (WorkspaceResolver extension) | Complete |

---

## Architecture

### Domain Layer

- `Workspace` — persisted model with `id`, `kind`, `createdAt`, `updatedAt`, `bookmarkData`, `rootPath`, `rootFileName`, `summaryText`, `isCorrupted`.
- `WorkspaceKind` — `.file` or `.directory`.
- `DirectoryWatcherProtocol` — contract for recursive directory monitoring.

### Application Layer

- `WorkspaceManager` — CRUD, security-scoped bookmarks, file accessibility monitoring, file watcher lifecycle management.
- `ManagedWorkspace` — runtime wrapper. Key properties: `parsedEntities`, `parsedEntitiesByFile: [String: [ParsedEntity]]`, `indexingCoordinator`, `directoryWatcher`, `directoryWatcherTask`, `isFileAccessible`, `navigationState`.
- `WorkspaceResolver` — scores workspaces against snippets. For `.directory` workspaces, searches `parsedEntitiesByFile` across all indexed files. Returns `resolvedFilePath` for file-within-directory matches.
- `WorkspaceResolution` — result type with `workspace`, `confidence`, `method`, `candidates`, `resolvedFilePath`.
- `IndexingCoordinator` — scans file manifest, batches files (20/batch) through the pipeline. `IndexingState` enum: `.idle`, `.scanning`, `.indexing(progress)`, `.complete`, `.failed`.
- `NavigationState` — `@Observable @MainActor`. Tracks `activeFilePath` and `activeEntityId` within directory workspaces.

### Infrastructure Layer

- `DirectoryWatcherService` — FSEvents-based recursive directory monitor. 500ms debounce. Mod-date snapshot comparison. Reuses `IndexingCoordinator.supportedExtensions` and `excludedDirectories`. `@unchecked Sendable` with serial DispatchQueue.

### Presentation Layer

- `ProjectExplorerView` — hierarchical file tree built from flat paths via `FileTreeNode`. Directory grouping, file type icons, active file highlighting.
- `SessionDockContentView` — folder icon for `.directory` workspaces, indexing progress, "Reveal in Finder" context menu.
- `SessionView` — indexing progress header, file count badge, ProjectExplorerView sidebar in HSplitView.

### Coordinator Changes

- `SessionQuestionCoordinator` — derives `effectiveFilePath`/`effectiveFileName`/`effectiveEntities` from workspace resolution. Pipeline, context builder, health classifier, and analytics all use effective values.
- `AppDependencies` — `handleOpenWorkspace()` for directory open, `.openWorkspace` hotkey routing (⌃⇧P).

---

## Key Design Decisions

1. **WorkspaceResolver single-workspace short-circuit.** When only one workspace is open, returns immediately with `.singleWorkspace` method. No entity matching or `resolvedFilePath` in this path.
2. **parsedEntitiesByFile populated during pipeline processing.** Set by the workspace manager after batch ingestion, not by the directory watcher.
3. **effectiveFilePath pattern.** The coordinator derives effective values from resolution, not from workspace root. This cleanly handles `.file` (effective = root) vs `.directory` (effective = resolved file) without branching in every downstream call.
4. **IndexingCoordinator uses nonisolated static.** `supportedExtensions`, `excludedDirectories`, `batchSize`, `scanManifest`, `makeBatches` are all `nonisolated static` to allow use from DirectoryWatcherService and tests without `@MainActor` isolation.
5. **DirectoryWatcherService reuses IndexingCoordinator constants.** Single source of truth for supported extensions and excluded directories.
6. **NavigationState is separate from WorkspaceManager.** Prevents WorkspaceManager from becoming a god object. Owned by the view model.

---

## Files Created (W0–W7)

| File | Layer | Milestone |
|------|-------|-----------|
| `Decode/Domain/Models/Workspace.swift` | Domain | W0 |
| `Decode/Domain/Models/WorkspaceKind.swift` | Domain | W0 |
| `Decode/Domain/Protocols/DirectoryWatcherProtocol.swift` | Domain | W5 |
| `Decode/Application/WorkspaceManager.swift` | Application | W2 |
| `Decode/Application/WorkspaceResolver.swift` | Application | W2/W7 |
| `Decode/Application/IndexingCoordinator.swift` | Application | W4 |
| `Decode/Application/NavigationState.swift` | Application | W6 |
| `Decode/Infrastructure/FileSystem/DirectoryWatcherService.swift` | Infrastructure | W5 |
| `Decode/Presentation/Session/ProjectExplorerView.swift` | Presentation | W6 |
| `DecodeTests/Domain/WorkspaceKindTests.swift` | Tests | W0 |
| `DecodeTests/Domain/WorkspaceTests.swift` | Tests | W0 |
| `DecodeTests/Infrastructure/WorkspaceRecordTests.swift` | Tests | W1 |
| `DecodeTests/Application/WorkspaceManagerTests.swift` | Tests | W2 |
| `DecodeTests/Application/WorkspaceResolverTests.swift` | Tests | W2 |
| `DecodeTests/Application/IndexingCoordinatorTests.swift` | Tests | W4 |
| `DecodeTests/Infrastructure/DirectoryWatcherServiceTests.swift` | Tests | W5 |
| `DecodeTests/Application/NavigationStateTests.swift` | Tests | W6 |
| `DecodeTests/Presentation/ProjectExplorerTreeTests.swift` | Tests | W6 |
| `DecodeTests/Application/WorkspaceResolverMultiFileTests.swift` | Tests | W7 |

## Files Modified (W0–W7)

| File | Changes |
|------|---------|
| `Decode/App/AppDependencies.swift` | WorkspaceManager ownership, `handleOpenWorkspace()`, `processChanges` closure, `.openWorkspace` hotkey |
| `Decode/Application/SessionQuestionCoordinator.swift` | Workspace resolution, `effectiveFilePath`/`effectiveFileName`/`effectiveEntities`, `.openWorkspace` switch case |
| `Decode/Application/SelectionModeCoordinator.swift` | `.openWorkspace` switch case |
| `Decode/Application/ScreenshotModeCoordinator.swift` | `.openWorkspace` switch case |
| `Decode/Domain/Protocols/HotkeyServiceProtocol.swift` | `.openWorkspace` action |
| `Decode/Infrastructure/Hotkey/HotkeyService.swift` | `⌃⇧P` chord (keyCode 35) |
| `Decode/Presentation/Session/SessionViewModel.swift` | `navigationState`, `isDirectoryWorkspace`, `indexingState`, `discoveredFiles` |
| `Decode/Presentation/Session/SessionDockContentView.swift` | Folder icon, indexing progress, Reveal in Finder |
| `Decode/Presentation/Session/SessionView.swift` | Indexing header, file count, ProjectExplorerView sidebar |

---

## Verification

| Metric | Value |
|--------|-------|
| Build | Succeeds (Debug configuration) |
| Main test suite | 518 tests, 4 pre-existing failures, 0 new failures |
| Pipeline test suite | 43 tests, all passing |
| New workspace tests | 34 tests across 4 suites, all passing |
| Pre-existing failures | `streamChatFormatsMessages`, `showStreamHandlesError`, `emptyTagSkipped`, SwiftSyntaxFrontend entity names |

---

## Technical Debt (Intentionally Deferred)

1. **No persistent NavigationState** — resets on app restart. Acceptable at alpha.
2. **No search/filter in ProjectExplorerView** — display-only tree.
3. **DirectoryWatcherService watches root FD only** — relies on FSEvents propagation for nested changes.
4. **Re-indexing of changed files not fully wired** — watcher detects changes but triggering re-parse of individual changed files through the pipeline is a separate concern.
5. **parsedEntitiesByFile not persisted** — rebuilt on each indexing run.

---

## Session Handoff

Future sessions touching workspace code should:

1. Read `CLAUDE.md` — project rules, engineering principles, constraints.
2. Read this file — workspace architecture, design decisions, current state.
3. Read `SESSION_MODE_IMPLEMENTATION_STATUS.md` — pipeline architecture (if touching pipeline integration).
4. Inspect affected files — do not assume.
5. Implement production-quality code. No stubs.
6. Build and test. Verify zero new regressions beyond the 4 pre-existing failures.
7. Update this document if workspace architecture changes.
