# DDS-003: Pass Runtime

```
Document:      DDS-003
Title:         Pass Runtime
Status:        Draft
Version:       0.2
Author:        Principal Engineer
Created:       2026-06-28
Last Revised:  2026-06-28
Reviewers:     CTO (focused review — execution semantics, isolation,
               cross-DDS compatibility)
Depends On:    DDS-000 (Design Authoring Standard), DDS-001 (Producer Runtime),
               DDS-002 (DIR Runtime Model)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-006, DAS-010
```

## Abstract

This document specifies the engineering design of the Pass Runtime — the subsystem that manages the execution lifecycle of individual pass invocations within the DIR pipeline. It defines input assembly (resolving a pass's declared input contract and scope to a concrete set of DIR units), execution context construction, execution strategies for deterministic and semantic passes (with composition as an orthogonal capability layered on either strategy), the output pipeline (collection, provenance stamping, validation), changed output detection for early termination, cancellation semantics, retry eligibility, and idempotency enforcement. The Pass Runtime refines the execution model of DDS-001 (Producer Runtime) at the individual invocation level, realizing pass execution contracts from DAS-006, tier-specific constraints from DAS-003, and early termination semantics from DAS-010.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P3 (deterministic before semantic — category-specific execution
            strategies enforce deterministic pass AI independence at runtime),
            P4 (composition produces emergence — composition pass execution
            validates emergence requirement), P8 (AI as consumer — semantic
            pass input is assembled from DIR, not source), P9 (incremental —
            scope resolution enables per-entity/per-file re-execution;
            changed output detection enables early termination),
            P12 (graceful degradation — semantic pass failure leaves
            deterministic layers unaffected)
  Not addressed: P1 (DDS-002 — DIR as canonical asset), P2 (DDS-001 —
                tier-ordered execution orchestration), P5 (DDS-002 —
                grounding enforcement at write boundary), P6, P7, P10
                (DDS for Retrieval/Context Assembly), P11 (DDS-001 —
                producer independence via DAG)

DAS-002: Decode Intermediate Representation
  Realized: I7 (pass grounding — grounding chain construction in output
            pipeline, co-realized with DDS-001:R4), I-PROV-1, I-PROV-2
            (provenance — output pipeline stamps provenance before
            submission to DIR)
  Not addressed: Atomic unit contract fields (DDS-002 intake validation),
                I1 through I6 (DDS-002 and DDS-001), I8 (DDS for Index
                Manager), DC-1 through DC-5 (DDS-002), lifecycle model
                (DDS-002:R4)

DAS-003: Tier Model
  Realized: TA-1 (assignment by production method — output pipeline verifies
            tier assignment consistency with pass category), TA-5 (lowest
            valid tier — enforced for deterministic passes), CTD-1, CTD-2,
            CTD-3 (cross-tier dependencies — input assembly filters by
            permitted input tiers), Freshness contracts (co-realized with
            DDS-001: synchronous execution for T0/T1 passes, deferred
            execution for T2 passes)
  Not addressed: I1 through I7 (DDS-002 and DDS-001), TL-1 (DDS-001
                tier-ordered execution), TL-2, TL-3 (DDS-002 and DDS
                for Storage Engine), confidence model per tier (DDS-002
                intake validation), MDT compliance (DDS-002:R2)

DAS-006: Pass Architecture
  Realized (co-realized with DDS-001):
    PE-3 (scoped re-execution — scope resolution maps scope to entity sets),
    PE-5 (early termination — changed output detection determines whether
    output differs from prior), PE-6 (semantic pass propagation — semantic
    output comparison accounts for non-determinism),
    PI-4 (no shared mutable state — execution context isolation),
    CPC-1 (declared inputs present — input assembly guarantees),
    CPC-4 (execution order not observable — execution context hides ordering)
  Realized (extends DDS-001):
    SP-1 (semantic pass reads DIR — input assembly enforces DIR-only input),
    SP-2 (grounded output — output pipeline constructs grounding chains),
    SP-3 (graceful degradation — semantic execution strategy handles AI
    failure without blocking pipeline), SP-4 (cost model — execution context
    carries budget information for semantic passes),
    SP-5 (inference provenance — output pipeline stamps inference metadata),
    CP-1 (entity creation — composition execution strategy supports
    scope-level entity creation), CP-2 (entity enrichment — composition
    strategy supports enrichment of existing entities),
    CP-3 (containment tree — composition output validation verifies
    containment integrity), CP-4 (emergence — composition output
    validation verifies emergent property production),
    DP-1 (no AI invocation — deterministic execution strategy enforces),
    DP-2 (testable by assertion — idempotency verification enables)
  Not addressed: PD-1 through PD-6 (DDS-001 DAG construction),
                PE-1 (DDS-001 tier-level ordering), PE-2 (DDS-001
                concurrent execution permission), PE-4 (DDS-001 change
                propagation terminates — DAG-level property),
                PI-1, PI-2, PI-3 (DDS-001 system-level failure isolation),
                PI-5 (DDS-001 provenance attribution),
                CPC-2, CPC-3, CPC-5 (DDS-001 cross-pass contracts),
                Pass Scheduling (PS-1 through PS-4 — DDS for Update Engine),
                Pass Invalidation (PINV-1 through PINV-5 — DDS for
                Update Engine), I1 through I8 (DDS-001),
                C1 through C7 (DDS-001)

DAS-010: Incremental Update Model
  Realized: IP-6 (early termination — changed output detection enables the
            scheduling subsystem to stop cascade propagation when pass output
            is unchanged), RS-1, RS-2, RS-3 (synchronous pipeline pass
            execution — co-realized with DDS-001 at orchestration level,
            realized here at invocation level)
  Not addressed: CD-1 through CD-6 (DDS for Update Engine),
                IP-1 through IP-5 (DDS for Update Engine),
                CB-1 through CB-4 (DDS for Update Engine),
                RS-4 through RS-10 (DDS for Update Engine and DDS-001),
                WR-1 through WR-7 (DDS-002), PU-1 through PU-5 (DDS-001),
                GC-1 through GC-4 (DDS for Storage Engine),
                IM-1 through IM-6 (DDS for Index Manager),
                I1 through I8 (DDS-002, DDS-001, DDS for Update Engine)
```

## Terminology

**Execution Context** — The runtime package provided to a pass when it is invoked. The execution context contains the input set, the scope window, pass metadata (identity, version, contract), and — for semantic passes — budget information. The execution context is the pass's complete view of the world. A pass interacts with the system only through its execution context; it does not query the DIR directly or communicate with other passes. `INTRODUCED`

**Input Set** — The concrete collection of DIR units matching a pass's declared input contract within its scope window. The input set is assembled by the Pass Runtime from the DIR before the pass is invoked. It contains only units at tiers permitted by the pass's input contract (DAS-006 PC-TIER-2) and only units within the scope window. The input set is a read-only snapshot — the pass cannot modify it. `INTRODUCED`

**Scope Window** — The entity set determined by scope resolution for a specific pass invocation. For a per-file pass processing file F, the scope window is the set of entities contained in F. For a per-module pass processing module M, the scope window is the set of entities contained in M. The scope window determines which DIR units are included in the input set and which entities the pass may produce output about. `INTRODUCED`

**Output Comparison** — The process of comparing a pass's new output batch against its prior output for the same scope window. Output comparison determines whether the pass produced changed output (triggering downstream cascade) or identical output (enabling early termination per DAS-006 PE-5, DAS-010 IP-6). Comparison operates at the unit level: same subject, same predicate, same tier, same value constitutes "identical." `INTRODUCED`

**Pass Invocation** — A single execution of a pass over a specific scope window. A pass invocation is the unit of work within the Pass Runtime. It begins with input assembly, proceeds through pass execution, and ends with output collection. Each invocation is independent — it shares no mutable state with other invocations (DAS-006 PI-4). `INTRODUCED`

**Retry Eligibility** — The property of a pass invocation that determines whether it may be safely re-executed after failure. Deterministic passes are always retry-eligible (same input produces same output — DAS-006 PC-IDEM-1). Semantic passes are retry-eligible unless the failure is due to a non-transient condition (defective pass logic, structurally invalid input). Retry eligibility is a property determined by the Pass Runtime; the retry decision itself is made by the scheduling subsystem. `INTRODUCED`

---

## Responsibilities

```
R1: Assemble the input set for each pass invocation from the DIR, matching
    the pass's declared input contract within its scope window.
    DAS: DAS-006 CPC-1 (declared inputs are present), SP-1 (semantic pass
         reads DIR), DAS-003 CTD-1 through CTD-3 (cross-tier input filtering)
    Boundary: The Pass Runtime reads from the DIR via DDS-002:PC-3. It does
              not construct indexes, optimize queries, or cache input sets
              across invocations. Input assembly is per-invocation.

R2: Resolve pass scope to a concrete scope window — the entity set over
    which a specific invocation operates.
    DAS: DAS-006 PC-SCOPE-1 (scope determines incremental granularity),
         DAS-001 P9 (incremental — scope resolution enables per-entity/
         per-file re-execution)
    Boundary: The Pass Runtime resolves scope given the pass's declared scope
              granularity and the entities/files specified in the execution
              ticket. Scope determination (which files changed, which entities
              are affected) is the scheduling subsystem's responsibility.

R3: Construct the execution context for each pass invocation — the complete
    runtime package the pass receives.
    DAS: DAS-006 PI-4 (no shared mutable state — the execution context
         isolates the pass from system state), CPC-4 (execution order not
         observable — context does not expose ordering information),
         SP-4 (cost model — context provides budget for semantic passes)
    Boundary: The Pass Runtime constructs and provides the context. The pass
              implementation consumes it. The Pass Runtime does not inspect
              or constrain pass internals (DAS-006 CPC-5).

R4: Execute passes according to their execution strategy (deterministic or
    semantic) and, for composition passes, apply additional composition-
    specific constraints.
    DAS: DAS-006 DP-1 (deterministic passes do not invoke AI), SP-1
         through SP-5 (semantic pass constraints), CP-1 through CP-4
         (composition pass constraints), DAS-001 P3 (deterministic before
         semantic), P4 (composition produces emergence), P8 (AI as consumer)
    Boundary: The Pass Runtime executes the pass and applies execution
              strategy constraints plus composition constraints where
              applicable. It does not determine execution order (DDS-001)
              or schedule the invocation (scheduling subsystem).

R5: Collect pass output and construct the output batch with provenance,
    grounding metadata, and tier assignment.
    DAS: DAS-002 I-PROV-1, I-PROV-2 (provenance stamping), I7 (pass
         grounding), DAS-006 SP-2 (grounded output), SP-5 (inference
         provenance for semantic passes)
    Boundary: The Pass Runtime prepares the output batch for submission to
              the DIR. DDS-001:R4 performs contract-level output validation
              (declared predicates, tier range). DDS-002:R2 performs intake
              validation (field-level invariants). The Pass Runtime's output
              pipeline operates before both.

R6: Detect changed output by comparing the new output batch against the
    pass's prior output for the same scope window.
    DAS: DAS-006 PE-5 (early termination for deterministic passes), PE-6
         (semantic pass change propagation), DAS-010 IP-6 (early termination)
    Boundary: The Pass Runtime is the sole owner of changed output comparison.
              It performs the comparison, maintains the prior output records,
              and exposes the result through PC-3. DDS-001's changed output
              reporting (DDS-001 Incremental Execution) is fulfilled by
              consuming DDS-003's comparison result — DDS-001 does not
              independently compare output. The cascade decision (whether to
              trigger downstream passes) is made by the scheduling subsystem.

R7: Handle cancellation of in-progress pass invocations.
    DAS: DAS-001 P12 (graceful degradation — cancellation must not corrupt
         state), DDS-001:FM-2 (timeout as a cancellation trigger)
    Boundary: The Pass Runtime signals cancellation and ensures no partial
              output is committed. The cancellation decision is made by
              the Producer Runtime (DDS-001) or scheduling subsystem.

R8: Determine retry eligibility for failed pass invocations.
    DAS: DAS-006 PC-IDEM-1 (deterministic passes are idempotent — safe to
         retry), SP-3 (semantic pass graceful degradation)
    Boundary: The Pass Runtime determines whether a failed invocation is
              retry-eligible based on the failure category and pass category.
              The retry decision (whether and when to retry) is made by
              the scheduling subsystem.

R9: Support composition pass entity creation and containment tree
    maintenance.
    DAS: DAS-006 CP-1 (create scope-level entities), CP-2 (enrich
         existing entities), CP-3 (containment tree integrity),
         DAS-001 P4 (composition produces emergence)
    Boundary: The Pass Runtime enables composition passes to declare new
              entities and containment relationships as part of their output.
              Entity identity assignment is DDS-002:R5. Containment tree
              structure is governed by DAS-004.

R10: Provide per-invocation observability — execution metrics, cost
     accounting, and failure diagnostics at the individual invocation level.
     DAS: DAS-006 PO-1 (execution metrics per pass invocation),
          PO-4 (cost accounting for semantic passes)
     Boundary: The Pass Runtime emits invocation-level metrics. Aggregation
               across invocations and across execution cycles is DDS-001:R7.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Pass Invocation
  Direction:    Offered
  Counterparty: Producer Runtime (DDS-001, during fulfillment of DDS-001:PC-2)
  Guarantee:    Given a registered pass identity, a scope window (set of
                entities or files), and the current DIR visibility context,
                the Pass Runtime:
                1. Assembles the input set (R1, R2).
                2. Constructs the execution context (R3).
                3. Executes the pass using its category-specific strategy (R4).
                4. Collects the output and constructs the output batch (R5).
                5. Compares the output to prior output (R6).
                6. Returns the validated output batch and a change report
                   indicating whether the output differs from the prior
                   invocation's output.
                The output batch is ready for submission to the DIR via
                DDS-002:PC-6. No partial output is produced — the invocation
                either completes with a full output batch or fails with
                no output.
  Preconditions: The pass is registered in the Producer Registry (DDS-001).
                 The scope window is non-empty. The DIR is available for
                 reads (DDS-002:PC-3).
  Failure mode: If input assembly fails (no units match the input contract
                within the scope window), the invocation returns an empty
                output batch — this is not a failure but a valid "nothing
                to produce" result. If the pass itself fails (error,
                timeout, AI unavailability), the invocation fails with no
                output — see FM-1 through FM-5. The caller receives the
                failure category and diagnostic.

PC-2: Input Assembly
  Direction:    Offered
  Counterparty: Producer Runtime (DDS-001), scheduling subsystem (for
                input set inspection during scheduling decisions)
  Guarantee:    Given a pass's input contract (predicates, tiers, entity
                types) and a scope window, the Pass Runtime queries the
                DIR and returns the complete set of units matching the
                contract within the scope. The input set reflects the
                current DIR visibility semantics (DDS-002:PC-3): during
                synchronous pipeline execution, pipeline-internal reads
                include prior producers' committed output (DDS-002:PC-3(b)).
                The input set contains only units at tiers permitted by the
                pass's input contract. Units outside the scope window are
                excluded.
  Preconditions: The pass's input contract is declared and validated
                 (DDS-001:PC-1). The scope window is defined.
  Failure mode: If no units match the input contract within the scope
                window, an empty input set is returned. This is not a
                failure — it indicates that upstream producers have not
                yet populated the relevant content within the scope.

PC-3: Changed Output Detection
  Direction:    Offered
  Counterparty: Producer Runtime (DDS-001), scheduling subsystem
  Guarantee:    After a pass invocation completes, the Pass Runtime compares
                the output batch against the pass's prior output for the
                same scope window. The Pass Runtime is the sole owner of
                this comparison — DDS-001 consumes the comparison result
                but does not independently perform output comparison. The
                comparison uses the canonical unit equality semantics
                defined by the DIR Runtime (DDS-002): two units are
                identical when they share the same subject, predicate, tier,
                and value as determined by the DIR's equality definition.
                The result is one of:
                - **No change**: complete bidirectional match under DIR
                  equality semantics. Every new unit has a prior counterpart
                  and vice versa.
                - **Changed**: at least one unit differs (added, removed,
                  or value/tier/confidence changed under DIR equality
                  semantics).
                This report enables the scheduling subsystem to implement
                early termination (DAS-006 PE-5, DAS-010 IP-6).
  Preconditions: A pass invocation has completed successfully. Prior output
                 for the same pass and scope window is available for
                 comparison (or absent, in which case the result is
                 "changed" by definition — first invocation always changes).
  Failure mode: None. Comparison is a deterministic operation over
                in-memory data.

PC-4: Pass Cancellation
  Direction:    Offered
  Counterparty: Producer Runtime (DDS-001), scheduling subsystem
  Guarantee:    An in-progress pass invocation can be cancelled. Cancellation
                is cooperative: the Pass Runtime sets a cancellation flag
                that the pass can check during execution. The Pass Runtime
                waits up to the pass's declared timeout for the pass to
                acknowledge cancellation and stop. If the pass does not
                stop within the timeout, the invocation is forcibly
                terminated (equivalent to timeout — DDS-001:FM-2).
                On cancellation, no output batch is produced and no output
                is committed to the DIR. The pass's prior output is
                retained.
  Preconditions: A pass invocation is in progress.
  Failure mode: None. Cancellation always succeeds — either the pass
                cooperates, or it is forcibly terminated after timeout.
```

### Required Contracts

```
PC-5: DIR Read Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-3)
  Guarantee:    The Pass Runtime can read DIR content matching a pass's
                input contract within a scope window. Reads during
                synchronous pipeline execution observe committed epoch
                plus prior producers' writes (DDS-002:PC-3(b)).
  Preconditions: The DIR Runtime is operational (DDS-002 state: Operational).
  Failure mode: If the DIR Runtime is not operational (Loading or
                Terminated), input assembly is deferred until the DIR
                Runtime becomes operational.

PC-6: DIR Write Transaction
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-6)
  Guarantee:    The Pass Runtime can submit validated output batches as
                write transactions. Used for committing pass output after
                the output pipeline completes.
  Preconditions: The output batch has passed the output pipeline (R5).
  Failure mode: If the DIR Runtime rejects the write transaction
                (DDS-002:FM-1 intake validation failure, DDS-002:FM-4
                supersession conflict), the pass invocation is treated as
                failed (FM-4).

PC-7: Pass Contract Query
  Direction:    Required
  Counterparty: Producer Runtime (DDS-001, via DDS-001:PC-3 and DDS-001:PC-4)
  Guarantee:    The Pass Runtime can query the pass's declared contract
                (input contract, output contract, scope, tier range,
                determinism, idempotency) and the Pass DAG structure to
                determine execution prerequisites.
  Preconditions: The pass is registered (DDS-001:PC-1).
  Failure mode: If the pass is not registered, the invocation is rejected
                (FM-5).
```

---

## Lifecycle

### Creation

The Pass Runtime is created during application startup, after the DIR Runtime (DDS-002) is operational and after the Producer Runtime (DDS-001) is created. The Pass Runtime requires DIR read access (PC-5) for input assembly and pass contract access (PC-7) for invocation.

**Preconditions for creation:** The DIR Runtime is created and at least Loading. The Producer Runtime is created.

**No persistent state:** The Pass Runtime has no persistent state of its own. Prior output records used for changed output detection (R6) are maintained in memory for the current session. On restart, the first invocation of every pass reports "changed" (no prior output to compare against).

### Operation

The Pass Runtime becomes operational when both the DIR Runtime is Operational (DDS-002) and the Producer Runtime is Ready (DDS-001). It accepts pass invocations (PC-1) from the Producer Runtime during execution cycles.

**Operational invariant:** Every in-progress invocation has an isolated execution context. No two invocations share mutable state.

### Quiescence

When the application is shutting down, the Pass Runtime enters quiescence:

1. No new pass invocations are accepted.
2. In-progress invocations are allowed to complete or are cancelled (PC-4) after timeout.
3. Output batches from completed invocations are submitted to the DIR (PC-6).
4. Output batches from cancelled invocations are discarded.
5. Prior output records are released.

### Destruction

The Pass Runtime is destroyed after the Producer Runtime (DDS-001) and before the DIR Runtime (DDS-002). The Producer Runtime stops issuing invocations before the Pass Runtime is destroyed; the DIR Runtime remains available for any final output submissions.

---

## State Model

The Pass Runtime occupies one of four states:

```
Uninitialized → Ready → Quiescing → Terminated
```

**Uninitialized.** The Pass Runtime has been created but one or both dependencies (DIR Runtime, Producer Runtime) are not yet operational. Pass invocations are rejected.

**Ready.** Both dependencies are operational. The Pass Runtime accepts pass invocations. Individual invocations may be in progress concurrently (within the concurrency bounds defined by the execution model).

**Quiescing.** The application is shutting down. No new invocations are accepted. In-progress invocations drain.

**Terminated.** The Pass Runtime has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Uninitialized | Ready | DIR Runtime Operational AND Producer Runtime Ready | Invocations accepted |
| Ready | Quiescing | Shutdown signal | No new invocations; in-progress drain |
| Quiescing | Terminated | All in-progress invocations resolved | Resources deallocated |

**Invalid transitions:** Uninitialized → Quiescing (must be Ready first). Terminated → any state. Quiescing → Ready (shutdown is irreversible).

### Invocation Lifecycle

Each pass invocation has its own lifecycle within the Pass Runtime:

```
Assembling → Executing → Collecting → Completed
                                    → Failed
           → Cancelled (from Assembling or Executing)
```

**Assembling.** The Pass Runtime is resolving the scope window and assembling the input set from the DIR.

**Executing.** The pass implementation is running with its execution context.

**Collecting.** The pass has returned its raw output. The output pipeline is constructing provenance, verifying grounding, and comparing against prior output.

**Completed.** The invocation has produced a validated output batch and a change report. The output is ready for submission to the DIR.

**Failed.** The invocation has failed. No output is produced. A failure diagnostic is available.

**Cancelled.** The invocation was cancelled before completion. No output is produced.

---

## Execution Model

### Input Assembly

When a pass invocation begins, the Pass Runtime assembles the input set:

1. **Resolve scope window.** Given the pass's declared scope (per-entity, per-file, per-module, per-system) and the scope specification from the execution ticket, determine the entity set. For a per-file pass with scope "file F," the scope window is all entities whose primary location is file F. For a per-module pass with scope "module M," the scope window is all entities contained in M (transitively through the containment tree per DAS-004).

2. **Query the DIR.** Read all units from the DIR (via PC-5) that match the pass's declared input contract — the specified predicates, entity types, relationship types — and whose subjects are within the scope window. Apply the tier filter: only units at tiers declared in the pass's input contract are included (DAS-006 PC-IN-1). During synchronous pipeline execution, reads observe committed epoch plus prior producers' committed output within the current execution cycle (DDS-002:PC-3(b)).

3. **Construct the input set.** The input set is a read-only collection of DIR units. The pass cannot modify input units. The input set is complete: every unit in the DIR matching the contract and scope is included (DAS-006 CPC-1).

**Empty input set.** If no units match the input contract within the scope window, the input set is empty. This is a valid state — it occurs during initial build (upstream passes have not yet produced content), after entity removal (the entities in the scope were deleted), or when the scope window contains no entities matching the pass's entity type filter. An empty input set produces an empty output batch (the pass has nothing to process).

### Scope Resolution

Scope resolution maps a pass's declared scope granularity to a concrete entity set:

**Per-entity scope.** The scope window contains exactly one entity. The pass processes one entity at a time. Re-execution granularity is per-entity: when entity E's inputs change, only the invocation for E re-runs.

**Per-file scope.** The scope window contains all entities whose primary location is the specified file. Re-execution granularity is per-file: when any entity in file F changes, the invocation for F re-runs.

**Per-module scope.** The scope window contains all entities within the specified module, including entities in files that belong to the module. Re-execution granularity is per-module.

**Per-system scope.** The scope window contains all entities in the system. Re-execution granularity is system-wide. This scope is used by system-level composition passes.

**Scope must match declared scope.** The execution ticket must specify a scope consistent with the pass's declared scope granularity (DAS-006 PC-SCOPE-2). A per-file pass cannot be invoked with a per-entity scope or a per-module scope.

### Execution Context Construction

After input assembly, the Pass Runtime constructs the execution context:

**For all passes:**
- **Input set:** The assembled input units (read-only).
- **Scope window:** The entity set being processed.
- **Pass identity:** The pass's identifier and version.
- **Output contract:** The pass's declared output predicates, tiers, and entity types — constraining what the pass may produce.
- **Cancellation flag:** A flag the pass can poll to detect cancellation requests.

**Additionally for semantic passes:**
- **Budget remaining:** The remaining invocation budget for this pass within the current scheduling window (DAS-006 SP-4). The pass may use this to decide whether to proceed with expensive AI invocations or to skip and let the scheduling subsystem defer.
- **Inference method:** The identifier of the AI service configuration to use (model identifier, prompt template version). This is pass metadata, not a service handle — the pass resolves the service internally.

**Additionally for composition passes:**
- **Existing scope entity:** If a scope-level entity (e.g., a Module entity for a file→module composition pass) already exists in the DIR, its identifier and current units are included. If no scope-level entity exists, this field is absent, signaling that the pass may create one (DAS-006 CP-1).

**Not included in the execution context:**
- Raw source code (DAS-001 P8 — passes read DIR, not source).
- Other passes' execution state (DAS-006 CPC-5 — pass internals are opaque).
- DAG structure or execution order (DAS-006 CPC-4 — execution order is not observable).
- Uncommitted output from concurrently executing passes (DAS-006 PI-4 — no shared mutable state).

### Execution Strategies

Every pass executes under exactly one of two execution strategies — deterministic or semantic — determined by the pass's output tier. Composition is not a third strategy; it is an orthogonal capability that applies additional constraints on top of the underlying execution strategy. A composition pass that produces T0 or T1 output executes under the deterministic strategy with composition constraints. A composition pass that produces T2 output executes under the semantic strategy with composition constraints.

#### Deterministic Execution Strategy

Deterministic passes produce T0 or T1 output using algorithmic analysis (DAS-006 DP-1). This strategy governs all passes with deterministic output, including deterministic composition passes. The execution strategy enforces:

**DE-1: No external service invocation.** The Pass Runtime verifies that the pass's declared determinism is `Deterministic`. During execution, the pass does not have access to AI service configuration or budget information. If a deterministic pass attempts to invoke an external service, this is a defect in the pass implementation detected by implementation-level validation, not by the Pass Runtime at the contract level. The contract-level enforcement is at registration (DDS-001:PC-1): a pass declaring `Deterministic` with an output tier of T2 is rejected.

**DE-2: Bounded execution time.** Deterministic passes have a timeout bound (DDS-001 Performance Requirements PR-2: 50ms per file per pass). The Pass Runtime enforces this bound. Deterministic passes that exceed the bound are terminated (FM-1). This bound applies equally to deterministic composition passes.

**DE-3: Idempotency expectation.** Deterministic passes are idempotent (DAS-006 PC-IDEM-1). When a deterministic pass is re-invoked with the same input set, the output must be identical. The Pass Runtime does not enforce idempotency at execution time (it cannot predict the output before the pass runs), but it verifies idempotency when changed output detection (R6) reports "changed" for a re-invocation with provably unchanged input. An idempotency violation is a pass defect, recorded as a diagnostic (FM-6). This expectation applies equally to deterministic composition passes.

#### Semantic Execution Strategy

Semantic passes produce T2 output using interpretive inference (DAS-006 SP-1 through SP-5). This strategy governs all passes with semantic output, including semantic composition passes. The execution strategy accounts for:

**SE-1: AI service dependency.** Semantic passes typically invoke external AI services. The execution context provides budget information (SP-4). The Pass Runtime does not manage the AI service connection — the pass implementation does. But the Pass Runtime enforces the timeout bound and handles AI unavailability as a specific failure mode (FM-3).

**SE-2: No latency bound.** Semantic passes are not on the synchronous pipeline critical path (DAS-003 T2 freshness is eventual). The Pass Runtime applies a configurable timeout (longer than deterministic pass timeouts) but does not enforce the tight latency bounds of deterministic passes.

**SE-3: Non-idempotency tolerance.** Semantic passes are presumed non-idempotent (DAS-006 PC-IDEM-2). Re-execution on identical input may produce different output. Changed output detection (R6) treats semantic pass output changes conservatively: a change report of "changed" triggers downstream cascade even if the change is superficial (e.g., different wording for the same semantic content). Structural identity is the comparison criterion — not semantic equivalence.

**SE-4: Graceful degradation.** When a semantic pass fails (AI unavailability, timeout, error), the pass produces no output. The pass's prior output remains in the DIR as stale-but-available content (DAS-001 P12, DAS-006 SP-3). The pipeline continues — no deterministic pass is affected (DAS-006 PI-2), and no downstream semantic pass is blocked (it will receive the prior T2 output or no T2 output, both valid states).

#### Composition Constraints (Orthogonal to Execution Strategy)

Composition passes read intelligence at a smaller scope and produce intelligence at a larger scope, generating emergent properties (DAS-001 P4, DAS-006 CP-1 through CP-4). Composition is not a separate execution strategy. Every composition pass inherits all rules from its underlying execution strategy (deterministic or semantic) based on its output tier. The following constraints are additional requirements specific to composition behavior:

**CE-1: Scope-level entity creation.** When the execution context indicates no existing scope-level entity (e.g., no Module entity exists for the target module), the composition pass may include entity creation declarations in its output. Entity creation declarations specify the entity's type, its position in the containment tree, and the containment relationships that integrate it (DAS-006 CP-3, DAS-004 I2). The actual entity identity is assigned by the DIR Runtime (DDS-002:R5) when the output batch is admitted.

**CE-2: Scope-level entity enrichment.** When the execution context includes an existing scope-level entity, the composition pass produces new units about that entity — emergent properties such as interaction patterns, coupling characteristics, and architectural roles (DAS-006 CP-2).

**CE-3: Emergence validation.** After a composition pass completes, the output pipeline verifies that the output contains at least one emergent property — a unit whose predicate does not appear on any constituent entity within the scope (DAS-006 CP-4). If the output contains only aggregation (counts, lists, unions of constituent properties) and no emergence, the output pipeline records a diagnostic warning. This is not a hard failure — the output is still committed — but it indicates a composition pass that may not be producing architectural value.

**CE-4: Containment tree integrity.** When a composition pass creates a scope-level entity, the output pipeline verifies that the declared containment relationships are valid: the new entity is contained by exactly one parent, and the entities it contains exist within the scope window. Invalid containment declarations cause the output batch to be rejected (FM-4).

### Output Pipeline

After the pass completes, the Pass Runtime processes the raw output:

1. **Output collection.** The pass returns a set of raw output records — units with subject, predicate, value, tier, confidence, and grounding references. Raw output does not include provenance (the Pass Runtime stamps it) or unit identifiers (the DIR Runtime assigns them).

2. **Provenance stamping.** The Pass Runtime constructs the provenance record for each output unit:
   - **Producer identity:** The pass's identifier and version (DAS-002 I-PROV-2).
   - **Method:** `derivation` for deterministic passes, `inference` for semantic passes (with additional fields: model identifier, prompt template version per DAS-006 SP-5).
   - **Timestamp:** The current time.
   - **Inputs:** References to the input set units that the pass consumed. For passes that declare specific input-to-output mappings, the references are precise. For passes that consume the full input set, the references include all input units.

3. **Grounding chain verification.** For each output unit, the Pass Runtime verifies that its grounding chain references are valid: they must point to units in the input set or to units earlier in the same output batch (DAS-002 I-GND-1, I-GND-2). Invalid grounding references cause the output unit to be flagged for rejection.

4. **Tier assignment verification.** The Pass Runtime verifies that each output unit's tier is within the pass's declared tier range and is consistent with the pass category: deterministic pass output must be T0 or T1, semantic pass output must be T2 (with exceptions per DAS-006 PC-DET-1). Tier violations cause the output unit to be flagged for rejection.

5. **Output batch construction.** Valid output units are assembled into an output batch suitable for submission to the DIR (DDS-002:PC-6). If any unit was flagged for rejection, the entire output batch is rejected (consistent with DDS-001:FM-3 whole-batch discard policy).

### Changed Output Detection

After the output pipeline constructs a valid output batch, the Pass Runtime compares it against the prior output for the same pass and scope window:

**Comparison model.** The Pass Runtime compares new and prior output using the canonical unit equality semantics defined by the DIR Runtime (DDS-002). The Pass Runtime consumes those semantics — it does not define its own equality rules. Two units are considered identical when they match under DIR equality for subject, predicate, tier, and value. For each unit in the new output, the Pass Runtime checks whether an identical unit exists in the prior output. For each unit in the prior output, it checks whether a match exists in the new output. The result is:

- **No change:** Complete bidirectional match under DIR equality. Every new unit has a prior counterpart and vice versa. The scheduling subsystem may terminate the cascade for this branch (DAS-006 PE-5).
- **Changed:** At least one unit was added, removed, or modified (different value, different tier, or different confidence under DIR equality). The scheduling subsystem must propagate the change to downstream passes (DAS-010 IP-6).

**Prior output storage.** The Pass Runtime maintains a per-pass, per-scope-window record of the most recent output batch for comparison. This record is stored in memory for the current session. It is not persisted — after restart, the first invocation reports "changed."

**Confidence changes.** A change in confidence alone (same subject, predicate, tier, value, but different confidence) is reported as "changed." Confidence affects consumer decisions and must be propagated.

### Cancellation

Cancellation is cooperative. When the Producer Runtime or scheduling subsystem requests cancellation of an in-progress invocation:

1. The Pass Runtime sets the cancellation flag in the execution context.
2. The pass polls the cancellation flag during execution. Well-behaved passes check the flag at natural checkpoints (between entities, between AI calls, between processing stages).
3. When the pass observes the cancellation flag, it stops processing and returns control to the Pass Runtime with no output.
4. If the pass does not check the flag within the timeout bound, the invocation is forcibly terminated.
5. No output is committed. The pass's prior output is retained.

**Cancellation is not failure.** A cancelled invocation is not recorded as a failure (it does not appear in FM-1 through FM-5). It is recorded as a cancellation event in observability.

### Retry Eligibility

After a pass invocation fails, the Pass Runtime determines whether the invocation is eligible for retry:

**RE-1: Deterministic passes are always retry-eligible.** They are idempotent (DAS-006 PC-IDEM-1) and AI-independent. Transient failures (resource contention, timeout due to system load) resolve on retry.

**RE-2: Semantic passes are retry-eligible for transient failures.** AI service unavailability (network timeout, rate limit, service outage) is transient — the pass may succeed on retry when the service recovers. Non-transient failures (pass logic error, structurally invalid input) are not retry-eligible.

**RE-3: Composition passes follow their underlying execution strategy.** A composition pass with deterministic output (T0 or T1) follows RE-1. A composition pass with semantic output (T2) follows RE-2. Composition is not a separate retry category.

**RE-4: Retry eligibility is advisory.** The Pass Runtime reports retry eligibility as part of the failure diagnostic. The retry decision (whether to retry, when, how many times) is made by the scheduling subsystem, not by the Pass Runtime.

---

## Memory and Ownership

### Owned Resources

**Execution contexts.** The Pass Runtime exclusively owns in-progress execution contexts. Each context is created for a single invocation and destroyed when the invocation completes, fails, or is cancelled. No other subsystem holds references to execution contexts.

**Prior output records.** The Pass Runtime owns the per-pass, per-scope-window records of the most recent output batch, used for changed output detection (R6). These records are in-memory, session-scoped, and released on shutdown.

**Invocation state.** The Pass Runtime owns the lifecycle state of each in-progress invocation (Assembling, Executing, Collecting, Completed, Failed, Cancelled).

### Borrowed Resources

**DIR content (read).** The Pass Runtime borrows DIR content via PC-5 for the duration of input assembly. The borrowed content is immutable (DDS-002 immutability model) and remains valid for the duration of the invocation.

**Pass contracts (read).** The Pass Runtime borrows pass contract metadata via PC-7 for the duration of invocation setup. Contracts are immutable for the duration of an execution cycle (DDS-001 state model: registrations are deferred during execution).

### Shared Resources

None. The Pass Runtime does not share mutable state with any other subsystem. All interactions are through contracts.

### Memory Bounds

**Execution contexts:** Proportional to the number of concurrent invocations. Each execution context contains the input set (copied from DIR reads — typically 50-500 units, a few kilobytes per invocation) and pass metadata. At expected concurrency (1-5 concurrent invocations at alpha), memory consumption is negligible.

**Prior output records:** Proportional to the number of registered passes multiplied by the number of scope windows per pass. For a per-file pass with 100 tracked files, 100 prior output records. Each record stores the output batch summary (subject-predicate-tier-value tuples, not full units) — estimated 10-50 KB per pass at alpha scale.

**Output batches:** Transient — exist only between pass completion and DIR commit or discard. Proportional to the number of units the pass produces per invocation (typically 50-300 units).

### Eviction

Execution contexts are released immediately on invocation completion, failure, or cancellation. Output batches are released after DIR commit or discard. Prior output records are released on session end. No explicit eviction policy is needed — all resources are transient or session-scoped.

---

## Failure Handling

```
FM-1: Pass Execution Error
  Trigger:     A pass throws an error during execution (logic error,
               resource exhaustion, assertion failure, unhandled exception).
  Detection:   The Pass Runtime catches the error at the invocation
               boundary. The pass runs within a controlled execution
               environment that prevents errors from propagating to the
               Pass Runtime's own state.
  Response:    The invocation transitions to Failed state. No output is
               produced. The execution context is destroyed. The pass's
               prior output in the DIR is retained as stale-but-available
               content (DAS-001 P12).
  Caller observes: The Producer Runtime (DDS-001) receives a failure
               diagnostic with: pass identity, scope window, failure
               category "execution_error," error detail, and retry
               eligibility (RE-1 or RE-2 depending on pass category).
  Recovery:    The scheduling subsystem determines whether to retry
               (eligible for deterministic passes per RE-1) or defer.

FM-2: Pass Timeout
  Trigger:     A pass does not complete within its timeout bound.
               Deterministic passes: bound from PR-1. Semantic passes:
               configurable bound (PR-2).
  Detection:   The Pass Runtime monitors execution duration.
  Response:    The invocation is forcibly terminated. No output is
               produced. Identical to FM-1 otherwise.
  Caller observes: Failure diagnostic with category "timeout."
  Recovery:    Same as FM-1.

FM-3: Semantic Pass AI Unavailability
  Trigger:     A semantic pass cannot reach its AI service (network
               failure, rate limit, service outage, budget exhausted).
  Detection:   The semantic pass reports the AI service error to the
               Pass Runtime. The Pass Runtime treats this as a specific
               subcategory of FM-1.
  Response:    The invocation transitions to Failed state. No output is
               produced. The prior T2 output remains available as stale
               content. No deterministic pass is affected (DAS-006 PI-2,
               DAS-001 I7).
  Caller observes: Failure diagnostic with category
               "ai_service_unavailable," retry eligibility = true
               (transient — RE-2).
  Recovery:    The scheduling subsystem may schedule the pass for
               deferred re-execution when AI services become available
               (DAS-010 RS-6, RS-7).

FM-4: Output Pipeline Rejection
  Trigger:     The output pipeline detects invalid output: grounding
               chain references invalid units, tier assignment outside
               declared range, or — for composition passes — invalid
               containment declarations.
  Detection:   Verification steps in the output pipeline (R5).
  Response:    The entire output batch is rejected (consistent with
               DDS-001 whole-batch discard policy). No output is produced.
               The invocation transitions to Failed state.
  Caller observes: Failure diagnostic with category "invalid_output,"
               specific validation violations, retry eligibility = false
               (non-transient — the pass produced structurally invalid
               output, indicating a defect).
  Recovery:    Invalid output indicates a defective pass. The pass
               remains registered but its output is not committed until
               the defect is corrected via producer upgrade (DAS-010 PU-1).

FM-5: Invocation Precondition Failure
  Trigger:     The pass is not registered, the scope window is empty,
               or the DIR is not available for reads.
  Detection:   Precondition check at invocation start.
  Response:    The invocation is rejected immediately. No execution
               occurs.
  Caller observes: Failure diagnostic with category
               "precondition_failure" and specific precondition violated.
  Recovery:    The caller must satisfy the precondition before
               re-attempting.

FM-6: Idempotency Violation (Diagnostic Only)
  Trigger:     A deterministic pass, re-invoked with provably unchanged
               input, produces different output.
  Detection:   Changed output detection (R6) reports "changed" for a
               deterministic pass re-invocation where the input set is
               identical to the prior invocation's input set (verified
               by content comparison).
  Response:    The output is still committed (the new output is
               structurally valid). A diagnostic warning is recorded
               identifying the pass and the specific units that differ.
               This is a pass defect — the pass declared Deterministic
               but is not reproducible (DAS-006 PC-IDEM-1).
  Caller observes: The output batch is returned normally, with an
               additional idempotency violation diagnostic. The
               scheduling subsystem may flag the pass for investigation.
  Recovery:    The pass implementation must be corrected to produce
               consistent output for identical input.
```

---

## Performance Requirements

Performance requirements are classified as follows:

- **Architectural requirement** — a bound mandated by DAS invariants or freshness contracts. Violation breaks an architectural guarantee.
- **Engineering target** — an initial numeric bound based on expected workload and reasoning, not yet validated by measurement. Must be validated through benchmarking before promotion to firm requirements.
- **Benchmark-derived** — a bound established through measured performance.

```
PR-1: Deterministic Pass Invocation Latency
  Operation:   Complete pass invocation for a deterministic pass (input
               assembly + execution + output pipeline + changed output
               detection)
  Category:    Architectural requirement (synchronous pipeline bound);
               engineering target (numeric bound)
  Bound:       Upper bound 60ms per invocation (initial target)
  Assumptions: Per-file scope. File with ≤ 200 entities. Input set ≤ 500
               units. Output batch ≤ 300 units. Prior output available
               for comparison.
  Rationale:   Deterministic passes are on the synchronous pipeline
               critical path (DAS-010 RS-2, RS-3). This bound includes
               DDS-001:PR-2 (50ms pass execution) plus 10ms for input
               assembly, output pipeline, and changed output detection.
               The cumulative budget for ~5 deterministic passes is ~300ms.
               Validate by benchmarking end-to-end invocation latency.

PR-2: Semantic Pass Invocation Overhead
  Operation:   Pass Runtime overhead for a semantic pass invocation
               (input assembly + output pipeline + changed output
               detection, excluding pass execution time)
  Category:    Engineering target
  Bound:       Upper bound 20ms (initial target)
  Assumptions: Input set ≤ 500 units. Output batch ≤ 100 units. Prior
               output available.
  Rationale:   Semantic pass execution time is dominated by AI service
               latency (1-10 seconds). The Pass Runtime's overhead must
               be negligible relative to execution time. No synchronous
               pipeline constraint (T2 freshness is eventual). Validate
               by benchmarking the non-execution overhead.

PR-3: Input Assembly Latency
  Operation:   Scope resolution + DIR query + input set construction
  Category:    Engineering target
  Bound:       Upper bound 5ms per invocation (initial target)
  Assumptions: Per-file scope. ≤ 200 entities in scope. ≤ 500 units
               matching input contract. DIR read via DDS-002:PC-3 is
               O(n) in scope window size.
  Rationale:   Input assembly is on the critical path of every
               invocation. At 5ms per invocation and ~10 invocations
               per execution cycle, total input assembly is ~50ms.
               Validate by benchmarking against representative scope
               window sizes.

PR-4: Changed Output Detection Latency
  Operation:   Comparison of new output batch against prior output
  Category:    Engineering target
  Bound:       Upper bound 2ms per invocation (initial target)
  Assumptions: Output batch ≤ 300 units. Prior output ≤ 300 units.
               Comparison by supersession key + value equality.
  Rationale:   Changed output detection is on the critical path between
               pass completion and cascade decision. At 2ms per
               invocation, the overhead is negligible relative to
               execution time. Validate by benchmarking comparison
               at the upper bound of expected output batch size.

PR-5: Prior Output Record Memory
  Operation:   Memory consumption for prior output records
  Category:    Engineering target
  Bound:       Upper bound 10 MB total (initial target)
  Assumptions: ≤ 50 registered passes. ≤ 200 scope windows per pass
               (200 tracked files). ≤ 300 units per output summary.
               ~100 bytes per summary entry.
  Rationale:   Prior output records are session-scoped and in-memory.
               50 × 200 × 300 × 100 = 300 MB would be excessive.
               Output summaries store only the comparison keys (subject,
               predicate, tier, value hash), not full unit records.
               At ~20 bytes per summary entry: 50 × 200 × 300 × 20 =
               ~60 MB — above the target. At alpha scale (~10 passes,
               ~50 files): 10 × 50 × 300 × 20 = 3 MB. The 10 MB target
               is appropriate for alpha. Revisit at scale.
```

---

## Observability

The Pass Runtime emits the following observable information:

**Invocation Metrics (DAS-006 PO-1).** For each pass invocation: pass identity, pass version, pass category (deterministic/semantic/composition), scope window identifier, input set size (number of units), output batch size (number of units), invocation duration (total), input assembly duration, execution duration, output pipeline duration, comparison duration, change report (changed/no change), and success/failure status. Emitted after each invocation completes, fails, or is cancelled.

**Cost Accounting (DAS-006 PO-4).** For semantic pass invocations: AI service invocation count within the invocation, token consumption (prompt tokens, completion tokens), and the inference method used. Emitted as part of the invocation metrics.

**Cancellation Events.** For each cancelled invocation: pass identity, scope window, time of cancellation request, time of cancellation acknowledgment (or forced termination), and reason for cancellation.

**Idempotency Violation Diagnostics.** For each idempotency violation (FM-6): pass identity, scope window, the specific units that differ between the expected (prior) and actual (new) output.

**Input Assembly Diagnostics.** When input assembly produces an empty input set, a diagnostic event is emitted with: pass identity, scope window, input contract summary, and reason for empty result (no matching units, empty scope, upstream pass not yet executed).

**Overhead.** Observability data collection does not block pass execution. Metrics are collected as side effects of the invocation lifecycle (timestamps at phase boundaries), not as separate processing steps.

---

## Testing Requirements

**Input assembly tests (R1, R2):**
- A pass with a declared input contract for predicate P at tier T0 receives only T0 units with predicate P from the DIR.
- A pass with per-file scope receives only units about entities in the specified file.
- A pass with per-module scope receives units about all entities in the module.
- Input assembly during synchronous pipeline execution includes units committed by prior producers in the current cycle (DDS-002:PC-3(b) visibility).
- An empty scope window produces an empty input set.
- Units at tiers outside the pass's input contract are excluded.

**Execution context tests (R3):**
- A deterministic pass's execution context does not include budget information.
- A semantic pass's execution context includes budget information.
- A composition pass's execution context includes the existing scope entity (if present) or indicates its absence.
- The execution context does not include raw source code, other passes' state, or DAG structure.
- The cancellation flag is initially unset.

**Category-specific execution tests (R4):**
- A deterministic pass that completes within the timeout produces valid output.
- A deterministic pass that exceeds the timeout is terminated with FM-2.
- A semantic pass that reports AI unavailability fails with FM-3 and prior T2 output is retained.
- A semantic pass failure does not affect concurrent or subsequent deterministic pass invocations.
- A composition pass that creates a new scope-level entity includes containment declarations in its output.
- A composition pass with an existing scope entity produces enrichment units about that entity.

**Output pipeline tests (R5):**
- Output units receive provenance records with the pass's identity and version.
- Deterministic pass output provenance has method = derivation.
- Semantic pass output provenance has method = inference with model metadata.
- Output units with invalid grounding references cause batch rejection (FM-4).
- Output units with tier outside the pass's declared range cause batch rejection (FM-4).
- Composition pass output with invalid containment declarations causes batch rejection (FM-4).

**Changed output detection tests (R6):**
- A deterministic pass that produces identical output on re-invocation reports "no change."
- A pass that produces different output (added unit, removed unit, changed value) reports "changed."
- First invocation of a pass (no prior output) reports "changed."
- A change in confidence alone (same subject, predicate, tier, value) reports "changed."

**Cancellation tests (R7):**
- A cancelled invocation produces no output.
- Cancellation during input assembly stops the invocation before execution begins.
- Cancellation during execution sets the cancellation flag; a cooperative pass observes it and stops.
- A non-cooperative pass is forcibly terminated after timeout.
- Cancellation does not appear as a failure in failure diagnostics.

**Retry eligibility tests (R8):**
- A failed deterministic pass invocation is retry-eligible.
- A semantic pass invocation that fails with AI unavailability is retry-eligible.
- A pass invocation that fails with invalid output (FM-4) is not retry-eligible.
- A pass invocation that fails with precondition failure (FM-5) is not retry-eligible.

**Idempotency tests:**
- A deterministic pass re-invoked with identical input produces identical output (no idempotency violation).
- A deterministic pass re-invoked with identical input that produces different output triggers FM-6 diagnostic.
- The FM-6 diagnostic identifies the specific units that differ.

**Integration tests:**
- A multi-pass invocation sequence where pass B's input includes pass A's output: B's input set contains A's committed output (within-cycle visibility).
- A deterministic pass invocation that reports "no change" does not trigger downstream invocations (verified through the scheduling subsystem).
- A semantic pass invocation failure during a synchronous pipeline does not prevent deterministic passes from completing.
- A composition pass creates a scope-level entity; subsequent passes can reference it.

---

## Future Evolution

**Module Intelligence (DAS Roadmap Phase 2).** As Module Intelligence matures, per-module composition passes will be registered. The Pass Runtime's scope resolution already supports per-module scope. The primary evolution will be in the complexity of composition pass entity creation — more entity types, deeper containment trees, and richer emergent properties. The execution context construction (R3) may need to provide richer containment tree information to composition passes.

**Project Intelligence (DAS Roadmap Phase 3).** System-level composition passes (per-system scope) will produce scope windows containing all entities. Input assembly at this scale may require performance optimization (batched DIR reads, incremental input set construction). The Pass Runtime's architecture is scope-agnostic — it executes passes at whatever scope the contract declares — but the performance characteristics will change at system scope.

**Parallel Pass Execution.** The current design supports concurrent invocations for independent passes within a topological level (DAS-006 PE-2), but the execution model does not mandate parallelism. As the pass DAG grows, parallel invocation of independent passes will reduce synchronous pipeline latency. The Pass Runtime's isolation model (no shared mutable state, independent execution contexts) is designed to support this without architectural changes.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial draft
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions: composition
      as orthogonal capability (not separate strategy), changed output
      detection ownership clarified (single owner in DDS-003), value
      comparison deferred to DIR Runtime equality semantics (DDS-002)
```
