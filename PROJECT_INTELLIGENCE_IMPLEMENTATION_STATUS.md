# Project Intelligence Implementation Status

## Purpose

This file tracks the implementation state of the Project Intelligence epic. It is the canonical handoff document for all future Claude Code sessions working on this epic. It is updated after every completed implementation milestone.

Do not reconstruct implementation history from git or conversation logs. Read this file instead.

---

## Architecture Status

| Layer | Status |
|-------|--------|
| DAS (DAS-000 through DAS-012) | Frozen |
| DDS (DDS-000 through DDS-009) | Frozen |
| IAG (IAG-001 through IAG-004) | Frozen |

Architecture changes require an RFC per IAG-004 §21.

The **Session Mode epic is closed.** All 18 specification-defined capabilities are implemented and tested. Session Mode implementation is tracked in `SESSION_MODE_IMPLEMENTATION_STATUS.md` (read-only reference).

Project Intelligence is a **consumer** of the completed Software Intelligence Platform. It does not modify the platform. All Project Intelligence code lives in the application layer (`Decode/Application/` or `Decode/App/`), not in pipeline modules (`Decode/Understanding/`). It registers into the pipeline at startup via `AppDependencies.performDeferredStartup()`, following the precedent of SwiftSyntaxFrontend, TreeSitterFrontend, ExplainReasoningEngine, ImproveReasoningEngine, FollowUpReasoningEngine, and ContextStrategies.

Capability specification: `docs/PROJECT_INTELLIGENCE_TECHNICAL_SPECIFICATION.md`

---

## Current Platform State

The Software Intelligence Platform is fully operational. All 8 pipeline modules are complete, tested, and frozen.

| Module | Role | Tests | Status |
|--------|------|-------|--------|
| DIRCore (M1) | Foundation types, cross-module protocols | 36 | Frozen |
| ProducerRuntime (M2) | Producer registration, DAG, execution | 34 | Frozen |
| IndexRuntime (M3) | Five index families, batch update | 45 | Frozen |
| StorageEngine (M8) | Snapshot persistence, GC, grounding map | 42 | Frozen |
| UpdateEngine (M7) | DIR runtime, change set processing | 54 | Frozen |
| RetrievalRuntime (M4) | Five-stage evidence retrieval | 38 | Frozen |
| ContextAssembly (M5) | Strategy-based context frame assembly | 60 | Frozen |
| ConsumerRuntime (M6) | Reasoning engine management | 52 | Frozen |

**Pipeline test totals:** 361 unit tests + 24 integration tests = 385 tests.

**Composition root:** `UnderstandingSystem` at `Decode/App/UnderstandingSystem.swift`.

**Application integration:** `AppDependencies` owns `UnderstandingSystem`. Started in `performDeferredStartup()` via `Task.detached`. Shutdown via `willTerminateNotification`.

---

## Completed Foundation

### File Intelligence (Closed)

All five understanding layers implemented and validated:
- Identity — file role, architectural layer, patterns (deterministic)
- Purpose — why the file exists (deterministic + semantic enrichment)
- Behavior — control flow, state transitions, side effects (semantic enrichment)
- Safety — error handling, concurrency model, resource lifecycle (semantic enrichment)
- Design — architectural responsibility, patterns, trade-offs (semantic enrichment)

Deterministic Facts Engine: single-pass AST extraction of entities, imports, relationships via SwiftSyntaxParser (Swift) and TreeSitterParser (all other languages).

Semantic Enrichment Pipeline: lazy, cached LLM-derived understanding. Single LLM call for all four semantic layers. Cached by file hash. Falls back to deterministic purpose on failure.

### Session Mode (Closed)

All 18 specification-defined capabilities implemented. Three modes, four hotkeys:
- Selection Mode (double-tap Control)
- Screenshot Mode (double-tap Option)
- Session Mode (⌃⇧O open file, then double-tap Shift)

Pipeline-first execution for Session Explain, Follow-Up, and Improve with automatic legacy fallback. Context tier system (tier1–tier3). Code health classification. Follow-up conversations. Post-explanation code improvement.

### Pipeline Integration (Closed)

- **3 reasoning engines:** ExplainReasoningEngine, ImproveReasoningEngine, FollowUpReasoningEngine — all registered at startup, all with deterministic fallback paths.
- **2 frontends:** SwiftSyntaxFrontend (Swift), TreeSitterFrontend (Python, JS, TS, HTML, CSS, Java, C#, C, C++) — both producing T0 atomic units via shared `FrontendOutputConversion`.
- **3 context strategies:** Explain v2.0.0 (50/25/10/15 with module stratum), Improve v1.0.0 (70/30), FollowUp v2.0.0 (50/25/10/15 with module stratum) — registered via `StrategyManagement`.
- **PipelineQueryService:** Orchestrates the complete query chain (processChanges → retrieve → assemble → invoke consumer → Understanding).
- **End-to-end flow:** File → frontend → DIR → retrieval → assembly → consumer → Understanding.

### Production Hardening (Closed)

Comprehensive unit tests for SessionResolver, ContextBuilderService, SnippetHealthClassifier, ExplanationTagParser. MockAIProvider conformance fix.

### Containment Migration (Closed)

File → Entity containment (`contains` predicate) migrated from CrossFileResolutionPass (T1 composition) to `FrontendOutputConversion.convert()` (T0 deterministic). DAS-004 CONT-3: below-file containment belongs exclusively to source parsers. CrossFileResolutionPass deleted.

---

## Current Epic: Project Intelligence

**Purpose:** Transform software understanding from individual files into understanding of modules, architecture, and complete software systems.

**Capability specification:** `docs/PROJECT_INTELLIGENCE_TECHNICAL_SPECIFICATION.md`

**Two phases:**
- Phase 1 (Milestones 1–7): **Module Intelligence** — cross-file resolution, module boundaries, emergent properties, module-scope context, module-aware explanations.
- Phase 2 (Milestones 8–12): **Project Intelligence** — system entity, architectural properties, project-scope context, architecture-aware explanations.

**Engineering principles** (from capability spec §5):
1. Compose, do not aggregate (DAS-001 P4, DAS-006 CP-4)
2. Deterministic before semantic, again (CLAUDE.md Principle #1)
3. Reuse the platform (no new framework targets, no new actor types)
4. Incremental value delivery (every milestone delivers user-facing value)
5. Graceful degradation at every scope
6. Budget-aware context (DDS-006 R3)

---

## Milestone Status

### Phase 1: Module Intelligence

#### Milestone 1: Cross-File Entity Resolution

- **Status:** Complete
- **Implementation:** `CrossFileResolutionPass` at `Decode/App/CrossFileResolutionPass.swift`
- **Tests:** 30 tests in `DecodeTests/Application/CrossFileResolutionPassTests.swift`
- **Dependencies:** SwiftSyntaxFrontend, TreeSitterFrontend (T0 relationship and entity predicates)
- **Notes:** Resolves symbolic relationship targets (e.g., `.calls` targeting `"resolve"`) to qualified cross-file entity references. Deterministic T1 pass with `perSystem` scope. Uses the SAME canonical relationship predicates (`calls`, `conformsTo`, `inherits`) at T1 — tier distinguishes symbolic (T0) from resolved (T1). Confidence: `.high` for unique match, `.low` for 2-3 candidates, skip for 4+. Grounding refs link to both the T0 relationship unit and the T0 kind unit of the resolved target. Value is `.boolean(true)` (same as T0). `owns` relationships skipped (intra-file by definition). Same-file targets skipped (already represented by T0). Registered in `AppDependencies.performDeferredStartup()` alongside ModuleBoundaryPass.

#### Milestone 2: Directory-Based Module Boundary Detection

- **Status:** Complete
- **Implementation:** `ModuleBoundaryPass` at `Decode/App/ModuleBoundaryPass.swift`
- **Tests:** 43 tests in `DecodeTests/Application/ModuleBoundaryPassTests.swift`
- **Dependencies:** SwiftSyntaxFrontend, TreeSitterFrontend
- **Notes:** Groups files by parent directory. Creates one Module entity per directory with `module:<dirName>` qualified names. T1 deterministic composition pass with `perSystem` scope. Registered in `AppDependencies.performDeferredStartup()`.

#### Milestone 3: Module Entity Creation via Composition Pass

- **Status:** Complete
- **Implementation:** `ModuleBoundaryPass` (same pass as M2)
- **Notes:** Module entities carry: `kind=module`, `name`, `path`, `fileCount`, `contains(Module → File)` containment relationships, plus structural metadata (`entityCount`, `typeCount`, `functionCount`, `importCount`, `relationshipCount`, `languageDistribution`, `entityKindDistribution`, `externalImports`). All outputs are T1 with `.high` confidence. Structural metadata outputs are aggregations, not emergent properties — genuine emergence is M4's responsibility.

#### Milestone 4: Module Emergent Properties

- **Status:** Complete
- **Implementation:** `ModuleEmergentPropertiesPass` at `Decode/App/ModuleEmergentPropertiesPass.swift`
- **Tests:** 46 tests across 12 suites in `DecodeTests/Application/ModuleEmergentPropertiesPassTests.swift`
- **Dependencies:** M1 (cross-file resolution), M2+M3 (module entities with containment). **M4 is the convergence point.**
- **Notes:** Produces five genuinely emergent properties per capability spec §8.3 and DAS-006 CP-4. All outputs are T1 with `emergence` domain. `isComposition: false`, `isIdempotent: true`, `scope: .perSystem`, `executionStrategy: .deterministic`. Dependencies: `module-boundary-pass`, `cross-file-resolution-pass`. Registered in `AppDependencies.performDeferredStartup()`.
- **Emergent Properties:**
  1. **cohesion** (`emergence` domain): Ratio of intra-module to total relationships. Structured value with `internal` (Int64), `external` (Int64), `ratio` (Double). No single file knows how many of its relationships stay within the module. Confidence: `.high`.
  2. **publicInterface** (`emergence` domain): Entities within the module that are targets of cross-module relationships. Structured value with `count` (Int64), `entities` (String, sorted comma-separated). No single file knows whether it is referenced from outside. Confidence: `.high`.
  3. **interactionProfile** (`emergence` domain): Distribution of intra-module relationship types. Structured value with `calls` (Int64), `conformsTo` (Int64), `inherits` (Int64). Reveals whether a module is delegation-heavy, protocol-heavy, or inheritance-heavy — a property of the group's internal interaction style. Confidence: `.high`.
  4. **boundaryProfile** (`emergence` domain): Inbound and outbound cross-module relationships by type. Structured value with `inboundCalls`, `outboundCalls`, `inboundConformsTo`, `outboundConformsTo`, `inboundInherits`, `outboundInherits` (all Int64). Reveals the module's interface shape. Confidence: `.high`.
  5. **moduleRole** (`emergence` domain): Structural classification derived from boundary profile direction. String value: `isolated` (no cross-module), `provider` (inbound >= 2*outbound or outbound==0), `consumer` (outbound >= 2*inbound or inbound==0), `mixed` (balanced). Confidence: `.high` for isolated, `.moderate` for non-isolated (classification is a judgment call).
- **Algorithm:** Phase 1 builds entity→module map from T0 `kind:structure` grounding (filePath → directoryPath → lastPathComponent). Phase 2 identifies modules from T1 `kind:structure` where value=="module". Phase 3 counts T0 relationships per module by type (always intra-module since T0 is intra-file). Phase 4 classifies T1 cross-file relationships as intra-module or cross-module. Phase 5 emits 5 emergent property units per module.

#### Milestone 5: Module-Scope Context Strategy

- **Status:** Complete
- **Dependencies:** M4 (module emergent properties available in DIR)
- **Implementation:**
  - `RetrievalRuntime.gatherScopeEvidence()` extended with additive module-scope gathering (distance 2, provenance `["scope", "module:<name>"]`)
  - `PipelineQueryService.query()` maps purpose→scope: explain/followup → `.module`, improve → `.local`
  - `ContextStrategies.explain` superseded to v2.0.0 with 4 strata: direct (50%, distanceFirst, essential), relational (25%, distanceFirst), module (10%, confidenceFirst, T1 only), scope (15%, distanceFirst, T0 only)
  - `ContextStrategies.followup` superseded to v2.0.0, mirrors explain
  - `ContextStrategies.improve` unchanged at v1.0.0
- **Tests:** 39 tests in `DecodeTests/Application/ModuleContextStrategyTests.swift` (10 suites) + 4 tests in `UnderstandingTests/RetrievalRuntimeTests/RetrievalRuntimeTests.swift` (Module Scope Evidence suite)
- **Key design decisions:**
  - SI-2 compliance via tier-based partition: module stratum selects scope-stage T1, file-scope stratum selects scope-stage T0. Disjoint because `minTier(.t1) > maxTier(.t0)`.
  - No pre-filtering in RetrievalRuntime (DDS-005 RI-2: horizon completeness). All filtering delegated to ContextAssembly via SelectionCriteria.
  - Budget fractions are tuning-level decisions. Architecture places them in strategy definitions where they can be adjusted without modifying pipeline code.
  - Module entity lookup uses path-based computation (same algorithm as ModuleBoundaryPass), not ScopeIndex inverse lookup (which doesn't exist).
  - Module evidence annotated at distance 2 (file=1, module=2) per DAS-005 hierarchy.
- **Notes:** RetrievalRuntimeTests added to Decode scheme test targets in `project.yml` for CI integration.

#### Milestone 6: Module-Aware Explanation Enhancement

- **Status:** Complete
- **Dependencies:** M5 (module-scope context available in context frames)
- **Implementation:**
  - `ModuleObservations` type in `ReasoningEngineSupport.swift` — structured semantic observation layer
  - Observation extraction: identifies `module:*` entities, parses emergent properties, applies suppression rules, interprets values, generates guidance directives
  - `ReasoningEngineSupport.extractModuleObservations()` — shared extraction logic
  - `ReasoningEngineSupport.filterModuleEntities()` — removes consumed module entities from raw entity facts
  - `ExplainReasoningEngine` — injects MODULE OBSERVATIONS into user prompt, adds module instruction to system prompt, filters module entities from entity section
  - `FollowUpReasoningEngine` — same prompt injection for initial invocation, module summary in ConversationState context summary, follow-up system prompt augmented with reactive module instruction
- **Tests:** 37 tests in `DecodeTests/Application/ModuleObservationTests.swift` (8 suites)
- **Key design decisions:**
  - Option B (structured semantic observations) over Option A (natural-language sentences). Observations are interpreted facts with guidance directives — the LLM synthesizes them into prose. Extensible to M10 system-level context.
  - Suppression rules: single-file module (fully suppressed), moderate cohesion 0.3–0.8 (suppressed), mixed role for internal entities (suppressed), balanced interaction profile (suppressed), low relationship count < 5 (suppressed), balanced boundary (suppressed).
  - Module entity facts removed from `## Entities` section — consumed by observation layer, no duplication.
  - Guidance directives are deterministic — computed from the combination of surviving observations.
  - FollowUp stores compact module summary in ConversationState; follow-up system prompt instructs reactive use (only reference module context when question touches cross-file concerns).
  - ImproveReasoningEngine unmodified — improve strategy has no module stratum, never receives module evidence.

#### Milestone 7: Module Intelligence Validation

- **Status:** Complete (2026-07-28)
- **Dependencies:** M6 (module-aware explanations operational)
- **Validated by:** 34 tests in `DecodeTests/Application/ModuleIntelligenceValidationTests.swift` (8 suites: M7-V1 through M7-V8)
- **Validation results:**
  1. **Multi-file module observations**: Provider/consumer/isolated modules produce correct observations with role, visibility, cohesion, style, and boundary fields. Public vs internal entity distinction works.
  2. **Single-file module suppression**: Single-file modules are fully suppressed regardless of role (provider, consumer, mixed, isolated). No false observations.
  3. **Prompt injection**: MODULE OBSERVATIONS block is formatted correctly with module name, role, guidance. Module entities filtered from entity section (AI path). System prompt includes weaving instruction. Follow-up instruction is reactive.
  4. **ExplainReasoningEngine integration**: Deterministic output includes entity information. AI prompt path filters module entities and injects observations. Single-file modules produce no observations for AI prompt.
  5. **Suppression rules**: Moderate cohesion (0.3-0.8), mixed role for internal entities, balanced interaction profiles, and low relationship counts (<5) are all correctly suppressed.
  6. **Guidance generation**: Provider+public generates cross-module impact guidance. Consumer generates dependency guidance. Isolated generates self-containment guidance.
  7. **Context strategy**: Explain v2.0.0 has 4 strata (direct 50%, relational 25%, module 10%, scope 15%). Module stratum selects T1 scope evidence. No T0/T1 overlap (SI-2). Budget fractions sum to 1.0. Improve has no module stratum. Followup mirrors explain.
  8. **Richness comparison**: Multi-file module produces role, visibility, cohesion observations absent from file-only. Single-file produces none.
- **Benchmark integration:** 4 module benchmark cases added to BenchmarkCorpus (mod-01 through mod-04): multi-file service, protocol conformance across files, layered architecture, single-file suppression.
- **No pipeline module modifications.** All validation through tests that exercise existing code paths.

### Phase 2: Project Intelligence

#### Milestone 8: System Entity Creation via Composition Pass

- **Status:** Complete (2026-07-31)
- **Dependencies:** M7 (Module Intelligence complete)
- **Implementation:** `SystemCompositionPass` at `Decode/App/SystemCompositionPass.swift`
- **Tests:** 35 tests across 8 suites in `DecodeTests/Application/SystemCompositionPassTests.swift`
- **Registration:** `AppDependencies.performDeferredStartup()` — registered after ModuleEmergentPropertiesPass, before context strategy registration.
- **Notes:** T1 deterministic composition pass with `perSystem` scope. Creates a single `system:<name>` entity from all T1 module entities produced by ModuleBoundaryPass. Follows the exact `enum` + static `contract`/`handler`/`identity` pattern established by ModuleBoundaryPass and ModuleEmergentPropertiesPass.
- **Contract:** Identity `"system-composition-pass"` v1.0. Input: T1 predicates (`kind:structure`, `name:structure`, `path:structure`, `fileCount:composition`, `entityCount:composition`, `languageDistribution:composition`). Output: T1 predicates (`kind:structure`, `name:structure`, `path:structure`, `moduleCount:composition`, `totalFileCount:composition`, `totalEntityCount:composition`, `languageDistribution:composition`, `contains:containment`). Scope: `.perSystem`. `isComposition: true`. Dependencies: `["module-boundary-pass"]`.
- **Handler phases:** Phase 1 — discover modules from T1 `kind:structure = "module"`. Phase 2 — collect metadata (paths, fileCounts, entityCounts, languageDistribution). Phase 3 — derive system name from common root path. Phase 4 — emit outputs (kind, name, path, moduleCount, totalFileCount, totalEntityCount, languageDistribution, contains).
- **System naming:** `deriveSystemName(from:)` computes the longest common directory prefix across all module paths, takes its last path component. Falls back to `"system"` for empty paths or filesystem root. `commonRootPath(from:)` handles single-module (parent directory), multi-module (LCP), absolute/relative paths.
- **Test suites:** SCPContractTests (9), SCPMinimalTests (3), SCPMultiModuleTests (6), SCPMetadataTests (5), SCPNamingTests (5), SCPOutputQualityTests (4), SCPIdempotencyTests (2), SCPUnitStatusTests (1).

#### Milestone 9: System Emergent Properties

- **Status:** Complete (2026-07-31)
- **Dependencies:** M8 (System entity exists in DIR), M4 (module emergent properties)
- **Implementation:** `SystemEmergentPropertiesPass` at `Decode/App/SystemEmergentPropertiesPass.swift`
- **Tests:** 48 tests across 12 suites in `DecodeTests/Application/SystemEmergentPropertiesPassTests.swift`
- **Registration:** `AppDependencies.performDeferredStartup()` — registered after SystemCompositionPass, before context strategy registration.
- **Notes:** T1 enrichment pass with `perSystem` scope. Enriches the existing `system:*` entity (created by M8) with 5 emergent properties. `isComposition: false` (DAS-006 CP-2). Dependencies: `system-composition-pass`, `module-emergent-properties-pass`. Follows the `enum` + static `contract`/`handler`/`identity` pattern.
- **Contract:** Identity `"system-emergent-properties-pass"` v1.0. Input: T0/T1 (`kind:structure`, `contains:containment`, `languageDistribution:composition`, `calls/conformsTo/inherits:relationship`, `cohesion/publicInterface/interactionProfile/boundaryProfile/moduleRole:emergence`). Output: T1 (`architectureStyle:emergence`, `dependencyDirection:emergence`, `crossCuttingPatterns:emergence`, `moduleInteractionMap:emergence`, `technologyDistribution:emergence`). Scope: `.perSystem`. `isComposition: false`. `isIdempotent: true`.
- **Handler phases:** Phase 1 — identify system entity, modules, build entity→module mapping. Phase 2 — build module interaction map from T1 cross-module relationships, track cross-cutting entity references. Phase 3 — collect module emergent properties and language distributions. Phase 4 — compute all 5 emergent properties. Phase 5 — emit outputs.
- **Emergent properties:**
  1. **moduleInteractionMap** (`emergence`): Typed interaction matrix between modules. Keys are `"srcModule→tgtModule"`, values are per-type counts (`calls`, `conformsTo`, `inherits`). Plus `edgeCount`. Deterministic, `.high` confidence.
  2. **dependencyDirection** (`emergence`): Directed module dependency graph. Topological sort via Kahn's algorithm assigns depth per module. Detects cycles (`hasCycles`), counts violations (`violationCount`), reports `layerCount` and `layers` string. Deterministic, `.high` confidence.
  3. **crossCuttingPatterns** (`emergence`): Entities referenced by ≥3 distinct source modules. Classified as `protocol_boundary` (conformsTo only), `shared_service` (calls only), `shared_base` (inherits only), or `shared_dependency` (mixed). Includes `threshold` field for transparency. Heuristic, `.moderate` confidence.
  4. **technologyDistribution** (`emergence`): System-wide language profile aggregated from module distributions. Includes `primaryLanguage` (lexicographic tiebreaker), `languageCount`, and per-language file counts. Deterministic, `.high` confidence.
  5. **architectureStyle** (`emergence`): Structural classification with supporting `evidence` string. Styles: `layered` (≥3 layers, 0 violations), `layered_with_violations` (≥3 layers, ≤20% violation edges), `hub_and_spoke` (one module receives ≥50% inbound), `modular` (peer modules, <3 layers), `entangled` (cycles), `isolated` (no cross-module deps or single module), `mixed` (fallback). Heuristic, `.moderate` confidence.
- **Test suites:** SEP Contract Tests (9), SEP Module Interaction Map (6), SEP Technology Distribution (4), SEP Dependency Direction (8), SEP Cross-Cutting Patterns (5), SEP Architecture Style (5), SEP Single Module (2), SEP Empty Input (2), SEP Output Quality (4), SEP Idempotency (2), SEP Inactive Units (1), SEP Layered Architecture Integration (1).

#### Milestone 10: Project-Scope Context Strategy

- **Status:** Not Started
- **Dependencies:** M9 (system emergent properties available)
- **Notes:** Architectural framing for explanations. Selective — not every question needs project scope.

#### Milestone 11: Architecture-Aware Explanation Enhancement

- **Status:** Not Started
- **Dependencies:** M10 (project-scope context available)
- **Notes:** Reasoning engine prompts enriched with architectural context.

#### Milestone 12: Project Intelligence Validation

- **Status:** Not Started
- **Dependencies:** M11 (architecture-aware explanations operational)
- **Notes:** Verify that explanations for architectural questions are measurably richer than module-only explanations.

---

## Dependency Graph

```
                    Frontends (T0)
                   ╱              ╲
                  ╱                ╲
    ┌─────────────────┐    ┌──────────────────────┐
    │ M1: Cross-File  │    │ M2+M3: Module        │
    │ Entity          │    │ Boundary + Entity     │
    │ Resolution      │    │ Creation              │
    │ (COMPLETE)      │    │ (COMPLETE)            │
    └────────┬────────┘    └──────────┬────────────┘
             │                        │
             │    ┌───────────────┐   │
             └───→│ M4: Module    │←──┘
                  │ Emergent      │
                  │ Properties    │
                  │ (COMPLETE)    │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M5: Module-   │
                  │ Scope Context │
                  │ Strategy      │
                  │ (COMPLETE)    │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M6: Module-   │
                  │ Aware Explain │
                  │ Enhancement   │
                  │ (COMPLETE)    │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M7: Module    │
                  │ Intelligence  │
                  │ Validation    │
                  └───────┬───────┘
                          │
              ════════════╪════════════
              Phase 2: Project Intelligence
                          │
                  ┌───────┴───────┐
                  │ M8: System    │
                  │ Entity        │
                  │ Creation      │
                  │ (COMPLETE)    │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M9: System    │
                  │ Emergent      │
                  │ Properties    │
                  │ (COMPLETE)    │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M10: Project- │
                  │ Scope Context │
                  │ (COMPLETE)    │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M11: Arch-    │
                  │ Aware Explain │
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │ M12: Project  │
                  │ Intelligence  │
                  │ Validation    │
                  └───────────────┘
```

**Key structural properties:**
- M1 and M2+M3 are **independent siblings** — both depend only on frontends. M2+M3 was correctly implementable before M1.
- M4 is the **convergence point** — requires both M1 (resolved cross-file relationships) and M2+M3 (module entities with containment).
- M5–M7 are **strictly sequential** — each consumes the previous milestone's output.
- M8–M12 **compose over M7** — system-level intelligence aggregates module-level intelligence.

---

## Current Immediate Task

### Milestone 12: Project Intelligence Validation

**Purpose:** End-to-end validation of the complete Project Intelligence stack (M8–M11). Verify that system composition, emergent properties, project-scope retrieval, and architecture-aware explanation work together correctly in production scenarios.

**Dependencies:** M11 (Architecture-Aware Explanation — COMPLETE).

**Not started.**

---

## Completed Milestone: M11 — Architecture-Aware Explanation

**Completed:** 2026-07-31

**What was implemented:**

1. **SystemObservations infrastructure** — `SystemObservations` struct in `ReasoningEngineSupport.swift` (~180 lines) with 6 observation types (ArchitectureObservation, DependencyObservation, ScaleObservation, CrossCuttingObservation, InteractionObservation, TechnologyObservation), `formatForPrompt()` with prioritized ordering support, `formatForContextSummary()`, `systemPromptInstruction`, `followUpContextInstruction`, and `ObservationKey` enum.

2. **System observation extraction pipeline** — `extractSystemObservations(from:codeEntityNames:moduleName:questionHint:)` in `ReasoningEngineSupport`. Full extraction: system entity discovery → property parsing → suppression rules (trivial system, unknown architecture, single language, insufficient layers) → observation building → guidance generation → question-aware ordering.

3. **System property parsing** — `SystemProperties` struct and `parseSystemProperties(from:)` parsing 8 predicate types: `architectureStyle`, `dependencyDirection`, `moduleCount`, `totalFileCount`, `totalEntityCount`, `crossCuttingPatterns`, `technologyDistribution`, `moduleInteractionMap`. Bracket-aware `parseStructuredValue()` fix (was splitting commas inside `[...]`).

4. **filterProjectEntities** — `filterProjectEntities(from:)` replaces `filterModuleEntities(from:)` in ExplainReasoningEngine and FollowUpReasoningEngine. Removes both `module:*` AND `system:*` entities from raw entity facts. Module-only filter retained for backward compatibility.

5. **ExplainReasoningEngine updates** — System observation extraction in `reason()`, `hasSystemObservations` parameter in `buildSystemPrompt()`, `systemObservations` parameter in `buildUserPrompt()`. System observations injected before module observations. Uses `filterProjectEntities`.

6. **FollowUpReasoningEngine updates** — System observation extraction in `handleInitialInvocation()`, system-aware `buildInitialSystemPrompt()`, `buildInitialUserPrompt()`, `buildContextSummary()`. Follow-up system prompt includes `SystemObservations.followUpContextInstruction`. Context summary encodes system info for follow-up turns.

7. **Question-aware observation prioritization** — `questionAwareOrder(questionHint:)` and `shouldSuppressSystemForNarrowQuestion(questionHint:)` infrastructure. Implemented and tested as standalone static methods. Activated at default ordering since question text doesn't flow to frozen reasoning engines (noted in code comment).

8. **6 observation builders** — `buildArchitectureObservation`, `buildDependencyObservation`, `buildScaleObservation`, `buildCrossCuttingObservation` (entity-aware: detects if the explained entity is itself cross-cutting), `buildInteractionObservation` (module-filtered), `buildTechnologyObservation`.

9. **System guidance generation** — `generateSystemGuidance(architecture:dependencies:crossCutting:moduleName:)` with architecture framing, cycle detection concern, cross-cutting impact emphasis, and generic fallback.

10. **Comprehensive test coverage** — 50 tests across 8 suites in `SystemObservationTests.swift`: system property parsing (7), observation extraction (7), observation builders (8), guidance generation (4), prompt formatting (5), filterProjectEntities (3), question-aware ordering (8), engine integration (8). All pass.

**Files modified:**
- `Decode/Application/ReasoningEngineSupport.swift` — SystemObservations struct, extractSystemObservations, filterProjectEntities, parseSystemProperties, 6 observation builders, guidance generation, question-aware ordering, bracket-aware parseStructuredValue
- `Decode/Application/ExplainReasoningEngine.swift` — reason(), buildSystemPrompt(), buildUserPrompt() updated for system observations
- `Decode/Application/FollowUpReasoningEngine.swift` — handleInitialInvocation(), buildInitialSystemPrompt(), buildInitialUserPrompt(), buildContextSummary(), followUpSystemPrompt updated for system observations

**Files created:**
- `DecodeTests/Application/SystemObservationTests.swift` — 50 tests across 8 suites

**ImproveReasoningEngine intentionally NOT modified** — decision 24 extended to system level. Improve strategy has no project stratum and maps to `.local` scope, so no system evidence reaches improve context frames.

**Bug fixed:** `parseStructuredValue()` was splitting on commas naively, breaking values containing bracket-enclosed lists like `[Swift(92.5), Python(7.5)]`. Fixed with bracket-depth tracking.

---

## Completed Milestone: M10 — Project-Scope Context Strategy

**Completed:** 2026-07-31

**What was implemented:**

1. **RetrievalRuntime system-scope evidence gathering** — Added `if plan.scope >= .system` block to `gatherScopeEvidence()` that scans active T1 units for `kind:structure = "system"`, queries the Entity Index for all system entity properties, and annotates at distance 3 with provenance `["scope", "system:<name>"]`. This is an additive extension following the M5 precedent (decision 9).

2. **Context strategies v3.0.0** — Superseded explain and followup strategies from v2.0.0 to v3.0.0. The "module" stratum is renamed to "project" and its budget increased from 10% to 15%. Direct stratum reduced from 50% to 45%. The project stratum continues to select T1 scope-stage evidence (SI-2 compliant via tier partition). Improve strategy unchanged at v1.0.0.

3. **QuestionClassifier system-scope routing** — Explain and followup purpose defaults changed from `.module` to `.system`. Overview keywords route to `max(baseline.scope, .system)`. Improve remains at `.local`.

4. **Comprehensive test coverage** — 4 new system scope evidence tests (RetrievalRuntimeTests), 4 new M10 question classifier tests, updated 10 strategy definition suites from M5→M10 naming, updated all QuestionClassifier tests for `.system` defaults, updated M7-V7 validation tests for v3.0.0 strategy.

**Files modified:**
- `Decode/Understanding/RetrievalRuntime/RetrievalRuntime.swift` — system-scope evidence block
- `Decode/App/ContextStrategies.swift` — v3.0.0 explain + followup strategies
- `Decode/App/QuestionClassifier.swift` — `.system` defaults, overview → `.system`
- `DecodeTests/Application/ModuleContextStrategyTests.swift` — full rewrite for M10
- `DecodeTests/Application/QuestionClassifierTests.swift` — `.system` scope expectations
- `DecodeTests/Application/ModuleIntelligenceValidationTests.swift` — v3.0.0 validation
- `UnderstandingTests/RetrievalRuntimeTests/RetrievalRuntimeTests.swift` — system scope tests

**No files created. No files deleted.**

---

## Known Decisions

These decisions are load-bearing. Future work must preserve them.

1. **Session Mode is closed.** All 18 specification-defined capabilities are implemented. Future Session Mode work limited to bug fixes, reliability improvements, security fixes, or explicitly approved product changes.

2. **File → Entity containment belongs to source parsers.** DAS-004 CONT-3 assigns below-file containment exclusively to source parsers (T0, deterministic). `FrontendOutputConversion` handles this natively. Do not recreate containment in composition passes.

3. **ModuleBoundaryPass is structurally correct for M2+M3.** Directory-based module boundary detection and module entity creation are complete. No restructuring required.

4. **ModuleBoundaryPass structural metadata outputs are aggregations, not emergent properties.** The capability spec (§5.1) explicitly states that passes producing only counts and distributions violate the emergence principle. Current PI-002-labeled outputs (`entityCount`, `typeCount`, etc.) are M3 structural metadata. Genuine emergence (interaction patterns, cohesion, public interface surface) is M4's responsibility.

5. **M2/M3 implemented before M1 — no architectural debt.** ModuleBoundaryPass reads only T0 inputs and does not attempt cross-file resolution. M1 registers as a parallel sibling in the DAG. No restructuring needed.

6. **M4 is the convergence point.** It requires both M1 (resolved cross-file relationships) and M2+M3 (module entities with containment). M4 cannot begin until M1 is complete.

7. **Architecture documents are frozen.** DAS-000–012, DDS-000–009, IAG-001–004. Changes require an RFC per IAG-004 §21.3.

8. **No downstream compensation for upstream defects.** Fix defects at the earliest phase that introduced them (IAG-004 §20).

9. **Project Intelligence code primarily lives in the application layer.** `Decode/Application/` or `Decode/App/`. No new framework targets. Two exceptions: `RetrievalRuntime.gatherScopeEvidence()` received additive extensions — M5 added module-scope evidence when `plan.scope >= .module`, M10 added system-scope evidence when `plan.scope >= .system`. These are necessary because evidence gathering is a retrieval-layer responsibility (DDS-005). Both extensions are additive — existing `.local` and `.module` behavior is unchanged.

10. **Frontend relationship targets are symbolic names.** `FrontendOutputConversion` produces `EntityReference(qualifiedName: rel.targetName)` where `targetName` is the unqualified symbolic name from the parser (e.g., `"resolve"`, `"Sendable"`). M1 must resolve these to qualified cross-file references.

11. **Pass registration follows established precedent.** `enum` with static `contract`, `handler`, and `identity`. Registered in `AppDependencies.performDeferredStartup()` inside the `Task.detached` block. Same pattern as ModuleBoundaryPass.

12. **Relationship predicates use EntityPair subjects.** Source and target entity references as `UnitSubject.pair(EntityPair(...))`. Value is `.boolean(true)`. The relationship's existence is the information; the subject encodes the direction.

13. **M1 uses the SAME canonical relationship predicates at T1.** Cross-file resolved relationships use `calls:relationship`, `conformsTo:relationship`, `inherits:relationship` — the same predicates as T0. The tier (T0 vs T1) distinguishes symbolic from resolved. This eliminates predicate proliferation and requires zero changes to RetrievalRuntime (which already hardcodes traversal plans for these predicates). The Graph Index automatically indexes T1 units alongside T0 units.

14. **T1 relationship units use `.boolean(true)` value, not structured metadata.** Confidence and grounding refs are sufficient provenance. Candidate counts, search statistics, and intermediate algorithm state are not persisted in the DIR — they are ephemeral computation artifacts.

15. **Ambiguity threshold: 1 candidate = `.high`, 2-3 = `.low`, 4+ = skip.** Common names like `init`, `configure`, `update` typically have 4+ candidates across files and are too ambiguous for deterministic resolution. The threshold is an implementation constant, not a configuration.

16. **SI-2 compliance via tier-based partition.** Module stratum selects scope-stage evidence at T1 (`SelectionCriteria(stage: .scope, minTier: .t1, maxTier: .t1)`). File-scope stratum selects scope-stage evidence at T0 (`SelectionCriteria(stage: .scope, maxTier: .t0)`). Disjoint because `minTier(.t1) > maxTier(.t0)`. Both strata share the same `stage: .scope` — tier ranges are the discriminator.

17. **No pre-filtering in RetrievalRuntime.** DDS-005 RI-2 (Horizon Completeness) requires retrieval to gather all evidence within the horizon. DDS-005 RC-5 confirms retrieval does not guarantee relevance — Context Assembly provides relevance via SelectionCriteria. RetrievalRuntime gathers; ContextAssembly filters.

18. **Purpose→scope mapping lives in PipelineQueryService.** The scope decision (`explain/followup → .module`, `improve → .local`) is an application-layer routing decision, not a pipeline concern. PipelineQueryService is the correct owner because it bridges application-level purpose strings to pipeline-level RetrievalScope values.

19. **Module evidence distance is 2.** File-scope evidence is distance 1, module-scope evidence is distance 2. This follows the containment hierarchy depth (Entity → File → Module). ContextAssembly's `maxDistance` filter in SelectionCriteria can use this for future pruning.

20. **Module entity lookup uses path computation, not ScopeIndex.** ScopeIndex supports only parent→child queries, not child→parent. Module identification uses `filePath → NSString.deletingLastPathComponent → NSString.lastPathComponent → "module:<name>"` — the same algorithm as ModuleBoundaryPass. This is implementation debt (recomputes instead of consuming containment), but produces identical results and avoids adding inverse lookup to IndexRuntime.

21. **Module context uses structured semantic observations (Option B), not natural-language sentences (Option A).** Observations are interpreted facts with guidance directives. The reasoning engine does interpretation (structured → interpreted structured); the LLM does synthesis (interpreted structured → prose). This preserves the pipeline's separation of concerns and extends naturally to M10 system-level context.

22. **Module entities are consumed by the observation layer and removed from raw entity facts.** The `module:*` entity and its facts do not appear in the `## Entities` section of the prompt. They are extracted, interpreted, and presented as a `MODULE OBSERVATIONS` block. This prevents duplication and avoids the LLM narrating raw structured values.

23. **FollowUp module context is reactive, not proactive.** The follow-up system prompt instructs: "Reference module-level information only when the user's question touches cross-file concerns, impact, or architectural position." Module context is stored in the ConversationState context summary for availability, but only surfaces when the question calls for it.

24. **ImproveReasoningEngine is unmodified.** Improve's v1.0.0 strategy has no module stratum, PipelineQueryService maps improve to `.local` scope, so no module evidence ever reaches improve context frames. No observation logic needed.

25. **SystemCompositionPass depends only on ModuleBoundaryPass.** Unlike ModuleEmergentPropertiesPass (which depends on both ModuleBoundaryPass and CrossFileResolutionPass), the system composition pass needs only module entities and their structural metadata. Cross-file relationships are not consumed at the system composition level — they will be consumed by M9 (System Emergent Properties).

26. **System entity naming is deterministic from module paths.** `deriveSystemName(from:)` computes the longest common directory prefix of all module paths, then takes the last path component. Falls back to `"system"` when the common root is `/` (filesystem root) or empty. Single-module systems use the parent directory name. This is consistent with `module:<dirName>` naming convention.

27. **SystemEmergentPropertiesPass is an enrichment pass, not a composition pass.** `isComposition: false` because the system entity already exists (created by M8). This follows DAS-006 CP-2: "Composition passes enrich scope-level entities when they already exist." Same pattern as M4's ModuleEmergentPropertiesPass enriching module entities created by M2/M3.

28. **Deterministic vs heuristic confidence split for system properties.** Three properties are deterministic (`.high` confidence): `moduleInteractionMap`, `dependencyDirection`, `technologyDistribution` — directly derived from factual graph data. Two are heuristic (`.moderate` confidence): `architectureStyle`, `crossCuttingPatterns` — require threshold-based detection or classification from graph shape. This follows the M4 precedent where `moduleRole` gets `.moderate` confidence.

29. **Heuristic properties include structured supporting evidence.** `architectureStyle` includes an `evidence` string explaining why the classification was produced. `crossCuttingPatterns` includes the `threshold` value used for detection. This makes heuristic outputs transparent to downstream consumers without requiring re-computation.

30. **Cross-cutting threshold is 3 modules.** An entity referenced by ≥3 distinct source modules is considered cross-cutting. Threshold of 3 excludes normal 2-module coupling while catching genuine cross-cutting concerns. This is an implementation constant (like M1's ambiguity threshold), not a configuration parameter.

31. **Dependency direction uses topological sort for layer assignment.** Kahn's algorithm assigns depth: modules with zero outbound cross-module dependencies are depth 0 (leaf layer). Cycles are detected when no modules can be assigned in a round — remaining modules get depth -1. Violations are edges where the target has a higher depth than the source (lower layer depending on higher layer).

32. **Entity→module mapping reuses M4's path computation algorithm.** Same approach as ModuleEmergentPropertiesPass Phase 1: T0 `kind:structure` entities provide `filePath` via `.direct` grounding → `deletingLastPathComponent` → `lastPathComponent` = module name. Implementation debt (decision 20) but consistent and correct.

33. **Merged "project" stratum replaces separate "module" and "system" strata.** SI-2 mutual exclusivity (`criteriaCouldOverlap()`) checks stage, predicateDomains, and tier ranges — but NOT maxDistance. Two strata sharing `stage: .scope, minTier: .t1, maxTier: .t1` would be rejected regardless of distance differences. The merged "project" stratum selects all T1 scope evidence (module at distance 2, system at distance 3) in a single budget pool.

34. **System evidence distance is 3.** Following the containment hierarchy: Entity→File=1, File→Module=2, Module→System=3. This is consistent with decision 19 (module distance = 2) and enables distance-based ordering within the project stratum.

35. **System entity discovery uses active unit scan, not path computation.** Unlike module entities (decision 20), system entities are found by scanning active T1 units for `kind:structure = "system"`. This is correct because there is typically one system entity, and the system entity's qualified name (`system:<name>`) cannot be derived from the anchor's file path.

36. **Purpose defaults upgraded from `.module` to `.system`.** Explain and followup now default to `.system` scope, enabling system-level evidence retrieval without requiring architectural keywords. Improve remains `.local`. This is a behavioral change — all non-improve pipeline queries now gather file, module, AND system evidence.

37. **Budget rebalanced: direct 50%→45%, project (was module) 10%→15%.** The project stratum now serves both module and system evidence, justifying the increased budget. Direct stratum donates 5% — acceptable because module/system context provides architectural perspective that reduces the need for raw entity evidence.

38. **System observations follow the M6 ModuleObservations pattern.** Same pipeline: extract → suppress → interpret → generate guidance → format for prompt. Same integration points: system prompt instruction, user prompt observation block, context summary for follow-up state. This is a deliberate architectural extension, not a new pattern.

39. **System observations injected BEFORE module observations in prompts.** Order: SYSTEM OBSERVATIONS → MODULE OBSERVATIONS → Entities → Relationships. System provides the broadest framing (architecture, scale), module narrows to the entity's immediate context, entities provide the detail. This mirrors the containment hierarchy: system > module > entity.

40. **filterProjectEntities replaces filterModuleEntities in explain and followup engines.** Both `module:*` and `system:*` entities are consumed by their respective observation layers. Neither should appear as raw facts in the prompt's `## Entities` section. The module-only filter is retained for backward compatibility.

41. **Question-aware ordering is infrastructure-ready but not active.** `questionAwareOrder()` and `shouldSuppressSystemForNarrowQuestion()` are implemented and tested as standalone static methods. They cannot be activated because question text doesn't flow to reasoning engines (pipeline is frozen). The infrastructure is ready for activation when question context becomes available at this layer.

42. **FollowUp context summary includes system info for multi-turn conversations.** `buildContextSummary()` appends `systemObservations.formatForContextSummary()` (compact one-line: "System: name, architecture, scale.") so follow-up turns can reference system context without re-synthesis.

43. **Bracket-aware parseStructuredValue is load-bearing.** The structured value format from `textRepresentation(of: .structured(...))` can contain commas within bracket-enclosed lists (e.g., cross-cutting patterns, technology distributions, module interactions). Naive comma-splitting truncates these values. The bracket-depth tracking fix is essential for correct parsing.

---

## Known Blockers

**Pre-existing tree-sitter linker issue.** All tree-sitter C package targets fail to link with `___llvm_profile_runtime` undefined symbol. This blocks full Decode scheme builds and test execution for DecodeTests. Pipeline tests (`UnderstandingTests/`) pass independently. This issue predates the Project Intelligence epic and is unrelated to it.

No Project Intelligence-specific blockers exist.

---

## Repository State

| Item | Value |
|------|-------|
| Current branch | `main` |
| Working tree | Uncommitted (Product Validation Sprint + SessionState) |
| Swift compilation | Clean (zero errors in all pipeline + app targets) |
| Full app build | Succeeds (BUILD SUCCEEDED) |
| Pipeline unit tests | 361 passing (36+34+45+42+54+38+60+52) |
| Pipeline integration tests | 24 passing |
| ModuleBoundaryPass tests | 43 passing |
| CrossFileResolutionPass tests | 30 passing |
| ModuleEmergentPropertiesPass tests | 46 passing |
| ModuleContextStrategy tests | 43 passing |
| ModuleObservation tests | 37 passing |
| SystemObservation tests | 50 passing |
| Module Scope Evidence tests | 4 passing |
| System Scope Evidence tests | 4 passing |
| QuestionClassifier tests | 34 passing |
| SystemCompositionPass tests | 35 passing |
| SystemEmergentPropertiesPass tests | 48 passing |
| Reasoning engine tests | 22 passing (7+7+8) |
| Frontend tests | 23 passing (10+13) |
| SessionState tests | 23 passing (2+5+16) |
| SessionViewModelDirectory tests | 8 passing |
| WorkspaceManager tests | 32 passing (16+4+5+7) |
| Strict concurrency | Clean (zero warnings in pipeline modules) |

---

## Session Handoff

Every future Claude Code session implementing Project Intelligence should follow this sequence:

1. **Read `CLAUDE.md`** — project rules, engineering principles, constraints.
2. **Read `PROJECT_INTELLIGENCE_IMPLEMENTATION_STATUS.md`** (this file) — current state, next task, decisions to preserve.
3. **Read `docs/PROJECT_INTELLIGENCE_TECHNICAL_SPECIFICATION.md`** — capability specification, only the sections relevant to the current milestone.
4. **Do NOT read `SESSION_MODE_IMPLEMENTATION_STATUS.md`** unless debugging a Session Mode issue. That epic is closed.
5. **Inspect affected repository files** — the modules being consumed and the code being added.
6. **Implement** — production-quality code, strict concurrency, no stubs.
7. **Verify** — build clean, all tests pass (new and existing), zero regressions.
8. **Update this status document** — mark milestone complete, update phase, advance the immediate task, record any new decisions or issues.
9. **Stop** after the milestone is complete.

### What Must Never Change

- Pipeline modules (`Decode/Understanding/`) — frozen, RFC required for modifications.
- DAS, DDS, IAG documents — frozen.
- Session Mode capabilities — closed epic.
- Existing frontend and reasoning engine registrations — stable infrastructure.

### Implementation Order

```
M1 (Cross-File Entity Resolution)     ← COMPLETE
M4 (Module Emergent Properties)        ← COMPLETE (depends on M1 + M2+M3)
M5 (Module-Scope Context Strategy)     ← COMPLETE (depends on M4)
M6 (Module-Aware Explanation)          ← COMPLETE (depends on M5)
M7 (Module Intelligence Validation)    ← COMPLETE
M8 (System Entity Creation)            ← COMPLETE
M9 (System Emergent Properties)        ← COMPLETE
M10 (Project-Scope Context Strategy)   ← COMPLETE (depends on M9)
M11 (Architecture-Aware Explanation)   ← COMPLETE (depends on M10)
M12 (Project Intelligence Validation)  ← NEXT (depends on M11)
```

M2 and M3 are already complete. Phase 1 (Module Intelligence) is fully complete.
