# IAG-001 — Module Architecture

| Field | Value |
|-------|-------|
| **Document** | IAG-001 |
| **Title** | Module Architecture |
| **Status** | Draft |
| **Version** | 0.2 |
| **Created** | 2026-06-28 |
| **Depends On** | DDS-000 through DDS-009 (all frozen) |
| **Consumed By** | IAG-002, IAG-003, IAG-004 |

---

## Preamble: IAG Layer Definition

### Purpose of the IAG Layer

The Implementation Architecture Guide (IAG) layer translates frozen Design Specifications (DDS) into codebase structure. It occupies the space between behavioral specification and source code.

The DDS layer defines **what** each subsystem must do — contracts, invariants, responsibilities, failure modes. The IAG layer defines **how the codebase is organized** to realize those specifications. Implementation defines **the source code** within that organization.

### What Belongs in IAG

An IAG statement must satisfy this test:

> **An engineer could not correctly implement the frozen DDS without this decision.**

IAG documents may contain:

- Module-to-subsystem mapping and rationale
- Module dependency graph (build-system enforceable)
- Protocol boundary identification and ownership assignment
- Repository directory layout
- Composition root location and dependency injection pattern
- Test target structure and shared test infrastructure
- Traceability from DDS contracts to module boundaries

Every IAG statement must be verifiable by inspecting the module graph, build configuration, or directory tree — never by reading source code logic.

### What Must Never Appear in IAG

**Belongs in DDS (behavioral specification):**

- Subsystem responsibilities, contracts, invariants
- State models, lifecycle transitions
- Failure taxonomies and required handling
- Observability requirements, performance bounds
- Any restatement of a DDS guarantee

An IAG may *reference* a DDS contract (e.g., "the protocol boundary at this module edge realizes DDS-006:PC-1") but must never restate its semantics.

**Belongs in implementation (source code):**

- Method signatures beyond protocol surface identification
- Algorithm selection, data structure design
- Error message text, logging format
- Configuration value defaults
- Specific test case logic or assertions

### Relationship to DAS, DDS, and Implementation

```
DAS (frozen, permanent)     — defines architectural principles and invariants
  ↓
DDS (frozen, permanent)     — specifies subsystem contracts and behavior
  ↓
IAG (transient, consumed)   — maps subsystems to code modules
  ↓
Implementation (permanent)  — realizes both DDS contracts and IAG structure
```

IAG documents are consumed artifacts. They are authoritative during construction and become historical references afterward. The code and build system become ground truth for module structure. The DDS remains ground truth for behavioral contracts.

---

## 1. Repository Topology

### Current State

The Decode project uses XcodeGen (`project.yml`) to generate an Xcode project. The existing codebase follows a layered directory structure within a single application target:

```
Decode/
  App/            → DecodeApp, AppDependencies, ContentView
  Application/    → Coordinators, managers, services
  Domain/         → Models, Protocols, Services
  Infrastructure/ → AI, AST, Capture, Database, FileSystem, Hotkey, Keychain, OCR
  Presentation/   → Overlay, Session, Onboarding, Settings, Chat, Toast
```

All source files compile into a single `Decode` application target. Dependencies are managed via SPM: GRDB, SwiftSyntax, SwiftTreeSitter, and nine language grammar packages.

### Topology Decision

The DDS understanding pipeline is introduced as **a set of modules within the existing project**, not as an external package. The understanding pipeline modules are XcodeGen targets that the application target depends on.

**Rationale:** The understanding pipeline is not a reusable library — it is purpose-built for Decode. Extracting it into a separate Swift Package would add repository management overhead (separate versioning, CI) without benefit at this project's scale. XcodeGen targets within the same project provide module isolation (build-system enforced import boundaries) without the overhead.

### Target Types

| Target Type | Purpose |
|-------------|---------|
| Framework target | Each understanding pipeline module. Produces a `.framework` importable by other targets. |
| Application target | The existing `Decode` application. Imports understanding pipeline modules. |
| Unit test target | One per module. Tests that module in isolation. |
| Integration test target | Cross-module tests verifying contract counterparties. |

---

## 2. Module Decomposition from DDS Subsystems

### Decomposition Principle

Each module boundary must satisfy at least one of:

1. **Multiple consumers** — two or more modules depend on this module's contracts, requiring build-system enforcement of the contract surface.
2. **Independent change reason** — the module's internals change for reasons unrelated to any other module's internals.
3. **Test isolation** — the module must be testable without compiling unrelated subsystem code.

A DDS subsystem maps to its own module unless it has a single consumer AND changes for the same reasons as that consumer — in which case it is combined with its consumer.

### Module Set

| Module | DDS Subsystem(s) | Justification |
|--------|-------------------|---------------|
| `DIRCore` | DDS-002 (types only) | Every subsystem depends on DIR types. Shared foundation. |
| `ProducerRuntime` | DDS-001 + DDS-003 | DDS-003 (Pass) has a single consumer: DDS-001 (Producer). Pass invocation occurs exclusively within producer execution cycles. They share a change reason: how the production pipeline processes source material into DIR units. |
| `IndexRuntime` | DDS-004 | Two consumers: Retrieval (DDS-005) queries indexes; Update Engine (DDS-007) delivers change batches. Multiple consumers require build-system enforcement. |
| `RetrievalRuntime` | DDS-005 | Independent change reason: retrieval strategy (five-stage pipeline, budget allocation, anchor resolution) varies independently of index structure and context assembly logic. |
| `ContextAssembly` | DDS-006 | Independent change reason: strategy catalog, stratum selection, coherence constraints, elision policy vary independently of retrieval logic and consumer reasoning. |
| `ConsumerRuntime` | DDS-009 | Terminal pipeline module. Independent change reason: reasoning engine management, grounding/confidence verification, conversation state, composition vary independently of context assembly. |
| `UpdateEngine` | DDS-007 + DDS-002 (runtime) | Central coordinator colocated with DIR runtime. Distinct change reason: DIR state management and coordinated state transitions. See §2 DDS-007 + DDS-002 combination rationale. |
| `StorageEngine` | DDS-008 | Independent change reason: snapshot format, crash recovery, GC policy, grounding dependency map maintenance. Distinct lifecycle (persistence survives process restarts; all other modules are ephemeral). |

**Total: 8 modules.**

### DDS-001 + DDS-003 Combination Rationale

DDS-003 (Pass Runtime) defines pass invocation — input assembly, execution strategy dispatch, output pipeline, changed output detection. DDS-001 (Producer Runtime) defines producer registration, DAG construction, execution cycle orchestration, failure isolation.

**Why separate DDS documents map to one implementation module.**

DDS-001 and DDS-003 are separate DDS documents because they specify distinct behavioral contracts with distinct invariants — producer orchestration vs. pass invocation. The DDS layer is organized by behavioral responsibility. However, the DDS boundary does not mandate a module boundary. Module boundaries exist to enforce contracts at the build system level. When a contract has a single consumer, build-system enforcement adds overhead without protection — the only consumer is already tightly coupled by design.

These are combined because:

1. **Single consumer.** DDS-003's contracts (PC-1 through PC-4) are consumed exclusively by DDS-001. No other subsystem invokes passes directly. There is no second consumer that could misuse the contract.
2. **Shared execution lifecycle.** Pass invocations happen within producer execution cycles (DDS-001:PC-2). The pass invocation lifecycle (Assembling → Executing → Collecting → Completed) is nested within the producer execution state (Ready → Executing → Ready).
3. **Shared change reason.** Changes to how passes execute (new execution strategies, new composition constraints) directly affect producer orchestration and vice versa.

**Why this preserves single responsibility.**

The combined module has one responsibility: **execute the production pipeline that transforms source material into DIR units.** DDS-001 owns the orchestration dimension (which producers, in what order). DDS-003 owns the invocation dimension (how each pass executes). These are two aspects of one concern — production — not two independent concerns. The module's single change reason is: "the way source material is processed into DIR units has changed." Neither DDS-001 logic nor DDS-003 logic changes for reasons unrelated to the other.

**When to split.**

Split `ProducerRuntime` into separate `ProducerRuntime` and `PassRuntime` modules if any of these conditions emerge:

1. A second consumer of DDS-003 contracts appears — another subsystem needs to invoke passes directly, bypassing producer orchestration.
2. Pass execution strategies begin varying on a different axis than producer orchestration — e.g., passes are reused across multiple producer architectures with incompatible execution models.
3. The module grows large enough that build time or cognitive load justifies structural separation, even with a single consumer.

None of these conditions exist in the current DDS. If they emerge, the internal protocol boundary (preserved below) makes the split mechanical — extract the `Pass/` subdirectory into its own target and promote internal protocols to public.

The contract boundary between DDS-001 and DDS-003 is preserved by **internal protocols** within the `ProducerRuntime` module. The DDS contracts are realized as protocol conformances; the module boundary enforcement is relaxed because there is a single consumer.

### DIRCore Foundation Module Boundary

`DIRCore` is the **foundation module** of the understanding pipeline. It is the only module with zero dependencies and is imported by every other module. This privileged position imposes strict content constraints.

**DIRCore may contain only:**

| Category | Examples | Rationale |
|----------|----------|-----------|
| Shared immutable types | Atomic unit record (10 fields), supersession key, provenance, grounding reference | Value types representing DDS-002 domain concepts, consumed by all modules |
| Identifiers | Unit identity type (opaque, unique), epoch type (monotonic counter) | Identity and ordering primitives shared across all subsystems |
| Protocol definitions | `DIRReadAccess`, `DIRWriteAccess`, `DemandSignalSink`, `ChangeBatchObserver`, `EpochControl` | Cross-module contract surfaces that cannot live in either consumer or implementer (see §4) |
| Value objects | Status enum and valid transition set, tier enum ({T0, T1, T2}) with tier-confidence bounds | Enumerated domain values with fixed semantics |
| Serialization contracts | Write transaction request/result types, status transition request type, unit query result types | Data transfer types for cross-module communication |

**DIRCore must never contain:**

| Prohibition | Rationale |
|-------------|-----------|
| Runtime behavior | Foundation types are inert. No type in DIRCore may perform computation, schedule work, or maintain mutable state. |
| Scheduling or coordination logic | Scheduling is exclusively owned by UpdateEngine (DDS-007). |
| Indexing logic | Indexing is exclusively owned by IndexRuntime (DDS-004). |
| Storage or persistence logic | Storage is exclusively owned by StorageEngine (DDS-008). |
| Orchestration | Pipeline coordination is exclusively owned by UpdateEngine (DDS-007). |
| Business policy | Tier assignment policy, GC retention policy, cascade boundary rules — all belong in the subsystem modules that own those decisions per DDS. |
| Mutable runtime state | No unit store, no epoch counter, no in-memory collections. DIRCore defines the *shape* of data; other modules own the *instances*. |

**Enforcement test:** If removing a type or protocol from `DIRCore` would break only one module, it does not belong in `DIRCore` — it belongs in that module. `DIRCore` contains only what is shared across module boundaries.

**Contents inventory:**

- Atomic unit record type (10 immutable fields: id, subject, predicate, value, tier, provenance, confidence, grounding, version, status)
- Unit identity type (opaque, unique)
- Status enum and valid transition set
- Supersession key type (subject, predicate, tier)
- Epoch type (monotonic counter)
- Tier enum ({T0, T1, T2}) and tier-confidence bounds
- Provenance type (producer identity, method, timestamp, inputs)
- Grounding reference type
- Write transaction request/result types
- Status transition request type
- Unit query result types
- Cross-module protocols (see §4 for complete inventory)

### DDS-007 + DDS-002 Runtime Combination Rationale

DDS-002 defines both shared types (used by all modules) and a runtime subsystem (the unit store with write transactions, epoch advancement, intake validation). These have different dependency profiles:

- **DIR types**: Depended on by every module. Zero dependencies of their own.
- **DIR runtime**: Depended on by Producer, Update Engine, Storage Engine. Depends on DIR types.

The DIR runtime implementation — the unit store, intake validation, write transaction processing, epoch advancement, read access — is implemented within the **`UpdateEngine` module**.

**Why separate DDS documents map to one implementation module.**

DDS-002 and DDS-007 are separate DDS documents because they specify distinct behavioral domains — DDS-002 defines the data model (unit invariants, immutability, epoch consistency, lifecycle state machine) while DDS-007 defines the coordination engine (change detection, invalidation cascade, scheduling, pipeline orchestration). The DDS separation is correct: the data model's invariants are independent of how updates are coordinated. However, at the implementation level, the DIR runtime and the Update Engine are not independent — they are co-dependent in a way that makes separation counterproductive.

The DIR runtime is colocated within `UpdateEngine` because:

1. **Exclusive write coordination.** The Update Engine exclusively coordinates all DIR write operations. Every write transaction (DDS-007:PC-6), every epoch advancement (DDS-007:PC-7), and every within-cycle visibility decision (DDS-002:PC-3(b)) is orchestrated by the Update Engine. No other module writes to the DIR independently. A separate DIR module would be "driven" entirely by the Update Engine, with no independent agency.
2. **Circular coordination avoidance.** If the DIR runtime were a separate module, the Update Engine would need to import it (to coordinate writes and epochs) and the DIR runtime would need callbacks to the Update Engine (to signal epoch completion, coordinate within-cycle visibility). This creates a coordination coupling that is better expressed as colocation than as bidirectional protocol injection.
3. **Atomic pipeline operations.** The synchronous pipeline (change detection → invalidation → recomputation → index update → epoch advance) requires the Update Engine to interleave DIR reads, DIR writes, and epoch operations within a single coordinated sequence. Separating the DIR runtime would force every pipeline step through a cross-module protocol boundary, adding overhead to the critical path without enforcement benefit.

**Why this preserves single responsibility.**

The combined module has one responsibility: **maintain the authoritative DIR state and coordinate all state transitions.** DDS-007 defines *when and why* state changes (change detection, cascade logic, scheduling). DDS-002 runtime defines *how* state changes are applied (write transactions, intake validation, epoch advancement). These are the policy and mechanism of one concern — DIR state management. The module's single change reason is: "the way DIR state is maintained or coordinated has changed."

The DDS-002 *types* remain in `DIRCore` because they are consumed everywhere. The DDS-002 *runtime* lives in `UpdateEngine` because it is coordinated exclusively by the Update Engine.

**When to split.**

Split the DIR runtime out of `UpdateEngine` into a separate `DIRRuntime` module if any of these conditions emerge:

1. A second write coordinator appears — another subsystem needs to issue DIR write transactions or advance epochs independently of the Update Engine.
2. The DIR runtime needs to be tested in complete isolation from Update Engine coordination logic, and internal boundaries within the module prove insufficient for test isolation.
3. The module grows large enough that the DIR runtime and Update Engine coordination logic have distinct engineering owners who need independent compilation and release.

None of these conditions exist in the current DDS. The Update Engine is the sole write coordinator by architectural design (DAS-010). If a second coordinator is ever introduced, it would require a DAS amendment — at which point the module split would follow naturally.

The DIR runtime exposes its contracts (DDS-002:PC-1 through PC-6) as protocols that other modules consume. These protocols are defined in `DIRCore` (see §4).

---

### 2.1 Module Inventory

| # | Module Name | DDS Realization | Public Surface |
|---|-------------|-----------------|----------------|
| M1 | `DIRCore` | DDS-002 (types + protocols) | Unit types, status transitions, epoch types, query protocols, write protocols |
| M2 | `ProducerRuntime` | DDS-001 + DDS-003 | Producer registration, DAG query, execution ticket acceptance, pass invocation (internal), failure reports |
| M3 | `IndexRuntime` | DDS-004 | Index query (5 families), index freshness report, batch update acceptance |
| M4 | `RetrievalRuntime` | DDS-005 | Evidence retrieval, anchor resolution |
| M5 | `ContextAssembly` | DDS-006 | Context assembly, strategy registration, strategy catalog query |
| M6 | `ConsumerRuntime` | DDS-009 | Consumer invocation, reasoning engine registration, demand signal emission |
| M7 | `UpdateEngine` | DDS-007 + DDS-002 (runtime) | Change set processing, deferred recomputation, producer upgrade, reconciliation, DIR runtime (unit store, epoch, read/write access) |
| M8 | `StorageEngine` | DDS-008 | Snapshot capture/load, GC execution, grounding dependency map access, content hash map, deferred queue persistence |

---

## 3. Module Dependency Graph

### Dependency Edges

```
DIRCore (M1)
├── ProducerRuntime (M2)    → imports DIRCore
├── IndexRuntime (M3)       → imports DIRCore
├── RetrievalRuntime (M4)   → imports DIRCore, IndexRuntime
├── ContextAssembly (M5)    → imports DIRCore, RetrievalRuntime
├── ConsumerRuntime (M6)    → imports DIRCore, ContextAssembly
├── UpdateEngine (M7)       → imports DIRCore, ProducerRuntime, IndexRuntime, StorageEngine
└── StorageEngine (M8)      → imports DIRCore
```

### Dependency Table

| Module | Imports | Imported By |
|--------|---------|-------------|
| `DIRCore` | (none) | All modules |
| `ProducerRuntime` | `DIRCore` | `UpdateEngine` |
| `IndexRuntime` | `DIRCore` | `RetrievalRuntime`, `UpdateEngine` |
| `RetrievalRuntime` | `DIRCore`, `IndexRuntime` | `ContextAssembly` |
| `ContextAssembly` | `DIRCore`, `RetrievalRuntime` | `ConsumerRuntime` |
| `ConsumerRuntime` | `DIRCore`, `ContextAssembly` | Application target |
| `UpdateEngine` | `DIRCore`, `ProducerRuntime`, `IndexRuntime`, `StorageEngine` | Application target |
| `StorageEngine` | `DIRCore` | `UpdateEngine` |

### Acyclicity Verification

The graph has two terminal nodes: `ConsumerRuntime` (read-side terminal) and `UpdateEngine` (write-side terminal). Both are imported only by the application target. No cycles exist.

**Topological order (build order):**
1. `DIRCore`
2. `ProducerRuntime`, `IndexRuntime`, `StorageEngine` (independent, parallelizable)
3. `RetrievalRuntime`, `UpdateEngine` (depend on level 2)
4. `ContextAssembly` (depends on level 3)
5. `ConsumerRuntime` (depends on level 4)

### Cross-Subsystem Communication Without Direct Import

Two cross-module interactions exist where modules must communicate but must not import each other:

**1. Consumer → Update Engine (demand signals): DDS-009:PC-4 → DDS-007:PC-2**

`ConsumerRuntime` emits advisory demand signals. `UpdateEngine` receives and processes them. These modules do not import each other.

**Resolution:** `DIRCore` defines a `DemandSignalSink` protocol. `UpdateEngine` conforms to it. The composition root injects the `UpdateEngine` instance (as `DemandSignalSink`) into `ConsumerRuntime`. `ConsumerRuntime` imports only `DIRCore`, not `UpdateEngine`.

**2. Update Engine → DIR read path (producer reads): DDS-001:PC-8 → DDS-002:PC-3**

Producers within `ProducerRuntime` need DIR read access during execution. The DIR runtime lives in `UpdateEngine`. `ProducerRuntime` does not import `UpdateEngine`.

**Resolution:** `DIRCore` defines the DIR read protocols (`DIRReadAccess`, `UnitResolution`). `UpdateEngine` conforms to them. The composition root injects the `UpdateEngine` instance (as `DIRReadAccess`) into `ProducerRuntime`. `ProducerRuntime` imports only `DIRCore`.

**3. Storage Engine ↔ Update Engine coordination: DDS-008:PC-11 → DDS-007 change notification**

`StorageEngine` receives change batch notifications from `UpdateEngine` for incremental grounding map maintenance. `UpdateEngine` imports `StorageEngine` directly. `StorageEngine` does not import `UpdateEngine`.

**Resolution:** `DIRCore` defines a `ChangeBatchObserver` protocol. `StorageEngine` conforms to it. `UpdateEngine` holds a reference to `StorageEngine` (it already imports `StorageEngine`) and calls its `ChangeBatchObserver` conformance directly.

---

## 4. Protocol Ownership Rules

### Ownership Principle

Every cross-module protocol is **defined in the module that is depended upon** (the upstream module in the dependency graph). Consumers import the upstream module and program against its protocols.

Exception: When two modules must communicate but neither imports the other (§3 cross-subsystem communication), the protocol is defined in `DIRCore` — the foundation module that both import.

### Protocol Inventory

| Protocol | Defined In | Realizes DDS Contract | Implemented By | Consumed By |
|----------|-----------|----------------------|----------------|-------------|
| `DIRReadAccess` | `DIRCore` | DDS-002:PC-3 (consumer reads), PC-5 (identity resolution) | `UpdateEngine` | `ProducerRuntime`, `RetrievalRuntime`, `StorageEngine` |
| `DIRWriteAccess` | `DIRCore` | DDS-002:PC-1 (admission), PC-2 (status transition), PC-6 (write transaction) | `UpdateEngine` | `ProducerRuntime`, `StorageEngine` |
| `EpochControl` | `DIRCore` | DDS-002:PC-4 (epoch advancement), PC-3(b) (within-cycle visibility) | `UpdateEngine` | (internal to `UpdateEngine`) |
| `ProducerRegistry` | `ProducerRuntime` | DDS-001:PC-1, PC-3, PC-4 | `ProducerRuntime` | `UpdateEngine` |
| `ExecutionDirective` | `ProducerRuntime` | DDS-001:PC-9 (execution tickets) | (consumed by `ProducerRuntime`) | `UpdateEngine` |
| `FailureReportSource` | `ProducerRuntime` | DDS-001:PC-6 | `ProducerRuntime` | `UpdateEngine` |
| `IndexQuerying` | `IndexRuntime` | DDS-004:PC-1 | `IndexRuntime` | `RetrievalRuntime` |
| `IndexFreshness` | `IndexRuntime` | DDS-004:PC-3 | `IndexRuntime` | `RetrievalRuntime` |
| `IndexBatchUpdate` | `IndexRuntime` | DDS-004:PC-4 | `IndexRuntime` | `UpdateEngine` |
| `EvidenceRetrieval` | `RetrievalRuntime` | DDS-005:PC-1, PC-2 | `RetrievalRuntime` | `ContextAssembly` |
| `ContextAssembling` | `ContextAssembly` | DDS-006:PC-1 | `ContextAssembly` | `ConsumerRuntime` |
| `StrategyManagement` | `ContextAssembly` | DDS-006:PC-2, PC-3 | `ContextAssembly` | Application target |
| `ConsumerInvocation` | `ConsumerRuntime` | DDS-009:PC-1 | `ConsumerRuntime` | Application target |
| `ReasoningEngineManagement` | `ConsumerRuntime` | DDS-009:PC-2, PC-3 | `ConsumerRuntime` | Application target |
| `DemandSignalSink` | `DIRCore` | DDS-007:PC-2 (counterparty to DDS-009:PC-4) | `UpdateEngine` | `ConsumerRuntime` |
| `ChangeBatchObserver` | `DIRCore` | DDS-008:PC-11 | `StorageEngine` | `UpdateEngine` |
| `SnapshotPersistence` | `StorageEngine` | DDS-008:PC-1, PC-2 | `StorageEngine` | `UpdateEngine` |
| `GarbageCollector` | `StorageEngine` | DDS-008:PC-3 | `StorageEngine` | `UpdateEngine` |
| `GroundingMapAccess` | `StorageEngine` | DDS-008:PC-4 | `StorageEngine` | `UpdateEngine` |
| `ContentHashMapAccess` | `StorageEngine` | DDS-008:PC-5 | `StorageEngine` | `UpdateEngine` |
| `DeferredQueuePersistence` | `StorageEngine` | DDS-008:PC-6 | `StorageEngine` | `UpdateEngine` |

### Protocols Defined in DIRCore

`DIRCore` defines protocols beyond its own type contracts in two cases:

1. **DIR runtime access protocols** (`DIRReadAccess`, `DIRWriteAccess`): These realize DDS-002 contracts that are consumed by modules across the entire graph. The implementation lives in `UpdateEngine`, but the protocol must be importable by `ProducerRuntime`, `RetrievalRuntime`, and `StorageEngine` — none of which import `UpdateEngine`.

2. **Cross-graph communication protocols** (`DemandSignalSink`, `ChangeBatchObserver`): These connect modules that must not import each other. Both modules import `DIRCore`, so the protocol is defined there.

### Protocol Ownership Rule Summary

| Rule | Application |
|------|-------------|
| Protocol defined in upstream module | `IndexQuerying` in `IndexRuntime`, `EvidenceRetrieval` in `RetrievalRuntime`, `ContextAssembling` in `ContextAssembly`, etc. |
| Protocol defined in foundation when neither module imports the other | `DemandSignalSink` in `DIRCore` (connects `ConsumerRuntime` ↔ `UpdateEngine`), `ChangeBatchObserver` in `DIRCore` |
| Protocol defined in foundation when implementation location differs from consumption | `DIRReadAccess`, `DIRWriteAccess` in `DIRCore` (implemented by `UpdateEngine`, consumed by many) |

---

## 5. Repository Directory Layout

### Layout

```
Decode/
  App/                              → DecodeApp, AppDependencies, ContentView (existing)
  Application/                      → Coordinators, managers, services (existing)
  Domain/                           → Models, Protocols, Services (existing)
  Infrastructure/                   → AI, AST, Capture, etc. (existing)
  Presentation/                     → Overlay, Session, etc. (existing)

  Understanding/                    → Understanding pipeline root
    DIRCore/                        → M1: Shared types and protocols
      Types/                        →   Unit, Identity, Epoch, Status, Tier, etc.
      Protocols/                    →   DIRReadAccess, DIRWriteAccess, DemandSignalSink, etc.
    ProducerRuntime/                → M2: DDS-001 + DDS-003
      Producer/                     →   Registry, DAG, execution orchestration
      Pass/                         →   Invocation, input assembly, output pipeline, comparison
    IndexRuntime/                   → M3: DDS-004
      Families/                     →   Entity, Graph, Predicate, Content, Scope
    RetrievalRuntime/               → M4: DDS-005
      Pipeline/                     →   Five-stage evidence retrieval
    ContextAssembly/                → M5: DDS-006
      Strategy/                     →   Catalog, stratum selection, coherence
    ConsumerRuntime/                → M6: DDS-009
      Engine/                       →   Reasoning engine registry, invocation
      Verification/                 →   Grounding, confidence propagation
    UpdateEngine/                   → M7: DDS-007 + DDS-002 runtime
      DIR/                          →   Unit store, intake validation, epoch management
      ChangeDetection/              →   File-level, entity-level, content hash
      Invalidation/                 →   Cascade, grounding chain traversal
      Pipeline/                     →   Synchronous pipeline, deferred pipeline
    StorageEngine/                  → M8: DDS-008
      Snapshot/                     →   Capture, loading, validation
      GC/                          →   Garbage collection, retention policy
      GroundingMap/                 →   Dependency map construction, maintenance
```

### Layout Rules

| Rule | Statement |
|------|-----------|
| **LR-1** | Each module occupies exactly one top-level directory under `Understanding/`. |
| **LR-2** | No source file exists directly under `Understanding/`. All source files exist within a module directory. |
| **LR-3** | Subdirectories within a module are organizational. They do not affect module boundaries or import visibility. |
| **LR-4** | The existing Decode application code (`App/`, `Application/`, `Domain/`, `Infrastructure/`, `Presentation/`) is unchanged. It remains in the application target and imports understanding pipeline modules as needed. |
| **LR-5** | Each module's directory name matches its target name in the build configuration. |

---

## 6. Composition Root

### Location

The understanding pipeline composition root is a single type — `UnderstandingSystem` — located in the application target at `Decode/App/UnderstandingSystem.swift`.

### Rationale

The composition root must import every understanding pipeline module to create and wire all subsystem instances. Placing it in the application target (which already imports everything) avoids creating a ninth module solely for composition. The existing `AppDependencies` creates and owns the `UnderstandingSystem` instance.

### Ownership Chain

```
AppDependencies (existing)
  └── UnderstandingSystem (composition root)
        ├── owns StorageEngine instance
        ├── owns UpdateEngine instance (receives StorageEngine, ProducerRuntime)
        │     └── contains DIR runtime (unit store, epoch)
        ├── owns ProducerRuntime instance (receives DIRReadAccess, DIRWriteAccess)
        ├── owns IndexRuntime instance (receives DIRReadAccess)
        ├── owns RetrievalRuntime instance (receives IndexQuerying, IndexFreshness, DIRReadAccess)
        ├── owns ContextAssembly instance (receives EvidenceRetrieval)
        └── owns ConsumerRuntime instance (receives ContextAssembling, DemandSignalSink)
```

### Composition Responsibilities

`UnderstandingSystem` owns exactly two responsibilities: **construction** and **wiring**.

1. **Construction** — Create each subsystem instance in dependency order (bottom-up: `DIRCore` types are value types requiring no instantiation; `StorageEngine` → `UpdateEngine` → `ProducerRuntime` → `IndexRuntime` → `RetrievalRuntime` → `ContextAssembly` → `ConsumerRuntime`).

2. **Wiring** — Inject protocol-typed dependencies into each subsystem. Every cross-module dependency is injected as a protocol (see §4), never as a concrete type from another module.

The composition root also exposes **lifecycle entry points** (start, shutdown) that delegate to subsystem state transitions. The startup sequence follows the DDS state models: `StorageEngine` loads snapshot → `UpdateEngine` enters Reconciling → `ProducerRuntime` enters Ready → pipeline becomes operational. Shutdown proceeds in reverse. The composition root calls lifecycle methods on subsystem instances; it does not make lifecycle decisions — those are defined by each subsystem's DDS state model.

### What UnderstandingSystem Must Never Contain

| Prohibition | Rationale | Owner |
|-------------|-----------|-------|
| Runtime policy | GC retention policy, cascade boundary rules, scheduling priority — these are DDS-specified subsystem decisions | The subsystem module whose DDS defines the policy |
| Business logic | Change detection logic, invalidation propagation, context strategy selection, grounding verification | The subsystem module whose DDS defines the responsibility |
| Scheduling decisions | When to run pipelines, how to prioritize deferred recomputation, whether to act on demand signals | `UpdateEngine` (DDS-007) exclusively owns all scheduling |
| Lifecycle state machines | State transitions, transition guards, valid/invalid transition enforcement | Each subsystem module per its DDS state model |
| Subsystem coordination logic | Within-cycle visibility, epoch advancement timing, cascade ordering | `UpdateEngine` (DDS-007) exclusively owns pipeline coordination |
| Configuration interpretation | What parameter values mean, how configuration affects subsystem behavior | Each subsystem module |

**Enforcement test:** If removing a line of code from `UnderstandingSystem` would change the system's runtime behavior (not just which instances exist or how they are connected), that code does not belong in the composition root — it belongs in a subsystem module.

The application interacts with the understanding pipeline through `ConsumerInvocation` (for queries) and `UnderstandingSystem` lifecycle entry points (for startup/shutdown). `UnderstandingSystem` does not expose subsystem internals to the application.

---

## 7. Dependency Injection Strategy

### Pattern

Manual constructor injection. No DI framework.

**Rationale:** The understanding pipeline has 8 modules with well-defined dependency edges. The total number of injection points is bounded (approximately 15-20 protocol injections across all modules). A DI framework would add a dependency, obscure the wiring, and provide no benefit at this scale. This is consistent with the existing Decode application's pattern (`AppDependencies` uses manual DI).

### Injection Rules

| Rule | Statement |
|------|-----------|
| **IR-1** | Every cross-module dependency is injected as a **protocol type**, never a concrete type. |
| **IR-2** | Injection happens at construction time (constructor injection), not post-construction. |
| **IR-3** | No module creates instances of types from another module. Only the composition root creates subsystem instances. |
| **IR-4** | Subsystem initializers declare their dependencies as protocol-typed parameters. The parameter list is the module's complete external dependency surface. |
| **IR-5** | No service locator, no global singletons, no ambient authority. Every dependency is explicit in the initializer signature. |

### Injection Examples by Module

| Module | Constructor Receives | Protocol Types |
|--------|---------------------|----------------|
| `StorageEngine` | DIR read access, DIR write access | `DIRReadAccess`, `DIRWriteAccess` (from `DIRCore`) |
| `UpdateEngine` | Producer execution, index update, snapshot persistence, GC, grounding map, content hashes, deferred queue, change batch observer | `ExecutionDirective`, `IndexBatchUpdate`, `SnapshotPersistence`, `GarbageCollector`, `GroundingMapAccess`, `ContentHashMapAccess`, `DeferredQueuePersistence`, `ChangeBatchObserver` (from `ProducerRuntime`, `IndexRuntime`, `StorageEngine`, `DIRCore`) |
| `ProducerRuntime` | DIR read, DIR write | `DIRReadAccess`, `DIRWriteAccess` (from `DIRCore`) |
| `IndexRuntime` | DIR read, unit resolution | `DIRReadAccess` (from `DIRCore`) |
| `RetrievalRuntime` | Index query, index freshness, DIR read | `IndexQuerying`, `IndexFreshness` (from `IndexRuntime`), `DIRReadAccess` (from `DIRCore`) |
| `ContextAssembly` | Evidence retrieval | `EvidenceRetrieval` (from `RetrievalRuntime`) |
| `ConsumerRuntime` | Context assembly, demand signal sink | `ContextAssembling` (from `ContextAssembly`), `DemandSignalSink` (from `DIRCore`) |

### Circular Dependency Prevention

The injection rules make circular dependencies structurally impossible:

1. Modules only depend on protocol types from modules they import (§3 dependency graph).
2. The dependency graph is acyclic (§3 verification).
3. The composition root creates instances in topological order — a module's dependencies always exist before the module is constructed.

---

## 8. Test Target Organization

### Test Target Inventory

| Test Target | Tests Module | Dependencies |
|-------------|-------------|--------------|
| `DIRCoreTests` | `DIRCore` | `DIRCore`, `UnderstandingTestSupport` |
| `ProducerRuntimeTests` | `ProducerRuntime` | `ProducerRuntime`, `DIRCore`, `UnderstandingTestSupport` |
| `IndexRuntimeTests` | `IndexRuntime` | `IndexRuntime`, `DIRCore`, `UnderstandingTestSupport` |
| `RetrievalRuntimeTests` | `RetrievalRuntime` | `RetrievalRuntime`, `IndexRuntime`, `DIRCore`, `UnderstandingTestSupport` |
| `ContextAssemblyTests` | `ContextAssembly` | `ContextAssembly`, `RetrievalRuntime`, `DIRCore`, `UnderstandingTestSupport` |
| `ConsumerRuntimeTests` | `ConsumerRuntime` | `ConsumerRuntime`, `ContextAssembly`, `DIRCore`, `UnderstandingTestSupport` |
| `UpdateEngineTests` | `UpdateEngine` | `UpdateEngine`, `ProducerRuntime`, `IndexRuntime`, `StorageEngine`, `DIRCore`, `UnderstandingTestSupport` |
| `StorageEngineTests` | `StorageEngine` | `StorageEngine`, `DIRCore`, `UnderstandingTestSupport` |
| `UnderstandingIntegrationTests` | Cross-module | All modules, `UnderstandingTestSupport` |

### Test Target Rules

| Rule | Statement |
|------|-----------|
| **TR-1** | Each module has exactly one unit test target. The test target name is the module name suffixed with `Tests`. |
| **TR-2** | A unit test target imports the module under test and its transitive dependencies. It does not import sibling modules (modules at the same dependency level that the module under test does not import). |
| **TR-3** | Cross-module dependencies in tests are replaced by test doubles from `UnderstandingTestSupport`. A unit test for `RetrievalRuntime` uses a mock `IndexQuerying`, not the real `IndexRuntime`. |
| **TR-4** | One integration test target (`UnderstandingIntegrationTests`) tests cross-module contract counterparties with real implementations. |
| **TR-5** | The integration test target imports all modules. It verifies that offered/required contract pairs (e.g., DDS-005:PC-3 ↔ DDS-004:PC-1) produce correct results when connected with real implementations. |

### Test Directory Layout

```
DecodeTests/                             → Existing application tests (unchanged)
UnderstandingTests/                      → Understanding pipeline test root
  DIRCoreTests/
  ProducerRuntimeTests/
  IndexRuntimeTests/
  RetrievalRuntimeTests/
  ContextAssemblyTests/
  ConsumerRuntimeTests/
  UpdateEngineTests/
  StorageEngineTests/
  UnderstandingIntegrationTests/
  UnderstandingTestSupport/              → Shared test doubles (framework target)
```

---

## 9. Shared Test Infrastructure Strategy

### UnderstandingTestSupport Module

A framework target containing shared test doubles for all cross-module protocols. Imported by every test target.

### Test Double Inventory

Every protocol defined in §4 that is used as a cross-module dependency injection point requires a test double in `UnderstandingTestSupport`.

| Test Double | Mocks Protocol | Used By Test Targets |
|-------------|---------------|---------------------|
| `MockDIRReadAccess` | `DIRReadAccess` | `ProducerRuntimeTests`, `IndexRuntimeTests`, `RetrievalRuntimeTests`, `StorageEngineTests` |
| `MockDIRWriteAccess` | `DIRWriteAccess` | `ProducerRuntimeTests`, `StorageEngineTests` |
| `MockIndexQuerying` | `IndexQuerying` | `RetrievalRuntimeTests` |
| `MockIndexFreshness` | `IndexFreshness` | `RetrievalRuntimeTests` |
| `MockIndexBatchUpdate` | `IndexBatchUpdate` | `UpdateEngineTests` |
| `MockEvidenceRetrieval` | `EvidenceRetrieval` | `ContextAssemblyTests` |
| `MockContextAssembling` | `ContextAssembling` | `ConsumerRuntimeTests` |
| `MockDemandSignalSink` | `DemandSignalSink` | `ConsumerRuntimeTests` |
| `MockChangeBatchObserver` | `ChangeBatchObserver` | `UpdateEngineTests` |
| `MockProducerExecution` | `ExecutionDirective` | `UpdateEngineTests` |
| `MockSnapshotPersistence` | `SnapshotPersistence` | `UpdateEngineTests` |
| `MockGarbageCollector` | `GarbageCollector` | `UpdateEngineTests` |
| `MockGroundingMapAccess` | `GroundingMapAccess` | `UpdateEngineTests` |
| `MockContentHashMapAccess` | `ContentHashMapAccess` | `UpdateEngineTests` |

### Test Double Design Rules

| Rule | Statement |
|------|-----------|
| **TD-1** | Every test double is configurable: its return values, its error behavior, and its call recording are controlled by the test. |
| **TD-2** | Test doubles record all calls (method name, arguments) for assertion. |
| **TD-3** | Test doubles are defined in `UnderstandingTestSupport`, not in individual test targets. A protocol has exactly one test double, shared across all test targets that need it. |
| **TD-4** | Test doubles implement the protocol contract's success path by default. Tests that need failure behavior configure the test double explicitly. |

### Test Double Exclusions

`DIRCore` types (Unit, Epoch, Status, etc.) are value types. They are not mocked — tests construct real instances. Test doubles exist only for protocols representing subsystem behavior.

### Factory Utilities

`UnderstandingTestSupport` includes factory functions for constructing `DIRCore` value types with test-appropriate defaults:

- `makeUnit(subject:predicate:tier:...)` — Creates a unit with sensible defaults for fields not under test.
- `makeEpoch(value:)` — Creates an epoch value.
- `makeProvenance(producer:...)` — Creates provenance with test defaults.

These factories reduce test boilerplate without hiding the types' structure.

---

## 10. Traceability: DDS Contracts to Module Boundaries

### Traceability Model

Every DDS public contract traces through a three-level chain:

```
DDS Contract → Protocol → Module
```

- **DDS Contract**: The behavioral specification (e.g., DDS-002:PC-1).
- **Protocol**: The Swift protocol that realizes the contract surface (e.g., `DIRWriteAccess`).
- **Module**: The module where the protocol is defined, the module that implements it, and the module(s) that consume it.

Internal contracts (where both sides live in the same module) trace to internal protocols — the DDS contract is preserved architecturally but not enforced at the build-system level.

### Contract Traceability Map

#### DDS-002: DIR Runtime Model

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Unit Admission) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime`, `StorageEngine` |
| PC-2 (Status Transition) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime`, `StorageEngine` |
| PC-3(a) (Consumer Reads) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime`, `RetrievalRuntime`, `StorageEngine` |
| PC-3(b) (Pipeline-Internal Reads) | `EpochControl` (internal) | `DIRCore` | `UpdateEngine` | `UpdateEngine` (internal) |
| PC-4 (Epoch Advancement) | `EpochControl` (internal) | `DIRCore` | `UpdateEngine` | `UpdateEngine` (internal) |
| PC-5 (Unit Identity Resolution) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime`, `RetrievalRuntime`, `StorageEngine` |
| PC-6 (Write Transaction) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime`, `StorageEngine` |
| PC-7 (GC Directives) | `GarbageCollector` → `DIRWriteAccess` | `StorageEngine` / `DIRCore` | `StorageEngine` / `UpdateEngine` | `UpdateEngine` / `StorageEngine` |
| PC-8 (Snapshot Capture) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `StorageEngine` |

#### DDS-001: Producer Runtime + DDS-003: Pass Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| DDS-001:PC-1 (Registration) | `ProducerRegistry` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-001:PC-2 (Execution) | `ExecutionDirective` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-001:PC-3 (DAG Query) | `ProducerRegistry` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-001:PC-4 (Discovery) | `ProducerRegistry` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-001:PC-5 (Batch Execution) | `ExecutionDirective` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-001:PC-6 (Failure Report) | `FailureReportSource` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-001:PC-7 (DIR Write) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime` |
| DDS-001:PC-8 (DIR Read) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime` |
| DDS-001:PC-9 (Execution Directives) | `ExecutionDirective` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| DDS-003:PC-1 (Pass Invocation) | Internal protocol | `ProducerRuntime` | `ProducerRuntime` | `ProducerRuntime` (internal) |
| DDS-003:PC-2 (Input Assembly) | Internal protocol | `ProducerRuntime` | `ProducerRuntime` | `ProducerRuntime` (internal) |
| DDS-003:PC-3 (Changed Output) | Internal protocol | `ProducerRuntime` | `ProducerRuntime` | `ProducerRuntime` (internal) |
| DDS-003:PC-4 (Cancellation) | Internal protocol | `ProducerRuntime` | `ProducerRuntime` | `ProducerRuntime` (internal) |
| DDS-003:PC-5 (DIR Read) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime` |
| DDS-003:PC-6 (DIR Write) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `ProducerRuntime` |
| DDS-003:PC-7 (Pass Contract Query) | Internal protocol | `ProducerRuntime` | `ProducerRuntime` | `ProducerRuntime` (internal) |

#### DDS-004: Index Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Index Query) | `IndexQuerying` | `IndexRuntime` | `IndexRuntime` | `RetrievalRuntime` |
| PC-2 (Index Rebuild) | Internal | `IndexRuntime` | `IndexRuntime` | `IndexRuntime` (internal) |
| PC-3 (Freshness Report) | `IndexFreshness` | `IndexRuntime` | `IndexRuntime` | `RetrievalRuntime` |
| PC-4 (Batch Update) | `IndexBatchUpdate` | `IndexRuntime` | `IndexRuntime` | `UpdateEngine` |
| PC-5 (DIR Read) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `IndexRuntime` |
| PC-6 (Change Batch Delivery) | `IndexBatchUpdate` | `IndexRuntime` | `IndexRuntime` | `UpdateEngine` |
| PC-7 (Unit Resolution) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `IndexRuntime` |

#### DDS-005: Retrieval Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Evidence Retrieval) | `EvidenceRetrieval` | `RetrievalRuntime` | `RetrievalRuntime` | `ContextAssembly` |
| PC-2 (Anchor Resolution) | `EvidenceRetrieval` | `RetrievalRuntime` | `RetrievalRuntime` | `ContextAssembly` |
| PC-3 (Index Query) | `IndexQuerying` | `IndexRuntime` | `IndexRuntime` | `RetrievalRuntime` |
| PC-4 (DIR Read) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `RetrievalRuntime` |
| PC-5 (Unit Resolution) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `RetrievalRuntime` |
| PC-6 (Freshness Report) | `IndexFreshness` | `IndexRuntime` | `IndexRuntime` | `RetrievalRuntime` |

#### DDS-006: Context Assembly Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Context Assembly) | `ContextAssembling` | `ContextAssembly` | `ContextAssembly` | `ConsumerRuntime` |
| PC-2 (Strategy Registration) | `StrategyManagement` | `ContextAssembly` | `ContextAssembly` | Application target |
| PC-3 (Catalog Query) | `StrategyManagement` | `ContextAssembly` | `ContextAssembly` | Application target |
| PC-4 (Evidence Set) | `EvidenceRetrieval` | `RetrievalRuntime` | `RetrievalRuntime` | `ContextAssembly` |

#### DDS-007: Update Engine Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Change Set Processing) | Direct public API | `UpdateEngine` | `UpdateEngine` | Application target |
| PC-2 (Deferred Recomputation) | `DemandSignalSink` | `DIRCore` | `UpdateEngine` | `ConsumerRuntime` |
| PC-3 (Producer Upgrade) | Direct public API | `UpdateEngine` | `UpdateEngine` | Application target |
| PC-4 (Reconciliation) | Direct public API | `UpdateEngine` | `UpdateEngine` | `UnderstandingSystem` |
| PC-5 (Producer Execution) | `ExecutionDirective` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| PC-6 (DIR Write) | Internal (colocated) | `UpdateEngine` | `UpdateEngine` | `UpdateEngine` (internal) |
| PC-7 (Epoch Advancement) | Internal (colocated) | `UpdateEngine` | `UpdateEngine` | `UpdateEngine` (internal) |
| PC-8 (DAG/Producer Query) | `ProducerRegistry` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |
| PC-9 (Index Update Delivery) | `IndexBatchUpdate` | `IndexRuntime` | `IndexRuntime` | `UpdateEngine` |
| PC-10 (Grounding Chain Traversal) | `GroundingMapAccess` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-11 (DIR Read) | Internal (colocated) | `UpdateEngine` | `UpdateEngine` | `UpdateEngine` (internal) |
| PC-12 (Failure Report) | `FailureReportSource` | `ProducerRuntime` | `ProducerRuntime` | `UpdateEngine` |

#### DDS-008: Storage Engine Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Snapshot Capture) | `SnapshotPersistence` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-2 (Snapshot Loading) | `SnapshotPersistence` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-3 (GC Execution) | `GarbageCollector` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-4 (Grounding Map) | `GroundingMapAccess` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-5 (Content Hash Map) | `ContentHashMapAccess` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-6 (Deferred Queue) | `DeferredQueuePersistence` | `StorageEngine` | `StorageEngine` | `UpdateEngine` |
| PC-7 (DIR Read) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `StorageEngine` |
| PC-8 (DIR Write) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `StorageEngine` |
| PC-9 (DIR Status Transitions) | `DIRWriteAccess` | `DIRCore` | `UpdateEngine` | `StorageEngine` |
| PC-10 (Unit Resolution) | `DIRReadAccess` | `DIRCore` | `UpdateEngine` | `StorageEngine` |
| PC-11 (Change Batch) | `ChangeBatchObserver` | `DIRCore` | `StorageEngine` | `UpdateEngine` |

#### DDS-009: Consumer Runtime

| DDS Contract | Protocol | Defined In | Implemented By | Consumed By |
|-------------|----------|-----------|----------------|-------------|
| PC-1 (Consumer Invocation) | `ConsumerInvocation` | `ConsumerRuntime` | `ConsumerRuntime` | Application target |
| PC-2 (Engine Registration) | `ReasoningEngineManagement` | `ConsumerRuntime` | `ConsumerRuntime` | Application target |
| PC-3 (Engine Catalog Query) | `ReasoningEngineManagement` | `ConsumerRuntime` | `ConsumerRuntime` | Application target |
| PC-4 (Demand Signal) | `DemandSignalSink` | `DIRCore` | `UpdateEngine` | `ConsumerRuntime` |
| PC-5 (Context Frame) | `ContextAssembling` | `ContextAssembly` | `ContextAssembly` | `ConsumerRuntime` |
| PC-6 (Deferred Recomputation) | `DemandSignalSink` | `DIRCore` | `UpdateEngine` | `ConsumerRuntime` |

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-06-28 | Initial draft. Complete module decomposition, dependency graph, protocol ownership, directory layout, composition root, DI strategy, test organization, DDS traceability. |
| 0.2 | 2026-06-28 | CTO review revisions. (1) Strengthened merged module rationale for ProducerRuntime (DDS-001+DDS-003) and UpdateEngine (DDS-007+DDS-002 runtime) — added why-separate-DDS-one-module justification, single-responsibility argument, and future split conditions for each. (2) Strengthened DIRCore boundary — defined as foundation module with explicit allowed/prohibited content categories and enforcement test. (3) Strengthened composition root ownership — explicitly limited to construction and wiring; prohibited runtime policy, business logic, scheduling, lifecycle decisions, coordination. (4) Extended traceability to explicit DDS Contract → Protocol → Defined In → Implemented By → Consumed By five-column format for all contracts. |
