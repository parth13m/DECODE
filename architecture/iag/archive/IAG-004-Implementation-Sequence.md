# IAG-004 — Implementation Sequence

| Field | Value |
|-------|-------|
| **Document** | IAG-004 |
| **Title** | Implementation Sequence |
| **Status** | Draft |
| **Version** | 0.2 |
| **Created** | 2026-06-28 |
| **Depends On** | IAG-001 (Module Architecture), IAG-002 (Technology Decisions), IAG-003 (Runtime Architecture), DDS-000 through DDS-009 (all frozen) |
| **Consumed By** | Implementation |

---

## Preamble: IAG Layer Definition

### Purpose of This Document

IAG-004 transforms the frozen engineering specifications into an executable implementation roadmap. IAG-001 defined module boundaries. IAG-002 selected technologies. IAG-003 specified runtime behavior. IAG-004 sequences the implementation of all eight modules, their test infrastructure, and their integration into the existing Decode application.

This document answers: **In what order should the modules be built, and what evidence proves each step is correct before the next begins?**

### Boundary with Other IAG Documents

- IAG-001 defines *what* the modules are, their dependency graph, and their protocol surfaces. IAG-004 does not redefine module boundaries.
- IAG-002 defines *which* technologies are used. IAG-004 does not make technology decisions.
- IAG-003 defines *how* the runtime behaves — actor placement, concurrency model, startup/shutdown sequencing. IAG-004 does not redefine runtime behavior.
- IAG-004 defines *when* each module is implemented relative to the others, and *what evidence* is required before advancing.

### What Must Never Appear in IAG-004

| Prohibited Content | Belongs In |
|-------------------|-----------|
| Module boundaries, dependency graph, protocol inventory | IAG-001 |
| Technology selection or constraints | IAG-002 |
| Actor placement, concurrency model, reentrancy policy | IAG-003 |
| DDS contract semantics or invariants | DDS documents |
| Method signatures, algorithms, data structures | Implementation |
| Timelines, staffing, sprint plans, deadlines | Project management |
| Source code of any kind | Implementation |

---

## 1. Implementation Philosophy

### 1.1 Bottom-Up Construction

The understanding pipeline is built bottom-up: foundation types first, then modules that depend only on the foundation, then modules that depend on those, and finally the composition root that wires everything together. This order is dictated by the acyclic dependency graph (IAG-001 §3) — a module cannot be compiled until every module it imports exists.

### 1.2 Compile-Before-Test, Test-Before-Integrate

Each module passes through three stages before it participates in cross-module work:

1. **Compile** — the module builds against its declared imports. The build system enforces that no undeclared imports exist.
2. **Test** — the module's unit tests pass, exercising its DDS contracts against mock dependencies from `UnderstandingTestSupport`.
3. **Integrate** — the module is connected to real dependencies and verified via integration tests.

A module that compiles but has no tests is not considered implemented. A module with passing unit tests but no integration verification is not considered integrated.

### 1.3 Vertical Slice Validation

At two points during implementation, the pipeline is validated end-to-end with a vertical slice — a single scenario that exercises the complete path from file change to consumer understanding. These slices prove that the module boundaries, protocol surfaces, and runtime architecture compose correctly. They are not feature-complete — they exercise one path through the system to validate architectural soundness.

### 1.4 No Forward References

No module is implemented against an interface that does not yet exist. If module A depends on a protocol defined in module B, module B's protocol definition must exist (even if module B's implementation is incomplete) before module A is implemented. DIRCore (Phase 1) defines all foundation protocols before any module that depends on them is started.

### 1.5 Incremental Verification

Every phase produces artifacts that are independently verifiable. Verification is objective: the build succeeds or fails, tests pass or fail, the strict concurrency checker reports or does not report violations. No phase exit criterion depends on subjective assessment.

---

## 2. Implementation Phases

Six phases, executed sequentially with parallel opportunities within phases. Each phase produces a verifiable milestone.

### Phase Overview

| Phase | Name | Modules | Purpose |
|-------|------|---------|---------|
| 1 | Foundation | DIRCore (M1), build system, UnderstandingTestSupport | Establish types, protocols, targets, and test infrastructure that all subsequent phases depend on |
| 2 | Leaf Modules | StorageEngine (M8), ProducerRuntime (M2), IndexRuntime (M3) | Build the three modules that depend only on DIRCore — the persistence, production, and indexing layers |
| 3 | Write Pipeline | UpdateEngine (M7) | Build the central coordinator that owns the DIR runtime and orchestrates the synchronous/deferred pipelines |
| 4 | Read Pipeline | RetrievalRuntime (M4), ContextAssembly (M5), ConsumerRuntime (M6) | Build the query path from evidence retrieval through context assembly to consumer understanding |
| 5 | System Integration | UnderstandingSystem (composition root) | Wire all modules together; implement startup/shutdown sequencing; validate end-to-end pipeline operation |
| 6 | Application Integration | AppDependencies wiring, file monitoring bridge | Connect the understanding pipeline to the existing Decode application; verify coexistence with existing features |

---

## 3. Phase 1: Foundation

### 3.1 Scope

**Build System Setup:**
- Add XcodeGen target entries for all 8 framework targets (IAG-001 §1: target types)
- Add XcodeGen target entries for all 9 test targets (IAG-001 §8: 8 unit + 1 integration)
- Add XcodeGen target entry for `UnderstandingTestSupport` framework (IAG-001 §9)
- Create directory structure per IAG-001 §5
- Configure inter-target dependencies matching IAG-001 §3 dependency graph
- Configure SPM package linkage per IAG-002 §11 cross-module technology usage matrix

**DIRCore (M1):**
- All value types: atomic unit record (10 fields), unit identity, epoch, status enum with valid transitions, tier enum with confidence bounds, supersession key, provenance, grounding reference
- All serialization contracts: write transaction request/result, status transition request, unit query result types
- All cross-module protocol definitions: `DIRReadAccess`, `DIRWriteAccess`, `EpochControl`, `DemandSignalSink`, `ChangeBatchObserver`
- Codable conformance on all types (IAG-002:TI-5 — conformance declared here, logic in StorageEngine)
- CryptoKit hash value type (IAG-002:TC-13)

**UnderstandingTestSupport:**
- Factory utilities: `makeUnit()`, `makeEpoch()`, `makeProvenance()` (IAG-001 §9)
- Initial mock set: `MockDIRReadAccess`, `MockDIRWriteAccess` (needed by Phase 2 modules)

### 3.2 Why This Phase Is First

DIRCore is the foundation module — every other module imports it (IAG-001 §3). No module can compile without DIRCore's types and protocols. The build system targets must exist before any module can be compiled as a separate framework. Test infrastructure must exist before any module can be tested.

**Prerequisites:** None. This is the first phase.

**Engineering risks reduced:** Validates that the 8-module architecture compiles as XcodeGen targets with the declared dependency graph. Catches dependency graph errors, SPM linkage issues, and strict concurrency violations in foundation types before any module implementation begins.

### 3.3 Entry Criteria

None — this is the starting phase.

### 3.4 Exit Criteria

| Criterion | Verification Method |
|-----------|-------------------|
| All 8 framework targets defined in `project.yml` | `xcodegen generate` succeeds |
| All 9 test targets + UnderstandingTestSupport defined | `xcodegen generate` succeeds |
| Inter-target dependencies match IAG-001 §3 exactly | Build each target individually — succeeds only with declared imports |
| Directory structure matches IAG-001 §5 | Directory tree inspection |
| DIRCore compiles with `SWIFT_STRICT_CONCURRENCY = complete` | `xcodebuild -scheme DIRCore` succeeds with zero warnings |
| All DIRCore value types are `Sendable` | Strict concurrency check (compile-time) |
| All cross-module protocols defined in DIRCore | Protocol inventory matches IAG-001 §4 DIRCore-defined protocols |
| `DIRCoreTests` pass | Unit tests for value type construction, status transitions, tier-confidence bounds, Codable round-trip |
| `UnderstandingTestSupport` compiles | `xcodebuild -scheme UnderstandingTestSupport` succeeds |
| Negative build test: a module that should not import another fails to build if the import is added | Verified once for at least one disallowed import pair |

### 3.5 Milestone

**M1: Foundation Verified.** The understanding pipeline's type system, protocol contracts, build targets, and test infrastructure exist and compile under strict concurrency. All subsequent phases can begin work.

### 3.6 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `project.yml` updates | All target definitions, dependencies, SPM linkage |
| `Decode/Understanding/DIRCore/` | Complete type and protocol source files |
| `UnderstandingTests/DIRCoreTests/` | Unit tests for DIRCore types |
| `UnderstandingTests/UnderstandingTestSupport/` | Factory utilities + initial mocks |

---

## 4. Phase 2: Leaf Modules

### 4.1 Scope

Three modules implemented in this phase. All three depend only on DIRCore (Phase 1). None depends on any other — they are independent and may be implemented in parallel.

**StorageEngine (M8):**
- `StorageActor` (IAG-003 §2: owned state — grounding dependency map, content hash map, in-progress GC state, snapshot write state)
- Protocol conformances: `SnapshotPersistence`, `GarbageCollector`, `GroundingMapAccess`, `ContentHashMapAccess`, `DeferredQueuePersistence`, `ChangeBatchObserver`
- Snapshot capture and loading via Codable + atomic file I/O (IAG-002:TD-7)
- Content hash tracking via CryptoKit SHA-256 (IAG-002:TD-8)
- Grounding dependency map: construction from unit store, incremental maintenance
- GC: retention policy, safety invariant enforcement, scheduling readiness
- State model: Created → Loading → MapBuilding → Operational → Quiescing → Terminated (DDS-008)
- os.Logger with category `"storage"` (IAG-003 §8)

**ProducerRuntime (M2):**
- `ProducerActor` (IAG-003 §2.2: owned state — registry, DAG, per-invocation lifecycle, prior output records)
- Protocol conformances: `ProducerRegistry`, `ExecutionDirective`, `FailureReportSource`
- Internal protocols for DDS-003 pass contracts (IAG-001 §10 traceability)
- DAG construction with cycle detection (DDS-001:R2)
- Execution ticket processing with topological ordering
- Concurrent same-level pass execution via TaskGroup (IAG-002:TC-5, IAG-003 §2.2)
- Changed output detection (DDS-003:PC-3)
- Pass cancellation via Task.cancel() with cooperative polling (IAG-003 §6.1)
- Output validation (DDS-001:R4)
- Failure isolation between producers (DDS-001:R6)
- State model: Empty → Ready → Executing → Quiescing → Terminated (DDS-001)
- os.Logger with category `"producer"` (IAG-003 §8)

**IndexRuntime (M3):**
- `IndexActor` (IAG-003 §2.3: owned state — five index families, per-family availability, in-progress rebuild copies)
- Protocol conformances: `IndexQuerying`, `IndexFreshness`, `IndexBatchUpdate`
- Five index families: Entity, Graph (bidirectional), Predicate, Content, Scope
- Per-family availability state machine: Absent → Building → Available → Rebuilding (DDS-004)
- Initial construction from DIR scan via `DIRReadAccess`
- Incremental maintenance from change batches
- Structural index update ordering: Entity/Graph → Scope/Predicate → Content deferred (DDS-004 update ordering)
- DIR scan fallback for unavailable families (DDS-004:RI-6)
- Content index deferred update queue (DDS-004:RI-8 — max one epoch behind)
- Construction priority order: Entity → Graph → Scope → Predicate → Content (DDS-004)
- State model: Uninitialized → Building → Operational → Quiescing → Terminated (DDS-004)
- os.Logger with category `"index"` (IAG-003 §8)

**UnderstandingTestSupport Expansion:**
- Add remaining mocks needed for Phase 2 testing: `MockIndexQuerying`, `MockIndexFreshness`, `MockIndexBatchUpdate`, `MockEvidenceRetrieval`, `MockContextAssembling`, `MockDemandSignalSink`, `MockChangeBatchObserver`, `MockProducerExecution`, `MockSnapshotPersistence`, `MockGarbageCollector`, `MockGroundingMapAccess`, `MockContentHashMapAccess`

### 4.2 Why This Phase Is Second

These three modules sit at the same level in the dependency graph — they depend only on DIRCore (IAG-001 §3 topological order: level 2). They cannot be built before DIRCore exists (Phase 1). They must be built before UpdateEngine (Phase 3), which imports all three.

**Prerequisites:** Phase 1 complete. DIRCore types, protocols, and build targets exist.

**Engineering risks reduced:**
- **StorageEngine**: Validates that Codable serialization round-trips all DIRCore types correctly. Catches schema issues before the unit store (UpdateEngine) depends on snapshot loading.
- **ProducerRuntime**: Validates that the DAG construction, topological execution, and pass lifecycle work in isolation. Catches execution model issues before the UpdateEngine orchestrates producers.
- **IndexRuntime**: Validates that all five index families can be constructed, queried, and incrementally maintained. Catches index consistency issues before the read pipeline depends on indexed queries.
- **All three**: Validates that actor isolation compiles under strict concurrency for real mutable state (not just DIRCore value types).

### 4.3 Entry Criteria

| Criterion | Source |
|-----------|--------|
| Phase 1 exit criteria fully satisfied | Phase 1 verification |
| DIRCore types and protocols importable by M2, M3, M8 | Build system configuration |
| `UnderstandingTestSupport` provides `MockDIRReadAccess` and `MockDIRWriteAccess` | Phase 1 deliverable |

### 4.4 Exit Criteria

| Criterion | Verification Method |
|-----------|-------------------|
| `StorageEngine` compiles with strict concurrency | `xcodebuild -scheme StorageEngine` zero warnings |
| `StorageEngineTests` pass | Snapshot round-trip, GC safety invariant, grounding map construction, content hash tracking, state machine transitions (valid and invalid) |
| `ProducerRuntime` compiles with strict concurrency | `xcodebuild -scheme ProducerRuntime` zero warnings |
| `ProducerRuntimeTests` pass | DAG construction and cycle rejection, topological execution order, pass lifecycle transitions, changed output detection, cancellation (cooperative + forced), output validation (valid and invalid), failure isolation between concurrent passes |
| `IndexRuntime` compiles with strict concurrency | `xcodebuild -scheme IndexRuntime` zero warnings |
| `IndexRuntimeTests` pass | All 5 family construction, per-family availability transitions, incremental batch update (create/invalidate/supersede/GC), structural index consistency after batch, content index deferred update, DIR scan fallback for unavailable families, construction priority ordering |
| All Phase 2 mocks added to `UnderstandingTestSupport` | Mock inventory matches IAG-001 §9 |
| No `@unchecked Sendable` without documented justification | Code inspection per IAG-003 §10.3 |

### 4.5 Parallel Work Opportunities

StorageEngine, ProducerRuntime, and IndexRuntime are fully independent. They share no imports beyond DIRCore, no shared test doubles beyond `MockDIRReadAccess`/`MockDIRWriteAccess`, and no build dependencies on each other. All three may be implemented concurrently.

UnderstandingTestSupport mock expansion can proceed incrementally as each module's protocol surface is implemented.

### 4.6 Milestone

**M2: Leaf Modules Verified.** The persistence layer (StorageEngine), production layer (ProducerRuntime), and indexing layer (IndexRuntime) are independently implemented, tested, and compiling under strict concurrency. The write pipeline coordinator (UpdateEngine) can now be built against real module interfaces.

### 4.7 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `Decode/Understanding/StorageEngine/` | Complete StorageActor implementation with all protocol conformances |
| `Decode/Understanding/ProducerRuntime/` | Complete ProducerActor implementation with internal pass protocols |
| `Decode/Understanding/IndexRuntime/` | Complete IndexActor implementation with five index families |
| `UnderstandingTests/StorageEngineTests/` | Unit tests |
| `UnderstandingTests/ProducerRuntimeTests/` | Unit tests |
| `UnderstandingTests/IndexRuntimeTests/` | Unit tests |
| `UnderstandingTests/UnderstandingTestSupport/` | Complete mock inventory |

---

## 5. Phase 3: Write Pipeline

### 5.1 Scope

**UpdateEngine (M7):**
- `UpdateActor` (IAG-003 §2.1: owned state — unit store, epoch counter, unit identity counter, change set queue, deferred queue, within-cycle visibility buffer)
- DIR Runtime implementation within UpdateEngine (IAG-001 §2: DDS-002 runtime colocated with DDS-007):
  - Unit store: admission, status transitions, identity resolution
  - Intake validation: provenance (PV-1 through PV-3), tier enforcement (TE-1 through TE-5) (DDS-002)
  - Epoch management: advancement, committed epoch query, within-cycle visibility
  - Write transaction atomicity (DDS-002:PC-6)
- Synchronous pipeline: content-hash filtering → frontend re-execution → entity comparison → direct invalidation → cascade propagation → synchronous recomputation → index update → epoch advancement (DDS-007 8-stage pipeline)
- Deferred T2 pipeline: queue management, committed-epoch reads, collision detection on commit (IAG-003 §5.2)
- Protocol conformances: `DIRReadAccess`, `DIRWriteAccess`, `EpochControl` (internal), `DemandSignalSink`
- Protocol consumption: `ExecutionDirective`, `ProducerRegistry`, `FailureReportSource` (from ProducerRuntime); `IndexBatchUpdate` (from IndexRuntime); `SnapshotPersistence`, `GarbageCollector`, `GroundingMapAccess`, `ContentHashMapAccess`, `DeferredQueuePersistence`, `ChangeBatchObserver` (from StorageEngine)
- Change event aggregation (DDS-007 concurrency model)
- GC trigger dispatching (DDS-008:GC-3 — never during synchronous pipeline)
- Sequential change set processing enforcement (DDS-007 R9 / IAG-003 §7)
- Reconciliation on startup (DDS-007:PC-4)
- State model: Created → Reconciling → Idle → Processing → Quiescing → Terminated (DDS-007)
- os.Logger with category `"update-engine"` (IAG-003 §8)

### 5.2 Why This Phase Is Third

UpdateEngine imports ProducerRuntime, IndexRuntime, and StorageEngine (IAG-001 §3). All three must exist before UpdateEngine can compile. UpdateEngine is the most complex module — it coordinates the entire write path. Building it after its dependencies are individually verified means that failures during Phase 3 are attributable to UpdateEngine's coordination logic, not to bugs in its dependencies.

**Prerequisites:** Phase 2 complete. All three leaf modules compile, pass unit tests, and conform to their protocols.

**Engineering risks reduced:**
- **DIR runtime correctness**: Validates intake validation, write transaction atomicity, epoch advancement, and within-cycle visibility in isolation from the read pipeline. These are the hardest invariants to debug once the full pipeline is running.
- **Pipeline coordination**: Validates that the 8-stage synchronous pipeline correctly dispatches to ProducerActor and IndexActor via async protocol calls. Catches actor reentrancy issues (IAG-003 §17) early.
- **Deferred pipeline**: Validates collision detection (discard on unit invalidation during recomputation) before consumer demand signals add scheduling complexity.

### 5.3 Entry Criteria

| Criterion | Source |
|-----------|--------|
| Phase 2 exit criteria fully satisfied | Phase 2 verification |
| `StorageEngine` protocol conformances available | Phase 2 deliverable |
| `ProducerRuntime` protocol conformances available | Phase 2 deliverable |
| `IndexRuntime` protocol conformances available | Phase 2 deliverable |
| `UpdateEngineTests` has mock dependencies from `UnderstandingTestSupport` | Phase 2 deliverable |

### 5.4 Exit Criteria

| Criterion | Verification Method |
|-----------|-------------------|
| `UpdateEngine` compiles with strict concurrency | `xcodebuild -scheme UpdateEngine` zero warnings |
| DIR Runtime: intake validation rejects invalid units | Tests for PV-1 through PV-3, TE-1 through TE-5 |
| DIR Runtime: write transaction atomicity | Test that partial-batch validation failure rejects entire batch |
| DIR Runtime: epoch advances after synchronous pipeline completion | Test epoch value before/after pipeline |
| DIR Runtime: within-cycle visibility serves committed + current-cycle writes to producers | Test read during pipeline execution |
| DIR Runtime: consumer reads observe committed epoch only | Test read during pipeline returns prior epoch state |
| Synchronous pipeline: content-hash filtering skips unchanged files | Test with unchanged hash |
| Synchronous pipeline: entity comparison detects added/removed/modified entities | Tests for each case |
| Synchronous pipeline: cascade propagation follows tier order (T0 → T1 → T2 deferred) | Test cascade reaches correct units at each tier |
| Synchronous pipeline: unchanged output terminates cascade branch | Test cascade termination |
| Synchronous pipeline: index update delivered before epoch advancement | Test ordering |
| Deferred pipeline: reads committed epoch, not in-progress writes | Test deferred read isolation |
| Deferred pipeline: discards result if unit invalidated during recomputation | Test collision detection |
| Sequential processing: second change set blocked until first completes | Test sequential enforcement |
| Change event aggregation: events during processing are batched | Test aggregation |
| GC trigger: never during synchronous pipeline | Test GC deferral |
| Reconciliation: validates deferred queue, reprocesses pending changes | Test startup reconciliation |
| State machine: all valid and invalid transitions | Test state model |
| `UpdateEngineTests` pass — all above | Test suite |
| No `@unchecked Sendable` without documented justification | Code inspection |

### 5.5 Milestone

**M3: Write Pipeline Verified.** The complete write path — from file change event through intake validation, cascade propagation, synchronous recomputation, index update, and epoch advancement — operates correctly. The DIR runtime maintains its invariants under the synchronous and deferred pipelines. The read pipeline (Phase 4) can now build against a functional DIR.

### 5.6 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `Decode/Understanding/UpdateEngine/` | Complete UpdateActor implementation: DIR runtime + pipeline coordination |
| `UnderstandingTests/UpdateEngineTests/` | Unit tests covering all exit criteria |

---

## 6. Phase 4: Read Pipeline

### 6.1 Scope

Three modules implemented sequentially within this phase. The build dependency chain (IAG-001 §3) requires this order: RetrievalRuntime → ContextAssembly → ConsumerRuntime.

**RetrievalRuntime (M4):**
- No actor — stateless (IAG-003 §1.2)
- Five-stage evidence retrieval pipeline (DDS-005)
- Anchor resolution
- Protocol conformance: `EvidenceRetrieval`
- Protocol consumption: `IndexQuerying`, `IndexFreshness` (from IndexRuntime), `DIRReadAccess` (from DIRCore, implemented by UpdateEngine)
- Committed epoch capture at pipeline start (DDS-005:RC-3)
- State model: Unavailable → Available → Terminated (DDS-005)
- os.Logger with category `"retrieval"` (IAG-003 §8)

**ContextAssembly (M5):**
- No actor — stateless (IAG-003 §1.2)
- Strategy catalog: built-in strategies populated at startup, read-only during requests
- Context frame assembly with stratum selection, coherence enforcement, budget enforcement, elision
- Protocol conformances: `ContextAssembling`, `StrategyManagement`
- Protocol consumption: `EvidenceRetrieval` (from RetrievalRuntime)
- State model: Unavailable → Available → Terminated (DDS-006)
- os.Logger with category `"context-assembly"` (IAG-003 §8)

**ConsumerRuntime (M6):**
- `ConsumerActor` (IAG-003 §2.4: owned state — reasoning engine registry, conversation state, demand deduplication)
- Six-phase consumer invocation lifecycle (DDS-009): validation → engine resolution → reasoning → grounding verification → confidence verification → understanding production
- Reasoning engine registry with fallback designation
- Grounding verification: ungrounded claims removed (DDS-009:UC-1, GP-1)
- Confidence capping: inflated confidence capped to tier-appropriate level (DDS-009:CP-2)
- Conversation state management with boundedness enforcement (DDS-009:CL-4 through CL-6)
- Demand signal emission via `DemandSignalSink` (fire-and-forget, deduplicated)
- Consumer composition: sequential and parallel (DDS-009:COMP-1 through COMP-4)
- Protocol conformances: `ConsumerInvocation`, `ReasoningEngineManagement`
- Protocol consumption: `ContextAssembling` (from ContextAssembly), `DemandSignalSink` (from DIRCore, implemented by UpdateEngine)
- State model: Unavailable → Available → Terminated (DDS-009)
- os.Logger with category `"consumer"` (IAG-003 §8)

### 6.2 Why This Phase Is Fourth

RetrievalRuntime imports IndexRuntime (Phase 2). ContextAssembly imports RetrievalRuntime. ConsumerRuntime imports ContextAssembly. The chain must be built in this order. The read pipeline cannot be verified until the write pipeline (Phase 3) provides a functional DIR to read from — integration tests in Phase 5 will use UpdateEngine to populate state that the read pipeline queries.

Building the read pipeline after the write pipeline ensures that the data the read pipeline consumes (units, epochs, indexes) is correctly produced. Debugging a read-path failure against a verified write path is tractable; debugging both simultaneously is not.

**Prerequisites:** Phase 3 complete. UpdateEngine provides functional `DIRReadAccess` and `DemandSignalSink`. IndexRuntime provides `IndexQuerying` and `IndexFreshness` (from Phase 2).

**Engineering risks reduced:**
- **RetrievalRuntime**: Validates the five-stage pipeline against mock indexes and mock DIR reads before end-to-end integration. Catches evidence assembly bugs before they compound with context assembly logic.
- **ContextAssembly**: Validates strategy resolution, budget enforcement, and coherence constraints against mock evidence before real evidence sets add complexity.
- **ConsumerRuntime**: Validates grounding verification, confidence capping, and conversation management against mock context frames before real context assembly output is involved.

### 6.3 Entry Criteria

| Criterion | Source |
|-----------|--------|
| Phase 3 exit criteria fully satisfied | Phase 3 verification |
| `DIRReadAccess` implemented and tested in UpdateEngine | Phase 3 deliverable |
| `IndexQuerying`, `IndexFreshness` available from IndexRuntime | Phase 2 deliverable |
| `DemandSignalSink` implemented in UpdateEngine | Phase 3 deliverable |

### 6.4 Exit Criteria

| Criterion | Verification Method |
|-----------|-------------------|
| `RetrievalRuntime` compiles with strict concurrency | `xcodebuild -scheme RetrievalRuntime` zero warnings |
| `RetrievalRuntimeTests` pass | Five-stage pipeline with mock indexes, anchor resolution, committed epoch capture, budget enforcement, fallback on unavailable family, empty evidence handling |
| `ContextAssembly` compiles with strict concurrency | `xcodebuild -scheme ContextAssembly` zero warnings |
| `ContextAssemblyTests` pass | Strategy resolution, stratum selection, coherence enforcement, budget enforcement, elision, context frame production with mock evidence |
| `ConsumerRuntime` compiles with strict concurrency | `xcodebuild -scheme ConsumerRuntime` zero warnings |
| `ConsumerRuntimeTests` pass | Engine registration/deregistration, engine resolution (including fallback), grounding verification (grounded/ungrounded/all-ungrounded), confidence capping, conversation state management (including corruption recovery and boundedness enforcement), demand signal emission with deduplication, consumer composition (sequential and parallel), resource budget exhaustion |
| All three modules: no `@unchecked Sendable` without documented justification | Code inspection |

### 6.5 Milestone

**M4: Read Pipeline Verified.** The complete read path — from evidence retrieval through context assembly to consumer understanding — operates correctly against mock dependencies. The system is ready for full integration.

### 6.6 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `Decode/Understanding/RetrievalRuntime/` | Complete stateless retrieval implementation |
| `Decode/Understanding/ContextAssembly/` | Complete stateless assembly implementation |
| `Decode/Understanding/ConsumerRuntime/` | Complete ConsumerActor implementation |
| `UnderstandingTests/RetrievalRuntimeTests/` | Unit tests |
| `UnderstandingTests/ContextAssemblyTests/` | Unit tests |
| `UnderstandingTests/ConsumerRuntimeTests/` | Unit tests |

---

## 7. Phase 5: System Integration

### 7.1 Scope

**UnderstandingSystem Composition Root:**
- `UnderstandingSystem` at `Decode/App/UnderstandingSystem.swift` (IAG-001 §6)
- Construction: create all 8 module instances in dependency order (IAG-001 §6 ownership chain)
- Wiring: inject protocol-typed dependencies via constructor injection (IAG-001 §7, IAG-003 §16)
- Startup sequencing: 10-step startup per IAG-003 §4.1, including concurrent MapBuilding + IndexConstruction, reconciliation
- Shutdown sequencing: 8-step shutdown per IAG-003 §4.2, following DDS destruction ordering
- Lifecycle entry points: `start()` and `shutdown()` for AppDependencies to call
- Runtime invariant enforcement: singleton UpdateActor (IAG-003 RI-1), total startup ordering (IAG-003 RI-5), total shutdown ordering (IAG-003 RI-6)

**Vertical Slice — Write Path:**
- File change → content hash comparison → frontend execution → entity comparison → invalidation → cascade → recomputation → index update → epoch advancement → snapshot
- Exercises: UpdateEngine ↔ ProducerRuntime ↔ IndexRuntime ↔ StorageEngine with real implementations

**Vertical Slice — Read Path:**
- Consumer invocation → engine resolution → context assembly → evidence retrieval → index query → DIR read → understanding production
- Exercises: ConsumerRuntime → ContextAssembly → RetrievalRuntime → IndexRuntime → UpdateEngine (via DIRReadAccess)

**Vertical Slice — Write-Then-Read:**
- File change processed through write pipeline → consumer query observes updated state
- Exercises: epoch advancement visibility, no partially committed runtime visibility (IAG-003 RI-7)

**Integration Tests:**
- `UnderstandingIntegrationTests` target (IAG-001 §8: TR-4, TR-5)
- Cross-module contract verification with real implementations (not mocks)
- Startup and shutdown sequencing correctness
- Write pipeline end-to-end with real actors
- Read pipeline end-to-end with real actors
- Write-then-read epoch visibility
- Deferred T2 pipeline with collision
- Demand signal round-trip: consumer → UpdateEngine → deferred recomputation

### 7.2 Why This Phase Is Fifth

The composition root imports every module (IAG-001 §6). All modules must exist. Integration tests verify that protocol counterparties work together with real implementations — this requires all implementations to be complete and individually verified.

Building integration after unit-tested modules means that integration failures expose wiring and cross-actor interaction bugs, not module-internal bugs. The module-internal bugs were caught in Phases 2–4.

**Prerequisites:** Phases 1–4 complete. All 8 modules compile, pass unit tests, and conform to their protocols.

**Engineering risks reduced:**
- **Composition root**: Validates that dependency injection wiring matches IAG-001 §7 injection rules. Catches missing dependencies, wrong protocol conformance injection, or construction ordering errors.
- **Startup/shutdown**: Validates the 10-step startup and 8-step shutdown sequences from IAG-003 §4. Catches race conditions in concurrent MapBuilding + IndexConstruction, and ordering violations in shutdown.
- **Cross-actor interaction**: Validates that real actors interacting across `await` boundaries behave correctly under reentrancy (IAG-003 §17). Unit tests with mocks cannot catch actor reentrancy bugs that emerge from real async interactions.
- **Epoch visibility**: Validates IAG-003 RI-7 (no partially committed runtime visibility) with a write-then-read scenario that would expose any visibility gap.

### 7.3 Entry Criteria

| Criterion | Source |
|-----------|--------|
| Phases 1–4 exit criteria fully satisfied | Phase 1–4 verification |
| All 8 modules compile independently | Build system |
| All 8 unit test suites pass | Test runner |
| All mocks in `UnderstandingTestSupport` implemented | Phase 2 deliverable |

### 7.4 Exit Criteria

| Criterion | Verification Method |
|-----------|-------------------|
| `UnderstandingSystem` compiles in application target | Build succeeds |
| Startup sequencing: all actors reach operational state in correct order | Integration test with state transition assertions |
| Shutdown sequencing: all actors reach terminated state in DDS destruction order | Integration test with state transition assertions |
| Concurrent startup: MapBuilding and IndexConstruction proceed concurrently | Integration test (verified by timing or interleaving observation) |
| Write vertical slice: file change → epoch advancement | Integration test end-to-end |
| Read vertical slice: consumer invocation → understanding produced | Integration test end-to-end |
| Write-then-read: consumer query after write observes updated state | Integration test epoch visibility |
| Deferred T2 collision: deferred result discarded when unit invalidated during recomputation | Integration test |
| Demand signal round-trip: consumer emits → UpdateEngine receives → deferred recomputation scheduled | Integration test |
| No `@MainActor` in any understanding pipeline module | Code inspection per IAG-003 §6.3 |
| `UnderstandingIntegrationTests` pass — all above | Test suite |

### 7.5 Milestone

**M5: System Integrated.** The understanding pipeline operates as a complete system. All modules are wired, startup/shutdown sequences are verified, and end-to-end vertical slices pass. The pipeline is ready to be connected to the existing Decode application.

### 7.6 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `Decode/App/UnderstandingSystem.swift` | Composition root with lifecycle entry points |
| `UnderstandingTests/UnderstandingIntegrationTests/` | Integration test suite |

---

## 8. Phase 6: Application Integration

### 8.1 Scope

**AppDependencies Integration:**
- `AppDependencies` creates and owns `UnderstandingSystem` instance
- `UnderstandingSystem.start()` called from `performDeferredStartup()` (CLAUDE.md: deferred startup via `didBecomeActiveNotification`)
- `UnderstandingSystem.shutdown()` called during application teardown
- `ConsumerInvocation` exposed to application layer for consumer queries

**File System Monitoring Bridge:**
- Connect existing `FileWatcherService` (Infrastructure/FileSystem) to UpdateEngine
- DispatchSource → debounced events → AsyncStream<FileChangeEvent> → UpdateActor consumption (IAG-003 §7)
- 300ms debounce window (IAG-002:TD-6)
- Session file events route to understanding pipeline when sessions are active

**Coexistence Verification:**
- Existing File Intelligence features (selection mode, screenshot mode, session mode) continue functioning
- Existing explanation, follow-up, and improvement flows are unaffected
- Understanding pipeline operates alongside existing features without interference
- No `@MainActor` usage in understanding pipeline causes UI thread contention

### 8.2 Why This Phase Is Last

Application integration touches the existing Decode codebase. Any bug introduced here affects existing shipping features. By deferring application integration until the understanding pipeline is a verified, self-contained system (Phase 5), the integration surface is narrow: one composition root instance in AppDependencies, one file monitoring bridge, and one consumer invocation protocol exposed to the application layer.

**Prerequisites:** Phase 5 complete. UnderstandingSystem verified end-to-end as a standalone system.

**Engineering risks reduced:**
- **Regression**: Existing features are verified to still work after the understanding pipeline is connected. Catching regressions here (Phase 6) rather than during module implementation (Phases 2–4) means the regression has a single cause: the integration wiring, not the module logic.
- **Startup contention**: Validates that the understanding pipeline's deferred startup does not cause activation timeout (CLAUDE.md: "Never do startup work in `init()` or SwiftUI body").
- **File monitoring routing**: Validates that session file events reach the understanding pipeline without disrupting the existing `FileWatcherService` consumers.

### 8.3 Entry Criteria

| Criterion | Source |
|-----------|--------|
| Phase 5 exit criteria fully satisfied | Phase 5 verification |
| UnderstandingSystem operates as standalone system | Phase 5 integration tests pass |
| Existing Decode test suite passes without understanding pipeline | Baseline test run |

### 8.4 Exit Criteria

| Criterion | Verification Method |
|-----------|-------------------|
| Application builds with understanding pipeline integrated | `xcodebuild -scheme Decode` succeeds |
| `UnderstandingSystem.start()` called from `performDeferredStartup()` | Code inspection |
| `UnderstandingSystem.shutdown()` called during app teardown | Code inspection |
| File monitoring bridge delivers events to UpdateEngine | Integration test or manual verification |
| Existing selection mode works | Manual test: highlight code → double-tap Control → HUD appears with explanation |
| Existing screenshot mode works | Manual test: double-tap Option → drag-select → HUD appears |
| Existing session mode works | Manual test: ⌃⇧O → open file → double-tap Shift → explanation |
| Existing follow-up and improve features work | Manual test |
| No activation timeout on cold start | Manual test: launch app → verify responsive within 3 seconds |
| All existing `DecodeTests` pass | Test runner |
| All `UnderstandingIntegrationTests` pass with app integration | Test runner |

### 8.5 Milestone

**M6: Application Integrated.** The understanding pipeline is fully connected to the Decode application. File changes flow through the pipeline, consumer queries produce understandings, and all existing features continue to function. Implementation is complete.

### 8.6 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `Decode/App/AppDependencies.swift` modifications | UnderstandingSystem ownership and lifecycle |
| File monitoring bridge | DispatchSource → AsyncStream integration |
| Regression verification | Existing feature test results |

---

## 9. Dependency Graph Between Phases

### 9.1 Phase Dependency Diagram

```
Phase 1: Foundation
    │
    ▼
Phase 2: Leaf Modules ──────────────────────────┐
    │ (StorageEngine, ProducerRuntime,           │
    │  IndexRuntime — all parallel)              │
    ▼                                            │
Phase 3: Write Pipeline ─────────────────────────┤
    │ (UpdateEngine — requires all 3 leaf        │
    │  modules)                                  │
    ▼                                            │
Phase 4: Read Pipeline                           │
    │ (RetrievalRuntime → ContextAssembly →      │
    │  ConsumerRuntime — sequential chain)       │
    ▼                                            │
Phase 5: System Integration ◄────────────────────┘
    │ (requires ALL modules)
    ▼
Phase 6: Application Integration
    │ (requires verified standalone system)
    ▼
  COMPLETE
```

### 9.2 Dependency Table

| Phase | Depends On | Blocking Reason |
|-------|-----------|-----------------|
| 1 | — | Starting phase |
| 2 | 1 | Requires DIRCore types, protocols, build targets |
| 3 | 2 | Requires ProducerRuntime, IndexRuntime, StorageEngine protocol conformances |
| 4 | 3 | Requires UpdateEngine's `DIRReadAccess` for integration testing; requires Phase 2's IndexRuntime for RetrievalRuntime imports |
| 5 | 1, 2, 3, 4 | Requires all 8 modules to exist for composition root and integration tests |
| 6 | 5 | Requires verified standalone system before touching existing application |

### 9.3 Why Phase 4 Depends on Phase 3

Phase 4 modules (RetrievalRuntime, ContextAssembly, ConsumerRuntime) do not import UpdateEngine at the build level. RetrievalRuntime imports DIRCore and IndexRuntime (both from Phases 1–2). ContextAssembly imports RetrievalRuntime. ConsumerRuntime imports ContextAssembly.

However, Phase 4 has a *logical* dependency on Phase 3: the read pipeline's unit tests use `MockDIRReadAccess`, but meaningful integration testing requires a real `DIRReadAccess` implementation — which is UpdateEngine. While Phase 4 modules can *compile* after Phase 2, they cannot be *integration-tested* without Phase 3.

For maximum parallelism, Phase 4 module implementation (not integration testing) may begin after Phase 2 completes, using mocks. But Phase 4 is not considered *complete* until Phase 3 provides a real `DIRReadAccess` for integration verification. The phase ordering reflects the completion dependency, not the start dependency.

---

## 10. Critical Path

The critical path is the longest sequence of dependent work items where no parallelism reduces the total duration:

```
Phase 1 → Phase 2 (longest leaf module) → Phase 3 → Phase 4 (M4 → M5 → M6) → Phase 5 → Phase 6
```

### 10.1 Critical Path Items

| Item | Blocking Reason |
|------|-----------------|
| Phase 1: DIRCore + build system | Everything depends on it |
| Phase 2: ProducerRuntime (longest leaf module — DAG construction, execution lifecycle, pass contracts, cancellation, output validation) | UpdateEngine cannot start without it |
| Phase 3: UpdateEngine (most complex module — DIR runtime + pipeline coordination) | Read pipeline integration requires it; system integration requires it |
| Phase 4: ConsumerRuntime (end of read chain — M4 → M5 → M6 sequential) | System integration requires complete read pipeline |
| Phase 5: UnderstandingSystem + integration tests | Application integration requires verified standalone system |
| Phase 6: AppDependencies integration | Definition of complete |

### 10.2 Critical Path Risk

UpdateEngine (Phase 3) is the highest-risk item on the critical path. It is the largest module, implements the most complex DDS contracts (DDS-002 + DDS-007), and coordinates all other actors. If UpdateEngine requires more implementation effort than expected, the entire critical path extends.

**Mitigation:** UpdateEngine's complexity is bounded by design — it coordinates via protocol calls to other actors, and each coordination step is individually verified in Phase 2 unit tests. The DIR runtime (intake validation, epoch management, write transactions) is the novel implementation within UpdateEngine; the pipeline coordination is primarily dispatch-and-await sequences.

---

## 11. Parallel Work Opportunities

### 11.1 Within Phase 2

StorageEngine, ProducerRuntime, and IndexRuntime are fully independent. They can be implemented by parallel work streams with zero coordination overhead — they share no source files, no test files, and no build dependencies beyond DIRCore.

### 11.2 Phase 4 Module Implementation During Phase 3

RetrievalRuntime and ContextAssembly can begin implementation (not completion) during Phase 3, since they depend only on DIRCore and IndexRuntime (Phase 2). Unit tests with mocks can be written and run while UpdateEngine is being built. ConsumerRuntime can begin after ContextAssembly's protocol surface is defined, even if ContextAssembly's full implementation is incomplete.

Phase 4 is not *complete* until Phase 3 is complete (integration testing requires UpdateEngine), but module implementation overlaps with Phase 3.

### 11.3 UnderstandingTestSupport

Mock expansion can proceed incrementally throughout Phases 2–4. Each new protocol implementation generates a corresponding mock. This work has no critical path dependency — it progresses as side-effect of module implementation.

### 11.4 Summary

| Parallel Opportunity | Phases | Constraint |
|---------------------|--------|------------|
| StorageEngine ∥ ProducerRuntime ∥ IndexRuntime | Within Phase 2 | All must complete before Phase 3 starts |
| Phase 4 module implementation ∥ Phase 3 | Phases 3–4 | Phase 4 completion requires Phase 3 complete |
| Mock expansion ∥ module implementation | Throughout | Mocks evolve with protocols |

---

## 12. Verification Gates

A verification gate is the checkpoint between phases. No work from the next phase may begin (except where §11 explicitly permits parallel start) until the gate is passed. Gate passage is binary — all criteria met or not.

| Gate | Between Phases | Gate Criteria |
|------|---------------|---------------|
| **G1** | 1 → 2 | All Phase 1 exit criteria (§3.4) satisfied. DIRCore compiles, all targets exist, test infrastructure operational. |
| **G2** | 2 → 3 | All Phase 2 exit criteria (§4.4) satisfied. All three leaf modules compile, unit tests pass, mock inventory complete. |
| **G3** | 3 → 4 | All Phase 3 exit criteria (§5.4) satisfied. UpdateEngine compiles, all pipeline tests pass, DIR runtime invariants verified. |
| **G4** | 4 → 5 | All Phase 4 exit criteria (§6.4) satisfied. All read pipeline modules compile, unit tests pass. |
| **G5** | 5 → 6 | All Phase 5 exit criteria (§7.4) satisfied. Integration tests pass, vertical slices verified, startup/shutdown correct. |
| **G6** | 6 → complete | All Phase 6 exit criteria (§8.4) satisfied. Application builds, existing features work, no regressions. |

---

## 13. Required Deliverables Per Milestone

| Milestone | Deliverables | Verification |
|-----------|-------------|--------------|
| **M1: Foundation Verified** | `project.yml` with all targets; `DIRCore/` source; `DIRCoreTests/`; `UnderstandingTestSupport/` with factories and initial mocks | Builds pass; tests pass; strict concurrency clean |
| **M2: Leaf Modules Verified** | `StorageEngine/` source + tests; `ProducerRuntime/` source + tests; `IndexRuntime/` source + tests; complete mock inventory | All 3 modules build; all unit tests pass |
| **M3: Write Pipeline Verified** | `UpdateEngine/` source + tests | Module builds; all pipeline tests pass; DIR runtime invariants verified |
| **M4: Read Pipeline Verified** | `RetrievalRuntime/` source + tests; `ContextAssembly/` source + tests; `ConsumerRuntime/` source + tests | All 3 modules build; all unit tests pass |
| **M5: System Integrated** | `UnderstandingSystem.swift`; `UnderstandingIntegrationTests/` | Composition root builds; integration tests pass; vertical slices verified |
| **M6: Application Integrated** | `AppDependencies.swift` modifications; file monitoring bridge; regression verification results | Application builds; existing features work; integration tests pass |

---

## 14. Integration Checkpoints

Integration checkpoints are points where modules first interact with real (not mock) dependencies. They differ from verification gates: gates are between phases; checkpoints are within or between phases where cross-module integration is first validated.

| Checkpoint | When | What Is Verified |
|------------|------|-----------------|
| **IC-1: StorageEngine ↔ DIRCore types** | Phase 2 | Codable round-trip of all DIRCore types through StorageEngine serialization |
| **IC-2: ProducerRuntime ↔ DIRCore protocols** | Phase 2 | ProducerActor correctly uses MockDIRReadAccess and MockDIRWriteAccess through protocol interface |
| **IC-3: UpdateEngine ↔ ProducerRuntime** | Phase 3 | UpdateActor dispatches execution tickets to real ProducerActor; receives execution results |
| **IC-4: UpdateEngine ↔ IndexRuntime** | Phase 3 | UpdateActor delivers change batches to real IndexActor; structural indexes update correctly |
| **IC-5: UpdateEngine ↔ StorageEngine** | Phase 3 | UpdateActor triggers snapshot via real StorageActor; change batch notification delivered |
| **IC-6: RetrievalRuntime ↔ IndexRuntime** | Phase 5 | RetrievalRuntime queries real IndexActor; receives evidence from real indexes |
| **IC-7: ConsumerRuntime ↔ UpdateEngine** | Phase 5 | ConsumerActor reads from real DIRReadAccess; demand signals reach real DemandSignalSink |
| **IC-8: End-to-end write → read** | Phase 5 | Write pipeline populates DIR; read pipeline queries and returns correct understanding |
| **IC-9: Application ↔ UnderstandingSystem** | Phase 6 | AppDependencies creates, starts, and shuts down UnderstandingSystem correctly |
| **IC-10: FileWatcherService ↔ UpdateEngine** | Phase 6 | File system events reach UpdateActor via AsyncStream bridge |

---

## 15. Testing Strategy

### 15.1 Testing Levels

| Level | Scope | When Written | Mock Policy |
|-------|-------|-------------|-------------|
| **Unit tests** | Single module in isolation | During module implementation (Phases 2–4) | All cross-module dependencies mocked via `UnderstandingTestSupport` |
| **Contract tests** | Protocol counterparty verification | During integration (Phase 5) | Real implementations for both sides of each protocol |
| **Integration tests** | Multi-module interaction | During integration (Phase 5) | Real implementations; no mocks |
| **Vertical slice tests** | End-to-end pipeline path | During integration (Phase 5) | Real implementations for the full path |
| **Regression tests** | Existing feature preservation | During app integration (Phase 6) | Existing test suite + manual verification |

### 15.2 Test Coverage Requirements

| Module | Required Test Coverage |
|--------|----------------------|
| DIRCore | Value type construction, Sendable verification (compile-time), status transition validation (valid + invalid), tier-confidence bound enforcement, Codable round-trip for all types |
| StorageEngine | Snapshot round-trip, atomic write (interrupt simulation), GC safety invariant, grounding map construction and incremental update, content hash tracking, state machine transitions |
| ProducerRuntime | DAG construction and cycle detection, topological execution order, concurrent same-level execution, pass lifecycle (all transitions), changed output detection, cancellation (cooperative + forced), output validation, failure isolation |
| IndexRuntime | All 5 family construction, per-family availability, incremental batch update (all change types), structural consistency, content index deferral, DIR scan fallback, construction priority |
| UpdateEngine | All Phase 3 exit criteria (§5.4) — intake validation, write transaction atomicity, epoch management, all 8 synchronous pipeline stages, deferred pipeline, collision detection, change event aggregation, GC scheduling, reconciliation, state machine |
| RetrievalRuntime | Five-stage pipeline, anchor resolution, epoch capture, budget enforcement, unavailable family fallback |
| ContextAssembly | Strategy resolution, stratum selection, coherence, budget, elision, context frame assembly |
| ConsumerRuntime | Engine management, six-phase invocation lifecycle, grounding verification, confidence capping, conversation management, demand signaling, composition |
| Integration | Startup/shutdown ordering, write vertical slice, read vertical slice, write-then-read epoch visibility, deferred collision, demand signal round-trip |

### 15.3 Test Infrastructure Rules

- All tests are `async` when testing cross-module protocol calls (IAG-002:TC-15)
- Test doubles follow IAG-001 §9 rules: configurable, call-recording, success-path defaults
- No test imports a module that the module under test does not import (IAG-001:TR-2)
- Integration tests import all modules and use real implementations (IAG-001:TR-4, TR-5)

---

## 16. Refactoring Policy During Implementation

### 16.1 Permitted Refactoring

Refactoring within a single module's implementation is permitted at any time during the module's implementation phase, provided:

1. The module's public protocol conformances are preserved — no protocol method signature changes without updating all consumers.
2. The module's unit tests continue to pass after the refactoring.
3. No new dependencies are introduced (see §17).

### 16.2 Cross-Module Refactoring

Refactoring that changes a cross-module protocol signature requires:

1. Updating the protocol definition in the owning module (DIRCore for foundation protocols, the upstream module for others).
2. Updating all implementations of the protocol.
3. Updating all consumers of the protocol.
4. Updating all mock implementations in `UnderstandingTestSupport`.
5. Verifying that all affected test suites pass.

Cross-module refactoring should be minimized. If a protocol surface requires frequent changes, the protocol was under-specified — revisit IAG-001 §4 to determine whether the protocol boundary is correctly placed.

### 16.3 Prohibited Refactoring

| Prohibition | Reason |
|-------------|--------|
| Changing the module set (adding, removing, or merging modules) | Requires IAG-001 amendment |
| Changing the dependency graph (adding an import between modules) | Requires IAG-001 amendment |
| Changing actor placement (making a stateless module an actor, or vice versa) | Requires IAG-003 amendment |
| Changing the startup/shutdown sequence | Requires IAG-003 amendment |
| Restructuring XcodeGen target configuration | Requires IAG-001 amendment |

If implementation reveals that any of these changes is necessary, the finding is documented and the relevant IAG is amended before the change is made. IAG amendments require explicit approval.

---

## 17. Rules for Introducing New Dependencies

### 17.1 Intra-Pipeline Dependencies

No new import between understanding pipeline modules may be introduced during implementation. The dependency graph is frozen in IAG-001 §3. If a module needs functionality from a module it does not import, the dependency must be satisfied through:

1. Protocol indirection via DIRCore (the existing pattern for cross-graph communication).
2. Moving shared types to DIRCore (if they satisfy DIRCore's content test — used by more than one module).
3. Passing the required data through existing protocol parameters.

### 17.2 External Dependencies

No new third-party dependency may be introduced during implementation beyond those specified in IAG-002 §5. The technology decisions are frozen. If implementation reveals a need for a technology not covered by IAG-002, the finding is documented and IAG-002 is amended before the dependency is introduced.

### 17.3 Platform SDK Dependencies

Platform SDK APIs (Foundation, os, CryptoKit) may be used within modules per the usage matrix in IAG-002 §11. No module may use a platform SDK API that IAG-002 §11 does not allocate to it. For example, ProducerRuntime may use URLSession (IAG-002 §11 allocates it); IndexRuntime may not.

---

## 18. Definition of "Implementation Complete"

Implementation is complete when all of the following are true:

| Criterion | Verification |
|-----------|-------------|
| All 8 framework targets compile under `SWIFT_STRICT_CONCURRENCY = complete` with zero warnings | Build system |
| All 8 unit test suites pass | Test runner |
| All integration tests pass | Test runner |
| Write vertical slice passes end-to-end | Integration test |
| Read vertical slice passes end-to-end | Integration test |
| Write-then-read epoch visibility verified | Integration test |
| `UnderstandingSystem` startup completes without error | Integration test |
| `UnderstandingSystem` shutdown completes in DDS destruction order | Integration test |
| Application builds with understanding pipeline integrated | Build system |
| Existing Decode features function without regression | Manual verification + existing test suite |
| No `@MainActor` in any understanding pipeline module (M1–M8) | Code inspection |
| No `@unchecked Sendable` without documented justification | Code inspection |
| No understanding pipeline module imports GRDB | Build system (IAG-002:TI-3) |
| No framework-specific types in cross-module protocol signatures | Code inspection (IAG-002:TI-2) |
| No framework-specific error types cross module boundaries | Code inspection (IAG-002:TI-4) |
| Every cross-module protocol from IAG-001 §4 has a real implementation | Code inspection |
| Every cross-module protocol from IAG-001 §4 has a mock in `UnderstandingTestSupport` | Code inspection |
| `project.yml` regeneration succeeds | `xcodegen generate` |

Implementation complete does not mean "all DDS contracts are fully exercised by real producers and real data." It means the pipeline infrastructure — modules, actors, protocols, wiring, startup, shutdown — is operational and can accept real producers and reasoning engines. Populating the pipeline with domain-specific producers, index families, and reasoning engines is product development work that uses the pipeline, not pipeline implementation work.

---

## 19. Traceability: Implementation Milestones to DDS and IAG

### 19.1 Milestone-to-DDS Traceability

| Milestone | DDS Contracts Verified |
|-----------|----------------------|
| **M1: Foundation** | DDS-002 types: unit record fields, status transitions, tier-confidence bounds, supersession key, epoch, provenance, grounding. Protocol surfaces for DDS-002:PC-1 through PC-6 defined. |
| **M2: Leaf Modules** | DDS-008: snapshot capture/load (PC-1, PC-2), GC (PC-3), grounding map (PC-4), content hash (PC-5), deferred queue (PC-6), state model. DDS-001: registration (PC-1), DAG (PC-2, PC-3), execution (PC-5, PC-9), failure (PC-6), state model. DDS-003: pass invocation (PC-1), input assembly (PC-2), changed output (PC-3), cancellation (PC-4). DDS-004: index query (PC-1), rebuild (PC-2), freshness (PC-3), batch update (PC-4), state model, all 5 families. |
| **M3: Write Pipeline** | DDS-002: unit admission (PC-1), status transition (PC-2), read access (PC-3), epoch advancement (PC-4), identity resolution (PC-5), write transaction (PC-6), intake validation (R2), immutability (R3), all 5 failure modes. DDS-007: change detection (R1), invalidation cascade (R2), synchronous pipeline (R4), deferred pipeline (R5), epoch advancement (R7), sequential processing (R9), reconciliation (PC-4), change event aggregation, scheduling priorities, all 6 failure modes, state model. |
| **M4: Read Pipeline** | DDS-005: evidence retrieval (PC-1), anchor resolution (PC-2), epoch capture (RC-3), five-stage pipeline, state model. DDS-006: context assembly (PC-1), strategy management (PC-2, PC-3), budget enforcement (R3), state model. DDS-009: consumer invocation (PC-1), engine management (PC-2, PC-3), demand signal (PC-4), grounding verification (UC-1, GP-1), confidence verification (CP-2), conversation management (CL-4 through CL-6), composition (COMP-1 through COMP-4), state model. |
| **M5: System Integration** | Cross-subsystem contracts: DDS-007:PC-5 ↔ DDS-001:PC-9 (execution tickets), DDS-007:PC-9 ↔ DDS-004:PC-4 (index batch update), DDS-008:PC-11 ↔ DDS-007 (change batch notification), DDS-009:PC-4 ↔ DDS-007:PC-2 (demand signals), DDS-005:PC-3 ↔ DDS-004:PC-1 (index query). Startup sequence (DDS-008 → DDS-002 → DDS-001 → DDS-004 → DDS-005 → DDS-006 → DDS-009 → DDS-007 reconciliation). Shutdown sequence (DDS-009 destruction ordering). |
| **M6: Application Integration** | DDS-007:R1 (change detection — file monitoring integration). Full pipeline operational with real file system events. |

### 19.2 Milestone-to-IAG Traceability

| Milestone | IAG Sections Realized |
|-----------|----------------------|
| **M1: Foundation** | IAG-001 §1 (repository topology), §2 (module decomposition — M1), §3 (dependency graph targets), §4 (protocol ownership — DIRCore protocols), §5 (directory layout), §8 (test target organization), §9 (test infrastructure). IAG-002 §7 (TC-1, TC-2 — Sendable, strict concurrency). |
| **M2: Leaf Modules** | IAG-001 §2 (M2, M3, M8 modules), §4 (protocol conformances for leaf modules), §5 (directory layout for leaf modules), §7 (DI — constructor injection with protocol-typed parameters). IAG-002 §5 (TD-3, TD-4 — SwiftSyntax/TreeSitter in M2; TD-7, TD-8 — Codable/SHA-256 in M8). IAG-003 §2.2, §2.3, §2.4 (actor specifications for ProducerActor, IndexActor, StorageActor — note: §2.4 is ConsumerActor, covered in M4). |
| **M3: Write Pipeline** | IAG-001 §2 (M7 module — DDS-007 + DDS-002 runtime combination). IAG-003 §2.1 (UpdateActor specification), §5 (data flow patterns), §7 (file system monitoring), §9 (performance considerations), §15 RI-1 through RI-3 (runtime invariants). |
| **M4: Read Pipeline** | IAG-001 §2 (M4, M5, M6 modules). IAG-003 §1.2 (RetrievalRuntime and ContextAssembly — no actor), §2.4 (ConsumerActor specification), §3 (async protocol surface — EvidenceRetrieval, ContextAssembling, ConsumerInvocation). |
| **M5: System Integration** | IAG-001 §6 (composition root), §7 (DI strategy — injection rules IR-1 through IR-5). IAG-003 §4 (startup/shutdown sequencing), §15 (runtime invariants RI-4 through RI-7), §16 (cross-actor dependency rule), §17 (reentrancy policy verification). |
| **M6: Application Integration** | IAG-003 §7 (file monitoring integration), §6.3 (@MainActor prohibition enforcement). CLAUDE.md integration requirements (deferred startup, accessibility gating). |

---

## 20. Rollback Policy

### 20.1 Verification Gate Failure

If any verification gate (§12, G1–G6) fails, the following rules apply without exception:

**Rule 1: Return to the owning phase.** Implementation returns to the phase whose exit criteria failed. The failed gate is not passed. No downstream phase may begin or continue work that depends on the failed gate's guarantees.

**Rule 2: Downstream work does not continue.** Work in phases beyond the failed gate is suspended. Artifacts produced by downstream phases during permitted parallel work (§11) are not discarded, but they are not considered verified and must be re-validated after the gate is cleared.

**Rule 3: Fix at the earliest defective phase.** The defect is corrected in the earliest phase that introduced it — not in the phase where it was detected. If a Phase 3 (UpdateEngine) integration test reveals that a Phase 2 module (ProducerRuntime) has an incorrect protocol conformance, the fix is applied to ProducerRuntime (Phase 2), not worked around in UpdateEngine (Phase 3).

**Rule 4: No downstream patching for upstream defects.** Downstream modules are never modified to compensate for an upstream defect. If DIRCore's type definitions are incomplete (Phase 1), the fix is additional types in DIRCore — not ad-hoc type definitions in the consuming module. If a leaf module's protocol conformance has incorrect behavior (Phase 2), the fix is in the leaf module — not defensive code in UpdateEngine that tolerates the incorrect behavior.

### 20.2 Rationale

The phase ordering exists because each phase's correctness is a prerequisite for the next. Patching a downstream phase to compensate for an upstream defect creates a hidden dependency between the patch and the defect — the downstream code now relies on the upstream module being broken in a specific way. When the upstream defect is eventually corrected, the downstream patch breaks. This is strictly worse than fixing the defect at its source immediately.

### 20.3 Re-Verification After Rollback

After a defect is corrected:

1. The owning phase's exit criteria are re-verified in full — not just the criterion that failed.
2. All downstream phases that had begun work re-run their exit criteria against the corrected upstream.
3. The verification gate is re-evaluated. Passage requires all criteria met, as before.

---

## 21. Architecture Freeze During Implementation

### 21.1 Freeze Scope

Once implementation begins (Phase 1 work starts), the following documents are frozen:

| Document Layer | Frozen Documents | Modification Path |
|---------------|-----------------|-------------------|
| DAS | All DAS documents | DAS amendment (out of scope for implementation) |
| DDS | DDS-000 through DDS-009 | DDS amendment (out of scope for implementation) |
| IAG | IAG-001, IAG-002, IAG-003, IAG-004 | Explicit RFC (see §21.3) |

Frozen means: the document's contents are authoritative. Implementation conforms to the documents. The documents do not conform to implementation.

### 21.2 Implementation Bugs Are Corrected in Code

When implementation does not match the frozen architecture, the implementation is wrong. The fix is always in the code:

| Scenario | Correct Response | Incorrect Response |
|----------|-----------------|-------------------|
| A module cannot satisfy a DDS contract as specified | Fix the implementation to satisfy the contract | Amend the DDS to match the implementation |
| A protocol surface from IAG-001 is awkward to implement | Implement the protocol as specified | Change the protocol to be more convenient |
| An actor boundary from IAG-003 creates unexpected complexity | Implement the actor as specified; document the complexity | Remove the actor to reduce complexity |
| A technology constraint from IAG-002 causes friction | Work within the constraint | Relax the constraint |

If repeated implementation difficulty suggests that a specification is genuinely incorrect (not merely inconvenient), the finding is documented and escalated via the RFC process (§21.3). The implementation continues to conform to the frozen specification until the RFC is approved.

### 21.3 Architectural Modification Requires Explicit RFC

Any modification to a frozen document requires a Request for Change (RFC) that includes:

1. **Which document and section** is proposed for modification.
2. **What the current specification says** (exact text).
3. **What the proposed modification is** (exact replacement text).
4. **Why the current specification is incorrect** — not inconvenient, not suboptimal, but incorrect. The specification produces a system that does not satisfy a DAS invariant, violates a DDS contract, or contains an internal contradiction.
5. **What implementation evidence** demonstrates the incorrectness — a failing test, a provable violation, or a contradiction identified during implementation.
6. **What downstream impact** the modification has on other frozen documents.

The RFC is reviewed and approved before any code is written against the modified specification. Implementation continues against the current frozen specification until the RFC is approved.

### 21.4 Implementation Convenience Is Never a Valid Reason

The following are not valid reasons for architectural modification:

| Invalid Reason | Why It Is Invalid |
|---------------|-------------------|
| "The protocol surface would be simpler with fewer methods" | IAG-001 protocol surfaces were designed to realize specific DDS contracts. Simplification may drop a contract. |
| "This module would be easier to implement if it could import another module" | IAG-001 dependency graph prevents cycles and enforces isolation. Adding an import may create a cycle or violate isolation. |
| "The actor creates unnecessary overhead for this module" | IAG-003 actor placement was determined by mutable state ownership. Removing an actor removes isolation of that state. |
| "This technology constraint is too restrictive" | IAG-002 constraints exist to satisfy DDS responsibilities. Relaxing a constraint may break a DDS contract. |
| "The phase ordering is too conservative" | IAG-004 phase ordering reduces engineering risk. Reordering may allow upstream defects to propagate undetected. |

If a specification is genuinely incorrect — not just inconvenient — the RFC process exists to correct it. But the bar for "incorrect" is objective evidence of a violation or contradiction, not subjective preference for a different design.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-06-28 | Initial draft. Six implementation phases, dependency graph, critical path analysis, parallel work opportunities, verification gates, integration checkpoints, testing strategy, refactoring policy, dependency introduction rules, definition of complete, full DDS and IAG traceability. |
| 0.2 | 2026-06-28 | CTO review revisions: (1) Added §20 Rollback Policy — four rules for verification gate failure: return to owning phase, suspend downstream, fix at earliest defective phase, no downstream patching. Includes re-verification procedure after rollback. (2) Added §21 Architecture Freeze During Implementation — DAS/DDS/IAG frozen once implementation starts, bugs corrected in code not specifications, architectural modifications require explicit RFC with objective evidence of incorrectness, implementation convenience explicitly excluded as valid modification reason. |
