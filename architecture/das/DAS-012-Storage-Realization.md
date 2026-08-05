# DAS-012: Storage Realization

```
Chapter:       DAS-012
Title:         Storage Realization
Status:        Frozen
Version:       0.1
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-006, DAS-007, DAS-010
Depended By:   —
Supersedes:    —
Superseded By: —
Layer:         L5
```

## Abstract

This chapter defines how the Decode Intermediate Representation (DIR), its five index families, update epochs, pass state, and lifecycle management are physically realized in storage. It selects a single-process, in-memory-primary architecture with epoch-aligned snapshot persistence for the DIR and ephemeral in-memory indexes. It introduces no new abstractions — every concept realized here is defined in DAS-001 through DAS-011. This is the only L5 chapter in the DAS.

## Motivation

The logical architecture (DAS-001 through DAS-011) defines *what* the DIR stores, *how* it is queried, *when* it is updated, and *what* invariants it must satisfy. But it deliberately defers all physical realization decisions: where does the DIR live? How does it persist across process restarts? How are indexes maintained in memory or on disk? How are epochs tracked? How is garbage collection scheduled? How does the system recover from a crash?

Without this chapter, five problems arise:

1. **The DIR has no physical home.** DAS-002 defines the DIR as a collection of atomic units with a rich contract. But a "collection" is not a data structure. Is it a hash map keyed by unit ID? A set of tables keyed by (subject, predicate)? A graph? An embedded database? The logical architecture cannot answer this — the answer depends on access patterns (DAS-007), update patterns (DAS-010), and scale assumptions that the logical architecture intentionally avoids.

2. **Persistence is undefined.** DAS-002 DC-5 states that the DIR is rebuildable from source, but T2 units are expensive to rebuild (each requires an AI invocation). A restart that discards T2 content and rebuilds it would cost ~1,000 AI calls for a 1,000-file codebase. The logical architecture permits both persistent and ephemeral storage — this chapter must choose.

3. **Epoch management has no mechanism.** DAS-010 WR-1 through WR-5 define epoch-based consistency as a logical model. But a monotonically increasing counter needs a physical location, an advancement mechanism, and a coordination strategy. Without defining these, epoch-based consistency is aspirational.

4. **Index persistence is undecided.** DAS-007 defines five index families as derived, rebuildable structures. But "rebuildable" does not mean "should be rebuilt on every restart." Some indexes are cheap to rebuild (Scope Index — from `contains` relationships). Others are more expensive (Content Index — from all text-valued units). The persistence decision is per-family.

5. **Garbage collection is unpolicied.** DAS-010 GC-1 through GC-4 define eligibility but defer implementation. Without a concrete retention policy, superseded units accumulate indefinitely.

**Source dependencies:**
- [DAS-001](DAS-001-Architectural-Principles.md) — P1 (intelligence is the canonical asset), P9 (incremental by design), P12 (graceful degradation)
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — atomic unit contract (10 fields), lifecycle (Active/Invalidated/Superseded), DIR completeness (I1), immutability (I2), grounding (I3), rebuildability (DC-5)
- [DAS-003](DAS-003-Tier-Model.md) — T0/T1/T2 freshness contracts, tier-informed GC retention (TL-3), supersession tier constraint (TL-2)
- [DAS-006](DAS-006-Pass-Architecture.md) — pass registrations, pass DAG, pass execution state
- [DAS-007](DAS-007-Index-Architecture.md) — five index families, derivability (I1), rebuild priority, freshness model
- [DAS-010](DAS-010-Incremental-Update-Model.md) — epoch-based consistency (WR-1 through WR-5), change set atomicity (I4), sequential processing (I8), index-DIR consistency (I7), grounding-chain cascade (IP-4), GC policy (GC-1 through GC-4)

## Terminology

**Snapshot** — A serialized representation of the complete DIR state at a specific epoch, written to persistent storage. A snapshot contains all active and invalidated atomic units, the current epoch counter, and sufficient metadata to restore the DIR to the snapshotted state on process restart. A snapshot is not a backup — it is the persistence mechanism. *Is:* the DIR state at epoch 42 serialized to disk after the synchronous pipeline completes. *Is not:* a diff, a log, or a partial state. `INTRODUCED`

**Reconciliation** — The process of bringing a snapshot-restored DIR into consistency with the current source state after a process restart. Reconciliation compares each tracked file's current content hash against the content hash recorded in the snapshot. Files with changed hashes are processed as a change set. *Is:* "snapshot was at epoch 42; files A and B changed since then; process change set for A and B to reach epoch 43." *Is not:* a full rebuild; a replay of missed change events. `INTRODUCED`

**Dependency Map (storage-internal)** — A reverse lookup structure that maps a unit identifier to the set of units whose `provenance.inputs` field references it. This structure supports the invalidation cascade traversal required by DAS-010 IP-4. It is derived from the DIR's provenance records, rebuilt on startup, and maintained incrementally during operation. *Is:* an internal storage optimization that makes "find all units grounded in unit U" an O(degree) operation. *Is not:* a DAS-007 index family (it serves the update model, not consumer retrieval). `INTRODUCED`

**Unit Store** — The physical data structure that holds all atomic units during operation. The unit store is the in-memory realization of the DIR. All queries against the DIR read from the unit store. All producers (frontends, passes) write to the unit store. *Is:* the runtime representation of the DIR in process memory. *Is not:* a database, a file, or a persistent store — persistence is handled by snapshots. `INTRODUCED`

**Scale Envelope** — The range of codebase sizes for which a storage realization is designed. The scale envelope defines the expected unit counts, memory footprint, and performance characteristics. A realization that exceeds its scale envelope may degrade in performance but must not violate invariants. `INTRODUCED`

---

## Domain Analysis

**DA-1: Decode is a single-user desktop application operating on one codebase at a time.** Decode runs as a native macOS process on the developer's machine. There is no server-side DIR. There is no multi-user access. There is no cross-machine replication. The DIR exists within a single process, accessed by a single thread of control for writes (the synchronous pipeline per DAS-010 I8) and potentially concurrent threads for reads (consumer queries). This is the foundational physical constraint that the logical architecture leaves open.

**DA-2: The DIR's size is bounded by the codebase it represents.** A file produces approximately 20 entities with ~15 predicates each = ~300 atomic units. Relationship units add ~2-5x for well-connected codebases. At 1,000 files: ~300,000-600,000 units. At 10,000 files: ~3,000,000-6,000,000 units. Each unit carries ~100-300 bytes of payload (subject reference, predicate ID, typed value, tier, provenance record, grounding chain, version stamp, status). At 200 bytes average: 1,000 files ≈ 60-120 MB; 10,000 files ≈ 600 MB-1.2 GB. These are in-memory-feasible sizes for a modern macOS system with 16-64 GB of RAM.

**DA-3: The DIR's write pattern is bursty; its read pattern is interactive.** Writes occur during change set processing: a developer saves a file, the synchronous pipeline fires, hundreds of units are created/invalidated/superseded in a burst of milliseconds. Between bursts, no writes occur. Reads occur when the developer presses a hotkey: the retrieval system queries the DIR through indexes, assembles context, and delivers understanding. Read latency directly affects perceived responsiveness — sub-10ms for index lookups, sub-100ms for full retrieval. Write throughput directly affects update latency — the synchronous pipeline must complete before the epoch advances and queries can see the new state.

**DA-4: Process lifecycle is bounded by the developer's work session.** Decode launches when the developer starts working and exits when they stop (or when the system restarts). Typical session: 1-12 hours. Between sessions, source files may change (the developer uses a different editor, switches branches, pulls changes). The DIR must handle the gap between last snapshot and current source state on every launch.

**DA-5: The T2 cost asymmetry dominates the persistence decision.** T0 units are cheap to produce: re-parsing a file takes milliseconds. T1 units are cheap to produce: rule application over T0 facts takes milliseconds. T2 units are expensive to produce: each file's semantic enrichment requires an AI API call taking 1-5 seconds and consuming API budget. A 1,000-file codebase with full T2 enrichment represents ~1,000 AI calls. Losing T2 content on restart and rebuilding it would cost ~$0.50-2.00 in API fees and ~15-80 minutes of wall time. This cost asymmetry makes T2 persistence mandatory, even though T0 and T1 could be economically rebuilt.

**DA-6: Content-hash-based change detection (DAS-010 CD-1) determines the reconciliation strategy.** Every unit records the content hash of the source it was derived from (DAS-002 I-VER-3). On restart, the system can compare each tracked file's current content hash against the hash in the snapshot. Files with matching hashes need no reprocessing. Files with changed hashes are processed as a standard change set. This makes reconciliation equivalent to processing a change set of "files that changed while the process was down" — using the same machinery as normal incremental updates.

**DA-7: The epoch counter's physical requirements are minimal.** DAS-010 defines the epoch as a monotonically increasing counter. In a single-process architecture, the epoch is a single integer in memory. It is incremented exactly once per change set completion (DAS-010 WR-3). It must survive process restart (persisted in the snapshot). No coordination protocol is needed — there is only one writer.

---

## Candidates

The foundational architectural question is: **what storage topology should the DIR, indexes, and supporting structures use?**

This question decomposes into two orthogonal decisions: (1) where does the DIR live during operation (the primary store), and (2) how does the DIR survive process restart (the persistence model). The candidates below address both.

### Candidate A: No Persistence (Memory-Only, Rebuild on Restart)

The DIR lives entirely in process memory. On restart, the DIR is rebuilt from source: all files are re-parsed (T0), all passes re-execute (T1), and T2 enrichment is scheduled as if no prior enrichment existed.

**Implications:** Zero persistence complexity. No snapshot format. No reconciliation logic. The system starts fresh every session.

**Strengths:** Maximum simplicity. No corruption risk (nothing persisted). No schema evolution concern (no stored state to migrate). Implementation is trivial.

**Weaknesses:** T2 rebuild cost is prohibitive (DA-5). A 1,000-file codebase requires ~1,000 AI calls on every application launch. At alpha pricing, this is $0.50-2.00 per restart — several times per day during development. T2 enrichment takes minutes, during which the user has no semantic intelligence. Additionally, T0/T1 rebuild for large codebases takes seconds to tens of seconds, introducing a visible startup delay even before T2.

**Disqualifying condition:** T2 rebuild cost violates practical usability. DAS-001 P12 (graceful degradation) means the system would function without T2 — but requiring developers to wait for re-enrichment on every launch is a product failure, not a graceful degradation.

### Candidate B: In-Memory Primary with Epoch-Aligned Snapshot Persistence

The DIR lives in process memory during operation. On each epoch advance (DAS-010 WR-3), the DIR state is serialized to a persistent snapshot file. On restart, the snapshot is loaded into memory and reconciled with the current source state.

**Implications:** All runtime operations (queries, updates, index maintenance) operate on in-memory data structures at memory-access speed. Persistence is a write-behind concern — the snapshot captures the DIR state after each consistent epoch transition. Crash recovery loses at most the in-progress change set (which is reprocessable from source).

**Strengths:** Maximum read/write performance (in-memory). Straightforward persistence (serialize/deserialize). Crash recovery is well-defined (load last snapshot, reconcile). T2 content survives restart. Snapshot writes can be asynchronous (write the snapshot while the next change set is being aggregated) as long as the prior epoch's state is captured before it is overwritten.

**Weaknesses:** Memory footprint scales with DIR size. At 10,000 files (~600 MB-1.2 GB), the footprint is significant but feasible. Snapshot writes introduce I/O on every epoch advance — at ~60 MB for a 1,000-file codebase, snapshot write time is ~10-50 ms to SSD. Snapshot format must be defined and versioned for schema evolution.

**Disqualifying condition:** None identified. Memory footprint is within the scale envelope.

### Candidate C: Embedded Database as Primary Store

The DIR is stored in an embedded relational database (e.g., SQLite). All reads and writes go through the database. Indexes are database indexes. Epochs are database transactions.

**Implications:** The database handles persistence, query optimization, transaction atomicity, and crash recovery. The DIR is stored as database rows. Indexes are database indexes. Epoch advancement is a database transaction commit.

**Strengths:** Persistence and crash recovery handled by the database engine. ACID transactions provide atomic epoch advancement. SQL provides a flexible query language for DIR access patterns. Schema evolution is manageable through database migrations.

**Weaknesses:** Query latency is higher than in-memory access. A hash-map lookup in memory is ~50 ns; a SQLite indexed query is ~50-500 µs — three orders of magnitude slower. The DIR's read pattern (interactive, latency-sensitive) is poorly served by database round-trips. The DIR's write pattern (burst of hundreds of units during change set processing) generates significant database I/O. The database engine adds complexity: connection management, schema definition, migration tooling, query optimization. The atomic unit contract (10 fields with complex types — grounding chains, provenance records) maps awkwardly to relational schemas.

**Disqualifying condition:** Interactive latency requirements (DA-3). A retrieval query that touches the Entity Index and Graph Index involves multiple database queries. At ~100 µs per query and ~5-10 queries per retrieval, retrieval latency is ~0.5-1 ms from the database alone — before context assembly, before AI invocation. This is acceptable but leaves no headroom. More critically, the synchronous pipeline (DAS-010 RS-1 through RS-4) must complete within milliseconds. Writing hundreds of units to a database during change set processing introduces I/O latency that extends the pipeline window. The in-memory candidate achieves the same correctness with better latency.

### Candidate D: In-Memory Primary with Write-Ahead Log (WAL)

The DIR lives in memory. Every mutation (unit creation, status transition) is appended to a write-ahead log on disk. On restart, the log is replayed to reconstruct the DIR state. Periodic compaction reduces log size.

**Implications:** Every write is durable — no data loss even on crash mid-change-set. Log replay reconstructs exact state. Compaction is equivalent to snapshot creation.

**Strengths:** Zero data loss on crash (every mutation is logged before being applied). Fine-grained durability (per-mutation, not per-epoch). More durable than snapshot persistence.

**Weaknesses:** Write amplification: every unit creation, invalidation, and supersession writes to both memory and disk. During change set processing (hundreds of mutations in milliseconds), the WAL receives hundreds of sequential writes. The I/O cost is small per write (~1 µs for buffered append) but cumulative during bursts. Log replay on restart is slower than snapshot loading: replaying 100,000 mutations is slower than deserializing 100,000 units from a snapshot. Compaction adds complexity (must coordinate with change set processing). The fine-grained durability exceeds what the architecture requires: DAS-010 I4 requires atomic change set processing, not per-mutation durability. Losing an in-progress change set is acceptable (it is reprocessed from source).

**Disqualifying condition:** Over-engineering. The architecture requires epoch-level durability (DAS-010 WR-3: epoch advances atomically). Per-mutation durability provides stronger guarantees than needed, at higher implementation and I/O cost. Candidate B provides epoch-level durability with less complexity.

## Evaluation

Criteria are derived from the domain analysis and the logical architecture's requirements:

| Criterion | No Persistence (A) | Snapshot (B) | Embedded DB (C) | WAL (D) |
|-----------|-------------------|-------------|-----------------|---------|
| T2 survival across restart (DA-5) | **No** | **Yes** | **Yes** | **Yes** |
| Interactive read latency (DA-3) | **Optimal** (memory) | **Optimal** (memory) | Acceptable (database) | **Optimal** (memory) |
| Synchronous pipeline throughput (DAS-010 RS-4) | **Optimal** (memory) | **Optimal** (memory) | Degraded (database I/O) | Good (memory + buffered append) |
| Crash recovery correctness | Trivial (rebuild) | **Correct** (snapshot + reconciliation) | **Correct** (DB recovery) | **Correct** (log replay) |
| Implementation complexity | Trivial | **Low** | Moderate-High | Moderate |
| Durability granularity | None | Epoch-level | Per-transaction | Per-mutation |
| Durability exceeds requirements? | N/A | **No** — matches DAS-010 | **No** — matches | **Yes** — over-engineers |
| Scale envelope (DA-2) | Unlimited | **10K files / ~1 GB** | Larger (disk-backed) | **10K files / ~1 GB** |

Candidate A is disqualified by T2 rebuild cost. Candidate C provides acceptable but not optimal latency and adds unnecessary complexity at alpha scale. Candidate D over-engineers durability beyond what the epoch model requires.

Candidate B satisfies every requirement at minimum complexity: in-memory for performance, snapshot for durability, reconciliation for crash recovery. Its scale envelope (up to ~10K files in memory) matches Decode's stated progression through Module Intelligence and into Project Intelligence.

## Decision

**The DIR, all indexes, and all supporting structures reside in process memory during operation. The DIR is persisted via epoch-aligned snapshots. Indexes are ephemeral — rebuilt from the DIR on startup. On restart, the snapshot is loaded and reconciled with the current source state.**

This realization satisfies every upstream invariant:
- **DAS-002 I1 (DIR completeness):** All persistent state is DIR content or derived. The snapshot persists DIR content; indexes are derived and rebuilt.
- **DAS-002 I2 (immutability):** In-memory units are immutable structures. Status transitions produce new status values, not in-place mutations.
- **DAS-007 I1 (index derivability):** Indexes are ephemeral — rebuilt from the DIR on every startup. This is the strongest possible expression of derivability.
- **DAS-010 I4 (change set atomicity):** In-memory epoch advancement is a single counter increment. Snapshot persistence captures the committed state.
- **DAS-010 I7 (index-DIR consistency):** In-memory indexes are updated synchronously within the change set processing pipeline, before epoch advancement.
- **DAS-010 I8 (sequential processing):** Single-process, single-writer architecture guarantees sequential change set processing without coordination.

---

## Storage Topology

### Single-Process Architecture

All DIR content, indexes, epochs, pass state, and supporting structures reside within a single macOS process. There is no multi-process coordination, no inter-process communication, and no distributed state.

**Why single-process satisfies the architecture:**

DAS-010 I8 requires sequential change set processing. DAS-010 WR-3 requires atomic epoch advancement. DAS-007 I4 requires cross-index snapshot consistency. In a single process, all three are trivially satisfied:
- Sequential processing: one thread runs the synchronous pipeline. No concurrent writers.
- Atomic epoch advancement: increment an integer. No distributed commit.
- Cross-index consistency: all indexes are in the same address space. A query sees the same memory state across all indexes.

**Alternatives considered:**
- *Multi-process with shared memory:* Introduces IPC complexity for zero benefit at the current scale. No consumer requires cross-process DIR access.
- *Client-server split (DIR on a local server process):* Adds network latency to every query. Decode's hotkey-to-explanation latency budget is ~500 ms end-to-end; adding ~1-5 ms per DIR query (IPC overhead) is wasteful when in-memory access is ~50 ns.

**How this preserves future scalability:** If Decode's architecture eventually requires multi-process access (e.g., a persistent background service that maintains the DIR while the UI process connects and disconnects), the in-memory-primary model can evolve into a persistent service with IPC. The DIR contract (DAS-002), index contract (DAS-007), and update model (DAS-010) are process-topology-agnostic — they define logical operations, not physical locations. The single-process choice is a realization decision, not an architectural commitment.

### Scale Envelope

This realization is designed for the following scale:

| Dimension | Target | Practical Limit |
|-----------|--------|-----------------|
| Source files tracked | 1,000 (alpha) | 10,000 |
| Entities | ~20,000 (alpha) | ~200,000 |
| Atomic units | ~300,000 (alpha) | ~6,000,000 |
| Memory footprint (DIR) | ~60 MB (alpha) | ~1.2 GB |
| Memory footprint (indexes) | ~30 MB (alpha) | ~600 MB |
| Snapshot file size | ~60 MB (alpha) | ~1.2 GB |
| Epoch advance latency | <50 ms | <200 ms |
| Startup (snapshot load + index rebuild) | <2 s | <15 s |

At the practical limit (10,000 files, ~1.8 GB total memory), the realization remains feasible on a 16 GB macOS system. Beyond 10,000 files, the memory footprint may require revisiting the storage topology — either persistent indexes (avoiding rebuild cost) or disk-backed DIR with in-memory caching. This evolution is noted in Open Questions.

---

## DIR Storage

### Unit Store Structure

The unit store is a collection of in-memory atomic units, organized for efficient access by the primary query axes defined in DAS-002.

**Primary key: unit identifier.** Every unit has a globally unique, opaque identifier (DAS-002 I-ID-1). The unit store provides O(1) lookup by identifier. This is the canonical access path — all other access paths (by subject, by predicate, by tier) are served by indexes.

**Lifecycle partitioning.** Units are partitioned by lifecycle status (DAS-002): Active, Invalidated, and Superseded. Active units are the primary query target (DAS-002 retrieval defaults: "queries return only Active units unless the consumer explicitly requests Invalidated or Superseded units"). Partitioning by status avoids scanning Superseded units during normal queries.

**Why this satisfies the architecture:**
- DAS-002 I-LC-5 (immutability except status): units are immutable structures in memory. Status transitions replace the status field but do not modify other fields. In practice, this means the unit object is not mutated — the unit store updates its status index.
- DAS-002 I-ID-1 through I-ID-3 (identity): the unit store's primary key is the opaque unit identifier. No semantic content is encoded in identifiers.

**Alternatives considered:**
- *Keying by (subject, predicate, tier) instead of unit ID:* This would make the "competing claims" lookup (DAS-002 I-PRED-3) efficient but would make unit-by-ID lookup (needed for grounding chain traversal) O(log N). Since grounding chain traversal is on the critical path for invalidation cascade (DAS-010 IP-4), O(1) by ID is preferred. The Entity Index serves the (subject, predicate, tier) access pattern.
- *Separate stores per tier:* This would simplify tier-filtered queries but complicate cross-tier operations (invalidation cascade traversal, epoch-consistent snapshots). A single store with tier as a filterable field is simpler.

### Supersession Key

DAS-002 I-LC-3 defines supersession: "creation of a replacement unit with the same subject and predicate." DAS-003 TL-2 constrains: "When a new unit supersedes an old unit, both must be at the same tier." Together, these define the supersession key as **(subject, predicate, tier)**.

When a new unit is created with the same (subject, predicate, tier) as an existing Active unit, the existing unit transitions to Superseded status. Multiple Active units with the same (subject, predicate) at *different* tiers coexist — they represent different kinds of claims (a T0 fact and a T2 interpretation) about the same aspect of the same entity. This coexistence is resolved at consumption time by context assembly (DAS-009 tier preferences), not at storage time.

**Why this satisfies the architecture:**
- DAS-003 TL-2: "A T2 unit cannot supersede a T0 unit." Enforced by requiring same tier in the supersession key.
- DAS-002 I-PRED-3: "Two units with the same subject and predicate represent competing claims." When tiers differ, they are not competing — they are complementary claims at different objectivity levels.

### Unit Identity Generation

Unit identifiers must be globally unique (DAS-002 I-ID-1), opaque (I-ID-3), and never reassigned (I-ID-2). In the single-process architecture, a monotonically increasing 64-bit integer satisfies all three properties. The counter is persisted in the snapshot to ensure uniqueness across restarts. No UUID generation, no hash computation, no coordination protocol.

**Why not content-based identity:** DAS-002 I-ID-3 explicitly forbids encoding semantic content in the identifier. Content-addressed identity (hashing the unit's fields) would create identifier instability — the same claim about the same entity would get different identifiers if any field changed, making grounding chain references fragile. Sequential integers are stable, cheap, and opaque.

---

## Index Storage

### Per-Family Persistence Decision

DAS-007 defines five index families. All are derived from the DIR (DAS-007 I1) and rebuildable (DAS-007 I5). The realization must decide whether each family is persisted in the snapshot or rebuilt on restart.

| Family | Rebuild Source | Rebuild Cost | Persistence Decision | Rationale |
|--------|---------------|-------------|---------------------|-----------|
| Entity Index | All units (by subject) | O(N) where N = total units | **Ephemeral** | Rebuild is a single scan of all units. At ~300K units, rebuild takes <500 ms. |
| Graph Index | Paired-entity units | O(R) where R = relationship units | **Ephemeral** | Rebuild is a scan of relationship units. At ~80K relationships, rebuild takes <200 ms. |
| Predicate Index | All units (by predicate) | O(N) | **Ephemeral** | Same scan as Entity Index, different projection. <500 ms. |
| Content Index | Text-valued units (T1, T2) | O(T) where T = text units | **Ephemeral** | Rebuild requires tokenizing text values. At ~4K T2 text units, rebuild takes <100 ms. |
| Scope Index | `contains` relationships | O(C) where C = containment edges | **Ephemeral** | Rebuild is a scan of containment edges. At ~20K containment edges, rebuild takes <50 ms. |

**Decision: all indexes are ephemeral.** They are rebuilt from the DIR on every startup, after the snapshot is loaded. This is the strongest expression of DAS-007 I1 (index derivability) — indexes carry zero persistent state.

**Why not persist indexes:**
- Persisting indexes doubles the snapshot size without improving correctness (indexes are derived).
- Persisted indexes require invalidation on schema changes — ephemeral indexes are automatically correct after rebuild.
- Rebuild cost is bounded and predictable: at alpha scale (300K units), total index rebuild takes <1 second. At the practical limit (6M units), rebuild takes <10 seconds. Both are within the startup time budget.

**Why this satisfies the architecture:**
- DAS-007 I6 (graceful absence): during index rebuild, queries fall back to DIR scan. The system is functional (with degraded performance) during the rebuild window.
- DAS-007 I4 (consistent snapshots): after rebuild completes, all indexes reflect the same DIR state (the snapshot epoch). No cross-index consistency concern exists because all indexes are rebuilt from the same source in the same process.

### Index Rebuild Order

Following DAS-007 IFR-4 (rebuild priority order):

1. **Entity Index** (highest priority — enables entity-centric queries)
2. **Graph Index** (enables relationship traversal and impact analysis)
3. **Scope Index** (enables scoped queries; cheap to rebuild from containment edges)
4. **Predicate Index** (enables predicate-filtered and provenance-based queries)
5. **Content Index** (lowest priority — enables text search over semantic content)

Each index becomes available for queries as soon as its rebuild completes. Queries that require a not-yet-rebuilt index fall back to DIR scan (DAS-007 I6).

### Internal Supporting Structures

In addition to the five DAS-007 index families, the storage layer maintains one internal structure that is not a retrieval index:

**Grounding Dependency Map.** A reverse lookup that maps each unit identifier to the set of units whose `provenance.inputs` field references it. This structure supports the invalidation cascade required by DAS-010 IP-4: "for each directly invalidated unit U, the system identifies all units whose grounding chains include U."

| Property | Value |
|----------|-------|
| Source data | `provenance.inputs` field of all atomic units |
| Access pattern | Given unit U, return all units V where U ∈ V.provenance.inputs |
| Persistence | Ephemeral — rebuilt on startup from DIR provenance records |
| Rebuild cost | O(N) — one scan of all units, extracting provenance.inputs references |
| Maintenance | Incremental — when a new unit is created, add entries for each of its provenance.inputs; when a unit is garbage-collected, remove its entries |

**Why this is not a DAS-007 index family:** DAS-007 I7 scopes its completeness claim to "retrieval operations" — consumer-facing queries defined by DAS-008. The grounding dependency map serves the update model (DAS-010), not consumer retrieval. Consumers never query "what depends on unit X?" — they query "what calls function F?" (served by the Graph Index) or "what is in module M?" (served by the Scope Index). The grounding dependency map is a storage-internal optimization for the invalidation cascade, not an architectural index family.

**Why this is necessary:** Without this structure, the invalidation cascade (DAS-010 IP-4) requires scanning all units to find those whose `provenance.inputs` includes the invalidated unit — O(N) where N is the total unit count. At 300K units, this is feasible but slow (~10-50 ms per invalidated unit). For a change that invalidates 20 units, cascade identification alone would take ~200 ms-1 s — a significant fraction of the synchronous pipeline budget. The dependency map reduces this to O(degree) — the number of directly dependent units, typically <50 per unit.

---

## Epoch and Consistency

### Epoch Counter

The update epoch (DAS-010 WR-1) is realized as a single 64-bit integer in process memory. It is initialized from the snapshot on startup (or to 0 on first launch). It is incremented by exactly one when the synchronous pipeline completes (DAS-010 WR-3).

**Epoch advancement is the commit point.** The sequence for a change set is:

1. Synchronous pipeline executes: T0 re-parse, T0/T1 pass re-execution, unit creation/invalidation/supersession.
2. All structural indexes (Entity, Graph, Scope, Predicate) are updated.
3. The epoch counter increments from N to N+1.
4. The snapshot is written (capturing the DIR at epoch N+1).
5. The new epoch is visible to consumer queries.

Steps 1-3 execute within the synchronous pipeline. Step 4 may execute asynchronously (the snapshot captures the state at the moment of epoch advancement; subsequent queries see epoch N+1 regardless of whether the snapshot write has completed).

**Why this satisfies the architecture:**
- DAS-010 WR-3: "The epoch advances atomically when the synchronous pipeline completes." In single-process, single-writer architecture, the counter increment is atomic by construction.
- DAS-010 WR-5: "If a consumer issues a query while a change set is being processed, the query executes against the prior epoch." Consumers read the epoch counter before querying. If the counter is N and the synchronous pipeline is executing (preparing epoch N+1), the consumer queries at epoch N — seeing the committed state.

### Snapshot Consistency

The snapshot captures the DIR at a specific epoch. Snapshot consistency is guaranteed by the epoch model:

- The snapshot is written after epoch advancement (step 4 above).
- The snapshot contains: all atomic units (Active, Invalidated, Superseded), the epoch counter, the unit ID counter, the content hash of every tracked file, and the set of invalidated T2 unit identifiers (the deferred recomputation queue).
- The snapshot does not contain: indexes (rebuilt on startup), the pass DAG (derived from code), or transient state (in-flight change sets, query results).

**Snapshot write timing.** The snapshot is written after every epoch advance. At alpha scale (~60 MB), snapshot serialization takes ~10-50 ms to SSD. This is within the inter-save interval (developers typically save every 2-30 seconds). If saves are faster than snapshot writes, the snapshot is skipped for intermediate epochs — only the latest committed epoch is captured. This means crash recovery may lose multiple epochs' worth of changes, but since all lost changes are reprocessable from source (DAS-010's change detection will re-detect them), no DIR content is permanently lost.

**Alternatives considered:**
- *Snapshot on every Nth epoch:* Reduces I/O but increases the reconciliation window on restart. At alpha scale, per-epoch snapshots are cheap enough. At larger scale, periodic snapshots may be justified — noted in Open Questions.
- *Incremental snapshots (only changed units):* Reduces snapshot write size but requires a merge-on-read strategy for loading. Added complexity is not justified at alpha scale.

### Content Hash Computation

DAS-002 I-VER-3 requires content-addressed versioning. DAS-010 CD-1 uses content hashes for change detection. This chapter defines the hash scope:

**Content hashes are computed over raw file bytes.** The hash function operates on the unmodified file content — no normalization, no whitespace stripping, no AST transformation.

**Why raw bytes:**
- Simplicity: no normalization step, no language-specific processing.
- Correctness: the hash changes whenever the file changes, ensuring that the change detection pipeline (DAS-010 CD-1) fires. The pipeline's entity-level comparison (DAS-010 CD-5) then determines which entities actually changed. If a whitespace-only change produces no structural differences, early termination (DAS-010 IP-6) prevents unnecessary cascade. The hash is a *gate* ("has anything changed?"), not a *filter* ("has anything meaningful changed?"). The meaningfulness determination is delegated to the entity-level comparison, which is the architecturally correct location.

**Alternatives considered:**
- *AST-normalized hash:* Would skip the pipeline entirely for whitespace-only changes, saving re-parse cost. But requires a language-specific normalization step before hashing — duplicating frontend logic in the change detection layer. The savings (skipping a re-parse that produces no entity changes) are marginal compared to the complexity cost.
- *Line-normalized hash (strip trailing whitespace, normalize line endings):* A simple normalization that avoids re-parsing for trivial formatting changes. Low complexity but low benefit — formatters that change only whitespace are uncommon in practice, and the re-parse cost for a false positive is milliseconds.

---

## Pass State and Configuration

### Pass Registrations

Pass registrations (DAS-006 pass contracts — input declarations, tier output ranges, dependency declarations) are defined in code, not in storage. The pass DAG is derived from registrations at process startup. Pass registrations are not persisted in the snapshot — they are reconstructed from the application binary on every launch.

**Why this is correct:** Pass registrations are configuration, not data. They change only when the application is updated (new pass added, pass logic changed). DAS-006 PINV-4 (producer upgrade invalidation) handles the case where a pass changes between versions — the upgrade detection mechanism compares the current pass version against the provenance of existing units.

### Pass Version Tracking

Each pass declares a version identifier (e.g., a string or integer). This version is recorded in the `provenance.producer` field of every unit the pass creates (DAS-002 I-PROV-2). Pass versions are not stored separately — they exist only within unit provenance records in the DIR.

On startup, the system compares the current pass versions (from code) against the provenance of existing units in the loaded snapshot. If a pass version has changed, all units produced by the old version are candidates for re-evaluation (DAS-010 PU-2). This re-evaluation uses the standard incremental update machinery — no special-purpose upgrade logic.

### Predicate Registry

The predicate registry (DAS-002 I-PRED-1: append-only, versioned) is defined in code. Predicates are enumerated as part of the application binary. The registry is not persisted in the snapshot.

**Schema evolution:** When a new predicate is added (application update), existing snapshot units do not reference the new predicate — no migration is needed. When an existing predicate is deprecated, existing units retain the deprecated predicate — they remain interpretable (DAS-002 I-PRED-1: "existing predicates can be deprecated but never removed"). The append-only nature of the predicate registry means that snapshots from older application versions are always loadable by newer versions.

### Context Strategies

Context strategies (DAS-009) are configuration defined in code. They are not persisted. They are effectively static during a process lifetime and reconstructed on startup.

---

## Lifecycle and Garbage Collection

### Retention Policy

DAS-010 GC-1 through GC-4 define eligibility; this section defines the concrete retention policy.

**GC-R1: T0 and T1 superseded units are eligible for collection at the next epoch.** T0 and T1 units are cheap to recompute (DAS-003 TL-3). Retaining superseded T0/T1 units provides no graceful degradation benefit — the replacement unit is already Active. Superseded T0/T1 units are collected during the next garbage collection pass after they are superseded.

**GC-R2: T2 superseded units are retained for a configurable number of epochs (default: 100).** T2 units are expensive to recompute (AI invocation). A superseded T2 unit may still be useful if the replacement fails or if the system needs to compare old and new interpretations. After 100 epochs (~100 file saves during active development), the superseded T2 unit is eligible for collection.

**GC-R3: Invalidated T2 units are never collected while invalidated.** An invalidated T2 unit is stale but queryable — it supports graceful degradation (DAS-001 P12, DAS-010 WR-6). It remains in the DIR until it is either superseded (by a fresh T2 recomputation) or explicitly removed (if the entity it describes no longer exists). Once superseded, GC-R2 applies.

**GC-R4: Units whose subject entity no longer exists are eligible for immediate collection.** When an entity is removed from source (DAS-010 IP-2), all units about that entity are invalidated. Since the entity no longer exists, these units serve no graceful degradation purpose — there is nothing to degrade *about*. They are eligible for collection at the next GC pass.

### Garbage Collection Schedule

**GC-S1: Garbage collection runs as a background operation, not during the synchronous pipeline.** DAS-010 GC-3 explicitly requires this. GC does not block change set processing or epoch advancement.

**GC-S2: GC is triggered after every Nth epoch advance (default: N=10).** At alpha scale, GC is cheap — scanning for eligible units and reclaiming their memory is a sub-millisecond operation. Running every 10 epochs prevents unbounded accumulation without adding per-save overhead.

**GC-S3: GC is also triggered when memory pressure exceeds a threshold.** If the DIR's memory footprint exceeds a configurable limit (default: 80% of the scale envelope's practical limit), GC runs immediately and may reduce retention periods (collecting T2 superseded units sooner). This is a safety valve, not a normal operating mode.

### GC and Snapshots

Garbage-collected units are removed from the DIR and from the next snapshot. A snapshot at epoch N+1 (after GC) is smaller than the snapshot at epoch N. This is correct: the collected units are no longer needed, and any query against the snapshot-restored DIR will not reference them.

---

## Durability and Recovery

### Crash Scenarios

**Scenario 1: Clean shutdown.** The application writes a snapshot before exiting. On restart, the snapshot is loaded and reconciled. No data loss.

**Scenario 2: Crash during idle (between change sets).** The latest snapshot reflects the last committed epoch. On restart, load snapshot. Reconcile with current file state (files may have changed while the app was running but after the last snapshot, OR while the app was down). All lost changes are reprocessable from source.

**Scenario 3: Crash during synchronous pipeline (mid-change-set).** The in-progress change set is lost. The latest snapshot reflects the prior epoch. On restart, load snapshot at epoch N. The files that triggered the in-progress change set still have their new content — reconciliation detects the changed content hashes and reprocesses them as a normal change set. No data loss — the change set is reprocessed, not replayed.

**Scenario 4: Crash during snapshot write.** The snapshot file may be partially written. On restart, the system detects a corrupted or truncated snapshot. Recovery: load the prior valid snapshot (the system keeps the previous snapshot until the new one is fully written, then atomically replaces it). If no prior snapshot exists (first launch, snapshot corruption), fall back to full rebuild from source (DAS-002 DC-5).

### Snapshot Integrity

**Snapshot atomicity.** The snapshot is written to a temporary file, then atomically renamed to the canonical snapshot path. This ensures that the snapshot file is either the complete prior state or the complete new state — never a mix. The atomic rename is a POSIX guarantee on macOS (HFS+ and APFS both support atomic rename).

**Snapshot validation.** Each snapshot includes a checksum of its contents. On load, the checksum is verified. If verification fails, the snapshot is treated as corrupted (Scenario 4 recovery applies).

### Reconciliation Process

On startup, after loading a valid snapshot:

1. **Enumerate tracked files.** List all source files within the tracked scope.
2. **Compare content hashes.** For each file, compute the current content hash and compare against the hash recorded in the snapshot.
3. **Classify changes.** Files with matching hashes: no action. Files with changed hashes: added to a change set. Files present in the snapshot but absent on disk: marked as deleted. Files present on disk but absent in the snapshot: marked as created.
4. **Process change set.** The accumulated changes are processed as a single change set using the standard incremental update machinery (DAS-010). The synchronous pipeline runs (T0 re-parse, T0/T1 pass re-execution, index updates), the epoch advances, and the new snapshot is written.

Reconciliation is equivalent to the system "catching up" on changes that occurred while it was not running. The machinery is identical to normal change set processing — no special-purpose reconciliation logic is needed.

### Full Rebuild

If no valid snapshot exists (first launch, all snapshots corrupted), the system performs a full rebuild from source:

1. Initialize an empty DIR at epoch 0.
2. Treat all source files as "created" (DAS-010 CD-3).
3. Parse all files via frontends → T0 units.
4. Execute T0/T1 passes → T0/T1 units.
5. Build all indexes.
6. Write initial snapshot.
7. T2 enrichment is not performed during full rebuild — it is triggered on consumer demand (DAS-010 RS-9) or background scheduling (DAS-010 RS-7).

Full rebuild cost at alpha scale (1,000 files): ~2-5 seconds for T0/T1. T2 is deferred. The system is usable (with T0+T1 intelligence) immediately after step 5.

---

## Deferred T2 Recomputation Queue

DAS-010 RS-5 requires recording invalidated T2 units for deferred processing. This queue is realized as an in-memory set of unit identifiers, persisted in the snapshot.

**Queue semantics:**
- When a T2 unit is invalidated during the synchronous pipeline (DAS-010 CB-2), its identifier is added to the deferred queue.
- When a T2 unit is recomputed (via consumer demand or background scheduling), its identifier is removed from the queue.
- On restart, the queue is loaded from the snapshot. Additionally, a reconciliation scan confirms the queue's consistency: any T2 unit with Invalidated status that is not in the queue is added. Any queue entry referencing a non-existent or Active unit is removed.

**Why persist the queue:** The queue is derivable from the DIR (scan for T2 units with Invalidated status). Persisting it avoids the scan on startup. At alpha scale (~4,000 T2 units), the scan is trivial (<10 ms). Persisting the queue is a minor optimization, not a correctness requirement. If the queue is lost (snapshot corruption affecting only the queue), it is reconstructed by scanning — no data is lost.

---

## Architectural Consequences

**C1: The DIR is always in memory.** Every query, every update, every index lookup operates at memory-access speed. No I/O is on the critical path for interactive operations. Snapshot writes are the only storage I/O, and they are either asynchronous or occur during the inter-save window.

**C2: Startup requires snapshot load + index rebuild + reconciliation.** This is the cost of ephemeral indexes. At alpha scale: snapshot load (~60 MB from SSD) takes <100 ms; index rebuild takes <1 s; reconciliation depends on how many files changed (typically a few change sets, <1 s). Total startup: <2 s. At the practical limit (10K files): <15 s.

**C3: Crash recovery is lossless for committed state.** Every committed epoch is captured in a snapshot. Only the in-progress change set (if any) is lost on crash, and it is reprocessable from source. T2 content is preserved across crashes (it is in the snapshot). No AI calls are needed for crash recovery unless files actually changed.

**C4: The snapshot is the single point of persistence.** The system has exactly one file on disk that matters: the snapshot. No database, no log, no index files. This minimizes the storage surface area — fewer files means fewer corruption vectors, fewer migration concerns, and simpler backup.

**C5: Memory is the scaling constraint.** The in-memory realization trades disk capacity (abundant) for memory capacity (limited). This trade-off is correct at current scale (60 MB-1.2 GB) but becomes the bottleneck before disk I/O does. The Open Questions section addresses the path to disk-backed storage if memory becomes insufficient.

**C6: Index rebuild on every restart ensures index correctness by construction.** Persistent indexes can diverge from the DIR through subtle bugs (missed updates, partial writes, version mismatches). Ephemeral indexes cannot diverge — they are rebuilt from the authoritative DIR every time. This eliminates an entire class of consistency bugs at the cost of startup latency.

**C7: The grounding dependency map enables efficient invalidation cascade.** DAS-010 IP-4's reverse grounding traversal, which would be O(N) without this structure, is O(degree) — typically <50 lookups per invalidated unit. This keeps the synchronous pipeline within its latency budget.

**C8: Supersession operates on (subject, predicate, tier) triples.** Multiple active units per (subject, predicate) at different tiers coexist. This is not a storage optimization — it is the faithful realization of DAS-003 TL-2's tier constraint on supersession.

---

## Invariants

**I1: Snapshot Epoch Correspondence.**
- **Statement:** The snapshot on disk represents a complete, internally consistent DIR state at a specific epoch. The epoch recorded in the snapshot matches the epoch at which the snapshot was written.
- **Rationale:** If the snapshot contains units from different epochs (some from epoch N, some from epoch N+1), loading it produces an inconsistent DIR — violating DAS-010 I1 (epoch consistency).
- **Verification:** Load the snapshot. Query all units. Confirm that no T0 or T1 unit has Invalidated status (DAS-010 I1 requires all T0/T1 to be current at each epoch). Confirm that the epoch counter in the snapshot matches the most recent change set processing.

**I2: Snapshot Atomicity.**
- **Statement:** At any point in time, the snapshot file on disk is either a complete valid snapshot or the previous complete valid snapshot. No intermediate state is observable.
- **Rationale:** A partially-written snapshot causes data loss on restart. The atomic write (write-to-temp + rename) guarantees that the snapshot file is always valid.
- **Verification:** Kill the process during a snapshot write. Confirm that the snapshot file contains the prior epoch's state, not a truncated version.

**I3: Index Ephemeral Derivability.**
- **Statement:** All indexes are rebuilt from the DIR on every process startup. No index state persists across restarts.
- **Rationale:** This is the strongest expression of DAS-007 I1 (index derivability). By rebuilding, the system guarantees that indexes are always consistent with the DIR — no stale index data can survive a restart.
- **Verification:** Delete all index state and restart the process. Confirm that all indexes are rebuilt and all queries return correct results.

**I4: Reconciliation Completeness.**
- **Statement:** After reconciliation, the DIR is consistent with the current source state: every tracked file's content hash in the DIR matches the file's current content hash on disk. No stale T0 or T1 units remain Active.
- **Rationale:** Reconciliation bridges the gap between the snapshot (which may be from a prior work session) and the current source state. Incomplete reconciliation would serve stale T0 facts — violating DAS-003's T0 source-synchronous freshness contract.
- **Verification:** After startup, compare every tracked file's disk content hash against the DIR's recorded content hash. Confirm they match.

**I5: Single Snapshot Persistence.**
- **Statement:** The system maintains at most two snapshot files at any time: the current (being written or most recently completed) and the prior (retained until the current write completes). No unbounded accumulation of snapshot files occurs.
- **Rationale:** Snapshot files are large (60 MB-1.2 GB). Accumulating snapshots without cleanup would consume disk space proportional to the number of epochs — unbounded.
- **Verification:** Count snapshot files on disk. Confirm the count does not exceed two.

**I6: Grounding Dependency Map Consistency.**
- **Statement:** For every unit V in the DIR with provenance.inputs = {U₁, U₂, ...}, each Uᵢ has an entry in the dependency map pointing to V. For every entry in the dependency map pointing to V, V.provenance.inputs includes the key unit.
- **Rationale:** An inconsistent dependency map causes the invalidation cascade (DAS-010 IP-4) to miss dependent units (if entries are missing) or to invalidate unrelated units (if entries are spurious). Both violate DAS-010 I5 (grounding chain completeness).
- **Verification:** Scan all units. For each unit V with provenance.inputs, verify that the dependency map contains the corresponding entries. For each entry in the dependency map, verify that the referenced unit's provenance.inputs includes the key.

**I7: GC Safety.**
- **Statement:** Garbage collection never removes a unit that is referenced by any active unit's provenance.inputs or grounding chain, or that has Active or Invalidated status.
- **Rationale:** Removing a referenced unit breaks grounding chains (DAS-002 I3: grounding termination). Removing an Active or Invalidated unit removes queryable content — violating DAS-002 lifecycle guarantees.
- **Verification:** Before each GC pass, confirm that every candidate for collection has Superseded status and is not referenced by any Active or Invalidated unit's provenance.inputs.

**I8: Memory Boundedness.**
- **Statement:** The total memory consumed by the DIR, all indexes, and all supporting structures is bounded by a function of the codebase size (number of files, entities, and relationships) and the GC retention policy. Memory does not grow unboundedly with the number of epochs processed.
- **Rationale:** Unbounded memory growth would eventually exhaust system resources. GC ensures that superseded units are collected. The retention policy bounds how many superseded units are retained.
- **Verification:** After processing a sustained workload (many change sets), confirm that memory usage stabilizes. Plot memory usage against epoch count. Confirm sub-linear growth after the initial population phase.

---

## Non-Goals

This chapter does not:

- **Define the serialization format for snapshots.** Whether snapshots use Protocol Buffers, MessagePack, custom binary, or JSON is an implementation choice. This chapter defines what the snapshot contains and what properties it must have (atomicity, checksummed, epoch-tagged), not how its bytes are arranged.

- **Define the in-memory data structure for unit storage or indexes.** Whether the unit store is a `Dictionary<UnitID, AtomicUnit>`, a sorted array, or a custom hash table is an implementation choice. Whether the Entity Index uses a `Dictionary<EntityRef, Set<UnitID>>` or a B-tree is an implementation choice. This chapter defines the access patterns and performance requirements; implementation selects the structures.

- **Define the file system layout.** Where the snapshot file lives, what it is named, and how multiple projects are isolated from each other on disk are implementation choices.

- **Define concurrency control for multi-threaded read access.** Whether consumer queries use copy-on-write snapshots, read-write locks, or actors to achieve thread-safe reads during change set processing is an implementation choice. This chapter defines the consistency guarantee (queries see a committed epoch); implementation selects the concurrency mechanism.

- **Prescribe a hash function for content-hash computation.** SHA-256, xxHash, or any cryptographic or non-cryptographic hash with negligible collision probability is acceptable.

- **Define the grounding dependency map's data structure.** Whether it uses a multi-map, an adjacency list, or a sparse matrix is an implementation choice.

- **Define cloud persistence, synchronization, or backup strategies.** The snapshot is a local file. Cloud backup, cross-device synchronization, and remote persistence are product features, not architectural concerns.

---

## Open Questions

**Q1: At what scale should the storage topology evolve beyond in-memory-primary?** *(Non-blocking)*

The in-memory realization supports up to ~10K files (~1.2 GB DIR + ~600 MB indexes). Beyond this, the memory footprint may exceed what is reasonable for a desktop application. The natural evolution path is: persist selected indexes (Entity, Graph) to avoid rebuild cost, then move the DIR to a disk-backed store with an in-memory cache for hot entities. This evolution does not change the logical architecture — the DIR contract, index contract, and update model are topology-agnostic.

**Investigation approach:** Monitor memory usage in production at alpha scale. If the median codebase exceeds 5,000 files, prototype disk-backed indexes and measure startup improvement.

**Q2: Should the snapshot frequency be adaptive?** *(Non-blocking)*

The current design writes a snapshot on every epoch advance. For workloads with rapid saves (5+ saves per second during burst editing), this may generate excessive I/O. An adaptive strategy — snapshot every N epochs or every T seconds, whichever comes first — would reduce I/O while bounding recovery window size.

**Investigation approach:** Profile snapshot write latency at alpha scale. If snapshot writes contribute >10% of the synchronous pipeline latency, implement adaptive snapshot frequency with a configurable epoch interval (default: 1) and time interval (default: 5 seconds).

**Q3: Should the grounding dependency map be formalized as a sixth DAS-007 index family?** *(Non-blocking)*

This chapter defines the grounding dependency map as a storage-internal structure that serves the update model, not consumer retrieval. However, a future consumer capability (e.g., "show me everything that depends on this claim") would need the same structure for retrieval. If such a capability is planned, formalizing the structure as a DAS-007 index family would be architecturally cleaner than maintaining it as a storage-internal optimization with a retrieval-facing wrapper.

**Investigation approach:** Enumerate planned consumer capabilities. If any require reverse grounding traversal as a retrieval operation, propose a DAS-007 amendment to add a Grounding Dependency Index family.

**Q4: Should snapshots support incremental writes at larger scale?** *(Non-blocking)*

At the practical limit (~1.2 GB), full snapshot writes take ~200-500 ms. If snapshot writes become a bottleneck (contributing to visible latency), incremental snapshots (writing only changed units since the last snapshot) would reduce I/O. This adds complexity: loading requires merging a base snapshot with incremental deltas, and periodic compaction is needed.

**Investigation approach:** Measure snapshot write latency at scale. If full snapshots at ~1 GB take >500 ms on target hardware, prototype incremental snapshots.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              ├── DAS-006 (Pass Architecture)
              ├── DAS-007 (Index Architecture)
              ├── DAS-010 (Incremental Update Model)
              └── DAS-012 (this chapter — Storage Realization)
```

This chapter depends on:
- **DAS-000:** Chapter structure, review checklist, layer discipline (L5 constraints)
- **DAS-001:** P1 (intelligence is canonical asset — determines what persists), P9 (incremental by design — shapes update support), P12 (graceful degradation — shapes GC retention and index absence policy)
- **DAS-002:** Atomic unit contract (10 fields — determines unit store structure), lifecycle (Active/Invalidated/Superseded — determines status partitioning), identity (I-ID-1 through I-ID-3 — determines primary key), immutability (I-LC-5 — determines write patterns), version (I-VER-3 — determines content hash scope), rebuildability (DC-5 — determines full rebuild path), predicate registry (I-PRED-1 — determines schema evolution strategy)
- **DAS-003:** Freshness contracts (T0 source-synchronous, T1 propagation delay, T2 eventual — determines which operations must be synchronous), supersession tier constraint (TL-2 — determines supersession key), GC retention by tier (TL-3 — determines retention policy)
- **DAS-006:** Pass contracts (input/output declarations — determines pass state storage), pass DAG (derived from registrations — determined to be ephemeral), producer versioning (PINV-4 — determines upgrade detection)
- **DAS-007:** Five index families (Entity, Graph, Predicate, Content, Scope — determines what indexes to build), derivability (I1 — enables ephemeral indexes), rebuild priority (IFR-4 — determines rebuild order), consistent snapshots (I4 — satisfied by in-memory topology)
- **DAS-010:** Epoch-based consistency (WR-1 through WR-5 — determines epoch counter realization), change set atomicity (I4 — satisfied by single-process topology), sequential processing (I8 — satisfied by single-process topology), grounding chain cascade (IP-4 — determines grounding dependency map), index-DIR consistency (I7 — satisfied by synchronous index updates), GC eligibility (GC-1 through GC-4 — determines GC policy)

This chapter is depended on by:
- No downstream DAS chapters. DAS-012 is the terminal chapter — it depends on all relevant upstream chapters but no chapter depends on it.

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial skeleton with section headings, dependency
    list, and pre-authoring open questions.
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining storage realization.
    Single-process, in-memory-primary architecture selected over no-persistence, embedded
    database, and write-ahead log alternatives. Epoch-aligned snapshot persistence for
    DIR. Ephemeral indexes rebuilt on startup. Grounding dependency map as storage-internal
    structure. Content hash over raw file bytes. Supersession on (subject, predicate, tier).
    Tier-informed GC retention policy. Crash recovery via snapshot + reconciliation.
    Eight invariants. Four open questions.
```
