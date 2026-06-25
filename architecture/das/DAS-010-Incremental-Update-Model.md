# DAS-010: Incremental Update Model

```
Chapter:       DAS-010
Title:         Incremental Update Model
Status:        Draft
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-006, DAS-007
Depended By:   DAS-011, DAS-012
Supersedes:    DAS-010 (Incremental Update Model — stub, never approved)
Superseded By: —
Layer:         L2
```

## Abstract

This chapter defines the incremental update model — how the DIR stays current as source code changes. Source code changes continuously. The DIR must reflect those changes without rebuilding from scratch. This chapter defines how changes are detected, how invalidation propagates through the DIR's grounding chains, where propagation stops, how recomputation is scheduled across tiers, how write-read consistency is maintained during updates, and how indexes are kept synchronized with DIR content. It selects a grounding-chain invalidation architecture with entity-level granularity over full-rebuild, file-level, and unit-level alternatives.

## Motivation

DAS-002 defines the DIR as a living representation of software. DAS-006 defines passes that transform the DIR incrementally. DAS-003 defines freshness contracts that each tier must honor. But none of these chapters defines the *coordination model* — the system-level architecture that detects changes, determines what is stale, decides what to recompute, and ensures that the DIR transitions from one consistent state to another.

Without this chapter, five problems arise:

1. **Invalidation scope is undefined.** DAS-002 I-GND-3 states that invalidation of a unit makes all transitively dependent units "candidates for invalidation." But who evaluates candidates? How far does the cascade extend? DAS-006 PINV-1 through PINV-3 define when passes re-execute, but the system-level coordination — which units are invalidated, in what order, before which passes re-execute — is unspecified. Without a defined invalidation model, the system either over-invalidates (marks everything stale, causing excessive recomputation) or under-invalidates (misses transitively dependent units, serving stale content as if it were current).

2. **Recomputation scheduling is ad hoc.** DAS-003 defines three freshness contracts: T0 is source-synchronous, T1 has propagation delay, T2 is eventual. DAS-006 PS-1 through PS-4 define scheduling priorities. But the interaction between freshness contracts and scheduling priorities is unspecified. When a file changes and 50 T0 units are invalidated, which cascade to T1, which cascade to T2, and which T2 units are deferred — this is the incremental update model's core responsibility. Without it, freshness contracts are aspirational rather than enforced.

3. **Write-read consistency is unaddressed.** During an update — while the system is invalidating old units, re-executing passes, and writing new units — what does a concurrent consumer query see? If the query sees a mix of old and new units (some entities updated, others not), the consumer receives an internally inconsistent view. If the query blocks until the entire update completes, latency spikes on large changesets. Without a defined consistency model, the system cannot guarantee that consumers see a coherent view of the DIR.

4. **Index maintenance is uncoordinated.** DAS-007 defines five index families that are derived views of the DIR. When DIR content changes, indexes must be updated. But when? Synchronously with every unit change? After a batch of changes? Lazily on query? Without coordination between DIR updates and index maintenance, indexes may be stale (returning units that have been invalidated), missing (not containing newly created units), or inconsistent (containing a mix of old and new content).

5. **The boundary between the update model and storage is undefined.** DAS-012 defines how the DIR is persisted. This chapter defines how the DIR is updated. The boundary between them — what the update model requires from storage (atomic writes, snapshot reads, invalidation markers) and what storage provides — must be explicit. Without this boundary, the update model assumes storage capabilities that may not exist, or storage provides capabilities that the update model does not exploit.

**Source dependencies:**
- [DAS-001 P3](DAS-001-Architectural-Principles.md) — deterministic before semantic
- [DAS-001 P9](DAS-001-Architectural-Principles.md) — incremental by design
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — atomic unit lifecycle (I-LC-1 through I-LC-5), grounding chain (I-GND-1 through I-GND-4), version contract (I-VER-1 through I-VER-4), provenance (I-PROV-1, I-PROV-2)
- [DAS-003](DAS-003-Tier-Model.md) — freshness contracts (T0 source-synchronous, T1 propagation delay, T2 eventual), invalidation cascade (upward only), cross-tier dependencies (CTD-1, CTD-2, CTD-3), lifecycle properties (TL-1, TL-2, TL-3)
- [DAS-006](DAS-006-Pass-Architecture.md) — pass execution contracts (PE-3 through PE-6), invalidation contracts (PINV-1 through PINV-5), scheduling priorities (PS-1 through PS-4), pass DAG (I1 acyclicity)
- [DAS-007](DAS-007-Index-Architecture.md) — index derivability (I8), index freshness, five index families

## Terminology

**Incremental Update** — The process by which the DIR transitions from one consistent state to another in response to source code changes, without rebuilding from scratch. An incremental update detects what changed, invalidates what is stale, recomputes what must be refreshed, and maintains indexes — all while preserving write-read consistency. *Is:* a developer saves a file, and within milliseconds the DIR's T0 and T1 content about entities in that file is current; within seconds, affected indexes are current; T2 enrichment is scheduled for eventual recomputation. *Is not:* a full re-parse of the codebase; a batch job that runs periodically; a cache invalidation (which merely deletes — the update model invalidates, recomputes, and transitions). `INTRODUCED`

**Change Event** — A notification that a source artifact has been modified, created, or deleted. Change events are the input to the incremental update model. Each change event identifies the artifact (by path), the nature of the change (content modification, creation, deletion, rename), and the new content hash. *Is:* "file `/src/auth.swift` was modified; new content hash is `a7b3c9`." *Is not:* a diff (the change event does not carry the delta — the system re-parses to determine structural changes). `INTRODUCED`

**Invalidation** — The process of marking a unit as potentially stale because the evidence supporting it may have changed. Invalidation transitions a unit from Active to Invalidated status (DAS-002 I-LC-2). Invalidated units remain queryable but are flagged — consumers can distinguish current from stale content. Invalidation is not deletion; it is a status transition that triggers recomputation. *Is:* "the function signature of `authenticate` changed; the unit `(authenticate, hasBehavioralCharacterization, ...)` is invalidated because it was derived from the old signature." *Is not:* deletion (the invalidated unit persists until superseded); recomputation (which produces the replacement). `INTRODUCED`

**Invalidation Cascade** — The process by which invalidation propagates from directly invalidated units to transitively dependent units through grounding chains (DAS-002 I-GND-3). The cascade follows the derivation direction: T0 invalidation cascades to dependent T1 units, T1 invalidation cascades to dependent T2 units. Cascade propagation is bounded by tier-specific policies: T0 and T1 cascades are synchronous; T2 cascades are deferred. *Is:* "invalidating a T0 entity unit about function `authenticate` cascades to the T1 classification unit that derives from it, which cascades to the T2 behavioral characterization that derives from the classification." *Is not:* unbounded (cascade depth is finite, governed by grounding chain depth and tier boundaries). `INTRODUCED`

**Change Set** — The complete set of source-level changes that constitute a single logical update. A change set groups one or more change events into an atomic processing unit. The system processes change sets, not individual change events, to maintain consistency — all files saved in a single editor action form one change set. *Is:* "files `auth.swift` and `auth_tests.swift` were both saved; they form one change set." *Is not:* a git commit (change sets track working-tree state, not committed state). `INTRODUCED`

**Recomputation** — The process of producing new, current units to replace invalidated ones. Recomputation invokes the appropriate producer (frontend or pass) to regenerate the unit from current inputs. The new unit supersedes the invalidated unit (DAS-002 I-LC-3). *Is:* "the T1 classification pass re-executes on function `authenticate` using the updated T0 entity units, producing a new T1 classification unit that supersedes the invalidated one." *Is not:* invalidation (which marks staleness); pass execution in general (recomputation is specifically the re-execution triggered by invalidation). `INTRODUCED`

**Update Epoch** — A monotonically increasing counter that identifies a consistent state of the DIR. Each completed change set processing advances the epoch. Queries reference an epoch to obtain a consistent snapshot. *Is:* "epoch 42 represents the DIR state after processing the 42nd change set." *Is not:* a timestamp (epochs are logical, not temporal); a version (which is per-unit, per DAS-002 I-VER-1). `INTRODUCED`

**Cascade Boundary** — A point in the invalidation cascade where synchronous propagation stops and deferred propagation begins. Cascade boundaries are tier-dependent: the boundary between T1 and T2 is a cascade boundary — T1 invalidation cascades synchronously, but T2 invalidation is deferred to eventual recomputation. *Is:* "T0 and T1 invalidations are processed synchronously within the change set; T2 invalidations are recorded for deferred processing." *Is not:* a point where invalidation stops entirely — deferred invalidation still occurs, just not synchronously. `INTRODUCED`

## Domain Analysis

### The Incremental Update Problem

Source code changes continuously during development. A developer may save a file every few seconds. Each save may change entity signatures, add or remove relationships, alter control flow, or restructure containment hierarchies. The DIR must reflect these changes, but the cost of reflecting them must be proportional to the size of the change, not the size of the codebase (DAS-001 P9).

The incremental update problem has four sub-problems:

**Sub-problem 1: Change Detection.** Given a source artifact that has been modified, determine what structurally changed. A raw file diff is insufficient — "line 42 was modified" does not tell the system which entities, predicates, or relationships were affected. The system must compare the old and new parse results to identify structural changes at entity granularity.

**Sub-problem 2: Invalidation Scope.** Given a set of structurally changed entities, determine which DIR units are stale. This requires traversing grounding chains (DAS-002 I-GND-3): a unit whose grounding chain passes through a changed unit is a candidate for invalidation. The challenge is bounding this traversal — in a densely connected DIR, every unit is transitively connected to every other.

**Sub-problem 3: Recomputation Order.** Given a set of invalidated units, determine the order in which they should be recomputed. DAS-003 TL-1 dictates tier-based ordering (T0 first, then T1, then T2). DAS-006 PS-1 through PS-4 define additional priorities (change proximity, consumer demand, budget constraints). The challenge is scheduling recomputation so that freshness contracts are honored without blocking consumers.

**Sub-problem 4: Consistency During Updates.** During recomputation, the DIR is in a transitional state — some units are current, some are invalidated, some are being recomputed. The system must define what consumers see during this transition and what guarantees they receive about the consistency of query results.

### Change Detection: What Changes?

Source code changes are detected at the file level — the file system reports that a file was modified, created, deleted, or renamed. But the DIR operates at entity level — it stores units about entities (functions, types, modules), not about files. The change detection subsystem must bridge this gap.

**File-level detection** is the entry point. When a file changes (detected via file system events or polling), the system knows that some entities in that file may have changed. But which ones?

**Entity-level detection** compares the old and new parse results for the changed file. The frontend re-parses the file, producing a new set of T0 atomic units. The system compares the new units against the prior units for entities in that file. The comparison operates at the semantic level — the system compares subjects, predicates, and values, not raw text. This comparison produces three sets:

1. **Added entities:** entities present in the new parse but absent in the old. New entities require fresh T0 units with no invalidation cascade (nothing depends on them yet).
2. **Removed entities:** entities present in the old parse but absent in the new. Removed entities require invalidation of all units about them and all transitively dependent units.
3. **Modified entities:** entities present in both parses but with different unit values. Modified entities require invalidation of changed units and their transitive dependents.

For modified entities, the comparison is predicate-by-predicate: if entity E's `hasSignature` unit changed but its `hasName` unit did not, only units whose grounding chains include the `hasSignature` unit are candidates for invalidation.

**Content-hash optimization.** DAS-002 I-VER-3 specifies content-addressed versioning: two source states with identical content produce the same version. The change detection subsystem exploits this: if the file's content hash is unchanged (the file was saved without modification, or was reverted), no structural comparison is needed and no invalidation occurs. This eliminates unnecessary work for save-without-change events, branch switches that revert to a prior state, and format-only changes that do not alter AST structure.

### Working Tree Tracking

The DIR tracks working tree state, not committed state. Decode is a real-time development tool — users expect intelligence about the code they are currently editing, not the code they last committed. The content hash (DAS-002 I-VER-3) is computed from the file's current content on disk, regardless of git status.

**Consequence:** The DIR may contain intelligence about uncommitted, experimental, or incomplete code. This is correct behavior — the user is working on that code now and needs understanding of it now. If the user reverts to a prior state, the content-hash optimization ensures that the DIR returns to the prior state without unnecessary recomputation (provided the prior units have not been garbage collected).

**Non-goal:** Tracking multiple versions simultaneously (e.g., the committed state and the working tree state, or multiple branches) is not addressed. The DIR represents a single state of the source material at any given time. Multi-version support, if needed, would require architectural changes to the DIR contract and is deferred.

### Invalidation Propagation

Invalidation propagates through grounding chains. DAS-002 I-GND-3 establishes the principle: "If any unit in a grounding chain is invalidated, all units that transitively depend on it are candidates for invalidation." This chapter defines the specific propagation model.

**Propagation direction.** Invalidation propagates upward through tiers: T0 → T1 → T2. This is a consequence of DAS-003 CTD-1 through CTD-3: T0 units derive only from source, T1 units derive from T0 (and possibly other T1), T2 units derive from T0, T1, and other T2. A T0 change can cascade to T1 and T2. A T1 change can cascade to T2 and other T1. A T2 change can cascade to other T2. No change at any tier cascades downward.

**Candidate evaluation.** Not every candidate for invalidation is actually invalidated. When a T0 unit is invalidated and recomputed, the new value may be identical to the old value. In this case, the downstream T1 units that depend on it are no longer candidates — their inputs have not actually changed. This is the early termination mechanism (DAS-006 PE-5): if a recomputed unit produces an identical result, the cascade stops.

**Propagation depth.** In a typical codebase, the invalidation cascade for a single-file change is shallow:
1. **Depth 0 (source):** The changed file.
2. **Depth 1 (T0):** T0 units about entities in the changed file, produced by frontends.
3. **Depth 2 (T1):** T1 units that derive from the changed T0 units (classifications, derived properties).
4. **Depth 3 (T2):** T2 units that derive from the changed T0/T1 units (behavioral characterizations, design analysis).
5. **Depth 4+ (cross-entity):** Units about other entities whose grounding chains include the changed entity (e.g., a caller's behavioral characterization that references the changed callee's signature).

Depth 4+ is where cascades can become expensive. A widely-called utility function, when modified, cascades to every caller's T1 and T2 units. The cascade boundary mechanism (defined below) limits the cost of deep cascades.

### Cross-File Invalidation

A change in file A can invalidate units about entities in file B, if entities in B have grounding chains that reference entities in A. This occurs through relationship edges: if entity B.foo calls A.authenticate, and A.authenticate's signature changes, B.foo's `calls` relationship is still valid but its behavioral characterization (which was derived partly from understanding what `authenticate` does) may be stale.

Cross-file invalidation is the reason the invalidation model operates on grounding chains rather than file boundaries. A file-level invalidation model would miss these cross-file dependencies. A grounding-chain model catches them because the cross-file dependency is explicit in the grounding chain of B.foo's T2 unit.

**Scope boundaries.** Cross-file invalidation respects entity scope boundaries defined in DAS-004. When a change in file A affects entity A.foo, the cascade to file B is through the relationship `B.bar calls A.foo`. The scope boundary is the module or package containing A and B — if A and B are in different modules, the cascade crosses a module boundary. The update model does not introduce additional boundaries beyond those implied by grounding chains. If a cross-module dependency exists in the grounding chain, the invalidation follows it. Artificial boundaries (e.g., "don't cascade across module boundaries") would cause stale content to be served as current.

## Candidates

This section evaluates four candidate architectures for incremental updates.

### Candidate A: Full Rebuild

On any source change, discard all DIR content and rebuild from scratch: re-parse all files, re-execute all passes in DAG order, rebuild all indexes.

**Strengths:** Trivially correct — the result is always a completely fresh DIR. No invalidation logic needed. No consistency concerns during updates (the entire DIR is replaced atomically).

**Weaknesses:** Cost is proportional to codebase size, not change size — directly violates DAS-001 P9 (incremental by design). For a codebase with 1,000 files, a one-line change triggers parsing of 1,000 files, execution of every pass over every entity, and rebuilding of every index. T2 passes that invoke AI would require thousands of API calls per file save. Completely impractical for real-time development use.

### Candidate B: File-Level Invalidation

Track changes at file granularity. When file F changes, invalidate all units whose grounding chains reference file F. Re-parse F, re-execute passes over F's entities, cascade to cross-file dependents at file granularity.

**Strengths:** Simple change detection (file system events). Clear invalidation boundary (the file). Moderate recomputation cost (only passes over the changed file, plus cross-file cascades).

**Weaknesses:** Over-invalidation. Changing a comment in a 500-line file invalidates every unit about every entity in that file — even entities whose structural properties are unchanged. This triggers unnecessary T1 and T2 recomputation for entities that were not actually affected. The over-invalidation is mitigated by early termination (PE-5): if the re-parsed T0 units are identical, no cascade occurs. But the re-parsing cost is real (re-parse the entire file, compare all entities), and for files with many entities, the comparison cost is non-trivial. Cross-file cascades at file granularity are even worse — if entity A.foo changed but entity A.bar did not, all entities in files that reference any entity in A are candidates, even those that only reference A.bar.

### Candidate C: Entity-Level Invalidation with File-Level Detection

Detect changes at file level (file system events). Determine structural changes at entity level (compare old and new parse results). Invalidate at unit level via grounding chains, but scope the cascade by entity — only units whose grounding chains include a changed entity's units are invalidated.

**Strengths:** Precise invalidation — only units actually affected by the change are invalidated. The content-hash optimization eliminates no-op saves. Entity-level comparison catches the common case where a change affects one entity in a multi-entity file. Cross-file cascades are scoped to entities that actually depend on the changed entity, not to all entities in the file.

**Weaknesses:** Requires entity-level comparison infrastructure (diff old and new parse results, match entities across parses by identity). Entity identity matching across parses must handle renames, moves, and restructuring — a renamed function is the "same" entity with a different name, or a "different" entity? The comparison logic must be defined precisely.

### Candidate D: Unit-Level Invalidation

Track and compare individual units. On each file change, re-parse and compare every unit against its prior value. Invalidate only units whose values actually changed.

**Strengths:** Finest possible granularity — zero over-invalidation. Every invalidation is justified by an actual value change.

**Weaknesses:** The per-unit tracking overhead is proportional to the total number of units, not the number of changed units. For a file with 20 entities and 15 predicates per entity, that is 300 unit comparisons per file save. The overhead is modest for a single file but scales linearly with the number of units in the DIR. More critically, the unit-level model does not improve cascade precision over entity-level — if a unit about entity E changes, the cascade through grounding chains is identical regardless of whether the invalidation was detected at unit level or entity level. The additional granularity adds complexity without meaningful benefit.

## Evaluation

| Criterion | Full Rebuild | File-Level | Entity-Level + File Detection | Unit-Level |
|-----------|-------------|------------|-------------------------------|------------|
| Satisfies DAS-001 P9 (incremental) | **No** — cost proportional to codebase | Partial — unnecessary recomputation | **Yes** — cost proportional to change | Yes — but marginal gain over entity |
| Invalidation precision | N/A (rebuilds all) | Over-invalidates (all entities in file) | **Precise** (only changed entities) | Finest (individual units) |
| Cross-file cascade precision | N/A | Coarse (all entities in referencing files) | **Precise** (only dependent entities) | Precise (same as entity) |
| Implementation complexity | Trivial | Low | **Moderate** | High |
| Change detection cost | Trivial (detect nothing) | Trivial (file events) | **Moderate** (file events + entity comparison) | High (unit-by-unit comparison) |
| Early termination benefit | N/A | High (mitigates over-invalidation) | **Moderate** (less over-invalidation to mitigate) | Low (little to mitigate) |
| Satisfies DAS-003 freshness contracts | Yes (trivially) | Yes (with early termination) | **Yes** | Yes |
| Satisfies DAS-001 P12 (degradation) | No (all-or-nothing) | Yes | **Yes** | Yes |
| Practical for real-time use | **No** | Marginal | **Yes** | Yes — with overhead |

**Disqualified:** Full Rebuild (violates P9 absolutely). Unit-Level (higher complexity than entity-level with equivalent cascade precision — the marginal granularity gain does not justify the tracking overhead).

**Remaining candidates:** File-Level and Entity-Level. Entity-Level is strictly superior: it achieves file-level's change detection simplicity (same file system events) while eliminating the over-invalidation that is file-level's primary weakness. The entity-level comparison cost is modest — it is one comparison pass over the entities in a single changed file, amortized against the recomputation savings from precise invalidation.

## Decision

**The Decode incremental update model uses entity-level invalidation with file-level change detection, grounding-chain cascade propagation, tier-dependent cascade boundaries, and epoch-based write-read consistency.**

This architecture:
- Detects changes at file level (file system events + content hash comparison).
- Determines structural changes at entity level (compare old and new frontend parse results).
- Propagates invalidation through grounding chains (DAS-002 I-GND-3).
- Bounds cascade propagation with tier-dependent boundaries (T0/T1 synchronous, T2 deferred).
- Schedules recomputation by tier priority (DAS-003 TL-1), consumer demand (DAS-006 PS-3), and change proximity (DAS-006 PS-2).
- Maintains write-read consistency through update epochs (consumers query against a consistent epoch).
- Coordinates index maintenance as part of the change-processing pipeline.

---

## Change Detection

### File-Level Detection

The system monitors the file system for changes to source artifacts within the tracked scope. Change detection produces change events.

**CD-1: Content-hash comparison.** When a file change is reported, the system computes the new content hash and compares it to the stored content hash (DAS-002 I-VER-3). If the hashes match, no structural comparison is needed and no invalidation occurs. This eliminates save-without-change events, format-only changes (if the formatter does not alter AST structure), and branch switches that restore prior content.

**CD-2: Change event aggregation.** Multiple file change events within a short time window (e.g., a multi-file save from an IDE, or a branch switch that modifies many files) are aggregated into a single change set. The aggregation window is an implementation parameter, not an architectural constant — it balances latency (shorter windows process changes sooner) against efficiency (longer windows batch more changes, reducing per-change overhead).

**CD-3: Change event types.** The system distinguishes four change types:
- **Modified:** File exists at both old and new state with different content hashes. Triggers entity-level comparison.
- **Created:** File exists at new state but not at old state. Triggers fresh frontend parsing with no invalidation cascade (no prior units exist).
- **Deleted:** File exists at old state but not at new state. Triggers invalidation of all units about entities in the deleted file, plus cascade to cross-file dependents.
- **Renamed:** File moved or renamed. Treated as a combined delete + create, unless the system supports identity tracking across renames (an implementation choice — the architecture permits but does not require rename detection).

### Entity-Level Comparison

For modified files, the system re-parses the file via the appropriate frontend, producing a new set of T0 atomic units. It then compares the new units against the prior units for entities in that file.

**CD-4: Entity identity matching.** Entities across parses are matched by qualified name (DAS-004). An entity with the same qualified name in the old and new parse is the same entity. Entities present in the new parse but absent in the old are additions. Entities present in the old parse but absent in the new are removals. This matching is deterministic and unambiguous for entities with stable qualified names.

**CD-5: Predicate-level change detection.** For matched entities, the system compares units predicate by predicate. For each predicate P on entity E, the old and new values are compared. If they are identical, no invalidation is needed for P on E. If they differ, the unit `(E, P, old_value)` is invalidated and the new unit `(E, P, new_value)` is created. This predicate-level comparison is the mechanism by which entity-level invalidation avoids over-invalidation — changing a function's body does not invalidate its name, signature, or return type if those properties are unchanged.

**CD-6: Structural change classification.** The comparison produces a structural change record for each modified file:
- **Per entity:** added, removed, or modified (with the set of changed predicates).
- **Per relationship:** added, removed, or modified (if endpoint identity changed).
- **Per import:** added or removed.

This change record drives the invalidation cascade.

---

## Invalidation Propagation

### Direct Invalidation

**IP-1: Source-triggered invalidation.** When entity-level comparison identifies changed units (CD-5), those units are directly invalidated. Their status transitions from Active to Invalidated (DAS-002 I-LC-2). The new units (produced by re-parsing) supersede the invalidated units (DAS-002 I-LC-3).

**IP-2: Entity removal invalidation.** When an entity is removed (absent from new parse), all units with that entity as subject are invalidated. No replacement units are created — the entity no longer exists. Dependent units (via grounding chains) are also invalidated.

**IP-3: Entity addition.** When an entity is added (absent from old parse), new T0 units are created in Active status. No invalidation occurs — nothing depended on the previously non-existent entity. However, the new entity may satisfy previously unsatisfiable grounding references (e.g., a relationship edge to a previously-undefined entity). The update model does not retroactively validate prior invalidations.

### Cascade Propagation

**IP-4: Grounding-chain traversal.** For each directly invalidated unit U, the system identifies all units whose grounding chains include U (DAS-002 I-GND-3). These units are candidates for invalidation. The traversal follows the `inputs` field of provenance records (DAS-002 I-PROV-1): if unit V's provenance lists U among its inputs, V is a candidate.

**IP-5: Tier-ordered cascade.** Invalidation propagates in tier order: T0 units are invalidated and recomputed first, then T1, then T2. This ordering is required by DAS-003 I5 (Freshness Ordering): no higher-tier claim may be fresher than the lower-tier claims it derives from. Processing T0 before T1 before T2 ensures that when a T1 pass re-executes, its T0 inputs are already current.

**IP-6: Early termination.** When a recomputed unit produces a value identical to its predecessor (DAS-006 PE-5), the cascade stops for that branch. Downstream units are no longer candidates — their inputs have not changed. Early termination is the primary cost-control mechanism: in practice, most single-file changes affect a small number of predicates, and early termination prevents the cascade from reaching deep cross-file dependents whose values are unchanged.

### Cascade Boundaries

**CB-1: T0-T1 boundary (synchronous).** T0 invalidation cascades synchronously to T1. When a T0 unit is invalidated and recomputed, T1 units that depend on it are invalidated within the same change set processing. T1 passes re-execute as part of the synchronous pipeline. This honors the T1 freshness contract: source-synchronous with propagation delay (DAS-003).

**CB-2: T1-T2 boundary (deferred).** T1 invalidation cascades to T2, but T2 recomputation is deferred. When a T1 unit is invalidated and recomputed, T2 units that depend on it are marked as invalidated but not immediately recomputed. T2 recomputation occurs on consumer demand (DAS-006 PS-3) or background scheduling. This honors the T2 freshness contract: eventual (DAS-003).

**CB-3: T2-T2 boundary (deferred).** T2 invalidation may cascade to other T2 units (DAS-003 CTD-3: within-T2 derivation is permitted). These cascades are also deferred. T2-to-T2 cascades are the most expensive in the system (each step may invoke AI), and the eventual freshness contract permits deferral.

**CB-4: Cross-entity cascade limit.** For a single change set, the cascade is bounded by the set of units reachable through grounding chains from the directly invalidated units. The system does not impose an artificial depth limit — the grounding chain determines the boundary. However, the combination of early termination (IP-6) and tier-boundary deferral (CB-2, CB-3) ensures that in practice, the synchronous cascade (T0 + T1) is shallow (typically depth 2-3 from the changed entity) and the deferred cascade (T2) is processed incrementally over time.

---

## Recomputation Scheduling

### Synchronous Pipeline

The synchronous pipeline processes T0 and T1 recomputation within the change set processing window. This pipeline runs before any consumer query against the new epoch.

**RS-1: Frontend re-execution.** For each changed file, the appropriate frontend re-parses the file, producing new T0 units. This is the first step of the synchronous pipeline.

**RS-2: T0 pass re-execution.** T0-producing passes whose invalidation surfaces include the changed entities re-execute (DAS-006 PINV-1). The pass DAG order determines execution sequence (DAS-006 I1 acyclicity ensures a valid order).

**RS-3: T1 pass re-execution.** T1-producing passes whose invalidation surfaces include the changed or newly-produced T0 content re-execute (DAS-006 PINV-2). T1 passes execute after all relevant T0 passes have completed, honoring the tier ordering (DAS-003 TL-1, DAS-006 PS-1).

**RS-4: Synchronous pipeline completion.** The synchronous pipeline completes when all T0 and T1 passes have re-executed (or terminated early due to unchanged output). At this point, the DIR's T0 and T1 content is current with respect to the change set. The update epoch advances.

### Deferred Pipeline

The deferred pipeline processes T2 recomputation outside the change set processing window.

**RS-5: T2 invalidation recording.** During the synchronous pipeline, T2 units that are candidates for invalidation (due to T0 or T1 changes in their grounding chains) are marked invalidated but not recomputed. The system records the invalidated T2 units for deferred processing.

**RS-6: Consumer-demand recomputation.** When a consumer queries DIR content and the query result includes invalidated T2 units, the system may trigger recomputation of those specific T2 units before serving the result (DAS-006 PS-3: consumer-demand priority). This is the mechanism by which lazy T2 enrichment is triggered — a consumer requests behavioral characterization, the content is stale, and the semantic enrichment pass is scheduled with elevated priority.

**RS-7: Background recomputation.** T2 units that have not been recomputed by consumer demand are recomputed in background processing. Background recomputation respects budget constraints (DAS-006 PS-4): if the T2 pass invocation budget is exhausted, recomputation is deferred until budget is available. Background recomputation prioritizes by change proximity (DAS-006 PS-2) — the most recently changed entities are recomputed first.

**RS-8: T2 recomputation order.** When multiple T2 units require recomputation, the scheduling system orders them by:
1. Consumer demand (units requested by active consumers first).
2. Change proximity (units about recently changed entities next).
3. Derivation order (units that depend on other T2 units — DAS-003 CTD-3 — are recomputed after their T2 inputs).

### Semantic Enrichment Triggering

**RS-9: First-question trigger.** When an entity has no T2 enrichment (no semantic enrichment pass has ever been executed for it), the first consumer question about that entity triggers initial enrichment. This is not recomputation (there is no invalidated unit to replace) but initial computation. The scheduling system treats it identically to consumer-demand recomputation (RS-6) — the consumer's query triggers the semantic enrichment pass with elevated priority.

**RS-10: Enrichment freshness.** T2 enrichment is cached by content hash (DAS-002 I-VER-3). If the entity's underlying T0/T1 content has not changed since the last enrichment, the T2 enrichment is still valid and no recomputation is needed. If the content has changed, the T2 unit is invalidated via the standard cascade and scheduled for recomputation per RS-5 through RS-8.

---

## Write-Read Consistency

### Epoch-Based Consistency

**WR-1: Update epochs.** Each completed change set processing advances the update epoch. The epoch is a monotonically increasing counter. The DIR is consistent at each epoch — all T0 and T1 content is current with respect to the source state at that epoch. T2 content may be invalidated but is flagged.

**WR-2: Snapshot queries.** Consumer queries execute against a specific epoch. The query sees all units that were Active at that epoch and all units that were Invalidated but not yet superseded at that epoch. No partially-processed change sets are visible — the consumer sees either the pre-change state or the post-change state, never a mix.

**WR-3: Epoch advancement.** The epoch advances atomically when the synchronous pipeline (RS-4) completes. This ensures that the new epoch represents a consistent state: all T0 and T1 recomputation for the change set is complete, all indexes are updated (see below), and all invalidated T2 units are recorded.

**WR-4: Concurrent change sets.** If a new change event arrives while a change set is being processed, the new event is queued for the next change set. Change sets are processed sequentially — they are not interleaved. This simplifies the consistency model: each epoch corresponds to exactly one change set, and the DIR transitions from one consistent state to the next.

**WR-5: Query during processing.** If a consumer issues a query while a change set is being processed, the query executes against the prior epoch (the last completed state). The consumer does not see partially-processed changes. When the current change set completes and the epoch advances, subsequent queries will reflect the updated state.

### Invalidated Content Visibility

**WR-6: Invalidated units are queryable.** Invalidated units remain in the DIR and are returned by queries. They carry an invalidation flag that consumers can inspect. This supports graceful degradation (DAS-001 P12): a consumer that receives invalidated T2 content can still use it (with reduced confidence) rather than receiving nothing.

**WR-7: Invalidation metadata.** Invalidated units carry metadata indicating when they were invalidated (which epoch) and why (which upstream change triggered the cascade). This metadata enables consumers to make informed decisions: a T2 unit invalidated 2 seconds ago is likely still useful; a T2 unit invalidated 2 hours ago may be substantially stale.

---

## Index Maintenance

### Synchronous Index Updates

**IM-1: Index updates within the synchronous pipeline.** When the synchronous pipeline produces new or invalidated units, the affected indexes are updated before the epoch advances. This ensures that queries against the new epoch see consistent index content — no index returns a superseded unit that the DIR no longer contains, and no index is missing a newly created unit.

**IM-2: Affected index identification.** Not all index families are affected by every change. The update model identifies which indexes need updating based on the change type:
- **Entity Index:** Updated when units about an entity are created, invalidated, or superseded.
- **Graph Index:** Updated when relationship units change (entity added/removed, relationship predicate changed).
- **Predicate Index:** Updated when units with any predicate are created, invalidated, or superseded.
- **Content Index:** Updated when text-valued units change (may be deferred — see IM-4).
- **Scope Index:** Updated when containment relationships change (entity moved, file restructured).

**IM-3: Index update ordering.** Entity and Graph indexes are updated first (they support the most latency-sensitive queries). Scope and Predicate indexes are updated next. Content Index updates may be deferred.

**IM-4: Deferred index updates.** The Content Index (DAS-007) supports full-text search over text-valued predicates. Content Index updates are more expensive than structural index updates. The update model permits Content Index updates to lag the epoch by a bounded number of epochs — the Content Index is eventually consistent with the DIR, but not synchronous. This trade-off is acceptable because Content Index queries are less latency-sensitive than entity or graph queries.

### Index Rebuild

**IM-5: Index rebuildability.** All indexes are derived views of the DIR (DAS-007 I8: derivability). If an index becomes corrupted or loses consistency, it can be rebuilt from the current DIR state without data loss. Rebuild does not require re-parsing source or re-executing passes — the DIR is the source of truth for indexes.

**IM-6: Rebuild triggers.** Index rebuild may be triggered by:
- Detection of index inconsistency (an index entry references a unit that does not exist in the DIR, or a DIR unit has no corresponding index entry).
- Schema evolution (a new predicate is added that requires indexing; the Predicate Index is rebuilt to include it).
- Producer upgrade (a pass upgrade changes the predicates it produces; the Content Index may need rebuild to reflect new text values).

---

## Producer Upgrade Invalidation

**PU-1: Producer identification.** Every unit records its producer in its provenance (DAS-002 I-PROV-2). The system can identify all units produced by a specific frontend version or a specific pass version.

**PU-2: Upgrade-triggered invalidation.** When a producer is upgraded (new parser version, new pass logic), all units produced by the old version are candidates for re-evaluation (DAS-006 PINV-4). The system queries for all units with the old producer version in their provenance and marks them for recomputation.

**PU-3: Upgrade scope.** Producer upgrade invalidation is equivalent to a batch change event that touches every entity the producer has processed. The recomputation follows the standard scheduling model: T0 passes re-execute first, then T1, then T2. Early termination (IP-6) prevents unnecessary cascades where the upgraded producer produces identical output.

**PU-4: Frontend upgrade.** When a frontend (parser) is upgraded, all T0 units produced by the old frontend version are re-evaluated. The new frontend re-parses every file it covers, and entity-level comparison (CD-4, CD-5) determines which entities actually changed. Entities with unchanged output avoid cascading invalidation.

**PU-5: Pass upgrade.** When a pass is upgraded, all units produced by the old pass version are re-evaluated. The new pass re-executes over its full scope (every entity in its scope, not just recently changed entities), and output comparison determines which results actually changed.

---

## Garbage Collection Policy

**GC-1: Garbage collection is the removal of units that are no longer useful.** A unit is eligible for garbage collection when it has been superseded (DAS-002 lifecycle: Active → Superseded → Garbage Collected) and no consumer, index, or grounding chain references it.

**GC-2: Tier-informed retention.** Garbage collection retention is informed by tier (DAS-003 TL-3):
- T0 and T1 superseded units are eligible for immediate collection — they are cheap to recompute if ever needed again.
- T2 superseded units are retained longer — they are expensive to recompute (AI invocation). Retained T2 units serve as fallback content during graceful degradation.

**GC-3: Garbage collection does not block updates.** Garbage collection runs as a background process, not as part of the synchronous pipeline. It does not affect epoch advancement or query consistency.

**GC-4: Storage realization.** The specific garbage collection schedule, retention durations, and storage reclamation mechanisms are DAS-012 (Storage Realization) concerns. This chapter defines what is eligible for collection and the tier-informed retention policy. DAS-012 defines how collection is implemented.

---

## Architectural Consequences

**C1: Update cost is proportional to change size, not codebase size.** Entity-level invalidation with early termination ensures that a single-file change triggers recomputation only for units actually affected by the change. This is the realization of DAS-001 P9: incrementality is not an optimization — it is an architectural property of the update model.

**C2: Freshness contracts are enforced, not aspirational.** The synchronous pipeline (RS-1 through RS-4) enforces T0 and T1 source-synchronous freshness. The deferred pipeline (RS-5 through RS-8) enforces T2 eventual freshness. DAS-003's freshness contracts are no longer "the update model should honor these" — they are "the update model does honor these, by construction."

**C3: The DIR is always queryable.** Epoch-based consistency (WR-1 through WR-5) ensures that consumers always see a consistent state. No query blocks indefinitely. No query returns partially-processed data. The worst case is that a query sees the prior epoch while a new change set is being processed — the result is consistent but may not include the latest changes.

**C4: T2 staleness is visible, not hidden.** Invalidated T2 units are returned with invalidation metadata (WR-6, WR-7). Consumers can distinguish current T2 content from stale T2 content. This supports DAS-001 P12 (graceful degradation) and DAS-003's T2 freshness contract: stale T2 is preferable to absent T2.

**C5: Early termination is the primary cost-control mechanism.** Without early termination, a change to a widely-used entity would cascade through every dependent entity at every tier. With early termination, the cascade stops as soon as a recomputed unit produces unchanged output. In practice, most changes affect values (function bodies, implementation details) rather than interfaces (signatures, types, relationships), and early termination stops the cascade at T0 — the entity's structural properties are unchanged, so no T1 or T2 recomputation is needed.

**C6: The synchronous and deferred pipelines enforce the tier contract.** T0 and T1 are always current (synchronous pipeline). T2 may be stale but is always flagged (deferred pipeline). This two-pipeline structure is the update model's expression of DAS-003's tier freshness hierarchy.

**C7: Producer upgrades are a batch change, not a special case.** Upgrade invalidation (PU-1 through PU-5) reuses the standard invalidation and recomputation machinery. No special-purpose upgrade logic is needed. This simplifies the system and ensures that upgrades honor the same freshness contracts and consistency guarantees as source changes.

**C8: Index maintenance is coordinated, not independent.** Indexes are updated as part of the synchronous pipeline (IM-1), not as independent background processes. This ensures that consumer queries against a new epoch see consistent DIR and index content. The exception is the Content Index (IM-4), which may lag for efficiency — a trade-off that is explicitly architectural, not an implementation accident.

---

## Invariants

**I1: Epoch Consistency.**
- **Statement:** At every update epoch, all T0 and T1 units in the DIR are current with respect to the source state at that epoch. No T0 or T1 unit is invalidated.
- **Rationale:** T0 source-synchronous and T1 propagation-delay freshness (DAS-003) require that these tiers are current before consumer queries are served. An epoch with invalidated T0 units would serve provably-stale deterministic facts — an architectural defect.
- **Verification:** At each epoch boundary, query all T0 and T1 units. Confirm none have Invalidated status. If any do, the synchronous pipeline failed to complete before epoch advancement.

**I2: Cascade Directionality.**
- **Statement:** Invalidation propagates only from lower tiers to higher tiers (T0 → T1 → T2). No invalidation cascade propagates downward.
- **Rationale:** Downward propagation would mean a T2 change invalidates T0 content — a semantic inference affecting deterministic facts. This violates DAS-003 CTD-1 (T0 derives only from source) and DAS-001 P3 (deterministic before semantic).
- **Verification:** Trace every invalidation cascade. Confirm that for every (invalidator, invalidated) pair, the invalidator's tier is less than or equal to the invalidated's tier.

**I3: Early Termination Correctness.**
- **Statement:** If a recomputed unit produces a value identical to its predecessor, no downstream unit is invalidated as a result of that recomputation.
- **Rationale:** Unnecessary cascades waste computation and may trigger unnecessary T2 AI invocations. The correctness condition is: identical input produces identical output for deterministic passes (DAS-006 PC-IDEM-1), so downstream passes would also produce identical output. For semantic passes, identical input may produce different output (non-determinism) — but the semantic pass has not been re-invoked, so no cascade occurs.
- **Verification:** Identify every early-termination point. Confirm that the recomputed unit's value matches its predecessor's value. Confirm that no downstream unit was invalidated.

**I4: Change Set Atomicity.**
- **Statement:** Each change set is processed atomically — either all T0 and T1 recomputation for the change set completes and the epoch advances, or none of it is visible to consumers. No partial change set is observable.
- **Rationale:** A partially-processed change set violates consistency — consumers would see a state where file A is updated but file B (saved in the same action) is not. Sequential change set processing (WR-4) ensures atomicity.
- **Verification:** Issue queries during change set processing. Confirm that the query returns the prior epoch's data, not a mix of old and new.

**I5: Grounding Chain Completeness.**
- **Statement:** Every unit whose grounding chain includes a directly invalidated unit is itself marked as a candidate for invalidation. No transitively dependent unit is missed.
- **Rationale:** A missed unit would remain Active while its grounding chain includes an invalidated unit — the unit appears current but its supporting evidence may have changed. This is the worst kind of staleness: invisible.
- **Verification:** For each directly invalidated unit, traverse all grounding chains that include it. Confirm that every unit in those chains is either invalidated, recomputed with unchanged output (early termination), or at a deferred tier (T2) and marked invalidated.

**I6: Content-Hash Idempotency.**
- **Statement:** If a file's content hash is unchanged, no invalidation or recomputation occurs for that file, regardless of the file system event type.
- **Rationale:** DAS-002 I-VER-3 specifies content-addressed versioning. Same content = same version = same DIR state. Processing a no-op change wastes resources and may trigger unnecessary cascades if the comparison logic has imprecision.
- **Verification:** Save a file without modification. Confirm that no units are invalidated, no passes re-execute, and no index updates occur.

**I7: Index-DIR Consistency.**
- **Statement:** At every update epoch, every structural index (Entity, Graph, Scope, Predicate) is consistent with the DIR at that epoch. No index entry references a superseded or garbage-collected unit. No active unit is missing from an index that should contain it.
- **Rationale:** Inconsistent indexes return stale or absent results, undermining the retrieval layer (DAS-008) and everything downstream. Structural index consistency is a prerequisite for correct retrieval.
- **Verification:** At each epoch, compare index contents against DIR contents. Confirm bijection between active units and their index entries for each structural index.

**I8: Sequential Change Set Processing.**
- **Statement:** Change sets are processed sequentially. No two change sets are processed concurrently. Each change set completes before the next begins.
- **Rationale:** Concurrent change set processing would require complex conflict resolution (what if change set A and change set B both affect the same entity?). Sequential processing eliminates concurrency conflicts and simplifies the consistency model. The serialization cost is acceptable because change set processing (including the synchronous pipeline) should complete within milliseconds for typical changes.
- **Verification:** Instrument the change set processing pipeline. Confirm that no overlap exists between consecutive change set processing windows.

---

## Non-Goals

This chapter does not:

- **Define how file system events are captured.** Whether changes are detected via FSEvents, inotify, polling, or editor integration is an infrastructure concern. This chapter requires only that change events are delivered with the file path and new content hash.

- **Define how entity identity is preserved across renames.** Whether a renamed function is treated as the same entity (with an updated name) or as a removal + addition is an implementation decision. Both produce correct DIR states — the choice affects only recomputation cost (rename detection avoids unnecessary T1/T2 recomputation of the renamed entity's derived content).

- **Define the content-hash algorithm.** SHA-256, xxhash, or any other hash function that produces unique hashes for distinct content is acceptable. The algorithm is an implementation choice.

- **Define the epoch counter implementation.** Whether epochs are stored as integers, UUIDs, or timestamps is a DAS-012 concern. This chapter requires only that epochs are monotonically increasing and comparable.

- **Define storage mechanisms for invalidation state.** How invalidated units are marked, how deferred T2 invalidation queues are persisted, and how epoch snapshots are managed are DAS-012 concerns.

- **Define the pass DAG.** The structure and ordering of passes is defined in DAS-006. This chapter defines how the update model interacts with the pass DAG (triggering re-execution, respecting ordering), not what the DAG contains.

- **Define consumer-side caching.** How consumers cache context frames, explanations, or other outputs that depend on DIR content is a consumer concern (DAS-011). This chapter defines how the DIR stays current; how consumers detect that their cached outputs are stale is outside scope.

- **Prescribe implementation technologies.** No file watcher library, queue implementation, scheduler framework, or concurrency model is specified.

---

## Open Questions

**Q1: Should the update model support partial-file change detection?** *(Non-blocking)*

The current model re-parses the entire changed file and compares at entity level. An alternative would accept a byte range or AST-level delta from the editor (via LSP or similar), enabling the system to skip re-parsing and directly identify changed entities. This would reduce latency but requires editor integration that may not be universally available.

**Investigation approach:** Measure re-parse latency for typical file sizes. If latency is under 50ms for files up to 1,000 lines, full re-parse is sufficient and editor integration is unnecessary complexity. If latency is significant, consider accepting editor-provided deltas as an optimization.

**Q2: Should the deferred pipeline have a staleness budget?** *(Non-blocking)*

The current model defers T2 recomputation indefinitely (bounded only by consumer demand and background scheduling). An alternative would define a staleness budget: "no T2 unit should remain invalidated for more than N minutes." This would provide a freshness guarantee beyond eventual, but would require background AI invocations that consume budget even when no consumer is asking questions.

**Investigation approach:** Monitor T2 invalidation durations in production. If most T2 units are recomputed within minutes (due to consumer demand), no staleness budget is needed. If many T2 units remain stale for hours, consider a staleness budget with tier-informed prioritization.

**Q3: Should change sets support rollback?** *(Non-blocking)*

The current model processes change sets atomically and advances the epoch on completion. If a change set processing fails (e.g., a frontend crashes during re-parsing), the epoch does not advance and the system remains at the prior consistent state. But if the failure is persistent (the file contains a syntax error that crashes the parser), the system cannot advance past this epoch. A rollback mechanism would allow the system to advance the epoch while recording the failed entities.

**Investigation approach:** Enumerate failure modes for frontend parsing. If frontends can handle malformed source gracefully (producing partial results or error markers rather than crashing), rollback is unnecessary. If frontends can fail unrecoverably on certain inputs, define a partial-success model.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              │     └── DAS-010 (this chapter — Incremental Update Model)
              ├── DAS-006 (Pass Architecture)
              │     └── DAS-010 (this chapter — also depends on DAS-006)
              ├── DAS-007 (Index Architecture)
              │     └── DAS-010 (this chapter — also depends on DAS-007)
              └── ...
```

This chapter depends on:
- DAS-000: chapter structure, review checklist
- DAS-001: P3 (deterministic before semantic — T0/T1 before T2), P9 (incremental by design — cost proportional to change), P12 (graceful degradation — stale content preferable to absent)
- DAS-002: atomic unit lifecycle (I-LC-1 through I-LC-5 — Active/Invalidated/Superseded status transitions), grounding chain (I-GND-1 through I-GND-4 — cascade invalidation mechanism), version contract (I-VER-1 through I-VER-4 — content-addressed versioning, per-file granularity), provenance (I-PROV-1, I-PROV-2 — producer identification for upgrade invalidation)
- DAS-003: freshness contracts (T0 source-synchronous, T1 propagation delay, T2 eventual — the requirements the update model enforces), cross-tier dependencies (CTD-1 through CTD-3 — invalidation propagation direction), lifecycle properties (TL-1 recomputation priority, TL-3 garbage collection eligibility), invariants (I3 derivation monotonicity, I5 freshness ordering)
- DAS-006: pass execution (PE-3 scoped re-execution, PE-4 termination guarantee, PE-5 early termination, PE-6 semantic pass propagation), invalidation triggers (PINV-1 through PINV-5), scheduling priorities (PS-1 through PS-4), pass DAG (I1 acyclicity — ensures recomputation terminates)
- DAS-007: index derivability (I8 — indexes are rebuildable from DIR), five index families (Entity, Graph, Predicate, Content, Scope — the indexes that must be maintained during updates)

This chapter is depended on by:
- DAS-011 (Consumer Architecture): consumers must understand epoch-based consistency, invalidation visibility, and T2 staleness to correctly interpret DIR content
- DAS-012 (Storage Realization): storage must support the atomic epoch advancement, invalidation state tracking, and garbage collection policies defined here

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub with section headings and open questions.
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the incremental update model.
    Entity-level invalidation with file-level detection selected over full-rebuild, file-level,
    and unit-level alternatives. Grounding-chain cascade propagation with tier-dependent
    boundaries defined. Synchronous pipeline (T0+T1) and deferred pipeline (T2) enforce
    freshness contracts. Epoch-based write-read consistency. Coordinated index maintenance.
    Producer upgrade invalidation via provenance. Tier-informed garbage collection policy.
    Eight invariants. Three open questions. Eight architectural consequences. Supersedes
    the DAS-010 stub.
```
