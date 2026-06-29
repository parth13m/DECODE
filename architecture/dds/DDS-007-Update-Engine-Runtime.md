# DDS-007: Update Engine Runtime

```
Document:      DDS-007
Title:         Update Engine Runtime
Status:        Draft
Version:       0.2
Author:        Principal Engineer
Reviewers:     —
Created:       2026-06-28
Last Revised:  2026-06-28
Depends On:    DDS-000 (Design Authoring Standard), DDS-001 (Producer Runtime),
               DDS-002 (DIR Runtime Model), DDS-003 (Pass Runtime),
               DDS-004 (Index Runtime)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-006, DAS-007, DAS-010
```

## Abstract

This document specifies the engineering design of the Update Engine Runtime — the subsystem that detects source changes, propagates invalidation through grounding chains, schedules recomputation across tiers, coordinates epoch advancement, and delivers change batches to the Index Runtime. It realizes the incremental update model defined in DAS-010, the freshness contracts of DAS-003, the pass invalidation and scheduling contracts of DAS-006, and the index maintenance coordination of DAS-007. The Update Engine is the orchestrator that connects file system events to a consistent, epoch-advanced DIR.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P3 (deterministic before semantic — T0/T1 synchronous pipeline
            before T2 deferred pipeline), P9 (incremental by design — cost
            proportional to change, not codebase), P12 (graceful degradation
            — stale T2 served rather than absent)
  Not addressed: P1, P5, P6, P7 (DDS-002, DDS-005, DDS-006),
                 P2 (DDS-001), P4, P8 (DDS-001, DDS-003),
                 P10, P11 (DDS-001, DDS-005, DDS-006)

DAS-002: Decode Intermediate Representation
  Realized: I-GND-3 (invalidation of grounded units — cascade propagation),
            I-LC-2 (Active → Invalidated transition — triggered by Update
            Engine), I-VER-3 (content-addressed versioning — exploited for
            change detection)
  Not addressed: I-ID-1 through I-ID-3 (DDS-002), I-LC-1, I-LC-3, I-LC-4,
                 I-LC-5 (DDS-002), I-SUB, I-PRED, I-VAL, I-TIER, I-PROV,
                 I-CONF, I-GND-1, I-GND-2 (DDS-002), I-VER-1, I-VER-2
                 (DDS-002), DC-1 through DC-5 (DDS-002, DDS for Storage Engine)

DAS-003: Tier Model
  Realized: Freshness contracts (T0 source-synchronous, T1 propagation delay,
            T2 eventual — enforced by synchronous and deferred pipelines),
            I5 (freshness ordering — no higher-tier claim fresher than
            lower-tier it derives from), CTD-1, CTD-2, CTD-3 (cross-tier
            dependencies — cascade propagation direction), TL-1 (recomputation
            priority — tier-ordered scheduling)
  Not addressed: TA-1 through TA-5 (DDS-001, DDS-003), I1 (DDS-002),
                 I2 (DDS-002), TL-2 (DDS-002), TL-3 (DDS for Storage Engine),
                 I3 (DDS-001), I4 (DDS-001), I6 (DDS-002), I7 (DDS-005, DDS-006)

DAS-006: Pass Architecture
  Realized: PINV-1 through PINV-5 (pass invalidation triggers — the Update
            Engine determines when passes re-execute based on invalidation),
            PS-1 through PS-4 (scheduling priorities — tier priority,
            change proximity, consumer demand, budget constraints),
            PE-5 (early termination — cascade stops when output unchanged)
  Not addressed: PE-1 through PE-4, PE-6 (DDS-001, DDS-003),
                 PD-1 through PD-6 (DDS-001), PI-1 through PI-5 (DDS-001),
                 DP-1, DP-2 (DDS-003), SP-1 through SP-5 (DDS-003),
                 CP-1 through CP-4 (DDS-001), CPC-1 through CPC-5 (DDS-001),
                 PO-1 through PO-4 (DDS-001)

DAS-007: Index Architecture
  Realized: IM-1 through IM-4 (index maintenance coordination — change
            batch delivery within the synchronous pipeline), IM-5, IM-6
            (index rebuild coordination)
  Not addressed: Five index family definitions (DDS-004), I1 through I8
                 (DDS-004), IL-1, IL-2 (DDS-004), IIM-1 through IIM-4
                 (DDS-004), IOB-1 through IOB-4 (DDS-004)

DAS-010: Incremental Update Model
  Realized: CD-1 through CD-6 (change detection — content-hash comparison,
            change event aggregation, entity-level comparison),
            IP-1 through IP-6 (invalidation propagation — direct invalidation,
            entity removal, cascade traversal, tier-ordered cascade, early
            termination), CB-1 through CB-4 (cascade boundaries — T0-T1
            synchronous, T1-T2 deferred, T2-T2 deferred, cross-entity limit),
            RS-1 through RS-10 (recomputation scheduling — synchronous
            pipeline, deferred pipeline, consumer-demand recomputation,
            background recomputation, first-question trigger, enrichment
            freshness), WR-1 through WR-5 (write-read consistency — epoch
            advancement coordination, snapshot queries, concurrent change
            sets, query during processing), PU-1 through PU-5 (producer
            upgrade invalidation),
            I1 (epoch consistency), I2 (cascade directionality),
            I3 (early termination correctness), I4 (change set atomicity),
            I5 (grounding chain completeness), I6 (content-hash idempotency),
            I7 (index-DIR consistency — via change batch delivery),
            I8 (sequential change set processing)
  Not addressed: WR-6, WR-7 (DDS-002 — invalidated unit visibility and
                 metadata), GC-1 through GC-4 (DDS for Storage Engine)

DAS-012: Storage Realization
  Referenced: Grounding Dependency Map (storage-internal structure used by
              this subsystem for cascade traversal), epoch counter
              realization, reconciliation process. DAS-012 defines the
              physical realization; this DDS defines the logical coordination
              that the storage layer supports.
  Not addressed: Snapshot persistence (DDS for Storage Engine), unit store
                 structure (DDS-002), GC retention policy (DDS for Storage
                 Engine), index persistence decisions (DDS-004)
```

## Terminology

**Change Event** — A notification that a source artifact has been modified, created, or deleted. The Update Engine's input. `See DAS-010`

**Change Set** — One or more change events grouped into an atomic processing unit. The Update Engine processes change sets, not individual change events. `See DAS-010`

**Invalidation** — The process of marking a unit as potentially stale. Transitions a unit from Active to Invalidated status via DDS-002:PC-2. `See DAS-010`

**Invalidation Cascade** — The process by which invalidation propagates from directly invalidated units to transitively dependent units through grounding chains. `See DAS-010`

**Cascade Boundary** — A point where synchronous propagation stops and deferred propagation begins. The T1-T2 boundary is the primary cascade boundary. `See DAS-010`

**Update Epoch** — A monotonically increasing counter identifying a consistent DIR state. Owned by the DIR Runtime (DDS-002:R6); advanced at the Update Engine's request. `See DAS-010`

**Recomputation** — The process of producing new, current units to replace invalidated ones by re-executing the appropriate producer. `See DAS-010`

**Synchronous Pipeline** — The processing stage that handles T0 and T1 recomputation within the change set processing window, before epoch advancement. `INTRODUCED`

**Deferred Pipeline** — The processing stage that handles T2 recomputation outside the change set processing window, driven by consumer demand or background scheduling. `INTRODUCED`

**Deferred Epoch** — An epoch advancement triggered by successful deferred T2 recomputation, rather than by synchronous pipeline completion. A deferred epoch follows the same visibility guarantees as a synchronous epoch — after advancement, all committed writes (including the fresh T2 output) are visible to consumer queries. The only difference from a synchronous epoch is the trigger source. `INTRODUCED`

**Execution Ticket** — A unit of work specifying which producer to execute over which scope. Issued by the Update Engine to the Producer Runtime via DDS-001:PC-9. `See DDS-001`

**Structural Change Record** — The result of entity-level comparison between old and new parse results for a modified file. Classifies each entity as added, removed, or modified (with the set of changed predicates) and each relationship as added, removed, or modified. `INTRODUCED`

**Deferred Recomputation Queue** — The set of invalidated T2 unit identifiers awaiting recomputation. Managed in memory by the Update Engine, persisted in the snapshot by the Storage Engine. `INTRODUCED`

**Grounding Dependency Map** — A reverse lookup structure mapping a unit identifier to the set of units whose provenance.inputs references it. Maintained by the storage layer (DAS-012); consumed by the Update Engine for cascade traversal. `See DAS-012`

---

## Responsibilities

```
R1: Detect source changes at file level and determine structural changes
    at entity level.
    DAS: DAS-010 CD-1 (content-hash comparison), CD-2 (change event
         aggregation), CD-3 (change event types), CD-4 (entity identity
         matching), CD-5 (predicate-level change detection), CD-6
         (structural change classification), DAS-001 P9 (incremental)
    Boundary: The Update Engine receives file-level change notifications
              and determines what structurally changed. It does not capture
              file system events — that is an infrastructure responsibility.
              It does not parse source files — it directs the Producer
              Runtime to re-parse via execution tickets and compares the
              resulting units against prior units.

R2: Propagate invalidation through grounding chains from directly changed
    units to transitively dependent units.
    DAS: DAS-010 IP-1 (source-triggered invalidation), IP-2 (entity
         removal invalidation), IP-4 (grounding-chain traversal), IP-5
         (tier-ordered cascade), DAS-002 I-GND-3 (invalidation of
         grounded units), DAS-003 CTD-1 through CTD-3 (cascade direction)
    Boundary: The Update Engine identifies which units to invalidate and
              submits invalidation requests to the DIR Runtime (DDS-002:PC-2).
              It does not perform the status transition — DDS-002 does.
              It does not determine GC eligibility — that is the Storage
              Engine's responsibility.

R3: Enforce cascade boundaries — synchronous cascade for T0 and T1,
    deferred cascade for T2.
    DAS: DAS-010 CB-1 (T0-T1 synchronous), CB-2 (T1-T2 deferred),
         CB-3 (T2-T2 deferred), CB-4 (cross-entity cascade limit),
         DAS-003 freshness contracts (T0 source-synchronous, T1
         propagation delay, T2 eventual)
    Boundary: The Update Engine enforces when cascade propagation
              is synchronous vs deferred. It does not define the freshness
              contracts themselves — DAS-003 does.

R4: Schedule and coordinate the synchronous pipeline — T0 and T1
    recomputation within the change set processing window.
    DAS: DAS-010 RS-1 (frontend re-execution), RS-2 (T0 pass
         re-execution), RS-3 (T1 pass re-execution), RS-4 (synchronous
         pipeline completion), DAS-006 PS-1 (tier priority),
         DAS-001 P3 (deterministic before semantic)
    Boundary: The Update Engine coordinates execution by issuing tickets
              to the Producer Runtime (DDS-001:PC-9) and receiving results.
              It does not execute producers — DDS-001 does. It does not
              invoke individual passes — DDS-003 does.

R5: Schedule and coordinate the deferred pipeline — T2 recomputation
    via consumer demand and background processing.
    DAS: DAS-010 RS-5 (T2 invalidation recording), RS-6 (consumer-
         demand recomputation), RS-7 (background recomputation), RS-8
         (T2 recomputation order), RS-9 (first-question trigger),
         RS-10 (enrichment freshness), DAS-006 PS-2 (change proximity),
         PS-3 (consumer demand), PS-4 (budget constraints)
    Boundary: The Update Engine manages the deferred recomputation queue
              and issues execution tickets for T2 producers. It does not
              determine whether a consumer query requires T2 content — the
              retrieval/context assembly subsystem signals demand.

R6: Implement early termination — stop cascade propagation when
    recomputed output is unchanged.
    DAS: DAS-010 IP-6 (early termination), DAS-006 PE-5 (unchanged
         output terminates cascade), DAS-010 I3 (early termination
         correctness)
    Boundary: The Update Engine consumes the change report from
              DDS-003:PC-3 (via DDS-001) and decides whether to continue
              or stop the cascade. It does not perform output comparison
              — DDS-003 does.

R7: Coordinate epoch advancement — both synchronous epochs (after
    synchronous pipeline completion) and deferred epochs (after
    successful deferred T2 recomputation). In both cases, ensure
    index updates are delivered before requesting advancement.
    DAS: DAS-010 WR-1, WR-3 (epoch advancement), I1 (epoch consistency),
         I4 (change set atomicity), I7 (index-DIR consistency),
         DAS-007 IM-1 (index updates within synchronous pipeline)
    Boundary: The Update Engine determines when advancement is warranted
              and requests it from the DIR Runtime (DDS-002:PC-4).
              It does not own the epoch counter — DDS-002 does. Both
              synchronous and deferred epochs use the same DDS-002:PC-4
              contract — the DIR Runtime does not distinguish them.

R8: Deliver change batches to the Index Runtime within the synchronous
    pipeline, before epoch advancement.
    DAS: DAS-010 IM-1 through IM-3 (synchronous index updates, affected
         index identification, update ordering), DAS-007 IM-1 through
         IM-4 (index maintenance coordination)
    Boundary: The Update Engine delivers change batches to the Index
              Runtime (DDS-004:PC-4). It does not update index structures
              — DDS-004 does.

R9: Enforce sequential change set processing — no two change sets
    processed concurrently.
    DAS: DAS-010 WR-4 (concurrent change sets queued), I8 (sequential
         processing)
    Boundary: The Update Engine serializes change set processing. It
              does not control the concurrency model of the overall
              application — only change set processing is serialized.

R10: Detect producer upgrades and schedule re-evaluation of affected
     units.
     DAS: DAS-010 PU-1 through PU-5 (producer upgrade invalidation),
          DAS-006 PINV-4 (pass upgrade triggers re-execution)
     Boundary: The Update Engine detects version changes by comparing
               current producer versions (from DDS-001:PC-3) against
               provenance of existing units. It issues execution tickets
               for re-evaluation. It does not detect version changes
               at the code level — DDS-001 provides version metadata.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Change Set Processing
  Direction:    Offered
  Counterparty: File system monitoring infrastructure, application lifecycle
                (for reconciliation on startup)
  Guarantee:    Given a change set (one or more file-level change events,
                each carrying a file path and change type), the Update Engine
                processes the change set to completion:
                1. Content-hash comparison (DAS-010 CD-1): files with
                   unchanged content hashes are filtered out.
                2. Entity-level comparison (DAS-010 CD-4, CD-5): for
                   modified files, the Update Engine directs the Producer
                   Runtime to re-parse the file (via PC-5, execution ticket
                   for the appropriate frontend) and compares the resulting
                   T0 units against the prior T0 units. The comparison
                   produces a structural change record (CD-6).
                3. Direct invalidation (DAS-010 IP-1, IP-2): changed and
                   removed units are invalidated via DDS-002:PC-2.
                4. Cascade propagation (R2, R3): invalidation cascades
                   through grounding chains. T0 and T1 cascades are
                   synchronous; T2 cascades are deferred.
                5. Synchronous pipeline (R4): T0 and T1 recomputation via
                   execution tickets to DDS-001:PC-2. Early termination
                   (R6) stops cascades where output is unchanged.
                6. Index update (R8): change batches delivered to
                   DDS-004:PC-4.
                7. Epoch advancement (R7): DDS-002:PC-4 advances the epoch.
                After processing, the DIR's T0 and T1 content is current
                with respect to the source state. T2 content may be
                invalidated but is flagged. All structural indexes are
                consistent with the new epoch.
  Preconditions: The DIR Runtime (DDS-002) is operational. The Producer
                 Runtime (DDS-001) is ready. The Index Runtime (DDS-004)
                 is in Building or Operational state. At least one frontend
                 producer is registered.
  Failure mode: If a frontend re-parse fails for a file in the change set,
                that file's entities are not updated — prior T0 units are
                retained as stale-but-available (DAS-001 P12). Other files
                in the change set are processed normally. The change set
                still advances the epoch — partial processing is preferable
                to blocking all updates.
                If the DIR Runtime rejects an invalidation transaction
                (DDS-002:FM-4), the Update Engine logs the rejection and
                continues processing. Affected units may remain Active
                when they should be Invalidated — the next change set
                that touches the same entity will re-detect the change.

PC-2: Deferred Recomputation Request
  Direction:    Offered
  Counterparty: Retrieval/Context Assembly subsystem (consumer-demand
                trigger), background scheduler
  Guarantee:    Given a set of entity identifiers or unit identifiers
                requiring T2 recomputation, the Update Engine schedules
                the appropriate T2 producer execution. Consumer-demand
                requests (DAS-010 RS-6) are prioritized above background
                requests. Scheduling respects the T2 recomputation order
                (DAS-010 RS-8): consumer demand first, change proximity
                second, derivation order third.
                When the T2 producer completes successfully, the output
                is committed to the DIR via a write transaction
                (DDS-002:PC-6), superseding the invalidated T2 unit. The
                Update Engine then delivers a change batch to the Index
                Runtime (PC-9) and triggers a deferred epoch advancement
                (PC-7). After the deferred epoch advances, the fresh T2
                output is visible to consumer queries. The deferred
                recomputation queue is updated accordingly.
  Preconditions: The identified T2 units are in Invalidated status, or
                 the entity has no T2 enrichment (first-question trigger,
                 DAS-010 RS-9).
  Failure mode: If the T2 producer fails (AI unavailability, timeout),
                the invalidated T2 unit is retained as stale-but-available
                (DAS-001 P12, DAS-010 WR-6). The unit remains in the
                deferred recomputation queue for later retry. The failure
                is recorded via DDS-001:PC-6. The caller is notified that
                recomputation was not completed — the stale T2 unit (or
                absence of T2 for first-question trigger) is the current
                state. No retry loop — the next consumer demand or
                background scheduling cycle will reattempt.

PC-3: Producer Upgrade Processing
  Direction:    Offered
  Counterparty: Application lifecycle (during startup, after producer
                registration)
  Guarantee:    Given a set of producer version changes detected by
                comparing current producer versions (from DDS-001:PC-3)
                against provenance of existing units, the Update Engine
                schedules re-evaluation of all units produced by the old
                versions. Re-evaluation is processed as a synthetic change
                set: the affected producers re-execute over their full
                scope (DAS-010 PU-3), early termination prevents
                unnecessary cascades (DAS-010 PU-4, PU-5), and the
                standard synchronous/deferred pipeline applies.
  Preconditions: The DIR is loaded (snapshot or fresh). Producer
                 registrations are complete. DDS-001:PC-3 (DAG Query) is
                 available for version comparison.
  Failure mode: If upgrade processing cannot complete (producer fails
                during re-evaluation), the standard failure isolation
                applies (DDS-001:PC-2 failure handling). Units produced
                by the old version remain — they are stale with respect
                to the new producer logic, but their content may still
                be valid. Upgrade re-evaluation can be reattempted on
                the next change set or on the next restart.

PC-4: Reconciliation
  Direction:    Offered
  Counterparty: Application lifecycle (during startup, after snapshot
                load)
  Guarantee:    Given the set of tracked files and their content hashes
                from the loaded snapshot, the Update Engine compares each
                file's current content hash against the snapshot hash
                (DAS-012 reconciliation process). Files with changed
                hashes, new files, and deleted files are assembled into
                a change set and processed via PC-1. After reconciliation,
                the DIR is consistent with the current source state —
                all T0 and T1 content reflects the files on disk.
  Preconditions: The DIR Runtime (DDS-002) is operational with the
                 snapshot-loaded state. The Producer Runtime (DDS-001)
                 is ready. File system access is available.
  Failure mode: If file system enumeration fails (directory not
                accessible), reconciliation completes with the files
                it could access. Missing files are treated as unchanged.
                The system operates with potentially stale content for
                inaccessible files — the next change event for those
                files will trigger normal change set processing.
```

### Required Contracts

```
PC-5: Producer Execution
  Direction:    Required
  Counterparty: Producer Runtime (DDS-001, via DDS-001:PC-2 and
                DDS-001:PC-5)
  Guarantee:    The Update Engine can direct the Producer Runtime to
                execute producers over specified scopes by issuing
                execution tickets (DDS-001:PC-9). For incremental
                execution, the Producer Runtime executes the specified
                producer and returns the change report (via DDS-003:PC-3).
                For batch execution (upgrade processing, reconciliation),
                DDS-001:PC-5 applies.
  Preconditions: The producer is registered (DDS-001:PC-1). The DIR is
                 writable (DDS-002 operational).
  Failure mode: If producer execution fails (DDS-001:PC-2 failure
                handling), the Update Engine receives the failure report
                (DDS-001:PC-6) and applies the appropriate response:
                for deterministic producers, no retry (deterministic
                failures are reproducible); for semantic producers,
                record for deferred retry (DAS-010 RS-7).

PC-6: DIR Write Operations
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-2 and DDS-002:PC-6)
  Guarantee:    The Update Engine can submit batch invalidation
                transactions to the DIR Runtime. Each transaction
                transitions specified units from Active to Invalidated
                status with invalidation metadata (epoch and reason per
                DAS-010 WR-7). The transaction is atomic — all
                transitions commit or none do.
  Preconditions: The specified units exist in the DIR and are in Active
                 status.
  Failure mode: If the DIR Runtime rejects the transaction
                (DDS-002:FM-4 — invalid transition), the Update Engine
                logs the rejection. Units that could not be invalidated
                remain Active — they will be re-detected on the next
                change set if the underlying evidence has changed.

PC-7: Epoch Advancement
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-4)
  Guarantee:    The Update Engine requests epoch advancement in two
                contexts:

                (a) Synchronous epoch: after the synchronous pipeline
                    completes and index updates are delivered. All T0
                    and T1 recomputation for the current change set has
                    completed. All structural index updates have been
                    delivered (PC-9).

                (b) Deferred epoch: after a successful deferred T2
                    recomputation commits its output to the DIR and
                    the corresponding index update is delivered (PC-9).

                In both contexts, the DIR Runtime atomically advances
                the epoch, making all committed changes visible to
                consumer queries. The visibility guarantees are
                identical — both synchronous and deferred epochs use
                DDS-002:PC-4 with the same semantics. The only
                difference is the trigger source.
  Preconditions: For synchronous epochs: all T0 and T1 recomputation
                 for the current change set has completed and all
                 structural index updates have been delivered (PC-9).
                 For deferred epochs: the T2 write transaction has been
                 committed to the DIR and the corresponding index
                 update has been delivered (PC-9).
  Failure mode: None. Epoch advancement is a counter increment
                (DDS-002:PC-4 specifies no failure mode).

PC-8: DAG and Producer Query
  Direction:    Required
  Counterparty: Producer Runtime (DDS-001, via DDS-001:PC-3 and
                DDS-001:PC-4)
  Guarantee:    The Update Engine can query the Pass DAG for topological
                order, dependency edges, and producer-to-predicate
                mappings. This supports: determining which producers
                must re-execute when specific predicates are invalidated,
                ordering execution tickets, and detecting producer
                version changes for upgrade processing.
  Preconditions: The Producer Runtime is in Ready or Executing state.
  Failure mode: None (DDS-001:PC-3 specifies no failure mode).

PC-9: Index Update Delivery
  Direction:    Required
  Counterparty: Index Runtime (DDS-004, via DDS-004:PC-4)
  Guarantee:    After each write transaction (producer output commit
                or invalidation batch) within the synchronous pipeline,
                the Update Engine delivers a change batch to the Index
                Runtime. The change batch describes unit-level changes:
                units created (with subject, predicate, tier, status),
                units whose status transitioned (invalidated, superseded).
                Delivery occurs before epoch advancement (PC-7), ensuring
                structural index consistency at the new epoch.
  Preconditions: The write transaction has been committed to the DIR.
                 The Index Runtime is in Building or Operational state.
  Failure mode: If the Index Runtime reports a structural index update
                failure (DDS-004:FM-1), the Update Engine proceeds with
                epoch advancement. The failing index family falls back
                to DIR scan (DDS-004:PC-1 graceful degradation). The
                Update Engine does not block the pipeline on index
                failure — index rebuild is the Index Runtime's recovery
                mechanism.

PC-10: Grounding Chain Traversal
  Direction:    Required
  Counterparty: Storage layer (grounding dependency map per DAS-012)
  Guarantee:    Given a unit identifier, the Update Engine can retrieve
                the set of units whose provenance.inputs references it.
                This is the reverse grounding lookup required for
                cascade propagation (DAS-010 IP-4). The lookup is
                O(degree) — the number of directly dependent units.
  Preconditions: The grounding dependency map has been constructed
                 (during startup, after snapshot load and index rebuild).
  Failure mode: If the grounding dependency map is not yet available
                (during startup before construction), the Update Engine
                falls back to a DIR scan for reverse grounding
                (DDS-002:PC-3 bulk read filtered by provenance.inputs).
                This fallback is correct but slower — O(N) where N is
                total unit count.

PC-11: DIR Read Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-3 and DDS-002:PC-5)
  Guarantee:    The Update Engine can read DIR content for entity-level
                comparison (comparing old and new T0 units for a file),
                for grounding chain inspection, and for identifying
                units to invalidate. Reads during the synchronous pipeline
                observe pipeline-internal visibility (DDS-002:PC-3(b)).
  Preconditions: The DIR Runtime is operational.
  Failure mode: None (DDS-002:PC-3 specifies no failure mode).

PC-12: Failure Report Consumption
  Direction:    Required
  Counterparty: Producer Runtime (DDS-001, via DDS-001:PC-6)
  Guarantee:    The Update Engine receives failure reports for all
                producer executions it directed. Each report includes
                producer identity, scope, failure category, and diagnostic
                detail. The Update Engine uses failure reports to make
                scheduling decisions: deterministic producer failures
                are not retried (failures are reproducible); semantic
                producer failures are recorded for deferred retry.
  Preconditions: A producer execution has failed.
  Failure mode: None (DDS-001:PC-6 specifies no failure mode for
                failure recording).
```

---

## Lifecycle

### Creation

The Update Engine is created during application startup, after the DIR Runtime (DDS-002) is operational, the Producer Runtime (DDS-001) is ready, and the Index Runtime (DDS-004) has begun construction.

**Preconditions for creation:** DDS-002 state: Operational. DDS-001 state: Ready (at least one frontend registered). DDS-004 state: Building or Operational.

**Startup sequence:** DIR Runtime → (snapshot load) → Producer Runtime → Index Runtime construction begins → Update Engine creation → reconciliation (PC-4) → producer upgrade processing (PC-3) → steady-state operation.

### Operation

The Update Engine becomes operational after reconciliation completes. It accepts change sets (PC-1), deferred recomputation requests (PC-2), and producer upgrade processing (PC-3).

**Operational invariant:** At most one change set is being processed at any time (R9). Between change set processing, the DIR is in a consistent, epoch-advanced state. The deferred recomputation queue accurately reflects all invalidated T2 units awaiting recomputation.

### Quiescence

When the application is shutting down, the Update Engine enters quiescence:

1. No new change sets are accepted.
2. The in-progress change set, if any, completes its synchronous pipeline and advances the epoch (to preserve the work already done).
3. Deferred T2 recomputation requests are abandoned — the deferred queue state is captured in the final snapshot by the Storage Engine.
4. The Update Engine signals completion to the application lifecycle.

**Quiescence ordering:** The Update Engine quiesces before the Producer Runtime (DDS-001), the Index Runtime (DDS-004), and the DIR Runtime (DDS-002). The final epoch advancement ensures that the Storage Engine captures a consistent snapshot.

### Destruction

The Update Engine is destroyed after quiescence. The deferred recomputation queue, change set aggregation state, and any queued change events are released. No persistent cleanup is needed — the snapshot captures the committed DIR state and the deferred queue.

---

## State Model

The Update Engine occupies one of five states:

```
Created → Reconciling → Idle → Processing → Idle
                                           → Quiescing → Terminated
```

**Created.** The Update Engine has been constructed. Dependencies are available. Reconciliation has not yet begun. Change events are queued but not processed.

**Reconciling.** The Update Engine is processing the reconciliation change set (PC-4) and/or producer upgrade processing (PC-3). Change events arriving during reconciliation are queued. This state is a specialized Processing state limited to startup.

**Idle.** No change set is being processed. The DIR is consistent at the committed epoch. The Update Engine accepts new change events. Queued change events trigger aggregation and transition to Processing.

**Processing.** A change set is being processed through the synchronous pipeline. New change events are aggregated into the next change set but not processed until the current processing completes. Deferred recomputation requests are accepted and queued.

**Quiescing.** The application is shutting down. If a change set is in progress, it completes. No new change sets are started. Transition to Terminated occurs when the in-progress change set (if any) completes.

**Terminated.** The Update Engine has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Created | Reconciling | Dependencies ready; startup reconciliation begins | Snapshot state being aligned with current source |
| Reconciling | Idle | Reconciliation and upgrade processing complete | DIR consistent with current source state |
| Idle | Processing | Aggregated change set ready | Synchronous pipeline executing |
| Processing | Idle | Synchronous pipeline complete; epoch advanced | DIR consistent at new epoch |
| Idle | Quiescing | Shutdown signal | No new change sets |
| Processing | Quiescing | Shutdown signal during processing | Current change set completes, then shutdown |
| Quiescing | Terminated | In-progress work resolved | Resources deallocated |

**Invalid transitions:** Created → Processing (must reconcile first). Created → Idle (must reconcile first). Terminated → any state. Quiescing → Idle or Processing (shutdown is irreversible).

---

## Execution Model

### Change Set Processing Pipeline

The core execution model is the change set processing pipeline. Each change set is processed sequentially through these stages:

**Stage 1: Content-Hash Filtering.**
For each file in the change set, compute the current content hash and compare against the stored hash (DDS-002 version stamp via PC-11). Files with unchanged hashes are removed from the change set (DAS-010 CD-1, I6). If all files are filtered, the change set produces no work — no epoch advancement occurs.

**Stage 2: Frontend Re-Execution.**
For each file with a changed content hash, the Update Engine issues an execution ticket to the Producer Runtime (PC-5) for the appropriate frontend. The frontend re-parses the file, producing new T0 units. The new units are committed to the DIR via the Producer Runtime's normal output path (DDS-001:PC-7 → DDS-002:PC-6).

**Stage 3: Entity-Level Comparison.**
The Update Engine compares the new T0 units (from Stage 2) against the prior T0 units for the same file. Comparison is by entity qualified name (DAS-010 CD-4) and predicate (DAS-010 CD-5). The result is a structural change record:
- **Added entities:** Present in new parse, absent in prior. No invalidation cascade — nothing depends on them yet.
- **Removed entities:** Present in prior, absent in new. All units about them are invalidated.
- **Modified entities:** Present in both with different predicate values. Only units with changed predicates are directly invalidated.

**Stage 4: Direct Invalidation.**
For removed and modified entities, the Update Engine submits invalidation transactions to the DIR Runtime (PC-6). Each invalidation carries the epoch and the upstream change identifier as metadata (DAS-010 WR-7).

**Stage 5: Cascade Propagation.**
For each directly invalidated unit, the Update Engine traverses the grounding dependency map (PC-10) to identify transitively dependent units. Cascade follows tier order (T0 → T1 → T2):

- **T0 → T0 cascade:** Rare (T0 units derive from source, not from other T0 units). Processed synchronously.
- **T0 → T1 cascade:** Synchronous (DAS-010 CB-1). The dependent T1 units are invalidated and their producers scheduled for re-execution.
- **T0/T1 → T2 cascade:** Deferred (DAS-010 CB-2). The dependent T2 units are invalidated and added to the deferred recomputation queue.
- **T2 → T2 cascade:** Deferred (DAS-010 CB-3). Processed during deferred pipeline.

**Stage 6: Synchronous Recomputation.**
The Update Engine issues execution tickets (PC-5) for all T0 and T1 passes whose invalidation surfaces include the changed entities. Execution follows Pass DAG topological order (DDS-001:PC-2 preconditions). After each pass execution, the Update Engine consumes the change report (DDS-003:PC-3 via DDS-001). If the output is unchanged, the cascade is terminated for that branch (R6, DAS-010 IP-6). If the output changed, the cascade continues to downstream passes.

**Stage 7: Index Update.**
After all synchronous recomputation is complete, the Update Engine delivers a consolidated change batch to the Index Runtime (PC-9). The change batch describes all unit-level changes from Stages 2 through 6: units created, units invalidated, units superseded.

**Stage 8: Epoch Advancement.**
The Update Engine requests epoch advancement from the DIR Runtime (PC-7). After advancement, the new DIR state is visible to consumer queries. The synchronous pipeline is complete.

### Concurrency Model

**Sequential change set processing.** Change sets are processed one at a time (R9, DAS-010 I8). No two change sets overlap. This eliminates concurrent-write conflicts and simplifies the consistency model. The serialization cost is acceptable because change set processing should complete within milliseconds for typical changes.

**Change event aggregation.** Change events arriving during processing are aggregated into the next change set. The aggregation window (DAS-010 CD-2) is bounded: after the current change set completes, aggregated events are processed as the next change set without artificial delay. Aggregation batches multi-file saves from IDEs and rapid successive saves into efficient processing units.

**Deferred pipeline concurrency.** Deferred T2 recomputation may execute concurrently with the synchronous pipeline of a subsequent change set, subject to two constraints:
1. A deferred T2 recomputation must read from a committed epoch (DDS-002:PC-3(a)) — it does not see in-progress synchronous pipeline writes.
2. If the synchronous pipeline invalidates a T2 unit that is currently being recomputed, the recomputation's output is discarded. The unit remains invalidated and is re-queued for deferred recomputation.

**Deferred pipeline and epoch advancement.** When deferred T2 recomputation completes successfully, the Update Engine commits the output via a write transaction (DDS-002:PC-6), delivers the corresponding change batch to the Index Runtime (PC-9), and triggers a deferred epoch advancement (PC-7). The deferred epoch follows the same visibility guarantees as a synchronous epoch — after advancement, the fresh T2 output is visible to consumer queries. This ensures that T2 recomputation results are visible promptly, without waiting for the next source change to trigger a synchronous pipeline.

### Scheduling Priorities

The Update Engine applies DAS-006 scheduling priorities when ordering recomputation:

**SP-1: Tier priority.** T0 before T1 before T2. Enforced by the synchronous/deferred pipeline split and by DAG ordering within the synchronous pipeline.

**SP-2: Change proximity.** Within a tier, entities most recently changed are recomputed first. Applied during deferred T2 scheduling — recently changed entities' T2 units are recomputed before stale T2 units from older change sets.

**SP-3: Consumer demand.** T2 units requested by active consumer queries (PC-2 with consumer-demand trigger) are recomputed before background T2 units. Consumer demand elevates a T2 unit's priority above SP-2.

**SP-4: Budget constraints.** T2 recomputation that requires AI invocation (semantic passes) respects execution availability. If execution is unavailable (budget exhausted, service unreachable), deferred recomputation pauses until execution becomes available. The Update Engine does not track budget itself — it observes execution availability as exposed through the producer execution contract (PC-5). When the Producer Runtime reports that a semantic producer cannot execute (DDS-001:PC-2 failure semantics), the Update Engine defers scheduling for that producer until the next scheduling cycle.

---

## Memory and Ownership

### Owned State

**Change event queue.** Incoming change events are queued until aggregated into a change set. The queue is bounded — if change events accumulate faster than the processing pipeline can drain them, the aggregation window widens but the queue size is capped. Events beyond the cap are coalesced (multiple events for the same file become a single event). Owned exclusively by the Update Engine. Not persisted.

**Deferred recomputation queue.** The set of T2 unit identifiers awaiting recomputation. Owned exclusively by the Update Engine during operation. Persisted in the snapshot by the Storage Engine (the Update Engine provides the queue contents to the Storage Engine upon request). On startup, restored from the snapshot. Validated during reconciliation (any T2 unit with Invalidated status not in the queue is added; any queue entry referencing a non-existent or Active unit is removed).

**In-progress change set state.** During processing, the Update Engine maintains: the structural change records for each file, the set of directly invalidated units, the cascade frontier (units pending cascade evaluation), and the set of execution tickets issued and their completion status. This state exists only during processing and is released on completion. Not persisted.

### Borrowed State

**Grounding dependency map.** Maintained by the storage layer (DAS-012). The Update Engine reads it during cascade propagation (PC-10). The Update Engine does not modify the map — the storage layer updates it when units are created or garbage-collected.

**Pass DAG.** Owned by the Producer Runtime (DDS-001:R2). The Update Engine queries it (PC-8) to determine execution order and producer-to-predicate mappings. The Update Engine does not modify the DAG.

### Memory Bounds

The Update Engine's memory footprint is dominated by the deferred recomputation queue and the in-progress change set state.

**Deferred recomputation queue:** At most one entry per T2 unit in the DIR. At alpha scale (~4,000 T2 units), the queue is at most ~4,000 entries × ~16 bytes (unit identifier + priority metadata) ≈ 64 KB. At the practical limit (~40,000 T2 units), ~640 KB.

**In-progress change set state:** Proportional to the size of the change set, not the codebase. A single-file change produces structural change records for ~20 entities. At ~200 bytes per record, the in-progress state is ~4 KB. A multi-file change (e.g., branch switch touching 100 files) produces ~2,000 records ≈ 400 KB. The cascade frontier is bounded by the grounding dependency fan-out — typically <1,000 entries for a single-file change.

**Total Update Engine memory:** <1 MB at alpha scale, <5 MB at practical limit. Negligible relative to the DIR and index memory footprints.

---

## Failure Handling

```
FM-1: Frontend Parse Failure
  Trigger:     A frontend execution ticket fails — the frontend cannot
               parse a changed file (syntax error, encoding issue,
               unsupported language feature).
  Detection:   The Producer Runtime reports failure via PC-12 with
               failure category "error" and the frontend identity.
  Response:    The file's prior T0 units are retained as stale-but-
               available. The file is excluded from entity-level
               comparison, direct invalidation, and cascade propagation
               for this change set. Other files in the change set
               continue processing normally. The file is recorded for
               retry on the next change set.
  Caller observes: The change set processing completes. The epoch
               advances. The failed file's entities appear at the prior
               epoch's state (stale but consistent). Observability
               metrics record the failure.
  Recovery:    The next change event for the file (including a save
               that fixes the syntax error) triggers a new change set
               that reprocesses the file. No manual intervention needed.

FM-2: Synchronous Pass Failure
  Trigger:     A T0 or T1 pass execution ticket fails during the
               synchronous pipeline.
  Detection:   The Producer Runtime reports failure via PC-12.
  Response:    The pass's prior output is retained (DDS-001:PC-2
               failure semantics). Downstream passes that depend on the
               failed pass's output execute against the prior output.
               The cascade continues based on the prior output state.
               The failure is recorded in observability.
  Caller observes: The epoch advances with the failed pass's prior
               output. Downstream content may be stale relative to the
               source change, but is internally consistent with the
               retained prior output.
  Recovery:    The next change set that touches entities in the failed
               pass's scope triggers re-execution. For reproducible
               failures (deterministic pass logic error), the failure
               persists until the producer is fixed and upgraded (PC-3).

FM-3: Deferred T2 Recomputation Failure
  Trigger:     A T2 producer execution fails (AI service unavailable,
               timeout, budget exhaustion).
  Detection:   The Producer Runtime reports failure via PC-12.
  Response:    The invalidated T2 unit remains in the deferred
               recomputation queue. No retry is attempted immediately.
               The unit's stale content remains available for consumer
               queries (DAS-001 P12, DAS-010 WR-6).
  Caller observes: The consumer-demand caller (PC-2) is notified that
               recomputation was not completed. The consumer uses the
               stale T2 content or proceeds without T2 content.
  Recovery:    The next consumer-demand request or background scheduling
               cycle reattempts recomputation. Budget exhaustion recovers
               automatically when budget is replenished. AI service
               unavailability recovers when the service is restored.

FM-4: Invalidation Transaction Rejection
  Trigger:     The DIR Runtime rejects an invalidation write transaction
               (DDS-002:FM-4) because the requested state transition is
               no longer valid. This occurs when the target unit is
               already Invalidated (duplicate invalidation request from
               overlapping cascade paths), already Superseded (a
               producer within the same pipeline committed a replacement
               unit before the invalidation was submitted), or when the
               execution context is stale (the unit was identified for
               invalidation based on grounding chain state that was
               subsequently updated by an earlier stage of the same
               pipeline).
  Detection:   The DIR Runtime returns a rejection diagnostic via PC-6,
               identifying the unit and the invalid transition.
  Response:    The Update Engine logs the rejection with the affected
               unit identifiers and continues processing. In all cases,
               the unit is already in a state that does not require
               invalidation: an already-Invalidated unit is in the
               correct state; a Superseded unit has been replaced and
               its successor carries the current content. No corrective
               action is needed.
  Caller observes: Change set processing continues. The epoch advances.
               The rejected invalidation does not block the pipeline.
  Recovery:    None needed. The rejection reflects a state that is
               already correct — the unit does not require the
               requested transition.

FM-5: Index Update Failure
  Trigger:     The Index Runtime reports a structural index update
               failure during change batch delivery (DDS-004:FM-1).
  Detection:   The Index Runtime returns failure notification for the
               affected family via PC-9.
  Response:    The Update Engine proceeds with epoch advancement. The
               failing index family falls back to DIR scan
               (DDS-004:PC-1 graceful degradation). The Update Engine
               records the failure for observability.
  Caller observes: Consumer queries that use the failing index are
               slower (DIR scan fallback) but correct. The Index Runtime
               independently schedules rebuild for the failing family.
  Recovery:    The Index Runtime's self-recovery mechanism
               (DDS-004:PC-2 rebuild) restores the failing family.
               The Update Engine does not participate in index recovery
               beyond delivering subsequent change batches normally.

FM-6: Grounding Dependency Map Unavailable
  Trigger:     The grounding dependency map is not yet constructed
               (during early startup before the storage layer completes
               map construction).
  Detection:   PC-10 returns a "not available" indicator.
  Response:    The Update Engine falls back to DIR scan for reverse
               grounding traversal — querying all units and filtering
               by provenance.inputs. This fallback is correct but slow
               (O(N) where N is total unit count).
  Caller observes: Change set processing is slower during early startup.
               Once the map is available, subsequent change sets use
               the O(degree) path.
  Recovery:    Automatic — the storage layer completes map construction
               during startup. No intervention needed.
```

---

## Performance Requirements

### Architectural Requirements

These requirements are derived from DAS invariants and must be satisfied by any conforming implementation.

**PR-1: Content-hash filtering is O(1) per file.** A content-hash comparison determines whether a file has changed. The comparison must not depend on file size or codebase size. (DAS-010 CD-1, I6.)

**PR-2: Entity-level comparison is O(E) per file.** Where E is the number of entities in the changed file. Comparison must not scan the entire DIR — only entities from the changed file. (DAS-010 CD-4, CD-5.)

**PR-3: Cascade propagation is O(D) per invalidated unit.** Where D is the degree (number of directly dependent units) in the grounding dependency map. Cascade propagation must not scan the entire DIR. (DAS-010 IP-4, DAS-012 grounding dependency map.)

**PR-4: Synchronous pipeline completes before epoch advancement.** All T0 and T1 recomputation, all structural index updates, and epoch advancement must complete as part of the synchronous pipeline. No consumer query observes a partially-processed state. (DAS-010 I1, I4, WR-3.)

### Engineering Targets

These targets are informed by the domain analysis in DAS-012 and represent expected performance at alpha scale. They are not architectural invariants — they are engineering goals for the initial implementation.

**ET-1: Single-file change set processing.** Target: <100 ms end-to-end (content-hash check through epoch advancement) at alpha scale (~300,000 units, ~20 entities per file).

**ET-2: Multi-file change set processing (10 files).** Target: <500 ms end-to-end at alpha scale.

**ET-3: Reconciliation (startup).** Target: proportional to files changed since last snapshot. At alpha scale with 10 files changed: <1 second. With 100 files changed: <5 seconds.

**ET-4: Deferred T2 recomputation latency (consumer demand).** Target: T2 execution ticket issued within 10 ms of consumer demand request. Actual recomputation time depends on the T2 producer (AI invocation — typically 1-5 seconds).

---

## Observability

**OB-1: Change set metrics.** For each change set: number of files in the change set, number of files filtered by content-hash (no change), number of entities added/removed/modified, total direct invalidations, total cascade invalidations (broken down by tier), synchronous pipeline duration, epoch number before and after.

**OB-2: Cascade metrics.** For each synchronous pipeline: cascade depth distribution, early termination count (cascades stopped because output unchanged), number of T2 units added to deferred queue.

**OB-3: Deferred pipeline metrics.** Current deferred queue size, consumer-demand recomputation requests (count and latency), background recomputation count, T2 recomputation failure count and reasons.

**OB-4: Scheduling metrics.** Execution tickets issued per change set (by tier and producer), execution ticket completion time, budget utilization for semantic passes.

**OB-5: Reconciliation metrics.** Files compared, files with changed hashes, reconciliation duration, change set size generated by reconciliation.

**OB-6: Producer upgrade metrics.** Producer version changes detected, units affected by upgrade, upgrade recomputation duration.

---

## Testing Requirements

### Contract Tests

- PC-1 (Change Set Processing): A change set with modified, created, and deleted files processes correctly — entities are compared, invalidation cascades propagate, the synchronous pipeline completes, indexes are updated, and the epoch advances.
- PC-1 content-hash filtering: A change set where all files have unchanged content hashes produces no work and no epoch advancement.
- PC-2 (Deferred Recomputation): A consumer-demand request for an invalidated T2 unit results in a T2 execution ticket and, on success, the T2 unit is superseded by fresh output.
- PC-3 (Producer Upgrade): After a producer version change, all units produced by the old version are scheduled for re-evaluation.
- PC-4 (Reconciliation): After snapshot load with files changed on disk, the reconciliation produces a change set that brings the DIR into consistency with current source state.

### State Model Tests

- Created → Reconciling → Idle transitions occur during startup.
- Idle → Processing → Idle transitions occur during normal change set processing.
- Change events arriving during Processing state are queued and processed in the next cycle.
- Shutdown during Processing state allows the current change set to complete before transitioning to Terminated.

### Failure Mode Tests

- FM-1: A frontend parse failure for one file in a multi-file change set does not prevent other files from being processed.
- FM-2: A synchronous pass failure retains prior output and allows downstream passes to execute against it.
- FM-3: A deferred T2 recomputation failure leaves the T2 unit in the deferred queue for later retry.
- FM-4: An invalidation transaction rejection for an already-Invalidated unit does not block the pipeline.
- FM-5: An index update failure does not prevent epoch advancement.
- FM-6: Unavailable grounding dependency map falls back to DIR scan correctly.

### Invariant Tests

- **I1 (Epoch Consistency):** After every change set processing, all T0 and T1 units are Active (not Invalidated) at the new epoch.
- **I2 (Cascade Directionality):** No invalidation cascade propagates from a higher tier to a lower tier.
- **I3 (Early Termination):** When a recomputed unit produces unchanged output, no downstream unit is invalidated from that branch.
- **I4 (Change Set Atomicity):** Consumer queries during processing observe only the prior epoch's state — never a mix of old and new.
- **I5 (Grounding Chain Completeness):** Every unit reachable through grounding chains from directly invalidated units is either invalidated, terminated early, or deferred.
- **I6 (Content-Hash Idempotency):** A file save with no content change produces zero invalidations and zero recomputations.
- **I8 (Sequential Processing):** Two change sets submitted concurrently are processed sequentially — no interleaving.

### Integration Tests

- End-to-end: A file change → change detection → frontend re-parse → entity comparison → invalidation → cascade → pass re-execution → index update → epoch advancement → consumer query returns updated content.
- Deferred pipeline: A T2 unit invalidated by the synchronous pipeline → consumer demand request → T2 recomputation → deferred epoch advancement → fresh T2 unit immediately visible to consumer queries.
- Reconciliation: Snapshot load → files changed on disk → reconciliation change set → DIR consistent with current source.
- Producer upgrade: Producer version change → upgrade detection → re-evaluation → units updated with new producer version in provenance.
- Early termination: File change affects function body but not signature → T0 re-parse → entity comparison shows `hasBody` changed but `hasSignature` unchanged → T1 passes that depend only on signature terminate early.

---

## Future Evolution

**Module Intelligence scope expansion.** As Module Intelligence introduces cross-file relationship tracking, the cascade propagation model (R2) will handle more cross-file invalidations. The current architecture supports this — cross-file cascade follows grounding chains regardless of file boundaries (DAS-010 cross-file invalidation). No architectural change is needed; the grounding chains will simply span more files.

**Project Intelligence scale.** Project Intelligence (full-codebase understanding) will increase the entity count and cascade fan-out. The Update Engine's performance characteristics (O(D) cascade per unit, sequential processing) remain valid, but the engineering targets (ET-1 through ET-4) may need revision. The deferred pipeline becomes more critical as T2 unit count grows.

---

## Open Questions

**Q1: Should the Update Engine maintain a per-entity change history for scheduling optimization?** *(Non-blocking)*

The change proximity scheduling priority (SP-2) requires knowing which entities were most recently changed. A per-entity change timestamp or epoch would support this. Currently, the Update Engine can derive this from the DIR's version stamps, but a dedicated structure would be more efficient.

**Impact:** Affects deferred pipeline scheduling performance, not correctness. No contracts are affected.

**Investigation approach:** Profile the deferred pipeline scheduling at alpha scale. If priority ordering is a bottleneck (>10ms per scheduling decision), add a per-entity change epoch structure.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial specification of the Update
    Engine Runtime. Realizes DAS-010 (Incremental Update Model) as the
    orchestrating subsystem for change detection, invalidation propagation,
    recomputation scheduling, and epoch advancement coordination. Depends on
    DDS-001 (Producer Runtime), DDS-002 (DIR Runtime Model), DDS-003 (Pass
    Runtime), and DDS-004 (Index Runtime). Twelve offered and required
    contracts (PC-1 through PC-12). Ten responsibilities. Five-state model.
    Eight-stage change set processing pipeline. Six failure modes. Six
    observability concerns. Three open questions.
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions: (1) Resolved
    deferred epoch semantics — successful deferred T2 recomputation triggers
    a deferred epoch advancement with the same visibility guarantees as
    synchronous epochs; Q2 removed as resolved. (2) Corrected FM-4 —
    removed race condition language, explained invalidation rejection as
    invalid state transition under sequential processing (duplicate request,
    already superseded, stale execution context). (3) Removed Q1 — rapid
    save coalescing is an implementation optimization, not a specification
    concern. (4) Refined SP-4 — execution availability exposed through
    producer execution contract rather than Producer Runtime budget ownership.
```
