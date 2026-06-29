# CLAUDE.md — Decode

## Project Mission

Decode is a **Software Intelligence Platform**. Its canonical asset is the **Decode Intermediate Representation (DIR)** — a structured, tiered, incrementally maintained representation of software from which all capabilities are derived.

Current capabilities (Explain, Improve, Follow-up) are **consumers** of the shared intelligence architecture. Future capabilities will also be consumers — the DIR is the platform, not the features.

Stage: Pre-beta alpha, invite-only, 5–50 users.

---

## Current Project State (June 2026)

Architecture phase is **complete**. Current phase: **Implementation** of the understanding pipeline.

The architecture is fully specified across three document layers (DAS → DDS → IAG). All specifications are frozen. Implementation follows IAG-004 phase ordering with verification gates between phases.

Phase 1 (File Intelligence) is complete and validated. All four semantic understanding layers are implemented end-to-end.

### What's Implemented

**Three modes, four hotkeys**, all with follow-up questions and post-explanation code improvement:

| Mode | Trigger | Flow |
|------|---------|------|
| Selection | Double-tap Control | Capture selected text → AI → HUD |
| Screenshot | Double-tap Option | Drag-select region → OCR → AI → HUD |
| Session | `⌃⇧O` open file, then Double-tap Shift | Capture snippet → resolve session → build context → AI → HUD |

**File Intelligence** — layered understanding of source files:
- **Deterministic Facts Engine**: entities, imports, relationships (calls, conformsTo, inherits, owns), structure outline — all extracted from AST in a single parse pass.
- **Identity layer**: file role, architectural layer, patterns (deterministic).
- **Purpose layer**: why the file exists (deterministic via `FilePurposeDeriver`, augmented by semantic enrichment).
- **Behavior layer**: control flow, state transitions, side effects (semantic enrichment).
- **Safety layer**: error handling, concurrency model, resource lifecycle (semantic enrichment).
- **Design layer**: architectural responsibility, patterns, trade-offs (semantic enrichment).
- **Semantic Enrichment Pipeline**: lazy, cached LLM-derived understanding (all four layers in a single call). Computed on first user question per file version. Cached by `fileHash`. Falls back to deterministic purpose on failure.
- **Question-aware Context Selection**: deterministic routing that selects which understanding layers to include in the explanation prompt based on snippet content and file role.

**Backend**: FastAPI + PostgreSQL on Railway. Full analytics pipeline, admin dashboard, invite management.

**Client**: Swift 6, macOS 15+, SwiftUI, Apple Development signed (Team `P5Y864DV5S`).
**Production AI**: `AI_ADAPTER=anthropic`, `AI_MODEL=claude-haiku-4-5-20251001`.
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
**Application**: `SelectionModeCoordinator`, `ScreenshotModeCoordinator`, `SessionQuestionCoordinator`, `SessionManager`, `SessionResolver`, `ContextBuilderService`, `ExplanationFramework`, `RepresentationGuidance`, `SnippetHealthClassifier`, `ImprovementService`, `SemanticEnrichmentService`, `FilePurposeDeriver`, `FileIdentityClassifier`.
**Domain**: Models (`Session`, `CodeEntity`, `SessionContext`, `AILimits`, `FileIntelligence`, `Relationship`, `SemanticEnrichment`, `ImportDeclaration`), Protocols (`AIProviderProtocol`, `DatabaseProtocol`).
**Infrastructure**: `DecodeGatewayProvider`, `AccessibilityCapture`, `HotkeyService`, `SwiftSyntaxParser`, `TreeSitterParser`, `DatabaseService`, `KeychainService`, `FileWatcherService`, `ScreenCaptureService`, `VisionOCRService`, `TextReplacementService`, `AnalyticsEventService`.
**Presentation**: `FloatingExplanationHUD`, `ExplanationHUDViewModel`, `ExplanationTagParser`, `ImprovementSectionView`, `FloatingSessionDock`, `SessionView`.

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
Decode/Understanding/  → Understanding pipeline modules (IAG-001 §5 — created during implementation)
backend/app/           → routers/, models/, static/, gateway_service.py, auth.py, config.py
backend/alembic/       → Database migrations
architecture/          → Frozen specifications: das/, dds/, iag/, rfc/, glossary/
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

## Session Mode Details

### Session Resolution (`SessionResolver`)
Pinned session → unconditional override. Single session → trivial. Multiple sessions → scored by entity containment, file content match, recency. Low confidence → fallback to `activeSessionId`.

### Context Tiers (`ContextBuilderService`)
Token reduction of ~63–97% vs sending the full file.

| Tier | Condition | What's sent |
|------|-----------|-------------|
| tier1 | Snippet matches a parsed entity | Entity source + outline |
| tier2 | File ≤200 lines | Full file content |
| tier2.5 | Large file, snippet found by text search | ±30 surrounding lines + outline |
| tier3 | Large file, no match | Outline only |

### Code Health (`SnippetHealthClassifier`)
Tree-sitter parses the snippet. Edge errors = partial-selection artifacts. Interior errors = real issues. Tiers: silent → observe → surface → diagnose, injected into system prompt.

### Session Dock
Non-activating `NSPanel` on right screen edge. Capsule pills with magnification. Pin session via context menu.

---

## Explanation Engine

- Two profiles: General (V7) and DSA. Toggled via `dsaModeEnabled` UserDefaults key.
- V7 is the active general prompt (`ExplanationFramework.swift`). Currently frozen.
- DSA prompt in `ExplanationFramework+DSA.swift`. Independently evolvable.
- 7 custom tags: `<hl>`, `<critical>`, `<tip>`, `<note>`, `<analogy>` (inline); `<tldr>`, `<flow>` (block).
- Renderer uses `.inlineOnlyPreservingWhitespace` — block-level headings (`##`) are NOT supported.
- Follow-ups: 3-message conversation with dedicated `followUpSystemPrompt`, NOT the explanation prompt.
- Do not redesign V7 without evidence from real-world usage.

---

## Improve Code Feature

Post-explanation code improvement. Available in Selection and Session modes (not Screenshot).

- `ImprovementService`: prompt construction, response parsing. Uses `<improvement_summary>` and `<improved_code>` XML-like tags.
- Session Improve reuses the `SessionContext` from the original explanation via `FollowUpContext.sessionContext`.
- No-improvement path: when code is already clean, model returns summary-only. This is a successful outcome.
- `TextReplacementService`: clipboard backup → write → simulated ⌘V → clipboard restore.

---

## Analytics

**Request analytics** (`request_logs`): `user_id`, `mode`, `success`, `latency_ms`, `error_type`, `ai_provider`, `ai_model`, `context_tier`, `explanation_profile`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_character_count`, `language`, `created_at`.

**Product analytics** (`analytics_events`): `user_id`, `event_type`, `mode`, `metadata` (JSONB), `created_at`. Events: `improve_copy`, `improve_replace`, `improve_dismiss`, `improve_no_change`.

**Compound modes**: `selection_followup`, `session_followup`, `screenshot_followup`, `selection_improve`, `session_improve`.

**Admin dashboard** at `GET /admin`: analytics, token stats, improve stats, follow-up stats, mode/tier/provider/profile tables, user management, invite generation.

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

The architecture is fully specified and frozen. Implementation conforms to these documents — they do not conform to implementation. Changing a frozen specification requires an RFC (see `architecture/iag/IAG-004-Implementation-Sequence.md` §21).

### Document Layers

```
DAS (frozen) — Architectural principles, invariants, the DIR definition
  ↓
DDS (frozen) — Runtime subsystem contracts, state models, failure modes
  ↓
IAG (frozen) — Module boundaries, technology decisions, runtime architecture, implementation sequence
  ↓
Implementation — Source code that realizes all of the above
```

### Specification Inventory

| Layer | Documents | Scope |
|-------|-----------|-------|
| DAS | DAS-000 through DAS-012 | Architecture: principles, DIR, tiers, entities, relationships, passes, indexes, retrieval, context assembly, incremental update, consumers, storage |
| DDS | DDS-000 through DDS-009 | Design: authoring standard, producer runtime, DIR runtime, pass runtime, index runtime, retrieval runtime, context assembly, update engine, storage engine, consumer runtime |
| IAG | IAG-001 through IAG-004 | Implementation: module architecture, technology decisions, runtime architecture, implementation sequence |

### Understanding Pipeline Modules (IAG-001)

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

### Implementation Phases (IAG-004)

| Phase | Name | Modules | Status |
|-------|------|---------|--------|
| 1 | Foundation | DIRCore, build system, test infrastructure | Not started |
| 2 | Leaf Modules | StorageEngine, ProducerRuntime, IndexRuntime (parallel) | Not started |
| 3 | Write Pipeline | UpdateEngine | Not started |
| 4 | Read Pipeline | RetrievalRuntime → ContextAssembly → ConsumerRuntime | Not started |
| 5 | System Integration | UnderstandingSystem composition root + integration tests | Not started |
| 6 | Application Integration | AppDependencies wiring, file monitoring bridge | Not started |

Phases are sequential with verification gates (G1–G6) between them. No phase begins until the previous gate passes. See IAG-004 for entry/exit criteria, parallel work opportunities, and rollback policy.

---

## Implementation Rules

### Implement, Do Not Redesign

The architecture is specified. Implementation realizes the specifications. Do not:
- Redesign module boundaries (IAG-001 is frozen)
- Change the dependency graph between modules
- Add or remove modules
- Change actor placement (IAG-003 is frozen)
- Change technology selections (IAG-002 is frozen)
- Skip verification gates or phase ordering (IAG-004 is frozen)

### Before Implementing

1. Read the relevant DDS contract for the subsystem being implemented.
2. Read the relevant IAG sections for module structure, technology, and runtime behavior.
3. Inspect the affected code and identify impacted files — do not assume.
4. Implement incrementally in production-quality code. No scaffolding, no stubs, no "we'll fix it later."

### Quality Priorities

Reliability, maintainability, correctness, incremental computation, and observability take precedence over clever implementations.

### When the Spec Seems Wrong

If implementation reveals a genuine contradiction with DAS/DDS/IAG — not inconvenience, but an actual invariant violation, contract contradiction, or impossibility — **stop and explain why an RFC is required**. Do not silently deviate from the specification. Do not work around it. Document the finding and the evidence.

The RFC must include: which document and section, what it currently says, what's proposed, why it's incorrect (with evidence), and downstream impact. See IAG-004 §21.3.

### Verification

Each phase has objective exit criteria (IAG-004 §3–§8). Verification is binary: builds succeed or fail, tests pass or fail, strict concurrency reports or doesn't. No subjective assessment.

---

## Roadmap

1. ~~**File Intelligence**~~ — **Complete.** All four semantic understanding layers implemented, validated, and shipped.
2. ~~**Architecture**~~ — **Complete.** DAS-000–012, DDS-000–009, IAG-001–004 all frozen.
3. **Understanding Pipeline Implementation** — **Active.** IAG-004 Phase 1 (Foundation) is next.
4. **Project Intelligence** — understand the whole codebase as architecture. Future phase.

---

## Known Limitations

1. **Test coverage thin** — 13 test files exist but key services lack coverage. Priority: `ContextBuilderService`, `SessionResolver`, `SnippetHealthClassifier`, `ExplanationTagParser`.
2. **Swift conformance ambiguity** — SwiftSyntax lacks type resolution. All inheritance clause items on classes are recorded as `.conformsTo` (cannot distinguish superclass from protocol without type checking).
3. **Sandbox disabled** — re-enabling requires security-scoped bookmarks.
4. **No server-side request cancellation** — client cancels URLSession task but server-side LLM call runs to completion.
5. **No `os.Logger` in release builds** — only server-side observability.
6. **SQL grammar excluded** from tree-sitter — upstream SPM package issue.
7. **Replace ⌘V targeting** — HUD panel may capture key window after Replace click, causing paste to target the panel instead of the editor.
8. **Pre-existing test failure** — `MockAIProvider` doesn't conform to `AIProviderProtocol` in `SelectionModeCoordinatorTests.swift:49`.

---

## Things NOT To Change

These architectural decisions are validated. Do not redesign without strong evidence.

### Frozen Specifications
13. **DAS-000 through DAS-012** — canonical architecture. Changes require a DAS amendment process.
14. **DDS-000 through DDS-009** — canonical design specifications. Changes require a DDS amendment process.
15. **IAG-001 through IAG-004** — canonical implementation architecture. Changes require an explicit RFC with evidence of incorrectness (IAG-004 §21.3).
16. **DIR as canonical asset** — all capabilities are consumers of the DIR. Do not build features that bypass the intelligence architecture.

### Existing Application
1. **Deterministic Facts Engine** — single-pass AST extraction of entities, imports, relationships. Foundation for everything.
2. **File Intelligence architecture** — layered understanding model (Identity → Purpose → Behavior → Safety → Design). All layers implemented and validated.
3. **Lazy Semantic Enrichment** — triggered by user question, not by parsing. Cached by file hash. In-memory cache. Single LLM call for all four layers.
4. **Structured facts prompt design** — send entity signatures/relationships to LLM, not raw source code. Methods grouped under owning types, external calls included.
5. **Context tier system** — 4 tiers (tier1→tier3) with ContextBuilderService. Stable.
6. **Manual DI** — `AppDependencies` as root container. No framework.
7. **Deferred startup** — `performDeferredStartup()` via `didBecomeActiveNotification`.
8. **Generation-counter request replacement** — coordinators use `requestGeneration` + cancellation. No mutex needed.
9. **V7 explanation prompt** — frozen until real-user evidence justifies changes.
10. **DSA as separate prompt** — not an overlay on V7. Lives in `ExplanationFramework+DSA.swift`.
11. **Analytics pipeline** — server-side token extraction, compound mode values, orthogonal `mode` and `explanation_profile`.
12. **Incremental milestone-based development** — File → Architecture → Implementation → Project Intelligence progression.

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
- **Never infer active session.** Use `activeSessionId` set by explicit user action only.
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
- **Never add imports between pipeline modules beyond IAG-001 §3.** The dependency graph is frozen.
- **Never use `@MainActor` in any understanding pipeline module.** Pipeline runs off the main thread (IAG-003 §6.3).
- **Never use `@unchecked Sendable` without documented justification.** Strict concurrency must be clean (IAG-003 §10.3).
- **Never skip a verification gate.** Phase N+1 does not begin until Phase N exit criteria pass (IAG-004 §12).
- **Never patch downstream to fix upstream.** Fix defects at the earliest phase that introduced them (IAG-004 §20).
- **Never import GRDB in any understanding pipeline module.** Storage uses Codable + atomic file I/O (IAG-002:TI-3).
- **Never redesign a DDS contract during implementation.** If it seems wrong, file an RFC (IAG-004 §21).

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
13 test files in `DecodeTests/`. One pre-existing failure: `MockAIProvider` conformance in `SelectionModeCoordinatorTests.swift:49`.
