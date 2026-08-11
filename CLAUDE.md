# CLAUDE.md — Decode

## Project Mission

Decode is a **Software Intelligence Platform**. Its canonical asset is the **Decode Intermediate Representation (DIR)** — a structured, tiered, incrementally maintained representation of software from which all capabilities are derived.

Current capabilities (Explain, Improve, Follow-up) are **consumers** of the shared intelligence architecture. Future capabilities will also be consumers — the DIR is the platform, not the features.

Stage: Pre-beta alpha, invite-only, 5–50 users.

---

## Current Project State (August 2026)

The **Software Intelligence Platform**, **Session Mode**, and **Workspace Mode** epics are all **complete** and production-ready. All are frozen except for bug fixes, reliability improvements, security fixes, or RFC-driven changes.

A **Product Validation Sprint** (July 2026) audited the completed epics, fixed engineering health findings, completed the folder upload UI flow, and introduced the **Session State architecture** — separating workspace history (database) from application session state (JSON file).

**Virtual Session** — cross-mode investigation memory — is **complete** and production-ready. Provides Working Memory (bounded, topic-aware prompt augmentation), Investigation tracking (living knowledge documents), and a Memory Inspector UI. Canonical architecture specification: `architecture/VAS-001-VirtualSessionArchitecture.md`.

The next engineering epic is **Project Intelligence** — understanding the whole codebase as architecture. Phase 1 (Module Intelligence, milestones M1–M7) is **complete**. Phase 2 (Project Intelligence, milestones M8–M11) is **complete**. M12 (Validation) not started. Cross-cutting: KGR Phase 2, Multi-Provider AI Platform, and Enhanced Explanation are all complete.

**Enhanced Explanation** — visual context extraction for Selection Mode — is **complete** and production-ready. Captures a screenshot of the user's working area, sends to a vision LLM (Claude Haiku via backend gateway), and injects corrective visual evidence into the explanation prompt. Vision prompt redesigned through multiple iterations to optimize for downstream explanation quality rather than screenshot description. Architecture: `architecture/VISUAL_CONTEXT_ARCHITECTURE.md`. In Selection Mode, Vision is now triggered by user intent (typing a custom question) rather than a feature flag — see Intent Bar and Conditional Vision below.

**Screenshot Mode Investigation** — product validation concluded that Screenshot Mode (OCR-based) does not currently provide sufficient explanation improvement to justify its latency and complexity. The feature is researched, validated, and closed. No further engineering effort should be invested unless a future product direction introduces fundamentally different use cases (e.g., debugger state capture, compiler diagnostics, runtime UI inspection).

The architecture is fully specified across three document layers (DAS → DDS → Feature Architecture). All specifications are frozen. Implementation follows these documents exactly. Architecture changes require an RFC (see `architecture/README.md` § Architectural Modification Process).

### Completed Platform

The understanding pipeline (all 8 modules) is operational end-to-end: ProducerRuntime → IndexRuntime → RetrievalRuntime → ContextAssembly → ConsumerRuntime, with UnderstandingSystem as the composition root, SwiftSyntaxFrontend and TreeSitterFrontend as producers, and ExplainReasoningEngine, ImproveReasoningEngine, and FollowUpReasoningEngine as consumers. Application integration is wired through AppDependencies with pipeline-first execution and automatic legacy fallback.

All four File Intelligence understanding layers (Identity, Purpose, Behavior, Safety, Design) are implemented and validated.

### What's Implemented

**Three modes, five hotkeys**, all with follow-up questions and post-explanation code improvement:

| Mode | Trigger | Flow |
|------|---------|------|
| Selection | Double-tap Control | Capture selected text → screenshot → intent bar → [if custom question: vision in parallel] → AI → HUD |
| Screenshot | Double-tap Option | Drag-select region → OCR → AI → HUD |
| Session | `⌃⇧O` open file / `⌃⇧P` open directory, then Double-tap Shift | Capture snippet → resolve workspace → build context → AI → HUD |

**Workspace Mode** — workspace-first application architecture (replaces session-first):
- **Two workspace kinds**: `.file` (single file) and `.directory` (entire project folder).
- **WorkspaceManager**: CRUD, security-scoped bookmarks, file accessibility monitoring.
- **WorkspaceResolver**: multi-file entity containment scoring across directory workspaces, `resolvedFilePath` for file-within-directory matching.
- **IndexingCoordinator**: manifest scanning, batched pipeline ingestion (20 files/batch) for directory workspaces.
- **DirectoryWatcherService**: FSEvents-based recursive monitoring, 500ms debounce, mod-date snapshot comparison.
- **NavigationState**: tracks active file/entity within directory workspaces.
- **ProjectExplorerView**: hierarchical file tree sidebar for directory workspaces.
- **Session dock**: shows folder icons, indexing progress, file counts for directory workspaces.

**File Intelligence** — layered understanding of source files:
- **Deterministic Facts Engine**: entities, imports, relationships (calls, conformsTo, inherits, owns), structure outline — all extracted from AST in a single parse pass.
- **Identity layer**: file role, architectural layer, patterns (deterministic).
- **Purpose layer**: why the file exists (deterministic via `FilePurposeDeriver`, augmented by semantic enrichment).
- **Behavior layer**: control flow, state transitions, side effects (semantic enrichment).
- **Safety layer**: error handling, concurrency model, resource lifecycle (semantic enrichment).
- **Design layer**: architectural responsibility, patterns, trade-offs (semantic enrichment).
- **Semantic Enrichment Pipeline**: lazy, cached LLM-derived understanding (all four layers in a single call). Computed on first user question per file version. Cached by `fileHash`. Falls back to deterministic purpose on failure.
- **Question-aware Context Selection**: deterministic routing that selects which understanding layers to include in the explanation prompt based on snippet content and file role.

**Virtual Session** — optional cross-mode investigation memory:
- **VirtualSessionManager**: session lifecycle, insight recording, investigation boundary detection, knowledge evolution, retrieval scoring, prompt augmentation.
- **Working Memory**: bounded (1000 chars), topic-aware, unconditional prompt injection, async LLM compression with deterministic fallback.
- **Investigations**: living knowledge documents with sentence-level evolution, importance-scored eviction, structural anchors.
- **Topic Switching**: two-layer detection — structural (Session Mode), semantic keyword overlap (Selection/Screenshot).
- **Memory Inspector**: popover showing statistics, Working Memory, investigations, known files/entities.
- **Persistence**: JSON file at `~/Library/Application Support/Decode/virtual-session.json`, incremental save after every mutation.
- **Architecture specification**: `architecture/VAS-001-VirtualSessionArchitecture.md` (canonical, cross-platform).

**Intent Bar** — universal pre-explanation interaction layer for Selection Mode:
- **Immediate keyboard interaction**: no click required. NSPanel made key with local+global event monitors.
- **Two interaction paths**: Enter/Space → default explanation (zero vision cost). Printable character → custom question (vision starts in background).
- **`onEditingStarted` callback**: one-shot callback from `ExplanationHUDViewModel` to coordinator. Fires on first printable character. Automatically nilled after firing.
- **`collectIntent()` API**: `FloatingExplanationHUD.collectIntent(sourceApp:mode:explanationProfile:onEditingStarted:)` with `CheckedContinuation` for async/await suspension.

**Conditional Vision** — intent-driven visual context for Selection Mode:
- **Screenshot captured immediately** on hotkey (cheap, local only, ~180ms via ScreenCaptureKit).
- **Vision deferred** until user types a custom question. Default explanations (Enter/Space) never invoke vision — zero AI cost.
- **Parallel execution**: vision runs in background while user types. If vision finishes before user submits, result is available instantly. If still running at submit, coordinator awaits.
- **Intent is the trigger**, not the Enhanced Explanation toggle. Custom questions always enable vision regardless of the toggle state.
- **`pendingVisionTask`**: stored as `Task<VisualContext?, Never>?` on coordinator. Cancelled on cancel, staleness, default explanation, re-invocation, or `stopListening()`.
- **Graceful degradation**: any vision failure → proceed without visual context → identical to no vision.

**Enhanced Explanation** — visual context pipeline components:
- **VisualContextExtractor**: stateless, Sendable. Crops edges, converts to JPEG, sends to vision LLM, validates response.
- **WindowSelector**: weighted scoring system for selecting the correct content window from ScreenCaptureKit candidates. Scores: title (1000), normalLayer (500), active (100), onScreen (50), normalizedArea (0-200).
- **VisualContextCaptureConfiguration**: configurable edge cropping (default 10% per edge) to reduce image tokens.
- **Vision prompt**: extracts information OUTSIDE the highlighted code (file name, containing function, surrounding code, compiler errors).
- **Backend vision gateway**: `POST /api/gateway/vision` with `ANTHROPIC_VISION_API_KEY` → falls back to `ANTHROPIC_API_KEY`.
- **`enhancedExplanationEnabled` toggle**: controls Screenshot Mode vision and debug panel visibility. Selection Mode vision is controlled by user intent, not this toggle.
- **Architecture**: `architecture/VISUAL_CONTEXT_ARCHITECTURE.md`.

**ExplanationExecutionContext** — canonical runtime model for explanation composition:
- **`ExplanationExecutionContext`**: `@MainActor final class` recording which capabilities contributed to an explanation. Created at the start of each explanation flow.
- **Subsystem registration**: each subsystem (Vision, Virtual Session, future capabilities) marks its contribution at the exact point of injection — not before, not after.
- **HUD rendering**: the explanation header renders `executionContext.displayText` (e.g., "Selection · General · Vision · Virtual Session"). No prompt string inspection.
- **Extensible**: to add a future capability, add a `Bool` property and append its label in `labels`. One file, no coordinator changes.
- **File**: `Decode/Domain/Models/ExplanationExecutionContext.swift`.

**Backend**: FastAPI + PostgreSQL on Railway. Full analytics pipeline, admin dashboard, invite management.

**Multi-Provider AI Platform** — capability-based provider routing:
- **AIConfiguration**: single source of truth for all AI provider env vars. `fromEnvironment()` reads `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`, `GROQ_API_KEY`, `GROQ_MODEL` once at startup. `ProviderConfig` struct per provider.
- **AIProviderRegistry**: lightweight `@MainActor` registry. Register/lookup providers by identifier, track availability.
- **GroqProvider**: wraps `OpenAICompatibleProvider` for Groq's OpenAI-compatible API. Used by KGR for background knowledge generation. Receives config via DI.
- **KnowledgeCapabilityResolver**: capability-based routing — jobs declare `requiredCapability`, resolver maps to executor, executor maps to provider. No job references any provider directly.
- **Routing**: File Understanding → Groq (direct, client-side). Explain/Follow-up/Improve → Claude (via Decode Gateway). If `GROQ_API_KEY` missing, everything falls back to Claude.
- **Backend config**: explicit `ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL`/`GROQ_API_KEY`/`GROQ_MODEL` with `resolve_*()` fallback to legacy `AI_API_KEY`/`AI_MODEL`/`AI_ADAPTER`.

**Client**: Swift 6, macOS 15+, SwiftUI, Apple Development signed (Team `P5Y864DV5S`).
**Production AI**: Claude via Decode Gateway (premium reasoning), Groq direct (background knowledge generation). Legacy: `AI_ADAPTER=anthropic`, `AI_MODEL=claude-haiku-4-5-20251001`.
**Auth**: Invite-code activation → access token in Keychain → Bearer auth.

---

## Architecture

### Layered Architecture (strict downward dependency)

```
Presentation → Application → Domain → Infrastructure
```

Protocols for cross-layer communication (dependency inversion). No layer imports above it.

### Key Services by Layer

**App**: `AppDependencies` — root DI container, deferred startup, hotkey fan-out.
**Application**: `SelectionModeCoordinator`, `ScreenshotModeCoordinator`, `SessionQuestionCoordinator`, `WorkspaceManager`, `WorkspaceResolver`, `IndexingCoordinator`, `NavigationState`, `SessionState`, `SessionStatePersistence`, `SessionManager`, `SessionResolver`, `ExplanationFramework`, `RepresentationGuidance`, `ImprovementService`, `SemanticEnrichmentService`, `FilePurposeDeriver`, `FileIdentityClassifier`, `VirtualSessionManager`, `VisualContextExtractor`.
**Domain**: Models (`Workspace`, `WorkspaceKind`, `Session`, `CodeEntity`, `AILimits`, `FileIntelligence`, `Relationship`, `SemanticEnrichment`, `ImportDeclaration`, `VirtualSession`, `Investigation`, `Insight`, `InsightContext`, `WorkingMemory`, `InvestigationAnchor`, `VisualContext`, `VisualContextCaptureConfiguration`, `ExplanationExecutionContext`), Protocols (`AIProviderProtocol`, `DatabaseProtocol`, `DirectoryWatcherProtocol`, `VisualContextExtracting`).
**Infrastructure**: `DecodeGatewayProvider`, `GroqProvider`, `AIConfiguration`, `AIProviderRegistry`, `AccessibilityCapture`, `HotkeyService`, `SwiftSyntaxParser`, `TreeSitterParser`, `DatabaseService`, `KeychainService`, `FileWatcherService`, `DirectoryWatcherService`, `ScreenCaptureService`, `VisionOCRService`, `TextReplacementService`, `AnalyticsEventService`, `WindowSelector`.
**Presentation**: `FloatingExplanationHUD`, `ExplanationHUDViewModel`, `ExplanationTagParser`, `ImprovementSectionView`, `FloatingSessionDock`, `SessionView`, `ProjectExplorerView`, `VirtualSessionInspectorView`.

### Dependency Injection
`AppDependencies` (`@Observable @MainActor`) passed via `.environment()`. Manual DI — no framework.

### App Lifecycle
`AppDependencies.init()` performs only lightweight construction. All activation-sensitive work deferred to `performDeferredStartup()` via `didBecomeActiveNotification`. Accessibility permission prompt gated on `authService.state == .authenticated`.

### Codebase Structure
```
Decode/App/            → DecodeApp, AppDependencies, ContentView
Decode/Application/    → Coordinators, managers, context/explanation logic, enrichment
Decode/Domain/         → Models, Protocols
Decode/Infrastructure/ → AI/, AST/, Capture/, Database/, FileSystem/, Hotkey/, Keychain/, OCR/
Decode/Presentation/   → Overlay/, Session/, Onboarding/, Settings/
Decode/Understanding/  → Understanding pipeline modules
backend/app/           → routers/, models/, static/, gateway_service.py, auth.py, config.py
backend/alembic/       → Database migrations
architecture/          → Frozen specifications: das/, dds/, glossary/, VAS-001, VISUAL_CONTEXT; archived: iag/archive/, rfc/archive/
docs/                  → VISION.md (product vision and philosophy)
```

---

## File Intelligence Architecture

File Intelligence is the layered understanding Decode builds about each source file. Defined in `FileIntelligence.swift`.

### Understanding Layers (all implemented)

| Layer | Source | Status |
|-------|--------|--------|
| Identity | Deterministic (naming, entity structure) | Implemented |
| Purpose | Deterministic + semantic enrichment | Implemented |
| Behavior | Semantic enrichment (control flow, state, side effects) | Implemented |
| Safety | Semantic enrichment (error handling, concurrency, resources) | Implemented |
| Design | Semantic enrichment (patterns, trade-offs, coupling) | Implemented |

### Deterministic Facts Engine

Extracts objective, provable facts from AST in a single parse pass:
- **Entities**: classes, structs, enums, protocols, functions, methods, properties (with signatures, line ranges, parent relationships)
- **Imports**: module and symbol imports (`ImportDeclaration`)
- **Relationships**: typed directed edges (`Relationship` struct)
  - `.calls` — entity A calls function B
  - `.conformsTo` — type A conforms to protocol/interface B
  - `.inherits` — type A inherits from type B
  - `.owns` — type A owns member B (nested type or stored property)
- **Structure outline**: hierarchical text outline of file structure

**Parsers**: `SwiftSyntaxParser` (Swift via SwiftSyntax) and `TreeSitterParser` (Python, JS, TS, HTML, CSS, Java, C#, C, C++ via tree-sitter grammars). Both produce `DetailedParseResult` with entities, imports, and relationships.

### Semantic Enrichment Pipeline

Lazy, cached LLM-derived understanding that augments deterministic analysis.

| Component | File | Role |
|-----------|------|------|
| `SemanticEnrichment` | `Domain/Models/SemanticEnrichment.swift` | Domain model (purpose, behavior, safety, design, fileHash, timestamp) |
| `SemanticEnrichmentService` | `Application/SemanticEnrichmentService.swift` | Orchestrator: cache, prompt, LLM call, XML response parsing |

**Lifecycle**:
1. User presses Session Question hotkey
2. `SessionQuestionCoordinator` calls `enrichmentService.enrich(intelligence:)`
3. Cache hit (`fileHash` match) → return immediately
4. Cache miss → send structured facts (NOT raw source) to LLM → cache result
5. LLM failure → return `nil` → coordinator falls back to deterministic purpose

**Key design decisions**:
- Sends structured entity signatures, relationships, imports (~200-500 tokens) instead of raw source (~2000-10000 tokens)
- Single LLM call produces all four layers via XML-tagged output (`<purpose>`, `<behavior>`, `<safety>`, `<design>`)
- Each tag parsed independently — partial responses degrade gracefully
- Runs before quota check — enrichment doesn't consume user quota
- In-memory cache only — resets on app restart, negligible memory at alpha scale
- `var semanticEnrichment: SemanticEnrichment?` on `FileIntelligence` — mutable field on otherwise immutable struct
- Question-aware context selection filters layers before prompt injection based on snippet content and file role

---

## Workspace Mode Architecture

### Workspace-First Flow
User opens a file (`⌃⇧O`) or directory (`⌃⇧P`) → `WorkspaceManager` creates a `ManagedWorkspace` → file is parsed/directory is indexed → user asks a question (Double-tap Shift) → `SessionQuestionCoordinator` resolves workspace → builds context → AI → HUD.

### Workspace Model
`Workspace` (Domain) — persisted via GRDB. Represents persistent workspace history/bookmarks. Every workspace ever created remains in the database — closing a workspace does NOT delete its record. `ManagedWorkspace` (Application) — runtime wrapper with `parsedEntities`, `parsedEntitiesByFile`, `indexingCoordinator`, `directoryWatcher`, `isFileAccessible`.

### Session State (`SessionState` + `SessionStatePersistence`)
Transient application state that survives restart. Stored as `~/Library/Application Support/Decode/session-state.json`. Tracks which workspaces were open (`openWorkspaceIDs`), which was active (`activeWorkspaceID`), and which was pinned (`pinnedWorkspaceID`). Saved incrementally on every open/close/activate/pin mutation (crash-resilient) and again on `willTerminateNotification` (belt-and-suspenders). On launch, `restoreWorkspaces()` restores only workspaces listed in the saved session state. If the file is missing or corrupt (first launch, reset), no workspaces are restored — clean slate.

### Workspace Resolution (`WorkspaceResolver`)
Pinned workspace → unconditional override. Single workspace → trivial. Multiple workspaces → scored by entity containment (100), normalized match (80), file content (60), recency bonus, active bonus. For `.directory` workspaces, searches `parsedEntitiesByFile` across all indexed files and returns `resolvedFilePath`. Low confidence or ambiguous → fallback to `activeWorkspaceId`.

### Directory Indexing (`IndexingCoordinator`)
Scans manifest of supported files, excludes `.git`/`node_modules`/`build`/etc., batches files (20/batch) through the understanding pipeline via `processChanges`. Populates `parsedEntitiesByFile` on ManagedWorkspace.

### Directory Watching (`DirectoryWatcherService`)
FSEvents on root directory FD. 500ms debounce. Mod-date snapshot comparison detects modified/new/deleted files. Reuses `IndexingCoordinator.supportedExtensions` and `excludedDirectories`.

### Multi-File Question Handling
`SessionQuestionCoordinator` derives `effectiveFilePath`/`effectiveFileName`/`effectiveEntities` from the resolved file within a directory workspace. The understanding pipeline uses these effective values for evidence retrieval and context assembly.

### Session Dock
Non-activating `NSPanel` on right screen edge. Capsule pills with magnification. Pin workspace via context menu. Directory workspaces show folder icon, indexing progress, file counts.

---

## Explanation Engine

- **Session Mode**: explanations produced by the understanding pipeline (`ExplainReasoningEngine`, `FollowUpReasoningEngine`, `ImproveReasoningEngine`). Reasoning engines receive structured facts from the DIR, not raw source code.
- **Selection/Screenshot Mode**: direct AI calls with prompts built by coordinators. Two profiles: General (V7) and DSA. Toggled via `dsaModeEnabled` UserDefaults key.
- V7 prompt in `ExplanationFramework.swift`, DSA in `ExplanationFramework+DSA.swift`. Both used by Selection/Screenshot only.
- 7 custom tags: `<hl>`, `<critical>`, `<tip>`, `<note>`, `<analogy>` (inline); `<tldr>`, `<flow>` (block).
- Renderer uses `.inlineOnlyPreservingWhitespace` — block-level headings (`##`) are NOT supported.
- Session follow-ups route through `FollowUpReasoningEngine` with `ConversationState` continuity. Selection/Screenshot follow-ups use 3-message conversation with `followUpSystemPrompt`.

---

## Anchored Follow-Up / Reply ↩

**Status**: Complete, manually verified, production-ready. Frozen except for bug fixes or evidence-driven changes.

Allows users to select a specific fragment of an AI-generated response, explicitly commit it via a "Reply ↩" button, and ask a follow-up question augmented with the selected fragment. Reuses the existing Follow-Up pipeline — no new backend, no new AI system, no persistence.

**Implementation files**:
- `Decode/Presentation/Overlay/SelectableTextView.swift` — NSTextView wrapper with Reply button, cross-block coordination.
- `Decode/Presentation/Overlay/ExplanationHUDViewModel.swift` — State management: `responseSelection` (pending), `anchoredResponseSelection` (committed), `activeSelectionBlockID`, `replyActivated`.
- `Decode/Presentation/Overlay/FloatingExplanationHUD.swift` — Passes `activeSelectionBlockID` to all `SelectableTextView` instances; renders replying-to indicator and placeholder from `anchoredResponseSelection`.
- `Decode/Infrastructure/AI/AILimits.swift` — `maxResponseSelectionCharacters = 1_500`.
- `DecodeTests/Presentation/AnchoredFollowUpTests.swift` — 27 tests covering all state transitions.

**Architecture document**: `architecture/ANCHORED_FOLLOW_UP_REPLY_ARCHITECTURE.md` (30-section CTO-level document).

**Three-state selection model**:
- **Native selection**: AppKit NSTextView highlight. Visual only.
- **Pending selection** (`responseSelection`): ViewModel record of highlighted text. Drives Reply button. Does NOT drive replying-to indicator, placeholder, or augmentation.
- **Anchored selection** (`anchoredResponseSelection`): Committed reply context, created ONLY by clicking Reply. Drives replying-to indicator, placeholder, and `buildAugmentedQuestion()`.

**Critical invariants** (do not violate):
1. Selecting text does NOT activate Reply — only clicking Reply commits the selection.
2. Only `anchoredResponseSelection` drives Follow-Up augmentation.
3. Pending and anchored selections are independent and may coexist.
4. Reply button is visible whenever a pending selection exists, regardless of existing anchored context.
5. A new Reply replaces the previous anchored context.
6. Only one native response selection may be visually highlighted at a time (`.onChange(of: activeSelectionBlockID)` coordination).
7. Stale deselection callbacks cannot clear a newer selection (`suppressNextDeselection` + `activeSelectionBlockID` comparison).
8. Selection state is transient — nothing is persisted.
9. Existing Follow-Up pipeline is reused unchanged.
10. No backend changes were introduced.

**Bugs fixed during implementation**:
- NSAttributedString bridging asymmetry causing spurious content resets (source `AttributedString` comparison on Coordinator).
- Selection immediately activating reply mode (split into pending vs anchored states).
- Multiple NSTextViews retaining visual selection (`.onChange` cross-block coordination replaced insufficient `updateNSView` approach).
- Reply button suppressed when anchored context existed (removed `!replyAnchored` guard).

---

## Improve Code Feature

Post-explanation code improvement. Available in Selection and Session modes (not Screenshot).

- **Session Mode**: improvement routed through `ImproveReasoningEngine` via the understanding pipeline.
- **Selection Mode**: improvement via `ImprovementService` direct AI call. Uses `<improvement_summary>` and `<improved_code>` XML-like tags.
- No-improvement path: when code is already clean, model returns summary-only. This is a successful outcome.
- `TextReplacementService`: clipboard backup → write → simulated ⌘V → clipboard restore.

---

## Analytics

**Request analytics** (`request_logs`): `user_id`, `mode`, `success`, `latency_ms`, `error_type`, `ai_provider`, `ai_model`, `context_tier`, `explanation_profile`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_character_count`, `language`, `created_at`.

**Product analytics** (`analytics_events`): `user_id`, `event_type`, `mode`, `metadata` (JSONB), `created_at`. Events: `improve_copy`, `improve_replace`, `improve_dismiss`, `improve_no_change`.

**Compound modes**: `selection_followup`, `session_followup`, `screenshot_followup`, `selection_improve`, `session_improve`.

**Admin dashboard (legacy)** at `GET /admin`: analytics, token stats, improve stats, follow-up stats, mode/tier/provider/profile tables, user management, invite generation. Remains for backward compatibility.

**Dashboard V2** at `GET /admin/v2`: Founder-grade operational intelligence dashboard. Feature-complete and frozen.
- **8 pages**: Executive, Product, AI Platform, Users, Workspaces, Quality, Cost, Settings.
- **Analytics V2 API** (`/api/v2/analytics/*`): 10 endpoints — executive, product, users, user detail, ai-platform, quality, cost, settings, timeline, live, search, token-breakdown, aggregate. All require ADMIN_TOKEN auth.
- **Token analytics**: Per-feature efficiency (compound modes), daily trends, top consumers, percentile distributions (P50/P95/P99), input/output ratio analysis, forecast metrics, feature × provider/model cross-tabulations.
- **Visualization**: 6 canvas-based chart types (area, bar, donut, stacked area, multi-line, heatmap), CSS-based components (ratio bars, percentile cards, horizontal bars), drill-down drawer with export (JSON/CSV).
- **Infrastructure**: `D.*` component library, API client with 1-min cache + inflight dedup + retry, global date filter, Cmd+K search, keyboard shortcuts.
- **Files**: `backend/app/routers/analytics_v2.py`, `backend/app/static/v2/{index.html,app.js,components.js,design.css}`.
- **Status**: Feature-complete. Frozen except for bug fixes, UX polish, or product-driven enhancements.

---

## Backend

### Multi-Provider Gateway (`gateway_service.py`)
Three adapter families selected by `AI_ADAPTER` env var: `openai_compat`, `anthropic`, `gemini`. `call_llm()` returns `(content, latency_ms, token_usage)`. 120s timeout.

### Auth Flow
Admin generates invite code → user activates → access token stored as SHA-256 hash server-side, raw in Keychain client-side → Bearer auth on all requests.

### Client-Side Limits
`AIUsageTracker`: 100 requests per 5-hour rolling window. `AILimits`: maxResponseTokens (4096), maxFileSizeBytes (512 KB), maxSelectedTextCharacters (15,000), maxOCRTextCharacters (10,000).

---

## Engineering Principles

1. **Deterministic first.** Compute everything objectively knowable from the AST deterministically. Never ask an LLM to infer what can be determined objectively.
2. **Semantic understanding augments, never replaces.** Deterministic facts are permanent. Semantic enrichment is an optional layer on top. Deterministic purpose is the permanent fallback.
3. **Lazy semantic enrichment.** Compute only when a user asks a question. Cache by file hash. Never compute during parsing.
4. **Structured facts, not raw source.** Send entity signatures and relationships to the LLM, not source code. 90-95% token reduction.
5. **Information density over narration.** Explanations tell users what they can't see by reading the code.
6. **Incremental shipping.** Small, verifiable changes. Production-quality code only. No multi-week branches.
7. **Server-side intelligence.** Analytics, token tracking, cost estimation — all server-side. Client stays thin.
8. **Backward compatibility by default.** New DB columns nullable. New API fields have defaults.

---

## Architecture Specifications (Frozen)

The architecture is fully specified and frozen. Implementation conforms to these documents — they do not conform to implementation. Changing a frozen specification requires an RFC (see `architecture/README.md` § Architectural Modification Process).

### Document Layers

```
DAS (frozen) — Architectural principles, invariants, the DIR definition
  ↓
DDS (frozen) — Runtime subsystem contracts, state models, failure modes
  ↓
Feature Architecture (frozen) — VAS-001 (Virtual Session), VISUAL_CONTEXT (Visual Context)
  ↓
Implementation — Source code that realizes all of the above
```

IAG-001 through IAG-004 are archived in `architecture/iag/archive/` — they guided pipeline construction (now complete) and are historical reference only.

### Specification Inventory

| Layer | Documents | Scope |
|-------|-----------|-------|
| DAS | DAS-000 through DAS-012 | Architecture: principles, DIR, tiers, entities, relationships, passes, indexes, retrieval, context assembly, incremental update, consumers, storage |
| DDS | DDS-000 through DDS-009 | Design: authoring standard, producer runtime, DIR runtime, pass runtime, index runtime, retrieval runtime, context assembly, update engine, storage engine, consumer runtime |
| Feature | VAS-001, VISUAL_CONTEXT | Virtual Session architecture, Visual Context architecture |

### Understanding Pipeline Modules

8 framework targets building the intelligence pipeline:

| Module | DDS Source | Role |
|--------|-----------|------|
| DIRCore (M1) | DDS-002 types | Foundation types and cross-module protocols |
| ProducerRuntime (M2) | DDS-001 + DDS-003 | Pass execution, DAG construction |
| IndexRuntime (M3) | DDS-004 | Five index families, incremental maintenance |
| RetrievalRuntime (M4) | DDS-005 | Five-stage evidence retrieval |
| ContextAssembly (M5) | DDS-006 | Strategy-based context frame assembly |
| ConsumerRuntime (M6) | DDS-009 | Reasoning engine management, grounding verification |
| UpdateEngine (M7) | DDS-007 + DDS-002 runtime | DIR runtime + synchronous/deferred pipeline coordination |
| StorageEngine (M8) | DDS-008 | Snapshots, GC, grounding map, content hashing |

### Implementation Phases

| Phase | Name | Modules | Status |
|-------|------|---------|--------|
| 1 | Foundation | DIRCore, build system, test infrastructure | Complete |
| 2 | Leaf Modules | StorageEngine, ProducerRuntime, IndexRuntime (parallel) | Complete |
| 3 | Write Pipeline | UpdateEngine | Complete |
| 4 | Read Pipeline | RetrievalRuntime → ContextAssembly → ConsumerRuntime | Complete |
| 5 | System Integration | UnderstandingSystem composition root + integration tests | Complete |
| 6 | Application Integration | AppDependencies wiring, file monitoring bridge | Complete |

All six phases are complete.

---

## Implementation Rules

### Implement, Do Not Redesign

The architecture is specified. Implementation realizes the specifications. Do not:
- Redesign module boundaries
- Change the dependency graph between modules
- Add or remove modules
- Change actor placement
- Change technology selections

### Before Implementing

1. Read only the DDS sections relevant to the current capability.
2. Inspect only the affected repository files — do not assume.
3. Implement the capability in production-quality code. No scaffolding, no stubs, no "we'll fix it later."
4. Verify DDS/DAS compliance.
5. Add focused tests.
6. Verify builds and tests.
7. Update the active implementation status document.
8. Continue to the next capability.

Think in milestones rather than files.

### Quality Priorities

Optimize for production quality, maintainability, correctness, scalability, and user value. These take precedence over clever implementations.

### Implementation Philosophy

- Build product capabilities on top of the completed platform.
- Reuse ProducerRuntime, RetrievalRuntime, ContextAssembly, ConsumerRuntime, UnderstandingSystem, and existing frontends and reasoning engines.
- Avoid modifying platform infrastructure unless implementation evidence demonstrates a genuine architectural problem.
- Avoid speculative refactoring.
- Avoid reopening completed architectural discussions.
- Avoid unnecessary investigations or documentation.

### When the Spec Seems Wrong

If implementation reveals a genuine contradiction with DAS/DDS — not inconvenience, but an actual invariant violation, contract contradiction, or impossibility — **stop and explain why an RFC is required**. Do not silently deviate from the specification. Do not work around it. Document the finding and the evidence.

The RFC must include: which document and section, what it currently says, what's proposed, why it's incorrect (with evidence), and downstream impact. See `architecture/README.md` § Architectural Modification Process.

### Verification

Verification is binary: builds succeed or fail, tests pass or fail, strict concurrency reports or doesn't. No subjective assessment.

---

## Roadmap

1. ~~**File Intelligence**~~ — **Complete.** All four semantic understanding layers implemented, validated, and shipped.
2. ~~**Architecture**~~ — **Complete.** DAS-000–012, DDS-000–009 all frozen. IAG-001–004 archived.
3. ~~**Understanding Pipeline Implementation (Session Mode)**~~ — **Complete.** All 6 phases, all 8 modules, application integration, pipeline-first execution for Explain/Follow-Up/Improve, production hardening, and comprehensive test coverage.
4. ~~**Workspace Mode**~~ — **Complete.** All 8 milestones (W0–W7). Workspace-first architecture, directory support, indexing, watching, multi-file resolution.
5. ~~**Product Validation Sprint**~~ — **Complete.** Engineering health cleanup (E1-01, E2-00, E3-01 findings), folder upload UI completion, SessionState architecture (workspace history vs application session separation).
6. ~~**Virtual Session**~~ — **Complete.** Cross-mode investigation memory with Working Memory, Investigations, topic switching, compression, and Memory Inspector. Architecture specification: `architecture/VAS-001-VirtualSessionArchitecture.md`.
7. **Project Intelligence** — **In progress.** Phase 1 (Module Intelligence, M1–M7) complete. Phase 2 (Project Intelligence, M8–M11) complete. M12 (Validation) not started. Cross-cutting: KGR Phase 2 (proactive File Understanding) and Multi-Provider AI Platform complete. See `PROJECT_INTELLIGENCE_IMPLEMENTATION_STATUS.md`.
8. ~~**Enhanced Explanation**~~ — **Complete.** Visual context extraction for Selection Mode. WindowSelector for reliable content window selection. Edge cropping for image token optimization. Backend vision gateway integration. Vision prompt redesigned for downstream explanation quality. Architecture: `architecture/VISUAL_CONTEXT_ARCHITECTURE.md`.
9. ~~**Screenshot Mode Investigation**~~ — **Complete (researched and closed).** Product validation concluded insufficient explanation improvement for the latency and complexity cost. No further work planned.
10. ~~**Dashboard V2**~~ — **Complete (feature-frozen).** Founder-grade operational intelligence dashboard with 8 pages, Analytics V2 API (10 endpoints), comprehensive token analytics (per-feature efficiency, trends, percentiles, forecasts, cross-tabulations), 6 chart types, drill-down drawers, global search, keyboard shortcuts. Future work: bug fixes, UX polish, validation, browser compatibility.

### Implementation Status Tracking

Virtual Session architecture is specified in `architecture/VAS-001-VirtualSessionArchitecture.md` (canonical cross-platform specification).
Visual Context architecture is specified in `architecture/VISUAL_CONTEXT_ARCHITECTURE.md` (canonical feature architecture).

---

## Known Limitations

1. **Swift conformance ambiguity** — SwiftSyntax lacks type resolution. All inheritance clause items on classes are recorded as `.conformsTo` (cannot distinguish superclass from protocol without type checking).
2. **Sandbox disabled** — re-enabling requires security-scoped bookmarks.
3. **No server-side request cancellation** — client cancels URLSession task but server-side LLM call runs to completion.
4. **No `os.Logger` in release builds** — only server-side observability.
5. **SQL grammar excluded** from tree-sitter — upstream SPM package issue.
6. **Replace ⌘V targeting** — HUD panel may capture key window after Replace click, causing paste to target the panel instead of the editor.
7. **Pre-existing tree-sitter linker issue** — All tree-sitter C package targets fail to link with `___llvm_profile_runtime` undefined symbol. Swift compilation succeeds. Unrelated to pipeline.
8. **Directory watcher monitors root FD only** — relies on FSEvents propagation for deeply nested changes.
9. **No persistent NavigationState** — active file/entity within directory workspaces resets on app restart. `SessionState` provides the foundation for persisting this (add `activeFilePaths: [UUID: String]` to `SessionState`) but this is not yet implemented.

### Pre-Existing Test Failures (4)

These failures predate the Workspace Mode implementation and are unrelated:
1. `streamChatFormatsMessages` (AINetworkClientTests) — `emptyResponse` error
2. `showStreamHandlesError` (ExplanationHUDViewModelTests) — display state mismatch
3. `emptyTagSkipped` (ExplanationTagParserTests) — segment parsing difference
4. `SwiftSyntaxFrontend: Contains output uses file: prefix` — entity qualified name format

---

## Things NOT To Change

These architectural decisions are validated. Do not redesign without strong evidence.

### Frozen Specifications
13. **DAS-000 through DAS-012** — canonical architecture. Changes require a DAS amendment process.
14. **DDS-000 through DDS-009** — canonical design specifications. Changes require a DDS amendment process.
15. **IAG-001 through IAG-004** — implementation architecture (archived in `architecture/iag/archive/`). Historical reference only. Changes to DAS/DDS require an RFC per `architecture/README.md`.
16. **DIR as canonical asset** — all capabilities are consumers of the DIR. Do not build features that bypass the intelligence architecture.

### Completed Platform (Frozen)
1. **Understanding Pipeline** — all 8 modules (DIRCore, ProducerRuntime, IndexRuntime, RetrievalRuntime, ContextAssembly, ConsumerRuntime, UpdateEngine, StorageEngine). Do not modify without RFC.
2. **UnderstandingSystem** — composition root wiring the pipeline. Frozen.
3. **SwiftSyntaxFrontend / TreeSitterFrontend** — producers that feed the pipeline. Frozen.
4. **ExplainReasoningEngine / ImproveReasoningEngine / FollowUpReasoningEngine** — consumers of the pipeline. Frozen.
5. **Pipeline-first execution** — Session Mode Explain, Follow-Up, and Improve attempt the pipeline first, fall back to legacy on failure. Do not remove fallback paths.

### Existing Application
1. **Deterministic Facts Engine** — single-pass AST extraction of entities, imports, relationships. Foundation for everything.
2. **File Intelligence architecture** — layered understanding model (Identity → Purpose → Behavior → Safety → Design). All layers implemented and validated.
3. **Lazy Semantic Enrichment** — triggered by user question, not by parsing. Cached by file hash. In-memory cache. Single LLM call for all four layers.
4. **Structured facts prompt design** — send entity signatures/relationships to LLM, not raw source code. Methods grouped under owning types, external calls included.
5. **Understanding pipeline** — Session Mode uses pipeline-first architecture (retrieve → assemble → reason). No legacy context tiers.
6. **Manual DI** — `AppDependencies` as root container. No framework.
7. **Deferred startup** — `performDeferredStartup()` via `didBecomeActiveNotification`.
8. **Generation-counter request replacement** — coordinators use `requestGeneration` + cancellation. No mutex needed.
9. **V7 explanation prompt** — used by Selection/Screenshot modes. Frozen until real-user evidence justifies changes.
10. **DSA as separate prompt** — not an overlay on V7. Lives in `ExplanationFramework+DSA.swift`.
11. **Analytics pipeline** — server-side token extraction, compound mode values, orthogonal `mode` and `explanation_profile`.
12. **Incremental milestone-based development** — File → Architecture → Session Mode → Workspace Mode → Project Intelligence progression.

### Completed Session Mode (Frozen)
All 18 specification-defined Session Mode capabilities are implemented. Future Session Mode work limited to bug fixes, reliability improvements, security fixes, or explicitly approved product changes.

### Completed Workspace Mode (Frozen)
All 8 milestones (W0–W7) are implemented: domain model, GRDB persistence, WorkspaceManager, IndexingCoordinator, DirectoryWatcherService, WorkspaceResolver multi-file resolution, NavigationState, ProjectExplorerView, SessionQuestionCoordinator directory-aware question handling. Future Workspace Mode work limited to bug fixes or explicitly approved changes.

### Completed Virtual Session (Frozen)
Virtual Session is complete and architecturally specified in `architecture/VAS-001-VirtualSessionArchitecture.md`. Future work limited to bug fixes or explicitly approved changes. Do not modify:
- Working Memory architecture (unconditional injection, 1000-char budget, topic-aware reset).
- Knowledge evolution algorithm (sentence-level dedup, information-density replacement, reinforcement, importance-scored eviction).
- Topic switching (two-layer: structural for Session Mode, semantic keyword overlap for Selection/Screenshot).
- Investigation boundary detection (structural anchor affinity scoring).
- Persistence model (JSON file, incremental save after every mutation).

### Multi-Provider AI Platform (Frozen)
Capability-based provider routing is complete and production-ready. Do not modify:
- AIConfiguration as single source of truth for provider env vars.
- ProviderConfig dependency injection (providers never read env vars directly).
- KnowledgeCapabilityResolver capability-based routing (jobs never reference providers).
- Routing table: File Understanding → Groq, premium reasoning → Claude via gateway.
- Graceful fallback: missing GROQ_API_KEY → uniform resolver routes everything to Claude.
- Backend `resolve_*()` methods with legacy `AI_API_KEY`/`AI_MODEL`/`AI_ADAPTER` fallback.

### Dashboard V2 & Analytics V2 API (Frozen)
Dashboard V2 is feature-complete. Analytics V2 API endpoints are stable. Do not modify:
- Analytics V2 endpoint signatures or response shapes (additive extensions only).
- Dashboard page structure (8 pages, `D.*` component library, `App.pages.*` modules).
- Token-breakdown endpoint compound feature derivation logic.
- Legacy dashboard at `/admin` (remains for backward compatibility).
- Dual-write architecture (v2 `ai_requests` + legacy `request_logs` coexist).

### Completed Anchored Follow-Up / Reply ↩ (Frozen)
Anchored Follow-Up is complete and architecturally documented in `architecture/ANCHORED_FOLLOW_UP_REPLY_ARCHITECTURE.md`. Future work limited to bug fixes or explicitly approved changes. Do not modify:
- Three-state selection model (native, pending, anchored).
- Explicit intent requirement (selecting text ≠ replying to text).
- Single native selection enforcement via `.onChange(of: activeSelectionBlockID)`.
- Stale deselection protection (two-layer: `suppressNextDeselection` + `activeSelectionBlockID` comparison).
- `buildAugmentedQuestion()` as the single augmentation point reading only `anchoredResponseSelection`.
- Reuse of existing Follow-Up pipeline (no separate AI system or backend endpoint).
- Transient selection state (no persistence).

### Session State Architecture
13. **Workspace history vs session state separation** — `Workspace` (database) stores persistent history. `SessionState` (JSON file) stores transient runtime state. Do not add `isOpen` or similar state flags to the `Workspace` model. Do not conflate workspace history with application session state.
14. **Incremental session state persistence** — `saveSessionState()` is called on every open/close/activate/pin mutation. Do not rely solely on `willTerminateNotification` for persistence — unexpected termination must not lose the current session.
15. **Clean-slate first launch** — When no `session-state.json` exists, the app starts with zero workspaces. Do not fall back to restoring all database workspaces.

---

## Explicitly Deferred Features

Do not build these unless explicitly requested.

| Feature | Reason |
|---------|--------|
| AI quality ratings | No user feedback mechanism. Wait for alpha feedback. |
| User-configurable hotkeys | Current hotkeys work. Not justified for alpha. |
| SSE streaming | Current single-chunk approach works. Marginal improvement. |
| ARE artifact generation | Model capability is the bottleneck. |
| Time-windowed analytics | Not useful until daily volume exceeds ~50. |

---

## Common Mistakes to Avoid

### macOS-Specific
- **Never do startup work in `init()` or SwiftUI body.** Causes activation timeout.
- **Never use `NSApp.activate()` in overlays.** Causes Space-switching. Use `orderFrontRegardless()`.
- **Accessibility permissions bind to CDHash.** Use Apple Development signing.
- **macOS 15 Input Monitoring is separate from Accessibility.** Both permissions required.
- **Chromium apps need clipboard fallback.** AX returns nothing for selected text.
- **Stale sandbox container** at `~/Library/Containers/com.decode.app/` intercepts UserDefaults.

### Decode-Specific
- **Never use markdown headings (`##`) in LLM prompts.** Renderer uses `.inlineOnlyPreservingWhitespace`.
- **Never infer active workspace.** Use `activeWorkspaceId` set by explicit user action only.
- **Never watch the file directly.** Watch parent directory to survive atomic saves.
- **Never reuse the explanation system prompt for follow-ups.** Use `followUpSystemPrompt`.
- **Never forget `rebuildAIProvider()` after auth state changes.**
- **All `print()` must be `#if DEBUG` gated.**
- **Run `xcodegen generate` after adding or removing Swift files.**
- **Never `await` handler inside coordinator's `for await` loop.** Use `Task {}` with generation counter.
- **Never encode explanation profile into mode strings.** `mode` and `explanation_profile` are orthogonal.
- **Never force improvement output when code is already clean.**
- **Update `_MODEL_PRICING_PER_MTOK` in admin.py** when switching AI models.

### Understanding Pipeline
- **Never add imports between pipeline modules.** The dependency graph is frozen.
- **Never use `@MainActor` in any understanding pipeline module.** Pipeline runs off the main thread.
- **Never use `@unchecked Sendable` without documented justification.** Strict concurrency must be clean.
- **Never patch downstream to fix upstream.** Fix defects at the earliest point that introduced them.
- **Never import GRDB in any understanding pipeline module.** Storage uses Codable + atomic file I/O.
- **Never redesign a DDS contract during implementation.** If it seems wrong, file an RFC (see `architecture/README.md`).
- **Never produce File → Entity containment in composition passes.** DAS-004 CONT-3 assigns below-file containment exclusively to source parsers (T0, deterministic).

---

## Development Workflow

### Build and Run
```bash
xcodegen generate                    # After project.yml changes or new files added
open Decode.xcodeproj                # Scheme: Decode → My Mac → Cmd+R
```

**Command-line build:**
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Decode.xcodeproj -scheme Decode -configuration Debug build
```

**Config**: Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete`, macOS 15.0, Xcode 16.2, sandbox disabled.
**Dependencies**: GRDB 7.5.0, SwiftSyntax 600.0.1, SwiftTreeSitter + 9 language grammars.
**First launch**: Requires Accessibility, Input Monitoring, Screen Recording permissions + restart.

### Git
Main branch: `main`. Build must pass before committing. Run `xcodegen generate` after adding/removing Swift files.

### Tests
40+ test files in `DecodeTests/`. Key coverage: `WorkspaceManager`, `WorkspaceResolver`, `WorkspaceResolverMultiFile`, `IndexingCoordinator`, `DirectoryWatcherService`, `NavigationState`, `ProjectExplorerTree`, `SessionState`, `SessionViewModelDirectory`, `SessionResolver`, `ExplanationTagParser`, `ExplainReasoningEngine`, `ImproveReasoningEngine`, `FollowUpReasoningEngine`, `SelectionModeCoordinator`, `SwiftSyntaxFrontend`, `TreeSitterFrontend`, `ModuleBoundaryPass`, `CrossFileResolutionPass`, `ModuleEmergentProperties`, `ModuleContextStrategy`, `ModuleObservation`, `ModuleIntelligenceValidation`, `VirtualSessionManager`, `AnchoredFollowUpTests`.

4 pre-existing test failures (see Known Limitations).

---

## Session Handoff (2026-08-05)

### What Was Completed

**Billing Engine Architecture** (design, not yet implemented):
- Complete 9-part architecture delivered in conversation. Atomic metering model: each LLM call is independently billed. One formula: `credits = max(1, ceil((input_tokens × input_rate + output_tokens × output_rate) / 1M))`. 1 credit = $0.001.
- 14 atomic LLM operations traced from all `generateCompletion`, `streamChat`, `generateVisionCompletion` call sites.
- Weekly billing periods (Monday reset). Three tiers: Free (750 credits), Medium (1500), Higher (2500).
- Server-authoritative, client-decorative (percentage bar only). Metering point: inside existing `_log_request()`.
- Implementation requires: add `credits` column to `request_logs`, add `tier` to `users`, add `compute_credits()` function. No new tables needed at alpha scale.
- Architecture survives 50+ future features, new models (one line in PricingTable), new tiers (two lines).
- Key finding: client already receives token usage in SSE `done` events (`SSEUsage` struct in `DecodeGatewayProvider.swift:474`) but explicitly discards it. Server logs all token data to `request_logs`.

**Token Economics Analysis** (analysis, not implementation):
- Complete measurement of all prompt sizes, token counts, and costs across all three modes.
- Production model: claude-haiku-4-5-20251001 ($0.80/$4.00 per Mtok input/output).
- Session Mode 2-5x cheaper than Selection/Screenshot (structured facts vs raw code).
- Output tokens dominate cost (66-84%) despite being minority of token volume.

**Credit System Design** (design, not implementation):
- Invisible credit system. Users see percentage bar only.
- Post-hoc metering of actual token consumption. No predictions.
- Three tiers optimized for adoption (first 4-5 months), not profit.

**Dashboard V2** (prior session, uncommitted):
- 8-page operational intelligence dashboard. Analytics V2 API with 10 endpoints.
- Files: `backend/app/routers/analytics_v2.py`, `backend/app/static/v2/{index.html,app.js,components.js,design.css}`.
- Status: Feature-complete. Changes are uncommitted in working tree.

**Previous sessions (2026-08-02 / 2026-08-03):**
- Enhanced Explanation (Visual Context pipeline, Intent Bar, Conditional Vision, ExplanationExecutionContext).
- Backend vision gateway with provider-agnostic dispatch.
- Screenshot Mode Investigation researched and closed.

### Current Implementation Status

| Component | Status | Location |
|-----------|--------|----------|
| Anchored Follow-Up / Reply ↩ | Complete (uncommitted) | `SelectableTextView.swift`, `ExplanationHUDViewModel.swift`, `FloatingExplanationHUD.swift`, `AILimits.swift` |
| Anchored Follow-Up Tests | Complete (uncommitted), 27 tests | `DecodeTests/Presentation/AnchoredFollowUpTests.swift` |
| Anchored Follow-Up Architecture Doc | Complete (uncommitted) | `architecture/ANCHORED_FOLLOW_UP_REPLY_ARCHITECTURE.md` |
| Billing Engine Architecture | Designed (not implemented) | Conversation output |
| Token Economics Analysis | Complete (reference) | Conversation output |
| Dashboard V2 (8 pages) | Complete (uncommitted) | `backend/app/static/v2/` |
| Analytics V2 API | Complete (uncommitted) | `backend/app/routers/analytics_v2.py` |
| Intent Bar (onEditingStarted) | Complete | `ExplanationHUDViewModel.swift`, `FloatingExplanationHUD.swift` |
| Conditional Vision (SelectionMode) | Complete | `Decode/Application/SelectionModeCoordinator.swift` |
| ExplanationExecutionContext | Complete | `Decode/Domain/Models/ExplanationExecutionContext.swift` |
| Visual Context Architecture | Complete | `architecture/VISUAL_CONTEXT_ARCHITECTURE.md` |

### Repository State

- Branch: `main`.
- All code builds successfully. 4 pre-existing test failures unchanged. CodeSign issue prevents `xcodebuild test` from CLI (pre-existing, unrelated to feature work).
- Uncommitted changes: CLAUDE.md, project.pbxproj, ExplanationHUDViewModel.swift, FloatingExplanationHUD.swift, AILimits.swift (Anchored Follow-Up + prior sessions). New files: SelectableTextView.swift, AnchoredFollowUpTests.swift, ANCHORED_FOLLOW_UP_REPLY_ARCHITECTURE.md.

### Immediate Next Recommended Tasks

1. **Commit all uncommitted work**: Anchored Follow-Up feature, Dashboard V2, CLAUDE.md updates.
2. **Implement Billing Engine Phase 1**: Add `credits` column to `request_logs`, implement `compute_credits()` in `_log_request()`, add `tier` to users table. See billing architecture in conversation for full spec.
3. **Dashboard V2 Validation**: Browser testing, UX polish, edge case handling.
4. **Project Intelligence M12 — Validation**: End-to-end validation of the complete Project Intelligence stack (M8–M11). See `PROJECT_INTELLIGENCE_IMPLEMENTATION_STATUS.md`.
