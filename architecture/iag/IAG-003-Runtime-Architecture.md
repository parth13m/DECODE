# IAG-003 — Runtime Architecture

| Field | Value |
|-------|-------|
| **Document** | IAG-003 |
| **Title** | Runtime Architecture |
| **Status** | Draft |
| **Version** | 0.3 |
| **Created** | 2026-06-28 |
| **Depends On** | IAG-001 (Module Architecture), IAG-002 (Technology Decisions), DDS-000 through DDS-009 (all frozen) |
| **Consumed By** | IAG-004 (Implementation Sequence) |

---

## Preamble: IAG Layer Definition

### Purpose of This Document

IAG-003 specifies how Swift Concurrency is applied to the eight understanding pipeline modules defined in IAG-001. IAG-002 selected Swift Concurrency as the concurrency framework and deferred the question of *how it is applied* to this document. IAG-003 answers that question.

For each module, this document specifies:

- **Actor placement** — which types are actors, which are plain structs/classes
- **Isolation boundary** — what state is protected by each actor
- **Async surface** — which protocol methods are async and why
- **Cancellation propagation** — how DDS-defined cancellation contracts map to Swift Task cancellation
- **Data flow** — how values move across module boundaries without shared mutable state

Every statement in this document must be verifiable by inspecting the module graph, actor declaration, or protocol signature — never by reading logic.

### Boundary with IAG-002

IAG-002 selects technologies. IAG-003 applies them. The boundary:

- IAG-002 says "Swift Concurrency" — IAG-003 says "the `UpdateEngine` module's unit store is an `actor`"
- IAG-002 says "structured concurrency for parallelizable pipeline work" — IAG-003 says "the synchronous pipeline stage uses `TaskGroup` to execute independent-tier passes concurrently"
- IAG-002 says "async/await for cross-module protocols" — IAG-003 specifies which protocols are async and which are synchronous

### What Must Never Appear in IAG-003

| Prohibited Content | Belongs In |
|-------------------|-----------|
| DDS contract semantics (what a subsystem must do) | DDS documents |
| Technology selection rationale (why Swift Concurrency) | IAG-002 |
| Method signatures with parameter names and types | Implementation |
| Algorithm selection (e.g., Kahn's for topological sort) | Implementation |
| Data structure choice (e.g., Dictionary vs. sorted array) | Implementation |
| Test assertions or test code | Implementation |
| Any restatement of a DDS invariant | DDS documents |

---

## 1. Isolation Architecture Overview

### 1.1 Design Principle

Every module has exactly one isolation boundary: a single actor that owns all mutable state within that module. Modules that are genuinely stateless (DDS-defined) use no actor — they are collections of synchronous or async functions operating on value types.

A module's actor is never imported directly by other modules. Other modules interact through the protocols defined in IAG-001 §4. Protocol methods that cross an actor boundary are `async`. Protocol methods that do not cross a concurrency boundary are synchronous.

### 1.2 Module Isolation Map

| Module | Actor Type | Actor Name | Mutable State Owned |
|--------|-----------|------------|---------------------|
| M1 `DIRCore` | None | — | No runtime state (types and protocols only) |
| M2 `ProducerRuntime` | Actor | `ProducerActor` | Pass DAG, registry, producer execution state, prior output records |
| M3 `IndexRuntime` | Actor | `IndexActor` | Five index families, per-family availability state |
| M4 `RetrievalRuntime` | None | — | Stateless (DDS-005: no persistent state) |
| M5 `ContextAssembly` | None | — | Stateless (DDS-006: strategy catalog is session-scoped; no assembly state survives requests) |
| M6 `ConsumerRuntime` | Actor | `ConsumerActor` | Reasoning engine registry, conversation state, demand signal deduplication state |
| M7 `UpdateEngine` | Actor | `UpdateActor` | DIR unit store, epoch counter, unit identity counter, change set processing queue, deferred recomputation queue, synchronous pipeline state |
| M8 `StorageEngine` | Actor | `StorageActor` | Grounding dependency map, content hash map, in-progress GC state, snapshot write state |

### 1.3 Rationale for Each Isolation Decision

**M1 DIRCore — No actor.** DIRCore contains only value types, enums, and protocol definitions. All instances are either immutable value types or protocol-typed references injected from outside. No mutable state requires protection.

**M2 ProducerRuntime — Actor.** The pass DAG is mutated during producer registration (DDS-001:PC-1) and must not be read concurrently with structural changes. Execution state (which producers are currently executing, per-invocation lifecycle) is mutable and shared between the producer orchestration logic and the timeout enforcement path. Prior output records (DDS-003) are session-scoped mutable state. One actor serializes all DAG mutations and prior-record updates while permitting concurrent reads via actor re-entrancy on non-mutating paths.

**M3 IndexRuntime — Actor.** Five index families each have independent availability state (Absent → Building → Available → Rebuilding). Family updates must not race with queries against the same family. The actor serializes family state transitions. Per DDS-004:SC-4, consumer queries during sequential family updates observe the prior committed epoch — the actor boundary enforces this by making all queries and updates go through the same actor, enabling the actor to route queries to the consistent snapshot until all families are updated.

**M4 RetrievalRuntime — No actor.** DDS-005 explicitly declares no persistent state and no index modifications. The retrieval request captures the committed epoch once at the start (DDS-005:RC-3) and all subsequent operations are read-only. A stateless async function set handles the five-stage pipeline without shared mutable state.

**M5 ContextAssembly — No actor.** DDS-006 declares the strategy catalog as session-scoped and assembly state as non-persistent. The strategy snapshot bound at phase 2 of assembly is an immutable value captured per-request. All assembly operations are pure transformation of immutable evidence sets. The strategy catalog is populated at startup and treated as read-only during request handling. No concurrency protection is required.

**M6 ConsumerRuntime — Actor.** The reasoning engine registry is mutable (engines are registered and deregistered). Demand signal deduplication requires tracking which entities have had signals emitted within the configurable deduplication window — this is mutable shared state. Conversation state, while transient and process-lifetime only (DDS-009:RI-9), is mutable per active conversation and must be protected across concurrent invocations.

**M7 UpdateEngine — Actor.** The DIR unit store, epoch counter, and unit identity counter are the core mutable state of the entire pipeline. DDS-002 requires single-writer serialization (no two write transactions concurrent). The change set processing queue enforces DDS-007's sequential processing constraint (DDS-007 R9 / DAS-010 I8). The deferred recomputation queue is owned by the Update Engine and queued T2 work must be serialized with epoch advancement. A single actor owns all of this: `UpdateActor`. This is the highest-contention actor in the system — see §5 for performance considerations.

**M8 StorageEngine — Actor.** The grounding dependency map is exclusively owned by StorageEngine (DDS-008). It is rebuilt on startup and maintained incrementally thereafter. Concurrent GC execution and incremental map updates must not race. Snapshot writes (atomic via temp → rename) are serialized to enforce DDS-008's at-most-2-files invariant. A single actor serializes all of this.

---

## 2. Actor Specifications

### 2.1 `UpdateActor` (M7 UpdateEngine)

The central actor of the understanding pipeline. Implements `DIRReadAccess`, `DIRWriteAccess`, `DemandSignalSink` (from `DIRCore`) and `EpochControl` (internal).

**Owned state:**
- Unit store: collection of all Active and Invalidated atomic units
- Epoch counter (monotonically increasing)
- Unit identity counter (monotonically increasing, for unique ID assignment)
- Change set processing queue (at most one change set active — DDS-007 R9)
- Deferred T2 recomputation queue
- Within-cycle write visibility buffer (prior-epoch committed + current-cycle writes, for DDS-002:PC-3(b))

**Isolation contracts derived from DDS:**
- All write transactions are serialized through `UpdateActor`. No concurrent writes exist (DDS-002 single-writer rule).
- Consumer read access via `DIRReadAccess` protocol is `async` — callers `await` through the actor boundary. Reads observe the committed epoch only (DDS-002:PC-3(a)).
- Producer reads during pipeline execution use the within-cycle visibility buffer, also served by `UpdateActor`. These are `async` reads that observe committed epoch + current-cycle writes (DDS-002:PC-3(b)).
- Epoch advancement is internal to `UpdateActor` (EpochControl is an internal protocol). No external caller can advance the epoch directly.
- Demand signals from `ConsumerRuntime` arrive as `async` calls on the `DemandSignalSink` conformance. They are enqueued to the deferred recomputation queue without blocking the caller.

**What UpdateActor does NOT own:**
- Index state (owned by `IndexActor`)
- Snapshot persistence (owned by `StorageActor`)
- Grounding dependency map (owned by `StorageActor`)
- Producer DAG and execution (owned by `ProducerActor`)

**Concurrency within UpdateActor:**
- The synchronous pipeline stages (content-hash filtering → frontend re-execution → entity comparison → direct invalidation → cascade propagation → synchronous recomputation → index update → epoch advancement) execute sequentially within `UpdateActor`. No two stages of the synchronous pipeline run concurrently.
- Synchronous recomputation dispatches execution tickets to `ProducerActor` via `async` calls. `UpdateActor` awaits each ticket completion in DAG topological order before issuing the next (for passes with dependencies). Independent passes at the same topological level may be dispatched concurrently using `TaskGroup` while `UpdateActor` awaits the group.
- Deferred T2 recomputation runs as `Task` items detached from the synchronous pipeline. Each deferred task reads the committed epoch via `DIRReadAccess` (observing committed state, not in-progress sync writes — DDS-007 deferred pipeline constraint). On completion, the deferred task re-enters `UpdateActor` to commit results and advance a deferred epoch.
- Deferred T2 recomputation output is discarded if the unit being recomputed was invalidated by a synchronous pipeline run during the deferred task's execution (DDS-007 deferred collision rule). `UpdateActor` enforces this by checking unit status on deferred commit entry.
- GC is initiated by `UpdateActor` (triggered every Nth epoch or on memory pressure signal from `StorageActor`). GC runs are dispatched to `StorageActor` and never execute during synchronous pipeline processing (DDS-008:GC-3 / DAS-010 GC-3).

### 2.2 `ProducerActor` (M2 ProducerRuntime)

**Owned state:**
- Producer registry (registered producers and their metadata)
- Pass DAG (directed acyclic graph of pass dependencies)
- Per-invocation lifecycle state (for in-flight passes)
- Prior output records (session-scoped; in-memory; not persisted — DDS-003)

**Isolation contracts derived from DDS:**
- Producer registration (DDS-001:PC-1) is an `async` mutating operation on `ProducerActor`. Registration is deferred during active execution cycles (DDS-001 state machine: registration deferred in Executing state).
- Execution ticket acceptance (DDS-001:PC-2, PC-5) is `async`. `UpdateActor` dispatches tickets to `ProducerActor` and awaits completion.
- DAG query (DDS-001:PC-3) is `async` (crosses actor boundary from `UpdateActor`). DAG reads are non-mutating within ProducerActor and do not block other actor work during the read.
- Changed output detection (DDS-003:PC-3) is performed within `ProducerActor` — prior output records are owned here. Comparison result is returned to `UpdateActor` as part of the execution ticket completion response.
- Pass cancellation (DDS-003:PC-4) uses Swift Task cancellation. `UpdateActor` cancels the Task wrapping the pass invocation; `ProducerActor` polls `Task.isCancelled` cooperatively. Forced termination after timeout (DDS-003) is implemented by cancelling the Task and, if the pass does not respond within the forced-termination window, treating the result as cancelled (not a failure per DDS-003).

**Concurrency within ProducerActor:**
- Independent passes at the same topological DAG level may execute concurrently. Each pass invocation runs in its own `Task`. `ProducerActor` uses `TaskGroup` to launch and await a topological level's passes before beginning the next level.
- Per-invocation lifecycle state transitions (Assembling → Executing → Collecting → Completed / Failed / Cancelled) are serialized within `ProducerActor` — the actor serializes lifecycle mutations while pass execution itself runs in a detached child Task.

### 2.3 `IndexActor` (M3 IndexRuntime)

**Owned state:**
- Five index families: Entity, Graph (bidirectional), Predicate, Content, Scope
- Per-family availability state (Absent / Building / Available / Rebuilding)
- In-progress rebuild copies (for families in Rebuilding state — DDS-004:PC-4 precondition)

**Isolation contracts derived from DDS:**
- Index queries (DDS-004:PC-1) are `async`. Callers (`RetrievalRuntime`) `await` through the `IndexActor` boundary. For unavailable families, `IndexActor` falls back to DIR scan (DDS-004:RI-6) and notifies the caller.
- Batch updates (DDS-004:PC-4) from `UpdateActor` are `async`. They arrive after epoch advancement and update structural indexes synchronously (within the actor) before returning. Content index update is deferred within `IndexActor` — it is enqueued as a `Task` and executed asynchronously, keeping the batch update response on the critical path fast (DDS-004:PR-2).
- Freshness reports (DDS-004:PC-3) are `async`. Content index staleness (max one epoch behind — DDS-004:RI-8) is reported in the query response.
- Family rebuilds are initiated within `IndexActor` as `Task` items. During rebuild, the in-progress copy receives change batch additions (DDS-004:PC-4 precondition for rebuilding families). The actor manages both the live family state and the in-progress rebuild copy without exposing this distinction to callers.
- Construction priority order (Entity → Graph → Scope → Predicate → Content — DDS-004) is enforced by `IndexActor` sequentially constructing each family at startup before transitioning to Operational state.

### 2.4 `ConsumerActor` (M6 ConsumerRuntime)

**Owned state:**
- Reasoning engine registry (registered engines, their capabilities, priority order)
- Conversation state (per active conversation; bounded per DDS-009:CL-5)
- Demand signal deduplication state (entity IDs with in-window signals, configurable window)

**Isolation contracts derived from DDS:**
- Consumer invocation (DDS-009:PC-1) is `async`. The invocation request enters `ConsumerActor`, performs engine resolution, dispatches to the selected engine (as a `Task`), performs grounding and confidence verification on return, and produces the understanding. Multiple concurrent consumer invocations are permitted — `ConsumerActor` does not serialize invocations; each enters the actor to resolve engine and retrieve conversation state, then execution proceeds in a detached `Task`.
- Engine registration (DDS-009:PC-2, PC-3) is `async` — crosses actor boundary; mutates registry.
- Demand signal emission (DDS-009:PC-4) is `async`. `ConsumerActor` checks deduplication state, and if within the deduplication window, skips the signal. Otherwise it emits to `UpdateActor` via the `DemandSignalSink` protocol. Emission does not block consumer invocation — demand signal calls are fire-and-forget from the consumer invocation Task's perspective.
- Conversation state corruption (DDS-009:FM-5) is handled within `ConsumerActor` — the corrupted state is discarded without affecting the actor's operation on other conversations.

---

## 3. Async Protocol Surface

### 3.1 Rule: Async When Crossing an Actor Boundary

A protocol method is `async` if and only if the implementation of that method is owned by an actor. Non-actor implementations may have synchronous methods.

| Protocol | Implemented By | `async`? | Reason |
|---------|---------------|---------|--------|
| `DIRReadAccess` | `UpdateActor` | Yes | Actor boundary |
| `DIRWriteAccess` | `UpdateActor` | Yes | Actor boundary |
| `DemandSignalSink` | `UpdateActor` | Yes | Actor boundary |
| `ProducerRegistry` | `ProducerActor` | Yes | Actor boundary |
| `ExecutionDirective` | `ProducerActor` | Yes | Actor boundary |
| `FailureReportSource` | `ProducerActor` | Yes | Actor boundary |
| `IndexQuerying` | `IndexActor` | Yes | Actor boundary |
| `IndexFreshness` | `IndexActor` | Yes | Actor boundary |
| `IndexBatchUpdate` | `IndexActor` | Yes | Actor boundary |
| `EvidenceRetrieval` | `RetrievalRuntime` (no actor) | Yes | Async I/O in retrieval pipeline (index queries, DIR reads) |
| `ContextAssembling` | `ContextAssembly` (no actor) | Yes | Async I/O (calls `EvidenceRetrieval`) |
| `ConsumerInvocation` | `ConsumerActor` | Yes | Actor boundary |
| `ReasoningEngineManagement` | `ConsumerActor` | Yes | Actor boundary |
| `ChangeBatchObserver` | `StorageActor` | Yes | Actor boundary |
| `SnapshotPersistence` | `StorageActor` | Yes | Actor boundary |
| `GarbageCollector` | `StorageActor` | Yes | Actor boundary |
| `GroundingMapAccess` | `StorageActor` | Yes | Actor boundary |
| `ContentHashMapAccess` | `StorageActor` | Yes | Actor boundary |
| `DeferredQueuePersistence` | `StorageActor` | Yes | Actor boundary |

**All cross-module protocols are `async`.** This is the correct outcome: every cross-module protocol in the understanding pipeline either crosses an actor boundary (UpdateActor, ProducerActor, IndexActor, ConsumerActor, StorageActor) or performs I/O (RetrievalRuntime, ContextAssembly). No cross-module protocol method is synchronous.

### 3.2 Internal Synchronous Surfaces

Within `DIRCore`, value types and enum cases are synchronous — they have no concurrency boundary of their own. Internal protocols within `ProducerRuntime` (DDS-003:PC-1 through PC-7 — see IAG-001 §10) are synchronous calls within `ProducerActor`'s isolation.

### 3.3 `Sendable` Requirements

All types crossing module boundaries (as protocol method parameters or return values) must be `Sendable`. The following categories apply:

| Category | Sendable Strategy |
|----------|------------------|
| `DIRCore` value types (Unit, Epoch, Status, Tier, etc.) | `Sendable` by virtue of being pure value types (structs with all-`Sendable` fields) |
| Result types (query results, context frames, evidence sets) | Structs with all-`Sendable` fields — `Sendable` by synthesis |
| Error types crossing module boundaries | Enums with `Sendable` associated values |
| Reasoning engine result (from ConsumerRuntime) | Struct with `Sendable` fields |
| Conversation state (opaque to pipeline, owned by ConsumerActor) | Not crossed across module boundaries — owned exclusively by `ConsumerActor` |

Third-party framework types (SwiftSyntax AST nodes, tree-sitter nodes) must not cross module boundaries. `ProducerRuntime` converts all parser output to `DIRCore` value types before returning results from any protocol method (IAG-002:TI-2).

---

## 4. Startup and Shutdown Sequencing

### 4.1 Startup Sequence

The composition root (`UnderstandingSystem` in `Decode/App/UnderstandingSystem.swift` — IAG-001 §6) creates and starts modules in the following sequence. Each step completes before the next begins.

```
1. StorageActor created
   └── Locates snapshot file on disk (synchronous file probe)

2. UpdateActor created (receives StorageActor references)
   └── Enters Loading state (DDS-008)
   └── Instructs StorageActor to load snapshot via SnapshotPersistence protocol
   └── StorageActor.loadSnapshot() → async → returns serialized state
   └── UpdateActor populates unit store from snapshot data
   └── UpdateActor advances to Operational state (DDS-002: Loading → Operational)
   └── StorageActor begins MapBuilding (grounding dependency map construction from unit store)
       [MapBuilding runs concurrently with steps 3-4 below]

3. ProducerActor created (receives DIRReadAccess, DIRWriteAccess from UpdateActor)
   └── Enters Empty state (DDS-001)

4. IndexActor created (receives DIRReadAccess from UpdateActor)
   └── Enters Uninitialized state (DDS-004)
   └── Begins index construction (Building state)
       [Index construction runs concurrently with MapBuilding above]

5. RetrievalRuntime created (receives IndexQuerying, IndexFreshness, DIRReadAccess)
   └── No initialization work — stateless

6. ContextAssembly created (receives EvidenceRetrieval)
   └── Strategy catalog initialized with built-in strategies

7. ConsumerRuntime created (receives ContextAssembling, DemandSignalSink from UpdateActor)
   └── Reasoning engine registry initialized (built-in engines registered)

8. UnderstandingSystem awaits:
   (a) StorageActor.mapBuildingComplete — StorageActor signals Operational (DDS-008: MapBuilding → Operational)
   (b) IndexActor.constructionComplete — IndexActor signals Operational (DDS-004: Building → Operational)
   [Both are awaited concurrently; UnderstandingSystem proceeds when both complete]

9. UpdateEngine enters Reconciling state (DDS-007: Created → Reconciling)
   └── Calls ProducerRuntime for producer upgrade processing (DDS-007:PC-3)
   └── Performs reconciliation: validates deferred queue, re-processes any file changes
       that occurred since last snapshot (DDS-007 startup sequence)
   └── UpdateEngine enters Idle state (DDS-007: Reconciling → Idle)

10. Pipeline is operational. UnderstandingSystem signals AppDependencies.
```

**Concurrent opportunities in startup:**
- Steps 2 (MapBuilding) and 4 (IndexConstruction) run concurrently — both read the unit store via `DIRReadAccess` without writing. `UpdateActor` serves both as read-only during this window.
- Steps 5–7 (Retrieval, ContextAssembly, ConsumerRuntime creation) run concurrently with MapBuilding and IndexConstruction — they are lightweight value constructions requiring no async work.

### 4.2 Shutdown Sequence

Shutdown follows the full destruction ordering from DDS-009: Consumer Runtime → Context Assembly → Retrieval → Index → Update Engine → Storage Engine → DIR Runtime.

In implementation terms, `UpdateActor` owns the DIR runtime. Shutdown proceeds:

```
1. UnderstandingSystem signals shutdown
2. ConsumerActor quiesces: completes in-progress invocations, stops accepting new ones
3. ContextAssembly quiesces: completes in-progress assemblies (stateless — immediate)
4. RetrievalRuntime quiesces: completes in-progress retrievals (stateless — immediate)
5. IndexActor quiesces: completes in-progress queries, stops accepting new batch updates
6. UpdateActor quiesces:
   a. Stops accepting new change sets (DDS-007: Idle/Processing → Quiescing)
   b. Completes current synchronous pipeline (if active)
   c. Cancels pending deferred recomputation Tasks
   d. Requests final snapshot from StorageActor (via SnapshotPersistence)
   e. StorageActor captures final snapshot, signals completion
   f. UpdateActor enters Terminated
7. StorageActor quiesces: completes final snapshot write, enters Terminated
8. UnderstandingSystem signals AppDependencies: shutdown complete
```

**No step may be skipped.** The DDS-defined destruction ordering is a correctness requirement, not a preference. Releasing `UpdateActor` before `StorageActor` captures its final snapshot violates DDS-008:RI-1 (snapshot single-epoch integrity).

---

## 5. Data Flow Patterns

### 5.1 Change Set Processing — Synchronous Pipeline

File system event arrives at `UpdateActor` via the DispatchSource-to-AsyncStream bridge (IAG-002:TD-6). The event enters `UpdateActor` as an async call. The full synchronous pipeline executes within `UpdateActor`'s isolation, but delegates to other actors for execution and storage:

```
UpdateActor receives file-change event
  → content-hash lookup (UpdateActor internal: StorageActor.contentHashMap already reflected)
  → hash comparison (UpdateActor internal, O(1))
  → if no change: discard, return (DDS-007:CD-1 / I6)
  → dispatch frontend execution ticket → await ProducerActor.executeTicket()
  → entity comparison (UpdateActor internal, O(E))
  → batch invalidation write (UpdateActor internal: mutates unit store)
  → cascade computation (UpdateActor internal: calls StorageActor.groundingMap for traversal)
  → T0/T1 recomputation tickets → await ProducerActor.executeTickets() [may use TaskGroup for same-level passes]
  → consolidated change batch → await IndexActor.applyBatch()
  → epoch advancement (UpdateActor internal: increments epoch counter)
  → notify StorageActor.onChangeBatch() [async, non-blocking from UpdateActor's perspective]
  → trigger snapshot (async Task dispatched to StorageActor)
  → return (pipeline complete for this change set)
```

**Key data flow properties:**
- The synchronous pipeline is a sequential chain of `await` calls from within `UpdateActor`. No two stages run concurrently within the synchronous pipeline.
- Calls to `ProducerActor` and `IndexActor` are `async` — they cross actor boundaries and may allow other work to run in those actors while `UpdateActor` awaits. This is safe because `UpdateActor` does not allow another change set to start while one is in progress.
- Snapshot trigger is fire-and-forget (`Task { await storageActor.captureSnapshot(...) }`). The snapshot runs asynchronously with the next change set. Per DDS-008 snapshot-skipping rule, if a new epoch advances before the prior snapshot write completes, the in-progress write finishes first.

### 5.2 Deferred T2 Recomputation Pipeline

Deferred recomputation is scheduled from `UpdateActor` but executes asynchronously:

```
UpdateActor identifies T2 units requiring deferred recomputation
  → enqueues unit IDs to deferred queue
  → for each unit (or batch), dispatches detached Task:
      Task {
        // Read committed epoch — observing committed state, not in-progress writes
        let evidence = await dirReadAccess.read(...)
        let result = await producerActor.executeSemanticPass(...)
        // Re-enter UpdateActor to commit
        await updateActor.commitDeferredResult(unit: id, result: result)
      }

commitDeferredResult (within UpdateActor):
  → check unit status: if Invalidated or Superseded → discard result, re-queue (DDS-007 deferred collision)
  → if Active → write new T2 unit via DIRWriteAccess (supersedes prior)
  → advance deferred epoch (same guarantees as synchronous epoch — DDS-007)
  → notify IndexActor and StorageActor (same PC-9 and PC-11 contracts as synchronous pipeline)
```

### 5.3 Consumer Invocation Pipeline

```
AppDependencies calls await consumerActor.invoke(request)
  → ConsumerActor: engine resolution, conversation state lookup
  → dispatch to reasoning engine Task:
      let contextFrame = await contextAssembly.assemble(intent, budget)
        → ContextAssembly: strategy resolution (immutable snapshot)
        → await retrievalRuntime.retrieve(anchor, intent, budget)
            → RetrievalRuntime: five-stage pipeline, all reads via DIRReadAccess
            → await indexActor.query(...) [for each relevant family]
            → returns evidence set (value type, Sendable)
        → returns context frame (value type, Sendable)
      let understanding = await reasoningEngine.reason(context: contextFrame, history: conversationState)
      // Grounding and confidence verification within ConsumerActor
      await consumerActor.verifyAndFinalizeResult(rawResult, conversationState)
        → grounding verification: claims without grounding references removed
        → confidence capping: inflated confidence capped to tier-appropriate level
        → conversation state update
        → demand signal emission if T2 units are degraded:
            await updateActor.signalDemand(entityIds: [...])  // DemandSignalSink
  → return Understanding to caller
```

### 5.4 Value-Type Data Transfer

All data crossing module boundaries is a value type. No shared mutable references cross actor boundaries. This is enforced by the `Sendable` requirement on all protocol method parameters and return values (§3.3).

The large data structures in the pipeline (evidence sets, context frames, unit query results) are structs. At alpha scale (< 50 files, < 10K units), the copy cost is negligible. If profiling reveals copy overhead at larger scale, the implementation may introduce `@unchecked Sendable` reference types with documented immutability guarantees — this is an implementation-level optimization that does not change the protocol surface.

---

## 6. Cancellation Propagation

### 6.1 DDS Cancellation Contracts and Swift Mapping

| DDS Cancellation Rule | Swift Concurrency Mapping |
|----------------------|--------------------------|
| DDS-003:PC-4 — Pass cancellation: cooperative; cancellation flag polled; forced termination after timeout | `Task.cancel()` sets Task's cancellation flag; pass checks `Task.isCancelled` cooperatively. Forced termination: if pass does not check within a deadline, the containing `withTimeout` wrapper cancels the Task and treats it as cancelled (not failure). |
| DDS-001:FM-2 — Execution timeout treated identically to FM-1 (output discarded, prior retained) | `withTimeout` or `Task.sleep(until:)` timeout propagates cancellation to the pass Task. `ProducerActor` receives `.cancelled` result, discards output, retains prior, records timeout. |
| DDS-009 — Consumer resource budget: wall-clock timeout | `withTimeout` wrapping the reasoning engine Task. Exhaustion produces partial understanding (FM-4). |
| DDS-005:FM-6 — DIR unavailable: deferred, not rejected | Retrieval pipeline defers by `await`-ing a retry; timeout produces rejection. |

### 6.2 Cancellation Does Not Propagate Across Module Boundaries

When `UpdateActor` cancels a producer execution Task, the cancellation propagates only within the Task that was dispatched to `ProducerActor`. It does not cancel `UpdateActor`'s own Task or any other producer Task. Each execution ticket is dispatched as an independent Task with its own cancellation scope.

When consumer invocation is cancelled by the caller (AppDependencies), `ConsumerActor` propagates cancellation to the reasoning engine Task. Cancellation does not propagate to the context assembly, retrieval, or index tasks if they have already completed — only the in-progress child Task is affected.

### 6.3 `@MainActor` Prohibition

No understanding pipeline module (M1–M8) uses `@MainActor`. All understanding pipeline work executes on the cooperative thread pool. Results are returned to the application layer (AppDependencies, which is `@MainActor`) via `await` at the boundary between `UnderstandingSystem` and the application target.

---

## 7. File System Monitoring Integration

The file system monitoring path bridges from GCD (DispatchSource) to Swift Concurrency (AsyncStream). This bridge is already implemented in `FileWatcherService.swift` (Infrastructure/FileSystem). In the understanding pipeline, the bridge is used within `UpdateEngine` (M7).

**Integration pattern:**

```
DispatchSource (GCD queue) → debounced events → AsyncStream<FileChangeEvent>
                                                     ↕
                            UpdateActor consumes AsyncStream via async for-await loop
```

`UpdateActor` holds the `AsyncStream` and iterates it in a long-running `Task` that starts at pipeline startup and runs until quiescence. Each event from the stream enters `UpdateActor`'s isolation as an `await` on the for-await body. This ensures file system events are processed sequentially — at most one change set is active at any time (DDS-007 R9).

The 300ms debounce window (IAG-002:TD-6) coalesces rapid events from atomic saves. Additional coalescing within `UpdateActor` is implementation-level: if a change set for file A is already in progress and another event arrives for file A, the second event is held until the first completes.

---

## 8. Logger Subsystem Convention

Each module uses `os.Logger` with subsystem `"com.decode.understanding"` and a module-specific category:

| Module | Logger Category |
|--------|----------------|
| `DIRCore` | N/A — no runtime behavior, no logging |
| `ProducerRuntime` | `"producer"` |
| `IndexRuntime` | `"index"` |
| `RetrievalRuntime` | `"retrieval"` |
| `ContextAssembly` | `"context-assembly"` |
| `ConsumerRuntime` | `"consumer"` |
| `UpdateEngine` | `"update-engine"` |
| `StorageEngine` | `"storage"` |

All log messages containing file paths, source content, entity names, or any user-derived strings use `.private` privacy level (IAG-002:TD-11 constraint). Structural metadata (unit counts, epoch numbers, latency values, error codes) use `.public`.

---

## 9. UpdateActor Performance Considerations

`UpdateActor` is the highest-contention actor: all DIR reads, all DIR writes, all epoch advancements, and all demand signals funnel through it. Two design decisions mitigate contention:

**1. Read-heavy workloads use actor re-entrancy.**
`DIRReadAccess` queries (`async` through `UpdateActor`) are non-mutating. The actor executor can interleave multiple concurrent read calls between mutation points. Reads do not block each other. Only write transactions, epoch advancements, and change set ingestion block reads.

**2. The synchronous pipeline is short on the actor's critical path.**
Most pipeline work executes *outside* `UpdateActor` — in `ProducerActor` (pass execution), `IndexActor` (batch updates), and `StorageActor` (snapshot, GC). `UpdateActor` primarily coordinates: it dispatches, awaits, and applies results. The actor is suspended during the `await` on `ProducerActor.executeTickets()` and `IndexActor.applyBatch()`, allowing other `UpdateActor` work (read-access requests) to proceed.

**Performance invariants preserved:**
- `UpdateActor` never holds a lock during a `Task.sleep` or external `await`. It is always suspended at actor-boundary `await` points, never blocking the cooperative thread pool.
- Epoch advancement (DDS-002:PR-4: ≤1μs architectural requirement) is a single counter increment within `UpdateActor` with no I/O — satisfiable within actor isolation.
- Content hash lookup (DDS-007:PR-1: O(1)/file) is a dictionary lookup within `UpdateActor` (the content hash map is reflected from `StorageActor` at startup and updated on each epoch via `ChangeBatchObserver`).

---

## 10. Thread-Safety Rules

### 10.1 Strict Concurrency as the Primary Enforcement Mechanism

Swift 6.0 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`, IAG-002:TC-2) is the primary thread-safety mechanism. The compiler enforces `Sendable` requirements at actor boundaries — any value crossing a concurrency boundary that is not provably `Sendable` produces a compile-time error. This eliminates entire classes of data races by construction.

**Why this rule exists.** Data races in concurrent systems are difficult to reproduce and diagnose. The DDS specifies multiple concurrent subsystems (synchronous pipeline, deferred pipeline, consumer invocations) that share data via protocol boundaries. Without compile-time enforcement, runtime data races would corrupt unit store state, epoch consistency, or index integrity.

**Which DDS contracts require it.** DDS-002 single-writer rule (no concurrent writes), DDS-002:PC-3(a) epoch-consistent reads, DDS-004:SC-4 cross-family consistency, DDS-009 per-invocation isolation. All of these depend on data not being shared mutably across concurrent execution contexts.

**What implementation mistakes it prevents.** Passing a mutable reference to a unit collection across an actor boundary. Sharing index state between the query path and the update path without serialization. Allowing a producer's output buffer to be read by the coordinator while the producer is still writing to it.

### 10.2 `Sendable` Conformance Strategy

| Type Category | Sendable Strategy | Rationale |
|--------------|------------------|-----------|
| DIRCore value types (Unit, Epoch, Status, Tier, Predicate, etc.) | Implicitly `Sendable` — pure value types with all-`Sendable` stored properties | Value types are copied on transfer; no aliasing possible |
| Cross-module result types (query results, evidence sets, context frames) | Implicitly `Sendable` — structs with all-`Sendable` fields | Designed as transfer types between actors |
| Error types crossing module boundaries | Enums with `Sendable` associated values | Error propagation crosses actor boundaries via `throws` |
| Actor types (UpdateActor, ProducerActor, IndexActor, ConsumerActor, StorageActor) | `Sendable` by virtue of being actors | Actors are always `Sendable` — references can cross boundaries; access is serialized |
| Internal mutable state within actors | Not `Sendable`; never exposed outside actor isolation | Protected by actor isolation; never needs to cross a boundary |

### 10.3 `@unchecked Sendable` Policy

`@unchecked Sendable` is prohibited unless all three conditions are met:

1. **The type cannot be made value-type** (e.g., it wraps a C library handle or a Foundation reference type with internal synchronization).
2. **The type has documented thread-safety guarantees** from its source (e.g., `os.Logger` is documented as thread-safe by Apple).
3. **The `@unchecked Sendable` conformance is accompanied by a comment citing the safety guarantee.**

**Why this rule exists.** `@unchecked Sendable` suppresses the compiler's data race safety checking. Overuse converts compile-time guarantees into runtime hopes.

**Which DDS contracts require it.** None — DDS contracts do not require `@unchecked Sendable`. This rule constrains its use to ensure that the DDS single-writer rule (DDS-002) and epoch consistency (DDS-002:PC-3) remain compiler-enforced rather than convention-enforced.

**What implementation mistakes it prevents.** Marking a class with mutable fields as `@unchecked Sendable` to silence the compiler, then sharing it across actors — creating a data race invisible to the compiler.

### 10.4 DIRCore Pure Value Type Rule

All types defined in DIRCore (M1) must be value types (structs or enums). No classes. No actors. No reference types.

**Why this rule exists.** DIRCore types are the universal data exchange currency — they appear in every cross-module protocol signature. If any DIRCore type were a reference type, it could create shared mutable state between actors, violating the fundamental isolation model.

**Which DDS contracts require it.** DDS-002 immutability model — units, once admitted, are immutable. Value types enforce immutability at the language level: the caller's copy and the callee's copy are independent. No aliasing, no races, no defensive copying needed.

**What implementation mistakes it prevents.** Two actors holding references to the same unit object and observing each other's mutations. A producer modifying a unit's fields after it has been admitted to the unit store.

### 10.5 Framework Error Type Isolation

Framework-specific error types (SwiftSyntax errors, URLSession errors, tree-sitter errors, file system errors) must not propagate across module boundaries. Each module converts framework errors to its own error enum or to a DIRCore-defined error protocol before the error crosses an actor or module boundary.

**Why this rule exists.** Framework error types may not be `Sendable`. Even when they are, exposing them creates a transitive dependency: a consumer of the error must import the framework that defines it, violating TI-2 (IAG-002) and TI-4 (IAG-002).

**Which DDS contracts require it.** Every DDS failure mode specification (DDS-001:FM-1 through FM-7, DDS-002:FM-1 through FM-5, DDS-007:FM-1 through FM-6, etc.) defines failure categories and diagnostic context without reference to any framework. The runtime error types must map to these categories without carrying framework-specific detail.

**What implementation mistakes it prevents.** A `SwiftSyntax.DiagnosticError` propagating from `ProducerActor` through `UpdateActor` to `ConsumerActor`, forcing `ConsumerRuntime` to import SwiftSyntax to handle a parser error.

---

## 11. Error Propagation Strategy

### 11.1 Error Boundaries

Each actor is an error boundary. Errors thrown within an actor's isolation are caught at the actor boundary and converted to the actor's public error type before propagation. No actor propagates errors from its internal implementation to its callers without transformation.

| Error Boundary | Internal Errors (caught) | Public Error (propagated) |
|---------------|-------------------------|--------------------------|
| `UpdateActor` | Framework I/O errors, hash computation errors, state machine violations | Update pipeline error with stage identifier, affected file/entity, and failure category matching DDS-007:FM-1 through FM-6 |
| `ProducerActor` | SwiftSyntax parse errors, tree-sitter parse errors, URLSession errors, timeout errors | Producer execution error with producer identity, failure category matching DDS-001:FM-1 through FM-7, and diagnostic context |
| `IndexActor` | Collection mutation errors, rebuild failures | Index error with family identifier and failure category matching DDS-004:FM-1 through FM-3 |
| `ConsumerActor` | Reasoning engine errors, URLSession errors, validation errors | Consumer error with purpose, engine identity, and failure category matching DDS-009:FM-1 through FM-6 |
| `StorageActor` | File I/O errors, Codable encoding/decoding errors, file system permission errors | Storage error with operation (snapshot/GC/map) and failure category matching DDS-008:FM-1 through FM-4 |

### 11.2 Write Transaction Atomicity

All write transactions to the DIR unit store are atomic (DDS-002:PC-6). If any unit in a batch fails intake validation, the entire transaction is rejected. No partial writes occur. The caller (typically `ProducerActor` via `UpdateActor`) receives a rejection diagnostic identifying every failing unit and the specific violations.

**Why this rule exists.** Partial writes would leave the unit store in an inconsistent state — some units from a producer's output committed while others are missing, breaking provenance chains and grounding references within the batch.

**Which DDS contracts require it.** DDS-002:PC-6 (write transaction atomicity), DDS-002:FM-1 (intake validation failure rejects entire transaction).

**What implementation mistakes it prevents.** A write loop that commits units one at a time, where a validation failure mid-batch leaves half the units committed and half missing.

### 11.3 Failure Isolation Between Subsystems

A failure in one subsystem does not cascade as an error to other subsystems. Each DDS failure mode specifies a local response — the failing subsystem handles the error and, where applicable, degrades gracefully.

| Failure Scenario | Failing Subsystem | Effect on Other Subsystems |
|-----------------|-------------------|---------------------------|
| Frontend parse failure (DDS-007:FM-1) | ProducerRuntime | File excluded from change set; prior T0 units retained; cascade continues for other files. UpdateEngine, IndexRuntime, ConsumerRuntime unaffected. |
| Synchronous pass failure (DDS-007:FM-2) | ProducerRuntime | Prior output retained; downstream passes execute against prior output. UpdateEngine continues pipeline. |
| Deferred T2 failure (DDS-007:FM-3) | ProducerRuntime | Unit remains invalidated in deferred queue; consumer uses stale content. UpdateEngine and IndexRuntime unaffected. |
| Index family corruption (DDS-004:FM-1) | IndexRuntime | Affected family falls back to DIR scan; other families unaffected. Consumer queries slower but correct. |
| Reasoning engine failure (DDS-009:FM-1) | ConsumerRuntime | Fallback engine attempted if designated; failure response returned to caller. No effect on pipeline or indexes. |
| Snapshot write failure (DDS-008:FM-1) | StorageEngine | Prior valid snapshot retained; next epoch triggers retry. Unit store and indexes unaffected. |
| DIR write rejection (DDS-002:FM-1) | UpdateActor (internal) | Transaction rejected; unit store unchanged. Producer retains prior output. |

**Why this rule exists.** The understanding pipeline processes user code changes continuously. A parse error in one file should not prevent the pipeline from processing other files or serving consumer queries. Failure isolation ensures the system degrades gracefully rather than halting.

**Which DDS contracts require it.** DDS-001:FM-1 (failure isolation between producers), DDS-001:R6 (isolation guarantee — one producer's failure cannot corrupt another), DDS-004:FM-1 (per-family independence), DDS-007:FM-1 (per-file isolation within change set).

**What implementation mistakes it prevents.** A `try` block wrapping the entire change set processing pipeline, where a single file's parse error causes `catch` to skip epoch advancement for all files in the change set.

### 11.4 Error Logging Convention

All errors at actor boundaries are logged via `os.Logger` (IAG-002:TD-11) at `.error` level with:
- The error category (matching DDS failure mode identifier, e.g., "FM-1")
- The affected entity identifiers (unit IDs, file paths, producer identity) — using `.private` privacy level for user-derived content
- The subsystem state at the time of failure (current state machine state)

Errors are logged at the boundary where they are caught and converted — not at every re-throw along the call chain. This prevents duplicate log entries for the same error.

---

## 12. Runtime Resource Ownership

### 12.1 Exclusive Ownership Table

Every mutable resource in the runtime is exclusively owned by exactly one actor. No mutable state is shared between actors.

| Resource | Exclusive Owner | Access by Others |
|----------|----------------|-----------------|
| DIR unit store (all Active, Invalidated, Superseded units) | `UpdateActor` | Read-only via `DIRReadAccess` protocol (async) |
| Epoch counter | `UpdateActor` | Read via `DIRReadAccess.committedEpoch` (async) |
| Unit identity counter | `UpdateActor` | None — internal to `UpdateActor` |
| Within-cycle visibility buffer | `UpdateActor` | Read by producers during pipeline execution via `DIRReadAccess` |
| Change set processing queue | `UpdateActor` | None — internal |
| Deferred recomputation queue | `UpdateActor` | None — internal; serialized to StorageEngine for snapshot |
| Producer registry | `ProducerActor` | Query via `ProducerRegistry` protocol (async) |
| Pass DAG | `ProducerActor` | Query via `ExecutionDirective` protocol (async) |
| Prior output records | `ProducerActor` | None — internal |
| Per-invocation lifecycle state | `ProducerActor` | None — internal |
| Five index families | `IndexActor` | Query via `IndexQuerying` protocol (async) |
| Per-family availability state | `IndexActor` | Query via `IndexFreshness` protocol (async) |
| Deferred content index update queue | `IndexActor` | None — internal |
| Reasoning engine registry | `ConsumerActor` | None — accessed only within `ConsumerActor` |
| Conversation state | `ConsumerActor` | None — per-conversation, internal |
| Demand signal deduplication state | `ConsumerActor` | None — internal |
| Grounding dependency map | `StorageActor` | Read via `GroundingMapAccess` protocol (async) |
| Content hash map | `StorageActor` | Read via `ContentHashMapAccess` protocol (async) |
| Snapshot file state | `StorageActor` | None — internal |
| In-progress GC state | `StorageActor` | None — internal |

### 12.2 No Shared Mutable State

There is no mutable state shared between any two actors. All cross-actor data transfer is via value types passed through async protocol methods. The actor that owns a resource is the sole writer; all other actors receive immutable copies.

**Why this rule exists.** Shared mutable state requires synchronization. Actor isolation provides synchronization, but only if each piece of mutable state has exactly one owning actor. If two actors both mutate the same state, one of them is violating the other's isolation — the compiler cannot enforce correctness for state that lives outside any single actor.

**Which DDS contracts require it.** DDS-002:R1 (unit store exclusively owned by DIR Runtime), DDS-004:R1 (index structures exclusively owned by Index Runtime), DDS-008:R3 (grounding dependency map exclusively owned by Storage Engine). Every DDS subsystem specification includes a "Memory and Ownership" section declaring exclusive ownership of its resources.

**What implementation mistakes it prevents.** Two actors holding a reference to the same dictionary and appending entries concurrently. An index update reading from a unit collection that the update pipeline is simultaneously modifying.

### 12.3 Transient State and Eager Release

Resources that exist only during a single operation (per-invocation working memory, per-change-set processing state, in-flight execution tickets) are released eagerly upon operation completion. They are not cached, pooled, or retained for potential reuse.

**Why this rule exists.** The understanding pipeline processes events continuously. Retaining transient state between operations creates memory pressure proportional to event history rather than current working set. At alpha scale this is negligible, but the rule prevents patterns that would become problematic at larger scales.

**Which DDS contracts require it.** DDS-007 Memory and Ownership: "In-progress change set state exists only during processing and is released on completion. Not persisted." DDS-001 Memory Bounds: "Output batches are released immediately after DIR commit or discard."

**What implementation mistakes it prevents.** Caching prior change set processing state "in case the next change set affects the same files." Retaining a producer's output buffer after the output has been committed to the DIR.

---

## 13. Runtime Verification Requirements

### 13.1 Compile-Time Verification

The primary verification mechanism is Swift 6.0 strict concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`). This verifies at compile time:

- **Sendable conformance** — every value crossing a concurrency boundary is `Sendable`
- **Actor isolation** — mutable state within actors is accessed only within the actor's isolation context
- **No data races** — the compiler rejects code that would permit concurrent mutable access to the same state

**Why this is the primary mechanism.** Compile-time verification catches entire categories of concurrency bugs before any code executes. The DDS single-writer rule (DDS-002) and actor isolation strategy (§1) are designed so that strict concurrency checking enforces the runtime invariants.

**What it catches.** Accessing an actor's stored property from outside the actor without `await`. Returning a non-`Sendable` type from an actor method. Mutating a shared variable from two concurrent tasks.

### 13.2 State Machine Transition Guards

Every actor with a DDS-defined state model validates state transitions at runtime. A transition request that does not match the allowed transitions in the DDS state model is rejected — not silently ignored.

| Actor | State Model | Guard Behavior |
|-------|------------|----------------|
| `UpdateActor` | DDS-002: Loading → Operational → Quiescing → Terminated | Invalid transition logs error and is rejected. Operations against a Terminated actor throw immediately. |
| `ProducerActor` | DDS-001: Empty → Ready → Executing → Quiescing → Terminated | Registration during Executing is deferred, not rejected. Invalid transitions rejected. |
| `IndexActor` | DDS-004: Uninitialized → Building → Operational → Quiescing → Terminated | Queries during Building use fallback. Invalid transitions rejected. |
| `ConsumerActor` | DDS-009: Unavailable → Available → Terminated | Invocations during Unavailable are rejected with FM-7. |
| `StorageActor` | DDS-008: Created → Loading → MapBuilding → Operational → Quiescing → Terminated | Operations outside valid state are rejected. |

**Why this rule exists.** State machines define the legal behavior of each subsystem. Without runtime guards, a caller could invoke an operation in a state where the DDS explicitly prohibits it (e.g., processing a change set while the Update Engine is in Reconciling state), producing undefined behavior.

**Which DDS contracts require it.** Every DDS document specifies a state model with explicit valid and invalid transitions. DDS-007: "Invalid transitions: Created → Processing (must reconcile first)." DDS-002: "Quiescing → any state other than Terminated (shutdown is irreversible)."

**What implementation mistakes it prevents.** Calling `processChangeSet()` on `UpdateActor` before reconciliation is complete. Accepting consumer invocations before the engine registry has been populated. Starting index construction before the DIR is operational.

### 13.3 Intake Validation

The DIR Runtime validates every unit at admission (DDS-002:R2). Intake validation checks:

- **PV-1: Completeness** — producer identity, method, timestamp required
- **PV-2: Machine-interpretability** — producer identity and method are machine-interpretable
- **PV-3: Input reference validity** — provenance inputs reference existing or same-transaction units
- **TE-1: Tier totality** — every unit declares exactly one tier from {T0, T1, T2}
- **TE-2: Tier-confidence bounds** — T0 = deterministic confidence; T1/T2 ≠ deterministic
- **TE-3: MDT compliance** — tier ≤ predicate's maximum deterministic tier (unless semantic tiers permitted)
- **TE-4: Derivation monotonicity** — no provenance input has a higher tier than the derived unit
- **TE-5: Tier immutability** — tier field cannot be changed after admission

Intake validation is the gatekeeper for DIR integrity. Any unit that passes intake validation is guaranteed to satisfy the structural constraints that cascade propagation, index updates, and consumer queries depend on.

### 13.4 Output Validation

Producer output is validated before DIR commit (DDS-001:R4, DDS-003):

- Output predicates match the producer's declared output contract
- Output tiers are within the producer's declared tier range
- Provenance is complete (required fields present, input references valid)
- Grounding chains are non-empty and non-cyclic within the batch

Invalid output causes whole-batch rejection (DDS-001:FM-3). The producer's prior output is retained.

### 13.5 Cross-Module Contract Verification via Tests

Every cross-module protocol defined in IAG-001 §4 has a corresponding contract test target. Contract tests verify:

- **Protocol method semantics** — calling the protocol method produces the DDS-specified behavior
- **Error cases** — invalid inputs produce the DDS-specified error response
- **State preconditions** — calling a method in an invalid state produces the specified rejection
- **Async correctness** — concurrent protocol calls do not produce data races or inconsistent results

Contract tests use XCTest (IAG-002:TD-10) with `async` test methods (IAG-002:TC-15).

---

## 14. Traceability: DDS Contracts to Concurrency Decisions

Every concurrency decision in this document derives from a DDS specification. This table provides the authoritative mapping.

| Concurrency Decision | DDS Source |
|---------------------|-----------|
| `UpdateActor` is a single actor (single-writer rule) | DDS-002: single-writer (no two write transactions concurrent), DAS-012 DA-1 |
| Epoch advancement is internal to `UpdateActor` | DDS-002:PC-4 — epoch advancement is a DIR Runtime operation; no external actor may advance it |
| Consumer reads observe committed epoch only | DDS-002:PC-3(a) — consumer queries during pipeline see prior epoch |
| Producer reads observe committed epoch + current-cycle writes | DDS-002:PC-3(b) — pipeline-internal reads; `UpdateActor` maintains within-cycle buffer |
| Deferred T2 reads committed epoch (not in-progress sync writes) | DDS-007 deferred pipeline concurrency constraint |
| Deferred T2 output discarded if unit invalidated during recomputation | DDS-007 deferred collision rule |
| Sequential change set processing (no concurrent change sets) | DDS-007 R9 / DAS-010 I8 |
| T0/T1 synchronous pipeline, T2 deferred pipeline | DDS-007:CB-1, CB-2, CB-3 |
| Synchronous recomputation: DAG topological order, independent levels concurrent | DDS-001 pass execution model; DDS-003:DE-2 per-pass bound |
| GC never during synchronous pipeline | DDS-008:GC-3 / DAS-010 GC-3 |
| Snapshot trigger is async (non-blocking from pipeline) | DDS-008 snapshot timing: "may execute asynchronously with next change set processing" |
| At most 2 snapshot files at any time | DDS-008: write to temp → atomic rename; prior retained until rename completes |
| `IndexActor` structural indexes updated before epoch advancement | DDS-004: structural indexes synchronous, updated before epoch advance (DDS-007 stage 7 before stage 8) |
| Content index updated asynchronously, max 1 epoch behind | DDS-004:RI-8 |
| Demand signals are advisory, non-blocking | DDS-009:PC-4 — Consumer Runtime does NOT block, does NOT wait for recomputation |
| Demand signals deduplicated within configurable window | DDS-009 demand signal deduplication |
| `ConsumerActor` does not serialize concurrent invocations | DDS-009: Consumer composition is parallel when independent; Consumer Runtime does not differentiate standalone vs. composition step |
| Conversation state is process-lifetime only (never persisted) | DDS-009:RI-9 |
| `ProducerActor` defers registration during Executing state | DDS-001 state model: registration deferred in Executing state |
| Startup: MapBuilding and IndexConstruction concurrent | DDS-008: map constructed after DIR Runtime operational; DDS-004: construction begins at startup; both read DIR without writing |
| Destruction ordering: Consumer → ContextAssembly → Retrieval → Index → UpdateEngine → StorageEngine | DDS-009 destruction ordering |

---

## 15. Runtime Invariants

These are architectural invariants of the runtime implementation — properties that must hold at all times during pipeline operation. They are not restatements of DDS invariants; they are constraints that IAG-003's actor architecture imposes on the implementation to satisfy DDS contracts.

**RI-1: Singleton UpdateActor.** Exactly one `UpdateActor` instance exists at any time. The composition root (`UnderstandingSystem`) creates it during startup (§4.1 step 2) and holds the sole owning reference. No factory, registry, or dynamic allocation creates a second instance. Duplication would violate the single-writer rule — two `UpdateActor` instances could independently advance epochs, corrupt the unit store, or process concurrent change sets.

**RI-2: Exclusive mutable resource ownership.** Every mutable runtime resource is exclusively owned by exactly one actor (per §12.1). No mutable resource has two owners. No actor accesses another actor's mutable state except through the protocol surface defined in IAG-001 §4. This invariant is the runtime realization of the DDS ownership model — each DDS subsystem's "Memory and Ownership" section declares exclusive ownership, and actor isolation enforces it at the language level.

**RI-3: No shared mutable state.** No mutable state is shared between any two actors, between an actor and a non-actor module, or between any two concurrent execution contexts. All cross-boundary data transfer uses `Sendable` value types. This invariant subsumes RI-2 — even within a single actor, mutable state is never exposed by reference to external callers.

**RI-4: Protocol-only cross-module communication.** Actors depend on and communicate through the protocols defined in IAG-001 §4. No actor calls another actor's methods directly by concrete type. No actor accesses another actor's stored properties. The only references between actors are protocol-typed references injected at construction time (IAG-001:IR-1 through IR-5). This invariant ensures that the module graph from IAG-001 §3 is the authoritative description of runtime dependencies — no undeclared coupling exists.

**RI-5: Startup ordering is total.** The construction and initialization sequence (§4.1) is a total order with explicit completion barriers. No actor begins accepting work before its dependencies are operational. `UnderstandingSystem` signals readiness only after all startup phases complete, including reconciliation (§4.1 step 9). A partial startup — where some actors are operational and others are not — is never observable by external callers (AppDependencies).

**RI-6: Shutdown ordering is total and irreversible.** The shutdown sequence (§4.2) is a total order following the DDS destruction ordering. Once an actor enters Quiescing, it never returns to an operational state (every DDS state model declares this transition as irreversible). Shutdown completes fully — no actor is abandoned in a half-quiesced state. `UnderstandingSystem` signals shutdown complete only after all actors reach Terminated.

**RI-7: No partially committed runtime visibility.** No external caller (consumer invocation, application layer query) observes the pipeline in a state where some subsystems reflect a new epoch and others reflect the prior epoch. Epoch advancement (§5.1) occurs after all synchronous pipeline stages — including index updates — are complete. Consumer reads (via `DIRReadAccess`) observe the committed epoch, which advances atomically from the consumer's perspective. Within-cycle visibility (DDS-002:PC-3(b)) is restricted to producer reads during pipeline execution and is never exposed to consumers.

---

## 16. Cross-Actor Dependency Rule

**Rule: Actors depend only on protocols, never on concrete actor implementations.**

Every actor receives its dependencies as protocol-typed references at construction time. No actor imports, instantiates, or holds a concrete reference to another actor type.

```
Correct:    UpdateActor receives ProducerRegistry, IndexBatchUpdate, SnapshotPersistence
Incorrect:  UpdateActor receives ProducerActor, IndexActor, StorageActor
```

**Why this rule exists.** The module architecture (IAG-001) defines a strict dependency graph where modules depend on protocols defined in DIRCore (M1), not on each other's implementations. The runtime architecture must preserve this property. If `UpdateActor` held a concrete `ProducerActor` reference, it would create a compile-time dependency from `UpdateEngine` (M7) to `ProducerRuntime` (M2) — violating the dependency graph (IAG-001 §3) where M7 depends on M1 protocols, not on M2.

**How it preserves module isolation.** Each actor's module can be compiled, tested, and reasoned about independently. The module's test target provides mock implementations of the protocol dependencies (IAG-001 §8 test target organization). A change to `ProducerActor`'s internal implementation — adding state, refactoring methods, changing concurrency strategy — has zero compile-time impact on `UpdateEngine` as long as the `ProducerRegistry` and `ExecutionDirective` protocol conformances are maintained.

**How it preserves future replaceability.** A protocol-only dependency means any conforming implementation can be substituted at the composition root. If `ProducerActor` is replaced with a different concurrency strategy (e.g., a lock-based implementation for profiling, or a distributed actor for future scale), `UnderstandingSystem` substitutes the new implementation at construction — no other actor is aware of the change. This is the runtime consequence of IAG-001:IR-2 (protocol indirection for all cross-module communication).

---

## 17. Actor Reentrancy Policy

### 17.1 Project-Wide Policy

**Swift actors are reentrant by default. This project assumes reentrancy and codes defensively against it.**

When an actor method contains an `await` (a suspension point), other work may execute on the same actor between the suspension and the resumption. The actor's mutable state may change across any `await`. This is not a bug — it is the defined behavior of Swift actors.

### 17.2 Rules

**Rule 1: Revalidate mutable assumptions after every external `await`.** If actor code reads a mutable property, then `await`s an external call, and then uses the value it read earlier, the value may be stale. The implementation must re-read the property after the `await` or verify that the assumption still holds.

```
// Incorrect — state.phase may have changed during await
let phase = state.phase
let result = await producerActor.executeTicket(ticket)
if phase == .processing { ... }  // phase was read before await — stale

// Correct — re-read after await
let result = await producerActor.executeTicket(ticket)
if state.phase == .processing { ... }  // fresh read
```

**Rule 2: Never assume actor state is unchanged across suspension points.** This applies to all actors: `UpdateActor`, `ProducerActor`, `IndexActor`, `ConsumerActor`, `StorageActor`. The following properties are particularly susceptible to reentrancy-induced staleness:

| Actor | Properties requiring post-await revalidation |
|-------|---------------------------------------------|
| `UpdateActor` | Epoch counter, unit status, deferred queue contents, change set processing state |
| `ProducerActor` | DAG structure (registration may have occurred), per-invocation lifecycle state |
| `IndexActor` | Per-family availability state, in-progress rebuild status |
| `ConsumerActor` | Engine registry contents, demand deduplication window entries |
| `StorageActor` | In-progress GC state, snapshot write state |

**Rule 3: Sequential change set processing (DDS-007 R9) is not violated by reentrancy.** `UpdateActor` processes change sets one at a time. The `for await` loop on the `AsyncStream<FileChangeEvent>` naturally serializes change set entry — the next event is not consumed until the current processing completes. However, within a single change set's processing, `await` calls to `ProducerActor` and `IndexActor` create suspension points where `DIRReadAccess` queries from `ConsumerActor` may interleave. This is correct behavior: consumer reads observe the committed epoch (DDS-002:PC-3(a)), not in-progress writes.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-06-28 | Initial draft. Actor placement for all 8 modules, async protocol surface, startup/shutdown sequence, data flow patterns for all three pipeline paths (synchronous, deferred, consumer), cancellation propagation, file system monitoring integration, UpdateActor performance considerations, complete DDS-to-concurrency traceability map. |
| 0.2 | 2026-06-28 | Added four required sections: §10 Thread-Safety Rules (Sendable strategy, @unchecked Sendable policy, DIRCore pure value type rule, framework error isolation), §11 Error Propagation Strategy (error boundaries, write transaction atomicity, failure isolation, error logging convention), §12 Runtime Resource Ownership (exclusive ownership table, no shared mutable state, transient state eager release), §13 Runtime Verification Requirements (compile-time via strict concurrency, state machine guards, intake/output validation, contract test requirements). |
| 0.3 | 2026-06-28 | CTO review revisions: (1) Added §15 Runtime Invariants — seven invariants (RI-1 through RI-7) defining singleton UpdateActor, exclusive ownership, no shared mutable state, protocol-only communication, total startup/shutdown ordering, no partially committed visibility. (2) Added §16 Cross-Actor Dependency Rule — actors depend on protocols, never concrete actor types; rationale for module isolation and replaceability. (3) Added §17 Actor Reentrancy Policy — reentrancy assumed, mutable assumptions revalidated after every await, per-actor susceptible properties enumerated, DDS-007 R9 compatibility confirmed. |
