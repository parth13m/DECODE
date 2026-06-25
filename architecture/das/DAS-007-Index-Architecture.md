# DAS-007: Index Architecture

```
Chapter:       DAS-007
Title:         Index Architecture
Status:        Draft
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005, DAS-006
Depended By:   DAS-008, DAS-009, DAS-010, DAS-012
Supersedes:    DAS-007 (Retrieval Model — stub, never approved)
Superseded By: —
Layer:         L3
```

## Abstract

This chapter defines the index architecture — the derived, query-optimized structures that sit between the DIR and retrieval. Indexes contain no information that is not derivable from the DIR; they exist solely to make retrieval efficient. The chapter identifies five index families from the DIR's access patterns, defines their purpose, source data, freshness requirements, and failure impact, and establishes the invariants that govern all indexes. It does not define the retrieval query algebra, context assembly, or storage realization — those are downstream concerns.

## Motivation

DAS-002 establishes that every field on an atomic unit is queryable: by subject, predicate, tier, status, confidence, version, provenance, and conjunction. DAS-002 also establishes the index contract: indexes are derived projections of the DIR, rebuilt from the DIR without data loss, and governed by the DIR's authority. But DAS-002 deliberately defers the index architecture to this chapter, noting only illustrative examples (entity lookup, relationship traversal, predicate index, full-text index) without analysis of whether those are the right categories or what their properties should be.

Without this chapter, four problems arise:

1. **Indexes are ad hoc.** Without a principled derivation of index families from the DIR's access patterns, indexes are added reactively — a new query pattern appears, a new index is created. Over time, the index set becomes a collection of special-purpose structures with overlapping responsibilities, inconsistent freshness guarantees, and no unified invalidation model.

2. **Freshness guarantees are undefined.** DAS-003 defines freshness contracts per tier: T0 is source-synchronous, T1 is source-synchronous with propagation delay, T2 is eventual. But the DIR's freshness contracts apply to atomic units. Indexes are derived from atomic units — what freshness guarantees do indexes provide? If an index is stale relative to the DIR, what does the consumer see? Without defined index freshness, consumers cannot know whether their query results reflect the current DIR state or a prior one.

3. **Invalidation is uncoordinated.** When a pass produces new units (DAS-006), which indexes must be updated? If the new units change an entity's relationships, the relationship index must update. If they change a predicate value, the predicate index must update. Without a defined model for index-to-DIR dependency, updates are either eager (update every index on every change — wasteful) or haphazard (update whichever index someone remembered — inconsistent).

4. **Rebuild cost is unknown.** DAS-002 I8 guarantees that every index can be rebuilt from the DIR. But rebuilding all indexes from scratch may be expensive. Without an index architecture that defines what each index contains, there is no basis for estimating rebuild cost, planning rebuild schedules, or deciding which indexes to rebuild first after a failure.

**Source dependencies:**
- [DAS-001 P1](DAS-001-Architectural-Principles.md) — intelligence is the canonical asset (indexes are not)
- [DAS-001 P7](DAS-001-Architectural-Principles.md) — relevance over completeness
- [DAS-001 P9](DAS-001-Architectural-Principles.md) — incremental by design
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — index contract, query semantics, I8 (index derivability)
- [DAS-003](DAS-003-Tier-Model.md) — freshness contracts per tier
- [DAS-004](DAS-004-Entity-Model.md) — entity types that indexes organize
- [DAS-005](DAS-005-Relationship-Model.md) — relationship predicates that indexes traverse
- [DAS-006](DAS-006-Pass-Architecture.md) — passes that produce the DIR content indexes derive from

## Terminology

**Index** — A derived, query-optimized structure built from DIR content. An index contains no information that is not derivable from the DIR. It exists to make a specific class of retrieval queries efficient. If an index is destroyed, it can be rebuilt from the DIR without data loss (DAS-002 I8). If an index and the DIR disagree, the index is stale and the DIR is authoritative. *Is:* a structure that maps entity identifiers to their atomic units for fast lookup; an adjacency structure that maps entities to their relationship neighbors. *Is not:* a parallel store of intelligence; a cache of consumer output; a replacement for the DIR. `See DAS-002`

**Index Family** — A class of indexes defined by the access pattern it serves and the DIR content it organizes. Each index family answers a distinct kind of retrieval question. Individual indexes within a family may be partitioned, scoped, or parameterized, but all share the family's structural properties. `INTRODUCED`

**Access Pattern** — A recurring retrieval question that consumers pose to the DIR. Access patterns are derived from the DIR's structure and from consumer needs. Each access pattern requires specific data organization to answer efficiently. *Is:* "retrieve all units about entity E" (entity-centric access); "traverse all relationship edges from entity E" (graph traversal access). *Is not:* a specific query in a query language; a consumer's business question ("explain this function"). `INTRODUCED`

**Index Projection** — The specific subset of atomic unit fields that an index stores. An index does not necessarily store complete atomic units — it may store only the fields relevant to its access pattern (e.g., an entity lookup index stores subject-to-unit mappings but may not store full grounding chains). The DIR retains the complete units; the index retains a projection optimized for its query pattern. `INTRODUCED`

**Index Freshness** — The degree to which an index reflects the current state of the DIR. An index is fresh if it incorporates all active units and has removed or updated entries for all invalidated or superseded units. An index is stale if it reflects a prior DIR state. Index freshness is bounded by the freshness of the DIR content it derives from (DAS-003 freshness contracts). `INTRODUCED`

**Index Rebuild** — The process of constructing an index from scratch by scanning the relevant DIR content. Rebuild produces a fresh index but is more expensive than incremental maintenance. Rebuild is the recovery mechanism when an index is corrupted, missing, or so stale that incremental repair would be more expensive than reconstruction. `INTRODUCED`

## Domain Analysis

**DA-1: The DIR is a collection of individually addressable atomic units, not a pre-organized structure.** The DIR stores atomic units — each with an id, subject, predicate, value, tier, provenance, confidence, grounding, version, and status. These units are individually created, individually invalidated, and individually superseded. They are not organized into tables, hierarchies, or graphs at the DIR level. The DIR is a flat set of units with rich metadata. This flatness is a strength (units are independent, immutable, and composable) but it means that any structured access — by entity, by relationship, by type, by predicate — requires an organizing layer. That organizing layer is the index.

**DA-2: Retrieval access patterns are derivable from the DIR's structure.** The DIR's atomic unit contract (DAS-002) and the entity/relationship models (DAS-004, DAS-005) define what can be queried. The access patterns are not arbitrary — they follow from the DIR's own structure:
- Atomic units have subjects (entities) → entity-centric access.
- Some subjects are entity pairs (relationships) → graph traversal access.
- Units carry predicates → predicate-filtered access.
- Units carry tiers → tier-filtered access.
- Units carry text values (semantic predicates) → content search access.
These are the fundamental axes along which DIR content is queried.

**DA-3: Different access patterns have fundamentally different performance characteristics without indexes.** Retrieving "all units about entity E" from a flat set of N units requires scanning all N units. Traversing "all entities that E calls" requires finding all `calls` units where E is the source — again a full scan. Searching "which entities have the word 'authentication' in their purpose" requires scanning all T2 text values. These scans are O(N) where N is the total unit count. Indexes reduce these to sub-linear operations. The specific reduction depends on the access pattern: entity lookup is O(1) with a hash map; graph traversal is O(degree) with an adjacency structure; content search is O(matching terms) with an inverted structure.

**DA-4: Not all access patterns have the same freshness requirements.** Entity lookup must be current — a consumer asking "what is function F?" must see F's current properties, not yesterday's. Relationship traversal must be current — a consumer asking "what does F call?" must see F's current call edges, not stale ones. But content search over T2 text values can tolerate staleness — a consumer searching for "authentication" in semantic descriptions can accept results from the last enrichment cycle. Freshness requirements for indexes inherit from the tier-based freshness contracts (DAS-003) of the DIR content they index.

**DA-5: Indexes are lossy projections of the DIR, not copies.** An entity lookup index needs to map entity identifiers to unit IDs — it does not need to store full grounding chains, provenance records, or version stamps. A relationship adjacency index needs to map (entity, predicate) to neighbor entities — it does not need to store confidence values or tier metadata for the adjacency query itself (those are retrieved from the DIR when the specific units are accessed). This is the essence of an index: it answers one question fast and defers other questions to the DIR. An index that stores complete atomic units is not an index — it is a replica.

**DA-6: Index staleness has different severity depending on the access pattern.** A stale entity lookup index that returns a deleted entity's units produces actively wrong results — the consumer sees an entity that no longer exists. A stale relationship index that includes a removed call edge produces misleading impact analysis. A stale content search index that returns a result whose text has changed produces a minor inconvenience — the consumer sees slightly outdated semantic text. Staleness severity correlates with the tier of the indexed content: T0 staleness is a defect; T2 staleness is tolerable.

**DA-7: Indexes must support the inverse access pattern that the DIR itself does not store.** DAS-005 R-DIR-2 establishes that inverse relationships are derived by query reversal, not stored. "What calls function F?" is the inverse of "function F calls what?" The DIR stores only forward edges (A calls B). The index must support both forward and inverse traversal without storing duplicate relationship units. This is a non-trivial requirement: an adjacency index must be bidirectional even though the underlying data is unidirectional.

## Candidates

The architectural question is: **how should indexes be organized?**

### Candidate A: Single Unified Index

One index structure that organizes all DIR content. Every query — entity lookup, relationship traversal, predicate filtering, content search — is served by the same index.

**Strengths:** Single structure to maintain. Single invalidation path. No coordination between indexes. Maximum simplicity.

**Weaknesses:** No single data structure efficiently serves all access patterns. Entity lookup wants a hash map. Graph traversal wants an adjacency structure. Content search wants an inverted structure. A unified index is either a general-purpose structure that serves every pattern poorly, or a composite structure that is internally partitioned — in which case it is multiple indexes under a single name, not a single index.

**Disqualifying condition:** The access patterns have fundamentally incompatible structural requirements. A single structure cannot be simultaneously optimized for point lookup, graph traversal, and content search.

### Candidate B: Per-Query-Type Indexes (One Index per Query)

Each specific query pattern gets its own index. "Get entity by ID" has one index. "Get entity by name" has another. "Get callers of F" has another. "Get callees of F" has another. "Search by keyword in purpose" has another.

**Strengths:** Each index is perfectly optimized for its query. No compromises.

**Weaknesses:** Index proliferation. Each new query pattern requires a new index. Indexes overlap — "callers of F" and "callees of F" both derive from the same relationship data but are maintained independently. Invalidation must be coordinated across many indexes. The number of indexes grows with the number of distinct queries, which is unbounded.

**Disqualifying condition:** Unbounded growth. The number of queries consumers can pose is open-ended. An index per query leads to index proliferation with escalating maintenance cost.

### Candidate C: Index Families by Access Pattern

Indexes are organized into families, where each family serves a class of structurally similar access patterns. An entity lookup family serves all "retrieve by entity identifier" patterns. A graph traversal family serves all "traverse from entity along relationships" patterns. Within each family, a single index structure (possibly partitioned) serves all queries in that class.

**Strengths:** Bounded number of families — determined by the DIR's structure, not by the number of consumer queries. Each family is optimized for its structural access pattern. Families do not overlap in structural responsibility (though a single consumer query may touch multiple families). Invalidation is per-family. New consumer queries are served by existing families, not by new indexes.

**Weaknesses:** Queries that span multiple access patterns require coordinating across families. The family taxonomy must be correct — a missing family means an unsupported access pattern class.

**Disqualifying condition:** None identified.

### Candidate D: No Indexes (Direct DIR Scan)

All queries scan the DIR directly. No derived structures.

**Strengths:** Maximum simplicity. No staleness possible — every query sees the current DIR state. No maintenance cost.

**Weaknesses:** O(N) for every query. For a codebase producing 100,000 atomic units, every query scans 100,000 units. For 1,000,000 units, every query scans 1,000,000. This is not a scaling concern for the future — it is a latency concern for the present. Interactive use (developer presses hotkey, expects sub-second response) requires sub-linear access.

**Disqualifying condition:** Violates interactive latency requirements. DAS-001 P9 (incremental by design) implies that the system's response time is bounded by change size, not total size. Direct scan's response time is bounded by total size.

## Evaluation

| Criterion | Unified (A) | Per-Query (B) | Families (C) | No Indexes (D) |
|-----------|-------------|---------------|-------------|----------------|
| Supports all access patterns | Poorly — structural mismatch | **Yes** — per-query optimization | **Yes** — per-family optimization | Yes — but O(N) |
| Bounded index count | Yes (1) | No — unbounded | **Yes** — bounded by access pattern classes | Yes (0) |
| Incremental maintenance (DAS-001 P9) | Single path | Many paths — coordination burden | **Per-family** — manageable | N/A |
| Freshness management | Single policy | Per-query — complex | **Per-family** — distinct policies | Always fresh |
| Interactive latency | Poor for some patterns | **Optimal** per query | **Good** per family | Unacceptable at scale |
| Open-ended query support | No — new patterns degrade | No — new patterns need new indexes | **Yes** — new queries use existing families | Yes |

Candidate A is disqualified by structural incompatibility. Candidate B is disqualified by unbounded index growth. Candidate D is disqualified by O(N) latency. Candidate C satisfies every criterion: bounded families, per-family optimization, per-family freshness, and open-ended query support.

## Decision

**Indexes are organized into families defined by the DIR's fundamental access patterns.** Each family serves a class of structurally similar retrieval queries. The number of families is bounded and derived from the DIR's structure — not from the number of consumer queries. Each family has its own freshness policy, invalidation path, and rebuild strategy. New consumer queries are served by existing families; new families are added only when a genuinely new access pattern class is identified.

---

## Index Families

The DIR's structure (DAS-002) and the entity/relationship models (DAS-004, DAS-005) produce five fundamental access patterns. Each access pattern defines an index family.

### Derivation

The atomic unit contract has ten fields. Of these, five create distinct structural access needs:

1. **Subject** (entity or entity pair) → "give me everything about entity E" → **Entity Index**
2. **Subject** (entity pair with direction) → "traverse from entity E along relationship predicate P" → **Graph Index**
3. **Predicate** × **Tier** × **Status** → "find all units matching predicate P at tier T with status S" → **Predicate Index**
4. **Value** (text-type values in semantic predicates) → "find entities whose semantic properties mention keyword K" → **Content Index**
5. **Containment hierarchy** (the `contains` relationship tree from DAS-004) → "give me everything within scope S (file, module, system)" → **Scope Index**

The remaining fields (id, confidence, provenance, version, grounding) are not primary access axes — they are filtering dimensions applied to results obtained through the five primary indexes. A query "find all units about entity E with confidence ≥ high" uses the Entity Index to find E's units, then filters by confidence. The filtering does not require a separate index.

---

### Family 1: Entity Index

**Purpose.** Enable retrieval of all atomic units whose subject includes a specific entity. This is the most fundamental access pattern: "tell me everything the DIR knows about entity E."

**Query patterns served.**
- Retrieve all units about entity E (single-entity and paired-entity subjects where E appears as source or target).
- Retrieve all units about entity E with predicate P.
- Retrieve all units about entity E at tier T.
- Retrieve all property units about entity E (single-entity subjects only).
- Retrieve all relationship units involving entity E (paired-entity subjects where E is source or target).

**Source data.** All atomic units in the DIR. The index maps entity identifiers to the set of unit identifiers whose subjects include that entity.

**Index projection.** Entity identifier → set of (unit identifier, predicate, tier, status). Full unit content is retrieved from the DIR when needed. The projection is sufficient to answer "does E have any units with predicate P at tier T?" without retrieving full units.

**Freshness requirements.** The Entity Index must be as fresh as the freshest tier it indexes:
- T0 units about E must be reflected immediately when they change (source-synchronous, per DAS-003).
- T1 units must be reflected after propagation delay.
- T2 units follow eventual freshness.
In practice, the Entity Index is updated as part of the same pipeline that produces new units: when a pass emits a new unit about E, the index entry for E is updated in the same operation.

**Tier interaction.** The Entity Index is tier-agnostic — it indexes units at all tiers. A consumer may request "all T0 units about E" or "all units about E regardless of tier." The index supports tier filtering but does not maintain separate structures per tier.

**Failure impact.** Loss of the Entity Index prevents entity-centric retrieval — the most common access pattern. Impact: **high**. All entity-based queries degrade to DIR scan. Rebuild priority: **highest**.

---

### Family 2: Graph Index

**Purpose.** Enable traversal of the DIR's relationship graph. Given an entity E and a relationship predicate P, efficiently find all entities connected to E by P — both forward (E is source) and inverse (E is target). This is the access pattern that supports impact analysis, dependency tracing, call graph navigation, and composition.

**Query patterns served.**
- Forward traversal: "what does entity E call?" (all targets where E is source of `calls`).
- Inverse traversal: "what calls entity E?" (all sources where E is target of `calls`).
- Multi-hop traversal: "what does E transitively depend on?" (follow `dependsOn` edges recursively).
- Typed traversal: "what types does E conform to?" (all targets of `conformsTo` from E).
- Neighborhood: "all entities directly connected to E by any relationship" (all neighbors regardless of predicate).
- Filtered traversal: "what does E call at T0 confidence?" (forward `calls` edges with tier/confidence filtering).

**Source data.** All paired-entity atomic units in the DIR — the twenty-four relationship predicates defined in DAS-005.

**Index projection.** (source entity, predicate) → set of (target entity, unit identifier, tier, status) and, bidirectionally, (target entity, predicate) → set of (source entity, unit identifier, tier, status). The bidirectional structure satisfies DAS-005 R-DIR-2: inverse relationships are derived by query reversal, not by storing inverse units. The Graph Index makes inverse access O(degree) without duplicating relationship units in the DIR.

**Freshness requirements.** Relationship freshness follows the tier of the relationship unit:
- T0 relationships (most structural and behavioral relationships — 13 of 24 predicates are T0-only) must be fresh source-synchronously.
- T1 relationships (derived by rule-based passes) must be fresh with propagation delay.
- T2 relationships (inferred by semantic passes) follow eventual freshness.
The Graph Index is updated when passes produce or invalidate relationship units.

**Tier interaction.** The Graph Index indexes relationships at all tiers. A consumer performing impact analysis may request only T0 relationships (deterministic confidence). A consumer exploring architectural patterns may include T1 and T2 relationships. The index supports tier filtering on traversal.

**Failure impact.** Loss of the Graph Index prevents relationship traversal — required for impact analysis, composition, and cross-entity queries. Impact: **high**. Rebuild priority: **high** (second only to Entity Index, because entity-centric queries can still return property units without the Graph Index).

---

### Family 3: Predicate Index

**Purpose.** Enable retrieval of all units carrying a specific predicate, optionally filtered by tier and status. This is the access pattern that supports questions like "find all entities with a role classification" or "find all T2 behavioral characterizations" or "find all invalidated units from producer X."

**Query patterns served.**
- Predicate query: "all units with predicate `hasRole`" (find everything classified).
- Predicate + tier query: "all T0 units with predicate `hasReturnType`" (find deterministic type information).
- Predicate + status query: "all invalidated units with predicate `hasPurpose`" (find stale semantic content for re-enrichment).
- Provenance query: "all units produced by pass `roleClassifier` version 2.1" (find units for batch re-evaluation after pass upgrade — DAS-006 PINV-4).
- Tier-only query: "all T2 units" (find all semantic content).

**Source data.** All atomic units in the DIR. The index maps predicate identifiers (and optionally tier, status, provenance) to sets of unit identifiers.

**Index projection.** Predicate → set of (unit identifier, subject, tier, status, provenance.producer). The projection supports filtering without retrieving full units. Subject is included to enable "find all entities that have predicate P" without a secondary lookup.

**Freshness requirements.** The Predicate Index follows the freshness of the units it indexes. When a pass produces a new unit with predicate P, the index entry for P is updated. Freshness varies by tier: T0 predicate entries are source-synchronous; T2 entries are eventual.

**Tier interaction.** The Predicate Index is the primary mechanism for tier-level queries. A consumer asking "what fraction of entities have T2 enrichment?" queries the Predicate Index for T2 predicates. A scheduling system asking "which entities lack T2 enrichment?" queries for entities present in T0 but absent in T2.

**Failure impact.** Loss of the Predicate Index prevents predicate-based and provenance-based queries. These are primarily operational and administrative queries (monitoring enrichment coverage, batch re-evaluation). Consumer-facing queries typically start from entities (Entity Index) or relationships (Graph Index), not from predicates. Impact: **moderate**. Rebuild priority: **moderate**.

---

### Family 4: Content Index

**Purpose.** Enable retrieval of entities whose text-type atomic unit values contain specific terms or phrases. This is the access pattern that supports natural-language search over the DIR's semantic content: finding entities by what they do, what they are for, or how they behave — as described in T1 and T2 text values.

**Query patterns served.**
- Term search: "find entities whose purpose mentions 'authentication'" (search T2 `hasPurpose` values).
- Phrase search: "find entities described as 'dependency injection container'" (search text values for a phrase).
- Multi-predicate search: "find entities whose purpose or behavioral description mentions 'caching'" (search across multiple text-valued predicates).

**Source data.** Atomic units whose values are text-type (DAS-002 value types: Text and possibly String when semantically meaningful). In practice, this is primarily T1 classificatory values and T2 semantic values — deterministic text values (T0) such as function names and type identifiers are better served by the Entity Index.

**Index projection.** Term → set of (unit identifier, subject, predicate). The projection enables "which entities mention term T in which predicates?" without retrieving full unit content. Full text is retrieved from the DIR when needed for display.

**Freshness requirements.** The Content Index derives from text-type values, which are predominantly T1 and T2 content. Its freshness follows the eventual freshness contract of T2 (DAS-003): the Content Index may be stale relative to the most recent semantic enrichment. This is acceptable because content search is inherently fuzzy — a consumer searching for "authentication" accepts approximate results. The Content Index is rebuilt or incrementally updated when semantic passes complete, not on every source change.

**Tier interaction.** The Content Index primarily indexes T1 and T2 text values. T0 text values (entity names, type names) are searchable through the Entity Index by identifier matching. The Content Index complements the Entity Index for cases where the consumer knows *what something does* but not *what it is named*.

**Failure impact.** Loss of the Content Index prevents term-based search. Consumers can still access entities by identifier (Entity Index), by relationship (Graph Index), or by predicate (Predicate Index). Content search is a convenience for discovery, not a requirement for core operations. Impact: **low**. Rebuild priority: **low**.

---

### Family 5: Scope Index

**Purpose.** Enable retrieval of all entities and units within a structural scope — a file, a module, a package, or a system. This is the access pattern that supports scoped queries: "give me everything in module M," "what changed in file F," "what is the composition of system S."

**Query patterns served.**
- Scope membership: "all entities contained (directly or transitively) in scope S."
- Scoped units: "all units about entities in scope S."
- Scope boundary: "all relationships where one endpoint is in scope S and the other is not" (identifies cross-scope dependencies).
- Scope hierarchy: "what scope contains entity E?" and "what scopes does scope S contain?"

**Source data.** The `contains` relationship tree (DAS-004 I2, DAS-005) and the entity containment hierarchy. The Scope Index is derived from the `contains` edges in the Graph Index but is maintained as a separate structure because scope queries require transitive closure — "all entities in module M" includes entities in files in M, and entities in types in files in M, recursively.

**Index projection.** Scope entity → set of (contained entity identifiers, depth in containment tree). The projection enables "which entities are in scope S?" without traversing the containment tree at query time. Depth enables shallow scope queries ("entities directly in M, not transitively").

**Freshness requirements.** The Scope Index derives from `contains` relationships, which are T0 (DAS-005: `contains` is T0 from file system, manifests, source syntax). The Scope Index must be source-synchronous: when a file is added to or removed from a module, the Scope Index must reflect the change before any scoped query is served.

**Tier interaction.** The Scope Index is tier-independent — it indexes containment structure, not unit content. Scoped queries combine the Scope Index (to determine which entities are in scope) with the Entity Index or Graph Index (to retrieve those entities' units). The Scope Index itself contains only structural information (containment), which is always T0.

**Failure impact.** Loss of the Scope Index prevents scoped queries. Entity-centric queries (Entity Index) and relationship queries (Graph Index) still function, but questions like "what is in module M?" require traversing the `contains` tree through the Graph Index — feasible but slower. Composition passes (DAS-006) that operate at module or system scope depend on scope resolution. Impact: **moderate to high**. Rebuild priority: **high** (because it derives from T0 containment relationships, which are always available, making rebuild cheap and fast).

---

## Summary of Index Families

| # | Family | Access Pattern | Source Data | Freshness | Failure Impact | Rebuild Priority |
|---|--------|---------------|-------------|-----------|---------------|-----------------|
| 1 | Entity | "Everything about entity E" | All units (by subject) | Tier-aligned | High | Highest |
| 2 | Graph | "Traverse from E along P" | Paired-entity units | Tier-aligned | High | High |
| 3 | Predicate | "All units with predicate P" | All units (by predicate) | Tier-aligned | Moderate | Moderate |
| 4 | Content | "Entities mentioning term T" | Text-valued units (T1, T2) | Eventual | Low | Low |
| 5 | Scope | "Everything in scope S" | `contains` relationships | Source-synchronous | Moderate–High | High |

**Five families, derived from the DIR's structure.** The families are not chosen by expected query volume or consumer preference. They are derived from the structural axes of the atomic unit contract: subject (Entity, Graph), predicate (Predicate), value (Content), and containment (Scope). No other structural axis in the DIR requires a dedicated index family.

---

## Index Lifecycle

### Creation

Indexes are created during initial DIR construction (batch mode — DAS-006) or on first demand. Creation is a full build from the relevant DIR content.

**IL-1: An index need not exist for the system to function.** A missing index does not prevent the DIR from being queried — it prevents the query from being efficient. The system may fall back to DIR scan for any query that a missing index would have served. This is consistent with DAS-001 P12 (graceful degradation): missing indexes reduce performance, not correctness.

**IL-2: Index creation order follows rebuild priority.** When building indexes from scratch (initial startup or recovery), indexes are created in priority order: Entity, Graph, Scope, Predicate, Content. This ensures that the most critical access patterns become available first.

### Maintenance

Indexes are maintained incrementally as DIR content changes. When a pass produces new units or a frontend re-extracts a file:

**IL-3: Index updates are driven by DIR changes.** The index maintenance system observes DIR changes (new units, invalidated units, superseded units) and updates the affected indexes. This is the same change event mechanism that drives incremental pass re-execution (DAS-006 PE-3). The index maintenance system is a consumer of these events, not a producer.

**IL-4: Index updates are per-family.** A new relationship unit triggers an update to the Graph Index. A new text-valued unit triggers an update to the Content Index. A new entity triggers an update to the Entity Index, and possibly the Scope Index if containment changes. Each family's update is independent.

### Destruction

Indexes may be destroyed (deleted) at any time without data loss (DAS-002 I8). Reasons for destruction include: corruption detected, schema change requiring rebuild, or space reclamation.

**IL-5: Index destruction does not affect the DIR.** The DIR is the source of truth. Destroying an index removes only the derived optimization structure. The DIR remains complete and queryable (via scan).

---

## Index Ownership and Authority

### The DIR Is Authoritative

**IO-1: Indexes contain no authoritative data.** Every byte in every index is derivable from the DIR. If the DIR and an index disagree, the DIR is correct and the index must be rebuilt. This is a restatement of DAS-002 I8 but is elevated here because it has specific implications for index design: no index may accumulate state that cannot be reconstructed from the DIR.

**IO-2: Indexes do not write to the DIR.** Indexes are read-only projections. The data flow is: DIR → Index, never Index → DIR. An index does not produce atomic units, modify atomic units, or influence pass execution.

**IO-3: Indexes are not shared across DIR instances.** If multiple DIR instances exist (e.g., for different branches or worktrees), each has its own indexes. Sharing indexes across DIR instances would create cross-instance staleness problems.

### Who Maintains Indexes

**IO-4: Index maintenance is a system responsibility, not a pass responsibility.** Passes produce DIR content. The index maintenance system updates indexes in response to DIR changes. No pass directly modifies any index. This separation ensures that passes are unaware of which indexes exist — consistent with DAS-002's boundary design (passes write to DIR; indexes derive from DIR).

---

## Index Invalidation

### When Indexes Become Stale

An index entry becomes stale when the DIR content it derives from changes. Staleness sources:

**INV-1: Unit creation.** A new atomic unit is created (by a frontend or pass). If the unit's subject, predicate, or value matches an index family's source data, the corresponding index entry must be added.

**INV-2: Unit invalidation.** An existing unit is invalidated (DAS-002 lifecycle: Active → Invalidated). The index entry referencing that unit must be updated to reflect the new status — or removed, depending on the index family's policy on invalidated units.

**INV-3: Unit supersession.** An existing unit is superseded by a new unit with the same subject and predicate (DAS-002 I-LC-3). The index entry for the old unit must be replaced by an entry for the new unit.

### Invalidation Policies

Each index family has a policy for handling invalidated units:

**Entity Index:** Invalidated units are retained in the index with their status. A consumer querying the Entity Index may request Active-only or Active-and-Invalidated units (DAS-002 retrieval defaults). The Entity Index reflects the DIR's lifecycle faithfully.

**Graph Index:** Invalidated relationship units are retained with status. A consumer traversing the graph may include or exclude invalidated edges. This supports DAS-001 P12: a stale relationship edge is preferable to a missing one when the replacement has not yet been computed.

**Predicate Index:** Invalidated units are retained with status. This supports operational queries ("how many units are stale?") and scheduling decisions ("which entities need re-enrichment?").

**Content Index:** Invalidated units may be removed from the index. Content search is inherently approximate — stale entries in the content index produce misleading search results without the graceful degradation benefit that stale entries provide in the Entity and Graph indexes. Removing invalidated entries from the Content Index is safe because the consumer's expectation of precision is already low.

**Scope Index:** Invalidated containment relationships are immediately removed. The containment tree must be structurally consistent (DAS-004 I2) — a stale containment edge can produce incorrect scope membership, which cascades to incorrect scoped queries across all other indexes.

---

## Incremental Index Maintenance

### How Indexes Stay Current

**IIM-1: Index maintenance is incremental, not batch.** When a single unit changes in the DIR, only the affected index entries are updated — not the entire index. This is the index-level expression of DAS-001 P9 (incremental by design).

**IIM-2: Index update cost is proportional to the change, not the index size.** Adding one unit to the DIR triggers one index entry addition (or a constant number of additions across families). The cost is O(1) per unit change, not O(N) where N is the index size.

**IIM-3: Index updates follow the pass execution pipeline.** The sequence for a source change is:

1. Frontend re-extracts the changed file → new T0 units in the DIR.
2. Index maintenance updates Entity, Graph, Scope, Predicate indexes for the new T0 units.
3. T0/T1 passes re-execute on affected inputs → new T0/T1 units in the DIR.
4. Index maintenance updates indexes for the new T0/T1 units.
5. (Eventually) T2 passes re-execute → new T2 units in the DIR.
6. Index maintenance updates indexes (including Content Index) for the new T2 units.

Index updates interleave with pass execution. Each pass execution produces DIR changes; each DIR change triggers index updates; the updated indexes are available for the next pass and for consumers.

**IIM-4: Index updates are atomic per unit.** The index state is consistent with the DIR state at every point: no index entry references a unit that does not exist in the DIR, and no DIR unit that should be indexed is missing from the index. This consistency is maintained per-unit, not per-batch — there is no window where an index reflects some but not all of a batch of changes.

---

## Index Freshness Model

### Freshness Follows Tier

Index freshness is not a single property — it varies by the tier of the indexed content.

**IF-1: T0-derived index entries are source-synchronous.** Entity Index entries for T0 units, Graph Index entries for T0 relationships, and Scope Index entries for `contains` relationships are updated before any consumer query is served after a source change. This inherits directly from DAS-003's T0 freshness contract.

**IF-2: T1-derived index entries are source-synchronous with propagation delay.** Index entries for T1 units are updated after T1 passes re-execute, which occurs after T0 entries are updated. The delay is the T1 pass execution time.

**IF-3: T2-derived index entries are eventually fresh.** Index entries for T2 units are updated after T2 passes re-execute, which may be deferred. The Content Index, which primarily indexes T2 text, is the most tolerant of staleness.

### Freshness Guarantees for Consumers

**IF-4: A consumer query observes a consistent snapshot.** DAS-002 establishes point-in-time consistency for retrieval queries. Indexes must support this: a query that spans multiple index families (e.g., "all T0 units about entities in module M" — uses Scope Index + Entity Index) must observe a consistent DIR state across both indexes. The two indexes may not reflect different points in time.

**IF-5: A consumer can query the freshness state of an index.** For each index family, the system can report: when the index was last updated, how many stale entries exist, and what tier of content has pending updates. This supports observability (DAS-006 PO-3) and enables consumers to make informed decisions about result currency.

---

## Index Observability

**IOB-1: Index size.** For each index family: number of entries, approximate memory or storage footprint.

**IOB-2: Index freshness.** For each index family: timestamp of last update, count of stale entries (entries referencing invalidated or superseded DIR units that have not yet been reflected), breakdown by tier.

**IOB-3: Index query performance.** For each index family: query count, average query latency, tail query latency. This enables monitoring index health and detecting degradation.

**IOB-4: Index rebuild history.** When each index was last rebuilt, how long the rebuild took, and what triggered it (corruption, startup, schema change).

---

## Index Failure and Recovery

### Failure Modes

**IFR-1: Index corruption.** An index's internal state becomes inconsistent — entries reference nonexistent units, or entries are missing for existing units. Detection: periodic consistency checks comparing index entries against the DIR. Recovery: rebuild the corrupted index from the DIR.

**IFR-2: Index loss.** An index is entirely lost (storage failure, process restart without persistence). Detection: the index is missing. Recovery: rebuild from the DIR.

**IFR-3: Index divergence.** An index is structurally sound but does not reflect recent DIR changes — it is stale. Detection: the index's last-update timestamp is older than the most recent DIR change. Recovery: incremental catch-up — apply all DIR changes since the index's last-update point. If the change log is unavailable, rebuild.

### Rebuild Strategy

**IFR-4: Rebuilds are ordered by priority.** When multiple indexes need rebuilding, they are rebuilt in priority order: Entity (highest), Graph, Scope, Predicate, Content (lowest). This ensures that the most critical access patterns recover first.

**IFR-5: Rebuilds are incremental when possible.** If the index has a known-good state and the DIR change log is available, the index is repaired by applying missed changes rather than scanning the full DIR. Full rebuild is the fallback when incremental repair is infeasible.

**IFR-6: The system operates during rebuild.** While an index is being rebuilt, queries that would use that index fall back to DIR scan (slow but correct) or return partial results from the partially rebuilt index. The system does not block on index availability — consistent with DAS-001 P12 (graceful degradation).

**IFR-7: Rebuild is bounded.** An index rebuild from the DIR has bounded cost: O(N) where N is the number of DIR units in the index family's source data. Entity Index rebuild scans all units. Graph Index rebuild scans all paired-entity units. Scope Index rebuild scans only `contains` relationship units (fast). Content Index rebuild scans only text-valued units. The bounded cost means rebuild time is predictable and plannable.

---

## Architectural Consequences

**C1: Five index families, derived from the DIR's structure.** The index families are not chosen by consumer preferences, implementation convenience, or anticipated query volume. They are derived from the structural axes of the atomic unit contract: subject (Entity, Graph), predicate (Predicate), value (Content), and containment (Scope). This derivation ensures that the families are stable — they change only if the atomic unit contract changes.

**C2: Indexes are disposable.** Every index can be destroyed and rebuilt without data loss (DAS-002 I8). This means indexes are not architectural risks — they are performance optimizations that can be tuned, restructured, or replaced without affecting the DIR or any pass.

**C3: Index freshness inherits from tier freshness.** The index freshness model does not invent its own freshness guarantees — it inherits them from DAS-003. T0-derived entries are source-synchronous. T2-derived entries are eventual. This simplifies the freshness model: there is one freshness framework (DAS-003), not two (one for DIR, one for indexes).

**C4: Inverse traversal is an index capability, not a DIR capability.** DAS-005 R-DIR-2 states that inverse relationships are not stored. The Graph Index provides bidirectional access from unidirectional data. This architectural consequence means that inverse queries (e.g., "what calls F?") are O(degree) only when the Graph Index is available — without it, they require a full scan of paired-entity units.

**C5: Adding a new index family requires amending this chapter.** The five families defined here are the architectural index families. Implementation may add sub-indexes within families (e.g., partitioned Entity Indexes per file), but a genuinely new index family — serving a structurally novel access pattern — requires an amendment through DAS-000 Section 8. This prevents index proliferation.

**C6: No index may accumulate non-derivable state.** If any index contains information that cannot be reconstructed from the DIR, it is a shadow store (DAS-002 I1 violation). This constraint applies even to operational metadata: an index may track its own rebuild timestamp, but it may not track query history, access frequency, or consumer-specific state that is not derivable from the DIR.

**C7: Index maintenance cost is bounded by DIR change rate, not DIR size.** Incremental maintenance (IIM-1, IIM-2) ensures that the cost of keeping indexes current scales with how much the DIR changes, not with how large it is. For large codebases with small, frequent changes, index maintenance cost is small and constant.

---

## Invariants

**I1: Index Derivability.**
- **Statement:** Every index can be rebuilt from the DIR without data loss. No index contains information that is not derivable from the DIR. (Restatement of DAS-002 I8, elevated to the index chapter for emphasis.)
- **Rationale:** If an index contains non-derivable data, it is a shadow store that can diverge from the DIR. Divergence produces inconsistent query results. Derivability guarantees that indexes can be destroyed and rebuilt without consequence.
- **Verification:** Delete each index. Rebuild from the DIR. Confirm that the rebuilt index is functionally identical to the original.

**I2: DIR Authority.**
- **Statement:** When an index and the DIR disagree, the DIR is authoritative and the index must be updated or rebuilt. No consumer decision may be based on index state that contradicts DIR state.
- **Rationale:** The DIR is the canonical asset (DAS-001 P1). Indexes are derived views. If a consumer receives stale or contradictory index results, the consumer makes decisions based on incorrect information. DIR authority eliminates this class of error.
- **Verification:** Introduce a controlled inconsistency between an index and the DIR. Confirm that the system detects the inconsistency and resolves it in favor of the DIR.

**I3: No Index Writes to DIR.**
- **Statement:** No index produces, modifies, or deletes atomic units in the DIR. Data flows from DIR to indexes, never from indexes to DIR.
- **Rationale:** If indexes could write to the DIR, they would become producers — subject to the pass contract (DAS-006), tier constraints (DAS-003), and grounding requirements (DAS-002). Indexes are optimized for query performance, not for knowledge production. Mixing the two responsibilities would violate DAS-001 P11 (boundaries define independent variability).
- **Verification:** Audit all index operations. Confirm no operation creates, modifies, or deletes an atomic unit in the DIR.

**I4: Consistent Snapshots.**
- **Statement:** A retrieval query that spans multiple index families observes a consistent DIR state across all families. No query observes a state where one index reflects a DIR change and another does not.
- **Rationale:** DAS-002 establishes point-in-time consistency for retrieval. If a query uses the Scope Index to find entities in module M, then uses the Entity Index to retrieve those entities' units, both indexes must reflect the same DIR state. Otherwise, the query may return units for entities that are no longer in M (or miss units for entities recently added to M).
- **Verification:** Introduce a DIR change that affects multiple index families. Issue a cross-family query during the update. Confirm that the query observes either the pre-change state or the post-change state — not a mix.

**I5: Bounded Rebuild.**
- **Statement:** Every index can be rebuilt in time proportional to the size of its source data — not the size of the full DIR or the age of the index.
- **Rationale:** Unbounded rebuild makes recovery unpredictable. A system that takes minutes to rebuild a small index (because it scans the full DIR) is a system that cannot recover gracefully from index loss. Bounded rebuild ensures that recovery time is proportional to the affected data, consistent with DAS-001 P9 (incremental by design — applied to recovery, not just to normal operation).
- **Verification:** Measure rebuild time for each index family. Confirm that rebuild time scales linearly with the number of DIR units in the family's source data.

**I6: Graceful Absence.**
- **Statement:** The absence of any index does not prevent the system from answering queries — it prevents the system from answering them efficiently. Every query that an index serves can also be answered by scanning the DIR directly.
- **Rationale:** DAS-001 P12 (graceful degradation) requires that subsystem unavailability reduces quality, not eliminates function. Indexes are performance optimizations. If an index is missing, queries degrade from O(1) or O(degree) to O(N) — slower, but correct.
- **Verification:** Remove each index individually. Confirm that all queries still return correct results (via DIR scan fallback), with degraded latency.

**I7: Index Family Completeness.**
- **Statement:** Every access pattern supported by the DIR's atomic unit contract is served by one of the five defined index families. No retrieval operation requires an index outside the five families.
- **Rationale:** If a legitimate access pattern cannot be served by any index family, the architecture has a gap. If it requires a sixth family, the family taxonomy is incomplete. If it can be served by an existing family (possibly with filtering), the taxonomy is complete.
- **Verification:** Enumerate all retrieval operations performed by consumers, passes, and the scheduling system. For each, identify which index family (or combination) serves it. Confirm no operation requires an undefined family.

---

## Non-Goals

This chapter does not:

- **Define the retrieval query algebra.** How consumers express queries — what operators exist, how they compose, what the query language looks like — is a concern for retrieval query design. This chapter defines what indexes exist and what access patterns they support. The query algebra operates on top of these indexes.

- **Define context assembly.** How retrieved units are filtered, prioritized, and shaped for a specific consumer and purpose is a DAS-009 concern. This chapter delivers units to retrieval; context assembly selects among them.

- **Define ranking or relevance scoring.** How retrieved results are ranked for relevance is a context assembly concern (DAS-009), not an index concern. Indexes return sets of matching entries; ranking is applied after retrieval.

- **Define storage realization.** How indexes are persisted on disk, what data structures are used, how memory is managed — these are DAS-012 (Storage Realization) concerns. This chapter defines the logical structure and architectural properties of indexes, not their physical implementation.

- **Prescribe specific technologies.** No database engine, search engine, graph engine, or data structure is specified. The index architecture is technology-independent. Each index family defines an access pattern and a projection — the realization layer selects the implementation.

- **Define how consumers select indexes.** Consumers do not select indexes directly. Consumers express queries; the retrieval system routes queries to the appropriate indexes. Index selection is an implementation concern of the retrieval system.

- **Define index partitioning or sharding.** Whether an index is partitioned by file, by module, by tier, or by any other dimension is an implementation concern. This chapter defines the logical structure of each index family.

---

## Open Questions

**Q1: Should the Entity Index and Graph Index be unified?** *(Non-blocking)*

The Entity Index maps entity identifiers to units. The Graph Index maps (entity, predicate) pairs to neighbor entities. Both are keyed by entity. A unified "Entity-Graph Index" could serve both access patterns from a single structure, reducing maintenance coordination. However, unification would make the index larger and potentially slower for pure entity lookups (which do not need adjacency information). At current scale, two separate indexes are simpler to reason about and maintain independently.

**Investigation approach:** Measure the overhead of maintaining two indexes versus one. If maintenance cost dominates query cost, unification is justified. If query performance dominates, separation is justified.

**Q2: Should the Content Index support structured queries?** *(Non-blocking)*

The current Content Index supports term-based search over text values. Some consumers may want structured queries: "find entities whose purpose is 'authentication' AND whose behavioral characterization mentions 'side effects.'" This is a conjunction over two text predicates — expressible as two Content Index queries with set intersection. Whether the Content Index should support this natively (as a structured query) or leave it to the retrieval layer (as composition of simple queries) affects index complexity.

**Investigation approach:** Enumerate consumer queries that require cross-predicate text search. If such queries are common and latency-sensitive, consider structured query support in the Content Index. If rare, leave to retrieval composition.

**Q3: Should the Scope Index pre-compute transitive closure?** *(Non-blocking)*

The Scope Index maps scope entities to their contained entities. Containment is transitive (DAS-005: `contains` is transitive). The index could store direct containment only (parent → children) or pre-compute transitive closure (ancestor → all descendants). Pre-computed transitive closure makes "all entities in module M" an O(1) lookup but increases update cost when containment changes. Direct containment makes updates cheap but requires traversal at query time.

**Investigation approach:** Measure the depth of typical containment trees. If depth is shallow (3–5 levels), traversal at query time is cheap and pre-computation is unnecessary. If depth is deep or variable, pre-computation may be justified.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              ├── DAS-004 (Entity Model)
              │     └── DAS-005 (Relationship Model)
              ├── DAS-006 (Pass Architecture)
              └── DAS-007 (this chapter — Index Architecture)
                    ├── DAS-008 (Retrieval Architecture)
                    │     └── DAS-009 (Context Assembly)
                    │           └── DAS-011 (Consumer Architecture)
                    ├── DAS-010 (Incremental Update Model)
                    └── DAS-012 (Storage Realization)
```

This chapter depends on:
- DAS-000: chapter structure, review checklist
- DAS-001: P1 (intelligence is canonical asset — indexes are not), P7 (relevance over completeness), P9 (incremental by design), P11 (boundaries define independent variability), P12 (graceful degradation)
- DAS-002: atomic unit contract (fields that define access patterns), index contract (I8 — derivability, authority), query semantics (retrieval defaults, point-in-time consistency), lifecycle model (Active, Invalidated, Superseded statuses)
- DAS-003: tier model (T0, T1, T2), freshness contracts (source-synchronous, propagation delay, eventual) — index freshness inherits from tier freshness
- DAS-004: entity types (subjects indexed by Entity Index), containment tree (indexed by Scope Index), scope-level entities
- DAS-005: relationship predicates (indexed by Graph Index), `contains` transitivity, inverse derivation (R-DIR-2 — Graph Index provides bidirectional access)
- DAS-006: pass execution pipeline (passes produce the DIR changes that drive index updates), incremental re-execution (index updates interleave with pass execution)

This chapter is depended on by:
- DAS-008 (Retrieval Architecture): retrieval queries the DIR through indexes; it depends on understanding what access patterns are available and what freshness guarantees they provide
- DAS-010 (Incremental Update Model): incremental update must coordinate DIR changes with index maintenance; it depends on the index invalidation and maintenance model defined here
- DAS-012 (Storage Realization): storage must persist the five index families; it depends on understanding their structure, size, and rebuild characteristics

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub titled "Retrieval Model" with section
    headings and open questions. Scope included both indexes and query algebra.
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the index architecture.
    Renamed from "Retrieval Model" to "Index Architecture" to reflect focused scope. Five
    index families derived from the DIR's structural access patterns: Entity, Graph,
    Predicate, Content, Scope. Index lifecycle, freshness model, invalidation policies,
    incremental maintenance, failure and recovery defined. Seven invariants. Three open
    questions. Supersedes the DAS-007 stub which defined section headings only.
```
