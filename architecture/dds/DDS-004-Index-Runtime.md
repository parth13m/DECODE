# DDS-004: Index Runtime

```
Document:      DDS-004
Title:         Index Runtime
Status:        Draft
Version:       0.2
Author:        Principal Engineer
Created:       2026-06-28
Last Revised:  2026-06-28
Reviewers:     —
Depends On:    DDS-000 (Design Authoring Standard), DDS-002 (DIR Runtime Model)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-007, DAS-010, DAS-012
```

## Abstract

This document specifies the engineering design of the Index Runtime — the subsystem that maintains derived, query-optimized index structures over the canonical DIR. It defines the lifecycle, construction, incremental maintenance, consistency guarantees, read contracts, failure handling, and recovery behavior for the five index families defined in DAS-007 (Entity, Graph, Predicate, Content, Scope). The Index Runtime realizes the index architecture from DAS-007, the index maintenance obligations from DAS-010, and the ephemeral index realization from DAS-012. The Index Runtime owns no authoritative data — every byte in every index is derivable from the DIR (DDS-002). Index failure degrades query performance, not correctness.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P1 (intelligence is the canonical asset — indexes are derived,
            never authoritative; DIR authority enforced), P7 (relevance over
            completeness — index projections store only fields needed for
            access patterns), P9 (incremental by design — index maintenance
            is incremental, proportional to change size not index size),
            P12 (graceful degradation — missing indexes degrade performance,
            not correctness; DIR scan fallback for all queries)
  Not addressed: P2, P3, P4 (DDS-001, DDS-003 — execution ordering),
                P5 (DDS-002 — grounding enforcement), P6, P8, P10
                (DDS for Retrieval/Context Assembly), P11 (DDS-001 —
                producer independence)

DAS-002: Decode Intermediate Representation
  Realized: I8 (index derivability — every index rebuildable from DIR
            without data loss), DC-4 (DIR exists independently of queries
            — indexes are derived projections, not corequisites of DIR)
  Not addressed: I1 through I7 (DDS-002, DDS-001), DC-1 through DC-3,
                DC-5 (DDS-002, DDS for Storage Engine), lifecycle model
                (DDS-002:R4), atomic unit contract fields (DDS-002:R2)

DAS-003: Tier Model
  Realized: Freshness contracts at the index level — T0-derived entries
            source-synchronous (IF-1), T1-derived entries propagation-delay
            (IF-2), T2-derived entries eventually fresh (IF-3). Index
            freshness inherits from tier freshness, not independently defined.
  Not addressed: I1 through I7 (DDS-002, DDS-001), tier assignment
                (DDS-002:R8, DDS-003), confidence model (DDS-002),
                TL-1, TL-2, TL-3 (DDS-002, DDS for Storage Engine)

DAS-007: Index Architecture
  Realized: Five index families (Entity, Graph, Predicate, Content, Scope)
            — construction, maintenance, query contracts for each.
            IL-1 (missing index does not prevent queries — DIR scan fallback),
            IL-2 (creation in priority order), IL-3 (updates driven by DIR
            changes), IL-4 (updates per-family), IL-5 (destruction does not
            affect DIR).
            IO-1 (no authoritative data in indexes), IO-2 (indexes do not
            write to DIR), IO-3 (no cross-instance sharing),
            IO-4 (index maintenance is system responsibility, not pass).
            INV-1 through INV-3 (staleness sources — creation, invalidation,
            supersession).
            IIM-1 (incremental, not batch), IIM-2 (cost proportional to
            change), IIM-3 (updates follow pass pipeline),
            IIM-4 (atomic per unit).
            IF-1 through IF-5 (freshness model).
            IFR-1 through IFR-7 (failure and recovery).
            I1 through I7 (all seven invariants).
  Not addressed: Index projections (implementation data structure choice),
                index partitioning/sharding (implementation decision),
                Content Index structured queries (DAS-007 Q2 — deferred)

DAS-010: Incremental Update Model
  Realized: IM-1 (synchronous index updates within pipeline),
            IM-2 (affected index identification by change type),
            IM-3 (index update ordering — Entity/Graph first, then
            Scope/Predicate, Content deferred),
            IM-4 (Content Index deferred updates — eventually consistent),
            IM-5 (index rebuildability from DIR),
            IM-6 (rebuild triggers — inconsistency, schema change, upgrade),
            I7 (Index-DIR consistency at every epoch for structural indexes)
  Not addressed: CD-1 through CD-6 (DDS for Update Engine),
                IP-1 through IP-6 (DDS for Update Engine),
                CB-1 through CB-4 (DDS for Update Engine),
                RS-1 through RS-10 (DDS for Update Engine, DDS-001),
                WR-1 through WR-7 (DDS-002), PU-1 through PU-5 (DDS-001),
                GC-1 through GC-4 (DDS for Storage Engine),
                I1 through I6, I8 (DDS-002, DDS for Update Engine)

DAS-012: Storage Realization
  Realized: I3 (index ephemeral derivability — all indexes rebuilt on
            every process startup; no index state persists across restarts),
            C6 (index rebuild on restart ensures correctness by
            construction — eliminates consistency bugs from persistent
            indexes)
  Not addressed: Snapshot persistence (DDS for Storage Engine),
                unit store structure (DDS-002), GC retention (DDS for
                Storage Engine), reconciliation (DDS for Storage Engine),
                grounding dependency map (DDS for Update Engine)
```

## Terminology

**Index Family** — One of five classes of derived query-optimized structures, each serving a distinct access pattern over the DIR: Entity, Graph, Predicate, Content, and Scope. Each family has its own construction method, freshness policy, invalidation behavior, and rebuild priority. `See DAS-007`

**Index Entry** — A single record within an index that maps a query key to a set of DIR unit references. An index entry is a derived projection — it stores only the fields relevant to its family's access pattern. The complete atomic unit is always retrievable from the DIR (DDS-002:PC-5). `INTRODUCED`

**Structural Index** — An index family whose entries must be consistent with the DIR at every committed epoch. The Entity, Graph, Scope, and Predicate indexes are structural indexes. They are updated synchronously during the pipeline, before epoch advancement. `INTRODUCED`

**Deferred Index** — An index family whose entries may lag behind the DIR by a bounded number of epochs. The Content Index is a deferred index. It is updated asynchronously after epoch advancement. `INTRODUCED`

**Change Batch** — The set of unit-level changes (creations, invalidations, supersessions) resulting from a committed write transaction. A change batch is the input to incremental index maintenance — it specifies exactly which index entries must be added, updated, or removed. `INTRODUCED`

**Index Rebuild** — The process of constructing an index family from scratch by scanning the relevant DIR content. Rebuild produces a fresh index and is the recovery mechanism for corruption, loss, or startup. Rebuild cost is bounded by the size of the family's source data, not by the full DIR size. `See DAS-007 IFR-5, IFR-7`

---

## Responsibilities

```
R1: Own and maintain the five index families as derived structures over
    the DIR.
    DAS: DAS-007 (five index families), DAS-002 I8 (index derivability),
         DAS-001 P1 (intelligence is canonical — indexes are not)
    Boundary: The Index Runtime owns the index data structures in memory.
              It does not own the DIR content from which indexes derive
              (DDS-002 owns the unit store). It does not own persistent
              storage of indexes (DAS-012 I3: indexes are ephemeral).

R2: Construct all index families from the DIR during process startup.
    DAS: DAS-012 I3 (ephemeral indexes rebuilt on every startup),
         DAS-012 C6 (rebuild ensures correctness by construction),
         DAS-007 IL-2 (creation in priority order)
    Boundary: The Index Runtime reads the DIR via PC-5 to build indexes.
              It does not participate in snapshot loading or reconciliation
              (DDS for Storage Engine). Index construction begins after
              the DIR Runtime is operational and the unit store is populated.

R3: Incrementally update indexes in response to DIR changes during
    execution cycles.
    DAS: DAS-007 IIM-1 through IIM-4 (incremental maintenance),
         DAS-010 IM-1 through IM-4 (synchronous and deferred updates)
    Boundary: The Index Runtime receives change batches (PC-6) and updates
              the affected index families. It does not produce DIR changes
              — it consumes them. It does not determine what changed — the
              scheduling subsystem delivers change batches.

R4: Serve index queries with epoch-consistent results for structural
    indexes.
    DAS: DAS-007 IF-4 (consistent snapshot across families),
         DAS-010 I7 (Index-DIR consistency at every epoch)
    Boundary: The Index Runtime serves queries from retrieval, scheduling,
              and observability consumers. It does not perform retrieval
              ranking, context assembly, or consumer-specific filtering
              (DDS for Retrieval/Context Assembly).

R5: Manage per-family freshness — synchronous updates for structural
    indexes, deferred updates for the Content Index.
    DAS: DAS-007 IF-1 (T0 source-synchronous), IF-2 (T1 propagation
         delay), IF-3 (T2 eventually fresh), DAS-010 IM-4 (Content Index
         deferred)
    Boundary: The Index Runtime applies the freshness policy per family.
              The freshness contracts themselves are defined by DAS-003.
              The Index Runtime inherits them — it does not independently
              define freshness guarantees.

R6: Detect and recover from index inconsistency.
    DAS: DAS-007 IFR-1 through IFR-7 (failure and recovery),
         DAS-007 I2 (DIR authority — index yields to DIR on conflict)
    Boundary: The Index Runtime detects inconsistency and triggers
              rebuild. It does not repair the DIR — the DIR is
              authoritative. Index recovery is always rebuild from DIR.

R7: Support graceful degradation when individual indexes are unavailable.
    DAS: DAS-007 IL-1 (missing index does not prevent queries),
         DAS-007 I6 (graceful absence), DAS-001 P12
    Boundary: When an index family is unavailable (during rebuild or
              after failure), the Index Runtime falls back to DIR scan
              for queries that would use that family. Queries remain
              correct but slower.

R8: Provide per-family observability metrics.
    DAS: DAS-007 IOB-1 through IOB-4 (index observability)
    Boundary: The Index Runtime emits per-family metrics (size, freshness,
              query performance, rebuild history). Aggregation,
              dashboarding, and alerting are outside scope.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Index Query
  Direction:    Offered
  Counterparty: Retrieval/Context Assembly subsystem, scheduling subsystem,
                observability consumers
  Guarantee:    Given an index family, query parameters, and the current
                epoch context, the Index Runtime returns the set of matching
                index entries. For structural indexes (Entity, Graph, Scope,
                Predicate), results are consistent with the DIR at the
                committed epoch — no entry references a superseded or
                garbage-collected unit, and no active unit matching the
                query is missing. For the deferred index (Content), results
                may reflect a prior epoch but are never older than the
                deferred freshness bound.

                Query types per family:
                - Entity: by entity identifier → set of (unit ID, predicate,
                  tier, status). Optional filters: predicate, tier, status.
                - Graph: by (entity, relationship predicate, direction) →
                  set of (neighbor entity, unit ID, tier, status). Supports
                  both forward and inverse traversal (DAS-005 R-DIR-2).
                - Predicate: by predicate → set of (unit ID, subject, tier,
                  status, provenance.producer). Optional filters: tier,
                  status, provenance.
                - Content: by search term → set of (unit ID, subject,
                  predicate). Supports term-based search over text-valued
                  units.
                - Scope: by scope entity → set of (contained entity ID,
                  depth). Supports transitive containment queries.

                When an index family is unavailable (during rebuild or
                after failure), the Index Runtime falls back to DIR scan
                via DDS-002:PC-3. The fallback is correct but slower.
                The caller is notified that fallback is in effect.
  Preconditions: The Index Runtime is in Building or Operational state.
                 For structural index queries during Building state, only
                 families that have completed construction return indexed
                 results; others use DIR scan fallback.
  Failure mode: None. Index queries do not fail. If an index family is
                unavailable, DIR scan provides correct results. If the
                DIR Runtime is not operational, queries are deferred until
                it becomes operational.

PC-2: Index Rebuild
  Direction:    Offered
  Counterparty: Scheduling subsystem, observability consumers (diagnostic
                rebuild)
  Guarantee:    Given an index family identifier, the Index Runtime
                rebuilds that family from the current DIR state. The
                rebuild scans the relevant subset of DIR content
                (DAS-007 IFR-7: bounded rebuild), constructs a fresh
                index, and atomically replaces the existing index. During
                rebuild, queries against the rebuilding family use DIR
                scan fallback (PC-1 graceful degradation).
  Preconditions: The DIR Runtime is operational (DDS-002 state:
                 Operational). The specified family is a valid family
                 identifier.
  Failure mode: If the DIR Runtime becomes unavailable during rebuild,
                the rebuild is aborted and the prior index state (if any)
                is retained. The family remains in its pre-rebuild state
                (possibly stale or absent). A rebuild failure is recorded
                in observability.

PC-3: Index Freshness Report
  Direction:    Offered
  Counterparty: Scheduling subsystem, observability consumers
  Guarantee:    For each index family, the Index Runtime reports:
                - Last update epoch (the most recent epoch at which the
                  index was updated).
                - Stale entry count (entries referencing invalidated or
                  superseded units not yet reflected — meaningful only
                  for the Content Index, as structural indexes are
                  always current at the committed epoch).
                - Family availability (available, rebuilding, absent).
                - Memory footprint estimate.
  Preconditions: None.
  Failure mode: None. The freshness report is always available — it
                reads in-memory metadata, not index content.

PC-4: Batch Index Update
  Direction:    Offered
  Counterparty: Scheduling subsystem (during synchronous pipeline
                execution)
  Guarantee:    Given a change batch (the set of unit creations,
                invalidations, and supersessions from a committed write
                transaction), the Index Runtime updates all structural
                indexes (Entity, Graph, Scope, Predicate) to reflect the
                changes. Structural index updates complete synchronously
                before the caller returns. The Content Index update is
                enqueued for deferred processing (DAS-010 IM-4).

                After PC-4 returns, all structural indexes are consistent
                with the DIR state that includes the change batch. The
                scheduling subsystem may then advance the epoch
                (DDS-002:PC-4) with the guarantee that consumer queries
                against the new epoch will see consistent index content.

                Update ordering within a change batch follows DAS-010
                IM-3: Entity and Graph indexes are updated first, then
                Scope and Predicate. This ordering ensures that scope
                resolution queries during subsequent pass input assembly
                reflect containment changes.
  Preconditions: The change batch describes a committed write transaction
                 (all units referenced in the batch exist in the DIR).
                 The Index Runtime is in Building or Operational state.
  Per-family behavior:
                 - Available families: updated immediately (synchronous).
                 - Rebuilding families: the change batch is applied to the
                   in-progress rebuild copy so that the rebuilt index is
                   current when it replaces the prior index.
                 - Building families (initial construction in progress):
                   the change batch is queued and applied when construction
                   completes, before the family transitions to Available.
                 The contract never rejects a valid change batch during
                 normal runtime. Every change batch is either applied
                 immediately or queued for application upon family
                 readiness.
  Failure mode: If a structural index update fails (internal
                inconsistency detected during update), the failing index
                is marked for rebuild (FM-1). The update for other
                families completes normally. The caller is notified of
                the failure. The failing family falls back to DIR scan
                until rebuild completes.
```

### Required Contracts

```
PC-5: DIR Read Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-3)
  Guarantee:    The Index Runtime can read DIR content for index
                construction and rebuild. Reads observe the committed
                epoch (DDS-002:PC-3(a) for index construction; PC-3(b)
                for within-pipeline reads during incremental updates).
  Preconditions: The DIR Runtime is operational (DDS-002 state:
                 Operational).
  Failure mode: If the DIR Runtime is not operational (Loading or
                Terminated), index construction or rebuild is deferred
                until the DIR Runtime becomes operational.

PC-6: Change Batch Delivery
  Direction:    Required
  Counterparty: Scheduling subsystem (coordinator of the synchronous
                pipeline)
  Guarantee:    After each write transaction is committed to the DIR
                (DDS-002:PC-6), the scheduling subsystem delivers a
                change batch to the Index Runtime describing the unit-
                level changes: units created (with subject, predicate,
                tier, status), units whose status transitioned
                (invalidated, superseded), and units removed (garbage
                collected). The change batch is delivered before epoch
                advancement (DDS-002:PC-4), ensuring that structural
                index updates complete before consumer queries observe
                the new epoch.
  Preconditions: The write transaction has been committed to the DIR.
  Failure mode: If no change batch is delivered (scheduling subsystem
                failure), indexes become stale. The Index Runtime
                detects staleness via epoch comparison (the DIR's
                committed epoch exceeds the index's last-update epoch)
                and triggers rebuild (FM-3).

PC-7: DIR Unit Resolution
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-5)
  Guarantee:    The Index Runtime can resolve unit identifiers to
                complete unit records. Used during index construction
                to retrieve full unit content, and during fallback
                queries (DIR scan) when an index family is unavailable.
  Preconditions: The unit identifier was issued by the DIR Runtime.
  Failure mode: If a unit identifier does not resolve (garbage
                collected), the index entry referencing it is removed.
                This is not an error — it is a normal consequence of
                garbage collection.
```

---

## Lifecycle

### Creation

The Index Runtime is created during application startup, after the DIR Runtime (DDS-002) is operational and the unit store is populated (snapshot loaded and reconciliation complete).

**Preconditions for creation:** The DIR Runtime is in Operational state. The unit store contains the reconciled DIR content.

**No persistent state.** The Index Runtime has no persistent state (DAS-012 I3). All index structures are built from scratch on every process startup. No index data survives across restarts. This eliminates the class of bugs where persistent indexes diverge from the DIR (DAS-012 C6).

### Construction (Startup Build)

Immediately after creation, the Index Runtime constructs all five index families from the DIR:

1. **Entity Index** — scan all units, group by subject entity. Priority: highest.
2. **Graph Index** — scan all paired-entity units, build bidirectional adjacency structure. Priority: high.
3. **Scope Index** — scan `contains` relationship units, compute transitive closure. Priority: high.
4. **Predicate Index** — scan all units, group by predicate. Priority: moderate.
5. **Content Index** — scan text-valued units (T1, T2), build term index. Priority: lowest.

Construction follows DAS-007 IL-2 (priority order) and DAS-007 IFR-4 (rebuild priority). Each family becomes available for queries as soon as its construction completes — the Index Runtime does not wait for all families to finish before serving queries for completed families.

**Construction performance.** At alpha scale (~300,000 units), total construction time is expected to be under 1 second. At the practical limit (~6,000,000 units), under 15 seconds (DAS-012 C2). Structural indexes (Entity, Graph, Scope, Predicate) are constructed first; the Content Index is constructed last.

### Operation

The Index Runtime becomes fully operational when all five index families have been constructed. It serves queries (PC-1), processes change batches (PC-4), and reports freshness (PC-3). The Index Runtime is partially operational during construction — completed families serve indexed queries while families under construction use DIR scan fallback.

**Operational invariant:** At every committed epoch, all structural indexes (Entity, Graph, Scope, Predicate) are consistent with the DIR. The Content Index may lag by a bounded number of epochs.

### Quiescence

When the application is shutting down, the Index Runtime enters quiescence:

1. No new change batches are accepted.
2. In-progress index updates complete.
3. Deferred Content Index updates are discarded (they are not persistent — DAS-012 I3).
4. Index structures remain available for read queries until final destruction.

### Destruction

The Index Runtime is destroyed during application teardown, after all consumers have stopped querying. Index structures are deallocated. No cleanup of DIR content occurs — the DIR Runtime owns the canonical data.

**Destruction ordering:** The Index Runtime is destroyed before the DIR Runtime (DDS-002). The DIR Runtime remains available for any final snapshot operations after index destruction.

---

## State Model

The Index Runtime occupies one of four states:

```
Uninitialized → Building → Operational → Quiescing → Terminated
```

**Uninitialized.** The Index Runtime has been created but index construction has not begun. The DIR Runtime may not yet be operational. No queries are served.

**Building.** Index families are being constructed from the DIR. Families complete in priority order. Completed families serve indexed queries; in-progress families use DIR scan fallback. Change batches arriving during construction are applied to completed families and queued for in-progress families.

**Operational.** All five index families are constructed and available. The Index Runtime serves indexed queries, processes change batches, and manages deferred Content Index updates. This is the steady state.

**Quiescing.** The application is shutting down. No new change batches are accepted. In-progress updates complete. Read queries remain available.

**Terminated.** The Index Runtime has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Uninitialized | Building | DIR Runtime operational; construction begins | Families building in priority order |
| Building | Operational | All five families constructed | All queries served from indexes |
| Operational | Building | Index family requires rebuild (FM-1, FM-3) | Rebuilding family uses fallback; others serve normally |
| Operational | Quiescing | Shutdown signal | No new change batches |
| Building | Quiescing | Shutdown signal during construction | Construction aborted; partial indexes discarded |
| Quiescing | Terminated | All in-progress updates resolved | Resources deallocated |

**Invalid transitions:** Uninitialized → Operational (must build first). Terminated → any state. Quiescing → Operational or Building (shutdown is irreversible).

**Note:** The Operational → Building transition is a partial state change — only the affected family reverts to building. Other families remain operational. The subsystem-level state is Operational if at least one family is available and no full rebuild is in progress.

### Per-Family Availability

Each index family independently tracks its availability:

```
Absent → Building → Available → Rebuilding → Available
                              → Absent (on corruption or loss)
```

**Absent.** The family has not been constructed or has been lost. Queries use DIR scan fallback.

**Building.** The family is being constructed or rebuilt. Queries use DIR scan fallback.

**Available.** The family is constructed, current, and serving indexed queries.

**Rebuilding.** The family is being rebuilt (due to inconsistency detection or explicit rebuild request). The prior index remains available for queries during rebuild. On rebuild completion, the new index atomically replaces the prior index.

---

## Index Construction and Maintenance

### Initial Construction

During startup, the Index Runtime constructs each family by scanning the relevant subset of the DIR:

**Entity Index construction.** Scan all Active and Invalidated units in the DIR. For each unit, extract the subject entity (or entities, for paired-entity subjects) and add an entry mapping the entity identifier to (unit ID, predicate, tier, status). Complexity: O(N) where N is the total unit count.

**Graph Index construction.** Scan all Active and Invalidated paired-entity units. For each, add a forward entry (source entity, predicate) → (target entity, unit ID, tier, status) and an inverse entry (target entity, predicate) → (source entity, unit ID, tier, status). This provides bidirectional traversal from unidirectional data (DAS-007 DA-7, DAS-005 R-DIR-2). Complexity: O(R) where R is the relationship unit count.

**Scope Index construction.** Scan all Active `contains` relationship units. Build the containment tree. Compute transitive closure: for each scope entity (file, module, system), record all transitively contained entities with depth. Complexity: O(R_c) where R_c is the `contains` relationship count, plus O(E) for transitive closure where E is the entity count.

**Predicate Index construction.** Scan all Active and Invalidated units. For each, add an entry mapping predicate → (unit ID, subject, tier, status, provenance.producer). Complexity: O(N).

**Content Index construction.** Scan all Active text-valued units (primarily T1 and T2). Tokenize values and build a term-to-unit mapping. Complexity: O(T) where T is the text-valued unit count, with tokenization cost proportional to total text volume.

### Incremental Maintenance

During operation, the Index Runtime receives change batches (PC-6) after each committed write transaction. Each change batch contains:

- **Units created:** new units admitted to the DIR (with subject, predicate, value, tier, status).
- **Units invalidated:** existing units whose status transitioned to Invalidated.
- **Units superseded:** existing units whose status transitioned to Superseded, with successor reference.
- **Units garbage-collected:** existing units removed from the DIR.

For each change in the batch, the Index Runtime updates the affected families:

**Unit creation.** Add index entries for the new unit in all relevant families:
- Entity Index: add entry under the unit's subject entity (or entities).
- Graph Index: if paired-entity unit, add forward and inverse entries.
- Scope Index: if `contains` relationship, update the containment tree and recompute affected transitive closures.
- Predicate Index: add entry under the unit's predicate.
- Content Index: if text-valued, enqueue for deferred term indexing.

**Unit invalidation.** Update the status field in index entries that reference the invalidated unit:
- Entity Index: update entry status to Invalidated. Entry retained (DAS-007 INV-2: Entity Index retains invalidated entries with status).
- Graph Index: update entry status. Entry retained (DAS-007: stale edge preferable to missing edge for graceful degradation).
- Predicate Index: update entry status. Entry retained (supports operational queries on stale content).
- Scope Index: if `contains` relationship, remove from containment tree immediately (DAS-007: stale containment produces incorrect scope membership).
- Content Index: enqueue for deferred removal (DAS-007: invalidated entries removed from Content Index).

**Unit supersession.** Replace the superseded unit's index entries with the successor's entries:
- Entity Index: remove superseded entry, add successor entry.
- Graph Index: if paired-entity, remove superseded forward/inverse entries, add successor entries.
- Predicate Index: remove superseded entry, add successor entry.
- Scope Index: if `contains` relationship, update containment tree.
- Content Index: enqueue superseded removal and successor addition for deferred processing.

**Unit garbage collection.** Remove all index entries referencing the collected unit across all families. This is a cleanup operation — the unit no longer exists in the DIR.

### Update Ordering

Within a change batch, index updates follow DAS-010 IM-3:

1. **Entity and Graph indexes** — updated first. These support the most latency-sensitive queries and are required for subsequent pass input assembly.
2. **Scope and Predicate indexes** — updated second. Scope updates incorporate containment changes needed for scope resolution.
3. **Content Index** — deferred. Updates are enqueued and processed asynchronously after epoch advancement.

This ordering ensures that structural indexes are fully current before the epoch advances and consumer queries observe the new state.

### Deferred Content Index Updates

The Content Index is a deferred index (DAS-010 IM-4). Its updates are processed asynchronously:

**Enqueue.** During synchronous pipeline execution, text-valued unit changes are added to a deferred update queue. The queue entries reference the affected unit identifiers and the change type (creation, invalidation, supersession, garbage collection).

**Process.** Deferred updates are processed during idle periods or when explicitly triggered. Processing involves tokenizing new text values, removing terms for invalidated or superseded units, and updating the term-to-unit mapping.

**Freshness bound.** The Content Index is never more than one execution cycle behind the DIR. After every epoch advancement, the deferred queue from the preceding cycle is processed before or during the next idle period. This bounds staleness to at most one epoch for text search results.

**Consistency.** Content Index staleness is visible to consumers. A consumer querying the Content Index is informed of the index's last-update epoch (via PC-3). The consumer can decide whether the staleness is acceptable or whether a synchronous rebuild is needed (via PC-2).

---

## Consistency Model

### Structural Index Consistency

**SC-1: Structural indexes are consistent with the DIR at every committed epoch.** After a synchronous pipeline completes and the epoch advances (DDS-002:PC-4), the Entity, Graph, Scope, and Predicate indexes reflect the DIR state at the new epoch. No structural index entry references a superseded or garbage-collected unit. No Active unit matching a query is missing from the index.

**SC-2: Cross-family consistency.** A query that spans multiple structural index families (e.g., Scope Index to find entities in a module, then Entity Index to retrieve those entities' units) observes a consistent DIR state across both families. Both families reflect the same committed epoch. This is guaranteed by the synchronous update model: all structural indexes are updated from the same change batch before epoch advancement.

**SC-3: Within-pipeline index visibility.** During synchronous pipeline execution, structural index updates from a change batch are visible to subsequent queries within the same pipeline. This parallels within-cycle visibility for DIR reads (DDS-002:PC-3(b)): a pass that executes after a prior pass can query indexes that reflect the prior pass's committed output.

### Content Index Consistency

**CC-1: The Content Index is eventually consistent with the DIR.** After a change batch is committed, the Content Index may not reflect the changes until the deferred update queue is processed. The Content Index lags the DIR by at most one epoch.

**CC-2: Content Index staleness is visible.** The Index Runtime reports the Content Index's last-update epoch via PC-3. Consumers can compare this against the current committed epoch to determine whether search results may be stale.

### Within-Update Query Isolation

**SC-4: Cross-family consistency is guaranteed only before and after a Batch Index Update (PC-4).** During execution of PC-4, the Index Runtime updates structural index families sequentially (Entity/Graph, then Scope/Predicate per Update Ordering). Between these sequential family updates, some families reflect the new change batch while others do not. The Index Runtime does not expose this partially-updated state to consumers for the current epoch — consumer queries continue to observe the prior committed epoch until PC-4 returns and the epoch advances. This preserves RI-5 (cross-family consistency) and protects future parallel execution of PC-4 internals. No consumer query observes a mix of pre-update and post-update index state within a single epoch.

### Fallback Consistency

**FC-1: DIR scan fallback preserves epoch consistency.** When an index family is unavailable and queries fall back to DIR scan (via DDS-002:PC-3), the scan observes the same committed epoch that indexed queries would observe. Fallback does not change consistency — it changes performance.

---

## Memory and Ownership

### Owned Resources

**Index structures.** The Index Runtime exclusively owns the in-memory data structures for all five index families. No other subsystem directly reads or writes index structures. All access is mediated through the public contracts (PC-1 through PC-4).

**Deferred update queue.** The Index Runtime owns the queue of pending Content Index updates. The queue is in-memory, session-scoped, and discarded on shutdown.

**Per-family metadata.** The Index Runtime owns the per-family availability state, last-update epoch, stale entry count, and rebuild history.

### Borrowed Resources

**DIR content (read).** The Index Runtime borrows DIR content via PC-5 for the duration of index construction, rebuild, and fallback queries. The borrowed content is immutable (DDS-002 immutability model) and remains valid for the duration of the read.

### Shared Resources

None. The Index Runtime does not share mutable state with any other subsystem. All interactions are through contracts.

### Memory Bounds

**Entity Index:** Proportional to the total number of units. Each entry stores (entity ID, unit ID, predicate ID, tier, status) — estimated ~40 bytes per entry. At alpha scale (~300,000 units): ~12 MB. At practical limit (~6,000,000 units): ~240 MB.

**Graph Index:** Proportional to the number of relationship units. Each relationship produces two entries (forward + inverse) — estimated ~50 bytes per entry pair. At alpha scale (~50,000 relationships): ~5 MB. At practical limit (~1,000,000 relationships): ~100 MB.

**Scope Index:** Proportional to the number of entities in the containment tree, with transitive closure expansion. At alpha scale (~10,000 entities, average depth 3): ~2 MB. At practical limit (~200,000 entities): ~40 MB.

**Predicate Index:** Proportional to the total number of units. Each entry stores (predicate ID, unit ID, subject, tier, status, producer ID) — estimated ~50 bytes per entry. At alpha scale: ~15 MB. At practical limit: ~300 MB.

**Content Index:** Proportional to the number of text-valued units and the total text volume. At alpha scale (~4,000 T2 text units, ~1 KB average text): ~8 MB for term mappings. At practical limit (~80,000 T2 text units): ~160 MB.

**Total at alpha scale:** ~42 MB. **Total at practical limit:** ~840 MB. These estimates align with DAS-012 DA-2 (~600 MB indexes at practical limit).

**Deferred update queue:** Proportional to the number of text-valued unit changes per epoch. At alpha scale: negligible (<1 KB per epoch).

### Eviction

Index structures are session-scoped and released on shutdown. No explicit eviction policy is needed — all resources are transient (DAS-012 I3). Within a session, index entries for garbage-collected units are removed when the garbage collection change batch is processed (R3).

---

## Runtime Invariants

```
RI-1: Index Derivability
  Statement:   Every index entry is derivable from the DIR. No index
               contains information that cannot be reconstructed from the
               current DIR state.
  Rationale:   If an index accumulates non-derivable state, it becomes a
               shadow store that can diverge from the DIR (DAS-007 I1).
               Derivability guarantees that indexes can be destroyed and
               rebuilt without consequence.
  Verification: Delete each index family. Rebuild from the DIR. Confirm
               that the rebuilt index is functionally identical to the
               original.

RI-2: DIR Authority
  Statement:   When an index entry and the DIR disagree, the DIR is
               authoritative. The index entry must be corrected or the
               index rebuilt. No query result may be based on index state
               that contradicts the DIR.
  Rationale:   DAS-001 P1 — intelligence is the canonical asset. Indexes
               are derived views. Contradictory index results lead to
               incorrect consumer decisions (DAS-007 I2).
  Verification: Introduce a controlled inconsistency. Confirm the system
               detects it and resolves in favor of the DIR.

RI-3: No Index Writes to DIR
  Statement:   No index operation produces, modifies, or deletes atomic
               units in the DIR. Data flows from DIR to indexes, never
               from indexes to DIR.
  Rationale:   Indexes are query optimizations, not knowledge producers.
               If indexes could write to the DIR, they would become
               producers subject to the pass contract (DAS-007 I3).
  Verification: Audit all index operations. Confirm no operation creates,
               modifies, or deletes DIR content.

RI-4: Structural Index Epoch Consistency
  Statement:   At every committed epoch, every structural index (Entity,
               Graph, Scope, Predicate) is consistent with the DIR. No
               structural index entry references a superseded or garbage-
               collected unit. No Active unit matching a query's criteria
               is absent from the index.
  Rationale:   Inconsistent structural indexes produce incorrect query
               results — missing entities, phantom relationships, wrong
               scope membership. This violates DAS-010 I7.
  Verification: At each epoch, compare structural index contents against
               DIR contents for a representative sample. Confirm bijection
               between Active units and their index entries.

RI-5: Cross-Family Consistency
  Statement:   A query spanning multiple structural index families
               observes a single consistent DIR state across all families.
               No cross-family query observes a mix of epochs.
  Rationale:   DAS-007 I4 — consistent snapshots. A scope query that
               returns entities at epoch N+1 followed by an entity query
               returning units at epoch N produces an inconsistent result.
  Verification: Issue cross-family queries during change batch processing.
               Confirm results are epoch-consistent.

RI-6: Graceful Absence
  Statement:   The absence of any index family does not prevent queries
               from returning correct results. Every query servable by an
               index can also be answered by DIR scan.
  Rationale:   DAS-007 I6, DAS-001 P12 — index failure degrades
               performance, not correctness.
  Verification: Remove each family individually. Confirm all queries
               return correct results via DIR scan fallback.

RI-7: Bounded Rebuild
  Statement:   Every index family can be rebuilt in time proportional to
               the size of its source data — not the full DIR or the
               index's age.
  Rationale:   DAS-007 I5 — unbounded rebuild makes recovery
               unpredictable. Bounded rebuild ensures recovery time is
               proportional to affected data.
  Verification: Measure rebuild time per family. Confirm linear scaling
               with source data size.

RI-8: Content Index Bounded Staleness
  Statement:   The Content Index is never more than one execution cycle
               behind the DIR. Deferred updates from the preceding cycle
               are processed before or during the next idle period.
  Rationale:   Unbounded Content Index staleness produces search results
               that are arbitrarily stale — degrading from "slightly
               outdated" to "useless." A one-epoch bound keeps the
               Content Index useful for discovery.
  Verification: Track the Content Index's last-update epoch. Confirm it
               is never more than one epoch behind the committed epoch.
```

---

## Failure Handling

```
FM-1: Index Inconsistency Detected
  Trigger:     A structural index entry references a unit that does not
               exist in the DIR (dangling reference), or a DIR unit
               that should be indexed is missing from the index.
  Detection:   Detected during query processing (a returned unit ID
               cannot be resolved via DDS-002:PC-5), during change batch
               processing (an expected entry is absent), or during
               periodic consistency verification.
  Response:    The inconsistent family is marked for rebuild. The family
               enters Rebuilding state. During rebuild, queries for that
               family use DIR scan fallback (PC-1 graceful degradation).
               Other families are unaffected. The rebuild is triggered
               immediately (not deferred).
  Caller observes: Queries against the rebuilding family return correct
               results via fallback, with a notification that fallback
               is in effect. The freshness report (PC-3) reflects the
               family's Rebuilding state.
  Recovery:    Rebuild completes and the family re-enters Available state.
               The fresh index atomically replaces the prior index.

FM-2: Index Family Lost
  Trigger:     An index family's data structure is entirely lost (memory
               corruption, unexpected deallocation).
  Detection:   The family's data structure is null or inaccessible.
  Response:    The family enters Absent state. Queries use DIR scan
               fallback. The family is scheduled for rebuild at its
               priority level (DAS-007 IFR-4: Entity first, Content
               last).
  Caller observes: Queries return correct results via fallback. The
               freshness report reflects the Absent state.
  Recovery:    Same as FM-1 — rebuild from DIR.

FM-3: Index Staleness Detected
  Trigger:     A structural index's last-update epoch is behind the
               DIR's committed epoch after an epoch advancement that
               should have included index updates.
  Detection:   Epoch comparison after epoch advancement. If the index's
               last-update epoch < committed epoch and the index was
               expected to be updated (change batch was delivered), the
               index is stale.
  Response:    If the staleness gap is one epoch (the most recent change
               batch was missed), the Index Runtime requests redelivery
               of the change batch from the scheduling subsystem. If the
               gap is larger or redelivery is unavailable, the family is
               rebuilt from the DIR (FM-1 handling).
  Caller observes: During repair, queries use fallback or the stale
               index (depending on whether the staleness is acceptable
               to the caller — structural index staleness is not
               acceptable, so fallback is used).
  Recovery:    Incremental catch-up (if change batch redelivered) or
               full rebuild.

FM-4: DIR Runtime Unavailable During Rebuild
  Trigger:     The DIR Runtime becomes unavailable (Quiescing or
               Terminated) while an index family is being rebuilt.
  Detection:   DIR read (PC-5) fails or returns no results.
  Response:    The rebuild is aborted. The family retains its prior
               state (if any) or remains Absent. No partial index is
               constructed.
  Caller observes: Queries continue using fallback or the prior index.
  Recovery:    When the DIR Runtime becomes operational again, the
               rebuild is retried. If the application is shutting down,
               no retry occurs (indexes are ephemeral — DAS-012 I3).

FM-5: Change Batch Processing Error
  Trigger:     An error occurs while processing a change batch for a
               specific family (e.g., unexpected unit structure, internal
               data structure error).
  Detection:   Error during the update operation for one family.
  Response:    The failing family is marked for rebuild (FM-1 handling).
               Other families' updates from the same change batch
               complete normally. Structural indexes that updated
               successfully are consistent; the failing family falls
               back to DIR scan.
  Caller observes: The caller (scheduling subsystem) is notified that
               one family failed. The epoch may still advance — consumer
               queries for the failing family use fallback.
  Recovery:    Rebuild of the failing family.
```

---

## Performance Requirements

Performance requirements are classified as follows:

- **Architectural requirement** — a bound mandated by DAS invariants or freshness contracts. Violation breaks an architectural guarantee.
- **Engineering target** — an initial numeric bound based on expected workload and reasoning, not yet validated by measurement. Must be validated through benchmarking before promotion to firm requirements.

```
PR-1: Startup Index Construction
  Operation:   Construction of all five index families from the DIR
  Category:    Architectural requirement (startup latency);
               engineering target (numeric bound)
  Bound:       Upper bound 1 second at alpha scale (~300,000 units);
               upper bound 15 seconds at practical limit (~6,000,000
               units)
  Assumptions: DIR content in memory (DDS-002). Sequential construction
               in priority order.
  Rationale:   DAS-012 C2 specifies startup budget: snapshot load +
               index rebuild + reconciliation < 2 seconds at alpha,
               < 15 seconds at practical limit. Index construction
               must fit within this budget. Validate by benchmarking
               construction at representative unit counts.

PR-2: Structural Index Update Latency
  Operation:   Update all four structural indexes for a single change
               batch
  Category:    Architectural requirement (synchronous pipeline bound);
               engineering target (numeric bound)
  Bound:       Upper bound 5ms per change batch (initial target)
  Assumptions: Change batch ≤ 500 units (a single producer's output
               batch per DDS-001 Memory Bounds). Incremental update
               per family is O(batch size).
  Rationale:   Structural index updates are on the synchronous pipeline
               critical path — they must complete before epoch
               advancement (DAS-010 IM-1). At 5ms per change batch and
               ~10 batches per execution cycle, total index update time
               is ~50ms. Combined with DDS-001 and DDS-003 pipeline
               budgets, this keeps total synchronous pipeline latency
               within interactive bounds. Validate by benchmarking
               updates at the upper bound of expected batch size.

PR-3: Index Query Latency
  Operation:   Single index query (entity lookup, graph traversal,
               scope membership, predicate query)
  Category:    Engineering target
  Bound:       Upper bound 1ms per query (initial target)
  Assumptions: O(1) hash-based lookup for entity and predicate queries.
               O(degree) for graph traversal. O(scope size) for scope
               membership. Index structures in memory.
  Rationale:   Index queries are on the retrieval critical path.
               Interactive latency requires sub-millisecond index access
               to leave room for retrieval processing, context assembly,
               and AI invocation. Validate by benchmarking representative
               queries at alpha scale.

PR-4: Content Index Query Latency
  Operation:   Single content search query (term lookup)
  Category:    Engineering target
  Bound:       Upper bound 10ms per query (initial target)
  Assumptions: Inverted index structure. O(matching terms) lookup.
               Index in memory.
  Rationale:   Content search is less latency-sensitive than structural
               queries (DAS-007 DA-4). Consumers performing content
               search tolerate higher latency than consumers performing
               entity lookup. Validate by benchmarking term search at
               alpha scale with representative text volumes.

PR-5: Index Rebuild Latency
  Operation:   Rebuild of a single index family from the DIR
  Category:    Engineering target
  Bound:       Entity Index: upper bound 500ms at alpha scale.
               Graph Index: upper bound 200ms. Scope Index: upper bound
               100ms. Predicate Index: upper bound 500ms. Content Index:
               upper bound 1 second.
  Assumptions: Same as PR-1. Single-family rebuild is proportional to
               the family's source data size, not the full DIR.
  Rationale:   DAS-007 IFR-7 — bounded rebuild. During rebuild, queries
               use DIR scan fallback. Rebuild must complete quickly to
               minimize the fallback window. Validate by benchmarking
               per-family rebuild at alpha scale.

PR-6: Index Memory
  Operation:   Total memory consumption for all five index families
  Category:    Engineering target
  Bound:       Upper bound 50 MB at alpha scale; upper bound 1 GB at
               practical limit
  Assumptions: Per-family estimates from Memory Bounds section.
  Rationale:   DAS-012 DA-2 estimates ~600 MB for indexes at the
               practical limit. The 1 GB upper bound provides margin
               for implementation overhead. At alpha scale, 50 MB is
               a small fraction of available system memory. Validate
               by measuring actual memory consumption at representative
               unit counts.
```

---

## Observability

The Index Runtime emits the following observable information:

**Index Size (DAS-007 IOB-1).** For each family: number of entries, approximate memory footprint in bytes. Queryable on demand.

**Index Freshness (DAS-007 IOB-2).** For each family: last-update epoch, stale entry count (entries referencing invalidated or superseded units not yet reflected — applicable to Content Index; always zero for structural indexes at the committed epoch), availability state (Available, Building, Rebuilding, Absent).

**Index Query Performance (DAS-007 IOB-3).** For each family: total query count since startup, average query latency (rolling window), tail query latency (p99 rolling window), DIR scan fallback count (queries served by fallback instead of index).

**Index Rebuild History (DAS-007 IOB-4).** For each family: last rebuild timestamp, last rebuild duration, rebuild trigger (startup, inconsistency, explicit request, staleness detection).

**Change Batch Processing Metrics.** For each change batch processed: batch size (units), per-family update duration, total update duration, families that failed (if any).

**Content Index Deferred Queue.** Current queue depth (pending deferred updates), average processing latency.

**Overhead.** Observability data collection does not block index updates or query processing. Metrics are collected as side effects of normal operations (timestamps at update boundaries, counters incremented during queries), not as separate processing steps.

---

## Testing Requirements

**Construction tests (R2):**
- On startup with a populated DIR, all five index families are constructed.
- Index construction follows priority order (Entity first, Content last).
- Queries against a completed family return correct results during construction of other families.
- Queries against an in-progress family use DIR scan fallback.
- After construction, all structural indexes are consistent with the DIR.

**Incremental update tests (R3):**
- A new unit creation adds entries to the appropriate index families.
- A new paired-entity unit adds both forward and inverse entries to the Graph Index.
- A new `contains` relationship updates the Scope Index containment tree.
- A unit invalidation updates entry status in Entity, Graph, and Predicate indexes.
- A unit invalidation removes the entry from the Scope Index (for `contains` relationships).
- A unit supersession replaces entries across all relevant families.
- A garbage collection removes entries from all families.
- Update ordering follows DAS-010 IM-3 (Entity/Graph first, Scope/Predicate second, Content deferred).

**Query consistency tests (R4):**
- A structural index query returns results consistent with the DIR at the committed epoch.
- A cross-family query (Scope + Entity) returns epoch-consistent results.
- A query during change batch processing returns results from the committed epoch (prior to the in-progress changes).
- A Content Index query returns results from its last-update epoch (may be one epoch behind).

**Freshness tests (R5):**
- After a change batch including T0 unit changes, structural indexes reflect the changes before epoch advancement.
- After a change batch including T2 text-valued unit changes, the Content Index update is deferred.
- The Content Index is updated within one epoch of the deferred change.
- The freshness report (PC-3) accurately reflects each family's last-update epoch and availability state.

**Graceful degradation tests (R7):**
- With one index family absent, queries for that family return correct results via DIR scan.
- With all index families absent, all queries return correct results via DIR scan.
- The caller is notified when DIR scan fallback is in effect.
- An absent family is rebuilt from the DIR. After rebuild, queries use the index.

**Failure mode tests (FM-1 through FM-5):**
- An inconsistent index (dangling reference) is detected and triggers rebuild.
- A lost index family enters Absent state; queries use fallback; rebuild is scheduled.
- A stale structural index triggers catch-up or rebuild.
- A DIR Runtime unavailability during rebuild aborts the rebuild cleanly.
- A change batch processing error for one family does not affect other families.

**Rebuild tests:**
- Rebuild of each family produces an index identical to initial construction.
- Rebuild of one family does not affect other families' availability.
- During rebuild, queries for the rebuilding family use DIR scan fallback.
- Rebuild completes within the performance bounds (PR-5).

**Integration tests:**
- A multi-pass execution cycle where pass A produces output, structural indexes are updated, and pass B's input assembly uses the updated indexes: B's scope resolution reflects A's containment changes.
- A deterministic pass producing "no change" output: indexes are not redundantly updated (change batch contains no changes, so index update is a no-op).
- A semantic pass failure during pipeline: indexes reflect the prior T2 state (invalidated entries retained with status in Entity and Graph indexes, removed from Content Index).
- Application startup with no snapshot (first launch): indexes are constructed from an empty DIR; as the full rebuild populates the DIR, indexes are constructed from the populated state.

---

## Future Evolution

**Module Intelligence (DAS Roadmap Phase 2).** As Module Intelligence matures, composition passes will create module-level entities and `contains` relationships. The Scope Index will grow with new containment entries. The Graph Index will grow with cross-module relationship edges. The Index Runtime's architecture is entity-type-agnostic — it indexes units by their structural properties (subject, predicate, containment), not by the entity types they reference. No architectural changes are needed for Module Intelligence.

**Project Intelligence (DAS Roadmap Phase 3).** System-level entities and system-wide scope queries will increase the Scope Index's transitive closure size. At system scope, the Scope Index contains all entities — effectively a full entity list. Performance optimization (lazy transitive closure computation, scope-level caching) may be needed. The architecture supports this as an implementation optimization within the Scope Index family, not as a structural change.

**Persistent Indexes (DAS-012 Q1).** At scale beyond 10K files (~1.2 GB DIR), ephemeral indexes with startup rebuild may exceed the startup latency budget. The natural evolution is to persist selected index families (Entity, Graph) across restarts, with startup validation against the DIR. This changes the lifecycle model (R2 becomes "load and validate" instead of "build from scratch") but does not change the contracts, consistency model, or failure handling — persistent indexes that fail validation trigger rebuild, just as ephemeral indexes do.

**Content Index Structured Queries (DAS-007 Q2).** The current Content Index supports term-based search. Structured queries (conjunction over multiple predicates) could be supported by adding cross-predicate term intersection within the Content Index. This is an implementation enhancement within the Content family, not a new index family.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial draft
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions: PC-4 precondition
      accepts change batches during Building/Operational with per-family behavior;
      SC-4 within-update query isolation guarantee added
```
