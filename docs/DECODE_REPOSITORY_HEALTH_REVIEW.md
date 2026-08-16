# Decode Repository Health Review

**Date**: 2026-08-16
**Reviewer**: Independent Architecture Audit (Claude Opus 4.6)
**Scope**: Full repository — macOS client (Swift 6), backend (Python/FastAPI), understanding pipeline, tests
**Method**: Static analysis, code reading, call-path tracing. No modifications made.

---

## Table of Contents

1. [Repository Overview](#1-repository-overview)
2. [Category Scores](#2-category-scores)
3. [Architecture Audit](#3-architecture-audit)
4. [Intelligence / Context Audit](#4-intelligence--context-audit)
5. [Session Audit](#5-session-audit)
6. [AI / Model Audit](#6-ai--model-audit)
7. [Vision / Multimodal Audit](#7-vision--multimodal-audit)
8. [Repository / Codebase Understanding Audit](#8-repository--codebase-understanding-audit)
9. [UX / UI Audit](#9-ux--ui-audit)
10. [Performance Audit](#10-performance-audit)
11. [Token / API Efficiency](#11-token--api-efficiency)
12. [Reliability / Concurrency](#12-reliability--concurrency)
13. [Security / Privacy](#13-security--privacy)
14. [Testing Audit](#14-testing-audit)
15. [Forgotten / Hidden Features](#15-forgotten--hidden-features)
16. [Self-Critique](#16-self-critique)
17. [Top Findings](#17-top-findings)
18. [Roadmap](#18-roadmap)
19. [9+/10 Roadmap](#19-910-roadmap)
20. [Final Scorecard](#20-final-scorecard)
21. [Final Architectural Verdict](#21-final-architectural-verdict)

---

## 1. Repository Overview

### Codebase Metrics

| Metric | Value |
|--------|-------|
| Swift source files | 232 |
| Swift source LOC | ~50,000 |
| Test files (Swift) | ~65 |
| Test LOC (Swift) | ~36,000 |
| Backend Python LOC | ~6,200 |
| Backend test files | 1 |
| Understanding pipeline modules | 8 |
| Alembic migrations | 14 |
| Architecture spec docs | ~30 (DAS, DDS, IAG, VAS, feature) |

### Actual Directory Structure (Verified)

```
Decode/App/            -> DecodeApp, AppDependencies (943 LOC), ContentView, UnderstandingSystem, Frontends, Passes
Decode/Application/    -> 29 files: Coordinators, Managers, Services, KnowledgeGeneration/
Decode/Domain/         -> Models (28), Protocols (9), Services (3 -- all stubs)
Decode/Infrastructure/ -> AI/ (11), AST/ (4), Capture/ (5), Database/ (9), FileSystem/ (4), Hotkey/ (1), Keychain/ (1), OCR/ (1)
Decode/Presentation/   -> Overlay/ (9), Session/ (5), Settings/ (4), Profile/ (2), Notes/ (2), Chat/ (2 -- dead), Onboarding/ (2), Toast/ (1)
Decode/Understanding/  -> DIRCore/, ProducerRuntime/, IndexRuntime/, RetrievalRuntime/, ContextAssembly/, ConsumerRuntime/, UpdateEngine/, StorageEngine/
backend/app/           -> main.py, gateway_service.py, auth.py, config.py, pricing.py, dual_write_service.py, aggregation_service.py
backend/app/routers/   -> gateway.py, admin.py, analytics_v2.py, auth.py
backend/app/models/    -> user.py, request_log.py, ai_request.py, analytics_event.py, event.py, daily_summary.py
backend/app/static/    -> admin.html, v2/{index.html, app.js, components.js, design.css}
```

### Major Request Flows (Verified)

**Selection Mode** (Double-tap Control):
```
HotkeyService -> SelectionModeCoordinator -> AccessibilityCapture (selected text)
  -> [if custom question: ScreenCaptureService -> VisualContextExtractor -> backend /vision]
  -> FloatingExplanationHUD.collectIntent() -> ExplanationFramework (prompt build)
  -> DecodeGatewayProvider.streamChat() -> backend /chat/stream -> Anthropic API
  -> SSE parsing -> HUD streaming display
  -> [VirtualSessionManager.recordInsight()] -> [ProfileIntelligenceService.recordObservation()]
  -> [FeedbackManager.recordExplanation()] -> [HistoryManager.recordExplanation()]
```

**Session Mode** (Double-tap Shift):
```
HotkeyService -> SessionQuestionCoordinator -> WorkspaceResolver (resolve workspace)
  -> [SemanticEnrichmentService.enrich()] -> PipelineQueryService
  -> UnderstandingSystem (processChanges -> retrieve -> assemble -> invoke)
  -> ExplainReasoningEngine -> DecodeGatewayProvider.streamChat()
  -> HUD streaming display
  -> [VirtualSessionManager.recordInsight() -- context NOT injected (bug)]
```

**Screenshot Mode** (Double-tap Option):
```
HotkeyService -> ScreenshotModeCoordinator -> ScreenSelectionOverlay (drag region)
  -> ScreenCaptureService -> VisionOCRService (OCR) -> ExplanationFramework (prompt)
  -> DecodeGatewayProvider.streamChat() -> HUD
  -> [Vision pipeline: dead code -- `let visualContext: VisualContext? = nil`]
```

---

## 2. Category Scores

### 1. Overall Architecture -- 7/10
- **Confidence**: High
- **Strongest**: Clean layered architecture (Presentation -> Application -> Domain -> Infrastructure) with strict downward dependency. Manual DI via `AppDependencies` is well-executed.
- **Biggest weakness**: Excessive specification vs implementation ratio. ~30 frozen architecture documents for a 50K LOC alpha app creates rigidity. Three Domain/Services stubs (`ChatService`, `RefactoringService`, `SessionService`) are empty shells from a phase plan never reached.
- **Evidence**: `Decode/Domain/Services/ChatService.swift` -- 13 lines, empty class, "Implemented in Phase 5." `Decode/Domain/Services/RefactoringService.swift` -- 16 lines, "Implemented in Phase 7."
- **What prevents 9-10**: Dead code paths (Chat, Settings direct-key flow, Screenshot vision), over-specification making evolution rigid, and hidden bugs in cross-cutting concerns (Virtual Session not wired in Session Mode).

### 2. Intelligence / Context Architecture -- 7/10
- **Confidence**: High
- **Strongest**: The DIR concept (Decode Intermediate Representation) with tiered understanding layers is genuinely differentiated. Deterministic-first philosophy (AST -> structured facts -> LLM enrichment) is architecturally sound.
- **Biggest weakness**: Knowledge Generation Runtime (KGR) is fully wired in `AppDependencies` but **silently disabled** -- `KnowledgePolicy.live()` reads `knowledgeGenerationEnabled` from UserDefaults which defaults to `false`, and no UI toggle exists. This means proactive File Understanding never runs in production.
- **Evidence**: `Decode/Application/KnowledgeGeneration/KnowledgePolicy.swift:101` reads `UserDefaults.standard.bool(forKey: enabledKey)`. `ContentView.swift` has toggles for `dsaModeEnabled` and `virtualSessionEnabled` but NOT `knowledgeGenerationEnabled`.
- **What prevents 9-10**: KGR disabled, Virtual Session context not injected in Session Mode, no cross-project context isolation verification, Groq routing contradicts docs.

### 3. Session System -- 6/10
- **Confidence**: High
- **Strongest**: SessionState architecture cleanly separates workspace history (database) from application state (JSON file). Incremental persistence on every mutation is crash-resilient.
- **Biggest weakness**: No session expiry, no session search, no session reuse intelligence. Sessions are workspace-bound; the "session" concept is really just "which workspaces are open." No conversation history beyond the current explanation + 10-item History.
- **Evidence**: `SessionState` in `AppDependencies` tracks only `openWorkspaceIDs`, `activeWorkspaceID`, `pinnedWorkspaceID`. No session identity, no session timestamps, no session resume logic beyond reopening the same workspace.
- **What prevents 9-10**: True session management (identity, search, resume, expiry) does not exist. What's called "Session Mode" is really "Workspace Question Mode."

### 4. Virtual Session / Investigation -- 6/10
- **Confidence**: High
- **Strongest**: Well-designed investigation boundary detection using affinity scoring (file overlap, entity overlap, module+layer). Working memory compression via LLM with deterministic fallback.
- **Biggest weakness**: Working memory is **not injected into Session Mode** explanations. `SessionQuestionCoordinator` sets `executionContext.virtualSession = true` but never calls `virtualSessionManager.workingMemoryBlock()`. Only Selection and Screenshot modes actually use the working memory in prompts.
- **Evidence**: `SelectionModeCoordinator.swift:336-343` calls `workingMemoryBlock()` and appends to system prompt. `SessionQuestionCoordinator.swift:277-279` only sets a boolean flag. No `workingMemoryBlock()` call anywhere in SessionQuestionCoordinator.
- **What prevents 9-10**: Silent Session Mode omission, no cross-project session isolation, in-memory cache only (resets on restart), synchronous file I/O on every mutation.

### 5. AI / Model Architecture -- 6/10
- **Confidence**: High
- **Strongest**: Provider abstraction is clean. `DecodeGatewayProvider` handles SSE parsing, retry, and rate limiting well. Shared `httpx.AsyncClient` on backend with connection pooling (40 connections, 20 keepalive).
- **Biggest weakness**: Multiple dead/contradictory AI paths. `AnthropicProvider` and `OpenAICompatibleProvider` exist but are unreachable in production. `KnowledgeCapabilityResolver.uniform(executor: gatewayExecutor)` routes everything through the gateway, contradicting the documented "File Understanding -> Groq direct" architecture.
- **Evidence**: `AppDependencies.swift` creates `GroqProvider` and registers it, but `KnowledgeCapabilityResolver.uniform()` ignores the Groq executor. `SettingsViewModel` is fully implemented for direct-key flow but never instantiated.
- **What prevents 9-10**: Dead provider paths, Groq routing broken, `validateConnection()` sends a real "hi" message consuming quota, no model fallback/retry on the client, vision 429 not handled.

### 6. Vision / Multimodal System -- 5/10
- **Confidence**: High
- **Strongest**: Selection Mode conditional vision is well-designed -- screenshot captured immediately (cheap), vision deferred until user types a custom question, parallel execution.
- **Biggest weakness**: Screenshot Mode vision is dead code. `ScreenshotModeCoordinator.swift:150` declares `let visualContext: VisualContext? = nil`, making the entire vision pipeline permanently unreachable in Screenshot Mode. The coordinator still accepts `visualContextExtractor` in its init -- misleading.
- **Evidence**: `ScreenshotModeCoordinator.swift:150` -- `let visualContext: VisualContext? = nil`. Lines 182-186 compute `formattedVC` from this nil value. Line 194 sets `executionContext.vision = true` -- but no vision actually ran.
- **What prevents 9-10**: Dead code in Screenshot Mode, no image size validation on backend `/vision` endpoint, hardcoded `.aqua` appearance breaks dark mode, `visionTimeoutSeconds = 20` has open TODO.

### 7. Repository / Codebase Understanding -- 5/10
- **Confidence**: Medium
- **Strongest**: Dual-frontend approach (SwiftSyntax for Swift, TreeSitter for 9 other languages) is architecturally sound. Entity/relationship extraction with typed edges (`.calls`, `.conformsTo`, `.inherits`, `.owns`) is genuinely useful.
- **Biggest weakness**: Understanding is per-file only. Cross-file resolution exists (`CrossFileResolutionPass`) but operates within a single module boundary. No true cross-module dependency resolution, no whole-project type resolution.
- **Evidence**: `CrossFileResolutionPass.swift` exists in `Decode/App/`. `ModuleBoundaryPass.swift` and `SystemCompositionPass.swift` exist for Project Intelligence Phase 2, but M12 (Validation) is not started.
- **What prevents 9-10**: Per-file understanding only, no type resolution across modules, KGR disabled (no proactive enrichment), `processProducerUpgrades()` is a no-op stub, cold restart causes full reparse (empty content hashes in snapshots).

**"How well does Decode actually understand a real-world repository?"** -- 5/10. For individual files with straightforward structures, understanding is solid. For complex cross-file dependencies, inheritance chains, or architectural patterns, understanding is limited to what can be determined from a single file's AST.

**"What happens with a 100k+ file repository?"** -- Untested. The `IndexingCoordinator` batches at 20 files/batch, which would take 5,000 batches. `DirectoryWatcherService` monitors root FD via FSEvents, which should scale. The real bottleneck is in-memory storage: all `parsedEntitiesByFile` are held in RAM on `ManagedWorkspace`. At 100k files, memory usage could be substantial.

### 8. Knowledge Graph / Dependency Understanding -- 4/10
- **Confidence**: Medium
- **Strongest**: The `GraphIndex` in `IndexRuntime` supports relationship traversal. `ModuleBoundaryPass` detects module boundaries from file paths. Five index families (Entity, Graph, Predicate, Content, Scope) are implemented.
- **Biggest weakness**: The graph is implicit (in-memory index entries), not a persistent queryable structure. No cross-module dependency graph. Module Intelligence (M1-M7) and Project Intelligence (M8-M11) are marked complete but M12 (Validation) has not run -- no evidence these produce useful results in production.
- **Evidence**: `SystemCompositionPass.swift`, `SystemEmergentPropertiesPass.swift` exist. No validation test or production evidence that they produce meaningful output.
- **What prevents 9-10**: No persistent graph, no query interface beyond pipeline retrieval, no visual dependency map, no cross-project graph, KGR disabled.

### 9. UX / UI Architecture -- 6/10
- **Confidence**: Medium (code-only review, no runtime testing)
- **Strongest**: Non-activating panels (`NSPanel` with `.nonactivatingPanel`) correctly preserve user's IDE focus. Intent Bar keyboard-first design (immediate typing without click) is excellent UX.
- **Biggest weakness**: Hard-coded `.aqua` appearance on all HUD panels means **no dark mode support**. `SessionView` shows "Coming Soon" placeholders for Module Intelligence and Project Intelligence despite both being documented as complete.
- **Evidence**: `FloatingExplanationHUD.swift` -- `panel.appearance = NSAppearance(named: .aqua)`. `SessionView.swift:476-478` -- `futurePlaceholderSection` still displayed for completed features.
- **What prevents 9-10**: No dark mode, stale "Coming Soon" UI, 1725-line `SessionView.swift` monolith, `ChatView` and `ChatViewModel` are empty stubs, no keyboard navigation for the Launcher.

### 10. Workspace Architecture -- 7/10
- **Confidence**: High
- **Strongest**: Clean model separation (Workspace in DB vs ManagedWorkspace runtime wrapper). Security-scoped bookmarks for file access. Multi-file workspace resolution with containment scoring.
- **Biggest weakness**: All parsed entities held in memory. No lazy loading or pagination for large workspaces. `expandedHeight()` computed once on dock expansion -- stale if workspaces change while open.
- **What prevents 9-10**: In-memory only, no workspace search, no workspace sharing, `NavigationState` not persisted.

### 11. Launcher Architecture -- 7/10
- **Confidence**: High
- **Strongest**: Orbital geometry is visually distinctive. Non-activating panel behavior is correct. Two-phase animation (main + buttons) is smooth.
- **Biggest weakness**: Pure mouse-driven -- no keyboard shortcut to expand/access the Launcher. Collapse delay (0.45s) after mouse exit may feel unresponsive.
- **What prevents 9-10**: No keyboard access, no customization, single-monitor positioning only.

### 12. Performance -- 5/10
- **Confidence**: Medium (no runtime profiling)
- **Strongest**: Deferred startup prevents activation timeout. Shared httpx client with connection pooling on backend.
- **Biggest weakness**: Synchronous file I/O on `@MainActor` for VirtualSession save, History save, and SessionState save -- called on every mutation. `SessionView.buildHierarchy()` is O(n^2) for entity processing.
- **Evidence**: `VirtualSessionManager.save()` called on every `recordInsight()`, uses `Data.write()` synchronously on MainActor. `HistoryManager` same pattern.
- **What prevents 9-10**: MainActor file I/O, no lazy loading for large workspaces, cold restart full reparse, `buildHierarchy()` O(n^2), no caching of index results between queries.

### 13. Token / API Efficiency -- 6/10
- **Confidence**: Medium
- **Strongest**: Structured facts approach (entity signatures/relationships instead of raw source) achieves 90-95% token reduction per CLAUDE.md. Single LLM call for all four semantic enrichment layers.
- **Biggest weakness**: `validateConnection()` sends a real "hi" message to the AI provider, consuming tokens and quota. Working memory is injected unconditionally (1000 chars) even when irrelevant. Follow-up system prompt is separate from explanation system prompt, requiring full re-send.
- **What prevents 9-10**: No prompt caching on the client, `validateConnection()` wastes tokens, no adaptive context selection based on token budget awareness, vision has no image size cap.

### 14. Reliability / Error Handling -- 6/10
- **Confidence**: Medium
- **Strongest**: Generation-counter pattern in coordinators eliminates request races without mutexes. `restoreAsync()` race guards prevent stale-load overwrites. Backend wraps all provider errors in typed `GatewayError`.
- **Biggest weakness**: Backend analytics writes use fire-and-forget thread pool (`dual_write_service.py:200`). If the pool is full or process killed, analytics are silently lost. No dead-letter queue.
- **Evidence**: `dual_write_service.py:200` -- `_db_executor.submit(...)`. Also: `DecodeGatewayProvider` vision path doesn't handle HTTP 429 (rate limited), only 200/401/403/502.
- **What prevents 9-10**: Fire-and-forget analytics, missing 429 handling in vision, synchronous MainActor I/O, no server-side request cancellation, no health monitoring or alerting.

### 15. Concurrency / Thread Safety -- 7/10
- **Confidence**: High
- **Strongest**: Swift 6 strict concurrency with `SWIFT_STRICT_CONCURRENCY = complete`. All `@unchecked Sendable` usages have documented justifications. Coordinators uniformly `@MainActor` with `Task {}` spawning.
- **Biggest weakness**: `DIRAccessForwarder` uses NSLock for construction-time circular dependency breaking -- safe but unconventional. `DemandSignal` deduplication map grows unboundedly without purge.
- **What prevents 9-10**: `NSLock` workaround in `DIRAccessForwarder`, demand dedup map growth, synchronous file I/O on MainActor.

### 16. Testing Quality -- 5/10
- **Confidence**: High
- **Strongest**: Understanding pipeline has dedicated test targets per module (8 test files in `UnderstandingTests/`). 65 test files total across the project.
- **Biggest weakness**: **Backend has only 1 test file** (`test_history_analytics.py`) with ~14 model-shape tests. Zero integration tests for auth, gateway, streaming, admin, or analytics endpoints. 12 pre-existing Swift test failures acknowledged but unfixed. No UI tests (empty `DecodeUITests`).
- **Evidence**: `backend/tests/test_history_analytics.py` -- only backend test. `DecodeUITests/DecodeUITests.swift` -- exists but minimal. 12 known failures in CLAUDE.md.
- **What prevents 9-10**: Near-zero backend test coverage, 12 broken Swift tests, no E2E tests, no UI tests, no performance tests, no large-repo stress tests.

### 17. Security / Privacy -- 4/10
- **Confidence**: High
- **Strongest**: Token stored as SHA-256 hash server-side, raw in Keychain client-side -- correct pattern. `.env` not tracked in git. API keys not hardcoded in application code.
- **Biggest weakness**: **CRITICAL: `backend/load_test.py` is tracked by git and contains a hardcoded production access token** (`3caa9b...`) and production Railway URL. Admin dashboards (`/admin`, `/admin/v2`) serve HTML without authentication -- only the API calls behind them require `ADMIN_TOKEN`. No server-side rate limiting. No input size validation on `/vision` image data or `/profile` profile data.
- **Evidence**: `backend/load_test.py:20` -- hardcoded token in git-tracked file. `backend/app/main.py:76-85` -- admin HTML served without auth check.
- **What prevents 9-10**: Committed production token (critical), unauthenticated admin UI serving, no rate limiting, no image size cap, no CORS configuration, no CSP headers.

### 18. Observability / Logging -- 4/10
- **Confidence**: High
- **Strongest**: `os.Logger` used correctly in several services with proper subsystem/category. Backend uses Python `logging` module.
- **Biggest weakness**: ~20 ungated `print()` statements in Release builds across `WorkspaceManager`, `KnowledgeArtifactStore`, `KnowledgePlanner`, `SessionQuestionCoordinator`, `ProfileIntelligenceService`. No structured logging on the backend. No metrics, no tracing, no alerting.
- **Evidence**: `WorkspaceManager.swift` lines 490, 553, 622, 648, 728, 790 -- all ungated `print()`. `SessionQuestionCoordinator.swift:437` -- ungated `print()`.
- **What prevents 9-10**: Ungated prints in production, no structured logging, no metrics/tracing, no error alerting, no request tracing correlation.

### 19. Maintainability -- 6/10
- **Confidence**: High
- **Strongest**: Clear module boundaries, protocol-based DI, frozen specifications prevent scope creep.
- **Biggest weakness**: Excessive documentation overhead (~30 frozen specs for a 50K LOC app). Multiple dead code paths that haven't been cleaned up. CLAUDE.md is 63K characters -- larger than many modules.
- **What prevents 9-10**: Dead code (Chat stubs, SettingsViewModel, Screenshot vision, Domain Services stubs), over-specification creating maintenance burden, 63K CLAUDE.md that diverges from reality.

### 20. Production Readiness -- 4/10
- **Confidence**: High
- **Strongest**: Auth flow, gateway architecture, and core explanation pipeline work end-to-end.
- **Biggest weakness**: Committed production token, no rate limiting, KGR silently disabled, Virtual Session broken in Session Mode, 12 broken tests, near-zero backend test coverage, no dark mode, no monitoring.
- **What prevents 9-10**: Security issues, missing test coverage, silent feature breakage, no observability, no error recovery for analytics.

### 21. Scalability -- 4/10
- **Confidence**: Medium
- **Strongest**: Backend connection pooling. Understanding pipeline designed for incremental updates.
- **Biggest weakness**: All workspace data in memory. Single-process backend with fire-and-forget thread pool for analytics. No connection pooling config on PostgreSQL. Client-side quota (trivially bypassed). No CDN for static assets.
- **What prevents 9-10**: In-memory everything on client, single-process backend, no horizontal scaling, no queue for async work, no caching layer.

### 22. Product / Technical Differentiation -- 7/10
- **Confidence**: High
- **Strongest**: The "Deterministic first, then semantic" philosophy is genuinely novel. Structured facts approach (AST -> entity signatures -> LLM) is a real differentiator vs sending raw source code. Five-layer File Intelligence model is a unique asset.
- **Biggest weakness**: Many differentiating features are silently broken or disabled (KGR disabled, Virtual Session missing from Session Mode, Module/Project Intelligence shown as "Coming Soon" in UI). The differentiation exists in code but isn't reaching users.
- **What prevents 9-10**: Differentiators not reaching users, no competitive moat analysis, no user feedback loop, limited language support for AST-level understanding.

---

## 3. Architecture Audit

### Duplicate Pipelines -- VERIFIED

Two explanation pipelines coexist:
1. **Pipeline path** (Session Mode): `PipelineQueryService` -> `UnderstandingSystem` -> `RetrievalRuntime` -> `ContextAssembly` -> `ConsumerRuntime` -> `ExplainReasoningEngine`
2. **Legacy/direct path** (Selection/Screenshot): `ExplanationFramework` -> direct `DecodeGatewayProvider.streamChat()`

This is documented and intentional ("pipeline-first with legacy fallback"). However, Session Mode also has a legacy fallback path in `SessionQuestionCoordinator` that duplicates much of the Selection Mode logic. The two code paths share no common extraction logic.

### Duplicate State -- VERIFIED

- `Workspace` (GRDB database) vs `SessionState` (JSON file) -- documented and intentional separation.
- `VirtualSession` (JSON file) vs `HistoryManager` (JSON file) vs `NoteService` (Markdown files + GRDB index) -- three separate persistence mechanisms for user-generated data. No unified lifecycle management.
- `ExplanationExecutionContext` tracks which subsystems contributed, but `ExplanationHUDViewModel.FollowUpContext` also tracks mode/profile separately. Minor overlap.

### Disconnected Instances -- VERIFIED

- **KGR fully wired but disabled**: `AppDependencies` creates `KnowledgeArtifactStore`, `KnowledgePlanner`, `KnowledgeGenerationRuntime`, registers the Groq provider -- but `KnowledgePolicy` defaults to `isEnabled: false` and no UI toggle exists.
- **`KnowledgeCapabilityResolver.uniform()`** creates a resolver that routes everything to the gateway executor. The Groq provider, despite being created and registered, is never dispatched to. The "capability-based routing" documented in CLAUDE.md does not function.
- **`SettingsViewModel`** implements a complete direct-API-key provider selection flow that is never instantiated in the production app.

### AI Request Path -- VERIFIED

```
Client: Coordinator -> ExplanationFramework (prompt build) -> DecodeGatewayProvider.streamChat()
         |
Network: URLSession -> backend /api/gateway/chat/stream (Bearer auth)
         |
Backend: gateway.py -> dual_write_service.log_ai_request() (thread pool)
         |
         gateway_service.stream_llm() -> _get_adapter() -> anthropic adapter
         |
         httpx.AsyncClient -> Anthropic Messages API (SSE)
         |
         StreamingResponse -> SSE events back to client
         |
Client: DecodeGatewayProvider SSE parser -> AsyncThrowingStream -> HUD
```

This path is clean and functional. The single concern is that `dual_write_service` logging runs in a fire-and-forget thread pool -- analytics loss on process kill.

### Hidden Dependencies -- VERIFIED

- `VirtualSessionManager.aiProvider` is a closure `(@MainActor () -> (any AIProviderProtocol)?)` set after init in `AppDependencies`. This is a hidden dependency not visible in the init signature.
- `WorkspaceManager.processChanges`, `onKnowledgeGenerationNeeded`, `loadExistingEnrichment` -- all `var` closures set post-init. Nil checks are inconsistent (some warn, some silently skip).
- `FeedbackManager` is created inline in `AppDependencies` (`let feedbackManager = FeedbackManager()`) with no protocol abstraction -- cannot be mocked in tests.

---

## 4. Intelligence / Context Audit

### Context Trustworthiness -- 6/10

**Deterministic context is trustworthy**: Entity extraction via SwiftSyntax/TreeSitter produces correct, verifiable facts. Relationship extraction (`.calls`, `.conformsTo`, `.inherits`, `.owns`) is grounded in AST evidence.

**Semantic context is unverified**: Semantic enrichment (Purpose, Behavior, Safety, Design layers) is LLM-derived and cached by file hash. No validation that enrichment output is correct. No quality metrics.

**Working memory is unreliable across modes**: Injected in Selection/Screenshot but not Session Mode. When injected, it's unconditional -- 1000 chars of investigation context regardless of relevance to the current question.

### Context Duplication -- VERIFIED

- `ExplanationFramework.buildV7Prompt()` includes: selected code, surrounding context, file metadata, visual context, working memory, user question. Each is assembled by the coordinator and passed as separate parameters. No deduplication if the same information appears in multiple parameters (e.g., file name in visual context AND in file metadata).
- Session Mode pipeline path: `ContextAssembly` builds context frames from `RetrievalRuntime` evidence. The legacy fallback duplicates much of this logic with different assembly.

### Cross-Project Context Leakage -- INFERRED RISK

Virtual Session does NOT track which workspace produced each insight. `VirtualSession.investigations` contain `Investigation` objects with `knownFiles` and `knownEntities`, but no workspace ID. If a user opens Project A, generates insights, then opens Project B, the working memory from Project A will be injected into Project B explanations. Topic switching (semantic keyword overlap) provides partial protection, but file/entity names from unrelated projects could persist.

**Evidence**: `VirtualSession.swift` -- `Investigation` has `knownFiles: Set<String>` and `knownEntities: Set<String>` but no workspace reference. `VirtualSessionManager.retrieveRelevantInsights()` scores by keyword overlap with no workspace filtering.

### Vision Integration -- VERIFIED (Partially Broken)

- **Selection Mode**: Correctly integrated. Screenshot captured immediately, vision deferred until user types custom question, result awaited or available at submit time.
- **Screenshot Mode**: Dead code. `let visualContext: VisualContext? = nil` permanently disables vision despite the coordinator accepting the extractor. The `executionContext.vision = true` flag is set incorrectly -- it claims vision contributed when it didn't.

---

## 5. Session Audit

### What "Session" Actually Means in Decode

Decode uses "Session Mode" to mean "ask a question about an open workspace file." There is no persistent session identity, no conversation threading beyond the current interaction + 10-item History, no session resume, no session search.

The actual session-like capabilities are:
- `SessionState` (JSON): tracks open/active/pinned workspaces across restarts
- `VirtualSession` (JSON): tracks investigation memory across interactions
- `HistoryManager` (JSON): stores last 10 explanations with follow-ups

These are **three separate, uncoordinated persistence mechanisms** with different lifecycles, different storage locations, and different cleanup triggers.

### Cross-Mode Continuity Test (Conceptual)

```
1. Open Project A workspace
2. Ask Session Mode question -> investigation starts, working memory populated
3. Open Project B workspace
4. Ask Session Mode question about Project B
5. Return to Project A
```

**Expected**: Project A context intact, Project B context separate.
**Actual (inferred)**:
- Step 2: Virtual Session records insight (if enabled), but working memory NOT injected in Session Mode (bug).
- Step 4: Previous working memory from Project A may be injected into Project B's Selection/Screenshot explanations (no workspace filtering on Virtual Session). Session Mode is unaffected since it doesn't use working memory.
- Step 5: `SessionState` correctly restores active workspace. Virtual Session may have mixed context from both projects.

### Concurrent Updates -- VERIFIED SAFE

All managers (`WorkspaceManager`, `VirtualSessionManager`, `HistoryManager`, `SessionStatePersistence`) are `@MainActor` isolated. Concurrent mutations are serialized by the MainActor. The risk is that synchronous file I/O on MainActor blocks the UI during saves.

---

## 6. AI / Model Audit

### Provider Abstraction -- VERIFIED

`AIProviderProtocol` defines `streamChat()`, `chat()`, `supportsStreaming`. Three conformers:
1. `DecodeGatewayProvider` -- production path via backend gateway (active)
2. `AnthropicProvider` -- direct Anthropic API (dead in production)
3. `OpenAICompatibleProvider` -- OpenAI-compatible APIs (dead in production)

### Duplicate AI Pipelines -- VERIFIED

- **Gateway path**: DecodeGatewayProvider -> backend `/chat/stream` -> `stream_llm()` -> Anthropic adapter
- **Direct Groq path**: `GroqProvider` wraps `OpenAICompatibleProvider` -> never actually dispatched to due to `KnowledgeCapabilityResolver.uniform()`
- **Direct Anthropic path**: `AnthropicProvider` -> unreachable in production
- **Vision path**: `VisualContextExtractor` -> `DecodeGatewayProvider` (via `visionGatewayProvider`) -> backend `/vision` -> `call_vision_llm()` -> Anthropic vision

### Backend Provider Routing -- VERIFIED

`gateway_service.py` supports three adapter families (`openai_compat`, `anthropic`, `gemini`). Only `anthropic` is used in production. `stream_llm()` falls back to `call_llm()` for non-Anthropic adapters -- a complete second HTTP call with no caller notification.

### Token Efficiency -- MODERATE CONCERN

- Structured facts approach saves 90-95% tokens vs raw source (good)
- But: `validateConnection()` sends a real chat message consuming tokens
- Working memory (1000 chars) injected unconditionally
- Follow-up conversations send the full system prompt each time (no caching)
- Vision images have no size cap -- a 10MB screenshot could cost significant tokens

---

## 7. Vision / Multimodal Audit

### Selection Mode Vision -- VERIFIED WORKING

```
SelectionModeCoordinator:
1. ScreenCaptureService.captureActiveWindow() -> CGImage (~180ms)
2. User types in Intent Bar -> onEditingStarted fires
3. pendingVisionTask = Task { VisualContextExtractor.extract(image) }
4. VisualContextExtractor: crop edges -> JPEG -> backend /vision -> parse response
5. Backend: call_vision_llm() -> Anthropic vision API -> VisualContext response
6. If user submits before vision completes: await pendingVisionTask
7. VisualContext injected into prompt via ExplanationFramework
```

**Issues**:
- No image size validation (client or server)
- `_VISION_MAX_TOKENS = 256` on backend caps response but not input cost
- Edge cropping (10% per edge) reduces tokens but is a fixed ratio -- doesn't adapt to content

### Screenshot Mode Vision -- DEAD CODE

`ScreenshotModeCoordinator.swift:150`:
```swift
let visualContext: VisualContext? = nil
```

The coordinator still:
1. Accepts `visualContextExtractor` in `init` (line 37)
2. Computes `formattedVC` from nil visual context (always nil)
3. Sets `executionContext.vision = true` when `formattedVC != nil` (never true)

This was the correct decision (Screenshot Mode investigation concluded insufficient value), but the dead code should be cleaned up.

---

## 8. Repository / Codebase Understanding Audit

### Parser Coverage -- VERIFIED

| Language | Parser | Status |
|----------|--------|--------|
| Swift | SwiftSyntax 600.0.1 | Full entity/relationship/import extraction |
| Python | tree-sitter-python | Entity extraction |
| JavaScript | tree-sitter-javascript | Entity extraction |
| TypeScript | tree-sitter-typescript | Entity extraction |
| HTML | tree-sitter-html | Entity extraction |
| CSS | tree-sitter-css | Entity extraction |
| Java | tree-sitter-java | Entity extraction |
| C# | tree-sitter-c-sharp | Entity extraction |
| C | tree-sitter-c | Entity extraction |
| C++ | tree-sitter-cpp | Entity extraction |
| SQL | Excluded | Upstream SPM package issue |

### Indexing Architecture -- VERIFIED

`IndexingCoordinator`:
- Scans manifest of supported file extensions
- Excludes `.git`, `node_modules`, `build`, etc.
- Batches 20 files/batch through the understanding pipeline
- Populates `parsedEntitiesByFile` on `ManagedWorkspace`
- All data in memory -- no persistent index

`DirectoryWatcherService`:
- FSEvents on root directory FD
- 500ms debounce
- Mod-date snapshot comparison
- Triggers `onChangesDetected` -> `IndexingCoordinator.processChanges()`

### Large Repository Behavior -- UNVERIFIED

For a 100k+ file repository:
- **Scanning**: `IndexingCoordinator` would scan the manifest and create 5,000+ batches of 20 files
- **Memory**: All `parsedEntitiesByFile` held in RAM. Estimated 500 bytes/entity x ~10 entities/file x 100k files = ~500MB
- **FSEvents**: Should handle large directories, but `modDateSnapshot` comparison compares every file mod date on each event
- **Indexing time**: Entirely dependent on file parsing speed. No progress indication beyond the dock progress bar

**Rating: 5/10** -- Works for small-to-medium repos, no evidence of large-repo testing or optimization.

---

## 9. UX / UI Audit

### Real UX Problems (Category A)

1. **No dark mode**: All HUD panels hard-code `.aqua` appearance. Users with dark IDEs see a jarring white overlay.
2. **"Coming Soon" for completed features**: SessionView shows Module Intelligence and Project Intelligence as placeholders despite being complete.
3. **History requires selection for follow-up**: Users cannot ask free-form questions about historical explanations -- they must select text and click "Reply" first.
4. **`SettingsView` hardcodes "Claude Sonnet 4"**: Model name doesn't reflect actual configuration.
5. **`SessionView` monolith**: 1,725 lines in one file with duplicated `iconForType` helper.

### Missing Product Exposure (Category B)

1. **Notes feature** fully implemented but not mentioned in onboarding or documentation
2. **Profile Intelligence** fully implemented but hidden behind `#if DEBUG` inspector
3. **Feedback Manager** (thumbs up/down after every 5th explanation) active but undocumented
4. **KGR** fully implemented but disabled -- no UI toggle

### Visual Polish (Category C)

1. Launcher peek amount (22px) may be hard to discover
2. Session dock Y-position only -- no horizontal positioning
3. Toast manager is single-panel (new toast replaces old)

### Window/Focus Behavior -- VERIFIED CORRECT

All floating panels use `NSPanel` with `.nonactivatingPanel`. The Launcher correctly sets `canBecomeMain -> false`. Focus never leaves the user's IDE. This is well-implemented.

---

## 10. Performance Audit

### Startup -- VERIFIED GOOD

- `AppDependencies.init()` performs only lightweight construction (~zero I/O)
- `performDeferredStartup()` fires on `didBecomeActiveNotification`
- `hasPerformedDeferredStartup` guard prevents duplicate calls
- Understanding pipeline startup is async (`understandingStartupTask`)

### Main Thread Blocking -- VERIFIED CONCERN

Synchronous file I/O on `@MainActor`:
- `VirtualSessionManager.save()` -- every `recordInsight()`, `addToWorkingMemory()`, `compressWorkingMemory()` call
- `HistoryManager.save()` -- every explanation/follow-up recording
- `SessionStatePersistence.saveSessionState()` -- every workspace open/close/activate/pin

At current scale (small JSON files, few users), this is imperceptible. At scale with large virtual sessions or many concurrent saves, this will cause UI stutter.

### First Likely Bottlenecks

1. **Memory**: `parsedEntitiesByFile` for large directory workspaces (all in RAM)
2. **Indexing**: 20-file batches with sequential pipeline processing for large repos
3. **Main thread**: Synchronous JSON writes on every mutation
4. **Backend**: Single-process with fire-and-forget thread pool -- no horizontal scaling
5. **Cold restart**: Full reparse of all workspace files (content hashes not persisted in snapshots)

---

## 11. Token / API Efficiency

### Unnecessary API Calls -- VERIFIED

1. **`validateConnection()`**: Sends `"hi"` message to the AI provider, consuming tokens and quota. Should use `/health` endpoint instead.
2. **Semantic enrichment**: Runs before quota check -- enrichment doesn't consume user quota but DOES consume backend API tokens.
3. **Working memory injection**: Unconditional 1000-char injection even when investigation context is irrelevant to the question.

### Unnecessary Tokens -- VERIFIED

1. **Full system prompt on every follow-up**: No prompt caching between explanation and follow-up requests.
2. **Visual context description** sent even when the vision content duplicates information already in the selected text.
3. **Profile context** (`profileContext: String?`) injected into all follow-ups -- may duplicate information already in the explanation.

### Duplicate Context -- INFERRED

1. Selected code appears in both the user message and potentially in the visual context description (if the screenshot shows the same code).
2. File name appears in multiple prompt sections (metadata, visual context, enrichment context).

### Expensive Operations That Could Be Deterministic

1. **Working memory compression**: Uses LLM to compress working memory. A simple truncation + keyword extraction could achieve 80% of the value deterministically.
2. **Semantic enrichment**: The Purpose layer can be derived deterministically (as `FilePurposeDeriver` demonstrates). Behavior and Safety layers genuinely benefit from LLM.

---

## 12. Reliability / Concurrency

### Race Conditions -- NONE FOUND

The `@MainActor` isolation pattern effectively prevents races. The generation-counter pattern in coordinators provides additional request-ordering safety.

### Shared Mutable State -- LOW RISK

- `EnhancedExplanationDebug.shared` -- global mutable singleton, but only written/read in `#if DEBUG` blocks
- `UserDefaults` keys -- shared state but atomic reads/writes

### Persistence Races -- LOW RISK (by design)

All persistence is on `@MainActor`, serialized. The risk is performance, not correctness.

### Likely Production-Only Failures

1. **Backend thread pool exhaustion**: `_db_executor` (default size) under high concurrent load -> analytics writes silently dropped
2. **Large virtual session JSON**: If investigations accumulate many insights, `save()` writes increasingly large files synchronously on MainActor
3. **FSEvents flood**: Rapid file system changes (git operations, build outputs) -> 500ms debounce may not be sufficient -> many redundant reindexing batches
4. **Memory pressure**: Large directory workspaces with thousands of parsed entities -> no eviction or pagination
5. **Network timeout stacking**: If Anthropic API is slow, multiple pending requests can stack up (120s timeout each)

---

## 13. Security / Privacy

### CRITICAL: Committed Production Token

**File**: `backend/load_test.py:20`
**Content**: `TOKEN = "3caa9b..."` (full token in file)
**Status**: Git-tracked (`git ls-files` confirms)
**Risk**: Anyone with repo access can use this token to make authenticated API calls as a real user

**Immediate action required**: Revoke the token and remove from git history.

### Admin Dashboard Authentication Gap

`backend/app/main.py:76-85` mounts admin HTML at `/admin` and `/admin/v2` without any authentication middleware. The pages are publicly accessible. Only the XHR API calls behind them require `ADMIN_TOKEN`.

While the dashboard UI alone doesn't expose data (data comes from auth-protected API calls), the HTML/JS reveals:
- All API endpoint URLs and their parameters
- Dashboard feature set and capabilities
- Token analytics methodology

### No Server-Side Rate Limiting

No `slowapi`, no custom middleware, no per-user throttling on any endpoint. The client-side 100-request/5-hour limit (`AIUsageTracker`) is trivially bypassed by direct API calls.

### No Input Size Validation

- `VisionRequest.image_data`: No `max_length` -- arbitrary-size base64 payloads accepted
- `ProfileSyncRequest.profile_data`: No schema validation, no size cap -- arbitrary JSONB stored directly

### Screenshot Privacy

Screenshots captured via `ScreenCaptureService` are held as `CGImage` in memory, converted to JPEG, sent to the backend, then discarded. No disk persistence. The backend receives the base64 image, forwards to Anthropic, and discards. This is acceptable, but the backend logs the first 100 chars of the base64 payload at INFO level (`VISION_DIAG` logger).

---

## 14. Testing Audit

### Swift Test Coverage

| Category | Files | Approx Tests | Quality |
|----------|-------|-------------|---------|
| Application (Coordinators) | 3 | ~15 | 4 known failures, mock-heavy |
| Application (Managers) | 8 | ~50 | Good unit coverage for workspace/history |
| Application (Pipeline passes) | 7 | ~40 | Good algorithmic coverage |
| Application (Reasoning engines) | 3 | ~22 | Prompt construction testing |
| Application (KGR) | 2 | ~8 | Basic lifecycle |
| Domain | 4 | ~15 | Model/enum tests |
| Infrastructure | 7 | ~45 | Parser tests solid, network mocked |
| Presentation | 6 | ~80 | AnchoredFollowUp (27), TagParser, HUD |
| Understanding pipeline | 8 + 3 support | ~60 | Per-module unit + integration |
| **Total** | **~51** | **~335+** | **Mixed** |

### What's Actually Tested vs Mocked

**Real testing** (no mocks):
- SwiftSyntax/TreeSitter parsers -- parse real source code
- Understanding pipeline modules -- operate on real in-memory data
- Domain models -- pure value types
- Tag parser, question classifier -- pure functions

**Mock-heavy** (mocks dominate):
- Coordinators -- mock AI provider, mock capture, mock HUD
- AINetworkClient -- MockURLProtocol
- WorkspaceManager -- mock database, mock watcher

**Not tested at all**:
- Backend API endpoints (zero integration tests)
- End-to-end flows
- UI interactions
- Large file/repo handling
- Concurrent request handling
- Error recovery paths
- Vision pipeline
- Analytics pipeline

### Known Broken Tests

12 pre-existing failures acknowledged in CLAUDE.md. These represent genuine regressions from feature changes (Intent Bar, entity format changes) that were documented but not fixed. This is a concerning pattern -- features ship with known test breakage.

---

## 15. Forgotten / Hidden Features

### WHAT DO WE HAVE THAT WE FORGOT WE BUILT?

| # | Feature | What It Does | File(s) | Trigger | Status | Product Value /10 | Impl Effort /10 |
|---|---------|-------------|---------|---------|--------|-------------------|-----------------|
| 1 | **Notes System** | Save explanations as Markdown files with GRDB index, full CRUD UI with search and time grouping | `NoteService.swift`, `NotesView.swift`, `NoteDetailView.swift`, `Note.swift` | Sidebar "Notes" tab + "Note" button in HUD | Fully implemented | 7 | 9 (done) |
| 2 | **Profile Intelligence** | Records user behavior observations, derives learning profile, caches profile, syncs to backend | `ProfileIntelligenceService.swift`, `ProfileView.swift`, `ProfileViewModel.swift`, `ProfileObservation.swift`, `UserProfile.swift` | Sidebar "Profile" tab (user-facing), `#if DEBUG` inspector | Implemented but hidden | 8 | 8 (mostly done) |
| 3 | **Feedback Manager** | Thumbs up/down feedback shown every 5th explanation and after every optimization, submitted as analytics event | `FeedbackManager.swift` | Automatic -- appears in HUD after explanations | Fully implemented | 6 | 10 (done) |
| 4 | **Knowledge Generation Runtime** | Proactive file understanding -- plans, schedules, and executes background AI enrichment jobs | `KnowledgeGeneration/` (7 files), `KnowledgeArtifactStore.swift` | UserDefaults `knowledgeGenerationEnabled` (defaults FALSE, no UI toggle) | Implemented but silently disabled | 9 | 7 (wiring done, toggle missing) |
| 5 | **DSA Mode** | Separate explanation profile for algorithms and interview prep | `ExplanationFramework+DSA.swift` | ContentView toggle "DSA Mode" | Fully implemented | 5 | 10 (done) |
| 6 | **Backend URL Override** | Developer tool to point client at staging/local backend | `DecodeConfig` in auth/config code | UserDefaults `decodeBackendBaseURL` | Implemented but undocumented | 3 | 10 (done) |
| 7 | **Direct API Key Providers** | Complete Anthropic + OpenAI-compatible provider implementations for direct API access without gateway | `AnthropicProvider.swift`, `OpenAICompatibleProvider.swift`, `SettingsViewModel.swift`, `AIProviderConfiguration.swift` | Dead -- `SettingsViewModel` never instantiated | Dead/obsolete | 4 | 10 (done but unused) |
| 8 | **Profile Sync to Backend** | Syncs derived user profile to backend `/profile` endpoint | `ProfileSyncService.swift`, backend `POST /profile` | Automatic after profile derivation | Implemented but backend stores raw JSONB with no validation | 5 | 7 |
| 9 | **Chat View/ViewModel** | Chat interface stubs (Phase 5) | `ChatView.swift`, `ChatViewModel.swift` | None -- entirely commented out | Dead/obsolete | 0 | 1 (stub only) |
| 10 | **EnhancedExplanationDebug** | Debug singleton tracking last visual context, extraction timing | `EnhancedExplanationDebug.swift` | `#if DEBUG` blocks in coordinators | Experimental/debug | 1 | 10 (done, should be removed) |

### HIDDEN PRODUCT POTENTIAL

1. **Knowledge Generation Runtime -> Enable with UI toggle** (HIGHEST VALUE)
   - The entire KGR is wired, tested, and ready. Adding a single toggle to ContentView (matching the existing DSA Mode and Virtual Session toggles) would enable proactive file understanding. This is the single highest-value change with the lowest effort.
   - Files: `ContentView.swift` (add toggle), `KnowledgePolicy.swift` (already reads the key)
   - Effort: ~10 lines of code

2. **Notes -> Promote to first-class feature**
   - The Notes system is production-quality with search, time grouping, and Markdown rendering. It's accessible from the sidebar but not mentioned in onboarding, not accessible via hotkey, and not integrated with the Launcher.
   - Adding a Launcher button or keyboard shortcut would expose this to users.
   - Effort: Low (add callback to Launcher or bind hotkey)

3. **Profile Intelligence -> Remove DEBUG gate on inspector**
   - The Profile page is already accessible in the sidebar. The inspector popover is gated by `#if DEBUG`. Removing the gate would let users see their derived learning profile, building trust and engagement.
   - Effort: Remove 2 lines (`#if DEBUG` / `#endif`)

4. **Direct API Key Providers -> Offer as "Offline Mode"**
   - The Anthropic and OpenAI-compatible providers are fully functional. If the gateway is down or for power users who want their own keys, exposing these would add resilience.
   - Effort: Medium (re-enable `SettingsViewModel`, add UI toggle between gateway/direct modes)

5. **Feedback Analytics -> Display in Admin Dashboard**
   - Feedback events are submitted to the analytics pipeline but the admin dashboard doesn't surface them. Adding a "User Satisfaction" panel to Dashboard V2 would provide product signal.
   - Effort: Medium (add analytics query + chart component)

---

## 16. Self-Critique

### Where Did I Overestimate Decode?

- **Architecture score (7/10)**: The layered architecture is clean on paper, but the number of dead code paths and disconnected systems (KGR, SettingsViewModel, Screenshot vision) suggests the architecture is aspirational rather than fully realized. A 6 might be more honest.
- **Understanding pipeline**: I gave credit for 8 implemented modules, but the pipeline is only exercised in Session Mode. Selection and Screenshot modes bypass it entirely with the legacy path. The pipeline's value is limited to ~1/3 of user interactions.

### Which Feature Looks Impressive in Documentation but Is Weak in Code?

- **"Multi-Provider AI Platform"**: Documented as a sophisticated capability-based routing system. In reality, `KnowledgeCapabilityResolver.uniform()` routes everything to the gateway, Groq is never dispatched to, and two of three providers are dead code.
- **"Virtual Session"**: Documented as "complete and production-ready." In reality, working memory is not injected in Session Mode (the primary workspace-aware mode), and there's no cross-project isolation.
- **"Project Intelligence (M8-M11 complete)"**: Documented as complete, but M12 (Validation) hasn't started, the UI still shows "Coming Soon," and there's no evidence the system composition passes produce useful output.

### Which Subsystem Is Unnecessarily Complicated?

- **Understanding pipeline (8 modules)** for what currently amounts to "build some context and call an LLM." The 8-module pipeline with 30+ frozen specifications is immense infrastructure for a product that, today, primarily does: capture text -> build prompt -> call AI -> show result. The pipeline is designed for a scale of intelligence that hasn't yet been validated.

### Which Subsystem Is Under-Engineered?

- **Backend**: 6,200 LOC, 1 test file (14 tests), no rate limiting, no input validation, fire-and-forget analytics. For a production service handling AI API calls and user data, this is critically under-tested and under-hardened.
- **Security**: Committed production token, unauthenticated admin HTML, no rate limiting. These are basics.

### Where Is Technical Debt Accumulating?

1. **12 broken tests** acknowledged but not fixed across multiple releases
2. **Dead code**: ChatView stubs, SettingsViewModel, Screenshot vision dead path, Domain Services stubs, EnhancedExplanationDebug singleton
3. **Ungated print statements**: ~20 across production code
4. **CLAUDE.md at 63K chars**: Growing unsustainably, diverging from reality (documents KGR as functional when it's disabled, documents Groq routing when it doesn't work)

### What Breaks First at 10x Scale?

1. Backend: single-process, no horizontal scaling, fire-and-forget analytics
2. Client: in-memory workspace data for large repos
3. Client: synchronous MainActor file I/O
4. Backend: no rate limiting -> abuse potential

### What Breaks First with a 100k-File Repository?

1. Memory: `parsedEntitiesByFile` in RAM (~500MB estimated)
2. Indexing time: 5,000 batches of 20 files, sequential processing
3. FSEvents: mod-date snapshot comparison for 100k files on every change
4. Cold restart: full reparse (no persistent content hashes)

### What Could Unexpectedly Increase Token/API Cost?

1. `validateConnection()` sends "hi" -- every connection validation consumes tokens
2. Semantic enrichment runs before quota check -- backend API cost even if user is at limit
3. Working memory injected unconditionally -- 1000 extra chars per request
4. Vision images with no size cap -- one large screenshot could cost as much as 10 regular requests
5. KGR if enabled would trigger background AI calls for every file in a workspace

### What Would Make a Senior Engineer Reject This Architecture?

1. 30+ frozen specifications for a 50K LOC alpha app -- over-engineering
2. Multiple dead provider implementations in production code
3. Committed production credentials in version control
4. 12 known broken tests shipped across multiple releases
5. KGR fully wired but silently disabled with no error or warning

### What Have We Built That We Probably Should NOT Have Built?

1. **8-module understanding pipeline** at this stage -- the infrastructure cost is disproportionate to validated user value
2. **30+ frozen architecture specifications** -- created analysis paralysis and maintenance burden
3. **Dashboard V2 (8 pages)** -- founder-grade analytics for 5-50 users generates noise, not signal
4. **Direct API key providers** (Anthropic, OpenAI-compatible) -- these are dead code since moving to gateway

### What Important Capability Is Missing?

1. **Conversation history/threading** -- users can't continue investigations across sessions
2. **Error recovery/retry** -- if the AI call fails, the user gets a toast and must retry manually
3. **Offline mode** -- no capability without network (despite having direct providers implemented)
4. **Team/collaboration** -- no way to share explanations, notes, or investigations
5. **User onboarding for hidden features** -- Notes, Profile, Feedback are invisible to new users

---

## 17. Top Findings

### TOP 10 STRENGTHS

1. **Deterministic-first philosophy** -- AST extraction before LLM enrichment is genuinely novel and correct
2. **Non-activating panel architecture** -- HUDs never steal focus from the user's IDE, a critical UX detail
3. **Structured facts approach** -- 90-95% token reduction by sending entity signatures instead of raw source
4. **Five-layer File Intelligence model** -- Identity, Purpose, Behavior, Safety, Design is a unique asset
5. **Intent Bar keyboard-first design** -- immediate typing without click is excellent UX
6. **Generation-counter concurrency pattern** -- eliminates request races without mutexes
7. **Deferred startup architecture** -- prevents macOS activation timeout, correctly prioritized
8. **Dual-frontend AST parsing** -- SwiftSyntax + TreeSitter covers 10 languages
9. **Clean manual DI** -- `AppDependencies` as root container with protocol-typed properties
10. **Anchored Follow-Up three-state selection model** -- correctly separates visual selection from reply intent

### TOP 10 WEAKNESSES

1. **Committed production token** in `load_test.py` -- critical security vulnerability
2. **KGR silently disabled** -- major feature fully wired but defaults to off with no UI toggle
3. **Virtual Session not wired in Session Mode** -- `workingMemoryBlock()` never called
4. **Near-zero backend test coverage** -- 1 test file, 14 model-shape tests, zero integration tests
5. **12 broken tests acknowledged but unfixed** -- shipped across multiple releases
6. **No dark mode** -- hard-coded `.aqua` appearance on all panels
7. **Dead code accumulation** -- ChatView stubs, SettingsViewModel, Screenshot vision, Domain Services stubs
8. **No server-side rate limiting** -- client-side quota trivially bypassed
9. **Over-specification** -- 30+ frozen specs for 50K LOC alpha creates rigidity
10. **CLAUDE.md diverges from reality** -- documents KGR as functional, Groq routing as active

### TOP 10 TECHNICAL RISKS

1. Backend single-process architecture with fire-and-forget analytics -- data loss under load
2. In-memory workspace data with no eviction -- memory pressure on large repos
3. Synchronous file I/O on MainActor -- UI stutter risk with growing data
4. No persistent content hashes -- cold restart causes full reparse
5. Cross-project context leakage via Virtual Session (no workspace filtering)
6. Demand signal deduplication map grows unboundedly
7. `processProducerUpgrades()` is a no-op -- producer version bumps never trigger re-evaluation
8. No server-side request cancellation -- cancelled client requests still consume backend/AI resources
9. FSEvents flood during git operations or builds could overwhelm debounce
10. 120s backend timeout x concurrent users = connection exhaustion potential

### TOP 10 UX PROBLEMS

1. No dark mode support -- jarring white overlays on dark IDEs
2. "Coming Soon" placeholders for completed features (Module/Project Intelligence)
3. Hidden features: Notes, Profile Intelligence, Feedback not discoverable
4. History requires text selection + Reply button before asking follow-up questions
5. `SettingsView` hardcodes "Claude Sonnet 4" -- stale model name
6. Launcher has no keyboard shortcut -- mouse-only interaction
7. KGR disabled silently -- user sees no benefit from a major differentiating feature
8. Single toast panel -- rapid errors can suppress important messages
9. No progress indication for understanding pipeline processing
10. SessionView is 1,725-line monolith -- maintainability risk for iterating on UX

### TOP 10 PERFORMANCE RISKS

1. `parsedEntitiesByFile` all in RAM -- no lazy loading or pagination
2. Synchronous JSON writes on `@MainActor` on every mutation
3. `SessionView.buildHierarchy()` O(n^2) entity processing
4. Cold restart full reparse (content hashes not in snapshots)
5. 20-file sequential indexing batches -- no parallelism
6. `DirectoryWatcherService` mod-date comparison for all files on each event
7. No index result caching between pipeline queries
8. Backend single-process with synchronous admin routes
9. `OnboardingView` polls permissions with 3-second timer (wasteful)
10. `DemandSignal` dedup map grows without eviction

### TOP 10 TOKEN/API WASTE OPPORTUNITIES

1. `validateConnection()` sends real "hi" message -- use `/health` instead
2. Working memory (1000 chars) injected unconditionally -- filter by relevance
3. Full system prompt re-sent on every follow-up -- implement prompt caching
4. Vision images have no size cap -- add client-side resize before upload
5. Semantic enrichment runs before quota check -- defer or gate
6. Profile context injected into all follow-ups -- may duplicate explanation context
7. Visual context may describe code already in the selected text -- deduplicate
8. File name/metadata repeated across multiple prompt sections
9. Working memory LLM compression could be partially deterministic
10. KGR (if enabled) would trigger AI calls for every file -- needs cost controls

### TOP 10 MISSING CAPABILITIES

1. Conversation threading/history across sessions
2. Server-side rate limiting
3. Dark mode
4. Error retry with backoff in the UI
5. Offline/direct-key mode
6. Team collaboration (share explanations/notes)
7. Cross-module dependency graph visualization
8. Large repository optimizations (lazy loading, persistent index)
9. User onboarding for hidden features
10. Structured error reporting and monitoring

### TOP 10 FORGOTTEN / DISCOVERED FEATURES

1. **Knowledge Generation Runtime** -- fully wired, disabled by default, no toggle
2. **Notes System** -- complete with search, time grouping, Markdown export
3. **Profile Intelligence** -- records observations, derives learning profile
4. **Feedback Manager** -- thumbs up/down every 5th explanation
5. **Direct API Key Providers** -- Anthropic + OpenAI-compatible, unreachable in production
6. **Backend URL Override** -- developer tool for staging/local backends
7. **Profile Sync to Backend** -- sends derived profile to `/profile` endpoint
8. **DSA Mode** -- separate explanation profile for algorithms
9. **EnhancedExplanationDebug** -- debug singleton marked for removal
10. **Chat View stubs** -- Phase 5 placeholder, entirely dead

---

## 18. Roadmap

### QUICK WINS

| # | Problem | Solution | Files | Complexity | Risk | Impact |
|---|---------|----------|-------|-----------|------|--------|
| 1 | KGR silently disabled | Add `@AppStorage` toggle to ContentView (matching existing toggles) | `ContentView.swift` | Low | Low | Very High -- enables core differentiator |
| 2 | "Coming Soon" placeholders | Remove `futurePlaceholderSection` for completed features | `SessionView.swift` | Low | Low | Medium -- honest UI |
| 3 | No dark mode | Remove `panel.appearance = NSAppearance(named: .aqua)` | All panel files | Low | Low | High -- fixes jarring UX |
| 4 | Ungated print statements | Gate ~20 `print()` calls with `#if DEBUG` | 5 files | Low | Low | Low -- cleaner release builds |
| 5 | Dead code cleanup | Remove ChatView/ViewModel stubs, Domain Services stubs, EnhancedExplanationDebug | 6 files | Low | Low | Low -- cleaner codebase |

### P0 -- Foundation / Correctness / Security

| # | Problem | Solution | Files | Complexity | Risk | Impact |
|---|---------|----------|-------|-----------|------|--------|
| 1 | **Committed production token** | Revoke token, scrub from git history, move credentials to env vars | `backend/load_test.py` | Low | Medium | Critical -- security |
| 2 | **Virtual Session not wired in Session Mode** | Add `workingMemoryBlock()` call in `SessionQuestionCoordinator` matching Selection/Screenshot pattern | `SessionQuestionCoordinator.swift` | Low | Low | High -- feature correctness |
| 3 | **Server-side rate limiting** | Add `slowapi` or custom middleware on gateway endpoints | `backend/app/main.py` | Medium | Low | High -- abuse prevention |
| 4 | **Vision image size validation** | Add `max_length` on `VisionRequest.image_data` (e.g., 5MB base64) | `backend/app/routers/gateway.py` | Low | Low | Medium -- cost protection |
| 5 | **Admin HTML authentication** | Add auth middleware to admin HTML routes, not just API routes | `backend/app/main.py` | Low | Low | Medium -- security |

### P1 -- Important Engineering

| # | Problem | Solution | Complexity | Risk | Impact |
|---|---------|----------|-----------|------|--------|
| 1 | 12 broken tests | Fix or remove -- they represent regression debt | Medium | Low | High |
| 2 | Backend test coverage | Add integration tests for auth, gateway, admin, analytics | High | Low | High |
| 3 | `validateConnection()` waste | Replace with `/health` endpoint check | Low | Low | Medium |
| 4 | Groq routing doesn't work | Fix `KnowledgeCapabilityResolver` to use Groq executor when available | Medium | Medium | Medium |
| 5 | Dead provider code | Remove `SettingsViewModel`, `AIProviderConfiguration.swift` if gateway-only confirmed | Low | Low | Medium |
| 6 | CLAUDE.md accuracy | Update to reflect actual state (KGR disabled, Groq not routing, Session Mode VS gap) | Medium | Low | Medium |

### P2 -- Product / UX

| # | Problem | Solution | Complexity | Risk | Impact |
|---|---------|----------|-----------|------|--------|
| 1 | Notes not discoverable | Add hotkey or Launcher button for Notes | Low | Low | Medium |
| 2 | Profile Intelligence hidden | Remove `#if DEBUG` gate on inspector, add to onboarding | Low | Low | Medium |
| 3 | History follow-up requires selection | Allow free-form questions on historical explanations | Medium | Low | Medium |
| 4 | Stale model name in Settings | Read model name from AI configuration | Low | Low | Low |
| 5 | SessionView monolith | Extract `EntityDetailView`, shared helpers into separate files | Medium | Low | Medium |

### FUTURE

| # | Problem | Solution | Complexity | Risk | Impact |
|---|---------|----------|-----------|------|--------|
| 1 | Async MainActor file I/O | Move persistence to background queue with completion callbacks | High | Medium | Medium |
| 2 | Large repo support | Persistent index, lazy loading, pagination for entities | High | Medium | High |
| 3 | Cross-project session isolation | Add workspace ID to Virtual Session investigations | Medium | Low | Medium |
| 4 | Conversation threading | Persistent conversation history beyond 10-item History | High | Medium | High |
| 5 | Offline mode | Re-enable direct API key providers as fallback | Medium | Medium | Medium |
| 6 | Team features | Share explanations, notes, investigations | Very High | High | High |

### DO NOT BUILD

| # | Idea | Why Not |
|---|------|---------|
| 1 | More architecture specifications | 30+ frozen specs for 50K LOC is already disproportionate. Validate existing specs before creating new ones. |
| 2 | Additional AI providers (Gemini, etc.) | The gateway abstracts this. Adding client-side providers adds complexity without user value. |
| 3 | Time-windowed analytics | Not useful until daily volume exceeds ~50 (CLAUDE.md correctly defers this). |
| 4 | SSE streaming optimization | Current single-chunk approach works. Marginal improvement for significant complexity. |
| 5 | User-configurable hotkeys | Current hotkeys work. Complexity outweighs value at alpha scale. |
| 6 | More dashboard pages | 8 pages for 5-50 users is already over-built. |
| 7 | Billing Engine | Designed but not built. Premature until user base and pricing model are validated. |
| 8 | Mobile/web client | Desktop-first product -- spreading to other platforms would dilute focus. |
| 9 | Plugin marketplace | Years ahead of the current state. |
| 10 | Custom LLM fine-tuning pipeline | Use commercial models. Fine-tuning adds enormous complexity for marginal gains at this scale. |

---

## 19. 9+/10 Roadmap

### Category-by-Category Target

| Category | Current | Target | Required Changes |
|----------|---------|--------|-----------------|
| 1. Overall Architecture | 7 | 9 | Remove dead code paths, validate pipeline value, reduce spec overhead |
| 2. Intelligence / Context | 7 | 9 | Enable KGR, fix Virtual Session in Session Mode, add context quality metrics |
| 3. Session System | 6 | 9 | True session identity, conversation threading, search, resume |
| 4. Virtual Session | 6 | 9 | Fix Session Mode wiring, add workspace isolation, persistent memory |
| 5. AI / Model | 6 | 9 | Fix Groq routing, remove dead providers, add model fallback, prompt caching |
| 6. Vision | 5 | 9 | Clean up dead Screenshot code, add image size validation, dark mode |
| 7. Repository Understanding | 5 | 9 | Cross-module resolution, persistent index, large repo optimization |
| 8. Knowledge Graph | 4 | 9 | Persistent queryable graph, cross-module deps, visual explorer |
| 9. UX / UI | 6 | 9 | Dark mode, surface hidden features, fix stale UI, reduce monoliths |
| 10. Workspace | 7 | 9 | Lazy loading, persistent NavigationState, workspace search |
| 11. Launcher | 7 | 9 | Keyboard shortcut, customization |
| 12. Performance | 5 | 9 | Async I/O, lazy loading, persistent indexes, parallel indexing |
| 13. Token / API Efficiency | 6 | 9 | Prompt caching, adaptive context, image resize, remove waste |
| 14. Reliability | 6 | 9 | Queue-based analytics, retry with backoff, health monitoring |
| 15. Concurrency | 7 | 9 | Async file I/O, demand dedup eviction |
| 16. Testing | 5 | 9 | Backend integration tests, fix 12 broken tests, E2E tests, UI tests |
| 17. Security | 4 | 9 | Revoke token, rate limiting, input validation, auth on admin HTML, CSP headers |
| 18. Observability | 4 | 9 | Structured logging, metrics, alerting, request tracing |
| 19. Maintainability | 6 | 9 | Remove dead code, accurate documentation, reduce CLAUDE.md |
| 20. Production Readiness | 4 | 9 | All P0 + P1 items, monitoring, horizontal scaling, load testing |
| 21. Scalability | 4 | 9 | Horizontal backend, persistent indexes, memory management |
| 22. Differentiation | 7 | 9 | Enable KGR, surface differentiators to users, validate with users |

### FOUNDATIONAL CHANGES

1. **Security remediation**: Revoke committed token, scrub git history, add server-side rate limiting, authenticate admin routes
2. **Fix silent feature breakage**: Virtual Session in Session Mode, KGR toggle, Groq routing
3. **Backend hardening**: Integration tests, rate limiting, input validation, structured logging
4. **Remove dead code**: Unify to a single live code path per capability

### TOP 15 HIGHEST-IMPACT CHANGES

1. Enable KGR with UI toggle (10 lines of code -> major feature activation)
2. Fix Virtual Session in Session Mode (5 lines -> feature correctness)
3. Revoke committed production token (security critical)
4. Add server-side rate limiting (abuse prevention)
5. Add dark mode support (remove `.aqua` hard-coding)
6. Backend integration test suite (reliability foundation)
7. Fix 12 broken Swift tests (engineering hygiene)
8. Remove "Coming Soon" for completed features (honest UI)
9. Surface Notes/Profile/Feedback to users (hidden product value)
10. Fix Groq routing (cost optimization -- use cheaper model for background tasks)
11. Implement prompt caching (token cost reduction)
12. Add image size validation (cost protection)
13. Replace `validateConnection()` with health check (waste elimination)
14. Async file I/O on MainActor paths (performance)
15. Persistent content hashes in snapshots (cold restart performance)

### 10x SCALE REQUIREMENTS

1. Horizontal backend scaling (multiple processes/containers)
2. Queue-based analytics with durability guarantees
3. Connection pooling configuration for PostgreSQL
4. CDN for static dashboard assets
5. Server-side request cancellation
6. Memory management for client-side parsed entities
7. Rate limiting per user and globally
8. Health monitoring and alerting
9. Load testing with realistic patterns (not hardcoded tokens)
10. Structured logging with request correlation IDs

### 100K+ FILE REPOSITORY REQUIREMENTS

1. Persistent index (don't reparse on restart)
2. Lazy loading of parsed entities (don't hold all in RAM)
3. Pagination for entity lists in UI
4. Parallel indexing batches (not sequential)
5. Incremental FSEvents processing (don't compare all file mod dates)
6. Background indexing with progress cancellation
7. Index eviction for unused files
8. Tiered entity storage (hot/warm/cold)

### PRODUCT QUALITY IMPROVEMENTS

1. Dark mode across all panels
2. User onboarding for Notes, Profile, Feedback features
3. Conversation threading beyond 10-item History
4. Free-form follow-up on historical explanations
5. Keyboard shortcut for Launcher
6. Cross-module dependency visualization
7. Error retry with visual feedback
8. KGR-powered proactive insights

### DO NOT BUILD FOR 9/10

1. More frozen specifications -- validate existing ones first
2. Additional AI provider implementations on client -- use the gateway
3. Complex billing engine -- premature at current scale
4. Real-time collaboration -- single-user focus is correct now
5. Custom LLM training pipeline -- commercial models suffice

---

## 20. Final Scorecard

| Category | Score /10 | Confidence | Biggest Strength | Biggest Weakness |
|----------|--------:|------------|-----------------|-----------------|
| 1. Overall Architecture | 7 | High | Clean layered architecture with protocol-based DI | Dead code paths and over-specification |
| 2. Intelligence / Context | 7 | High | Deterministic-first philosophy with structured facts | KGR silently disabled |
| 3. Session System | 6 | High | Clean workspace history vs session state separation | No true session identity or threading |
| 4. Virtual Session | 6 | High | Investigation boundary detection | Not wired in Session Mode |
| 5. AI / Model | 6 | High | Gateway abstraction with connection pooling | Dead providers, Groq routing broken |
| 6. Vision / Multimodal | 5 | High | Selection Mode conditional vision design | Screenshot Mode vision is dead code |
| 7. Repository Understanding | 5 | Medium | Dual-frontend 10-language AST parsing | Per-file only, no cross-module resolution |
| 8. Knowledge Graph | 4 | Medium | Five index families implemented | No persistent queryable graph |
| 9. UX / UI | 6 | Medium | Non-activating panels preserve IDE focus | No dark mode, hidden features |
| 10. Workspace | 7 | High | Multi-file resolution with containment scoring | All entities in memory |
| 11. Launcher | 7 | High | Orbital geometry, correct focus behavior | No keyboard shortcut |
| 12. Performance | 5 | Medium | Deferred startup prevents timeout | Synchronous MainActor file I/O |
| 13. Token / API Efficiency | 6 | Medium | Structured facts 90-95% token reduction | Unconditional working memory, no prompt cache |
| 14. Reliability | 6 | Medium | Generation-counter pattern | Fire-and-forget analytics |
| 15. Concurrency | 7 | High | Swift 6 strict concurrency, documented @unchecked | MainActor synchronous I/O |
| 16. Testing | 5 | High | Understanding pipeline per-module tests | Near-zero backend tests, 12 broken Swift tests |
| 17. Security | 4 | High | Token hashing, Keychain storage | Committed production token |
| 18. Observability | 4 | High | os.Logger with subsystem/category | Ungated prints, no metrics/alerting |
| 19. Maintainability | 6 | High | Clear module boundaries | Dead code, 63K CLAUDE.md diverging from reality |
| 20. Production Readiness | 4 | High | Core explanation pipeline works E2E | Security issues, silent feature breakage |
| 21. Scalability | 4 | Medium | Connection pooling on backend | In-memory everything, single-process backend |
| 22. Differentiation | 7 | High | Unique intelligence architecture | Differentiators disabled or hidden |

### OVERALL SCORE: 5.5/10

**Weighting**: Security (P0), Production Readiness, and Testing are weighted higher because they gate whether the product can be shipped. A product with a committed production token, 12 broken tests, and near-zero backend test coverage cannot score above 6 regardless of architectural sophistication. Architecture and Differentiation are weighted moderately -- they represent the product's ceiling. Performance and Scalability are weighted lower because the current user base (5-50) doesn't expose these limits.

The raw average across categories is 5.6. Applying the security/reliability penalty brings this to **5.5/10**.

### WOULD I SHIP THIS?

**YES WITH FIXES**

The core product idea is sound and the explanation pipeline works. The security issue is critical but fixable. The hidden features represent untapped value. The architecture, while over-specified, provides a solid foundation.

### WHAT WOULD I FIX BEFORE BETA?

1. **Revoke committed production token** and scrub git history
2. **Add server-side rate limiting** on gateway endpoints
3. **Fix Virtual Session in Session Mode** (working memory injection)
4. **Enable KGR with UI toggle** (the single highest-value change)
5. **Fix or remove 12 broken tests** -- they represent unacknowledged regression

### WHAT WOULD I FIX BEFORE 10x SCALE?

1. **Horizontal backend scaling** -- move from single-process to multiple workers
2. **Queue-based analytics** -- replace fire-and-forget thread pool with durable queue
3. **Persistent content hashes** -- eliminate cold-restart full reparse
4. **Memory management for parsed entities** -- lazy loading, eviction
5. **Structured logging with request correlation** -- observability foundation

### WHAT SHOULD WE STOP BUILDING?

1. **More frozen architecture specifications** -- 30+ is enough; validate what exists
2. **Dashboard V2 enhancements** -- 8 pages for 5-50 users is sufficient
3. **Additional client-side AI providers** -- the gateway handles this
4. **Billing Engine implementation** -- premature before pricing validation
5. **New features before fixing broken ones** -- KGR disabled, VS not wired, 12 broken tests

### WHAT SHOULD WE BUILD NEXT?

1. **Enable KGR** (toggle + Groq routing fix) -- unlocks proactive intelligence
2. **Security hardening sprint** -- token revocation, rate limiting, input validation
3. **Backend test suite** -- integration tests for auth, gateway, admin
4. **Dark mode** -- remove `.aqua` hard-coding across all panels
5. **Feature discovery** -- surface Notes, Profile, Feedback to users

---

## 21. Final Architectural Verdict

1. **Current architectural maturity**: Early alpha. Strong foundation but significant gaps in security, testing, and feature integration. The architecture is more documented than validated.

2. **Overall score**: **5.5/10**

3. **Biggest architectural strength**: Deterministic-first intelligence philosophy -- AST extraction -> structured facts -> selective LLM enrichment. This is a genuine technical differentiator that no competitor has replicated in this form.

4. **Biggest architectural weakness**: Over-specification without validation. 30+ frozen architecture specifications, 8 pipeline modules, and 63K CLAUDE.md for a 50K LOC alpha app. The architecture was designed for a scale of intelligence that hasn't been validated with real users.

5. **Biggest UX strength**: Non-activating panel architecture -- HUDs never steal focus from the user's IDE. Combined with Intent Bar keyboard-first design, this demonstrates deep understanding of developer workflow.

6. **Biggest UX weakness**: No dark mode. Hard-coded `.aqua` appearance on all panels. For a developer tool used alongside dark-themed IDEs, this is a fundamental UX failure.

7. **Biggest scalability risk**: All workspace parsed entities held in memory with no eviction or pagination. A 100k-file repository would consume ~500MB of RAM for entity data alone.

8. **Biggest token/API risk**: Vision images have no size cap. A single large screenshot forwarded to the Anthropic vision API could cost 10x a normal request, with no client or server validation.

9. **Biggest reliability risk**: Backend analytics uses fire-and-forget thread pool (`dual_write_service.py`). Under load or process termination, analytics data is silently lost with no recovery mechanism.

10. **Biggest forgotten capability**: Knowledge Generation Runtime (KGR) -- a fully wired, tested background intelligence system that would enable proactive file understanding. Disabled because a UserDefaults key defaults to `false` and no UI toggle was ever added. Enabling it is ~10 lines of code.

11. **Biggest missing capability**: Conversation threading and persistent investigation memory. Users cannot continue an investigation across app restarts beyond the 10-item History. Virtual Session resets on restart. There is no way to say "continue what I was working on yesterday."

12. **Biggest product opportunity**: Enabling KGR + fixing Virtual Session in Session Mode + surfacing Notes/Profile/Feedback to users. These are all implemented features that aren't reaching users. The product is better than it appears because multiple differentiating capabilities are disabled, hidden, or broken.

13. **Recommended next 3 engineering priorities**:
    1. **Security sprint**: Revoke committed token, add rate limiting, authenticate admin HTML, add input validation
    2. **Feature activation**: Enable KGR toggle, fix Virtual Session in Session Mode, fix Groq routing, surface hidden features
    3. **Engineering hygiene**: Fix 12 broken tests, add backend integration tests, remove dead code, gate production print statements

---

*Evidence classification throughout this document:*
- **VERIFIED**: Confirmed by reading source code at specified file/line
- **INFERRED**: Logical conclusion from code structure, not directly observed in runtime
- **UNVERIFIED**: Cannot be confirmed without runtime testing or additional context
