# Decode Launcher Architecture

**Status**: ⚠️ SUPERSEDED — This document predates the orbital redesign (2026-08-12) and History integration. The canonical architecture document is now [`DECODE_LAUNCHER_ARCHITECTURE_AND_IMPLEMENTATION.md`](../DECODE_LAUNCHER_ARCHITECTURE_AND_IMPLEMENTATION.md) in the repository root. This file is retained for historical reference only.

**Date**: 2026-08-11
**Author**: Architecture specification derived from codebase inspection
**Scope**: Launcher feature — persistent UI surface for workspace content intake (pre-orbital layout)

---

## Preface: Codebase Inspection Summary

This document was produced by deep inspection of the Decode repository. Every architectural claim is grounded in the current implementation unless explicitly marked otherwise.

### A. Files Inspected

| File | Relevance |
|------|-----------|
| `Decode/Presentation/Overlay/FloatingLauncher.swift` | **Primary subject** — complete Launcher implementation |
| `Decode/App/AppDependencies.swift` | Root DI container; Launcher wiring, `handleOpenSession()`, `handleOpenWorkspace()` |
| `Decode/App/DecodeApp.swift` | SwiftUI App entry point, lifecycle notifications |
| `Decode/App/ContentView.swift` | Main window, session sheet presentation |
| `Decode/Application/WorkspaceManager.swift` | Workspace lifecycle, creation, dedup, persistence, indexing, watching |
| `Decode/Domain/Models/Workspace.swift` | Workspace domain model, GRDB persistence |
| `Decode/Domain/Models/WorkspaceKind.swift` | `.file` / `.directory` enum |
| `Decode/Application/WorkspaceResolver.swift` | Multi-workspace resolution scoring |
| `Decode/Application/IndexingCoordinator.swift` | Batch directory indexing, supported extensions, excluded dirs |
| `Decode/Infrastructure/FileSystem/DirectoryWatcherService.swift` | FSEvents monitoring for directories |
| `Decode/Infrastructure/FileSystem/FileWatcherService.swift` | Parent-directory monitoring for single files |
| `Decode/Application/SessionState.swift` | `SessionState` struct + `SessionStatePersistence` enum |
| `Decode/Application/NavigationState.swift` | Active file/entity within directory workspaces |
| `Decode/Presentation/Session/SessionViewModel.swift` | Session sheet ViewModel, `openFile()`, `openDirectory()`, `loadFile()`, `loadDirectory()` |
| `Decode/Presentation/Session/SessionView.swift` | Session sheet UI |
| `Decode/Presentation/Session/FloatingSessionDock.swift` | Right-edge floating dock panel |
| `Decode/Presentation/Overlay/FloatingExplanationHUD.swift` | Explanation overlay panel |
| `Decode/Presentation/Toast/DecodeToastManager.swift` | Toast notification panel |
| `Decode/Infrastructure/Hotkey/HotkeyService.swift` | Global hotkey monitoring |
| `Decode/Infrastructure/FileSystem/BookmarkManager.swift` | Stub — not implemented |
| `Decode/Application/SessionQuestionCoordinator.swift` | Session Mode question handling |
| `Decode/Application/SelectionModeCoordinator.swift` | Selection Mode coordinator |
| `Decode/Application/ScreenshotModeCoordinator.swift` | Screenshot Mode coordinator |
| `Decode/Infrastructure/AI/AnalyticsEventService.swift` | Fire-and-forget analytics |
| `Decode/Presentation/Session/ProjectExplorerView.swift` | Directory file tree sidebar |

### B. Existing Launcher-Related Implementation

**A complete, production-quality Launcher exists** at `Decode/Presentation/Overlay/FloatingLauncher.swift`. It is:
- Registered in the Xcode project
- Wired into `AppDependencies.performDeferredStartup()` (step 2d)
- Shown unconditionally after authentication
- Functional: Add File and Add Folder buttons trigger `NSOpenPanel` via `handleOpenSession()` / `handleOpenWorkspace()`

### C. Existing Workspace-Related Implementation

The workspace architecture is complete and production-ready:
- `WorkspaceManager` (`@Observable @MainActor`) — CRUD, dedup, persistence, watching, indexing
- Two workspace kinds: `.file` (single file) and `.directory` (project folder)
- `SessionState` / `SessionStatePersistence` — transient session state as JSON
- `IndexingCoordinator` — batch pipeline ingestion for directories
- `DirectoryWatcherService` / `FileWatcherService` — live filesystem monitoring
- `WorkspaceResolver` — multi-workspace resolution for question targeting

### D. Architectural Assumptions Discovered

1. The Launcher is a **thin UI surface** — it owns no workspace state and delegates entirely to `AppDependencies` callbacks.
2. The Launcher uses the **same `NSOpenPanel` code paths** as the hotkeys (`Control+Shift+O` / `Control+Shift+P`), which in turn delegate to `SessionViewModel.loadFile()` / `loadDirectory()`.
3. There is **no drag-and-drop** anywhere in the codebase. All file/folder intake is exclusively via `NSOpenPanel`.
4. There is **no `fileImporter`** (SwiftUI) usage. All file picking uses AppKit `NSOpenPanel.runModal()`.
5. The Launcher does not persist any state of its own.
6. The Launcher panel uses the same architectural pattern as FloatingSessionDock: `NSPanel` + `NSHostingView` + `NSTrackingArea`.

### E. Contradictions and Missing Information

1. **Type filtering inconsistency**: `SessionViewModel.openFile()` applies `allowedContentTypes` (40+ extensions via UTType), but `AppDependencies.handleOpenSession()` (used by Launcher and hotkeys) does **not** filter by content type. This means the Launcher accepts any file, while the in-session button restricts to known code types.
2. **No error feedback from Launcher**: When `WorkspaceManager.createFileWorkspace()` throws (e.g., `fileTooLarge`, `binaryFile`), the error is caught by `SessionViewModel.loadFile()` and set on `vm.errorMessage`. But the Launcher collapses immediately after triggering the action — the user may not see the error unless the session sheet opens.
3. **Launcher always shows on primary display**: Unlike the HUD (which follows mouse cursor), the Launcher is fixed to `NSScreen.main`. On multi-display setups, it may not be on the display the user is working on.
4. **BookmarkManager is a stub**: Security-scoped bookmarks are created but never resolved. The sandbox is disabled, so this works today but is a future risk.

---

## 1. Executive Summary

The **Launcher** is a persistent, always-visible floating UI element anchored to the left edge of the user's primary screen. It provides the fastest path for adding files and folders into Decode's workspace system.

The Launcher is architecturally a **thin input surface** — a front door to the workspace lifecycle. It owns no workspace state, performs no parsing, and has no knowledge of Decode's intelligence infrastructure. It delegates all workspace operations to `AppDependencies`, which routes them through `SessionViewModel` to `WorkspaceManager`.

The Launcher is **already fully implemented** in production code. This architecture document describes the existing implementation, identifies its integration points with the broader Decode architecture, proposes refinements where the current design has gaps, and establishes the architectural contract for future evolution.

**Key architectural properties:**
- Non-activating `NSPanel` — never steals focus from the user's editor
- Hover-to-expand interaction — no click required to reveal actions
- Two actions: Add File (multi-select) and Add Folder (single directory)
- Collapse-after-action — returns to sliver state after triggering an operation
- Zero state ownership — all workspace state lives in `WorkspaceManager`
- Same code paths as hotkeys — `handleOpenSession()` / `handleOpenWorkspace()`

---

## 2. Product Context

Decode is a **Software Intelligence Platform** for macOS. It runs as a background-aware overlay application: the user works in their editor (Xcode, VS Code, etc.) while Decode's floating surfaces (HUD, Dock, Launcher) provide intelligence on demand.

### The Workspace Abstraction

Everything Decode understands is organized into **Workspaces**:
- **File Workspace** (`.file`): A single source file. Parsed immediately on creation. Watched for changes.
- **Directory Workspace** (`.directory`): An entire project folder. Scanned, batch-indexed through the understanding pipeline, and watched for changes via FSEvents.

Workspaces are the fundamental unit of Decode's knowledge. No intelligence capability works without an active workspace.

### Content Intake Before the Launcher

Before the Launcher, users could add content to Decode through:

| Method | Trigger | Scope |
|--------|---------|-------|
| Hotkey `Control+Shift+O` | Keyboard chord | Opens `NSOpenPanel` for files (multi-select) |
| Hotkey `Control+Shift+P` | Keyboard chord | Opens `NSOpenPanel` for folders (single) |
| Session UI "Open File" button | Click in session sheet | Opens `NSOpenPanel` for files |
| Session UI "Open Folder" button | Click in session sheet | Opens `NSOpenPanel` for folders |

All four paths converge on the same `WorkspaceManager` operations. The Launcher provides a fifth path — a persistent, always-visible surface that the user can see and interact with without memorizing keyboard shortcuts or opening the session sheet.

---

## 3. Problem Definition

### The User Problem

The user is coding in their editor. They want Decode to understand a new file or project folder. Today, this requires either:
1. **Remembering a hotkey** (`Control+Shift+O` or `Control+Shift+P`) — requires memorization
2. **Opening the session sheet** and clicking a button — requires switching context to Decode's main window, opening the sheet, finding the button

Both paths impose cognitive overhead. The user must already know Decode's interaction model to discover them.

### What the Launcher Solves

The Launcher provides a **persistent visual affordance** — a small, unobtrusive indicator on the screen edge that says "Decode is here, and you can add content." On hover, it expands to reveal two clear actions: Add File and Add Folder.

This solves:
1. **Discoverability** — the Launcher is visible without prior knowledge
2. **Speed** — hover + click is faster than recalling a keyboard shortcut
3. **Context preservation** — the Launcher is non-activating, so the user's editor remains focused
4. **Simplicity** — two buttons, two actions, no configuration

### What the Launcher Does NOT Solve

- **Browsing/navigating** already-added workspace content (that's `ProjectExplorerView`)
- **Switching** between workspaces (that's `FloatingSessionDock`)
- **Asking questions** about code (that's double-tap hotkeys)
- **Viewing explanations** (that's `FloatingExplanationHUD`)
- **Understanding code** (that's the intelligence pipeline)

---

## 4. Launcher Responsibilities

### Core Responsibilities

1. **Always visible**: Present a persistent, unobtrusive indicator on the left screen edge whenever Decode is running and the user is authenticated.
2. **Expand on hover**: Reveal action buttons when the user moves their cursor to the left screen edge.
3. **Add File action**: Trigger the file-selection flow (`NSOpenPanel` for files, multi-select).
4. **Add Folder action**: Trigger the folder-selection flow (`NSOpenPanel` for directories, single-select).
5. **Activate Decode**: Tapping the main circle brings Decode's main window to the front.
6. **Collapse after action**: Return to the sliver state after an action is triggered or the cursor leaves.

### Delegation Responsibilities

The Launcher delegates everything beyond UI interaction:
- **Workspace creation** → `AppDependencies` → `SessionViewModel` → `WorkspaceManager`
- **File validation** → `WorkspaceManager` (size check, binary detection, dedup)
- **Indexing** → `IndexingCoordinator` (via `WorkspaceManager`)
- **File watching** → `FileWatcherService` / `DirectoryWatcherService` (via `WorkspaceManager`)
- **Session state persistence** → `SessionStatePersistence` (via `WorkspaceManager`)
- **Intelligence generation** → Understanding pipeline (via `WorkspaceManager` callbacks)

### Non-Responsibilities

The Launcher does NOT:
- Own or mutate workspace state
- Parse files or directories
- Build intelligence (FileIntelligence, semantic enrichment)
- Call AI providers
- Access the DIR, retrieval, context assembly, or consumers
- Track indexing progress
- Display errors from workspace operations (currently)
- Provide workspace management (rename, delete, reorder)
- Provide search or filtering
- Persist any state of its own

---

## 5. Non-Goals

These are architecturally meaningful exclusions — things the Launcher must never become:

1. **Not a second WorkspaceManager**: The Launcher does not create, mutate, or track workspaces directly. It fires callbacks; the workspace lifecycle is owned entirely by `WorkspaceManager`.

2. **Not an intelligence consumer**: The Launcher has no dependency on `DIRCore`, `ProducerRuntime`, `IndexRuntime`, `RetrievalRuntime`, `ContextAssembly`, `ConsumerRuntime`, `UnderstandingSystem`, or any reasoning engine.

3. **Not an indexing monitor**: The Launcher does not display indexing progress. That responsibility belongs to the Session Dock (which shows indexing state per workspace) and the Session View (which shows detailed file trees).

4. **Not a workspace browser**: The Launcher does not list existing workspaces. That is `FloatingSessionDock` (capsule pills on the right edge) and `SessionView` (session list sidebar).

5. **Not a file browser**: The Launcher does not display directory contents, file trees, or search results. That is `ProjectExplorerView`.

6. **Not an error recovery surface**: The Launcher is too small and transient to handle complex error states. Errors from workspace operations should be surfaced through `DecodeToastManager` or the session sheet.

7. **Not a configuration surface**: The Launcher has no settings, preferences, or customization. Its behavior is fixed.

---

## 6. Current System Context

### Decode's Floating Surface Architecture

Decode operates four independent floating `NSPanel` instances, each serving a distinct purpose:

| Surface | Position | Purpose | Panel Class | Behavior |
|---------|----------|---------|-------------|----------|
| **Launcher** | Left edge | Content intake | `LauncherPanel` | Always visible, hover-expand |
| **Session Dock** | Right edge | Workspace switching | `DockPanel` | Visible when workspaces exist, hover-expand |
| **Explanation HUD** | Screen center | Explanation display | `KeyablePanel` | Shown during explanations, movable |
| **Toast** | Top-right | Notifications | `NSPanel` | Transient, auto-dismiss |

All four share these architectural properties:
- `NSPanel` subclass (not `NSWindow`) — non-activating behavior
- `.floating` window level — above normal windows
- `hidesOnDeactivate = false` — visible when Decode is not the active app
- `backgroundColor = .clear`, `isOpaque = false` — transparent chrome
- `NSHostingView` wrapping SwiftUI content
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]` (Launcher and Dock)

### The Workspace Lifecycle

```
User Action (Launcher / Hotkey / Session UI)
    │
    ▼
NSOpenPanel (file or directory selection)
    │
    ▼
SessionViewModel.loadFile(url:) / loadDirectory(url:)
    │
    ▼
WorkspaceManager.createFileWorkspace(url:) / createDirectoryWorkspace(url:)
    │
    ├── Dedup check (in-memory → database)
    ├── Validation (size, binary detection)
    ├── Bookmark creation (for future sandbox support)
    ├── Database persistence (GRDB)
    ├── Parse / Index
    │   ├── .file: immediate parse (SwiftSyntax or TreeSitter)
    │   └── .directory: IndexingCoordinator batch scan + pipeline
    ├── Start watching (FileWatcher for .file, DirectoryWatcher for .directory)
    ├── Activate workspace (set activeWorkspaceId)
    ├── Save session state (session-state.json)
    └── Trigger KGR (proactive knowledge generation)
    │
    ▼
Workspace Ready for Intelligence Queries
```

### How the Launcher Connects

```
FloatingLauncher
    │
    ├── onAddFile callback ──→ AppDependencies.handleOpenSession()
    │                              │
    │                              ├── NSApp.activate(ignoringOtherApps: true)
    │                              ├── NSOpenPanel (multi-select, files only)
    │                              ├── Task { vm.loadFile(url:) for each URL }
    │                              └── vm.shouldPresentSession = true
    │
    ├── onAddFolder callback ──→ AppDependencies.handleOpenWorkspace()
    │                              │
    │                              ├── NSApp.activate(ignoringOtherApps: true)
    │                              ├── NSOpenPanel (single-select, directories only)
    │                              ├── Task { vm.loadDirectory(url:) }
    │                              └── vm.shouldPresentSession = true
    │
    └── onLauncherTapped ──→ NSApp.activate + mainWindow.makeKeyAndOrderFront
```

The Launcher is three closures. Everything below the closure boundary belongs to the existing workspace architecture.

---

## 7. Architectural Position

### Layer Placement

```
Presentation Layer
    ├── FloatingLauncher          ◄── This component
    ├── FloatingExplanationHUD
    ├── FloatingSessionDock
    ├── DecodeToastManager
    ├── SessionView
    └── ContentView

        │ callbacks (closures)
        ▼

Application Layer (via AppDependencies)
    ├── SessionViewModel
    ├── WorkspaceManager
    ├── IndexingCoordinator
    ├── SelectionModeCoordinator
    ├── SessionQuestionCoordinator
    └── ...

        │ protocols / closures
        ▼

Domain Layer
    ├── Workspace
    ├── WorkspaceKind
    ├── FileIntelligence
    └── ...

        │ implementations
        ▼

Infrastructure Layer
    ├── DatabaseService (GRDB)
    ├── FileWatcherService
    ├── DirectoryWatcherService
    ├── SwiftSyntaxParser / TreeSitterParser
    └── ...
```

The Launcher lives in the **Presentation layer**. It communicates exclusively through closures set by `AppDependencies` (the Application layer DI root). It has no direct imports of Application, Domain, or Infrastructure types.

### Dependency Direction

```
FloatingLauncher ──closures──→ AppDependencies ──method calls──→ SessionViewModel ──method calls──→ WorkspaceManager
```

The dependency direction is strictly downward (Presentation → Application → Domain → Infrastructure). The Launcher does not violate Decode's layered architecture.

---

## 8. Component Architecture

### 8.1 LauncherState

| Property | |
|----------|---|
| **Name** | `LauncherState` |
| **File** | `Decode/Presentation/Overlay/FloatingLauncher.swift:12` |
| **Type** | `@Observable @MainActor final class` |
| **Responsibility** | Holds the two animation progress values that drive the Launcher's visual morph |
| **State** | `mainProgress: CGFloat` (0→1, circle morph), `buttonsProgress: CGFloat` (0→1, button emergence) |
| **Computed** | `isExpanded: Bool` (true when `mainProgress > 0.01`) |
| **Inputs** | Set by `FloatingLauncher.expand()` and `collapse()` via `withAnimation` |
| **Outputs** | Read by `LauncherContentView` to derive all visual properties |
| **Dependencies** | None |
| **Ownership** | Owned by `FloatingLauncher` (single instance) |
| **Concurrency** | `@MainActor` — all mutations on the main thread |
| **Failure behavior** | Cannot fail — pure animation state |

### 8.2 FloatingLauncher

| Property | |
|----------|---|
| **Name** | `FloatingLauncher` |
| **File** | `Decode/Presentation/Overlay/FloatingLauncher.swift:31` |
| **Type** | `@MainActor final class` |
| **Responsibility** | Manages the `NSPanel` lifecycle, hover detection, expand/collapse animation, and callback routing |
| **State** | `panel: LauncherPanel?`, `isVisible: Bool`, `state: LauncherState`, `collapseWorkItem: DispatchWorkItem?`, `anchorCenterY: CGFloat`, `isAnimating: Bool` |
| **Inputs** | Mouse hover events (via `LauncherTrackingView`), button taps (via `LauncherContentView`) |
| **Outputs** | `onAddFile` closure, `onAddFolder` closure, `onLauncherTapped` closure |
| **Dependencies** | `LauncherPanel`, `LauncherTrackingView`, `LauncherContentView`, `LauncherState` |
| **Ownership** | Owned by `AppDependencies.floatingLauncher` |
| **Concurrency** | `@MainActor` — panel operations, animations, and DispatchWorkItem scheduling all on main thread |
| **Failure behavior** | Guard clauses prevent double-expand, double-collapse, and animation re-entrance |

### 8.3 LauncherPanel

| Property | |
|----------|---|
| **Name** | `LauncherPanel` |
| **File** | `Decode/Presentation/Overlay/FloatingLauncher.swift:265` |
| **Type** | `private final class LauncherPanel: NSPanel` |
| **Responsibility** | NSPanel subclass that can become key but not main |
| **Overrides** | `canBecomeKey → true`, `canBecomeMain → false` |
| **Why needed** | `.nonactivatingPanel` style mask normally returns `canBecomeKey = false`, which prevents button clicks from registering. This subclass restores key capability without making the panel activating. |

### 8.4 LauncherTrackingView

| Property | |
|----------|---|
| **Name** | `LauncherTrackingView` |
| **File** | `Decode/Presentation/Overlay/FloatingLauncher.swift:272` |
| **Type** | `private final class LauncherTrackingView: NSView` |
| **Responsibility** | Provides mouse enter/exit tracking for hover detection |
| **Why AppKit, not SwiftUI** | SwiftUI's `onHover` does not fire when the app is not active. Since the Launcher is non-activating and the user is typically in another app, hover detection must use AppKit's `NSTrackingArea` with `.activeAlways` option. |
| **Callbacks** | `onMouseEntered` → cancel collapse + expand, `onMouseExited` → schedule collapse |

### 8.5 LauncherContentView

| Property | |
|----------|---|
| **Name** | `LauncherContentView` |
| **File** | `Decode/Presentation/Overlay/FloatingLauncher.swift:301` |
| **Type** | `private struct LauncherContentView: View` (SwiftUI) |
| **Responsibility** | Renders the visual content — main circle, Add Folder button, Add File button |
| **Design principle** | **Single persistent ZStack** — all elements are always in the hierarchy. No view swapping. All visual properties (size, position, opacity, scale) are computed from `LauncherState.mainProgress` and `buttonsProgress`. This produces fluid, interruptible animations. |
| **Derived properties** | Main circle: 42→52px diameter, 0.22→1.0 opacity, position slides from right edge to left. Buttons: 0→1 scale, emerge from main circle center outward. |
| **Callbacks** | `onMainTap`, `onAddFile`, `onAddFolder` — pure closures, no business logic |

### 8.6 Dependency Graph

```
AppDependencies
    │
    │ owns (stored property)
    ▼
FloatingLauncher
    │
    │ owns
    ├──→ LauncherState          (animation progress)
    │
    │ creates (lazily, on show())
    ├──→ LauncherPanel          (NSPanel subclass)
    │       │
    │       │ contentView
    │       ▼
    │    LauncherTrackingView   (NSView, hover detection)
    │       │
    │       │ subview
    │       ▼
    │    NSHostingView<LauncherContentView>
    │       │
    │       │ wraps
    │       ▼
    │    LauncherContentView    (SwiftUI, visual rendering)
    │
    │ closures (set by AppDependencies)
    ├──→ onAddFile       → AppDependencies.handleOpenSession()
    ├──→ onAddFolder     → AppDependencies.handleOpenWorkspace()
    └──→ onLauncherTapped → NSApp.activate + mainWindow.makeKeyAndOrderFront
```

---

## 9. State Architecture

### 9.1 Launcher-Owned State

The Launcher maintains only **UI/animation state**:

| State | Type | Purpose | Transient? |
|-------|------|---------|------------|
| `mainProgress` | `CGFloat` | Main circle morph progress (0→1) | Yes |
| `buttonsProgress` | `CGFloat` | Button emergence progress (0→1) | Yes |
| `isVisible` | `Bool` | Whether the panel is ordered front | Yes |
| `isAnimating` | `Bool` | Re-entrance guard for expand/collapse | Yes |
| `anchorCenterY` | `CGFloat` | Vertical center position on screen | Yes |
| `collapseWorkItem` | `DispatchWorkItem?` | Pending collapse timer | Yes |
| `panel` | `LauncherPanel?` | The NSPanel instance (lazily created) | Yes |

**All Launcher state is transient.** Nothing is persisted. On app restart, the Launcher is recreated from scratch in `performDeferredStartup()`.

### 9.2 Why No Launcher Persistence

The Launcher has no user-customizable properties:
- Position is derived from `NSScreen.main` (always left edge, vertically centered)
- Size is fixed (132x164)
- Visibility is unconditional (always shown after auth)
- There are no user preferences (no "remember collapsed state", no "preferred screen")

Therefore, persisting Launcher state would add complexity with no user benefit.

**OPEN DECISION**: If the Launcher gains drag-to-reposition or screen-preference features in the future, a persistence decision will be needed. The `FloatingSessionDock` model (Y position in `UserDefaults`) provides a proven pattern for this.

### 9.3 Relationship to Other State Owners

```
Launcher State (transient, UI-only)
    │
    │ does NOT own
    ▼
Workspace State ──→ WorkspaceManager (canonical, in-memory)
    │
    │ persisted as
    ├──→ Workspace records (GRDB database, permanent history)
    └──→ SessionState (JSON file, transient session — which workspaces are open)
```

The Launcher never reads or writes workspace state. It fires closures that eventually cause `WorkspaceManager` to mutate workspace state and persist it.

### 9.4 Decode's State Architecture (Context for External Reader)

Decode maintains a strict separation between two forms of persistence:

1. **Persistent knowledge** (`Workspace` records in GRDB): Every workspace ever created. Closing a workspace does NOT delete its record. Records serve as permanent history/bookmarks.

2. **Transient application state** (`SessionState` in `session-state.json`): Which workspaces are currently open, which is active, which is pinned. Saved incrementally on every mutation. Restored on launch.

The Launcher participates in neither persistence mechanism directly. Its actions cause downstream writes to both (a new workspace is both persisted to GRDB and added to the session state), but the Launcher is unaware of this.

---

## 10. Launcher Lifecycle

### 10.1 State Machine

```
                    ┌──────────────────────────────────────────┐
                    │                                          │
                    ▼                                          │
    ┌─────────┐  show()  ┌──────────┐  mouseEnter  ┌────────────┐
    │ Created │ ───────→ │ Collapsed │ ──────────→ │  Expanding  │
    └─────────┘          └──────────┘              └────────────┘
                              ▲                          │
                              │                     animation done
                              │                          │
                              │                          ▼
                         mouseExit              ┌────────────┐
                        (after delay)           │  Expanded   │
                              │                 └────────────┘
                              │                      │
                         ┌────────────┐          mouseExit
                         │ Collapsing │ ◄────── (450ms delay)
                         └────────────┘              │
                              │                      │
                         animation done         button tap
                              │                      │
                              ▼                      ▼
                         ┌──────────┐         ┌────────────┐
                         │ Collapsed │         │  Action     │
                         └──────────┘         │  Triggered  │
                                              └────────────┘
                                                    │
                                              collapse (150ms delay)
                                                    │
                                                    ▼
                                              ┌────────────┐
                                              │ Collapsing  │
                                              └────────────┘
```

### 10.2 State Definitions

#### Created
- **Entry**: `FloatingLauncher()` constructor called in `AppDependencies.performDeferredStartup()`
- **Exit**: `show()` called
- **UI**: No panel exists yet
- **Actions**: Only `show()` is meaningful

#### Collapsed
- **Entry**: `show()` called, or collapse animation completes
- **Exit**: Mouse enters tracking area
- **UI**: Panel positioned off-screen left, only 22px sliver visible. Main circle at 42px, opacity 0.22.
- **Actions**: Hover → Expanding

#### Expanding
- **Entry**: `expand()` called (triggered by `mouseEntered`)
- **Exit**: Both animation phases complete
- **Guards**: `!state.isExpanded && isVisible && !isAnimating`
- **UI**: Panel slides right (350ms ease-out). Circle morphs larger (spring 380ms). Buttons emerge at +180ms (spring 500ms, bouncier).
- **Async work**: Two-phase spring animation via `withAnimation` + `DispatchQueue.main.asyncAfter`
- **Cancellation**: Cannot be interrupted mid-animation (`isAnimating` guard)

#### Expanded
- **Entry**: Expansion animation completes (`isAnimating` set to `false`)
- **Exit**: Mouse exits tracking area, or a button is tapped
- **UI**: Panel fully visible. Circle at 52px, opacity 1.0, orange glow. Both action buttons visible at full scale.
- **Actions**: Add File, Add Folder, Main Circle tap, or mouse exit

#### Action Triggered
- **Entry**: User clicks Add File or Add Folder button
- **Exit**: Collapse triggered after 150ms delay
- **Immediate effect**: Callback fires (`onAddFile` or `onAddFolder`), which calls `handleOpenSession()` or `handleOpenWorkspace()` in `AppDependencies`. These methods call `NSApp.activate()` and show `NSOpenPanel`.
- **UI**: Collapse begins 150ms after button tap (aesthetic delay so the click feels acknowledged)

#### Collapsing
- **Entry**: `collapse()` called (triggered by `scheduleCollapse()` after 450ms, or action-triggered after 150ms)
- **Exit**: Collapse animation completes
- **Guards**: `state.isExpanded && isVisible && !isAnimating`
- **UI**: Buttons retract (spring 280ms). Circle shrinks at +100ms (spring 320ms). Panel slides left (300ms ease-in).
- **Cancellation**: Cannot be interrupted mid-animation. However, if `mouseEntered` fires during the 450ms **delay** (before `collapse()` is called), the `DispatchWorkItem` is cancelled and `expand()` is called instead.

#### Hidden
- **Entry**: `hide()` called
- **Exit**: `show()` called
- **UI**: Panel ordered out. All progress values reset to 0.
- **Currently unused**: `hide()` exists but is never called in production code. The Launcher is shown once and never hidden.

### 10.3 Re-Entrance Protection

The `isAnimating` flag prevents concurrent expand/collapse operations:
- `expand()` guards: `!state.isExpanded && isVisible && !isAnimating`
- `collapse()` guards: `state.isExpanded && isVisible && !isAnimating`

This means:
- If the user moves the mouse in and out rapidly during an animation, the action is dropped.
- The 450ms collapse delay (via `DispatchWorkItem`) provides a grace period — if the user re-enters during the delay, the collapse is cancelled and the Launcher stays expanded.

**CURRENT IMPLEMENTATION**: The `isAnimating` flag is set to `false` inside a `DispatchQueue.main.asyncAfter` callback (in `expand()`) and in the `NSAnimationContext.completionHandler` (in `collapse()`). This is correct for preventing re-entrance, but means the Launcher is briefly "locked" during animation.

---

## 11. File Addition Flow

### Current Implementation (CURRENT IMPLEMENTATION)

```
User hovers over Launcher (left screen edge)
    │
    ▼
Launcher expands (hover animation)
    │
    ▼
User clicks "File" button (doc.badge.plus icon)
    │
    ▼
onAddFile closure fires
    │
    ▼
AppDependencies.handleOpenSession()
    │
    ├── Guard: workspaceManager != nil
    │
    ├── NSApp.activate(ignoringOtherApps: true)
    │   └── Decode comes to front (necessary for NSOpenPanel visibility)
    │
    ├── NSOpenPanel configured:
    │   ├── title: "Select code files"
    │   ├── allowsMultipleSelection: true
    │   ├── canChooseDirectories: false
    │   ├── NO allowedContentTypes filter  ◄── NOTED: differs from SessionView
    │   └── runModal() — blocks main thread until user selects or cancels
    │
    ├── User selects file(s) or cancels
    │   └── Cancel → return (no-op)
    │
    ├── Task { for url in urls: await vm.loadFile(url: url) }
    │   │
    │   │   For each URL:
    │   ▼
    │   SessionViewModel.loadFile(url:)
    │       │
    │       ├── isLoading = true
    │       ├── errorMessage = nil
    │       │
    │       ├── try await workspaceManager.createFileWorkspace(url:)
    │       │   │
    │       │   ├── Guard: fileSize ≤ 512 KB
    │       │   │   └── Throws WorkspaceError.fileTooLarge
    │       │   │
    │       │   ├── Guard: !isBinaryFile
    │       │   │   └── Throws WorkspaceError.binaryFile
    │       │   │
    │       │   ├── Dedup: in-memory check (rootPath match)
    │       │   │   └── Found → reparse + activate → return
    │       │   │
    │       │   ├── Dedup: database check (fetchAllWorkspaces)
    │       │   │   └── Found → parse + build intelligence + create ManagedWorkspace
    │       │   │              + startWatching + activate + trigger KGR → return
    │       │   │
    │       │   ├── New workspace:
    │       │   │   ├── Read source text
    │       │   │   ├── Parse (SwiftSyntax or TreeSitter)
    │       │   │   ├── Create Workspace struct (UUID, timestamps, bookmark, path)
    │       │   │   ├── Persist to database
    │       │   │   ├── Build FileIntelligence (Identity, Purpose layers)
    │       │   │   ├── Create ManagedWorkspace
    │       │   │   ├── Add to workspaces dictionary
    │       │   │   ├── Start file watching
    │       │   │   ├── Activate workspace
    │       │   │   ├── Save session state
    │       │   │   └── Trigger KGR
    │       │   │
    │       │   └── return
    │       │
    │       ├── isLoading = false
    │       └── catch: errorMessage = "Failed to open: \(error)"
    │
    └── If active workspace exists:
        └── vm.shouldPresentSession = true
            └── Triggers session sheet presentation via ContentView onChange
```

### Multiple File Selection

When the user selects multiple files in `NSOpenPanel`, each URL is processed sequentially in a `for` loop:

```swift
for url in urls {
    await vm.loadFile(url: url)
}
```

This means:
- Each file is fully processed (parsed, persisted, watched, activated) before the next begins
- The last file in the selection becomes the active workspace
- All files share the same `Task`, so cancellation would cancel all remaining files
- Errors on one file do not prevent processing of subsequent files (each `loadFile` has its own try/catch)

### Duplicate File Behavior

**CURRENT IMPLEMENTATION**: If the selected file's path matches an existing workspace:
1. **In-memory match** → reparse the file (may have changed) and activate the workspace. No new workspace created.
2. **Database match** (workspace existed before but was closed) → reload from DB, parse, rebuild intelligence, start watching, activate. The workspace is "reopened" from history.

This is idempotent — selecting the same file repeatedly has no harmful effect.

---

## 12. Folder Addition Flow

### Current Implementation (CURRENT IMPLEMENTATION)

```
User hovers over Launcher
    │
    ▼
Launcher expands
    │
    ▼
User clicks "Folder" button (folder.badge.plus icon)
    │
    ▼
onAddFolder closure fires
    │
    ▼
AppDependencies.handleOpenWorkspace()
    │
    ├── Guard: sessionViewModel != nil
    │
    ├── NSApp.activate(ignoringOtherApps: true)
    │
    ├── NSOpenPanel configured:
    │   ├── title: "Select a project folder"
    │   ├── allowsMultipleSelection: false  ◄── Single folder only
    │   ├── canChooseDirectories: true
    │   ├── canChooseFiles: false
    │   └── runModal()
    │
    ├── User selects folder or cancels
    │   └── Cancel → return
    │
    ├── Task { await vm.loadDirectory(url: url) }
    │   │
    │   ▼
    │   SessionViewModel.loadDirectory(url:)
    │       │
    │       ├── isLoading = true, errorMessage = nil
    │       │
    │       ├── try await workspaceManager.createDirectoryWorkspace(url:)
    │       │   │
    │       │   ├── Dedup: in-memory check (rootPath match)
    │       │   │   └── Found → activate → return (NO re-indexing)
    │       │   │
    │       │   ├── Dedup: database check
    │       │   │   └── Found → create ManagedWorkspace (empty entities)
    │       │   │              → activate → startIndexing → return
    │       │   │
    │       │   ├── New workspace:
    │       │   │   ├── Create Workspace struct (UUID, .directory, timestamps, bookmark, path)
    │       │   │   ├── Persist to database
    │       │   │   ├── Create ManagedWorkspace (empty parsedEntities)
    │       │   │   ├── Add to workspaces dictionary
    │       │   │   ├── Activate workspace
    │       │   │   ├── Save session state
    │       │   │   └── startIndexing(managed:)
    │       │   │       │
    │       │   │       ├── Create IndexingCoordinator
    │       │   │       ├── Set onComplete callback → buildPerFileIntelligence + KGR
    │       │   │       ├── coordinator.start(rootPath:, processChanges:)
    │       │   │       │   ├── scanManifest: FileManager.enumerator
    │       │   │       │   │   ├── Skip .skipsHiddenFiles
    │       │   │       │   │   ├── Prune: .git, node_modules, build, etc.
    │       │   │       │   │   └── Filter: .swift, .py, .js, .ts, etc. (22 extensions)
    │       │   │       │   ├── Batch into groups of 20
    │       │   │       │   ├── For each batch:
    │       │   │       │   │   ├── Convert to FileChangeEvent(.modified)
    │       │   │       │   │   ├── await processChanges(events) → pipeline
    │       │   │       │   │   ├── Update state: .indexing(processed:, total:)
    │       │   │       │   │   └── Task.yield()
    │       │   │       │   └── Set state: .complete(fileCount:)
    │       │   │       │
    │       │   │       └── startDirectoryWatching(managed:)
    │       │   │           ├── Open root directory FD
    │       │   │           ├── DispatchSource.makeFileSystemObjectSource(.write)
    │       │   │           ├── 500ms debounce
    │       │   │           └── Mod-date snapshot comparison → AsyncStream
    │       │   │
    │       │   └── return
    │       │
    │       ├── isLoading = false
    │       └── catch: errorMessage = "Failed to open folder: \(error)"
    │
    └── vm.shouldPresentSession = true
```

### Duplicate Folder Behavior

**CURRENT IMPLEMENTATION**: If the directory path matches an existing workspace:
1. **In-memory match** → activate the workspace. **No re-indexing occurs.** The existing indexed state is preserved.
2. **Database match** → create a fresh `ManagedWorkspace` with empty entities, activate, and start indexing from scratch. This means a previously closed directory workspace loses its in-memory indexed state and must re-index.

**ARCHITECTURAL NOTE**: The asymmetry between file and directory dedup is intentional — file workspaces are cheap to reparse (single file), but directory workspaces may contain thousands of files, so re-indexing is expensive and only done when necessary (i.e., when the workspace was closed and its in-memory state was lost).

---

## 13. Drag & Drop Flow

### Current State (CURRENT IMPLEMENTATION)

**There is no drag-and-drop implementation anywhere in the Decode codebase.** Extensive search confirms:
- No `onDrop` modifiers in any SwiftUI view
- No `.dropDestination` usage
- No `NSDraggingDestination` protocol conformance
- No `registerForDraggedTypes` calls
- No `NSPasteboardItem` reading from drag sessions
- No `fileImporter` (SwiftUI) usage

All file/folder intake is exclusively through `NSOpenPanel.runModal()`.

### Proposed Design (PROPOSED DESIGN)

If drag-and-drop were to be added to the Launcher, the following architecture is proposed:

#### What Can Be Dropped

| Input | Handling |
|-------|----------|
| Single file | Validate → `createFileWorkspace(url:)` |
| Multiple files | Validate each → `createFileWorkspace(url:)` for each |
| Single directory | Validate → `createDirectoryWorkspace(url:)` |
| Multiple directories | Validate each → `createDirectoryWorkspace(url:)` for each |
| Mixed files and directories | Separate → process each appropriately |
| URLs (non-file) | Reject with feedback |
| Non-file pasteboard items | Reject silently |

#### Drop Target Architecture

The drop target would be on the `LauncherTrackingView` (AppKit level, not SwiftUI), because:
1. The Launcher is non-activating — SwiftUI drop targets may not work when the app is not active
2. The `LauncherTrackingView` already handles mouse events via `NSTrackingArea`
3. AppKit's `NSDraggingDestination` provides fine-grained control over drag session feedback

#### Proposed Drop Flow

```
User drags file(s)/folder(s) from Finder
    │
    ▼
LauncherTrackingView receives draggingEntered(_:)
    │
    ├── Read NSPasteboard for file URLs
    ├── Validate: are they file URLs? Do paths exist?
    ├── If valid → return .copy (green + icon)
    ├── If invalid → return .none (no drop feedback)
    │
    ▼ (during drag)
Launcher expands (visual feedback that it's a valid target)
    │
    ▼
User drops
    │
    ▼
LauncherTrackingView receives performDragOperation(_:)
    │
    ├── Extract file URLs from NSPasteboard
    ├── Separate into files and directories
    ├── For each file URL → onAddFile-equivalent callback
    ├── For each directory URL → onAddFolder-equivalent callback
    └── Return true (accepted)
    │
    ▼
Same downstream flow as button-based addition
(AppDependencies → SessionViewModel → WorkspaceManager)
```

#### OPEN DECISIONS for Drag & Drop

1. **Should drag expand the Launcher?** The current hover-to-expand behavior uses `NSTrackingArea`. A drag session may or may not trigger `mouseEntered`. If not, the Launcher would need to detect `draggingEntered` and expand explicitly.

2. **Should drop bypass `NSOpenPanel`?** Currently, the Launcher's callbacks go through `handleOpenSession()` / `handleOpenWorkspace()`, which show `NSOpenPanel`. For drag-and-drop, the URLs are already known — the `NSOpenPanel` step should be skipped. This requires new callbacks on `FloatingLauncher` (e.g., `onDropFiles: (([URL]) -> Void)?` and `onDropFolders: (([URL]) -> Void)?`).

3. **Error feedback for invalid drops**: The Launcher collapses after action. For drag-and-drop, validation can reject before drop (via `draggingEntered` return value), but post-drop errors (binary file, too large) need a feedback path. `DecodeToastManager` is the natural candidate.

4. **Should the session sheet auto-present after drop?** Currently, the session sheet presents after `NSOpenPanel` completes. For drop, the equivalent trigger should fire.

---

## 14. Workspace Integration

### Integration Point: Closures, Not Dependencies

The Launcher integrates with the workspace system exclusively through three closures set by `AppDependencies`:

```swift
// In AppDependencies.performDeferredStartup():
let launcher = FloatingLauncher()
launcher.onAddFile = { [weak self] in self?.handleOpenSession() }
launcher.onAddFolder = { [weak self] in self?.handleOpenWorkspace() }
launcher.onLauncherTapped = { /* activate app + bring window to front */ }
self.floatingLauncher = launcher
launcher.show()
```

This is the correct architectural pattern:
- The Launcher has **zero imports** of workspace types
- The Launcher does not know what a `Workspace`, `ManagedWorkspace`, or `WorkspaceManager` is
- The Launcher does not know about indexing, watching, or intelligence
- All workspace logic lives in `WorkspaceManager` and is accessed through `AppDependencies`

### Who Creates Workspaces?

Only `WorkspaceManager` creates workspaces. The call chain:

```
Launcher callback → AppDependencies method → SessionViewModel method → WorkspaceManager method
```

No shortcut exists. The Launcher never calls `WorkspaceManager` directly.

### Who Owns Canonical State?

| State | Owner | Why |
|-------|-------|-----|
| In-memory workspaces | `WorkspaceManager.workspaces` | Single source of truth for runtime workspace state |
| Active workspace ID | `WorkspaceManager.activeWorkspaceId` | Set only by `activateWorkspace(id:)` |
| Pinned workspace ID | `WorkspaceManager.pinnedWorkspaceId` | Set only by `pinWorkspace(id:)` |
| Workspace history | GRDB `workspaces` table | Persistent across app restarts |
| Open session state | `session-state.json` | Which workspaces are open, active, pinned |

The Launcher owns none of this.

### Architectural Risks of Tighter Coupling

If the Launcher were to directly reference:

| Component | Risk |
|-----------|------|
| `WorkspaceManager` | Launcher becomes a second controller; state mutation paths fork |
| `IndexingCoordinator` | Launcher becomes responsible for indexing lifecycle; dual ownership |
| `DIR` / `IndexRuntime` | Violates layer boundary; Launcher would import understanding pipeline modules |
| `AIProviderProtocol` | Launcher would need auth awareness; inappropriate for a UI surface |
| `DatabaseService` | Launcher would become a persistence actor; bypasses WorkspaceManager |

**The current closure-based design correctly prevents all of these risks.**

---

## 15. Indexing Integration

### What the Launcher Knows About Indexing

**Nothing.** The Launcher fires a callback and collapses. It has no knowledge of whether indexing starts, progresses, succeeds, or fails.

### What Happens After the Launcher's Action

For a directory workspace:

```
Launcher fires onAddFolder
    │
    ▼
AppDependencies.handleOpenWorkspace()
    │
    ▼
SessionViewModel.loadDirectory(url:)
    ├── isLoading = true
    │
    ▼
WorkspaceManager.createDirectoryWorkspace(url:)
    ├── Database persist
    ├── Activate
    ├── Save session state
    └── startIndexing(managed:)
        │
        ├── IndexingCoordinator created
        │   ├── State: .idle → .scanning → .indexing(processed:, total:) → .complete(fileCount:)
        │   └── Batches of 20 files → pipeline
        │
        └── DirectoryWatcherService starts
            └── FSEvents on root directory FD
    │
    ▼
SessionViewModel.isLoading = false  (returns immediately after workspace created)
    │
    ▼
Indexing continues in background Task
    │
    ▼
On completion:
    ├── buildPerFileIntelligenceAndTriggerKGR
    │   ├── Parse each file → FileIntelligence
    │   ├── Populate parsedEntitiesByFile, fileIntelligenceByFile
    │   └── Trigger KGR planner
    └── coordinator.state = .complete(fileCount:)
```

### Indexing Progress Visibility

Indexing progress is visible through:
1. **FloatingSessionDock**: Shows capsule pills per workspace. Directory workspaces show folder icon and indexing state. The dock observes `IndexingCoordinator.state` via SwiftUI's `@Observable` machinery.
2. **SessionView**: Shows detailed file tree and indexing state in the session sheet.

The Launcher is **not** a surface for indexing progress. This is by design — the Launcher's purpose is intake, not monitoring.

### Supported File Types for Indexing

`IndexingCoordinator.supportedExtensions` (static, 22 extensions):
```
swift, py, js, ts, jsx, tsx, java, c, cpp, h, hpp, cs,
html, css, mjs, cjs, htm, scss, cxx, cc, hxx
```

`IndexingCoordinator.excludedDirectories` (static, 21 directories):
```
.git, .svn, .hg, node_modules, Pods, Carthage, build, Build,
DerivedData, .build, .swiftpm, .xcodeproj, .xcworkspace,
__pycache__, .pytest_cache, dist, .next, .nuxt, vendor,
.gradle, .idea, .vscode
```

These are relevant to the Launcher only in that they determine what gets indexed after a folder is added. The Launcher itself has no awareness of these filters.

---

## 16. Intelligence Integration

### End-to-End Flow: Launcher to Intelligence

```
Launcher (Presentation)
    │ closure
    ▼
AppDependencies (Application - DI root)
    │ method call
    ▼
SessionViewModel (Application - ViewModel)
    │ method call
    ▼
WorkspaceManager (Application - Workspace lifecycle)
    │
    ├── For .file:
    │   ├── Parse (SwiftSyntax / TreeSitter) → ParsedEntity[], Relationships
    │   ├── Build FileIntelligence (Identity, Purpose layers - deterministic)
    │   ├── Start FileWatcherService → onFileChanged → pipeline processChanges
    │   └── Trigger KGR → planner → runtime → background knowledge generation
    │
    └── For .directory:
        ├── IndexingCoordinator.start()
        │   └── Batch files → processChanges → UnderstandingSystem pipeline
        ├── Start DirectoryWatcherService → onFileChanged → pipeline
        └── On complete: build per-file FileIntelligence → trigger KGR
            │
            ▼
Understanding Pipeline (Infrastructure - @MainActor-free)
    ├── ProducerRuntime → passes → entities
    ├── IndexRuntime → five index families
    ├── StorageEngine → snapshots
    └── Ready for query
            │
            ▼
User asks question (double-tap Shift)
    │
    ▼
SessionQuestionCoordinator
    ├── WorkspaceResolver.resolve() → find workspace + file
    ├── SemanticEnrichmentService.enrich() → Purpose, Behavior, Safety, Design
    ├── PipelineQueryService.query() → RetrievalRuntime → ContextAssembly
    └── ConsumerRuntime → ExplainReasoningEngine → AI → HUD
```

### Boundary Between Launcher and Intelligence

The Launcher's responsibility ends at the closure call. There are **four layers of indirection** between the Launcher and the intelligence pipeline:

```
Launcher → AppDependencies → SessionViewModel → WorkspaceManager → [Pipeline]
```

This is intentional and must be preserved. The Launcher is a thin input surface. It should never:
- Import any understanding pipeline module
- Reference `UnderstandingSystem`, `PipelineQueryService`, or any reasoning engine
- Know about `FileIntelligence`, `SemanticEnrichment`, or `ParsedEntity`
- Access AI providers

### Evolution Compatibility

The Launcher's design supports Decode's evolution from File → Directory → Module → Project intelligence without Launcher changes:

| Evolution Stage | Launcher Impact |
|----------------|-----------------|
| File Intelligence (complete) | None — Launcher adds files, intelligence is built downstream |
| Directory/Workspace (complete) | None — Launcher adds directories, indexing is downstream |
| Module Intelligence (complete) | None — module analysis is a pipeline concern |
| Project Intelligence (in progress) | None — project-level understanding is a pipeline concern |
| Cross-project Intelligence (future) | May need new input type (e.g., "Add Git Repo"), but core architecture unchanged |

The Launcher can gain new input types (new buttons, new callbacks) without architectural rewrites, because it is decoupled from what happens after the input.

---

## 17. Concurrency Model

### Thread/Actor Isolation

| Component | Isolation | Reason |
|-----------|-----------|--------|
| `FloatingLauncher` | `@MainActor` | NSPanel operations, NSAnimationContext, UI |
| `LauncherState` | `@MainActor` | SwiftUI `@Observable` state driving animations |
| `LauncherPanel` | Main thread (AppKit) | NSWindow subclass — all window operations are main thread |
| `LauncherTrackingView` | Main thread (AppKit) | NSView — mouse events delivered on main thread |
| `LauncherContentView` | Main thread (SwiftUI) | SwiftUI View — body evaluated on main thread |

The Launcher is **entirely `@MainActor`**. It performs no background work.

### Downstream Concurrency

When the Launcher fires a callback:

```
@MainActor: FloatingLauncher.onAddFile()
    │
    ▼
@MainActor: AppDependencies.handleOpenSession()
    │
    ├── NSOpenPanel.runModal()  ← blocks main thread (modal)
    │
    ├── Task { ... }  ← spawns on @MainActor (inherited)
    │   │
    │   ▼
    │   @MainActor: SessionViewModel.loadFile(url:)
    │       │
    │       ▼
    │       @MainActor: WorkspaceManager.createFileWorkspace(url:)
    │           │
    │           ├── Synchronous: parse, build intelligence, add to dict
    │           ├── await: database operations (GRDB, may briefly yield)
    │           └── Synchronous: startWatching (launches Task for AsyncStream)
    │
    └── @MainActor: vm.shouldPresentSession = true
```

**Key observation**: `NSOpenPanel.runModal()` blocks the main thread. During this time:
- The Launcher cannot expand or collapse (no mouse events processed)
- No other `@MainActor` work runs
- The UI is effectively frozen while the panel is open

This is standard macOS behavior for modal panels and is not a Launcher-specific concern.

### Concurrent Add Operations

**Scenario**: User adds a folder via Launcher, then immediately adds a file via Launcher.

**Analysis**:
1. First action: `onAddFolder` fires → `handleOpenWorkspace()` → `NSOpenPanel.runModal()` blocks main thread.
2. While `NSOpenPanel` is modal, the Launcher cannot receive new interactions. The user must dismiss the panel before interacting with the Launcher again.
3. After panel dismisses, `Task { vm.loadDirectory(url:) }` starts. This returns quickly (workspace created, indexing starts in background).
4. If the user then clicks "Add File" before indexing completes:
   - `handleOpenSession()` → new `NSOpenPanel.runModal()`
   - After panel: `Task { vm.loadFile(url:) }` → `createFileWorkspace(url:)`
   - Both operations are sequential on `@MainActor` — no race condition.
   - Indexing continues in its own `Task` inside `IndexingCoordinator`.

**Conclusion**: Concurrent add operations are safe because:
- `NSOpenPanel.runModal()` serializes user interaction
- All workspace mutations are on `@MainActor` (serialized)
- Background indexing runs in its own `Task` and does not conflict with workspace creation

### Application Shutdown During Indexing

**Scenario**: User adds a large folder, indexing starts, user quits the app.

**CURRENT IMPLEMENTATION**:
1. `willTerminateNotification` fires in `DecodeApp`
2. `workspaceManager.saveSessionState()` saves the current session state (workspace is listed as open)
3. `Task.detached { await understandingSystem.shutdown() }` shuts down the pipeline
4. `IndexingCoordinator.cancel()` is NOT explicitly called — the `Task` is cancelled when the coordinator is deallocated
5. On next launch: `restoreWorkspaces()` loads the workspace from session state, creates a fresh `IndexingCoordinator`, and re-indexes from scratch

**Consequence**: Partial indexing state is lost on app quit. This is acceptable because:
- Indexing is idempotent (re-running produces the same result)
- The pipeline's `processChanges` is resilient to duplicate events
- The workspace record in the database is preserved (no data loss)

### Same Path Added Twice Concurrently

This cannot happen through the Launcher because `NSOpenPanel.runModal()` is modal. However, it could theoretically happen if:
- User adds via Launcher (NSOpenPanel), and a hotkey triggers simultaneously

**CURRENT IMPLEMENTATION**: `WorkspaceManager.createFileWorkspace()` performs an in-memory dedup check first. Since all mutations are on `@MainActor`, two concurrent calls for the same path would be serialized:
1. First call creates the workspace
2. Second call finds the in-memory match and repurposes + activates (no-op)

This is safe.

---

## 18. UI Architecture

### 18.1 Window/Panel Architecture

```
NSPanel (LauncherPanel)
    │
    ├── Style: [.nonactivatingPanel, .fullSizeContentView, .borderless]
    ├── Level: .floating (above normal windows, same level as HUD/Dock/Toast)
    ├── Behavior: [.canJoinAllSpaces, .fullScreenAuxiliary]
    │
    ├── Properties:
    │   ├── canBecomeKey: true (overridden — needed for button clicks)
    │   ├── canBecomeMain: false
    │   ├── becomesKeyOnlyIfNeeded: true
    │   ├── hidesOnDeactivate: false (visible when Decode is not active)
    │   ├── isMovableByWindowBackground: false (fixed position)
    │   ├── backgroundColor: .clear
    │   ├── isOpaque: false
    │   ├── hasShadow: false
    │   └── appearance: NSAppearance(named: .aqua)  ◄── forced light appearance
    │
    └── contentView:
        LauncherTrackingView (NSView)
            │
            └── subview:
                NSHostingView<LauncherContentView> (SwiftUI bridge)
                    │
                    └── LauncherContentView (SwiftUI)
                        ├── Main Circle (Button, .plain style)
                        ├── Add Folder (Button, upper right)
                        └── Add File (Button, lower right)
```

### 18.2 Positioning

**CURRENT IMPLEMENTATION**: The Launcher is anchored to the **left edge** of `NSScreen.main`:

- **Collapsed**: `x = screenLeft - (panelWidth - peekAmount)` = only 22px visible
  - Panel width: 132px
  - Panel height: 164px
  - Peek amount: 22px
- **Expanded**: `x = screenLeft` = full panel visible on screen
- **Vertical**: `y = screen.visibleFrame.midY - panelHeight/2` = vertically centered

The panel does **not** resize during expand/collapse. Only the x-position changes. This is a deliberate design choice — resizing causes visual glitches, while position-only animation is smooth.

### 18.3 "Always Visible" — What It Means

The Launcher is "always visible" in the following sense:

| Property | Value | Meaning |
|----------|-------|---------|
| `hidesOnDeactivate` | `false` | Stays visible when user switches to another app |
| `canJoinAllSpaces` | `true` | Visible on all macOS Spaces/Desktops |
| `fullScreenAuxiliary` | `true` | Visible in fullscreen mode |
| `level` | `.floating` | Above normal windows |
| `show()` called unconditionally | Yes | Shown after `performDeferredStartup()` regardless of workspace count |

**Distinction**:
- **Always mounted**: Yes — the `LauncherPanel` is created once and never destroyed
- **Always visible**: Yes — the panel is never hidden in production code (`hide()` exists but is never called)
- **Always fully visible**: No — when collapsed, only the 22px sliver is visible
- **Application-relative**: The panel belongs to the Decode process but `hidesOnDeactivate = false`
- **Screen-relative**: Anchored to `NSScreen.main`'s left edge (not window-relative)

### 18.4 Focus Behavior

The Launcher is **non-activating** (`.nonactivatingPanel` style mask):
- Hovering over the Launcher does NOT activate Decode
- Clicking action buttons does NOT steal focus from the user's editor
- The `NSOpenPanel` that appears after a button click **does** activate Decode (via `NSApp.activate(ignoringOtherApps: true)`)
- Tapping the main circle **does** activate Decode (via `NSApp.activate(ignoringOtherApps: true)`)

### 18.5 Keyboard Interaction

**CURRENT IMPLEMENTATION**: The Launcher has no keyboard interaction. It is purely mouse/trackpad driven:
- Hover to expand
- Click to trigger action
- No keyboard shortcuts to summon/dismiss the Launcher
- No focus ring or tab navigation

**PROPOSED DESIGN**: No keyboard interaction is needed. The hotkeys (`Control+Shift+O`, `Control+Shift+P`) already provide keyboard-driven file/folder addition. The Launcher is the mouse-driven complement.

### 18.6 Accessibility

**CURRENT IMPLEMENTATION**: The Launcher uses standard SwiftUI `Button` views, which automatically provide VoiceOver labels from the system icon names. The button labels ("Folder", "File") are rendered as text inside the buttons.

**OPEN DECISION**: Whether the Launcher needs explicit `accessibilityLabel` / `accessibilityHint` attributes for:
- The main circle button
- The collapsed sliver (how does VoiceOver discover a 22px sliver?)
- The overall Launcher purpose

### 18.7 Dark/Light Mode

**CURRENT IMPLEMENTATION**: The panel forces `NSAppearance(named: .aqua)` (light mode). This means the Launcher always appears in light mode regardless of the system setting.

This matches the pattern used by all other floating surfaces in Decode (HUD, Dock, Toast).

### 18.8 Multi-Display Behavior

**CURRENT IMPLEMENTATION**: The Launcher uses `NSScreen.main ?? NSScreen.screens.first` for positioning. It always appears on the **primary display** (the one with the menu bar, or the one most recently interacted with).

| Surface | Display Selection |
|---------|-------------------|
| Launcher | `NSScreen.main` — primary display |
| HUD | `NSEvent.mouseLocation` — follows cursor |
| Dock | `NSScreen.main` — primary display |
| Toast | `NSEvent.mouseLocation` — follows cursor |

**OPEN DECISION**: Should the Launcher follow the cursor (like the HUD) or stay on the primary display? If the user has a multi-monitor setup and is coding on a secondary display, the Launcher may not be visible. However, since the Launcher uses hover-to-expand, it needs to be on a screen edge — following the cursor would require tracking which screen the cursor is on and repositioning.

### 18.9 Fullscreen Behavior

**CURRENT IMPLEMENTATION**: `.fullScreenAuxiliary` allows the Launcher to appear over fullscreen apps. This is correct — the user may be coding in a fullscreen editor and should still have access to the Launcher.

---

## 19. Persistence Model

### Current State (CURRENT IMPLEMENTATION)

The Launcher persists **nothing**. Its state is entirely transient:

| What | Persisted? | Where | By Whom |
|------|-----------|-------|---------|
| Launcher position | No | Computed from `NSScreen.main` | `FloatingLauncher` |
| Launcher visibility | No | Always visible after startup | `FloatingLauncher` |
| Expand/collapse state | No | Transient animation state | `LauncherState` |
| Workspace created via Launcher | Yes | GRDB + session-state.json | `WorkspaceManager` |

### Comparison with Session Dock

The `FloatingSessionDock` persists its Y position in `UserDefaults`:
```swift
UserDefaults.standard.set(anchor, forKey: "sessionDockPosition")
```

The Launcher does not persist position because it is not draggable. If drag-to-reposition were added, the same `UserDefaults` pattern would apply.

### What Should NOT Be Persisted

- **Expand/collapse state**: The Launcher always starts collapsed. Persisting "expanded" would mean the Launcher covers screen edge on launch before the user even hovers.
- **"Last used action"**: There is no benefit to remembering whether the user last added a file or folder.
- **Action history**: What files/folders were added is already tracked in the workspace database.

---

## 20. Error Architecture

### 20.1 Error Taxonomy

#### User Errors (recoverable, user-visible)

| Error | Origin | Current Handling | Proposed Handling |
|-------|--------|------------------|-------------------|
| User cancels `NSOpenPanel` | `NSOpenPanel.runModal() == .cancel` | Silent no-op (correct) | No change needed |
| File too large (>512 KB) | `WorkspaceManager.createFileWorkspace()` throws `.fileTooLarge` | `SessionViewModel.errorMessage` set; visible in session sheet | Should show toast via `DecodeToastManager` |
| Binary file detected | `WorkspaceManager.createFileWorkspace()` throws `.binaryFile` | `SessionViewModel.errorMessage` set; visible in session sheet | Should show toast |
| File read error (permission denied) | `String(contentsOf:)` throws | `SessionViewModel.errorMessage` set | Should show toast |
| File not found (race between select and open) | `String(contentsOf:)` throws | `SessionViewModel.errorMessage` set | Should show toast |

#### System Errors (internal, should not reach user)

| Error | Origin | Current Handling |
|-------|--------|------------------|
| Database write failure | `db.createWorkspace()` throws | Propagated to `SessionViewModel.errorMessage` |
| Bookmark creation failure | `url.bookmarkData()` returns nil | Falls back to empty `Data()` — non-fatal |
| Parser crash | `SwiftSyntaxParser` / `TreeSitterParser` | No crash handling — would propagate as uncaught |
| Indexing batch failure | `processChanges()` returns error | Logged in DEBUG; indexing continues with next batch |
| File watcher failure | DispatchSource creation | Would fail silently; workspace becomes unwatched |
| Directory watcher FD failure | `open()` returns -1 | Watcher doesn't start; no error surfaced |

### 20.2 Error Propagation Path

```
WorkspaceManager throws error
    │
    ▼
SessionViewModel.loadFile() / loadDirectory() catches
    │
    ├── Sets vm.errorMessage = "Failed to open: \(error)"
    ├── Sets vm.isLoading = false
    │
    ▼
Session sheet displays error (IF the sheet is open)
```

### 20.3 Error Gap (PROPOSED DESIGN)

**Problem**: When the Launcher triggers file/folder addition, errors are caught by `SessionViewModel` and set on `errorMessage`. But the Launcher collapses immediately, and the session sheet may not be visible. The user has no indication that the operation failed.

**Proposed solution**: Route Launcher-originated errors through `DecodeToastManager`:

```
WorkspaceManager throws
    │
    ▼
SessionViewModel catches
    │
    ├── Sets vm.errorMessage (for session sheet display)
    │
    └── If error originated from Launcher flow:
        └── toastManager.show("Could not add file: too large", style: .error)
```

This requires either:
1. A flag on `SessionViewModel` indicating the source of the current operation
2. Or the `handleOpenSession()` / `handleOpenWorkspace()` methods in `AppDependencies` catching errors directly and showing toasts

Option 2 is simpler and keeps the error handling close to the Launcher wiring.

### 20.4 Error Recovery

| Error | Retryable? | Recovery |
|-------|-----------|----------|
| File too large | No | User must select a smaller file |
| Binary file | No | User must select a text file |
| Permission denied | Maybe | User must grant permission in System Settings |
| File not found | No | File was deleted between selection and open |
| Database failure | Maybe | App restart; database corruption → full reset |
| Parser error | Yes | Reselecting the file retries parsing |

---

## 21. Performance Architecture

### 21.1 Launcher-Specific Performance

| Operation | Target Latency | Actual (CURRENT IMPLEMENTATION) |
|-----------|---------------|--------------------------------|
| Launcher panel creation | <50ms | One-time on `show()`. Panel is reused. |
| Hover → expand animation | 380ms | Spring animation, non-blocking |
| Button tap → NSOpenPanel | <100ms | Immediate — `NSApp.activate()` + `NSOpenPanel()` |
| Collapse animation | 430ms | Spring animation, non-blocking |

The Launcher itself is extremely lightweight. It has:
- No network calls
- No file I/O
- No database access
- No parsing
- No computation beyond animation math

### 21.2 Downstream Performance

| Operation | Latency Range | Blocking? |
|-----------|--------------|-----------|
| `NSOpenPanel.runModal()` | User-dependent | Yes (modal, blocks main thread) |
| File parse (single file) | 5-200ms | Yes (on `@MainActor`) |
| Database write (GRDB) | <10ms | Brief await |
| Start file watcher | <5ms | No (launches background Task) |
| Directory manifest scan | 100ms-5s | Background Task |
| Directory indexing (full) | 1s-60s+ | Background Task (batched) |
| KGR knowledge generation | 2s-30s | Background Task (off-main) |

**Critical path**: The only main-thread blocking work between "user clicks button" and "UI is responsive again" is:
1. `NSOpenPanel.runModal()` (user-driven)
2. File read + parse (for `.file` workspaces, typically <200ms)
3. Database write (<10ms)

Directory workspace creation returns quickly — indexing happens entirely in the background.

### 21.3 Large Folder Handling

**CURRENT IMPLEMENTATION**: No explicit limit on directory size. The `IndexingCoordinator`:
- Scans the manifest (may be slow for very large directories, e.g., 100K+ files)
- Batches into groups of 20
- Calls `Task.yield()` between batches to prevent starvation
- Reports progress via `IndexingState.indexing(processed:, total:)`

**Potential issue**: The manifest scan (`FileManager.enumerator`) runs inside a `Task` on `@MainActor` (since `IndexingCoordinator` is `@MainActor`). For very large directories, this could block the main thread during the scan phase.

### 21.4 Memory Pressure

The Launcher itself is negligible in memory:
- One `NSPanel` instance (~few KB)
- One `NSHostingView` + SwiftUI view tree (~few KB)
- No caches, no buffers

Downstream memory pressure from adding content:
- Per-file workspace: `ParsedEntity` array + `FileIntelligence` (typically <50KB per file)
- Per-directory workspace: `parsedEntitiesByFile` across all indexed files (proportional to codebase size)

This is not a Launcher concern — memory management is `WorkspaceManager`'s responsibility.

---

## 22. Security Architecture

### 22.1 Filesystem Access

**CURRENT IMPLEMENTATION**: The Decode sandbox is **disabled** (`Decode.entitlements`). All file access goes through direct path strings without security-scoped bookmark resolution.

Implications for the Launcher:
- `NSOpenPanel` returns regular file URLs (no security scope)
- `String(contentsOf:)` reads files directly (no `startAccessingSecurityScopedResource()`)
- `FileManager.enumerator` traverses directories without security scope
- This works because the sandbox is disabled

**Future risk**: If the sandbox is re-enabled:
1. `NSOpenPanel` URLs would need to be converted to security-scoped bookmarks
2. `BookmarkManager` (currently a stub) would need full implementation
3. Bookmark resolution (`URL(resolvingBookmarkData:options:.withSecurityScope:)`) would need to be called before any file access
4. `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` lifecycle management

### 22.2 Path Validation

**CURRENT IMPLEMENTATION**:
- **File size guard**: `fileSize(url) <= AILimits.maxFileSizeBytes` (512 KB)
- **Binary detection**: First N bytes checked for null byte
- **Path existence**: `FileManager.default.fileExists(atPath:)` during workspace restoration
- **No symlink handling**: Symlinks are followed without detection. A symlink to a file outside the expected scope would be accepted.
- **No path traversal protection**: Paths from `NSOpenPanel` are trusted (this is appropriate — `NSOpenPanel` returns user-selected paths)

### 22.3 Sensitive File Protection

**CURRENT IMPLEMENTATION**: No filtering of sensitive files. The user can add `.env`, `credentials.json`, private keys, etc. This is appropriate for a local-only tool, but:
- These files would be parsed and potentially sent to AI providers for explanation
- The intelligence pipeline does not filter sensitive content

**OPEN DECISION**: Whether the Launcher or `WorkspaceManager` should warn when adding known-sensitive file patterns.

### 22.4 Relevant Security Properties

- The Launcher does not access the network
- The Launcher does not read file contents
- The Launcher does not log file paths (no `print()` in `FloatingLauncher.swift`)
- The Launcher does not send analytics events
- All file access happens downstream in `WorkspaceManager`

---

## 23. Observability

### 23.1 Current Observability (CURRENT IMPLEMENTATION)

The Launcher has **zero observability**. No analytics events, no debug logging, no metrics.

The downstream operations do have observability:
- `SessionViewModel.loadFile()` / `loadDirectory()` set `isLoading` / `errorMessage` (UI state)
- `IndexingCoordinator.state` tracks indexing progress (UI state)
- Workspace creation/activation trigger `saveSessionState()` (persistence side-effect)

### 23.2 Proposed Analytics Events

Based on Decode's existing analytics architecture (`AnalyticsEventService`, fire-and-forget):

| Event | Type | When | Metadata |
|-------|------|------|----------|
| `launcher_add_file` | Product analytics | User clicks Add File button | `{ source: "launcher" }` |
| `launcher_add_folder` | Product analytics | User clicks Add Folder button | `{ source: "launcher" }` |
| `launcher_tap` | Product analytics | User taps main circle | None |

**Events NOT recommended**:
- `launcher_expanded` / `launcher_collapsed` — too noisy, hover is not intent
- `launcher_shown` / `launcher_hidden` — always shown, never hidden
- `launcher_error` — errors are workspace errors, not Launcher errors

### 23.3 Distinguishing Launcher from Hotkey

**CURRENT IMPLEMENTATION**: Both the Launcher and the hotkeys call the same methods (`handleOpenSession()` / `handleOpenWorkspace()`). There is no way to distinguish in analytics whether a workspace was created via the Launcher, a hotkey, or the session sheet UI.

**PROPOSED DESIGN**: Add a `source` parameter to the flow:
```swift
launcher.onAddFile = { [weak self] in self?.handleOpenSession(source: "launcher") }
// vs hotkey:
self?.handleOpenSession(source: "hotkey")
```

This source could be passed through to the analytics event for workspace creation.

---

## 24. Protocol / Service Contracts

### 24.1 Existing Contracts Used by Launcher

The Launcher uses **no protocols**. It communicates exclusively through closures:

```swift
var onAddFile: (() -> Void)?
var onAddFolder: (() -> Void)?
var onLauncherTapped: (() -> Void)?
```

This is the simplest possible contract. No new protocols are needed.

### 24.2 Why No Protocol Is Needed

A protocol would be justified if:
- Multiple implementations of the Launcher existed (e.g., for testing) — they don't
- The Launcher needed to be injected into other components — it doesn't
- The Launcher's callbacks needed to be swapped at runtime — they don't

The closure-based approach is simpler, provides the same testability (closures can be replaced in tests), and avoids abstraction for the sake of abstraction.

### 24.3 Contracts the Launcher Depends On (Indirectly)

Through its callbacks, the Launcher indirectly depends on:

| Contract | Owner | Used By |
|----------|-------|---------|
| `SessionViewModel.loadFile(url:)` | `SessionViewModel` | `handleOpenSession()` calls it |
| `SessionViewModel.loadDirectory(url:)` | `SessionViewModel` | `handleOpenWorkspace()` calls it |
| `WorkspaceManager.createFileWorkspace(url:)` | `WorkspaceManager` | `loadFile()` calls it |
| `WorkspaceManager.createDirectoryWorkspace(url:)` | `WorkspaceManager` | `loadDirectory()` calls it |

These are method contracts, not protocol contracts. The Launcher does not import these types and has no compile-time dependency on them.

### 24.4 Proposed Contracts for Drag & Drop (PROPOSED DESIGN)

If drag-and-drop is added, new callbacks would be needed:

```swift
var onDropFiles: (([URL]) -> Void)?
var onDropFolders: (([URL]) -> Void)?
```

These would bypass `NSOpenPanel` and go directly to:
```swift
launcher.onDropFiles = { [weak self] urls in
    Task {
        for url in urls {
            await self?.sessionViewModel?.loadFile(url: url)
        }
    }
}
```

---

## 25. Data Flow Diagrams

### A. Add File (Current Implementation)

```
┌─────────────┐     hover      ┌─────────────┐    click     ┌─────────────┐
│  Collapsed   │ ────────────→ │  Expanded    │ ──────────→ │ onAddFile() │
│  (22px peek) │               │  (132x164)   │  "File" btn  │  callback   │
└─────────────┘               └─────────────┘              └──────┬──────┘
                                                                   │
                              ┌────────────────────────────────────┘
                              ▼
                    ┌─────────────────────┐
                    │ AppDependencies     │
                    │ .handleOpenSession()│
                    │                     │
                    │ NSApp.activate()    │
                    │ NSOpenPanel()       │──── user selects files ────┐
                    │ .runModal()         │                            │
                    └─────────────────────┘                            ▼
                                                              ┌──────────────┐
                                                              │ SessionVM    │
                                                              │ .loadFile()  │
                                                              │              │
                                                              │ isLoading=T  │
                                                              └──────┬───────┘
                                                                     │
                              ┌──────────────────────────────────────┘
                              ▼
                    ┌─────────────────────────┐
                    │ WorkspaceManager        │
                    │ .createFileWorkspace()   │
                    │                         │
                    │ ┌─ dedup check          │
                    │ ├─ validation           │
                    │ ├─ parse (AST)          │
                    │ ├─ DB persist           │
                    │ ├─ build intelligence   │
                    │ ├─ start watcher        │
                    │ ├─ activate             │
                    │ ├─ save session state   │
                    │ └─ trigger KGR          │
                    └─────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────────┐
                    │ Session sheet presents  │
                    │ (shouldPresentSession)   │
                    │                         │
                    │ Workspace visible in    │
                    │ session list + dock     │
                    └─────────────────────────┘
```

### B. Add Folder

```
┌─────────────┐     hover      ┌─────────────┐    click      ┌──────────────┐
│  Collapsed   │ ────────────→ │  Expanded    │ ──────────→  │ onAddFolder()│
└─────────────┘               └─────────────┘  "Folder" btn  └──────┬───────┘
                                                                     │
                              ┌──────────────────────────────────────┘
                              ▼
                    ┌─────────────────────┐         ┌──────────────┐
                    │ AppDependencies     │         │ SessionVM    │
                    │ .handleOpenWorkspace│ ──────→ │ .loadDir()   │
                    │ NSOpenPanel (dir)   │         └──────┬───────┘
                    └─────────────────────┘                │
                                                           ▼
                    ┌───────────────────────────────────────────────────┐
                    │ WorkspaceManager.createDirectoryWorkspace()       │
                    │                                                   │
                    │ ┌─ dedup check                                    │
                    │ ├─ DB persist                                     │
                    │ ├─ activate + save session state                  │
                    │ └─ startIndexing(managed:)                        │
                    │     │                                             │
                    │     ├─ IndexingCoordinator.start()                │
                    │     │   ├─ scanManifest() → list of files         │
                    │     │   ├─ batch(20) → processChanges() → pipeline│
                    │     │   └─ .complete(fileCount:)                   │
                    │     │                                             │
                    │     └─ startDirectoryWatching(managed:)           │
                    │         └─ FSEvents on root FD → AsyncStream      │
                    └───────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────────┐
                    │ Session sheet presents  │
                    │ Dock shows indexing     │
                    │ progress indicator      │
                    └─────────────────────────┘
```

### C. Drag and Drop (PROPOSED DESIGN)

```
┌─────────────┐   drag enters   ┌─────────────┐    drop       ┌──────────────┐
│  Collapsed   │ ─────────────→ │  Expanded    │ ──────────→  │ performDrag  │
│  (auto-expand│  with visual   │  (drop zone  │  files/dirs   │ Operation()  │
│   on drag)   │  highlight     │   highlight)  │              └──────┬───────┘
└─────────────┘               └─────────────┘                       │
                                                        ┌────────────┴────────────┐
                                                        │ Separate files from dirs │
                                                        └────────────┬────────────┘
                                                                     │
                                              ┌──────────────────────┼──────────────┐
                                              ▼                      ▼              │
                                    onDropFiles([URL])     onDropFolders([URL])      │
                                              │                      │              │
                                              ▼                      ▼              │
                                    vm.loadFile(url:)    vm.loadDirectory(url:)      │
                                    (for each URL)       (for each URL)             │
                                              │                      │              │
                                              └──────────┬───────────┘              │
                                                         ▼                          │
                                              WorkspaceManager                      │
                                              (same flows as A & B)                 │
                                                                                    │
                                                         ┌──────────────────────────┘
                                                         ▼
                                              Toast on error
                                              (no NSOpenPanel needed)
```

### D. Duplicate Input

```
User selects file already in workspace
    │
    ▼
WorkspaceManager.createFileWorkspace(url:)
    │
    ├── In-memory check: workspaces.values.first(where: rootPath == url.path)
    │   └── MATCH FOUND
    │
    ├── reparseFileWorkspace(id:)  ← re-reads source, rebuilds entities
    ├── activateWorkspace(id:)     ← makes it the active workspace
    └── return                     ← no new workspace, no error
    │
    ▼
SessionViewModel.isLoading = false  (success)
Session sheet presents (shows existing workspace, now refreshed)
```

### E. Failed Input (File Too Large)

```
User selects 2MB source file via Launcher
    │
    ▼
WorkspaceManager.createFileWorkspace(url:)
    │
    ├── fileSize(url) == 2,097,152
    ├── Guard: 2,097,152 > 524,288 (512 KB)
    └── throw WorkspaceError.fileTooLarge
    │
    ▼
SessionViewModel.loadFile() catch block
    │
    ├── errorMessage = "Failed to open: The file is too large."
    ├── isLoading = false
    │
    ▼
Session sheet shows error (IF visible)
Launcher has already collapsed (no feedback)  ◄── GAP
```

### F. Application Restart

```
App launches
    │
    ▼
DecodeApp.init()
    ├── AppDependencies() — lightweight construction
    └── No Launcher yet
    │
    ▼
didBecomeActiveNotification
    │
    ▼
AppDependencies.performDeferredStartup()
    │
    ├── ... (auth, database, services) ...
    │
    ├── Task { await wsManager.restoreWorkspaces() }
    │   └── Loads session-state.json
    │   └── For each workspace ID in state:
    │       └── Fetch from DB → parse/index → add to memory
    │
    ├── FloatingLauncher() ← created here
    │   ├── Set callbacks
    │   └── launcher.show() ← panel ordered front
    │
    └── ... (pipeline startup, hotkeys) ...
    │
    ▼
Launcher visible (collapsed, 22px sliver)
Workspaces restored (dock shows pills)
```

### G. Workspace Restoration + Launcher Action

```
App launches → restoreWorkspaces() starts (async)
    │                                        │
    │ (concurrent)                           │
    ▼                                        │
Launcher.show() ← visible immediately        │
    │                                        │
    ▼                                        │
User hovers + clicks "Add File"              │ (restore still running)
    │                                        │
    ▼                                        │
handleOpenSession()                          │
    │                                        │
    ├── NSOpenPanel.runModal() ← blocks      │
    │                                        │
    │   (restore may finish during panel)    │
    │                                        ▼
    │                              workspaces restored
    ▼
User selects file
    │
    ▼
vm.loadFile(url:) → createFileWorkspace(url:)
    │
    ├── Dedup check includes restored workspaces  ◄── correct behavior
    └── No race condition: all on @MainActor
```

### H. Concurrent Add Operations

```
User adds folder via Launcher → NSOpenPanel (modal, blocks)
    │
    ▼
User selects folder → panel dismisses
    │
    ▼
Task { vm.loadDirectory(url:) } ← starts, returns quickly
    │
    │ (indexing runs in background)
    │
    ▼ (main thread free)
User immediately hovers Launcher → clicks "Add File"
    │
    ▼
handleOpenSession() → NSOpenPanel (modal, blocks)
    │
    ▼
User selects file → panel dismisses
    │
    ▼
Task { vm.loadFile(url:) } ← starts
    │
    ├── createFileWorkspace() runs on @MainActor (serialized)
    ├── Indexing of directory continues in parallel (background Task)
    └── Both workspaces exist simultaneously — no conflict
```

---

## 26. Testing Architecture

### 26.1 Testing Strategy

| Test Category | Scope | Method |
|---------------|-------|--------|
| State machine | `LauncherState` transitions | Unit test |
| Expand/collapse guards | `FloatingLauncher` re-entrance protection | Unit test |
| Callback wiring | Closures are called correctly | Unit test |
| Workspace creation via Launcher | End-to-end flow | Integration test (existing `WorkspaceManager` tests) |
| Dedup behavior | Same path added twice | Integration test (existing) |
| Error propagation | `fileTooLarge`, `binaryFile` | Integration test (existing) |
| Concurrent adds | Two adds in sequence | Integration test |
| NSPanel lifecycle | Panel creation, show, hide | Manual test (AppKit panels difficult to unit test) |
| Hover behavior | NSTrackingArea enter/exit | Manual test |
| Animation | Spring animations smooth | Manual/visual test |
| Multi-display | Positioning on secondary display | Manual test |
| Fullscreen | Visible in fullscreen mode | Manual test |

### 26.2 Key Invariants

These are the properties that must always hold:

1. **Launcher never owns workspace state.** The Launcher has no `Workspace`, `ManagedWorkspace`, or `WorkspaceManager` property. All workspace operations flow through closures.

2. **UI remains responsive during ingestion.** The Launcher returns to collapsed state immediately after triggering an action. Indexing runs in background.

3. **Duplicate additions are idempotent.** Adding the same file/directory twice does not create a duplicate workspace, does not corrupt state, and does not error.

4. **Failed ingestion does not leave inconsistent state.** If `createFileWorkspace()` throws, no workspace is created, no watcher starts, no session state is saved.

5. **Application restart preserves workspace state.** Workspaces created via the Launcher persist across restarts through the GRDB + session-state.json architecture.

6. **Intelligence infrastructure remains decoupled.** `FloatingLauncher.swift` does not import any understanding pipeline module, AI provider, or domain model.

7. **The Launcher is visible on all Spaces and in fullscreen.** `.canJoinAllSpaces` + `.fullScreenAuxiliary` ensure this.

8. **The Launcher never activates Decode on hover.** `.nonactivatingPanel` ensures the user's editor keeps focus.

### 26.3 Existing Test Coverage

The Launcher's downstream behavior is covered by existing tests:
- `WorkspaceManagerTests` — workspace creation, dedup, close, restore
- `IndexingCoordinatorTests` — scanning, batching, progress states
- `SessionStateTests` — persistence, restoration, clean-slate first launch
- `WorkspaceResolverTests` — resolution after workspace creation

The Launcher itself has no dedicated tests. Given its simplicity (three closures, animation state), the testing ROI is highest on the downstream integration.

---

## 27. Scalability & Extensibility

### 27.1 Current Scalability

The Launcher scales to any number of workspace additions because it owns no state. Each addition is independent:
- No accumulation of Launcher-specific data
- No memory growth in the Launcher
- No performance degradation with more workspaces

Scalability constraints come from downstream:
- `WorkspaceManager.workspaces` dictionary grows with open workspaces
- `IndexingCoordinator` processing time scales with directory size
- GRDB workspace table grows with all-time workspace count (but only queried on dedup and restore)

### 27.2 Extension Points

The Launcher can be extended without architectural rewrites by adding:

| Extension | Change Required |
|-----------|----------------|
| New action button | Add SwiftUI Button to `LauncherContentView`, new callback on `FloatingLauncher`, wire in `AppDependencies` |
| Drag-and-drop | Add `NSDraggingDestination` to `LauncherTrackingView`, new callbacks |
| Drag-to-reposition | Add `mouseDragged` to `LauncherTrackingView`, persist Y in UserDefaults |
| Multi-display tracking | Change `NSScreen.main` to cursor-tracking logic |
| Collapse/minimize | Add a dismiss gesture, show via hotkey or menu bar |
| Workspace count badge | Add overlay to main circle reading from `WorkspaceManager.workspaces.count` |

### 27.3 Future Input Types

| Input Type | Launcher Change | Downstream Change |
|------------|----------------|-------------------|
| Git repository URL | New button + text field | `WorkspaceManager.createGitWorkspace(url:)` (new) |
| Archive (.zip, .tar.gz) | New button or drop target | `WorkspaceManager.createArchiveWorkspace(url:)` (new) |
| Remote repository | New button + auth flow | Significant infrastructure change |
| IDE integration | Not a Launcher concern | Separate integration point |
| Cloud source | New button + auth flow | Significant infrastructure change |

**Guidance**: Only add extension points when they are needed. Do not prematurely abstract the Launcher's callback mechanism into a protocol or command pattern. The current closure approach is sufficient for the foreseeable feature set.

### 27.4 What Should NOT Be Extended

- **The Launcher should not become a workspace browser.** If users need to see/manage existing workspaces, use the Session Dock or Session View.
- **The Launcher should not show indexing progress.** If users need progress, use the Session Dock or Session View.
- **The Launcher should not display explanations.** That's the HUD.
- **The Launcher should not become a command palette.** If Decode needs a command palette, it should be a separate component.

---

## 28. Architectural Risks

### Risk 1: Error Feedback Gap

**Severity**: Medium
**Likelihood**: High (occurs whenever a user adds an unsupported file)
**Impact**: User adds a file via Launcher, Launcher collapses, error is only visible in the session sheet (which may not be open). User has no feedback that the operation failed.
**Mitigation**: Route Launcher-originated errors through `DecodeToastManager`. The toast surface is always visible and auto-dismisses.

### Risk 2: NSOpenPanel Blocks Main Thread

**Severity**: Low
**Likelihood**: High (occurs on every file/folder addition)
**Impact**: While `NSOpenPanel.runModal()` is open, the Launcher (and all UI) is frozen. No animations, no hover detection.
**Mitigation**: This is standard macOS behavior for modal panels. No fix needed — all macOS apps behave this way. If non-modal file selection is desired in the future, `NSOpenPanel.beginSheet()` could be used, but this requires a parent window.

### Risk 3: Forced Light Appearance

**Severity**: Low
**Likelihood**: Medium (affects users with dark mode enabled)
**Impact**: The Launcher always appears in light mode (`NSAppearance(named: .aqua)`). This may look out of place in a dark mode environment.
**Mitigation**: This is a deliberate design choice shared by all Decode floating surfaces. If dark mode support is added, it should be added consistently across all surfaces, not just the Launcher.

### Risk 4: Primary Display Only

**Severity**: Low
**Likelihood**: Medium (affects multi-display users)
**Impact**: The Launcher only appears on `NSScreen.main`. Users coding on a secondary display must move their cursor to the primary display's left edge.
**Mitigation**: The hotkeys (`Control+Shift+O/P`) work regardless of display. If multi-display Launcher support is needed, the Launcher could track cursor position and reposition.

### Risk 5: No Content Type Filtering

**Severity**: Low
**Likelihood**: Medium
**Impact**: The Launcher's `NSOpenPanel` (via `handleOpenSession()`) does not apply `allowedContentTypes` filtering. Users can select any file type, including images, PDFs, and binaries. Binary files are caught downstream by `isBinaryFile()`, but non-binary unsupported files (e.g., `.png`) would be accepted and parsed (likely yielding empty/meaningless results).
**Mitigation**: Add `allowedContentTypes` to the `handleOpenSession()` panel configuration, matching `SessionViewModel.supportedCodeTypes`.

### Risk 6: Sandbox Re-Enablement

**Severity**: Medium
**Likelihood**: Low (sandbox is disabled for alpha)
**Impact**: If the sandbox is re-enabled, the Launcher's current flow (which relies on direct path access) would break. `BookmarkManager` is a stub.
**Mitigation**: Security-scoped bookmark lifecycle must be implemented before sandbox re-enablement. This is a known limitation documented in CLAUDE.md.

### Risk 7: Collapse During Action

**Severity**: Low
**Likelihood**: Low
**Impact**: The Launcher collapses 150ms after a button tap. If the closure throws synchronously before `NSOpenPanel` appears, the Launcher has already collapsed. The user sees a flash with no result.
**Mitigation**: The current closures are fire-and-forget (no return value, no error propagation back to the Launcher). This is acceptable because `NSOpenPanel` always appears (it's the first thing the closure does after `activate()`).

---

## 29. Architectural Decisions

### Decision 1: Closures Over Protocol

**Decision**: The Launcher communicates with `AppDependencies` through closures, not a protocol.
**Reason**: The Launcher has exactly three actions. A protocol would add indirection with no benefit (no multiple implementations, no runtime swapping, no testing advantage over closures).
**Alternatives**: `LauncherDelegate` protocol, command pattern, event bus.
**Why rejected**: Over-engineering for three fire-and-forget callbacks. Closures are simpler, equally testable, and more idiomatic in Swift.
**Consequences**: Adding a new action requires adding a new closure property and wiring it in `AppDependencies`. This is O(1) work.

### Decision 2: Position-Only Animation (No Resize)

**Decision**: Expand/collapse is achieved by sliding the panel's x-position, not resizing the panel.
**Reason**: Panel resize causes visual glitches with SwiftUI content hosted in `NSHostingView`. Position-only animation is smooth and predictable.
**Alternatives**: Resize the panel from 22px to 132px wide.
**Why rejected**: Visual glitches during resize. SwiftUI layout recalculation during resize causes jank.
**Consequences**: The panel is always 132x164px, even when collapsed. The offscreen portion is invisible but allocated.

### Decision 3: Left Edge Anchoring

**Decision**: The Launcher is anchored to the left edge of the primary screen.
**Reason**: The right edge is occupied by `FloatingSessionDock`. Top/bottom edges conflict with Dock and menu bar. Left edge is typically empty in macOS.
**Alternatives**: Right edge (conflicts with dock), top edge (conflicts with menu bar), draggable position.
**Why rejected**: Left edge minimizes conflicts with macOS chrome and other Decode surfaces.
**Consequences**: On left-handed mouse setups or with macOS Dock on the left, the Launcher may conflict. This is acceptable for alpha.

### Decision 4: Non-Activating Panel

**Decision**: The Launcher uses `.nonactivatingPanel` and never steals focus.
**Reason**: The user is coding in their editor. The Launcher must not disrupt their workflow.
**Alternatives**: Regular window, activating panel.
**Why rejected**: Activating Decode on hover would switch the user's focus, disrupt keyboard input, and potentially switch macOS Spaces.
**Consequences**: `NSApp.activate()` is called only when intentionally needed (before `NSOpenPanel`, on main circle tap).

### Decision 5: Always Visible (No Toggle)

**Decision**: The Launcher is shown unconditionally after authentication and never hidden.
**Reason**: The Launcher's value is in its persistent presence. Hiding it would require a mechanism to show it again, adding complexity.
**Alternatives**: Toggle via menu bar, hotkey to show/hide, auto-hide after inactivity.
**Why rejected**: Simplicity. The 22px sliver is minimal screen real estate. Adding show/hide adds UI and state management complexity.
**Consequences**: The Launcher occupies the left screen edge permanently. Users who don't want it have no way to disable it (a future settings option could address this).

### Decision 6: Reuse Existing Workspace Flows

**Decision**: The Launcher calls the same `handleOpenSession()` / `handleOpenWorkspace()` methods as the hotkeys, rather than having its own workspace creation path.
**Reason**: Single code path for workspace creation. No risk of divergence.
**Alternatives**: Launcher-specific methods that bypass `SessionViewModel`.
**Why rejected**: Code duplication, risk of behavioral divergence between Launcher and hotkey paths.
**Consequences**: Any change to `handleOpenSession()` / `handleOpenWorkspace()` affects both the Launcher and the hotkeys. This is a feature, not a bug.

---

## 30. Open Questions

### OQ-1: Should the Launcher support drag-and-drop?

**Context**: Currently, all file/folder intake is via `NSOpenPanel`. Drag-and-drop from Finder would be a natural interaction.
**Considerations**: Requires `NSDraggingDestination` on `LauncherTrackingView`, new callbacks that bypass `NSOpenPanel`, error feedback via toast.
**Dependencies**: Must validate that `NSTrackingArea` and `NSDraggingDestination` coexist correctly on the same `NSView`.

### OQ-2: Should the Launcher provide error feedback?

**Context**: Errors from workspace creation are caught by `SessionViewModel` and displayed in the session sheet. The Launcher collapses immediately and provides no feedback.
**Recommendation**: Yes — route errors through `DecodeToastManager`.

### OQ-3: Should content type filtering be consistent?

**Context**: `SessionViewModel.openFile()` filters by `supportedCodeTypes` (40+ extensions). `handleOpenSession()` does not filter. This means the Launcher and hotkeys accept any file type.
**Recommendation**: Add `allowedContentTypes` to `handleOpenSession()`'s `NSOpenPanel` configuration.

### OQ-4: Should the Launcher follow cursor across displays?

**Context**: The Launcher is fixed to `NSScreen.main`. Multi-display users may not see it on their working display.
**Recommendation**: Defer until user feedback indicates this is a problem. The hotkeys provide display-independent access.

### OQ-5: Should the Launcher be dismissible?

**Context**: The Launcher is always visible. There is no way to hide it.
**Recommendation**: Add a Settings toggle (`launcherEnabled` in UserDefaults) for users who don't want it. Low priority for alpha.

### OQ-6: Should the Launcher show workspace count?

**Context**: The Launcher's main circle could display the number of open workspaces as a badge.
**Recommendation**: Defer. The Session Dock already shows workspace pills. Adding a count to the Launcher risks duplicating information.

---

## 31. Final Canonical Architecture

### Architecture Diagram

```
                    ┌─────────────────────────────────────────────┐
                    │              PRESENTATION LAYER              │
                    │                                             │
                    │  ┌──────────────────┐                      │
                    │  │ FloatingLauncher  │ ◄── This component   │
                    │  │                  │                      │
                    │  │  LauncherState   │  (animation)         │
                    │  │  LauncherPanel   │  (NSPanel)           │
                    │  │  TrackingView    │  (hover)             │
                    │  │  ContentView     │  (SwiftUI)           │
                    │  └────────┬─────────┘                      │
                    │           │ closures                        │
                    │  ┌────────┴──────────────────────────────┐  │
                    │  │  FloatingSessionDock  FloatingHUD      │  │
                    │  │  DecodeToastManager   SessionView      │  │
                    │  └───────────────────────────────────────┘  │
                    └───────────────┬─────────────────────────────┘
                                    │ method calls
                    ┌───────────────▼─────────────────────────────┐
                    │           APPLICATION LAYER                  │
                    │                                             │
                    │  AppDependencies (DI root)                  │
                    │      │                                      │
                    │      ├── handleOpenSession()                │
                    │      └── handleOpenWorkspace()              │
                    │          │                                   │
                    │          ▼                                   │
                    │  SessionViewModel                           │
                    │      │                                      │
                    │      ├── loadFile(url:)                     │
                    │      └── loadDirectory(url:)               │
                    │          │                                   │
                    │          ▼                                   │
                    │  WorkspaceManager                           │
                    │      │                                      │
                    │      ├── createFileWorkspace(url:)          │
                    │      ├── createDirectoryWorkspace(url:)     │
                    │      ├── IndexingCoordinator                │
                    │      └── SessionStatePersistence            │
                    └───────────────┬─────────────────────────────┘
                                    │ async bridging
                    ┌───────────────▼─────────────────────────────┐
                    │          INFRASTRUCTURE LAYER                │
                    │                                             │
                    │  DatabaseService (GRDB)                     │
                    │  FileWatcherService                         │
                    │  DirectoryWatcherService                    │
                    │  SwiftSyntaxParser / TreeSitterParser       │
                    │  UnderstandingSystem (pipeline)             │
                    └─────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Single Responsibility |
|-----------|----------------------|
| `FloatingLauncher` | Manage the NSPanel, hover interaction, and fire callbacks |
| `LauncherState` | Hold animation progress values |
| `LauncherPanel` | NSPanel that can become key but not main |
| `LauncherTrackingView` | Hover detection via NSTrackingArea |
| `LauncherContentView` | Render the visual content (SwiftUI) |
| `AppDependencies` | Wire Launcher callbacks to application operations |
| `SessionViewModel` | Mediate between UI actions and workspace lifecycle |
| `WorkspaceManager` | Own canonical workspace state and lifecycle |

### State Ownership

| State | Owner | Type |
|-------|-------|------|
| Animation progress | `LauncherState` | Transient |
| Panel visibility | `FloatingLauncher` | Transient |
| Workspaces | `WorkspaceManager` | Canonical (in-memory + DB) |
| Open workspace set | `SessionState` | Transient (JSON file) |
| Active workspace | `WorkspaceManager` | Transient (in-memory, persisted in session state) |

### Data Flow

```
User hover → Launcher expands → User clicks → Callback fires →
AppDependencies → SessionViewModel → WorkspaceManager →
{Parse, Persist, Watch, Index, Activate} → Session sheet presents
```

### Concurrency Boundaries

```
@MainActor: FloatingLauncher → AppDependencies → SessionViewModel → WorkspaceManager
    │
    ├── NSOpenPanel.runModal() — blocks main thread (modal)
    │
    └── Background Tasks:
        ├── IndexingCoordinator.start() — pipeline processing
        ├── DirectoryWatcherService — FSEvents on utility queue
        ├── FileWatcherService — file monitoring on utility queue
        └── KGR runtime — knowledge generation on detached task
```

### Persistence Boundaries

```
Launcher: NONE (all state is transient)

Downstream:
├── GRDB: Workspace records (permanent history)
├── JSON: session-state.json (transient session — which workspaces are open)
├── JSON: virtual-session.json (investigation memory)
└── File I/O: understanding pipeline snapshots
```

### Error Boundaries

```
Launcher: No error handling (fire-and-forget callbacks)

Downstream:
├── SessionViewModel: catches WorkspaceManager errors → sets errorMessage
├── WorkspaceManager: throws WorkspaceError (.fileTooLarge, .binaryFile)
├── IndexingCoordinator: logs batch failures, continues with next batch
└── Watchers: fail silently; workspace becomes unwatched
```

### Integration Boundaries

```
Launcher → [closures] → AppDependencies
AppDependencies → [method calls] → SessionViewModel → WorkspaceManager
WorkspaceManager → [closures] → Understanding Pipeline
WorkspaceManager → [GRDB] → Database
WorkspaceManager → [Codable] → Session State File
```

### Key Invariants

1. The Launcher **never** imports Application, Domain, or Infrastructure types
2. The Launcher **never** owns workspace state
3. The Launcher **never** blocks the main thread (except indirectly via `NSOpenPanel.runModal()`)
4. The Launcher **always** delegates to `AppDependencies` via closures
5. Adding content via the Launcher produces the **identical result** as adding via hotkeys
6. The Launcher is **visible on all Spaces and in fullscreen**
7. The Launcher **never activates Decode** on hover (only on explicit tap or `NSOpenPanel`)

### Future Extension Boundaries

```
Safe extensions (Launcher-only changes):
├── New action buttons (add callback, wire in AppDependencies)
├── Drag-and-drop (add NSDraggingDestination to TrackingView)
├── Position persistence (add UserDefaults for Y)
├── Dismissibility (add Settings toggle)
└── Visual enhancements (badges, indicators)

Requires downstream changes:
├── New workspace types (Git, archive, remote)
├── Error feedback (Toast integration)
└── Content type filtering (NSOpenPanel configuration)

Must NOT be added to Launcher:
├── Intelligence pipeline access
├── AI provider access
├── Direct database access
├── Indexing management
└── Workspace state ownership
```

---

*End of Decode Launcher Architecture Specification*
