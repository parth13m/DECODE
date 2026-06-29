# DDS-002: DIR Runtime Model

```
Document:      DDS-002
Title:         DIR Runtime Model
Status:        Draft
Version:       0.3
Author:        Principal Engineer
Reviewers:     —
Created:       2026-06-28
Last Revised:  2026-06-28
Depends On:    DDS-000 (Design Authoring Standard)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-010, DAS-012
```

## Abstract

This document specifies the engineering design of the DIR Runtime Model — the subsystem that manages the runtime lifecycle, identity, immutability, ownership, read/write semantics, visibility, consistency, and tier enforcement of atomic units within the Decode Intermediate Representation. It realizes the atomic unit contract defined in DAS-002, the tier-confidence and supersession constraints from DAS-003, the epoch-based consistency model from DAS-010, and the in-memory unit store contract from DAS-012. The DIR Runtime Model owns the unit store and epoch counter; it does not own producer execution, change detection, index construction, or snapshot persistence.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P1 (intelligence is the canonical asset — the DIR Runtime is the
            runtime custodian of Intelligence), P5 (grounding — grounding chain
            integrity enforced at write boundary), P9 (incremental — per-unit
            lifecycle enables scoped invalidation), P12 (graceful degradation —
            invalidated units remain queryable)
  Not addressed: P2, P3, P4 (realized by DDS-001 and DDS for Update Engine
                 via tier-ordered execution), P6, P7 (DDS for Context Assembly),
                 P8 (DDS-001 — semantic passes consume DIR), P10 (DDS for
                 Consumer Architecture), P11 (DDS-001 — producer independence)

DAS-002: Decode Intermediate Representation
  Realized: Atomic unit contract (all 10 fields — identity, subject, predicate,
            value, tier, provenance, confidence, grounding, version, status),
            I-ID-1, I-ID-2, I-ID-3 (identity invariants),
            I-SUB-1, I-SUB-2, I-SUB-3 (subject invariants),
            I-PRED-1, I-PRED-3 (predicate registry and competition),
            I-VAL-1, I-VAL-2 (value immutability and structure),
            I-TIER-3 (tier immutability), I-TIER-4 (tier-MDT compliance),
            I-TIER-5 (derivation monotonicity — validated at write),
            I-PROV-1, I-PROV-2 (provenance immutability and interpretability),
            I-CONF-1 through I-CONF-4 (confidence model),
            I-GND-1, I-GND-2, I-GND-4 (grounding structure and traversability),
            I-VER-1, I-VER-2, I-VER-3, I-VER-4 (version contract),
            I-LC-1 through I-LC-5 (lifecycle model),
            I1 (DIR completeness — enforced at the runtime boundary),
            I2 (atomic unit immutability — enforced at write),
            DC-4 (DIR exists independently of queries)
  Not addressed: I3 (grounding termination — enforced transitively by
                 DDS-001 output validation and DDS for Update Engine cascade),
                 I4 (tier monotonicity — partially enforced here via I-TIER-5
                 validation, fully by DDS-001 DAG ordering),
                 I5 (predicate registry append-only — the registry is a
                 code-defined structure per DAS-012, not a runtime concern),
                 I6 (frontend determinism — DDS-001),
                 I7 (pass grounding — DDS-001 output validation),
                 I8 (index derivability — DDS for Index Manager),
                 DC-1 (language independence — structural, not runtime),
                 DC-2 (selective abstraction — structural, not runtime),
                 DC-3 (stable contract — structural, not runtime),
                 DC-5 (rebuildable from source — DDS for Storage Engine)

DAS-003: Tier Model
  Realized: I1 (tier totality — validated at write), I2 (T0 deterministic
            confidence — validated at write), I3 (derivation monotonicity —
            validated at write via provenance inputs), I4 (MDT compliance —
            validated at write), I6 (tier immutability — enforced by unit
            immutability), TL-2 (supersession respects tier — enforced by
            supersession key)
  Not addressed: I5 (freshness ordering — DDS for Update Engine),
                 I7 (degradation validity — DDS for Retrieval/Context Assembly),
                 Freshness contracts enforcement (DDS for Update Engine),
                 Confidence model per tier (defined in DAS-003, consumed by
                 context assembly — DDS for Context Assembly),
                 TL-1 (recomputation priority — DDS for Update Engine),
                 TL-3 (GC eligibility by tier — DDS for Storage Engine)

DAS-010: Incremental Update Model
  Realized: WR-1, WR-2, WR-3 (epoch-based consistency — epoch counter
            ownership and advancement), WR-5 (query during processing —
            prior-epoch visibility), WR-6, WR-7 (invalidated content
            visibility and metadata),
            I1 (epoch consistency — enforced by synchronous pipeline
            completion before epoch advance),
            I4 (change set atomicity — enforced by epoch model)
  Not addressed: Change detection (CD-1 through CD-6 — DDS for Update Engine),
                 Invalidation propagation (IP-1 through IP-6 — DDS for
                 Update Engine), Cascade boundaries (CB-1 through CB-4 —
                 DDS for Update Engine), Recomputation scheduling (RS-1
                 through RS-10 — DDS for Update Engine),
                 WR-4 (concurrent change sets — DDS for Update Engine
                 serialization), Index maintenance (IM-1 through IM-6 —
                 DDS for Index Manager),
                 I2 (cascade directionality — DDS for Update Engine),
                 I3 (early termination — DDS for Update Engine),
                 I5 (grounding chain completeness — DDS for Update Engine),
                 I6 (content-hash idempotency — DDS for Update Engine),
                 I7 (index-DIR consistency — DDS for Index Manager),
                 I8 (sequential change set processing — DDS for Update Engine)

DAS-012: Storage Realization
  Realized: Unit store structure (primary key by unit ID, lifecycle
            partitioning), supersession key (subject, predicate, tier),
            unit identity generation (monotonic counter),
            epoch counter realization (single 64-bit integer),
            I8 (memory boundedness — ownership of unit store memory)
  Not addressed: Snapshot persistence (I1, I2 — DDS for Storage Engine),
                 index storage (I3 — DDS for Index Manager),
                 reconciliation (I4 — DDS for Storage Engine),
                 grounding dependency map (I6 — DDS for Update Engine
                 or Storage Engine), GC retention policy and schedule
                 (I7 — DDS for Storage Engine)
```

## Terminology

**Unit Store** — The runtime data structure that holds all atomic units during operation. The unit store is the in-memory realization of the DIR (DAS-012). All reads from the DIR query the unit store. All writes to the DIR modify the unit store. The DIR Runtime Model exclusively owns the unit store. `See DAS-012`

**Supersession Key** — The composite key (subject, predicate, tier) that identifies competing claims within the DIR. When a new unit is created with the same supersession key as an existing Active unit, the existing unit transitions to Superseded status. Units with the same subject and predicate at different tiers coexist — they are complementary, not competing. `See DAS-012, DAS-003 TL-2`

**Update Epoch** — A monotonically increasing counter identifying a consistent state of the DIR. The DIR Runtime Model owns the epoch counter and advances it when a synchronous pipeline completes. Queries reference the current committed epoch. `See DAS-010`

**Write Transaction** — A batch of unit operations (creations, status transitions) submitted to the DIR Runtime as an atomic group. A write transaction either commits entirely or is rejected entirely. Write transactions are the mechanism by which the Producer Runtime (DDS-001) commits output batches and by which the scheduling subsystem records invalidations. `INTRODUCED`

**Intake Validation** — The set of structural and contractual checks applied to every unit before it is admitted to the unit store. Intake validation enforces the DAS-002 atomic unit contract, the DAS-003 tier-confidence bounds, and provenance completeness. Intake validation is the DIR Runtime's gatekeeper — it is the last line of defense before a unit becomes part of the canonical asset. `INTRODUCED`

**Committed Epoch** — The most recently completed epoch whose state is visible to consumer queries. During synchronous pipeline execution, the committed epoch is the prior epoch — queries see the pre-change state. After epoch advancement, the new epoch becomes the committed epoch. `INTRODUCED`

---

## Responsibilities

```
R1: Own and manage the unit store — the authoritative in-memory collection
    of all atomic units in the DIR.
    DAS: DAS-002 I1 (DIR completeness — all non-source persistent state is
         DIR content or derived from it), DAS-012 (unit store structure),
         DAS-001 P1 (intelligence is the canonical asset)
    Boundary: The DIR Runtime owns the unit store's runtime state. Snapshot
              persistence of the unit store to disk is the Storage Engine's
              responsibility. Index structures derived from the unit store
              are the Index Manager's responsibility.

R2: Enforce the atomic unit contract at the write boundary — validate every
    unit entering the DIR against all DAS-002 field invariants, DAS-003
    tier-confidence bounds, and provenance completeness requirements.
    DAS: DAS-002 I-ID-1 through I-ID-3 (identity), I-SUB-1 through I-SUB-3
         (subject), I-PRED-1 (predicate registry membership), I-VAL-1, I-VAL-2
         (value), I-TIER-3, I-TIER-4, I-TIER-5 (tier), I-PROV-1, I-PROV-2
         (provenance), I-CONF-1 through I-CONF-4 (confidence), I-GND-1,
         I-GND-2 (grounding structure), I-VER-1, I-VER-3 (version)
    Boundary: The DIR Runtime validates structural conformance of incoming
              units. It does not validate semantic correctness of values —
              that is the producer's responsibility. It does not validate
              output completeness against producer contracts — that is
              DDS-001:R4. Intake validation is the second line of defense
              after DDS-001 output validation.

R3: Enforce atomic unit immutability — guarantee that once a unit is admitted
    to the unit store, its id, subject, predicate, value, tier, provenance,
    confidence, and grounding fields never change.
    DAS: DAS-002 I-LC-5 (immutability of all fields except status),
         DAS-002 I2 (atomic unit immutability)
    Boundary: Only the status field transitions, and only in permitted
              directions (Active → Invalidated, Active → Superseded).
              The DIR Runtime enforces transition legality.

R4: Manage atomic unit lifecycle — enforce the status state machine
    (Active → Invalidated, Active → Superseded, Superseded/Invalidated
    → Garbage Collected) and the supersession protocol.
    DAS: DAS-002 I-LC-1 through I-LC-4 (lifecycle rules),
         DAS-003 TL-2 (supersession respects tier),
         DAS-012 supersession key (subject, predicate, tier)
    Boundary: The DIR Runtime performs status transitions and supersession.
              Invalidation decisions (which units to invalidate) are made
              by the scheduling subsystem. Garbage collection eligibility
              is determined by the Storage Engine based on tier-informed
              retention policy (DAS-010 GC-1 through GC-4).

R5: Assign globally unique, immutable, opaque identifiers to every unit
    admitted to the DIR.
    DAS: DAS-002 I-ID-1 (uniqueness), I-ID-2 (no reassignment),
         I-ID-3 (no semantic content), DAS-012 (monotonic counter)
    Boundary: Identity generation is internal to the DIR Runtime.
              No external subsystem assigns unit identifiers.

R6: Own and advance the update epoch counter — maintain the monotonically
    increasing counter that identifies consistent DIR states.
    DAS: DAS-010 WR-1 (epoch definition), WR-3 (atomic epoch advancement),
         DAS-012 (epoch counter realization)
    Boundary: The DIR Runtime advances the epoch when instructed by the
              synchronous pipeline coordinator. It does not determine when
              the synchronous pipeline is complete — that is the scheduling
              subsystem's responsibility.

R7: Provide epoch-consistent read access — guarantee that consumer queries
    observe a consistent snapshot of the DIR at the committed epoch.
    DAS: DAS-010 WR-2 (snapshot queries), WR-5 (query during processing),
         WR-6 (invalidated units queryable), WR-7 (invalidation metadata)
    Boundary: The DIR Runtime provides read access to unit store contents
              at the committed epoch. Query optimization (indexes),
              filtering (by predicate, tier, scope), and result assembly
              are the responsibility of the Retrieval/Index subsystem.

R8: Enforce tier-confidence bounds — reject units whose confidence value
    violates the DAS-003 tier-confidence constraints.
    DAS: DAS-003 I2 (T0 requires deterministic confidence, T1/T2 forbid it)
    Boundary: The DIR Runtime enforces the bounds at intake. It does not
              assign confidence values — producers assign them.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Unit Admission
  Direction:    Offered
  Counterparty: Producer Runtime (DDS-001, via DDS-001:PC-7)
  Guarantee:    Every unit that passes intake validation is admitted to the
                unit store with a globally unique identifier (R5), Active
                lifecycle status (DAS-002 I-LC-1), and is immediately
                visible to subsequent writes within the same write
                transaction. If the new unit's supersession key (subject,
                predicate, tier) matches an existing Active unit, the
                existing unit is atomically transitioned to Superseded
                status (R4).
  Preconditions: The unit passes intake validation (R2): all 10 fields
                 present and well-formed, tier within {T0, T1, T2}, tier
                 does not exceed predicate MDT unless predicate permits
                 semantic tiers, confidence conforms to tier bounds
                 (DAS-003 I2), provenance includes producer identity and
                 method, grounding chain is non-empty and acyclic within
                 the submitted batch, version stamp is present.
  Failure mode: If any unit in a write transaction fails intake validation,
                the entire transaction is rejected. No units are admitted.
                The rejection includes a diagnostic identifying the unit
                and the specific validation failures.

PC-2: Status Transition
  Direction:    Offered
  Counterparty: Scheduling subsystem (for invalidation), Storage Engine
                (for garbage collection)
  Guarantee:    A unit's status is transitioned from its current state to
                the requested state, subject to the lifecycle state machine.
                Permitted transitions: Active → Invalidated, Active →
                Superseded (handled internally by PC-1 supersession),
                Invalidated → Superseded (when a replacement unit is
                admitted), Superseded → Garbage Collected, Invalidated →
                Garbage Collected. Invalidation records the epoch at which
                invalidation occurred and the reason (upstream change
                identifier) as invalidation metadata (DAS-010 WR-7).
  Preconditions: The unit exists in the unit store. The requested
                 transition is valid per the lifecycle state machine.
  Failure mode: If the transition is invalid (e.g., Superseded → Active,
                Terminated → Active, Active → Garbage Collected without
                intervening Invalidated/Superseded), the request is
                rejected with a diagnostic identifying the unit and the
                invalid transition.

PC-3: Epoch-Consistent Read
  Direction:    Offered
  Counterparty: Index/Retrieval subsystem, scheduling subsystem,
                observability consumers, Producer Runtime (DDS-001:PC-8)
  Guarantee:    The DIR Runtime supports two read contexts:

                (a) Consumer/external reads. Queries from the Index/Retrieval
                    subsystem, observability consumers, or any component
                    outside the synchronous pipeline always observe the
                    committed epoch. All units returned were Active or
                    Invalidated (if explicitly requested) at the committed
                    epoch. No partially-committed write transaction is
                    visible.

                (b) Pipeline-internal producer reads. During synchronous
                    pipeline execution, a producer read (as required by
                    DDS-001:PC-8) observes the committed epoch plus all
                    writes successfully committed by producers earlier in
                    the current execution cycle. This is the Within-Cycle
                    Visibility guarantee: each producer sees a consistent
                    view that includes prior producers' committed output
                    but excludes its own uncommitted writes.

                In both contexts, no partially-committed write transaction
                is visible, and the epoch counter does not advance until
                the scheduling subsystem explicitly requests advancement
                (PC-4).
  Preconditions: None. The unit store is always queryable.
  Failure mode: None. Read access does not fail. If the unit store is
                empty (no units admitted), queries return empty results.

PC-4: Epoch Advancement
  Direction:    Offered
  Counterparty: Scheduling subsystem (synchronous pipeline coordinator)
  Guarantee:    The epoch counter advances from N to N+1 atomically. After
                advancement, all writes committed during the synchronous
                pipeline for epoch N+1 become visible to consumer queries
                (via PC-3). The prior epoch N is no longer the committed
                epoch.
  Preconditions: The synchronous pipeline has completed — all T0 and T1
                 producer executions for the current change set have
                 finished, all output batches have been admitted (PC-1),
                 and all invalidations have been recorded (PC-2).
  Failure mode: None. Epoch advancement is a counter increment in memory.
                If the preconditions are not met (synchronous pipeline
                incomplete), the caller has violated the contract — the
                DIR Runtime does not independently verify pipeline
                completion.

PC-5: Unit Identity Resolution
  Direction:    Offered
  Counterparty: Any subsystem that holds unit references (Producer
                Runtime, scheduling subsystem, Index Manager)
  Guarantee:    Given a unit identifier, the DIR Runtime returns the
                complete unit record (all 10 fields plus lifecycle status)
                if the unit exists in the unit store, regardless of its
                lifecycle status. This enables grounding chain traversal,
                provenance inspection, and supersession history lookup.
  Preconditions: The unit identifier was issued by the DIR Runtime (R5).
  Failure mode: If the identifier does not match any unit in the store
                (the unit has been garbage collected or the identifier
                was never issued), the resolution returns absent. This is
                not an error — it indicates the unit has been reclaimed.

PC-6: Write Transaction
  Direction:    Offered
  Counterparty: Producer Runtime (DDS-001:PC-7), scheduling subsystem
                (for batch invalidation)
  Guarantee:    A set of unit operations (admissions via PC-1, status
                transitions via PC-2) is applied atomically. Either all
                operations succeed or none are applied. Within a write
                transaction, operations are ordered: admissions are
                processed before status transitions, and supersession
                is resolved as part of admission. Units admitted earlier
                in the transaction are visible to validation of units
                admitted later in the same transaction (enabling a
                producer's output batch to reference units it created
                in the same batch).
  Preconditions: All units in the admission set pass intake validation.
                 All status transitions are valid.
  Failure mode: If any operation fails (intake validation failure,
                invalid status transition), the entire transaction is
                rejected. A diagnostic identifies all failures.
```

### Required Contracts

```
PC-7: Garbage Collection Directives
  Direction:    Required
  Counterparty: Storage Engine (DDS for Storage Engine)
  Guarantee:    The Storage Engine issues garbage collection directives
                specifying which units to transition to Garbage Collected
                status, based on the tier-informed retention policy
                (DAS-010 GC-1 through GC-4, DAS-012 GC-R1 through GC-R4).
  Preconditions: The identified units have Superseded or Invalidated
                 status. No active grounding chain references them
                 (DAS-012 I7 — GC safety).
  Failure mode: If no garbage collection directives are received, the
                unit store retains all units indefinitely. This is not
                a failure — it indicates no units are eligible or the
                Storage Engine has not yet run a GC pass.

PC-8: Snapshot Capture
  Direction:    Required
  Counterparty: Storage Engine (DDS for Storage Engine)
  Guarantee:    The Storage Engine reads the unit store contents and the
                epoch counter to produce a persistent snapshot. The DIR
                Runtime provides a consistent view of the unit store at
                the committed epoch for this purpose (using PC-3
                semantics).
  Preconditions: The epoch has been advanced (PC-4). The synchronous
                 pipeline is not in progress (the committed epoch is
                 stable).
  Failure mode: If the Storage Engine cannot read the unit store (process
                termination during snapshot), the prior snapshot remains
                valid. The DIR Runtime does not participate in snapshot
                failure recovery — that is the Storage Engine's
                responsibility.
```

---

## Lifecycle

### Creation

The DIR Runtime is created during application startup. Creation allocates an empty unit store and initializes the epoch counter. If a snapshot exists, the Storage Engine loads it and populates the unit store via write transactions (PC-6) before the DIR Runtime enters operation. If no snapshot exists, the unit store starts empty at epoch 0.

**Preconditions for creation:** None. The DIR Runtime has no dependencies that must be satisfied before it can be constructed.

**Startup sequence:** The DIR Runtime is created before the Producer Runtime (DDS-001), because the Producer Runtime requires DIR read/write access (DDS-001:PC-7, DDS-001:PC-8) to execute producers.

### Operation

The DIR Runtime is operational from the moment it is created. It accepts write transactions (PC-6), status transitions (PC-2), and read queries (PC-3) at all times. The unit store may be empty during initial operation — this is valid and does not prevent the DIR Runtime from accepting writes.

**Operational invariant:** The unit store is consistent at all times. Every unit in the store satisfies the DAS-002 atomic unit contract. Every Active unit's supersession key is unique — no two Active units share the same (subject, predicate, tier). The epoch counter is monotonically increasing.

### Quiescence

When the application is shutting down, the DIR Runtime enters quiescence:

1. No new write transactions are accepted.
2. In-progress write transactions are completed or rolled back.
3. The unit store remains available for read queries (PC-3) and for snapshot capture (PC-8) until final destruction.
4. The epoch counter is not advanced during quiescence.

### Destruction

The DIR Runtime is destroyed during application teardown, after the Storage Engine has captured the final snapshot. The unit store and epoch counter are deallocated.

**Destruction ordering:** The DIR Runtime is destroyed after the Producer Runtime (DDS-001) and after the Storage Engine has completed its final snapshot. The Producer Runtime depends on the DIR Runtime for writes; the Storage Engine depends on it for snapshot reads.

---

## State Model

The DIR Runtime occupies one of four states:

```
Loading → Operational → Quiescing → Terminated
```

**Loading.** The DIR Runtime has been created. The unit store is being populated from a snapshot (if one exists). Write transactions from the Storage Engine (snapshot loading) are accepted. Producer write transactions and consumer read queries are deferred until loading completes. The epoch counter is set to the snapshot's epoch (or 0 if no snapshot).

**Operational.** The unit store is populated and consistent. All contracts (PC-1 through PC-8) are active. Write transactions, read queries, epoch advancement, and status transitions are all accepted. This is the steady-state during application operation.

**Quiescing.** The application is shutting down. No new write transactions are accepted. Read queries and snapshot capture remain available. Transition to Terminated occurs when the Storage Engine signals that the final snapshot is complete.

**Terminated.** The DIR Runtime has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Loading | Operational | Snapshot load complete (or no snapshot) | Unit store consistent, epoch set |
| Operational | Quiescing | Shutdown signal | No new writes accepted |
| Quiescing | Terminated | Final snapshot complete | Resources deallocated |

**Invalid transitions:** Loading → Quiescing (must complete loading before shutdown). Terminated → any state. Quiescing → Operational (shutdown is irreversible).

---

## Identity Model

### Identifier Assignment

Every unit admitted to the DIR receives a globally unique identifier from a monotonically increasing 64-bit counter (DAS-012). The counter is initialized from the snapshot (preserving uniqueness across restarts) or from 0 on first launch.

**IM-1: Uniqueness.** No two units ever share an identifier, even across process restarts (DAS-002 I-ID-1). The counter is persisted in the snapshot and restored on load.

**IM-2: Immutability.** An identifier, once assigned, is never reassigned to a different unit (DAS-002 I-ID-2). Even after garbage collection removes a unit, its identifier is never reused.

**IM-3: Opacity.** Identifiers carry no semantic content (DAS-002 I-ID-3). They encode no ordering, hierarchy, tier, or provenance. External subsystems must not parse or interpret identifier values.

**IM-4: Assignment timing.** Identifiers are assigned at the moment of admission (PC-1), not before. Units submitted for admission do not carry pre-assigned identifiers — the DIR Runtime is the sole identity authority.

### Supersession Key

The supersession key is the composite **(subject, predicate, tier)** (DAS-012, DAS-003 TL-2). This key determines which units compete:

- Two Active units with the same supersession key cannot coexist. When a new unit is admitted with a key matching an existing Active unit, the existing unit is atomically transitioned to Superseded, with a reference to its successor.
- Two Active units with the same (subject, predicate) but **different tiers** coexist. A T0 fact and a T2 interpretation about the same entity's same predicate are complementary, not competing (DAS-003 TL-2).

---

## Immutability Model

### Field Immutability

Once a unit is admitted to the unit store, the following fields are immutable for the lifetime of the unit (DAS-002 I-LC-5):

| Field | Immutable | Rationale |
|-------|-----------|-----------|
| id | Yes | DAS-002 I-ID-2 |
| subject | Yes | DAS-002 I-LC-5 |
| predicate | Yes | DAS-002 I-LC-5 |
| value | Yes | DAS-002 I-VAL-1 |
| tier | Yes | DAS-002 I-TIER-3, DAS-003 I6 |
| provenance | Yes | DAS-002 I-PROV-1 |
| confidence | Yes | DAS-002 I-CONF-3 |
| grounding | Yes | DAS-002 I-LC-5 |
| version | Yes | DAS-002 I-LC-5 |
| status | **Mutable** | Lifecycle transitions only |

### Status Transitions

The status field is the only mutable field. Permitted transitions:

```
Active → Invalidated     (source change, grounding collapse, producer upgrade)
Active → Superseded      (new unit with same supersession key admitted)
Invalidated → Superseded (replacement unit admitted for invalidated unit)
Superseded → [Garbage Collected]
Invalidated → [Garbage Collected]
```

**Irreversibility.** Status transitions are irreversible (DAS-002 I-LC-4). An Invalidated unit cannot return to Active. If the source reverts to a prior state, a new unit is created rather than reactivating the old one. This eliminates the complexity of undo semantics in the lifecycle model.

### Enforcement Mechanism

The DIR Runtime enforces immutability by never exposing mutable references to unit fields. External subsystems receive read-only views of units (via PC-3, PC-5). Write operations are mediated exclusively through PC-1 (admission of new units) and PC-2 (status transitions). There is no "update unit" operation — to change a value, the old unit is superseded by a new unit.

---

## Read/Write Semantics

### Write Path

All writes to the DIR pass through the write transaction contract (PC-6). A write transaction contains:

1. **Unit admissions** — new units to be added to the unit store (validated via PC-1).
2. **Status transitions** — existing units to be transitioned (validated via PC-2).

Write transactions are atomic: all operations succeed or none are applied. Within a transaction:

- Admissions are processed in submission order.
- Each admitted unit receives an identifier (R5) and is added to the unit store.
- If the admitted unit's supersession key matches an existing Active unit, the existing unit is transitioned to Superseded.
- Units admitted earlier in the transaction are visible to intake validation of later units (enabling grounding chain references within a batch).
- Status transitions are applied after all admissions.

**Write ordering.** Writes are serialized. No two write transactions execute concurrently. This is a consequence of the single-writer architecture (DAS-012 DA-1, DAS-010 I8). The synchronous pipeline coordinator submits write transactions sequentially.

### Read Path

All reads from the DIR pass through the epoch-consistent read contract (PC-3). Reads observe the committed epoch — the most recent epoch for which the synchronous pipeline has completed and the epoch counter has advanced.

**Read during writes.** If a read query arrives while a write transaction is in progress (during synchronous pipeline execution), the query observes the prior committed epoch. The in-progress writes are invisible to the reader (DAS-010 WR-5). This ensures that consumers never see a partially-updated DIR.

**Read access patterns.** The DIR Runtime supports the following read operations:

- **By identifier** (PC-5): O(1) lookup. Returns the complete unit record.
- **By status partition**: Active units, Invalidated units, or all units. Active-only is the default (DAS-002 retrieval defaults).
- **By supersession key** (subject, predicate, tier): Returns the Active unit for a given key, if one exists.
- **Bulk read**: All units, optionally filtered by status. Used by the Storage Engine for snapshot capture and by the Index Manager for index construction.

Query optimization (by predicate, by entity, by tier range, by confidence) is the Index Manager's responsibility. The DIR Runtime provides the primitive read operations; indexes accelerate them.

### Within-Cycle Visibility

During an execution cycle (DDS-001:PC-2), producers execute in DAG order. A pass that executes after a prior pass must see the prior pass's output. This is satisfied by the write transaction model: each producer's output batch is committed as a write transaction (PC-6) before the next producer begins. The committed units are immediately visible to subsequent reads within the same synchronous pipeline, even though the epoch has not yet advanced.

**Clarification:** Within-cycle visibility applies to producers operating within the synchronous pipeline, not to consumer queries. Consumer queries always see the committed epoch (the prior epoch during pipeline execution). Producer reads during execution see all units committed by prior producers in the current cycle.

---

## Consistency Model

### Epoch-Based Consistency

The DIR Runtime implements DAS-010's epoch-based consistency model:

**EC-1: Epoch monotonicity.** The epoch counter only increases. It advances from N to N+1 when PC-4 is invoked. It never decreases, skips, or resets (except on first launch where it starts at 0 or is restored from snapshot).

**EC-2: Epoch atomicity.** The epoch advance is a single counter increment. All writes committed during the synchronous pipeline become visible at the moment of advancement. There is no intermediate state between epoch N and epoch N+1.

**EC-3: Consumer isolation.** Consumer queries are isolated from in-progress synchronous pipeline execution. A query that arrives during pipeline execution observes epoch N (the prior committed state). A query that arrives after epoch advancement observes epoch N+1 (the new committed state). No query observes a mix.

**EC-4: Within-pipeline visibility.** Writes committed during the synchronous pipeline for epoch N+1 are visible to subsequent writes within the same pipeline (enabling DAG-ordered producer execution per DDS-001:PC-2). This visibility is scoped to the pipeline — it does not extend to consumer queries until epoch advancement.

### Invalidated Content Visibility

Invalidated units remain in the unit store and are queryable (DAS-010 WR-6). They carry invalidation metadata:

- **Invalidation epoch:** The epoch at which the unit was invalidated.
- **Invalidation reason:** An identifier for the upstream change that triggered invalidation (e.g., the changed entity, the upgraded producer).

Consumers can distinguish Active from Invalidated units. Invalidated T2 units are preferable to absent T2 units (DAS-001 P12 — graceful degradation). The DIR Runtime does not filter Invalidated units from query results unless the consumer explicitly requests Active-only results.

---

## Versioning Model

### Content-Addressed Versioning

Every unit records the version of the source material it was derived from (DAS-002 I-VER-1). The version stamp is content-addressed (DAS-002 I-VER-3): two source states with identical content produce the same version. This prevents unnecessary invalidation when a file is saved without changes.

**VM-1: Per-artifact granularity.** The version stamp is granular to the source artifact (DAS-002 I-VER-4). A unit about a function in file X carries the version (content hash) of file X, not the version of the repository.

**VM-2: Version immutability.** The version stamp is immutable once the unit is created (DAS-002 I-LC-5). If the source changes, the old unit is invalidated and a new unit is created with the new version stamp.

**VM-3: Staleness detection.** The scheduling subsystem can compare a unit's version stamp against the current content hash of its source artifact to determine whether the unit is fresh (hashes match) or stale (hashes differ). The DIR Runtime stores the version stamp but does not perform staleness detection — that is the scheduling subsystem's responsibility.

---

## Provenance Model

### Provenance at Admission

Every unit admitted to the DIR must carry a complete provenance record (DAS-002 I-PROV-1). The provenance record includes:

- **Producer identity:** The identifier of the producer (frontend or pass) that created the unit, including its version.
- **Method:** The production method category (extraction, inference, derivation, annotation).
- **Timestamp:** When the unit was produced.
- **Inputs:** References to the units or source material consumed to produce this unit.

### Provenance Validation at Intake

The DIR Runtime validates provenance at intake (R2):

- **PV-1: Completeness.** Producer identity and method are required. Timestamp is required. Inputs may be empty only for units extracted directly from source material (frontends).
- **PV-2: Machine-interpretability.** Producer identity and method must be machine-interpretable (DAS-002 I-PROV-2). The DIR Runtime can programmatically identify all units produced by a specific producer version.
- **PV-3: Input reference validity.** For derived units (method = derivation or inference), the provenance inputs must reference units that exist in the unit store or that appear earlier in the same write transaction. Dangling provenance references are rejected.

### Provenance and Batch Invalidation

Machine-interpretable provenance (DAS-002 I-PROV-2) enables batch operations: "invalidate all units produced by producer X at version V." The DIR Runtime supports this as a bulk status transition via PC-2. This is the mechanism by which producer upgrades trigger re-evaluation (DAS-010 PU-1, PU-2).

---

## Tier Enforcement

### Intake-Time Tier Validation

The DIR Runtime validates tier constraints at intake (R2, R8):

**TE-1: Tier totality.** Every unit must declare exactly one tier from {T0, T1, T2} (DAS-003 I1).

**TE-2: Tier-confidence bounds.** T0 units must have confidence = `deterministic`. T1 and T2 units must not have confidence = `deterministic` (DAS-003 I2).

**TE-3: MDT compliance.** A unit's tier must not exceed its predicate's maximum deterministic tier unless the predicate permits semantic tiers (DAS-003 I4). A `hasReturnType` unit (MDT = T0) at T1 or T2 is rejected.

**TE-4: Derivation monotonicity.** For derived units, no provenance input may have a higher tier than the unit being admitted (DAS-002 I-TIER-5, DAS-003 I3). A T0 unit whose provenance inputs include a T1 or T2 unit is rejected. This check applies to inputs resolvable within the unit store or within the same write transaction.

**TE-5: Tier immutability.** The tier field is immutable after admission (DAS-002 I-TIER-3, DAS-003 I6). There is no operation to change a unit's tier.

---

## Memory and Ownership

### Owned Resources

**Unit store.** The DIR Runtime exclusively owns the in-memory collection of all atomic units. No other subsystem directly reads or writes the unit store. All access is mediated through the public contracts (PC-1 through PC-6).

**Epoch counter.** The DIR Runtime exclusively owns the 64-bit epoch counter. No other subsystem directly reads or modifies it. Epoch queries are served via PC-3 (the committed epoch is part of the read contract). Epoch advancement is via PC-4.

**Unit identity counter.** The DIR Runtime exclusively owns the monotonically increasing unit identifier counter. No other subsystem assigns unit identifiers.

### Borrowed Resources

**Predicate registry (read).** The DIR Runtime reads the predicate registry (a code-defined structure per DAS-012) to validate predicate membership, MDT compliance, and value type conformance at intake. The registry is not owned by the DIR Runtime — it is a shared, immutable, application-level structure.

### Shared Resources

None. The DIR Runtime does not share mutable state with any other subsystem. All interactions are through contracts.

### Memory Bounds

**Unit store size.** Proportional to the number of atomic units in the DIR. At expected scale: ~300,000 units at alpha (~60 MB), up to ~6,000,000 units at practical limit (~1.2 GB). Per DAS-012 DA-2.

**Epoch counter and identity counter.** 16 bytes total. Negligible.

**Overhead per unit.** Each unit carries the 10 DAS-002 fields plus lifecycle status and supersession metadata (successor reference, invalidation metadata). Estimated ~100-300 bytes per unit (DAS-012 DA-2).

### Eviction

The DIR Runtime does not independently evict units. Eviction is driven by garbage collection directives from the Storage Engine (PC-7). The DIR Runtime removes units from the unit store when instructed, subject to the GC safety invariant: no unit referenced by an Active or Invalidated unit's provenance chain is removed.

---

## Failure Handling

```
FM-1: Intake Validation Failure
  Trigger:     A write transaction contains a unit that fails intake
               validation (R2). Possible causes: missing required field,
               tier outside {T0, T1, T2}, tier exceeds predicate MDT,
               confidence violates tier bounds, provenance incomplete,
               dangling provenance input reference, grounding chain
               empty or cyclic within the batch.
  Detection:   Intake validation during write transaction processing.
  Response:    The entire write transaction is rejected (PC-6 atomicity).
               No units are admitted. No status transitions are applied.
               A diagnostic is returned identifying each failing unit
               and the specific validation violations.
  Caller observes: The Producer Runtime (DDS-001) receives a transaction
               rejection. Per DDS-001:PC-7, the Producer Runtime treats
               this as a DIR write failure (DDS-001:FM-6).
  Recovery:    The caller must correct the invalid units and resubmit.
               The DIR Runtime's state is unchanged — no partial writes
               occurred.

FM-2: Invalid Status Transition
  Trigger:     A status transition request specifies an invalid
               transition (e.g., Superseded → Active, Active → Garbage
               Collected directly).
  Detection:   Lifecycle state machine validation during write
               transaction processing.
  Response:    The entire write transaction is rejected (PC-6 atomicity).
               A diagnostic identifies the unit and the invalid
               transition.
  Caller observes: Transaction rejection with invalid transition detail.
  Recovery:    The caller must correct the transition request. The DIR
               Runtime's state is unchanged.

FM-3: Unit Not Found
  Trigger:     A status transition or identity resolution references a
               unit identifier that does not exist in the unit store.
  Detection:   Identifier lookup during transaction processing or
               PC-5 resolution.
  Response:    For status transitions within a write transaction: the
               transaction is rejected (PC-6 atomicity). For PC-5
               identity resolution: absent is returned. This is not
               an error for PC-5 — the unit may have been garbage
               collected.
  Caller observes: For transactions: rejection with "unit not found"
               detail. For PC-5: absent result.
  Recovery:    For transactions: the caller must correct the reference.
               For PC-5: the caller handles the absent unit (e.g., by
               treating a broken grounding chain as a stale reference).

FM-4: Supersession Conflict
  Trigger:     A write transaction admits two units with the same
               supersession key (subject, predicate, tier) within the
               same transaction.
  Detection:   Supersession key conflict detection during transaction
               processing.
  Response:    The entire write transaction is rejected. A diagnostic
               identifies the conflicting units and their shared
               supersession key.
  Caller observes: Transaction rejection with conflict detail.
  Recovery:    The caller must ensure that each supersession key
               appears at most once per write transaction. If a
               producer produces multiple versions of the same claim,
               only the final version should be submitted.

FM-5: Memory Exhaustion
  Trigger:     The unit store exceeds available memory during unit
               admission.
  Detection:   Memory allocation failure during write transaction
               processing.
  Response:    The write transaction is rejected. No units are admitted.
               The DIR Runtime remains operational with its existing
               unit store contents.
  Caller observes: Transaction rejection with "memory exhaustion"
               category.
  Recovery:    The Storage Engine should be instructed to run aggressive
               garbage collection (PC-7) to reclaim memory from
               Superseded and eligible Invalidated units. If memory
               remains insufficient after GC, the system has exceeded
               the scale envelope (DAS-012) and requires architectural
               evolution.
```

---

## Performance Requirements

Performance requirements are classified as follows:

- **Architectural requirement** — a bound mandated by DAS invariants or freshness contracts. Violation breaks an architectural guarantee.
- **Engineering target** — an initial numeric bound based on expected workload and reasoning, not yet validated by measurement. Must be validated through benchmarking before promotion to firm requirements.
- **Benchmark-derived** — a bound established through measured performance.

```
PR-1: Unit Admission Latency
  Operation:   Admission of a single unit (intake validation + store
               insertion + supersession check)
  Category:    Engineering target
  Bound:       Upper bound 10μs per unit (initial target)
  Assumptions: Unit store size ≤ 6,000,000 units. O(1) identifier
               assignment (counter increment). O(1) supersession key
               lookup (hash-based).
  Rationale:   Unit admission is on the synchronous pipeline critical
               path. A producer that emits 300 units per file must
               complete admission in <3ms to stay within the pipeline
               budget. Validate by benchmarking admission at the upper
               bound of expected unit store size.

PR-2: Write Transaction Latency
  Operation:   Complete write transaction (all admissions + all status
               transitions + supersession resolution)
  Category:    Architectural requirement (synchronous pipeline bound);
               engineering target (numeric bound)
  Bound:       Upper bound 5ms per transaction (initial target)
  Assumptions: Transaction size ≤ 500 units (a single producer's
               output batch per DDS-001 Memory Bounds).
  Rationale:   Write transactions are on the synchronous pipeline
               critical path (DAS-010 RS-1 through RS-4). Multiple
               transactions occur per execution cycle (one per producer).
               At 5ms per transaction and ~10 producers per cycle,
               total write time is ~50ms. Validate by benchmarking
               batch transactions at the upper bound of expected size.

PR-3: Epoch-Consistent Read Latency
  Operation:   Single unit lookup by identifier (PC-5)
  Category:    Engineering target
  Bound:       Upper bound 100ns per lookup (initial target)
  Assumptions: O(1) hash-based lookup. Unit store in memory.
  Rationale:   Identity resolution is on the critical path for
               grounding chain traversal (DAS-010 IP-4). A cascade
               traversal may resolve ~50 units. At 100ns per lookup,
               traversal takes ~5μs. Validate by benchmarking at the
               upper bound of unit store size.

PR-4: Epoch Advancement Latency
  Operation:   Epoch counter increment + committed epoch update
  Category:    Architectural requirement
  Bound:       Upper bound 1μs
  Assumptions: Single integer increment. No I/O.
  Rationale:   Epoch advancement is the commit point for the
               synchronous pipeline (DAS-010 WR-3). It must be
               effectively instantaneous. No validation needed —
               this is an integer increment.

PR-5: Bulk Status Transition
  Operation:   Batch invalidation of N units (e.g., producer upgrade)
  Category:    Engineering target
  Bound:       Upper bound 1ms per 1,000 units (initial target)
  Assumptions: Status transition is O(1) per unit (status field update
               + invalidation metadata write).
  Rationale:   Producer upgrade invalidation (DAS-010 PU-2) may
               invalidate all units produced by a specific producer.
               At alpha scale (~300,000 units, ~10% per producer),
               a producer upgrade invalidates ~30,000 units, taking
               ~30ms. Validate by benchmarking at the upper bound of
               producer scope.
```

---

## Observability

The DIR Runtime emits the following observable information:

**Unit Store Metrics.** Total unit count (by status: Active, Invalidated, Superseded). Total unit count by tier (T0, T1, T2). Memory footprint estimate. These metrics are queryable on demand (not emitted as events — they are point-in-time statistics).

**Write Transaction Events.** For each committed write transaction: number of units admitted, number of supersessions triggered, number of status transitions applied, transaction duration, and the epoch at which the transaction was committed. Emitted after each successful transaction.

**Rejected Transaction Events.** For each rejected write transaction: the number of validation failures, the failure categories (missing field, tier violation, confidence violation, provenance violation, supersession conflict), and the identity of the submitting producer. Emitted immediately on rejection.

**Epoch Events.** For each epoch advancement: the new epoch number, the number of units admitted since the prior epoch, and the number of units invalidated since the prior epoch. Emitted after each advancement.

**Identity Counter.** The current value of the unit identity counter. Queryable on demand. Useful for estimating total units ever created (including garbage-collected units).

**Overhead.** Observability data collection does not block write transactions or read queries. Metrics are collected as side effects of normal operations (transaction processing, epoch advancement), not as separate passes over the unit store.

---

## Testing Requirements

**Intake validation tests (R2):**
- A unit with all 10 fields correctly populated is admitted.
- A unit missing any required field is rejected with a diagnostic identifying the missing field.
- A unit with tier outside {T0, T1, T2} is rejected.
- A T0 unit with confidence ≠ `deterministic` is rejected.
- A T1 unit with confidence = `deterministic` is rejected.
- A unit whose tier exceeds its predicate's MDT is rejected.
- A derived unit whose provenance inputs include a higher-tier unit is rejected.
- A unit with empty grounding chain is rejected.
- A unit with a cyclic grounding chain within the batch is rejected.
- A unit with a dangling provenance input reference is rejected.

**Immutability tests (R3):**
- After admission, all fields except status are unchanged on subsequent reads.
- No operation modifies the id, subject, predicate, value, tier, provenance, confidence, grounding, or version of an admitted unit.

**Lifecycle tests (R4):**
- Active → Invalidated transition succeeds.
- Active → Superseded transition is triggered by admitting a unit with the same supersession key.
- Invalidated → Superseded transition succeeds when a replacement is admitted.
- Superseded → Active transition is rejected.
- Invalidated → Active transition is rejected.
- Active → Garbage Collected transition (skipping Invalidated/Superseded) is rejected.
- Superseded unit retains a reference to its successor.

**Supersession tests:**
- Admitting a unit with supersession key (S, P, T0) supersedes the existing Active unit at (S, P, T0).
- Admitting a unit at (S, P, T2) does NOT supersede an Active unit at (S, P, T0) — they coexist.
- After supersession, the superseded unit has Superseded status and the new unit has Active status.
- Admitting two units with the same supersession key in the same transaction is rejected (FM-4).

**Identity tests (R5):**
- Every admitted unit receives a unique identifier.
- Identifiers are monotonically increasing.
- After garbage collection, the identifier of a collected unit is never reused.
- Identifiers carry no semantic content (not derived from unit fields).

**Epoch consistency tests (R6, R7):**
- A read query during synchronous pipeline execution returns the prior epoch's state.
- After epoch advancement, a read query returns the new epoch's state.
- Units admitted during the synchronous pipeline are invisible to consumer queries until epoch advancement.
- Units admitted during the pipeline are visible to subsequent producer reads within the same pipeline.
- The epoch counter only increases.

**Write transaction atomicity tests (PC-6):**
- A transaction with one invalid unit and nine valid units: no units are admitted.
- A transaction with all valid units: all are admitted.
- Within a transaction, a unit admitted first is visible to validation of a unit admitted later (provenance input reference).

**Failure mode tests (FM-1 through FM-5):**
- Each failure mode returns the correct diagnostic.
- All transaction failures leave the unit store unchanged.
- Memory exhaustion rejection preserves existing unit store contents.

**Integration tests:**
- A Producer Runtime output batch (DDS-001:PC-7) is admitted as a write transaction: units receive identifiers, supersession is resolved, and the batch is visible to subsequent producer reads.
- A scheduling subsystem batch invalidation transitions multiple units from Active to Invalidated with correct metadata.
- Epoch advancement after a synchronous pipeline makes all pipeline writes visible to consumer queries.

---

## Future Evolution

**Index Manager Integration.** The DIR Runtime currently provides primitive read operations (by identifier, by status, by supersession key, bulk). When the Index Manager DDS is authored, it will define derived query-optimized structures built from DIR content. The DIR Runtime may need to emit write notifications (unit admitted, unit status changed) to enable incremental index maintenance. The contract surface for these notifications will be defined in the Index Manager DDS — the DIR Runtime's core contracts (PC-1 through PC-6) are designed to be sufficient without notification-based index maintenance (indexes can be built from bulk reads), but notifications would enable lower-latency index updates.

**Multi-Version Read.** The current design supports single-epoch reads (the committed epoch). If future capabilities require reading the DIR at a prior epoch (e.g., "what did the DIR say about this function before the last change?"), the DIR Runtime would need to support epoch-parameterized queries. This is not currently required by any DAS obligation and is deferred.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial draft
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions: PC-3 read context distinction, state count correction
0.3 — 2026-06-28 — Principal Engineer — Platform consistency cleanup:
      removed incorrect DDS-001 from Depends On (DDS-002 has no Required
      contracts from DDS-001; DDS-001 depends on DDS-002, not the reverse).
      Replaced Depended By with derived marker per platform convention.
```
