# DDS-001: Producer Runtime

```
Document:      DDS-001
Title:         Producer Runtime
Status:        Draft
Version:       0.3
Author:        Principal Engineer
Reviewers:     —
Created:       2026-06-29
Last Revised:  2026-06-28
Depends On:    DDS-000 (Design Authoring Standard), DDS-002 (DIR Runtime Model)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-006, DAS-010
```

## Abstract

This document specifies the engineering design of the Producer Runtime — the subsystem that manages the lifecycle, registration, execution, isolation, and observability of all DIR producers (frontends and passes). It realizes the frontend contract and pass contract defined in DAS-002, the pass architecture defined in DAS-006, relevant tier constraints from DAS-003, and the recomputation scheduling interface from DAS-010. The Producer Runtime owns the pass DAG, orchestrates producer execution in both batch and incremental modes, enforces failure isolation between producers, validates producer output against declared contracts, and provides the observability surface for production diagnostics.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P2 (layered intelligence — tier-ordered execution), P3 (deterministic before
            semantic — deterministic passes execute before semantic), P4 (composition produces
            emergence — composition pass execution), P8 (AI as consumer — semantic passes
            consume DIR, not source), P9 (incremental — scoped re-execution), P11 (boundaries
            — producer independence), P12 (graceful degradation — failure isolation),
            I2 (downward layer dependency — tier ordering enforcement),
            I3 (deterministic completeness — frontend determinism),
            I6 (incremental expressibility — per-scope re-execution),
            I7 (AI independence of deterministic layers — deterministic pass isolation)
  Not addressed: P1 (addressed by DDS for DIR Store), P5 (grounding verification — addressed
                 partially here via output validation, fully by DDS for DIR Store),
                 P6, P7, P10 (addressed by DDS for Retrieval/Context Assembly)

DAS-002: Decode Intermediate Representation
  Realized: Frontend contract (Producers section), Pass contract (Producers section),
            I6 (frontend determinism — enforced at registration and output validation),
            I7 (pass grounding — enforced at output validation),
            I-PROV-1, I-PROV-2 (provenance immutability and machine-interpretability —
            producer identity in output), I-TIER-3 (tier immutability — validated at output),
            I-TIER-5 (derivation monotonicity — enforced at DAG construction),
            C2 (adding a language = adding a frontend), C6 (independently deployable)
  Not addressed: I1 (DIR completeness — DDS for DIR Store), I2 (atomic unit immutability —
                 DDS for DIR Store), I3 (grounding termination — DDS for DIR Store),
                 I4 (tier monotonicity — partially enforced here, fully by DIR Store),
                 I5 (predicate registry — DDS for DIR Store), I8 (index derivability —
                 DDS for Index Manager), DC-1 through DC-5 (design constraints — DDS for
                 DIR Store)

DAS-003: Tier Model
  Realized: TA-1 through TA-5 (tier assignment rules — validated at output),
            CTD-1, CTD-2, CTD-3 (cross-tier dependencies — enforced at DAG construction),
            I3 (derivation monotonicity — pass input/output tier validation),
            I4 (MDT compliance — validated at output)
  Not addressed: I1 (tier totality — DDS for DIR Store), I2 (T0 deterministic confidence —
                 DDS for DIR Store), I5 (freshness ordering — DDS for Update Engine),
                 I6 (tier immutability — DDS for DIR Store), I7 (degradation validity —
                 DDS for Retrieval), Freshness contracts (DDS for Update Engine)

DAS-006: Pass Architecture
  Realized: Pass Contract (all fields), Pass Dependencies (PD-1 through PD-6),
            Pass Execution (PE-1 through PE-6), Pass Isolation (PI-1 through PI-5),
            Deterministic Passes (DP-1, DP-2), Semantic Passes (SP-1 through SP-5),
            Composition Passes (CP-1 through CP-4), Cross-Pass Contracts (CPC-1 through
            CPC-5), Pass Observability (PO-1 through PO-4),
            I1 (DAG acyclicity), I2 (input completeness), I3 (output completeness),
            I4 (tier consistency), I5 (grounded output), I6 (failure isolation),
            I7 (provenance attribution), I8 (deterministic pass AI independence),
            C1, C2, C3, C4, C5, C7
  Not addressed: Pass Invalidation (PINV-1 through PINV-5 — DDS for Update Engine),
                 Pass Scheduling priorities (PS-1 through PS-4 — DDS for Update Engine),
                 C6 (composition answers DAS-002 Q5 — architectural, not engineering)

DAS-010: Incremental Update Model
  Realized: RS-1 through RS-4 (synchronous pipeline — execution interface),
            RS-5, RS-6, RS-7 (deferred pipeline — execution interface),
            PU-1 through PU-5 (producer upgrade invalidation — upgrade lifecycle)
  Not addressed: Change Detection (CD-1 through CD-6 — DDS for Update Engine),
                 Invalidation Propagation (IP-1 through IP-6 — DDS for Update Engine),
                 Cascade Boundaries (CB-1 through CB-4 — DDS for Update Engine),
                 Write-Read Consistency (WR-1 through WR-7 — DDS for Update Engine),
                 Index Maintenance (IM-1 through IM-6 — DDS for Index Manager),
                 Garbage Collection (GC-1 through GC-4 — DDS for DIR Store)
```

## Terminology

**Producer** — Any component that creates atomic units in the DIR. Producers are either frontends (which read source material) or passes (which read existing DIR content). The Producer Runtime manages both. `See DAS-002`

**Frontend** — A producer that reads source material in a specific language or format and emits atomic units at deterministic tiers (T0). Frontends are the entry point to the DIR. `See DAS-002`

**Pass** — A producer that reads existing DIR content and produces new atomic units at the same or higher tier. `See DAS-006`

**Producer Contract** — The declared specification of a producer's identity, inputs, outputs, tier range, and execution characteristics. For frontends, the contract specifies the source formats handled and the predicates produced. For passes, the contract is the full pass contract defined in DAS-006: input contract, output contract, scope, tier range, determinism, and idempotency. `INTRODUCED`

**Pass DAG** — The directed acyclic graph of pass dependencies, constructed from pass contract declarations. `See DAS-006`

**Producer Registry** — The subsystem-internal catalog of all registered producers and their contracts. The registry is the authoritative source for DAG construction, contract validation, and provenance resolution. `INTRODUCED`

**Execution Ticket** — A unit of work issued to the Producer Runtime via the Execution Directives contract (PC-9), specifying which producer to execute over which scope. An execution ticket carries the producer identity, the scope (entity set or file set), and whether the execution is batch or incremental. `INTRODUCED`

**Output Batch** — The set of atomic units produced by a single producer execution. An output batch is validated against the producer's declared output contract before being committed to the DIR. `INTRODUCED`

---

## Responsibilities

```
R1: Maintain the Producer Registry — accept, validate, and catalog producer
    contract declarations.
    DAS: DAS-006 PD-1 (dependencies are declared), DAS-002 C2 (adding a language
         = adding a frontend), DAS-006 C2 (adding a pass = declaring its contract)
    Boundary: The registry stores contracts; it does not store producer
              implementations or source code.

R2: Construct and maintain the Pass DAG from registered pass contracts.
    DAS: DAS-006 PD-1 through PD-6 (dependency declaration and DAG construction),
         DAS-006 I1 (DAG acyclicity)
    Boundary: The DAG represents declared dependencies. Invalidation surface
              computation is outside scope (see DAS-010 IP-1 through IP-6).

R3: Execute producers when directed via execution tickets (PC-9), in the order
    determined by the Pass DAG and tier constraints.
    DAS: DAS-006 PE-1 (tier-level ordering), PE-2 (concurrent execution permitted),
         DAS-010 RS-1 through RS-4 (synchronous pipeline execution),
         DAS-010 RS-5, RS-6, RS-7 (deferred pipeline execution)
    Boundary: The Producer Runtime executes producers. The scheduling subsystem
              decides which producers to execute and when. The Producer Runtime
              does not perform change detection or invalidation propagation.

R4: Validate producer output against declared contracts and DAS invariants
    before committing to the DIR.
    DAS: DAS-006 I2 (input completeness), I3 (output completeness),
         I4 (tier consistency), I5 (grounded output), I7 (provenance attribution),
         DAS-002 I6 (frontend determinism), I7 (pass grounding),
         DAS-003 TA-1 through TA-5 (tier assignment), I4 (MDT compliance)
    Boundary: The Producer Runtime validates structural conformance of output.
              Semantic correctness of the claims within units is not validated —
              the Producer Runtime checks that a unit has proper provenance, tier,
              and grounding, not that its value is true.

R5: Enforce failure isolation between producers — ensure that one producer's
    failure does not prevent independent producers from executing.
    DAS: DAS-006 PI-1 (failure does not prevent independent passes),
         PI-2 (semantic failure does not affect deterministic),
         PI-3 (failure is recorded), DAS-001 P12 (graceful degradation),
         I7 (AI independence of deterministic layers)
    Boundary: The Producer Runtime isolates execution and reports failures
              (PC-6). Recovery policy (retry, defer, abandon) is determined by
              the scheduling subsystem based on tier and scheduling priorities.

R6: Manage producer versioning and support upgrade-triggered re-evaluation.
    DAS: DAS-010 PU-1 through PU-5 (producer upgrade invalidation),
         DAS-006 PINV-4 (pass upgrade triggers re-execution)
    Boundary: The Producer Runtime detects version changes and reports them
              via PC-6. The scheduling subsystem determines which units to
              invalidate and which producers to re-execute.

R7: Provide the observability surface for producer execution diagnostics.
    DAS: DAS-006 PO-1 (execution metrics), PO-2 (DAG health),
         PO-3 (freshness state), PO-4 (cost accounting)
    Boundary: The Producer Runtime emits events and metrics. Alerting,
              dashboarding, and persistence of observability data are outside scope.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Producer Registration
  Direction:    Offered
  Counterparty: Any component registering a producer (frontends, passes)
  Guarantee:    Every producer whose contract is structurally valid and does not
                introduce a cycle into the Pass DAG is accepted into the registry.
                Upon acceptance, the producer is discoverable, schedulable, and its
                identity is available for provenance records.
  Preconditions: The producer contract is complete (all required fields populated).
                 For passes: input contract, output contract, scope, tier range,
                 determinism, and idempotency are declared. For frontends: source
                 format and output predicates are declared.
  Failure mode: If the contract is structurally invalid (missing required fields,
                tier range inconsistent with determinism classification), registration
                is rejected with a diagnostic identifying the violation. If the
                contract would introduce a cycle into the Pass DAG, registration is
                rejected with the cycle path.

PC-2: Producer Execution
  Direction:    Offered
  Counterparty: Scheduling subsystem (issuer of execution tickets via PC-9)
  Guarantee:    Given an execution ticket specifying a registered producer and a
                scope, the Producer Runtime executes the producer over the specified
                scope in accordance with the Pass DAG ordering and tier constraints.
                The producer receives its declared inputs from the DIR and its output
                batch is validated and committed to the DIR. Execution completes
                or fails within the producer's timeout bound.
  Preconditions: The producer is registered. For passes: all producers that produce
                 the pass's declared input predicates at the required tiers have
                 already executed for the relevant scope in the current execution
                 cycle (DAG ordering satisfied). For frontends: source material at
                 the specified scope is accessible.
  Failure mode: If the producer fails (error, timeout, invalid output), the failure
                is recorded (PC-6), the output batch is discarded, and the producer's
                prior output in the DIR is retained as stale-but-available content
                (DAS-001 P12). Independent producers continue execution unimpeded
                (DAS-006 PI-1). The caller is notified of the failure with the
                producer identity, scope, and failure category (PC-6).

PC-3: DAG Query
  Direction:    Offered
  Counterparty: Scheduling subsystem, observability consumers
  Guarantee:    The current state of the Pass DAG is queryable: registered producers,
                dependency edges, topological order, tier assignments, and per-producer
                execution state. The DAG reflects all accepted registrations and no
                rejected or removed producers.
  Preconditions: None.
  Failure mode: None — the DAG is always available (it is an in-memory structure
                derived from the registry).

PC-4: Producer Discovery
  Direction:    Offered
  Counterparty: Scheduling subsystem
  Guarantee:    Given a predicate identifier and tier, the Producer Runtime returns
                the identity of the producer(s) whose output contract declares that
                predicate at that tier. This enables the scheduling subsystem to
                determine which producer must execute to produce or refresh specific
                DIR content.
  Preconditions: At least one producer is registered.
  Failure mode: If no registered producer's output contract matches the query,
                an empty result is returned. This is not a failure — it indicates
                that no currently registered producer produces the requested content.

PC-5: Batch Execution
  Direction:    Offered
  Counterparty: Scheduling subsystem (for initial build or recovery)
  Guarantee:    Given a batch execution directive, the Producer Runtime executes
                all registered frontends over all tracked source files, then
                executes all registered passes in Pass DAG order over their full
                declared scope. Batch execution honors all tier ordering constraints
                (DAS-006 PE-1) and all isolation guarantees (DAS-006 PI-1 through
                PI-5). Batch execution is functionally equivalent to processing
                a change set that touches every tracked file.
  Preconditions: Source material is accessible. The DIR store is writable.
  Failure mode: Individual producer failures during batch execution are isolated
                per PC-2. Batch execution completes even if some producers fail —
                the resulting DIR state reflects all successful producers and
                retains prior content for failed producers.

PC-6: Failure Report
  Direction:    Offered
  Counterparty: Scheduling subsystem, observability consumers
  Guarantee:    Every producer failure is recorded with: producer identity, producer
                version, scope of the failed execution, failure category (error,
                timeout, invalid output, dependency unavailable), and diagnostic
                detail sufficient for debugging. Failure records are retained for
                the current session.
  Preconditions: A producer execution has failed.
  Failure mode: None — failure recording itself does not fail. If the observability
                subsystem is unavailable, failure records are retained in memory.
```

### Required Contracts

```
PC-7: DIR Write Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-6 and DDS-002:PC-1)
  Guarantee:    The Producer Runtime can commit validated output batches to the DIR
                as write transactions (DDS-002:PC-6). Each unit in the batch is
                admitted via DDS-002:PC-1. Committed units are immediately visible
                to subsequent producer executions within the same execution cycle
                (DAG-ordered producers can read output from prior producers, per
                DDS-002:PC-3(b) within-cycle visibility).
  Preconditions: The output batch has passed validation (R4).
  Failure mode: If the DIR Runtime rejects a write transaction (DDS-002:FM-1
                intake validation failure, DDS-002:FM-4 supersession conflict),
                the Producer Runtime treats the producer execution as failed and
                applies PC-2 failure handling.

PC-8: DIR Read Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-3)
  Guarantee:    Producers can read DIR content matching their declared input
                contracts. Reads during an execution cycle reflect all units
                committed by prior producers in the same cycle (within-cycle
                visibility per DDS-002:PC-3(b)).
  Preconditions: The producer's input contract is declared and validated.
  Failure mode: If DIR content matching the input contract is absent (no producer
                has yet produced it), the pass receives an empty input set. This
                is not a failure — it indicates that upstream producers have not
                yet populated the relevant content (expected during initial build
                or after pass removal).

PC-9: Execution Directives
  Direction:    Required
  Counterparty: Scheduling subsystem responsible for change detection and
                invalidation (DAS-010 RS-1 through RS-7, CD-1 through CD-6,
                IP-1 through IP-6)
  Guarantee:    The scheduling subsystem issues execution tickets specifying
                which producers to execute and over which scope, in response
                to change detection and invalidation cascade results.
  Preconditions: Change detection and invalidation propagation have completed
                for the current change set.
  Failure mode: If no execution directives are received, the Producer Runtime
                remains idle. This is not a failure — it indicates no source
                changes occurred.
```

---

## Lifecycle

### Creation

The Producer Runtime is created during application startup. Creation is lightweight — it allocates the Producer Registry (empty) and the Pass DAG (empty). No producers are registered at creation time.

**Preconditions for creation:** None. The Producer Runtime has no dependencies that must be satisfied before it can be constructed.

**Deferred initialization:** Producer registration occurs after creation, when producer implementations become available. The Producer Runtime does not discover producers autonomously — producers are registered explicitly by the application's dependency injection layer.

### Operation

The Producer Runtime becomes operational when at least one producer is registered. It accepts execution tickets via PC-9 and executes producers according to the Pass DAG.

**Operational invariant:** The Pass DAG is consistent at all times — no cycles, no references to unregistered producers, topological order is current. If a registration or removal would violate consistency, the operation is rejected rather than leaving the DAG in an inconsistent state.

### Quiescence

When the application is shutting down, the Producer Runtime enters quiescence:

1. No new execution tickets are accepted.
2. Currently executing producers are allowed to complete or are interrupted after a timeout.
3. Any output batches from completed producers are committed to the DIR.
4. Output batches from interrupted producers are discarded.
5. The registry and DAG remain available for query (supporting snapshot operations by the DIR Store) until final destruction.

### Destruction

The Producer Runtime is destroyed during application teardown. The registry and DAG are deallocated. No cleanup of DIR content is performed — the DIR Store owns persistence.

**Access after destruction:** Any attempt to register a producer, query the DAG, or execute a producer after destruction is an error in the caller. The Producer Runtime does not guard against post-destruction access — this is a contract on the application lifecycle.

---

## State Model

The Producer Runtime occupies one of four states:

```
Empty → Ready → Executing → Ready
                          → Quiescing → Terminated
```

**Empty.** The runtime has been created but no producers are registered. The Pass DAG is empty. Execution tickets are rejected (no producers to execute). Registration is accepted.

**Ready.** At least one producer is registered. The Pass DAG is constructed and valid. Execution tickets are accepted. Registration and removal are accepted (the DAG is reconstructed on each change).

**Executing.** An execution cycle is in progress (either batch or incremental). The runtime is processing execution tickets — invoking producers in DAG order, validating output, and committing results. New execution tickets are queued. Producer registration is deferred until the current execution cycle completes (to prevent DAG mutation during execution).

**Quiescing.** The runtime is shutting down. No new execution tickets are accepted. In-progress producers are completing or being interrupted. Transition to Terminated occurs when all in-progress work is resolved.

**Terminated.** The runtime has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Empty | Ready | First producer registered | DAG constructed with at least one node |
| Ready | Empty | Last producer removed | DAG empty |
| Ready | Executing | Execution ticket received | Producers invoked in DAG order |
| Executing | Ready | All tickets in current cycle processed | Output committed, DAG stable |
| Ready | Quiescing | Shutdown signal | No new tickets accepted |
| Executing | Quiescing | Shutdown signal during execution | In-progress work drains |
| Quiescing | Terminated | All in-progress work resolved | Resources deallocated |

**Invalid transitions:** Empty → Executing (no producers to execute). Terminated → any state. Quiescing → Ready or Executing (shutdown is irreversible).

---

## Execution Model

### Execution Ordering

Producers execute in the order defined by the Pass DAG and the tier hierarchy:

1. **Frontends first.** All frontends execute before any pass. Frontends are implicit DAG roots (DAS-006 PD-6). Frontend execution produces the T0 foundation that all passes depend on.

2. **Passes in topological order.** Passes execute in the topological order of the Pass DAG. A pass does not begin until all passes that produce its declared inputs have completed for the relevant scope.

3. **Tier-level ordering is enforced.** All T0-producing passes complete before any T1-producing pass begins. All T1-producing passes complete before any T2-producing pass begins (DAS-006 PE-1). This is a consequence of DAG ordering combined with the tier dependency constraint (DAS-006 PC-TIER-2, DAS-003 CTD-1/CTD-2).

### Concurrency

Within a single topological level, passes with no mutual dependency may execute concurrently (DAS-006 PE-2). Concurrent execution is permitted but not mandated — the Producer Runtime may serialize execution within a level without violating any contract.

**Isolation guarantee during concurrent execution:** Concurrently executing passes share no mutable state (DAS-006 PI-4). Each pass reads from the DIR (which provides immutable units per DAS-002 I-LC-5) and produces an output batch that is validated and committed independently. No pass observes another pass's uncommitted output.

### Incremental Execution

When execution tickets for a subset of producers and scopes are received (incremental mode), the Producer Runtime:

1. Accepts the set of execution tickets.
2. Orders the tickets according to the Pass DAG.
3. Executes each producer over its specified scope only.
4. Validates and commits output batches.
5. Reports which producers produced changed output (enabling the scheduling subsystem to determine whether downstream cascade is needed, per DAS-006 PE-5).

**Changed output detection:** The Pass Runtime (DDS-003) is the sole owner of output comparison. After a pass invocation completes, the Pass Runtime compares the output batch to the pass's prior output for the same scope window (DDS-003:PC-3) and returns a change report (changed or no change). The Producer Runtime consumes this change report and forwards it to the scheduling subsystem. The Producer Runtime does not independently perform output comparison — it relies on DDS-003:PC-3 for the comparison result and on its own orchestration role to propagate that result to the caller (DAS-006 PE-5, DAS-010 IP-6).

### Batch Execution

In batch mode (initial build or recovery per DAS-002 DC-5), all producers execute over their full scope in DAG order. No incremental scoping is applied. Batch execution is functionally equivalent to an execution cycle where every file has changed.

### Producer Invocation

The Producer Runtime invokes a producer by:

1. Assembling the producer's input set from the DIR, matching the producer's declared input contract.
2. Providing the input set and the scope to the producer.
3. Receiving the output batch from the producer.
4. Validating the output batch (R4).
5. Committing the validated output to the DIR (via PC-7).

The Producer Runtime does not inspect producer internals (DAS-006 CPC-5). It interacts only with the producer's contract — providing declared inputs, receiving declared outputs.

---

## Memory and Ownership

### Owned Resources

**Producer Registry.** The Producer Runtime exclusively owns the runtime registration state: the catalog of producer contracts, their validation status, and their participation in the Pass DAG. The registry does not store installation metadata, deployment information, or producer implementation artifacts — it stores only the declared contracts needed for DAG construction, execution orchestration, and provenance resolution. No other subsystem reads or writes the registry directly. External access is through PC-1 (registration), PC-3 (DAG query), and PC-4 (discovery).

**Pass DAG.** The Producer Runtime exclusively owns the Pass DAG data structure. The DAG is derived from the registry and is reconstructed when the registry changes. External subsystems query the DAG through PC-3.

**Execution state.** During an execution cycle, the Producer Runtime owns the per-producer execution state: which producers have executed, which are in progress, which have failed, and the output batches awaiting validation.

**Failure records.** The Producer Runtime owns the failure records for the current session (PC-6). These records are retained in memory for the session duration and are not persisted.

### Borrowed Resources

**DIR content (read).** The Producer Runtime borrows DIR content via PC-8 for the duration of a producer's execution. The borrowed content is immutable (DAS-002 I-LC-5) and remains valid for the duration of the execution cycle.

**Source material (read).** Frontends borrow access to source files for the duration of their execution. The Producer Runtime does not own source files — it receives file paths from execution tickets.

### Shared Resources

**DIR (write).** The Producer Runtime shares write access to the DIR with the DIR Store. Writes are mediated through PC-7 — the Producer Runtime never writes to the DIR directly but submits validated output batches through the contract.

### Memory Bounds

**Registry and DAG:** Proportional to the number of registered producers. At the expected scale (tens of producers, not thousands), memory consumption is negligible — a few kilobytes.

**Output batches:** Proportional to the number of units produced per execution. For a per-file pass processing a single file, the output batch is typically 50-300 units (a few kilobytes). For a per-module composition pass, the batch may be larger. Output batches are transient — they exist only between producer execution and DIR commit.

**Failure records:** Proportional to the number of failures in the current session. Expected to be small under normal operation.

### Eviction

Output batches are released immediately after DIR commit or discard (on failure). Failure records are released on session end. The registry and DAG persist for the session duration.

---

## Failure Handling

```
FM-1: Producer Execution Error
  Trigger:     A producer throws an error during execution (logic error,
               resource exhaustion, assertion failure).
  Detection:   The Producer Runtime catches the error at the producer
               invocation boundary.
  Response:    The output batch from the failed producer is discarded.
               Prior output from the producer remains in the DIR as stale-but-
               available content (DAS-001 P12, DAS-006 PI-3). The failure is
               recorded (PC-6). Passes that depend on the failed producer's
               output are skipped for the current cycle — they retain their
               prior output (DAS-006 PI-1).
  Caller observes: The scheduling subsystem receives a failure notification
               with the producer identity, scope, and failure category. Recovery
               policy (retry, defer, abandon) is outside Producer Runtime scope.
  Recovery:    On the next execution cycle, the producer is eligible for
               re-execution. No permanent state change occurs from a transient
               failure.

FM-2: Producer Timeout
  Trigger:     A producer does not complete within its declared timeout bound.
  Detection:   The Producer Runtime monitors execution duration against the
               producer's timeout.
  Response:    Identical to FM-1 — the execution is interrupted, the output
               batch is discarded, prior output is retained, the failure is
               recorded. Dependent passes are skipped.
  Caller observes: Failure notification with category "timeout."
  Recovery:    Same as FM-1.

FM-3: Invalid Output
  Trigger:     A producer's output batch fails validation (R4). Possible causes:
               output predicates not in declared output contract (DAS-006 I3),
               output tier outside declared tier range (DAS-006 I4), missing
               provenance (DAS-006 I7), missing grounding (DAS-006 I5), tier
               exceeds predicate MDT (DAS-003 I4).
  Detection:   Output validation after producer execution.
  Response:    The entire output batch is discarded. The producer's prior output
               is retained. The failure is recorded with the specific validation
               violations.

               Whole-batch discard rationale: A producer's output batch is the
               result of a single execution over a declared scope. The producer's
               contract guarantees output completeness (DAS-006 I3) — accepting
               a partial batch would violate this invariant, leaving the DIR in
               a state where some units for the scope are current and others are
               stale, with no way to distinguish which are trustworthy. Partial
               acceptance would also break provenance integrity: downstream
               passes that depend on the producer's output contract would receive
               an incomplete input set without knowing it is incomplete.
               Whole-batch discard preserves a simple invariant: committed output
               is always complete and valid, or the prior complete output is
               retained.

  Caller observes: Failure notification with category "invalid_output" and
               validation details.
  Recovery:    Invalid output indicates a defective producer. The producer
               remains registered but its output is not committed until the
               defect is corrected (via producer upgrade, PU-1).

FM-4: DAG Cycle on Registration
  Trigger:     Registering a new pass would introduce a cycle in the Pass DAG.
  Detection:   Cycle detection during DAG construction (DAS-006 I1).
  Response:    Registration is rejected. The pass is not added to the registry.
               The existing DAG is unchanged.
  Caller observes: Registration rejection with the cycle path (the sequence
               of passes forming the cycle).
  Recovery:    The pass contract must be revised to eliminate the dependency
               that creates the cycle (DAS-006 §5.2 resolution options: merge,
               extract, or interface).

FM-5: Semantic Pass AI Unavailability
  Trigger:     A semantic pass (T2-producing) cannot reach the AI service
               (network failure, rate limit, service outage).
  Detection:   The semantic pass reports an AI service error to the Producer
               Runtime (treated as FM-1).
  Response:    Identical to FM-1. Critically: no deterministic pass is affected
               (DAS-006 PI-2, DAS-001 I7). T0 and T1 producers execute normally.
               The T2 producer's prior output remains available as stale content.
  Caller observes: Failure notification with category "dependency_unavailable."
  Recovery:    The scheduling subsystem may schedule the T2 producer for
               deferred re-execution when AI services become available
               (DAS-010 RS-6, RS-7).

FM-6: DIR Write Failure
  Trigger:     The DIR Store rejects a commit (PC-7 failure).
  Detection:   The DIR Store returns an error on commit.
  Response:    The output batch is discarded. The producer execution is treated
               as failed (FM-1 handling applies). The failure is recorded.
  Caller observes: Failure notification with category "dir_write_failure."
  Recovery:    The scheduling subsystem determines whether to retry the
               producer execution after the DIR Store issue is resolved.

FM-7: Source Material Inaccessible
  Trigger:     A frontend cannot read its source file (file deleted, permissions
               changed, disk error).
  Detection:   The frontend reports an I/O error to the Producer Runtime.
  Response:    The frontend execution for the inaccessible file is treated
               as failed (FM-1 handling). Other files' frontend executions
               proceed independently.
  Caller observes: Failure notification with category "source_inaccessible"
               and the file path.
  Recovery:    If the file reappears (e.g., it was temporarily locked), the
               next execution cycle will process it normally.
```

---

## Performance Requirements

Performance requirements are classified as follows:

- **Architectural requirement** — a bound mandated by DAS invariants or freshness contracts. Violation breaks an architectural guarantee.
- **Engineering target** — an initial numeric bound based on expected workload and reasoning, not yet validated by measurement. These targets must be validated through benchmarking under representative workloads before promotion to firm requirements.
- **Benchmark-derived** — a bound established through measured performance of a working implementation.

```
PR-1: Frontend Execution Latency
  Operation:   Single-file frontend execution (parse and emit T0 units)
  Category:    Architectural requirement (latency constraint);
               engineering target (numeric bound)
  Bound:       Upper bound 100ms per file (initial target)
  Assumptions: File size ≤ 5,000 lines. Single-language frontend.
  Rationale:   DAS-003 T0 freshness contract requires source-synchronous
               update. Frontend execution is on the synchronous pipeline
               critical path (DAS-010 RS-1). The 100ms bound is an initial
               target — the architectural requirement is that frontend
               execution is fast enough to maintain perceived source-
               synchronous freshness. Validate by benchmarking the
               SwiftSyntax and tree-sitter frontends on files at the upper
               bound of the expected size range.

PR-2: Deterministic Pass Execution Latency
  Operation:   Single per-file deterministic pass execution
  Category:    Architectural requirement (latency constraint);
               engineering target (numeric bound)
  Bound:       Upper bound 50ms per file per pass (initial target)
  Assumptions: File with ≤ 200 entities. Pass reads ≤ 5 predicates.
  Rationale:   Deterministic passes are on the synchronous pipeline critical
               path (DAS-010 RS-2, RS-3). The architectural requirement is
               that the cumulative deterministic pass pipeline does not
               dominate synchronous latency. The 50ms per-pass target
               assumes ~5 deterministic passes for a cumulative target of
               ~250ms. Validate by benchmarking representative deterministic
               passes on files with entity counts at the upper bound.

PR-3: DAG Construction Latency
  Operation:   Full DAG reconstruction from registry
  Category:    Engineering target
  Bound:       Upper bound 10ms (initial target)
  Assumptions: ≤ 100 registered passes
  Rationale:   DAG reconstruction occurs on producer registration, which is
               infrequent. No DAS freshness contract constrains this
               operation. The 10ms target reflects the expectation that
               topological sort of ≤100 nodes is computationally trivial.
               Validate by benchmarking DAG construction at the upper bound
               of expected registry size.

PR-4: Output Validation Latency
  Operation:   Validation of a single output batch
  Category:    Engineering target
  Bound:       Upper bound 5ms per batch (initial target)
  Assumptions: Batch of ≤ 500 units
  Rationale:   Validation is on the critical path between producer execution
               and DIR commit. Validation is structural (contract matching,
               tier checking, provenance checking) and does not require I/O.
               Validate by benchmarking contract validation on batches at the
               upper bound of expected size.

PR-5: Semantic Pass Budget
  Operation:   Semantic pass execution (T2-producing)
  Category:    Architectural requirement
  Bound:       No latency bound (T2 freshness is eventual per DAS-003).
               Cost bound: declared in the pass's cost model (DAS-006 SP-4).
  Assumptions: AI service latency 1-10 seconds per invocation.
  Rationale:   Semantic passes are not on the synchronous pipeline. Their
               cost is governed by budget constraints (DAS-006 PS-4), not
               by latency bounds. No numeric target needed — the
               architectural constraint (eventual freshness, budget cap)
               is sufficient.
```

---

## Observability

The Producer Runtime emits the following observable information:

**Execution Metrics (DAS-006 PO-1).** For each producer execution: producer identity, producer version, scope, input size (number of units read), output size (number of units produced), execution duration, success or failure, and change delta (how many units in the output batch differ from prior output). These metrics are emitted as events after each producer execution completes.

**DAG Health (DAS-006 PO-2).** On query (PC-3): number of registered producers (by type: frontend, deterministic pass, semantic pass, composition pass), dependency structure, any producers in failed state (last execution failed), any producers with stale output (last execution was more than one epoch ago for T0/T1 producers).

**Cost Accounting (DAS-006 PO-4).** For semantic passes: cumulative AI invocation count, cumulative token consumption, and cumulative execution duration, aggregated per pass and per configurable time window. Cost accounting is maintained in memory for the current session.

**Registration Events.** Producer registered, producer removed, producer upgraded (version change detected). Each event includes the producer identity, contract summary, and timestamp.

**Failure Events.** Every FM-1 through FM-7 occurrence emits a failure event with the fields specified in PC-6.

**Overhead.** Observability data collection does not block producer execution. Metrics are collected after execution completes, not during. The memory overhead of observability data is bounded by the number of producers multiplied by the retention window (session duration).

---

## Testing Requirements

**Contract tests (PC-1 through PC-9):**
- Registration of a valid frontend contract succeeds and the frontend appears in the registry.
- Registration of a valid pass contract succeeds, the pass appears in the registry, and the DAG is updated.
- Registration of an invalid contract (missing fields, inconsistent tier/determinism) is rejected with a diagnostic.
- Registration that introduces a DAG cycle is rejected with the cycle path.
- Execution of a registered producer over a specified scope produces output that is validated and committed.
- DAG query returns the current graph state including all registered producers and edges.
- Discovery by predicate and tier returns the correct producer(s).
- Batch execution invokes all producers in DAG order.
- Failure reports contain all required fields.

**State model tests:**
- Empty → Ready transition on first registration.
- Ready → Empty transition on last removal.
- Ready → Executing → Ready transition on execution cycle completion.
- Executing state defers new registrations until cycle completion.
- Quiescing state rejects new execution tickets.
- Invalid transitions (Empty → Executing, Terminated → any) are rejected.

**Failure mode tests (FM-1 through FM-7):**
- A producer that throws an error: output discarded, prior output retained, failure recorded, independent producers unaffected.
- A producer that exceeds timeout: same handling as error.
- A producer that produces invalid output (wrong predicates, wrong tier, missing provenance, missing grounding): output discarded, validation violations reported.
- DAG cycle detection on registration: specific cycle path reported.
- Semantic pass with unavailable AI: T0/T1 producers unaffected, T2 prior output retained.
- DIR write failure: output discarded, failure recorded.
- Inaccessible source file: only the affected file's frontend fails; others proceed.

**Integration tests:**
- A multi-pass pipeline where pass B depends on pass A: B receives A's output as input, B does not execute before A completes.
- Incremental execution: only the specified producers over the specified scopes execute.
- Changed output detection: when a producer produces identical output, "no change" is reported.
- Tier ordering: T0 passes complete before T1 passes begin, T1 before T2.
- Concurrent execution: independent passes within a topological level execute correctly regardless of execution order.

---

## Future Evolution

**Module Intelligence (DAS Roadmap Phase 2).** The current design supports composition passes (DAS-006 CP-1 through CP-4) that create module-level entities. As Module Intelligence matures, new composition passes will be registered. The Producer Runtime requires no design changes — new passes register their contracts and integrate into the DAG automatically (DAS-006 C2).

**Project Intelligence (DAS Roadmap Phase 3).** System-level composition passes (per-system scope) will follow the same registration and execution model. The broader scope may increase execution latency for composition passes, but the Producer Runtime's architecture is scope-agnostic — it executes producers at whatever scope the pass contract declares.

---

## Revision History

```
0.1 — 2026-06-29 — Principal Engineer — Initial draft
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions: decoupled from Update Engine (contract-oriented counterparties), classified performance requirements (architectural vs engineering target), clarified Producer Registry ownership scope, justified FM-3 whole-batch discard policy, removed operational Open Questions
0.3 — 2026-06-28 — Principal Engineer — Platform consistency cleanup:
      (1) Changed output detection: clarified that Pass Runtime (DDS-003:PC-3)
          is sole owner of output comparison; Producer Runtime consumes the
          comparison result.
      (2) Dependency correction: added DDS-002 to Depends On (DDS-001
          requires DDS-002:PC-3, DDS-002:PC-6).
      (3) Required contracts PC-7 and PC-8: resolved counterparty from
          placeholder "DDS for DIR Store" to DDS-002 with qualified
          contract references.
      (4) Replaced Depended By with derived marker per platform convention.
```
