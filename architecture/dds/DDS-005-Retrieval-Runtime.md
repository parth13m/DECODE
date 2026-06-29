# DDS-005: Retrieval Runtime

```
Document:      DDS-005
Title:         Retrieval Runtime
Status:        Draft
Version:       0.2
Author:        Principal Engineer
Created:       2026-06-28
Last Revised:  2026-06-28
Reviewers:     —
Depends On:    DDS-000 (Design Authoring Standard), DDS-002 (DIR Runtime Model),
               DDS-004 (Index Runtime)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-005, DAS-007, DAS-008
```

## Abstract

This document specifies the engineering design of the Retrieval Runtime — the subsystem that executes multi-stage evidence retrieval over the canonical DIR using the Index Runtime. It defines the retrieval request lifecycle, the five-stage execution pipeline, query planning, budget enforcement, evidence annotation, consistency guarantees, degradation behavior, and failure handling. The Retrieval Runtime realizes the retrieval architecture from DAS-008. It is read-only: it never writes to the DIR or modifies indexes. It produces annotated evidence sets consumed by the Context Assembly subsystem. It does not perform context assembly, prompt construction, or relevance ranking beyond structural proximity.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P7 (relevance over completeness — budget-constrained evidence
            gathering, not exhaustive collection), P12 (graceful degradation
            — missing indexes degrade to DIR scan; absent tiers degrade to
            available tiers; budget exhaustion truncates, not fails)
  Not addressed: P1, P5, P6, P8 (DDS-002, DDS-001, DDS for Context Assembly),
                P2, P3, P4 (DDS-001, DDS-003 — execution ordering),
                P9 (DDS-001, DDS-004 — incremental maintenance),
                P10 (DDS for Consumer Architecture — scope parameterization),
                P11 (DDS-001 — producer independence)

DAS-002: Decode Intermediate Representation
  Realized: Retrieval defaults (Active-only unless explicit, unordered,
            point-in-time consistent, all fields queryable). Consumer
            contract (consumers read DIR via retrieval, degrade gracefully
            when tiers unavailable).
  Not addressed: Atomic unit contract fields (DDS-002:R2), lifecycle model
                (DDS-002:R4), identity (DDS-002:R5), immutability (DDS-002:R3),
                DC-1 through DC-5 (DDS-002, structural), I1 through I8
                (DDS-002, DDS-001, DDS-004)

DAS-003: Tier Model
  Realized: I7 (degradation validity — retrieval at any degradation level
            returns a valid, queryable subset). Tier floor/ceiling enforcement
            in retrieval requests. Confidence surfacing (TC-4: confidence
            carried through, not filtered by default). Freshness awareness
            (retrieval conveys index freshness metadata to consumers).
  Not addressed: I1 through I6 (DDS-002, DDS-001), tier assignment
                (DDS-002:R8, DDS-003), TL-1, TL-2, TL-3 (DDS-002,
                DDS for Storage Engine), freshness contracts enforcement
                (DDS-004, DDS for Update Engine)

DAS-005: Relationship Model
  Realized: R-DIR-2 (bidirectional traversal from unidirectional data —
            relational evidence stage uses Graph Index forward and inverse
            entries, per DDS-004 Graph Index construction)
  Not addressed: Relationship predicates definition (DAS-005),
                inverse derivation rules (DAS-005), relationship storage
                (DDS-002)

DAS-007: Index Architecture
  Realized: Query consumption of all five index families (Entity, Graph,
            Predicate, Content, Scope) via DDS-004:PC-1. IL-1 (missing
            index does not prevent queries — DIR scan fallback consumed
            by retrieval). I6 (graceful absence — retrieval degrades to
            DIR scan when any family is unavailable).
  Not addressed: Index maintenance (DDS-004:R3), index construction
                (DDS-004:R2), index ownership (DDS-004:R1), freshness
                management (DDS-004:R5), failure recovery (DDS-004:R6),
                all IIM invariants (DDS-004)

DAS-008: Retrieval Architecture
  Realized: Five-stage evidence retrieval pipeline (anchor resolution,
            direct evidence, relational evidence, scope evidence,
            annotation). RetrievalRequest and EvidenceSet contracts.
            RC-1 (completeness within horizon), RC-2 (soundness),
            RC-3 (consistent snapshot), RC-4 (deterministic anchor
            resolution). TC-1 (tier floor/ceiling), TC-3 (absent tiers
            do not fail), TC-4 (confidence surfaced), TC-5 (confidence
            floor). RF-1 through RF-5 (all failure modes). I1 through I8
            (all invariants).
  Not addressed: Retrieval request construction (DDS for Consumer
                Architecture — how intents are determined), lazy
                enrichment triggers (DDS for Update Engine),
                context assembly (DAS-009, DDS for Context Assembly)
```

## Terminology

**Retrieval Request** — A structured specification of what evidence to gather from the DIR. Contains: a subject (entity, snippet, or scope reference), an intent (which determines stage parameterization), a scope (retrieval breadth), tier floor and ceiling, an evidence budget, and a freshness requirement. `See DAS-008`

**Evidence Set** — The output of a retrieval execution. Contains: the resolved anchors, the original retrieval request, a collection of annotated units, and metadata describing retrieval execution (stages completed, budget consumed, fallbacks used, freshness state). The evidence set is the contract between the Retrieval Runtime and Context Assembly. `See DAS-008`

**Annotated Unit** — An atomic unit augmented with retrieval-specific metadata: evidence provenance (which stage produced it, the structural path from anchor), distance from anchor (hop count in the relationship graph), and the unit's tier and confidence carried through from the DIR. `See DAS-008`

**Query Plan** — The internal representation that translates a retrieval request's intent, scope, and budget into concrete parameters for each stage of the pipeline: which index families to query, which predicates to traverse, traversal depth limits, per-stage budget allocation, and tier/confidence filters. The query plan is deterministic given the same retrieval request. `INTRODUCED`

**Anchor** — A resolved entity reference that serves as the starting point for evidence gathering. Anchor resolution (stage 1) translates the retrieval request's subject into one or more concrete anchors. All subsequent stages gather evidence relative to these anchors. `See DAS-008`

**Traversal Plan** — The subset of a query plan that parameterizes the relational evidence stage: which relationship predicates to follow, traversal direction (forward, inverse, or both), maximum depth per predicate, and per-entity budget (maximum units gathered per traversed entity). The traversal plan is derived from the retrieval intent. `See DAS-008`

**Evidence Budget** — A numeric bound on the total evidence an individual retrieval may gather, expressed as a maximum unit count. The budget is allocated across stages and enforced during execution. Budget exhaustion truncates evidence gathering — it does not fail the retrieval. `See DAS-008`

---

## Responsibilities

```
R1: Execute multi-stage evidence retrieval against the DIR and indexes.
    DAS: DAS-008 (five-stage pipeline: anchor resolution, direct evidence,
         relational evidence, scope evidence, annotation)
    Boundary: The Retrieval Runtime executes the five-stage pipeline. It
              does not define retrieval intents (the consumer determines
              intent). It does not maintain indexes (DDS-004). It does not
              construct context frames from evidence (DDS for Context
              Assembly).

R2: Resolve retrieval subjects to entity anchors.
    DAS: DAS-008 RC-4 (deterministic anchor resolution), DAS-008 stage 1
    Boundary: The Retrieval Runtime resolves EntityReferences,
              SnippetReferences, and ScopeReferences to concrete entity
              anchors. For SnippetReferences, resolution uses source
              position to identify the containing entity. The Retrieval
              Runtime does not create entities — it resolves references
              to existing entities in the DIR.

R3: Plan index queries based on retrieval intent.
    DAS: DAS-008 (intent determines parameterization, not stage structure)
    Boundary: The Retrieval Runtime translates the retrieval request's
              intent, scope, and budget into a query plan that
              parameterizes each pipeline stage. The Retrieval Runtime
              does not define intent semantics — it consumes intent
              specifications to derive query parameters.

R4: Enforce evidence budget constraints.
    DAS: DAS-008 I6 (budget respect — evidence count does not exceed
         budget), DAS-008 RF-2 (budget exhaustion truncates, not fails)
    Boundary: The Retrieval Runtime allocates and tracks budget across
              stages. It never exceeds the budget. When budget is
              exhausted, it stops gathering evidence and records truncation
              in evidence set metadata. It does not determine optimal
              budget values — the caller specifies the budget.

R5: Annotate evidence with provenance, distance, and tier/confidence.
    DAS: DAS-008 I5 (evidence provenance completeness), DAS-008 stage 5
         (annotation)
    Boundary: Every unit in the evidence set carries evidence provenance
              (which stage produced it, the structural path from anchor),
              distance from anchor, and the unit's tier and confidence.
              The Retrieval Runtime does not assign relevance scores —
              that is Context Assembly's responsibility.

R6: Enforce tier and confidence constraints on evidence gathering.
    DAS: DAS-008 TC-1 (tier floor/ceiling), TC-3 (absent tiers do not
         fail), TC-4 (confidence surfaced), TC-5 (confidence floor),
         DAS-003 I7 (degradation validity)
    Boundary: The Retrieval Runtime filters evidence by the request's
              tier floor and ceiling. It surfaces confidence values on
              every annotated unit. When requested tiers are absent, it
              returns available tiers with metadata noting the absence.
              It does not assign tiers or confidence — those are unit
              properties set by producers and validated by the DIR
              Runtime (DDS-002:R8).

R7: Degrade gracefully when indexes or tiers are unavailable.
    DAS: DAS-008 RF-3 (index unavailable — DIR scan fallback),
         DAS-008 RF-4 (tier unavailable — return available tiers),
         DAS-008 I7 (tier monotonicity in degradation),
         DAS-001 P12 (graceful degradation)
    Boundary: When an index family is unavailable, the Retrieval Runtime
              uses DIR scan fallback via DDS-002:PC-3. When requested
              tiers are absent, it returns evidence from available tiers.
              Degradation is transparent to the caller via evidence set
              metadata. The Retrieval Runtime does not trigger index
              rebuilds — it consumes the Index Runtime's fallback
              behavior (DDS-004:PC-1 graceful degradation).

R8: Provide per-request retrieval observability.
    DAS: DAS-008 (retrieval correctness guarantees require observable
         verification)
    Boundary: The Retrieval Runtime emits per-request metrics (stages
              executed, budget consumed, fallbacks used, latency).
              Aggregation and dashboarding are outside scope.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Evidence Retrieval
  Direction:    Offered
  Counterparty: Context Assembly subsystem, scheduling subsystem,
                diagnostic consumers
  Guarantee:    Given a retrieval request (subject, intent, scope, tier
                floor/ceiling, budget, freshness requirement), the
                Retrieval Runtime executes the five-stage evidence
                retrieval pipeline and returns an evidence set.

                The evidence set contains:
                - The resolved anchors (one or more entity references).
                - The original retrieval request.
                - A collection of annotated units, each carrying evidence
                  provenance, distance from anchor, and tier/confidence.
                - Metadata: stages completed, budget consumed, budget
                  remaining, whether truncation occurred, index families
                  that used DIR scan fallback, tier availability at time
                  of retrieval, the committed epoch at which evidence was
                  gathered.

                The annotated units in the evidence set are in canonical
                deterministic order (see Evidence Ordering in Execution
                Model). The ordering is independent of execution timing
                and implementation concurrency — the same retrieval
                request against the same DIR state always produces the
                same evidence set in the same order.

                Correctness guarantees (per DAS-008):
                - RC-1 Completeness within horizon: every active unit
                  within the query plan's traversal horizon that satisfies
                  the tier and confidence filters is included (up to
                  budget).
                - RC-2 Soundness: every unit in the evidence set exists
                  in the DIR at the observed epoch with the reported
                  status.
                - RC-3 Consistent snapshot: all evidence in a single
                  evidence set observes the same committed epoch.
                - RC-4 Deterministic anchor resolution: the same subject
                  resolves to the same anchors given the same DIR state.

                Non-guarantees (per DAS-008):
                - RC-5: Retrieval does not guarantee relevance. Evidence
                  may include units that are structurally proximate but
                  not relevant to the consumer's purpose. Relevance
                  filtering is Context Assembly's responsibility.
                - RC-6: Retrieval does not guarantee sufficiency. The
                  evidence set may not contain everything needed for
                  a complete answer.

  Preconditions: The Retrieval Runtime is in Available state. The
                 retrieval request specifies a valid subject reference,
                 a recognized intent, and a positive evidence budget.
  Failure mode: If the subject cannot be resolved to any anchor (RF-1),
                the retrieval returns an evidence set with empty anchors
                and empty evidence, with metadata indicating "subject
                not found." This is not an exception — it is a valid
                (empty) evidence set.
                If the DIR Runtime is unavailable, the retrieval is
                deferred until the DIR Runtime becomes operational.

PC-2: Anchor Resolution
  Direction:    Offered
  Counterparty: Context Assembly subsystem, scheduling subsystem
  Guarantee:    Given a subject reference (EntityReference,
                SnippetReference, or ScopeReference), the Retrieval
                Runtime resolves it to concrete entity anchors without
                executing the full retrieval pipeline.

                Resolution behavior by subject type:
                - EntityReference: resolved directly via Entity Index
                  lookup. If the entity exists in the DIR, returns the
                  entity reference. If not, returns empty.
                - SnippetReference: resolved by source position. The
                  Retrieval Runtime identifies the entity whose source
                  range contains the snippet's position. Uses entity
                  line ranges from the Entity Index or DIR content. If
                  the snippet spans multiple entities, returns all
                  containing entities. If no entity contains the
                  position, falls back to the file-level scope entity
                  if that entity exists in the DIR. If neither a
                  containing entity nor the file scope entity exists,
                  returns empty anchors.
                - ScopeReference: resolved via Scope Index lookup.
                  Returns the scope entity if it exists.

                The Retrieval Runtime never synthesizes anchors — it
                resolves references to entities that already exist in
                the DIR. If no existing entity matches the subject
                reference, resolution returns empty.

                Anchor resolution is deterministic (DAS-008 RC-4): the
                same subject and DIR state always produce the same
                anchors.
  Preconditions: The Retrieval Runtime is in Available state. The
                 subject reference is well-formed.
  Failure mode: If the subject cannot be resolved, returns empty
                anchors. This is not an error — the subject may
                reference an entity that does not exist in the DIR.
```

### Required Contracts

```
PC-3: Index Query Access
  Direction:    Required
  Counterparty: Index Runtime (DDS-004, via DDS-004:PC-1)
  Guarantee:    The Retrieval Runtime can query any of the five index
                families (Entity, Graph, Predicate, Content, Scope)
                with epoch-consistent results for structural indexes.
                When an index family is unavailable, the Index Runtime
                provides DIR scan fallback with correct results.
  Preconditions: The Index Runtime is in Building or Operational state
                 (DDS-004:PC-1 preconditions).
  Failure mode: Index queries do not fail (DDS-004:PC-1 failure mode).
                If a family is unavailable, DIR scan fallback provides
                correct but slower results. The Retrieval Runtime
                records which families used fallback in evidence set
                metadata.

PC-4: DIR Read Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-3)
  Guarantee:    The Retrieval Runtime can read DIR content at the
                committed epoch. Consumer reads observe the committed
                epoch (DDS-002:PC-3(a)). No partially-committed write
                transaction is visible.
  Preconditions: The DIR Runtime is operational (DDS-002 state:
                 Operational).
  Failure mode: If the DIR Runtime is not operational, retrieval
                requests are deferred until it becomes operational.

PC-5: Unit Resolution
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-5)
  Guarantee:    The Retrieval Runtime can resolve unit identifiers
                returned by index queries to complete unit records
                (all 10 fields plus lifecycle status). Used to
                populate annotated units in the evidence set.
  Preconditions: The unit identifier was issued by the DIR Runtime.
  Failure mode: If a unit identifier does not resolve (garbage
                collected between index query and resolution), the
                unit is excluded from the evidence set. This is not
                an error — it is a normal consequence of concurrent
                garbage collection.

PC-6: Index Freshness Report
  Direction:    Required
  Counterparty: Index Runtime (DDS-004, via DDS-004:PC-3)
  Guarantee:    The Retrieval Runtime can query per-family freshness
                (last-update epoch, availability state) to populate
                evidence set metadata and to evaluate the freshness
                requirement of the retrieval request.
  Preconditions: None (DDS-004:PC-3 has no preconditions).
  Failure mode: None (DDS-004:PC-3 always returns).
```

---

## Lifecycle

### Creation

The Retrieval Runtime is created during application startup, after the DIR Runtime (DDS-002) is operational and the Index Runtime (DDS-004) has begun construction.

**Preconditions for creation:** The DIR Runtime is in Operational state. The Index Runtime is in Building or Operational state.

**No persistent state.** The Retrieval Runtime has no persistent state. It holds no data between requests. Its creation is lightweight — it acquires references to the required contracts (PC-3 through PC-6) and enters Available state.

### Operation

The Retrieval Runtime becomes available immediately after creation. It can process retrieval requests as soon as the DIR Runtime is operational and the Index Runtime is in at least Building state. During Index Runtime construction, retrieval requests execute with DIR scan fallback for index families not yet available — results are correct but slower.

**Operational invariant:** Every evidence set returned by the Retrieval Runtime is consistent with the DIR at the committed epoch observed during retrieval execution.

### Quiescence

When the application is shutting down, the Retrieval Runtime enters quiescence:

1. No new retrieval requests are accepted.
2. In-progress retrieval requests complete.
3. No cleanup is required — the Retrieval Runtime owns no persistent resources.

### Destruction

The Retrieval Runtime is destroyed during application teardown, after all consumers have stopped issuing retrieval requests.

**Destruction ordering:** The Retrieval Runtime is destroyed before the Index Runtime (DDS-004) and before the DIR Runtime (DDS-002). Both remain available for any in-progress request completion.

---

## State Model

The Retrieval Runtime occupies one of three states:

```
Unavailable → Available → Terminated
```

**Unavailable.** The Retrieval Runtime has been created but its required contracts are not yet available (DIR Runtime not operational or Index Runtime not yet created). No retrieval requests are processed.

**Available.** The required contracts are available. The Retrieval Runtime processes retrieval requests. Individual requests may experience degraded performance when index families are unavailable (DIR scan fallback), but this is per-request degradation, not a subsystem state change.

**Terminated.** The Retrieval Runtime has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Unavailable | Available | DIR Runtime operational, Index Runtime created | Retrieval requests accepted |
| Available | Terminated | Shutdown signal and all in-progress requests complete | Resources released |

**Invalid transitions:** Unavailable → Terminated (must become Available first or be destroyed without having operated). Terminated → any state. Available → Unavailable (once available, remains available until shutdown — loss of DIR Runtime during operation is a failure mode, not a state transition).

**Per-request degradation.** The Retrieval Runtime does not track index availability as subsystem state. Each retrieval request queries index freshness (PC-6) at execution time and records any fallbacks in the evidence set metadata. This design keeps the state model simple and avoids coupling subsystem state to the Index Runtime's per-family availability.

---

## Execution Model

### Request Lifecycle

A retrieval request passes through five phases:

1. **Validation.** The request is validated: subject reference is well-formed, intent is recognized, budget is positive, tier floor ≤ tier ceiling. Invalid requests are rejected immediately.

2. **Epoch capture.** The committed epoch is captured from the DIR Runtime (via PC-4). All subsequent index queries and DIR reads for this request observe this epoch. This ensures RC-3 (consistent snapshot).

3. **Query plan construction.** The retrieval intent, scope, and budget are translated into a query plan that parameterizes each stage. The plan is deterministic given the same request.

4. **Pipeline execution.** The five-stage pipeline executes with the query plan and captured epoch. Each stage produces annotated units and consumes budget.

5. **Evidence set assembly.** The annotated units from all stages, together with resolved anchors and execution metadata, are assembled into the evidence set and returned.

### Five-Stage Pipeline

Every retrieval request executes the same five stages. The intent determines parameterization, not stage structure (DAS-008).

**Stage 1 — Anchor Resolution.** Resolves the retrieval request's subject to one or more concrete entity anchors.

- **EntityReference:** Query the Entity Index (DDS-004:PC-1, Entity family) for the entity. If the entity has units in the DIR, the reference is a valid anchor.
- **SnippetReference:** Identify the entity whose source range contains the snippet's source position. If the snippet spans multiple entities, all containing entities become anchors. If no entity contains the position, the file-level scope entity becomes the anchor — but only if that file scope entity exists in the DIR. If neither a containing entity nor the file scope entity exists, resolution returns empty anchors.
- **ScopeReference:** Query the Scope Index (DDS-004:PC-1, Scope family) for the scope entity.

The Retrieval Runtime never synthesizes anchors. Every anchor is an entity that already exists in the DIR.

Anchor resolution is deterministic (DAS-008 RC-4). It uses only T0 data (entity positions and containment are structural facts). If no anchor can be resolved, the pipeline terminates early and returns an empty evidence set with "subject not found" metadata.

**Stage 2 — Direct Evidence.** Gathers all atomic units directly about the resolved anchors.

For each anchor entity, query the Entity Index for all units with that entity as subject. Filter by the request's tier floor and ceiling. Filter by confidence floor if specified. Each returned unit consumes one unit of budget. If budget is exhausted during this stage, gathering stops and truncation is recorded.

Direct evidence units receive distance-from-anchor = 0 and evidence provenance indicating "direct."

**Stage 3 — Relational Evidence.** Traverses typed relationship edges from the anchors per the query plan's traversal plan.

The traversal plan specifies:
- Which relationship predicates to follow (e.g., `calls`, `conformsTo`, `inherits`).
- Traversal direction per predicate (forward, inverse, or both).
- Maximum depth (hop count) per predicate.
- Per-entity budget (maximum units gathered per traversed entity).

For each anchor, traverse the Graph Index (DDS-004:PC-1, Graph family) following the traversal plan. At each traversed entity, gather units from the Entity Index, subject to per-entity budget and tier filters.

Multi-hop traversal is breadth-first from the anchor. Each hop increments distance-from-anchor. The traversal plan's depth limit bounds the maximum distance. At each hop, both the relationship unit itself (the edge) and the evidence about the traversed entity (the node) are included.

Relational evidence units receive distance-from-anchor = hop count and evidence provenance indicating the predicate chain from anchor (e.g., "anchor → calls → target").

Budget is shared across all anchor traversals. When budget is exhausted, traversal stops.

**Stage 4 — Scope Evidence.** Gathers evidence about the anchor's containing scope.

Query the Scope Index (DDS-004:PC-1, Scope family) to identify the anchor's containing scope entities (file, module, system — depending on the request's retrieval scope). For each scope entity, gather scope properties from the Entity Index: scope-level units (e.g., file purpose, module structure) and cross-boundary edges (relationships between the scope and external entities).

Scope breadth is determined by the retrieval scope parameter:
- **Narrow:** No scope evidence gathered (anchor only).
- **Local:** File-level scope properties and cross-boundary edges.
- **Module:** File-level plus module-level scope properties.
- **System:** File, module, and system scope properties.

Scope evidence units receive distance-from-anchor reflecting the scope's structural distance and evidence provenance indicating "scope."

**Stage 5 — Annotation and Ordering.** Augments every unit gathered in stages 2–4 with complete retrieval metadata, then sorts the evidence into canonical order.

For each unit in the evidence set:
- **Evidence provenance:** The stage that produced it (direct, relational, scope), the structural path from the anchor, and the predicate chain for relational evidence.
- **Distance from anchor:** Integer hop count (0 for direct, 1+ for relational, scope-dependent for scope evidence).
- **Tier and confidence:** Carried through from the atomic unit's fields in the DIR. Not modified by retrieval.
- **Budget state:** Whether the unit was gathered before or after budget pressure (within the first 50% of budget, within the last 50%, or gathered after truncation warning).

After annotation, the evidence is sorted into canonical order (see Evidence Ordering below).

Stage 5 is a pure computation over the gathered evidence — it issues no index queries and consumes no budget.

### Query Planning

The query plan translates a retrieval request into stage parameters. Query plan construction is deterministic: the same retrieval request always produces the same query plan.

**Intent-to-plan mapping.** Each retrieval intent specifies:
- Which predicates are relevant for relational evidence (stage 3).
- Traversal direction preferences per predicate.
- Depth limits per predicate.
- Budget allocation weights across stages (e.g., Explain allocates more to direct evidence; Impact allocates more to relational evidence).
- Tier preference (which tiers to prioritize when budget is limited).

**Scope-to-plan mapping.** The retrieval scope determines:
- Whether scope evidence (stage 4) is gathered.
- Which scope levels are included (file, module, system).

**Budget allocation.** The total evidence budget is distributed across stages 2, 3, and 4 using a reservation model. Stage 1 (anchor resolution) and stage 5 (annotation) do not consume evidence budget.

- **Minimum reservation.** Each stage receives a minimum guaranteed reservation derived from the intent's allocation weights applied to the total budget. The sum of all minimum reservations must not exceed the total budget. The minimum reservation guarantees that no stage is starved — even if earlier stages consume their full allocation, later stages retain their reserved capacity.
- **Shared remaining budget.** Budget not reserved by any stage forms a shared remaining pool. As each stage executes, any unused portion of its minimum reservation returns to the shared remaining pool.
- **Stage consumption.** A stage may consume up to its minimum reservation plus any budget available in the shared remaining pool at the time of its execution. Within a stage, budget is consumed per unit gathered.
- **Execution order determines access.** Stages execute in order (2, then 3, then 4). Earlier stages that consume less than their reservation release budget for later stages. Earlier stages that exhaust their reservation may draw from the shared pool, reducing what is available to later stages — but they cannot draw below later stages' minimum reservations.
- **Determinism.** Budget allocation is deterministic: the same retrieval request always produces the same minimum reservations. Because stages execute in fixed order and budget consumption within each stage follows the canonical evidence ordering, the set of evidence gathered is identical regardless of implementation concurrency.

**Tier filtering.** The query plan applies the request's tier floor and ceiling as filters on all index queries. Units outside the tier range are excluded before budget accounting. Confidence floor, if specified, is applied as an additional filter.

### Concurrency and Isolation

**Request isolation.** Each retrieval request executes independently. No state is shared between concurrent requests. Each request captures its own epoch and maintains its own budget counter.

**Stage ordering.** Stage 1 (anchor resolution) must complete before stages 2–4. Stages 2, 3, and 4 are independent — they query different index families for different evidence relative to the resolved anchors. They may execute concurrently or sequentially; the evidence set is identical either way. Stage 5 (annotation) requires stages 2–4 to complete.

**Read-only guarantee.** The Retrieval Runtime never writes to the DIR (DDS-002) or modifies indexes (DDS-004). All interactions with required contracts are read operations. No retrieval operation has side effects on canonical data (DAS-008 I8).

### Evidence Ordering

The evidence set's annotated units are sorted into a canonical deterministic order before the evidence set is returned. This ordering is independent of execution timing, stage concurrency, and implementation choices. The same retrieval request against the same DIR state always produces identically ordered evidence.

**Canonical sort key** (applied in priority order):

1. **Stage** — direct (stage 2) before relational (stage 3) before scope (stage 4). This groups evidence by structural proximity: the anchor's own properties appear first, then related entities, then scope context.
2. **Distance from anchor** — ascending within each stage. Closer evidence appears before farther evidence. Direct evidence is always distance 0. Relational evidence at distance 1 appears before distance 2.
3. **Unit identifier** — ascending within the same stage and distance. Unit identifiers are monotonically increasing (DDS-002 Identity Model, IM-1), providing a stable, deterministic tie-breaker that does not depend on execution order.

**Deduplication.** A unit may be reachable through multiple traversal paths (e.g., via two different relationship predicates). Each unit appears at most once in the evidence set, at the shortest distance and earliest stage in which it was encountered. The evidence provenance records the path through which the unit was first gathered.

---

## Consistency Guarantees

### Retrieval Consistency

**EC-1: Single-epoch evidence.** All evidence in a single evidence set observes the same committed epoch. The epoch is captured once at the start of retrieval (execution model phase 2) and used for all subsequent index queries and DIR reads. No evidence set contains units from different epochs.

**EC-2: Cross-family consistency.** When a retrieval request queries multiple index families (Entity + Graph + Scope), all queries observe the same committed epoch. This is guaranteed by DDS-004:SC-2 (cross-family consistency) and by the Retrieval Runtime's single-epoch capture.

**EC-3: Concurrent retrieval isolation.** Two concurrent retrieval requests may observe different committed epochs if an epoch advancement occurs between their epoch captures. Each individual evidence set is internally consistent. Cross-request consistency is not guaranteed and not required.

### Content Index Freshness

**CF-1: Content Index staleness disclosure.** When the retrieval pipeline uses the Content Index (for content search queries), the evidence set metadata includes the Content Index's last-update epoch (from PC-6). If the Content Index lags the committed epoch, the metadata indicates that content search results may not reflect the most recent changes.

**CF-2: Freshness requirement enforcement.** The retrieval request's freshness requirement (Current or Tolerant) determines how the Retrieval Runtime handles Content Index staleness:
- **Current:** If the Content Index lags the committed epoch and the query plan includes content search, the Retrieval Runtime uses DIR scan fallback for content queries. Structural index queries are unaffected (structural indexes are always epoch-current per DDS-004:SC-1).
- **Tolerant:** The Content Index is queried regardless of staleness. Staleness is disclosed in metadata.

### Fallback Consistency

**FC-1: DIR scan fallback preserves epoch consistency.** When an index family is unavailable and queries fall back to DIR scan (via DDS-002:PC-3), the fallback observes the same committed epoch as indexed queries. Fallback changes performance, not consistency. This inherits from DDS-004:FC-1.

---

## Memory and Ownership

### Owned Resources

**None persistent.** The Retrieval Runtime owns no persistent data structures. It holds references to the required contracts (PC-3 through PC-6) and processes requests statelessly.

### Per-Request Resources

**Query plan.** Allocated per request, deallocated when the request completes. Size is proportional to the number of predicates in the intent's traversal plan — bounded and small (tens of predicates at most).

**Evidence accumulator.** Allocated per request to collect annotated units during pipeline execution. Size is bounded by the evidence budget. Deallocated after the evidence set is assembled and returned.

**Budget counter.** A single integer per request tracking consumed budget. Negligible.

### Borrowed Resources

**Index query results (read).** The Retrieval Runtime borrows unit references from index query results (DDS-004:PC-1) for the duration of unit resolution (DDS-002:PC-5). The borrowed references are valid for the captured epoch.

**DIR content (read).** The Retrieval Runtime borrows unit records from the DIR (DDS-002:PC-5) for the duration of evidence set assembly. Borrowed content is immutable (DDS-002 immutability model).

### Shared Resources

None. The Retrieval Runtime does not share mutable state with any other subsystem. All interactions are through contracts.

### Memory Bounds

**Per-request memory.** Proportional to the evidence budget. Each annotated unit carries the full atomic unit record (~100–300 bytes per DDS-002 Memory Bounds) plus annotation metadata (~50 bytes). At the maximum expected budget of ~1,000 units: ~350 KB per request.

**Concurrent requests.** At alpha scale, retrieval requests are user-triggered and sequential (one explanation at a time). Concurrent requests are architecturally supported but not expected at alpha. At N concurrent requests: ~350 KB × N.

**Subsystem overhead.** The Retrieval Runtime holds no baseline memory beyond contract references. Subsystem overhead is negligible (<1 KB).

### Eviction

Per-request resources are released when the request completes. No eviction policy is needed — all resources are request-scoped.

---

## Runtime Invariants

```
RI-1: Evidence Soundness
  Statement:   Every annotated unit in the evidence set exists in the DIR
               at the observed epoch with the reported status, tier, and
               confidence.
  Rationale:   If an evidence set contains a unit that does not exist or
               has different properties, consumers make decisions based on
               false information (DAS-008 I1).
  Verification: For each unit in the evidence set, resolve its identifier
               via DDS-002:PC-5 and confirm field equality.

RI-2: Horizon Completeness
  Statement:   Every active unit within the query plan's traversal horizon
               that satisfies the tier and confidence filters is included
               in the evidence set, subject to budget constraints. No unit
               within the horizon is omitted unless budget is exhausted.
  Rationale:   Incomplete evidence within the horizon produces retrieval
               gaps that Context Assembly cannot compensate for — it
               cannot select evidence that was never retrieved (DAS-008
               I2).
  Verification: Execute a retrieval with unlimited budget. Independently
               scan the DIR for all units within the traversal horizon.
               Confirm the evidence set contains all matching units.

RI-3: Consistent Snapshot
  Statement:   All evidence in a single evidence set observes the same
               committed epoch. No evidence set contains units from
               different DIR states.
  Rationale:   Mixed-epoch evidence produces inconsistent views —
               an entity's relationships at epoch N combined with its
               properties at epoch N+1 (DAS-008 I3).
  Verification: Record the epoch at evidence set assembly. Confirm all
               unit versions are consistent with that epoch.

RI-4: Deterministic Anchor Resolution
  Statement:   Given the same subject reference and the same DIR state,
               anchor resolution produces the same set of anchors. The
               resolution does not depend on request ordering, timing,
               or concurrent state.
  Rationale:   Non-deterministic anchor resolution makes retrieval
               results unpredictable for the same input (DAS-008 I4).
  Verification: Issue the same anchor resolution request twice against
               the same DIR state. Confirm identical results.

RI-5: Evidence Provenance Completeness
  Statement:   Every annotated unit in the evidence set carries complete
               evidence provenance: the stage that produced it, the
               structural path from anchor, and the distance from anchor.
               No unit lacks provenance.
  Rationale:   Provenance is required for Context Assembly to make
               informed stratum assignment decisions. Evidence without
               provenance cannot be prioritized (DAS-008 I5).
  Verification: Inspect every annotated unit in the evidence set. Confirm
               provenance fields are non-empty.

RI-6: Budget Respect
  Statement:   The total number of annotated units in the evidence set
               does not exceed the evidence budget specified in the
               retrieval request. Budget exhaustion truncates evidence
               gathering — it does not cause failure.
  Rationale:   Budget violation produces unbounded evidence sets that
               overwhelm downstream consumers and exceed memory bounds
               (DAS-008 I6).
  Verification: For each evidence set, confirm unit count ≤ budget.
               Confirm that budget exhaustion produces a valid (truncated)
               evidence set with appropriate metadata.

RI-7: Tier Monotonicity in Degradation
  Statement:   When the retrieval request specifies a tier range and
               some tiers within the range are unavailable, the evidence
               set contains evidence from the available tiers within the
               range. The absence of higher tiers does not prevent
               retrieval of lower tiers. T0 evidence is always available
               (it is deterministic and always present when entities
               exist).
  Rationale:   Tier unavailability should degrade richness, not prevent
               retrieval entirely. A system with only T0 evidence
               should still return structural facts (DAS-008 I7,
               DAS-003 I7).
  Verification: Execute retrieval with T2 absent. Confirm T0 and T1
               evidence is returned. Execute with T1 and T2 absent.
               Confirm T0 evidence is returned.

RI-8: No Retrieval Side Effects
  Statement:   No retrieval operation creates, modifies, or deletes
               atomic units in the DIR. No retrieval operation modifies
               index structures. Retrieval is purely read-only.
  Rationale:   If retrieval had side effects, concurrent requests could
               interfere with each other and with the synchronous
               pipeline (DAS-008 I8).
  Verification: Audit all retrieval operations. Confirm no operation
               invokes DIR write contracts (DDS-002:PC-1, PC-2, PC-6)
               or Index write contracts (DDS-004:PC-4).
```

---

## Failure Handling

```
FM-1: Subject Not Found
  Trigger:     The retrieval request's subject reference cannot be
               resolved to any entity anchor. The entity does not exist
               in the DIR, or the snippet position does not fall within
               any entity's source range, or the scope entity is absent.
  Detection:   Anchor resolution (stage 1) returns empty anchors.
  Response:    The Retrieval Runtime returns a valid evidence set with
               empty anchors and empty evidence. Evidence set metadata
               indicates "subject not found" and the unresolved subject
               reference. The retrieval does not fail — an empty
               evidence set is a valid result.
  Caller observes: An evidence set with zero evidence units and
               metadata explaining the absence.
  Recovery:    None required. The caller decides whether to retry with
               a different subject or report the absence to the user.

FM-2: Budget Exhausted
  Trigger:     The total evidence budget is fully consumed before all
               stages complete evidence gathering.
  Detection:   Budget counter reaches the budget limit during stage 2,
               3, or 4 execution.
  Response:    The current stage stops gathering evidence. Subsequent
               stages may still execute using their minimum reservation
               if any reserved budget remains unconsumed. If no budget
               remains (all reservations and the shared pool are
               exhausted), subsequent evidence-gathering stages are
               skipped. Stage 5 (annotation and ordering) still
               executes over the gathered evidence. The evidence set
               is valid but truncated. Metadata indicates which stages
               completed fully and which were truncated.
  Caller observes: A valid evidence set with evidence count at most
               equal to the budget. Metadata indicates truncation and
               the stages affected.
  Recovery:    None required. Budget exhaustion is expected behavior
               for large retrieval horizons. The caller may re-request
               with a larger budget if the truncated result is
               insufficient.

FM-3: Index Family Unavailable
  Trigger:     One or more index families are unavailable (Building,
               Rebuilding, or Absent per DDS-004 per-family availability)
               when a retrieval request queries that family.
  Detection:   DDS-004:PC-1 indicates fallback is in effect for the
               queried family.
  Response:    The Retrieval Runtime proceeds with DIR scan fallback
               (provided by DDS-004:PC-1). Results are correct but
               slower. The evidence set metadata records which families
               used fallback.
  Caller observes: A valid evidence set with correct content. Metadata
               indicates fallback was used. Retrieval latency may be
               higher.
  Recovery:    None required by the Retrieval Runtime. The Index
               Runtime (DDS-004) manages index rebuild independently.
               Future requests against a rebuilt index will use the
               index directly.

FM-4: Tier Unavailable
  Trigger:     The retrieval request specifies a tier range (e.g., T0
               through T2) but some tiers within the range have no
               units for the resolved anchors.
  Detection:   Index or DIR queries return no units at the requested
               tier for the queried entities.
  Response:    The Retrieval Runtime returns evidence from the available
               tiers within the range. Evidence set metadata indicates
               which tiers had no evidence. The retrieval does not fail
               — partial tier availability produces a valid evidence
               set with reduced richness (DAS-008 RF-4).
  Caller observes: A valid evidence set containing evidence from
               available tiers only. Metadata indicates tier gaps.
  Recovery:    None required. Tier absence may resolve when semantic
               enrichment produces T2 units, but this is outside
               retrieval's control.

FM-5: Unit Resolution Failure
  Trigger:     A unit identifier returned by an index query cannot be
               resolved via DDS-002:PC-5. The unit has been garbage
               collected between the index query and the resolution
               attempt.
  Detection:   DDS-002:PC-5 returns absent for the unit identifier.
  Response:    The unresolvable unit is excluded from the evidence set.
               The budget allocation for that unit is not consumed
               (the unit was never successfully gathered). If multiple
               units fail resolution, each is independently excluded.
               Evidence set metadata records the count of excluded
               units.
  Caller observes: A valid evidence set that may have fewer units
               than the traversal horizon would suggest. Metadata
               indicates the number of excluded units.
  Recovery:    None required. This is a normal consequence of
               concurrent garbage collection and does not indicate
               a system defect.

FM-6: DIR Runtime Unavailable
  Trigger:     The DIR Runtime (DDS-002) is not in Operational state
               when a retrieval request requires DIR access.
  Detection:   DIR read (PC-4) or unit resolution (PC-5) returns
               an unavailability indication.
  Response:    The retrieval request is deferred. It is not rejected —
               the Retrieval Runtime holds the request until the DIR
               Runtime becomes operational. If the DIR Runtime does
               not become operational within a bounded timeout (aligned
               with application startup budget), the request is
               rejected with a diagnostic.
  Caller observes: Increased latency (if deferred) or a rejection
               with "DIR unavailable" diagnostic (if timeout exceeded).
  Recovery:    When the DIR Runtime becomes operational, deferred
               requests resume. If the application is shutting down,
               deferred requests are cancelled.
```

---

## Performance Requirements

Performance requirements are classified as follows:

- **Architectural requirement** — a bound mandated by DAS invariants or freshness contracts. Violation breaks an architectural guarantee.
- **Engineering target** — an initial numeric bound based on expected workload and reasoning, not yet validated by measurement. Must be validated through benchmarking before promotion to firm requirements.

```
PR-1: End-to-End Retrieval Latency
  Operation:   Complete evidence retrieval (all five stages) for a
               typical retrieval request
  Category:    Engineering target
  Bound:       Upper bound 50ms at alpha scale (~300,000 units) for
               a Local-scope retrieval with default budget
  Assumptions: All index families available (no DIR scan fallback).
               Index query latency per DDS-004:PR-3 (≤1ms per query).
               Budget ≤ 500 units. Traversal depth ≤ 3 hops.
  Rationale:   Retrieval is on the critical path between user input
               and AI explanation. Total latency (retrieval + context
               assembly + AI invocation) must remain interactive.
               With AI invocation dominating at ~2-5 seconds, retrieval
               must be a small fraction. Validate by benchmarking
               representative retrieval requests at alpha scale.

PR-2: Anchor Resolution Latency
  Operation:   Stage 1 (anchor resolution) for a single subject
  Category:    Engineering target
  Bound:       Upper bound 5ms
  Assumptions: Entity Index available. O(1) entity lookup. Snippet
               position resolution requires scanning entity line
               ranges within a single file (~100 entities at most).
  Rationale:   Anchor resolution is prerequisite for all subsequent
               stages. It must complete quickly to avoid delaying
               the pipeline. Validate by benchmarking all three
               subject types (entity, snippet, scope).

PR-3: Direct Evidence Latency
  Operation:   Stage 2 (direct evidence) for a single anchor
  Category:    Engineering target
  Bound:       Upper bound 10ms
  Assumptions: Entity Index available. O(1) entity lookup returns
               all units for the entity. Typical entity has ≤ 200
               units. Tier filtering is O(N) over returned units.
  Rationale:   Direct evidence is the most critical stage — it
               provides the anchor's own properties. Must complete
               quickly to leave budget and time for relational and
               scope evidence.

PR-4: Relational Evidence Latency
  Operation:   Stage 3 (relational evidence) for a Local-scope
               retrieval
  Category:    Engineering target
  Bound:       Upper bound 25ms
  Assumptions: Graph Index available. Traversal depth ≤ 2 hops.
               Average entity degree ≤ 20 relationships. Per-entity
               budget ≤ 50 units. Total traversed entities ≤ 40.
  Rationale:   Relational evidence is the most variable stage —
               traversal depth and entity degree create combinatorial
               expansion. The bound assumes typical codebases where
               entities have moderate connectivity. Validate by
               benchmarking with entities at the upper bound of
               expected degree.

PR-5: Evidence Set Assembly
  Operation:   Stage 5 (annotation) plus evidence set construction
  Category:    Engineering target
  Bound:       Upper bound 2ms for a 500-unit evidence set
  Assumptions: Pure computation over in-memory data. No I/O.
               Annotation is O(N) over evidence units.
  Rationale:   Annotation is computation, not query. It should be
               negligible relative to index query latency. Validate
               by benchmarking at the upper bound of expected
               evidence set size.

PR-6: Retrieval Memory
  Operation:   Peak memory consumption during a single retrieval
               request
  Category:    Engineering target
  Bound:       Upper bound 500 KB per request at alpha scale
  Assumptions: Evidence budget ≤ 1,000 units. ~350 bytes per
               annotated unit. Query plan and intermediate state
               ≤ 10 KB.
  Rationale:   Retrieval is request-scoped. Memory must be bounded
               to prevent a single request from consuming excessive
               resources. At alpha scale with sequential requests,
               500 KB is negligible relative to available memory.
```

---

## Observability

The Retrieval Runtime emits the following observable information:

**Per-Request Metrics.** For each completed retrieval request:
- Total retrieval latency (request received to evidence set returned).
- Per-stage latency (anchor resolution, direct evidence, relational evidence, scope evidence, annotation).
- Evidence budget: allocated, consumed, remaining.
- Evidence count by stage (direct, relational, scope).
- Whether truncation occurred and at which stage.
- Index families queried and whether fallback was used for each.
- Tier distribution of evidence (count of T0, T1, T2 units).
- Committed epoch observed.
- Retrieval intent and scope.

**Anchor Resolution Metrics.** For each anchor resolution:
- Subject type (EntityReference, SnippetReference, ScopeReference).
- Number of anchors resolved.
- Whether resolution succeeded or returned empty.
- Resolution latency.

**Fallback Metrics.** Aggregate counts:
- Total retrievals since startup.
- Retrievals that used DIR scan fallback (by family).
- Retrievals where subject was not found.
- Retrievals where budget was exhausted.
- Retrievals where unit resolution failed (FM-5 count).

**Overhead.** Observability data collection does not block retrieval execution. Metrics are collected as side effects of normal operations (timestamps at stage boundaries, counters incremented during evidence gathering), not as separate processing steps.

---

## Testing Requirements

**Anchor resolution tests (R2):**
- An EntityReference for an existing entity resolves to that entity.
- An EntityReference for a non-existent entity returns empty anchors.
- A SnippetReference within a function's source range resolves to that function's entity.
- A SnippetReference spanning multiple entities resolves to all containing entities.
- A SnippetReference outside all entity ranges resolves to the file-level scope entity if it exists in the DIR.
- A SnippetReference outside all entity ranges with no file scope entity in the DIR returns empty anchors.
- Anchor resolution never synthesizes entities — only resolves to existing DIR entities.
- A ScopeReference for an existing scope entity resolves to that entity.
- Anchor resolution is deterministic: same input, same DIR state → same anchors.

**Direct evidence tests (R1, stage 2):**
- For an anchor with 10 units in the DIR, direct evidence returns all 10.
- Tier floor filters out units below the floor.
- Tier ceiling filters out units above the ceiling.
- Confidence floor filters out units below the confidence threshold.
- Direct evidence units have distance-from-anchor = 0.
- Direct evidence units have provenance indicating "direct."

**Relational evidence tests (R1, stage 3):**
- A 1-hop traversal of `calls` from anchor A returns all entities A calls, with their units.
- A 2-hop traversal returns entities at distance 1 and distance 2.
- Traversal depth limit is respected: a 1-hop traversal does not return 2-hop entities.
- Inverse traversal (e.g., "who calls anchor") returns callers.
- Per-entity budget limits the units gathered per traversed entity.
- Relationship units (edges) are included in the evidence set.
- Relational evidence units have correct distance-from-anchor.
- Evidence provenance records the predicate chain.

**Scope evidence tests (R1, stage 4):**
- Narrow scope: no scope evidence gathered.
- Local scope: file-level scope properties gathered.
- Module scope: file and module scope properties gathered.
- Scope evidence includes cross-boundary edges.

**Budget enforcement tests (R4):**
- A retrieval with budget = 10 returns at most 10 annotated units.
- Each stage receives its minimum reservation regardless of prior stage consumption.
- A stage that consumes less than its reservation releases unused budget to the shared pool.
- A stage may consume beyond its reservation using the shared remaining pool.
- No stage can consume another stage's minimum reservation.
- Total evidence across all stages does not exceed the total budget.
- Budget exhaustion produces a valid evidence set with truncation metadata.
- A retrieval with unlimited budget gathers all evidence within the horizon.

**Annotation and ordering tests (R5):**
- Every annotated unit has non-empty evidence provenance.
- Every annotated unit has a valid distance-from-anchor (≥ 0).
- Tier and confidence values match the underlying DIR unit's fields.
- Evidence is ordered: direct before relational before scope.
- Within each stage, evidence is ordered by ascending distance from anchor.
- Within the same stage and distance, evidence is ordered by ascending unit identifier.
- A unit reachable through multiple paths appears once at the shortest distance.
- Two identical retrieval requests against the same DIR state produce identically ordered evidence sets.

**Consistency tests:**
- All evidence in a single evidence set observes the same committed epoch.
- A retrieval spanning Entity Index and Graph Index returns epoch-consistent results.
- A retrieval during epoch advancement observes either the prior or new epoch, not a mix.

**Tier degradation tests (R6, R7):**
- With T2 absent, retrieval returns T0 and T1 evidence with metadata noting T2 absence.
- With T1 and T2 absent, retrieval returns T0 evidence.
- Tier absence does not cause retrieval failure.

**Graceful degradation tests (R7):**
- With one index family unavailable, retrieval completes using DIR scan fallback.
- With all index families unavailable, retrieval completes using DIR scan for all queries.
- Evidence set metadata records which families used fallback.
- Fallback produces the same evidence content as indexed retrieval (correctness check).

**Failure mode tests (FM-1 through FM-6):**
- Subject not found returns an empty evidence set with appropriate metadata.
- Budget exhaustion produces a truncated but valid evidence set.
- Index unavailability triggers fallback; results are correct.
- Tier unavailability returns available tiers with metadata.
- Unit resolution failure excludes the unit; other evidence is unaffected.
- DIR Runtime unavailability defers the request; timeout produces rejection.

**Integration tests:**
- A full retrieval pipeline for an Explain intent against a populated DIR: anchor resolves, direct evidence gathered, relational evidence traverses 1 hop, scope evidence gathered at file level, all evidence annotated. Verify evidence set completeness and consistency.
- A retrieval during Index Runtime construction: some families use fallback, evidence is correct, metadata records fallback usage.
- A retrieval immediately after epoch advancement: evidence reflects the new epoch's state.
- Two concurrent retrieval requests: each produces an internally consistent evidence set, potentially at different epochs.

---

## Future Evolution

**Module Intelligence (DAS Roadmap Phase 2).** As Module Intelligence introduces module-level entities and cross-module relationships, retrieval scope at the Module level will gather richer evidence: module-level scope properties, cross-module relationship edges, and module-level entities. The Retrieval Runtime's architecture is scope-agnostic — it queries the Scope Index and Entity Index at whatever scope the request specifies. No architectural changes are needed. The traversal plan for module-aware intents will include module-relevant predicates.

**Project Intelligence (DAS Roadmap Phase 3).** System-scope retrieval will traverse system-level entities and system-wide relationships. The primary concern is budget management: at system scope, the traversal horizon is much larger. The reservation-based budget allocation inherently bounds the evidence set size regardless of scope, and the shared remaining pool allows flexible distribution across stages. Performance optimization (early termination, priority-ordered traversal) may be needed for system-scope requests to stay within latency bounds.

**Content Search Retrieval.** The current five-stage pipeline does not include a content search stage (term-based search via the Content Index). When content search becomes a retrieval capability, it could be added as an additional evidence source within the pipeline — either as a new stage or as an alternative anchor resolution path (resolve by content match instead of entity reference). The evidence set contract (annotated units with provenance) accommodates content-search evidence without structural changes.

**Retrieval Intent Registry.** The current design assumes intents are known at compile time. If the intent set becomes extensible (user-defined intents, plugin intents), the query plan construction would need an intent registry mapping intent identifiers to traversal plans. The query planning architecture supports this evolution — the plan is derived from intent parameters, not hardcoded per intent.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial draft
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions: canonical
      deterministic evidence ordering (stage → distance → unit ID);
      reservation-based budget allocation replacing fixed-per-stage;
      anchor resolution clarified — file scope fallback requires existing
      entity, retrieval never synthesizes anchors
```
