# Decode Engineering Backlog

**Created:** 2026-07-28
**Owner:** Engineering
**Status:** Active — this is the operational source of truth for implementation.

Do not reconstruct priorities from conversation logs. Read this file.

---

## Epic Dependency Graph

```
Epic 1: Evaluation & Benchmarking
    │
    │  (informs all other epics)
    │
Epic 2: Software Intelligence ←── gates ──→ Epic 3: Context Intelligence
    │                                              │
    └──────────┬───────────────────────────────────┘
               │
        Epic 4: Knowledge Lifecycle
               │
        Epic 5: Product Intelligence
               │
        Epic 6: Question Intelligence (Future)
```

**Critical path:** E1-01 → E2-01 → E2-02 → E2-03 → E3-03 → E5-01

---

## Epic 1: Evaluation & Benchmarking

**Purpose:** Build the measurement infrastructure that every other epic depends on. Without evaluation, every change to strategies, observations, and retrieval is a guess.

**Desired end state:** Any change to the pipeline's consumer-facing output can be evaluated against a reproducible baseline. Regressions are detected before merge.

**User value:** No direct user value. Enables every subsequent milestone to ship with confidence.

**Success metrics:**
- Evaluation harness runs end-to-end without human intervention
- Baseline dataset is reproducible (same entities → same evidence → same prompts)
- Grounding precision is measured on every evaluation run
- Quality regressions are detectable via automated comparison

### Backlog Items

#### E1-01: Explanation Quality Baseline

- **Objective:** Build an evaluation harness that processes a fixed entity set through the pipeline and captures evidence, prompts, and outputs as a reusable baseline.
- **Dependencies:** None
- **Complexity:** M
- **Expected user impact:** None direct. Enables regression detection for all future work.
- **Status:** Complete (2026-07-28)

**Deliverables:**
- `EvaluationTypes.swift`: Codable types for metrics, results, reports, comparisons, thresholds
- `EvaluationRunner.swift`: Benchmark runner + `BaselineComparator` for regression detection
- `EvaluationFrameworkTests.swift`: 28 tests covering metric extraction, expectations, comparison, serialization, baseline scenarios
- Structured JSON output for comparison (ISO 8601, pretty-printed, round-trip verified)
- Comparison tool: `BaselineComparator` diffs two evaluation runs, flags regressions by configurable thresholds
- `BenchmarkTypes.swift`: Pipeline-level benchmark types — BenchmarkCase, BenchmarkExpectations (entities, relationships, predicates, evidence bounds, stages, tiers, grounding, completeness), BenchmarkMetrics (28 fields: latency, evidence, precision/recall, context quality, size, engine), BenchmarkResult, BenchmarkReport, BenchmarkSummary, BenchmarkThresholds
- `BenchmarkRunner.swift`: Full-pipeline benchmark runner (processChanges→retrieve→assemble→invoke with per-stage ContinuousClock timing), `runCorpus()` single-command entry point, BenchmarkComparator (reuses BaselineComparison), BenchmarkReportFormatter (Markdown with summary tables, category scores, total score, regressions/improvements, per-case detail)
- `BenchmarkCorpus.swift`: 22 canonical benchmark cases across 6 categories (entity discovery, relationships, cross-file, data flow/module, DI/architecture, edge cases). Auto-discovery via `allCases`, category filtering via `cases(for:)`, ID lookup via `findCase(id:)`. Progressive difficulty within each category.
- `BenchmarkSuiteTests.swift`: 42 tests across 10 suites — types, comparator, formatter, expectations, thresholds, JSON export, runner units, corpus integrity (uniqueness, coverage, ordering, naming), category scores, formatter category output

---

#### E1-02: Grounding Completeness Metric

- **Objective:** Measure the fraction of context frame units that are referenced in reasoning engine grounding claims.
- **Dependencies:** E1-01
- **Complexity:** S
- **Expected user impact:** None direct. Drives context precision improvements.
- **Status:** Complete (2026-07-28) — delivered as part of E1-01. `groundingCoverage` is a first-class metric in `EvaluationMetrics` and `BenchmarkMetrics`. `averageGroundingCoverage` aggregated in both summaries. `BaselineComparator` and `BenchmarkComparator` detect grounding regressions via configurable thresholds.

**Deliverables:**
- `EvaluationMetrics.groundingCoverage` and `BenchmarkMetrics.groundingCoverage`: precision = |referenced units| / |total units|
- `EvaluationSummary.averageGroundingCoverage` and `BenchmarkSummary.averageGroundingCoverage`: aggregation across entity set
- `BaselineComparator` and `BenchmarkComparator` threshold alerting on grounding regression
- Baseline precision value established via evaluation framework tests

---

#### E1-03: A/B Strategy Comparison

- **Objective:** Compare explanation quality between two context strategies (e.g., v2.0.0 vs v3.0.0) on the same entity set.
- **Dependencies:** E1-01, E1-02
- **Complexity:** S
- **Expected user impact:** None direct. Enables data-driven strategy tuning.
- **Status:** Later

**Deliverables:**
- Side-by-side evaluation: run two strategy versions on the same entity set
- Comparison metrics: evidence count delta, precision delta, prompt size delta
- Summary report

---

## Epic 2: Software Intelligence

**Purpose:** Complete the entity composition hierarchy (Entity → File → Module → System) and deliver system-scope understanding to explanations.

**Desired end state:** Decode understands an entire codebase as an architecture. Explanations include architectural framing — layers, dependency direction, module roles — grounded in DIR evidence.

**User value:** When a developer asks about code in a multi-module project, the explanation includes where the code fits architecturally: which layer, what depends on it, whether it's a boundary contract or an internal implementation.

**Success metrics:**
- System entity exists in the DIR for every indexed project
- System emergent properties are computed (dependency graph, direction, hubs)
- Explanations for module-boundary entities include architectural framing
- Single-module projects produce no system noise (suppression works)
- Explanation quality (per E1-01 baseline) improves for cross-module entities

### Backlog Items

#### E2-00: Module Intelligence Validation (M7)

- **Objective:** Verify that the complete M1–M6 stack produces measurably richer explanations for cross-file questions. This is the existing M7 milestone — the gate between Phase 1 and Phase 2.
- **Dependencies:** M1–M6 complete (verified)
- **Complexity:** S
- **Expected user impact:** Confirms that module-aware explanations work as intended. May reveal tuning adjustments needed.
- **Status:** Now

**Deliverables:**
- Process representative multi-file codebase through the pipeline
- Document: module observations appear in prompts for multi-file modules
- Document: suppression works for single-file modules
- Document: framing is woven naturally, not a separate section
- Tuning adjustments to suppression thresholds or budget fractions if needed
- `PROJECT_INTELLIGENCE_IMPLEMENTATION_STATUS.md` updated: M7 complete

**Validation criteria:**
- Cross-file information present in multi-file module explanations
- Single-file module explanations unchanged
- No pipeline module modifications
- No performance regression

---

#### E2-01: System Entity Creation

- **Objective:** Create a System entity in the DIR representing the entire codebase, composing over module entities.
- **Dependencies:** E2-00
- **Complexity:** M
- **Expected user impact:** Not directly user-facing. Enables E2-02 and E2-03.
- **Status:** Next

**Deliverables:**
- `SystemCompositionPass` in `Decode/App/` — T1 composition pass, `perSystem` scope
- System entity `system:<projectName>` with `kind=system`, structural metadata
- `contains:containment` from System → each Module
- Registration in `AppDependencies.performDeferredStartup()`
- Tests in `DecodeTests/Application/SystemCompositionPassTests.swift`

---

#### E2-02: System Emergent Properties

- **Objective:** Compute genuinely emergent system properties — dependency graph, dependency direction, module interaction map, hub modules, technology distribution.
- **Dependencies:** E2-01
- **Complexity:** M
- **Expected user impact:** Enables architectural framing in explanations.
- **Status:** Next

**Deliverables:**
- `SystemEmergentPropertiesPass` in `Decode/App/`
- Five emergent properties: `dependencyGraph`, `dependencyDirection`, `moduleInteractionMap`, `hubModules`, `technologyDistribution`
- Tests in `DecodeTests/Application/SystemEmergentPropertiesPassTests.swift`

---

#### E2-03: System Context and Observations

- **Objective:** Connect system knowledge to explanations via context assembly and observation layer.
- **Dependencies:** E2-02
- **Complexity:** L
- **Expected user impact:** Explanations include architectural framing for multi-module projects.
- **Status:** Next

**Deliverables:**
- `PipelineQueryService`: `explain/followup → .system`
- `RetrievalRuntime.gatherScopeEvidence()`: additive `if plan.scope >= .system` block
- `ContextStrategies.explain` superseded to v3.0.0 with system stratum
- `SystemObservations` in `ReasoningEngineSupport.swift`
- Suppression rules for system observations
- Reasoning engine integration
- Tests for system observation extraction, suppression, and prompt injection

---

#### E2-04: Architectural Layer Detection

- **Objective:** Identify architectural layers from module dependency direction. Assign layer predicates to module entities.
- **Dependencies:** E2-02
- **Complexity:** M
- **Expected user impact:** Explanations include layer identification: "This is in the Domain layer."
- **Status:** Later

**Deliverables:**
- `ArchitecturalLayerPass` in `Decode/App/` — T1 deterministic
- Layer assignment via topological sort of dependency DAG
- Cycle detection: modules in cycles get `layer: mixed`
- Tests with layered and non-layered dependency graphs

---

#### E2-05: Cross-Cutting Pattern Detection

- **Objective:** Identify structural patterns spanning modules — protocol bridges, coordinator patterns, DI roots.
- **Dependencies:** E2-02, E2-04
- **Complexity:** L
- **Expected user impact:** Explanations reference recurring codebase patterns.
- **Status:** Later

**Deliverables:**
- `PatternDetectionPass` in `Decode/App/` — T1
- Pattern types: protocol-implementation bridges, coordinator pattern, DI root
- Pattern entities with `kind:pattern`, contained by system entity
- Tests

---

## Epic 3: Context Intelligence

**Purpose:** Improve how evidence is gathered, selected, and assembled for the LLM — making context frames more precise, more relevant, and more efficiently compressed.

**Desired end state:** The context assembly pipeline is question-aware and scope-adaptive. Different questions get different retrieval strategies and different context budgets. Evidence is coherent across strata and compressed to the right abstraction level.

**User value:** Faster, more focused, more trustworthy explanations. Simple questions get fast answers. Complex questions get deeper evidence. Impact questions get caller information. The LLM receives exactly what it needs.

**Success metrics:**
- Grounding precision (E1-02) improves from baseline
- Prompt token count for module/system scope reduced by ≥30% via compression
- Impact/dependency follow-up questions produce evidence at traversal depth ≥3
- Context coherence: when observations reference entities, those entities appear in evidence

### Backlog Items

#### E3-01: Question-Aware Scope Selection

- **Objective:** Dynamically determine retrieval scope from entity properties instead of static purpose→scope mapping.
- **Dependencies:** E2-00
- **Complexity:** S
- **Expected user impact:** Faster explanations for simple entities. Richer evidence for cross-file entities.
- **Status:** Now

**Deliverables:**
- Scope selection logic in `PipelineQueryService` or `ScopeSelector` in `Decode/App/`
- Rules: 0 cross-file relationships → `.local`; public interface entity → `.module`; multi-module boundary → `.system` (after E2-03)
- Tests against known entity profiles

---

#### E3-02: Multi-Hop Relational Traversal

- **Objective:** Support configurable traversal depth in relational evidence, beyond hardcoded maxDepth 1–2.
- **Dependencies:** E2-00
- **Complexity:** S
- **Expected user impact:** Deep dependency chains produce complete evidence.
- **Status:** Next

**Deliverables:**
- `TraversalPlan` depth configurable per intent: explain→1, impact→3, dependencies→3, overview→2
- Budget-per-entity scaling for deeper traversal
- Tests for distance >2 evidence

---

#### E3-03: Inverse Relationship Index

- **Objective:** Enable efficient "what references this entity?" queries without DIR scan.
- **Dependencies:** None
- **Complexity:** M
- **Expected user impact:** "What calls this?" and "What would break?" produce complete answers.
- **Status:** Now

**Note:** This modifies IndexRuntime, a frozen pipeline module. The modification is strictly additive (new index entries, new query method). **An RFC per IAG-004 §21.3 is required.** The justification: inverse lookup is a retrieval capability gap that cannot be worked around at the application layer.

**Deliverables:**
- RFC document for IndexRuntime additive modification
- Graph Index: inverse index (target → sources) alongside forward index
- `IndexQuerying`: `queryGraphInverse(entity:predicate:)` or equivalent
- Incremental maintenance during `batchUpdate`
- Tests for inverse lookup completeness

---

#### E3-04: Containment-Based Scope Lookup

- **Objective:** Replace path-computation module lookup in `gatherScopeEvidence()` with containment graph traversal.
- **Dependencies:** E3-03
- **Complexity:** S
- **Expected user impact:** None direct. Enables uniform scope resolution for file/module/system.
- **Status:** Next

**Deliverables:**
- `gatherScopeEvidence()` refactored: containment graph traversal instead of string path operations
- System scope: file → module → system via containment chain
- Distance assignments preserved: file=1, module=2, system=3

---

#### E3-05: Abstraction-Level Context Compression

- **Objective:** Send higher-level observations instead of raw units for distant evidence when budget is tight.
- **Dependencies:** E2-03, E1-02
- **Complexity:** M
- **Expected user impact:** Broader context within same token budget. More architectural framing without noise.
- **Status:** Later

**Deliverables:**
- Compression policy: for evidence at distance ≥2, aggregate into observations
- Token reduction measurement: ≥30% for module/system scope
- Quality verification via evaluation harness

---

#### E3-06: Coherence-Aware Evidence Selection

- **Objective:** When observations reference specific entities, ensure at least one appears in the evidence.
- **Dependencies:** E2-03, E1-02
- **Complexity:** M
- **Expected user impact:** More trustworthy explanations. Claims about callers/implementors are backed by visible evidence.
- **Status:** Later

**Note:** May require RFC if it modifies ContextAssembly coherence constraints.

**Deliverables:**
- Cross-stratum coherence: observation-referenced entities get priority in relational stratum
- Uses existing coherence enforcement infrastructure (DDS-006 CFI-3)
- Precision metric improvement verified

---

## Epic 4: Knowledge Lifecycle

**Purpose:** Make the knowledge graph persistent, incremental, and fast — so the developer never waits for indexing and knowledge survives app restarts.

**Desired end state:** Opening a previously indexed project is near-instant. Single-file edits recompute only affected modules. The DIR persists across app restarts.

**User value:** Returning to a project is fast. Saving a file produces updated explanations quickly. The developer never sees "indexing..." for a project they've worked with before.

**Success metrics:**
- Previously indexed project reopens with <2s to first rich explanation
- Single-file edit triggers composition pass recomputation for 1 module, not all
- Snapshot persistence survives app restart with correct invalidation

### Backlog Items

#### E4-01: DIR Snapshot Persistence

- **Objective:** Persist the DIR across app restarts using the existing StorageEngine snapshot infrastructure.
- **Dependencies:** None
- **Complexity:** M
- **Expected user impact:** Returning to a previously opened project is fast.
- **Status:** Now

**Deliverables:**
- Shutdown: snapshot save via `StorageEngine`
- Startup: snapshot restore if checksum validates, mod-date comparison for changed files
- Snapshot location: `~/Library/Application Support/Decode/understanding/snapshot/`
- Invalidation on producer version mismatch
- Corruption handling: discard and full reindex

---

#### E4-02: Incremental Composition Pass Recomputation

- **Objective:** When a single file changes, recompute only the affected module's composition passes.
- **Dependencies:** E4-01
- **Complexity:** L
- **Expected user impact:** Faster updates after file edits in large projects.
- **Status:** Later

**Note:** May require RFC if it modifies UpdateEngine's `processChangeSet()` contract. If implementable as an internal optimization preserving the public contract, no RFC needed.

**Deliverables:**
- Change detection: identify affected module(s) from containment index
- Selective pass invocation for affected modules only
- Idempotency verification: selective output matches full recomputation
- Latency improvement: >50% for single-file updates in 200-file projects

---

## Epic 5: Product Intelligence

**Purpose:** Integrate Software Intelligence and Context Intelligence into user-facing product capabilities that make Decode's explanations competitive with or superior to state-of-the-art AI coding assistants.

**Desired end state:** Session Mode explanations draw on project-wide architectural understanding. The quality difference between Decode and a generic AI assistant is obvious and measurable.

**User value:** The developer gets the kind of answer a senior engineer would give — not just what the code does, but where it fits, what depends on it, and what would break if it changed.

**Success metrics:**
- Explanation quality (per E1-01) is measurably higher than file-only baseline across all entity types
- Module-boundary entities include cross-file information in >80% of explanations
- System-scope entities include architectural framing when relevant
- Grounding precision >70% (every claim traceable to DIR evidence)

### Backlog Items

#### E5-01: Purpose-Driven Context Strategies

- **Objective:** Register multiple context strategies per consumer purpose, selected by intent and entity characteristics.
- **Dependencies:** E2-03, E3-01
- **Complexity:** M
- **Expected user impact:** Impact questions get more relational evidence. Dependency questions get deeper traversal. Overview questions get broader scope.
- **Status:** Later

**Deliverables:**
- Strategy variants: `explain-impact`, `explain-dependencies`, `explain-overview`
- Strategy selection in `PipelineQueryService`: intent → strategy
- Registration at startup
- Tests verifying correct selection per intent

---

#### E5-02: Impact-Aware Improve Suggestions

- **Objective:** When the Improve feature suggests changes, include information about downstream impact from the relationship graph.
- **Dependencies:** E3-03, E2-03
- **Complexity:** M
- **Expected user impact:** Improve suggestions warn about downstream breakage: "Changing this signature affects 3 callers in 2 files."
- **Status:** Later

**Deliverables:**
- `ImproveReasoningEngine` extended: when improving a public-interface entity, include caller count and file locations from inverse index
- Impact observation injected only for entities with cross-file callers
- Tests

---

#### E5-03: Architectural Explanation Profiles

- **Objective:** When a developer asks about a module-boundary entity, the explanation naturally positions it in the project's architecture without a separate architecture section.
- **Dependencies:** E2-03, E2-04, E5-01
- **Complexity:** M
- **Expected user impact:** "This protocol is the AI abstraction boundary between Application and Infrastructure. 3 coordinators depend on it. Changing the contract affects the entire Application layer."
- **Status:** Later

**Deliverables:**
- System + layer observations combined in reasoning engine prompts
- Guidance directives for architectural framing
- Quality verification via evaluation harness

---

## Epic 6: Question Intelligence (Future)

**Purpose:** Enable Decode to understand the developer's question at a deep level — decomposing complex questions, planning evidence gathering, and orchestrating multi-strategy retrieval.

**Desired end state:** Decode handles questions that span multiple concerns ("How does data flow from the API endpoint to the database, and what error handling exists along the path?") by decomposing them into sub-questions, gathering evidence for each, and synthesizing a coherent answer.

**User value:** Developers can ask complex, multi-faceted questions and get comprehensive answers instead of partial ones.

**Success metrics:** Not yet defined. These are strategic capabilities for future planning.

**Status:** Future — not scheduled for implementation. Captured here for strategic alignment.

### Future Backlog Items

#### E6-01: Intent Classification from Question Content

- **Objective:** Classify question intent (explain / impact / dependencies / overview) from question text using lightweight heuristics.
- **Dependencies:** E2-00
- **Complexity:** S
- **Expected user impact:** Follow-up questions about callers and impact get appropriate retrieval strategies.
- **Status:** Future

---

#### E6-02: Question Decomposition

- **Objective:** Decompose complex questions into sub-questions that can be independently answered and synthesized.
- **Dependencies:** E6-01
- **Complexity:** L
- **Expected user impact:** Multi-faceted questions get comprehensive answers.
- **Status:** Future

---

#### E6-03: Evidence Planning

- **Objective:** Given a decomposed question, plan which retrieval strategies and scopes to use for each sub-question before executing retrieval.
- **Dependencies:** E6-02
- **Complexity:** L
- **Expected user impact:** More efficient retrieval — the system knows what evidence it needs before searching.
- **Status:** Future

---

#### E6-04: Retrieval Orchestration

- **Objective:** Execute multi-strategy retrieval plans — composing graph traversal, scope expansion, and (future) semantic search into a single evidence set.
- **Dependencies:** E6-03
- **Complexity:** L
- **Expected user impact:** Complex questions produce evidence from multiple retrieval paths, not just entity-anchored graph traversal.
- **Status:** Future

---

#### E6-05: Conceptual Search

- **Objective:** Enable retrieval by concept ("where is caching?") rather than by entity name, complementing structural graph retrieval.
- **Dependencies:** E6-04
- **Complexity:** L
- **Expected user impact:** Navigational questions that reference concepts rather than specific symbols get accurate answers.
- **Status:** Future

---

## Status Definitions

| Status | Meaning |
|--------|---------|
| **Now** | Start immediately. No unmet dependencies. |
| **Next** | Start when dependencies complete. Expected within current cycle. |
| **Later** | Scheduled but not imminent. Dependencies may still be in progress. |
| **Future** | Strategic. Not scheduled for implementation. |

---

## Summary Table

| ID | Name | Epic | Deps | Size | Status |
|----|------|------|------|------|--------|
| E1-01 | Explanation Quality Baseline | Evaluation | — | M | Now |
| E1-02 | Grounding Completeness Metric | Evaluation | E1-01 | S | Next |
| E1-03 | A/B Strategy Comparison | Evaluation | E1-01, E1-02 | S | Later |
| E2-00 | Module Intelligence Validation | Software Intel | — | S | Now |
| E2-01 | System Entity Creation | Software Intel | E2-00 | M | Next |
| E2-02 | System Emergent Properties | Software Intel | E2-01 | M | Next |
| E2-03 | System Context and Observations | Software Intel | E2-02 | L | Next |
| E2-04 | Architectural Layer Detection | Software Intel | E2-02 | M | Later |
| E2-05 | Cross-Cutting Pattern Detection | Software Intel | E2-02, E2-04 | L | Later |
| E3-01 | Question-Aware Scope Selection | Context Intel | E2-00 | S | Now |
| E3-02 | Multi-Hop Relational Traversal | Context Intel | E2-00 | S | Next |
| E3-03 | Inverse Relationship Index | Context Intel | — | M | Now |
| E3-04 | Containment-Based Scope Lookup | Context Intel | E3-03 | S | Next |
| E3-05 | Abstraction-Level Compression | Context Intel | E2-03, E1-02 | M | Later |
| E3-06 | Coherence-Aware Evidence Selection | Context Intel | E2-03, E1-02 | M | Later |
| E4-01 | DIR Snapshot Persistence | Knowledge Life | — | M | Now |
| E4-02 | Incremental Composition Recompute | Knowledge Life | E4-01 | L | Later |
| E5-01 | Purpose-Driven Context Strategies | Product Intel | E2-03, E3-01 | M | Later |
| E5-02 | Impact-Aware Improve Suggestions | Product Intel | E3-03, E2-03 | M | Later |
| E5-03 | Architectural Explanation Profiles | Product Intel | E2-03, E2-04 | M | Later |
| E6-01 | Intent Classification | Question Intel | E2-00 | S | Future |
| E6-02 | Question Decomposition | Question Intel | E6-01 | L | Future |
| E6-03 | Evidence Planning | Question Intel | E6-02 | L | Future |
| E6-04 | Retrieval Orchestration | Question Intel | E6-03 | L | Future |
| E6-05 | Conceptual Search | Question Intel | E6-04 | L | Future |

---

## Critical Path

```
E2-00 → E2-01 → E2-02 → E2-03 → E5-01
  Module     System     System      System     Purpose-Driven
  Validation Entity     Properties  Context    Strategies
```

This is the longest dependency chain. Every milestone on this path must complete before architecture-aware explanations reach the user.

---

## Recommended Execution Order: Next 3 Months

**Assumptions:** One primary engineer (Claude Code). Architectural review from ChatGPT on RFCs and design decisions. Continuous delivery — each completed item is merged to main.

### Sprint 1 (Week 1–2): Foundation

**Parallel:**
- **E2-00** Module Intelligence Validation (S) — the gate. Must pass before Phase 2.
- **E3-03** Inverse Relationship Index — RFC draft (S for RFC, M for implementation). Draft the RFC during E2-00 validation. Begin implementation if RFC is approved.
- **E4-01** DIR Snapshot Persistence (M) — fully independent. Immediate user value.

**Rationale:** Three independent workstreams, no blocking dependencies. E2-00 is the gate. E3-03 RFC can be reviewed while E2-00 runs. E4-01 delivers user value (fast project reopening) regardless of what happens with the other tracks.

### Sprint 2 (Week 3–4): Measurement + System Foundation

**Parallel:**
- **E1-01** Explanation Quality Baseline (M) — uses E2-00's validation work as a starting point. Captures the baseline before system-scope changes.
- **E2-01** System Entity Creation (M) — first Phase 2 milestone.
- **E3-01** Question-Aware Scope Selection (S) — independent, immediate product improvement.

**Rationale:** E1-01 establishes measurement before the system-scope work changes explanation quality. E2-01 begins the critical path. E3-01 is a quick win that improves explanations today.

### Sprint 3 (Week 5–6): System Properties + Retrieval

**Parallel:**
- **E2-02** System Emergent Properties (M) — continues critical path.
- **E3-03** Inverse Index implementation (M) — if RFC approved in Sprint 1.
- **E1-02** Grounding Completeness Metric (S) — quick extension to evaluation harness.

**Rationale:** Critical path continues. Inverse index unblocks E3-04 and future impact features. Grounding metric enables data-driven decisions for E2-03.

### Sprint 4 (Week 7–9): System Context (largest milestone)

**Primary:**
- **E2-03** System Context and Observations (L) — the critical path milestone that delivers architecture-aware explanations to users. This is the largest single milestone.

**Secondary (if capacity):**
- **E3-04** Containment-Based Scope Lookup (S) — clean up module lookup debt, enable uniform system scope.

**Rationale:** E2-03 is the payoff. It connects all the system-level knowledge to actual explanations. This is the milestone where users see architectural framing for the first time.

### Sprint 5 (Week 10–11): Context Quality + Layers

**Parallel:**
- **E3-02** Multi-Hop Relational Traversal (S) — deeper dependency chains.
- **E2-04** Architectural Layer Detection (M) — adds layer identification to module entities.
- **E1-03** A/B Strategy Comparison (S) — enables comparison of v2.0.0 vs v3.0.0 strategies.

**Rationale:** E2-03 is complete. Now improve the quality of what's delivered. Layers add meaningful product value. Multi-hop improves follow-up quality.

### Sprint 6 (Week 12–13): Product Integration

**Parallel:**
- **E5-01** Purpose-Driven Context Strategies (M) — intent-aware context assembly.
- **E3-05** Abstraction-Level Compression (M) — reduce token waste in system scope.

**Rationale:** The intelligence stack is built. Now optimize how it reaches the user. Purpose-driven strategies and compression make the difference between good and excellent explanations.

### 3-Month Outcome

At the end of 3 months, Decode will have:

1. **System-scope understanding** — system entities, emergent properties, architectural layers
2. **Architecture-aware explanations** — explanations include layer identification, dependency direction, module roles
3. **Persistent knowledge** — DIR survives app restart, reopening projects is fast
4. **Evaluation infrastructure** — quality baseline, grounding metric, strategy comparison
5. **Improved retrieval** — inverse index for caller queries, containment-based scope, multi-hop traversal
6. **Adaptive context** — scope selection based on entity characteristics, purpose-driven strategies
7. **Context compression** — broader context within the same token budget

**Items deferred to month 4+:**
- E2-05 Cross-Cutting Pattern Detection (L)
- E3-06 Coherence-Aware Evidence Selection (M)
- E4-02 Incremental Composition Recompute (L)
- E5-02 Impact-Aware Improve (M)
- E5-03 Architectural Explanation Profiles (M)
- Epic 6 Question Intelligence (Future)

---

## RFC Requirements

Two backlog items require modifications to frozen pipeline modules:

| Item | Module | Change | RFC Required |
|------|--------|--------|-------------|
| E3-03 | IndexRuntime | Additive inverse index + query method | Yes |
| E4-02 | UpdateEngine | Selective pass invocation optimization | Maybe (depends on whether public contract changes) |

RFC drafts should be prepared during Sprint 1 and reviewed before implementation begins.

---

## Rules

1. **Every completed item updates this file.** Change Status from Now/Next to a completion date.
2. **No item begins implementation without its dependencies complete.**
3. **Every item that touches explanation quality runs the evaluation harness (E1-01) before and after.**
4. **No frozen pipeline module is modified without an approved RFC.**
5. **Every item is merged to main individually.** No multi-week branches.
