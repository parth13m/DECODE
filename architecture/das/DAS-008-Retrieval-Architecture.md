# DAS-008: Retrieval Architecture

```
Chapter:       DAS-008
Title:         Retrieval Architecture
Status:        Frozen
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005, DAS-006, DAS-007
Depended By:   DAS-009, DAS-010
Supersedes:    DAS-008 (Context Assembly — stub, never approved)
Superseded By: —
Layer:         L3
```

## Abstract

This chapter defines the retrieval architecture — how Decode discovers, gathers, and returns the minimum evidence required to answer a question about software. Retrieval operates over the DIR through the five index families (DAS-007) and produces an evidence set consumed by context assembly and backends. Retrieval is not a search for documents; it is a search for grounded, tiered, typed evidence. This chapter defines what a retrieval request is, how evidence is discovered and expanded, how retrieval handles tiers and confidence, and what invariants govern retrieval correctness. It selects a multi-stage evidence-first retrieval architecture over single-stage, cascading, and query-planning alternatives.

## Motivation

DAS-007 defines the index architecture — five index families (Entity, Graph, Predicate, Content, Scope) that organize DIR content for efficient access. But indexes are access structures, not retrieval strategies. An index answers "give me the units matching this key." Retrieval answers "give me the evidence I need to understand this piece of software."

The gap between indexes and understanding is the retrieval architecture. Without this chapter, four problems arise:

1. **Retrieval is conflated with index access.** A consumer asking "explain this function" does not want "all units about entity E." It wants the function's signature, its callers, its callees, the types it depends on, the module it belongs to, its behavioral characterization, and possibly the design decisions that govern it. This is not a single index lookup — it is a structured evidence-gathering process that touches multiple indexes, traverses relationships, crosses scope boundaries, and filters by tier and confidence. Without an architecture for this process, each consumer reimplements its own ad-hoc evidence gathering, producing inconsistent and incomplete results.

2. **The boundary between retrieval and context assembly is undefined.** DAS-002 states "Retrieval selects units. Context assembly determines which selected units are relevant for a specific consumer and purpose." But what does "selects" mean? If retrieval returns all units that could possibly be relevant (high recall, low precision), context assembly becomes the bottleneck — it must sift through a large, noisy set. If retrieval returns only units that are certainly relevant (high precision, low recall), it may miss evidence that context assembly would have included. The retrieval architecture must define the precision-recall contract: what retrieval guarantees to include, what it is allowed to omit, and what it leaves to context assembly.

3. **Multi-hop evidence gathering is ad hoc.** Many questions require evidence that is not directly attached to the subject entity. "Why does this function exist?" may require understanding the function's callers to understand its role. "Is this refactoring safe?" requires understanding not just the function but everything that depends on it. These are multi-hop evidence requirements: the initial entity leads to related entities, which lead to further related entities. Without a structured traversal model, multi-hop evidence gathering is either unbounded (follow every edge — produces too much) or absent (return only the subject's units — produces too little).

4. **Tier and confidence handling is undefined.** The DIR contains units at three tiers (T0, T1, T2) with four confidence levels. When retrieval gathers evidence, should it include T2 units that may be stale? Should it include T1 classifications with low confidence? Should it prefer T0 facts over T2 interpretations? Without tier-aware retrieval, consumers receive a flat set of units with no guidance on which to trust, which to display, and which to treat as provisional.

**Source dependencies:**
- [DAS-001 D4](DAS-001-Architectural-Principles.md) — understanding is always relative to a question
- [DAS-001 D7](DAS-001-Architectural-Principles.md) — comprehension has diminishing returns per unit of information
- [DAS-001 P5](DAS-001-Architectural-Principles.md) — intelligence is grounded
- [DAS-001 P7](DAS-001-Architectural-Principles.md) — relevance over completeness
- [DAS-001 P10](DAS-001-Architectural-Principles.md) — scope scales along independent axes
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — atomic unit contract, retrieval semantics, query defaults
- [DAS-003](DAS-003-Tier-Model.md) — tier definitions, confidence model, freshness contracts
- [DAS-004](DAS-004-Entity-Model.md) — entity types, ontology layers, containment hierarchy
- [DAS-005](DAS-005-Relationship-Model.md) — relationship predicates, traversal patterns, cross-layer connections
- [DAS-006](DAS-006-Pass-Architecture.md) — passes produce the DIR content that retrieval discovers
- [DAS-007](DAS-007-Index-Architecture.md) — five index families that retrieval operates through

## Terminology

**Retrieval** — The process of discovering and gathering the atomic units from the DIR that constitute evidence for answering a question about software. Retrieval operates through indexes (DAS-007) and produces an evidence set. It is not a search for documents or files — it is a search for grounded, tiered, typed evidence organized as atomic units. *Is:* given a function and the intent "explain," discover its signature, callers, callees, type dependencies, scope, and semantic characterizations. *Is not:* returning all units about the function (that is an index lookup); selecting the most relevant units for an AI prompt (that is context assembly). `INTRODUCED`

**Retrieval Request** — A structured specification of what evidence is needed. A retrieval request identifies: the subject (which entity or entities), the intent (what kind of understanding is sought), the scope (how far to look), the tier floor (minimum tier to include), and the budget (maximum evidence volume). The retrieval request is the input to the retrieval system. *Is:* "gather evidence about function `authenticate`, intent=explain, scope=callers+callees+containing-file, tier-floor=T0, budget=200 units." *Is not:* a consumer's natural-language question; an index query; a context frame. `INTRODUCED`

**Evidence Set** — The output of retrieval: a collection of atomic units gathered from the DIR that constitutes the evidentiary basis for answering a question. An evidence set is structured — units are organized by their relationship to the subject and annotated with their retrieval provenance (why each unit was included). The evidence set is consumed by context assembly, which selects from it. *Is:* a structured collection of units about function `authenticate`, its callers, its callees, and its containing file's role classification. *Is not:* a flat list of units; a ranked result set; a context frame ready for a consumer. `INTRODUCED`

**Retrieval Stage** — One discrete step in the retrieval process. Each stage operates on the output of the prior stage and produces input for the next. Stages are: anchor resolution, evidence discovery, evidence expansion, and evidence annotation. `INTRODUCED`

**Anchor** — The entity or entities that are the primary subject of a retrieval request. The anchor is where retrieval begins. All evidence is gathered relative to the anchor — by direct attachment, by relationship traversal, or by scope membership. *Is:* function `authenticate` when the question is "what does this function do?" *Is not:* a search result; a keyword; an intermediate entity discovered during traversal. `INTRODUCED`

**Evidence Provenance** — A record of why a specific atomic unit was included in the evidence set. Evidence provenance traces each unit's inclusion back to a retrieval rule: "included because it is a direct property of the anchor," "included because it is a callee of the anchor," "included because it shares the anchor's containing scope." Evidence provenance is distinct from unit provenance (DAS-002), which records how the unit was produced. `INTRODUCED`

**Retrieval Horizon** — The boundary beyond which retrieval does not gather evidence. The horizon is defined by the retrieval request's scope and budget. Evidence beyond the horizon is not absent from the DIR — it is absent from this specific retrieval because the request did not ask for it. *Is:* "retrieval gathered callers of the anchor but did not gather callers of callers." *Is not:* a limitation of the DIR; a statement that the evidence does not exist. `INTRODUCED`

**Tier Floor** — The minimum tier of evidence that a retrieval request will include. A tier floor of T0 includes only deterministic facts. A tier floor of T0 with no ceiling includes all tiers. The tier floor enables consumers to control the reliability-richness trade-off. `INTRODUCED`

## Domain Analysis

**DA-1: A question about software implies an evidence requirement, not a data requirement.** When a developer asks "what does function `authenticate` do?", they are not requesting a database query. They are requesting the evidence needed to construct an answer: the function's signature, its callees (what it does), its callers (why it's called), its type context (what contracts it satisfies), and its behavioral characterization (how it behaves). The evidence requirement is determined by the intent of the question, not by the identity of the subject. Two different questions about the same function require different evidence.

**DA-2: Evidence has structure — it is not a flat set of facts.** The units in an evidence set stand in specific relationships to each other and to the anchor. Some are direct properties of the anchor. Some are properties of related entities. Some are relationship edges. Some provide scope context. A flat, unstructured bag of units loses this relational structure, making it impossible for downstream consumers to distinguish "this is what the function does" from "this is what the function's caller does." Evidence structure is as important as evidence content.

**DA-3: Most evidence is reachable by relationship traversal from the anchor.** The evidence for explaining a function is: the function itself (Entity Index), what it calls (Graph Index, `calls` forward), what calls it (Graph Index, `calls` inverse), what types it belongs to (Graph Index, `contains` inverse), what it conforms to (Graph Index, `conformsTo` forward), what scope it lives in (Scope Index). In every case, evidence is discovered by starting at the anchor and following typed relationship edges. The Graph Index (DAS-007 Family 2) is the primary evidence discovery mechanism.

**DA-4: Evidence requirements vary categorically by intent.** An "explain" intent needs the anchor's properties, immediate callees, containing scope, and semantic characterization. An "impact analysis" intent needs the anchor's inverse callees (what calls it), transitive dependents, test coverage, and deployment relationships. An "improvement" intent needs the anchor's full source context, behavioral characterization, and design assessment. These are not minor variations — they are structurally different evidence requirements. A retrieval architecture that serves all intents with the same evidence-gathering strategy will either over-retrieve (waste) or under-retrieve (miss) for most intents.

**DA-5: Evidence gathering must be bounded.** Following every relationship edge from the anchor produces a transitive closure of the entity graph — potentially the entire codebase. A function calls another function, which calls another, which calls another. At each hop, the evidence set grows multiplicatively. Without a bound, evidence gathering is O(|V| + |E|) where V and E are the graph's vertices and edges. The bound must be architectural (defined by the retrieval model) not incidental (defined by whatever the implementation happens to do). The bound comes from two sources: scope (how many hops from the anchor) and budget (how many units to include).

**DA-6: Higher-tier evidence is valuable but non-essential.** T0 evidence (deterministic facts) is always available and always correct. T1 evidence (derived classifications) is usually available and usually correct. T2 evidence (semantic characterizations) may be unavailable, stale, or unreliable. A retrieval architecture must produce useful evidence sets even when T2 is entirely absent (DAS-001 P12, DAS-003 Graceful Degradation). This means retrieval must distinguish between evidence that is required (T0 — without it, the answer is impossible) and evidence that is enriching (T2 — with it, the answer is better).

**DA-7: Not all entities reached by traversal are equally valuable as evidence.** When retrieving evidence for function F, the function F calls (G, H, I) are all relevant. But if F calls 50 functions, including all 50 callees' full evidence produces an enormous set that buries the important callees under the trivial ones. Retrieval must distinguish between entities that should contribute their full evidence (high-value neighbors) and entities that should contribute only their identity and key properties (low-value neighbors). The determination of value is not retrieval's responsibility — it is context assembly's. But retrieval's structure must support this discrimination: it must annotate evidence with enough information for context assembly to make the cut.

**DA-8: Some evidence is only discoverable through multi-hop traversal.** "Is function F safe to delete?" requires knowing not just what directly calls F, but whether anything transitively depends on F through chains of calls, conformances, and containment. "What is the architectural role of module M?" requires knowing not just M's entities but M's relationship to other modules in the system. Single-hop retrieval (gather only the anchor's direct neighbors) misses structurally critical evidence. The retrieval architecture must support controlled multi-hop traversal with bounded depth.

## Candidates

The architectural question is: **how should retrieval operate over the DIR and indexes to produce evidence sets?**

### Candidate A: Single-Stage Retrieval

Retrieval resolves the anchor, then executes a single index query (or a fixed set of queries) to gather all evidence. The query set is the same regardless of intent. The evidence set is everything matching the queries.

**Strengths:** Maximum simplicity. Predictable execution. Easy to reason about what retrieval will return.

**Weaknesses:** A single query set cannot serve different intents without being either too broad (includes everything for every intent — wasteful) or too narrow (returns the same subset for every intent — misses intent-specific evidence). No multi-hop support — single-stage retrieval returns only what the fixed queries match, with no ability to follow evidence trails discovered during gathering.

**Disqualifying condition:** Violates DA-4 (evidence requirements vary by intent). A fixed query set produces the wrong evidence for most intents.

### Candidate B: Cascading Retrieval

Retrieval is a fixed pipeline of stages where each stage's output feeds the next. Stage 1 resolves the anchor. Stage 2 gathers direct evidence. Stage 3 gathers relationship evidence. Stage 4 gathers scope evidence. The pipeline is always the same; the only variation is the anchor.

**Strengths:** Structured and predictable. Each stage has a clear responsibility. Stages build on each other.

**Weaknesses:** The pipeline is fixed — all intents traverse the same stages in the same order. An "impact analysis" intent needs heavy relationship traversal and light property gathering; an "explain" intent needs the reverse. A fixed pipeline cannot prioritize stages differently per intent. Adding a new stage (e.g., for evolutionary evidence from git history) requires modifying the pipeline, not configuring it.

**Disqualifying condition:** Fixed stage ordering prevents intent-specific evidence strategies. New evidence sources require pipeline changes rather than configuration.

### Candidate C: Query-Planning Retrieval

Retrieval receives the request and generates a query plan — a directed graph of index operations optimized for the specific intent. The plan is compiled, optimized, and executed. Different intents produce different plans.

**Strengths:** Maximum flexibility. Each intent gets a purpose-built plan. Plans can be optimized for the specific evidence requirements.

**Weaknesses:** Plan generation is itself a complex operation. The plan compiler must understand intent semantics, index capabilities, and evidence structure — effectively a query optimizer. At Decode's scale and complexity, this is over-engineering: the set of intents is bounded (explain, improve, impact, investigate, refactor), and each has a knowable evidence strategy. Building a general-purpose query planner to serve a small, stable set of intents introduces complexity without proportional benefit.

**Disqualifying condition:** None — but the complexity cost exceeds the benefit for a bounded intent set. If the intent set were unbounded or rapidly evolving, query planning would be justified. For a stable, enumerable set, it is premature.

### Candidate D: Iterative Retrieval

Retrieval gathers an initial evidence set, examines it, identifies gaps, and gathers additional evidence in subsequent rounds. Each round is informed by what was found (or not found) in prior rounds. Retrieval continues until the evidence set satisfies a completeness criterion or the budget is exhausted.

**Strengths:** Adaptive — can follow evidence trails that only become apparent after initial gathering. Handles the case where the initial evidence reveals unexpected dependencies or relationships.

**Weaknesses:** Unpredictable execution time — the number of rounds is not known in advance. Completeness criteria are difficult to define: "when do I have enough evidence?" requires understanding what the consumer will do with the evidence, which is a context assembly concern, not a retrieval concern. Risk of oscillation: round N discovers entities that trigger round N+1, which discovers entities that trigger round N+2, indefinitely.

**Disqualifying condition:** Completeness criteria require understanding consumer intent at a level that retrieval should not possess — that is context assembly's responsibility. Unbounded iteration violates DA-5 (evidence gathering must be bounded).

### Candidate E: Multi-Stage Evidence-First Retrieval

Retrieval operates in a fixed number of stages, but each stage's behavior is parameterized by the retrieval request (intent, scope, tier floor, budget). The stages are:

1. **Anchor Resolution:** Resolve the subject to one or more anchor entities.
2. **Direct Evidence:** Gather the anchor's own atomic units (properties and relationships).
3. **Relational Evidence:** Traverse typed relationship edges from the anchor, guided by the intent, to discover related entities and their key evidence.
4. **Scope Evidence:** Gather contextual evidence from the anchor's containing scope (file, module).
5. **Annotation:** Annotate each unit in the evidence set with its evidence provenance (why included) and its distance from the anchor.

The stages are always the same. What varies is the *parameterization* within each stage: which relationship predicates to traverse, how many hops, what tier floor, what budget allocation per stage. The parameterization is determined by the retrieval request's intent.

**Strengths:** Fixed, predictable stage structure — easy to reason about and debug. Intent-specific behavior via parameterization, not via structural changes. Each stage has a single responsibility. Bounded execution: the number of stages is constant; the work within each stage is bounded by scope and budget. Multi-hop traversal is supported in Stage 3 with explicit depth limits. Evidence provenance (Stage 5) supports downstream context assembly decisions.

**Weaknesses:** Stage parameterization must be correct for each intent — a poorly parameterized intent produces poor evidence. Not as adaptive as iterative retrieval — if Stage 3 discovers something surprising, there is no mechanism to re-enter Stage 2. The fixed stage count may be insufficient for future evidence types not anticipated by the current architecture.

**Disqualifying condition:** None identified.

## Evaluation

| Criterion | Single-Stage (A) | Cascading (B) | Query-Planning (C) | Iterative (D) | Multi-Stage Evidence-First (E) |
|-----------|------------------|---------------|--------------------|--------------|-----------------------------|
| Intent-specific evidence (DA-4) | No — fixed queries | No — fixed pipeline | **Yes** — per-intent plans | Yes — adaptive | **Yes** — per-intent parameterization |
| Bounded execution (DA-5) | Yes | Yes | Yes | No — unbounded rounds | **Yes** — fixed stages, bounded work |
| Multi-hop support (DA-8) | No | Limited | Yes | Yes | **Yes** — Stage 3 with depth limits |
| Evidence provenance (DA-2) | No | Partial | Yes | Partial | **Yes** — Stage 5 |
| Graceful degradation (DAS-001 P12) | Partial | Partial | Yes | Yes | **Yes** — tier floor controls |
| Complexity proportional to need | **Low** | Low | High | Moderate | **Low-to-moderate** |
| Debuggability | High | High | Low (plan optimization) | Low (round count varies) | **High** (fixed stages) |
| Extensibility | Low | Low — pipeline changes | High | Moderate | **Moderate** — new parameters, not new stages |

Candidate A is disqualified by lack of intent sensitivity. Candidate B is disqualified by fixed ordering. Candidate D is disqualified by unbounded iteration. Candidate C is viable but introduces query planning complexity disproportionate to the bounded intent set.

Candidate E satisfies every criterion: intent-specific via parameterization, bounded via fixed stages and budgets, multi-hop via traversal depth, provenance-annotated, and debuggable via fixed structure.

## Decision

**Retrieval uses a multi-stage evidence-first architecture with five fixed stages parameterized by the retrieval request.** The stages — anchor resolution, direct evidence, relational evidence, scope evidence, and annotation — are always executed in order. What varies per retrieval request is the parameterization within each stage: which predicates to traverse, how many hops, what tier floor, how much budget to allocate to each stage. This architecture treats retrieval as evidence gathering, not data fetching.

---

## Retrieval Request

A retrieval request is the input to the retrieval system. It specifies what evidence is needed without prescribing how to gather it.

### Request Fields

```
RetrievalRequest {
    subject      : EntityReference | SnippetReference | ScopeReference
    intent       : RetrievalIntent
    scope        : RetrievalScope
    tierFloor    : Tier
    tierCeiling  : Tier
    budget       : EvidenceBudget
    freshness    : FreshnessRequirement
}
```

### Subject (`subject`)

The subject identifies what the retrieval is about. Three subject types:

- **EntityReference:** A specific entity in the DIR (function, type, file, module). Retrieval gathers evidence about this entity.
- **SnippetReference:** A code snippet (text with file position). Retrieval resolves the snippet to one or more entities, then gathers evidence about them.
- **ScopeReference:** A containment scope (file, module, system). Retrieval gathers evidence about the scope and its constituents.

**RR-1: Subject resolution is the first retrieval operation.** A snippet reference must be resolved to entity references before evidence can be gathered. Resolution uses the Entity Index and Scope Index (DAS-007) to map source positions to DIR entities.

### Intent (`intent`)

The intent classifies what kind of understanding the evidence will support. Intent determines the parameterization of retrieval stages — which relationships to traverse, how deep to traverse, and what evidence to prioritize.

The retrieval architecture does not define a closed set of intents. Instead, it defines the parameterization contract: an intent is a named configuration that specifies, for each retrieval stage, the stage's parameters. The following intents are illustrative:

**Explain:** Gather evidence for explaining what a piece of software is and does. Emphasizes: direct properties, immediate callees, containing scope, type conformances, semantic characterizations. Traversal depth: 1 hop for callees, 0 hops for callers. Tier preference: all tiers.

**Impact:** Gather evidence for analyzing the impact of changing the subject. Emphasizes: inverse relationships (what depends on the subject), transitive dependents, test coverage, cross-module boundary crossings. Traversal depth: multi-hop along `calls` inverse, `dependsOn` inverse, `conformsTo` inverse. Tier preference: T0 strongly preferred (impact analysis requires deterministic edges).

**Improve:** Gather evidence for suggesting improvements to the subject. Emphasizes: full source context, behavioral characterization, design assessment, similar entities for comparison. Traversal depth: 1 hop for callees and callers, scope context. Tier preference: all tiers, T2 especially valuable.

**Investigate:** Gather evidence for answering an open-ended question about the subject. Emphasizes: broad relationship traversal, cross-scope connections, semantic content search. Traversal depth: 2+ hops along multiple predicates. Tier preference: all tiers.

**Refactor:** Gather evidence for assessing whether a structural change is safe. Emphasizes: all consumers (inverse callers, conformers, overriders), test coverage, containment structure. Traversal depth: multi-hop along dependency edges. Tier preference: T0 required, T1 valuable.

**RR-2: Intent determines stage parameterization, not stage structure.** All intents execute the same five stages. The intent controls *what* each stage does (which predicates, which depth, which budget allocation), not *whether* each stage runs.

### Scope (`scope`)

The scope specifies how far from the subject retrieval should gather evidence:

- **Narrow:** Subject entity only — no relationship traversal, no scope context. Used for simple property lookups.
- **Local:** Subject entity, immediate relationship neighbors (1 hop), and containing file. The default for most intents.
- **Module:** Subject entity, relationship neighbors, containing file, and containing module's relevant entities. Used when the question concerns cross-file context.
- **System:** Subject entity, multi-hop relationship neighbors, and cross-module connections. Used for architectural questions.

**RR-3: Scope bounds the traversal horizon.** Retrieval does not gather evidence beyond the specified scope. Evidence beyond the horizon exists in the DIR but is excluded from this retrieval. The scope is a request parameter, not a system limitation.

### Tier Floor and Ceiling (`tierFloor`, `tierCeiling`)

The tier floor specifies the minimum tier of evidence to include. The tier ceiling specifies the maximum.

- `tierFloor=T0, tierCeiling=T2`: Include all tiers (default).
- `tierFloor=T0, tierCeiling=T0`: Include only deterministic facts. Used for automated analysis where reliability is critical.
- `tierFloor=T0, tierCeiling=T1`: Include deterministic and derived, exclude semantic. Used during AI outages.

**RR-4: Tier filtering is applied during evidence gathering, not after.** Retrieval does not gather all tiers and then filter. It gathers only the tiers within the floor-ceiling range. This reduces evidence volume and avoids unnecessary work for constrained requests.

### Budget (`budget`)

The budget constrains the total volume of evidence that retrieval will gather:

- **Unit count:** Maximum number of atomic units in the evidence set.
- **Per-stage allocation:** How the budget is distributed across stages (e.g., 30% direct evidence, 50% relational evidence, 20% scope evidence).

**RR-5: Budget exhaustion truncates, not fails.** When the budget is exhausted, retrieval stops gathering and returns what it has collected so far. It does not fail or return empty. The evidence set carries a flag indicating whether the budget was exhausted, enabling context assembly to request a larger budget if needed.

### Freshness Requirement (`freshness`)

Specifies the acceptable staleness of evidence:

- **Current:** Only active units. Invalidated units are excluded. Used for queries where accuracy is critical.
- **Tolerant:** Active and invalidated units are both included, with status annotated. Used when stale evidence is preferable to absent evidence (DAS-001 P12).

---

## Retrieval Stages

Retrieval operates in five stages, always in order. Each stage reads from the DIR through indexes (DAS-007) and contributes to the evidence set.

### Stage 1: Anchor Resolution

**Purpose.** Resolve the retrieval request's subject to one or more concrete entity references in the DIR.

**Input.** The retrieval request's subject field.

**Process.**
- If the subject is an EntityReference, verify the entity exists in the Entity Index (DAS-007 Family 1). If it exists, it becomes the anchor. If it does not exist, retrieval fails with "subject not found."
- If the subject is a SnippetReference, resolve the snippet's source position to the containing entity using the Entity Index and Scope Index. A code snippet at line 42 of file F resolves to the function, type, or property that contains line 42. If the snippet spans multiple entities, all become anchors.
- If the subject is a ScopeReference, verify the scope entity exists. The scope entity (file, module, system) becomes the anchor.

**Output.** A set of one or more anchor entities with their entity types.

**RS-1: Anchor resolution is deterministic.** The same subject always resolves to the same anchors (given the same DIR state). Resolution uses T0 structural information only — it does not depend on semantic content or AI.

### Stage 2: Direct Evidence

**Purpose.** Gather all atomic units that are directly about the anchor entities — properties, classifications, and semantic characterizations.

**Input.** Anchor entities from Stage 1. Intent and tier parameters from the retrieval request.

**Process.** For each anchor entity:
1. Query the Entity Index for all units whose subject is the anchor entity (single-entity subjects).
2. Filter by tier floor and ceiling.
3. Filter by freshness requirement (active only, or active + invalidated).
4. Add matching units to the evidence set with evidence provenance: "direct property of anchor."

**Output.** The evidence set now contains the anchors' own properties — signature, return type, parameters, line range, role classification, semantic characterizations, etc.

**RS-2: Direct evidence is always gathered.** Regardless of intent, direct evidence about the anchor is always included. The anchor's own properties are the minimum evidence for any question about the anchor.

### Stage 3: Relational Evidence

**Purpose.** Traverse typed relationship edges from the anchor to discover related entities and gather their key evidence. This is the stage where retrieval follows the DIR's graph structure to build a connected evidence set.

**Input.** Anchor entities from Stage 1. Intent (determines which predicates to traverse and at what depth). Tier parameters. Budget allocation for this stage.

**Process.** The intent specifies a traversal plan — a set of (predicate, direction, depth, per-entity budget) tuples:

1. For each (predicate, direction, depth) in the traversal plan:
   a. Query the Graph Index (DAS-007 Family 2) for entities connected to the anchor by this predicate in this direction.
   b. For each discovered entity (up to the per-entity budget):
      - Add the relationship unit to the evidence set with evidence provenance: "relationship `{predicate}` from anchor, hop 1."
      - Gather the discovered entity's key properties via the Entity Index. "Key properties" is intent-defined: for an explain intent, the key property of a callee is its signature; for an impact intent, the key property of a dependent is its test coverage.
      - Add these property units with evidence provenance: "property of entity discovered via `{predicate}`, hop 1."
   c. If depth > 1, repeat from (a) using the discovered entities as the new traversal origins, incrementing the hop count. Continue until the specified depth is reached or the stage budget is exhausted.

2. Apply budget limits. When the stage budget is exhausted, stop traversal. Partially traversed predicates are noted in the evidence set metadata.

**Output.** The evidence set now contains relationship edges and key properties of related entities, organized by predicate type and hop distance.

**RS-3: Traversal predicates are intent-specific.** An explain intent traverses `calls` (forward), `conformsTo` (forward), `contains` (inverse — to find the containing scope). An impact intent traverses `calls` (inverse), `dependsOn` (inverse), `tests` (inverse), `conformsTo` (inverse). A refactor intent traverses `calls` (both directions), `overrides` (both directions), `conformsTo` (inverse), `tests` (inverse). The predicates are determined by the intent's parameterization, not by a fixed traversal strategy.

**RS-4: Multi-hop traversal has an explicit depth limit.** No traversal exceeds the depth specified in the retrieval request's scope and intent. Depth limits are small (typically 1–3 hops) because evidence value decays rapidly with distance from the anchor (DAS-001 D7). A 4-hop callee chain is rarely relevant to understanding the anchor.

**RS-5: Relational evidence includes the relationship unit itself.** When retrieval discovers that A calls B, it includes the `calls` relationship unit (with its tier, confidence, and grounding) in the evidence set. This enables context assembly and consumers to inspect the connection's reliability, not just its existence.

### Stage 4: Scope Evidence

**Purpose.** Gather contextual evidence from the anchor's containing scope — the file, module, or system that the anchor belongs to. Scope evidence provides the structural context that makes the anchor's evidence interpretable.

**Input.** Anchor entities from Stage 1. Scope parameter from the retrieval request. Budget allocation for this stage.

**Process.**
1. Query the Scope Index (DAS-007 Family 5) to find the anchor's containing file, module, and system.
2. Based on the retrieval request's scope parameter:
   - **Narrow:** No scope evidence gathered (skip this stage).
   - **Local:** Gather the containing file's key properties (role, purpose, outline of sibling entities).
   - **Module:** Gather the containing file's properties plus the containing module's properties (composition, cohesion, architectural role) and a summary of the module's other files.
   - **System:** Gather module-level properties plus the module's relationships to other modules.
3. Gather scope boundary evidence: relationships where one endpoint is inside the anchor's scope and the other is outside. These cross-boundary edges reveal the anchor's external dependencies and consumers.

**Output.** The evidence set now contains structural context: what the anchor belongs to, what surrounds it, and what crosses its scope boundary.

**RS-6: Scope evidence provides context, not exhaustive enumeration.** Scope evidence gathers the scope's *properties* (role, purpose, composition) and *boundary crossings* (cross-scope relationships), not every unit about every entity in the scope. Exhaustive scope enumeration would make scope evidence dominate the evidence set for large scopes (a module with 50 files would produce thousands of units). Key properties and boundary crossings provide the context needed without the volume.

### Stage 5: Annotation

**Purpose.** Annotate every unit in the evidence set with metadata that enables downstream consumers to understand why each unit was included and how it relates to the anchor.

**Input.** The evidence set from Stages 2–4.

**Process.** For each unit in the evidence set:
1. **Evidence provenance:** Tag the unit with why it was included. Examples:
   - "Direct property of anchor `authenticate`."
   - "Relationship: anchor `authenticate` calls `validateCredentials`."
   - "Property of callee `validateCredentials` discovered at hop 1 via `calls`."
   - "Scope context: containing file `AuthService.swift` has role `service`."
   - "Scope boundary: module `Auth` depends on module `Crypto` (cross-boundary `dependsOn`)."

2. **Distance from anchor:** Record the hop count — 0 for direct evidence, 1 for immediate neighbors, 2 for neighbors of neighbors.

3. **Tier and confidence:** Carry forward each unit's tier and confidence from the DIR. These are not modified by retrieval — they are surfaced for context assembly.

4. **Budget state:** Record whether the evidence set was budget-truncated in any stage, and if so, which stage and which predicates were partially traversed.

**Output.** The fully annotated evidence set — ready for consumption by context assembly.

**RS-7: Annotation does not modify evidence content.** Annotation adds metadata to the evidence set; it does not change, remove, or reorder units. The evidence set's content is fixed after Stage 4; Stage 5 only enriches the metadata.

---

## Evidence Set Structure

The evidence set is the output of retrieval. It has the following structure:

```
EvidenceSet {
    anchors          : [EntityReference]
    request          : RetrievalRequest
    evidence         : [AnnotatedUnit]
    metadata         : EvidenceSetMetadata
}

AnnotatedUnit {
    unit             : AtomicUnit
    evidenceProvenance : EvidenceProvenance
    distanceFromAnchor : Integer
}

EvidenceSetMetadata {
    totalUnits       : Integer
    unitsByTier      : {T0: Integer, T1: Integer, T2: Integer}
    unitsByStage     : {direct: Integer, relational: Integer, scope: Integer}
    budgetExhausted  : Boolean
    truncatedStages  : [StageName]
    staleness        : {activeUnits: Integer, invalidatedUnits: Integer}
    retrievalDuration : Duration
}
```

**ES-1: The evidence set is self-describing.** The metadata enables context assembly to understand the evidence set's composition without scanning every unit. It can determine: how much evidence is deterministic vs. semantic, how much is direct vs. relational, whether the budget was exhausted, and how stale the evidence is.

**ES-2: The evidence set is ordered by distance from anchor.** Units at distance 0 (direct evidence) appear before units at distance 1 (immediate neighbors), which appear before units at distance 2. Within a distance, ordering is by tier (T0 before T1 before T2). This ordering supports context assembly's default behavior: include the closest, most reliable evidence first.

---

## Tier and Confidence Handling

### Tier-Aware Retrieval

**TC-1: Retrieval respects the tier floor and ceiling.** A retrieval request with `tierFloor=T0, tierCeiling=T0` returns only deterministic evidence. This enables consumers like automated impact analysis to operate on provably correct evidence only.

**TC-2: Retrieval gathers all qualifying tiers within the range.** Within the tier range, retrieval does not prefer one tier over another. If T0 and T2 units both exist for the same entity and predicate, both are included (if within the tier range). The choice between them is context assembly's responsibility.

**TC-3: When T2 evidence is absent, retrieval does not fail.** If the retrieval request includes T2 in its range but no T2 units exist for the anchor (semantic enrichment has not run), retrieval returns the T0 and T1 evidence that does exist. The evidence set's metadata records the absence of T2 content. This is the retrieval-level expression of DAS-001 P12 (graceful degradation).

### Confidence Handling

**TC-4: Confidence is surfaced, not filtered, by default.** Retrieval includes all confidence levels within the tier range. Each unit carries its confidence in the evidence set. Context assembly decides whether to include low-confidence evidence.

**TC-5: A retrieval request may specify a confidence floor.** When specified, units below the confidence floor are excluded. This is primarily used by automated consumers (impact analysis, refactoring safety checks) that require high-confidence evidence.

---

## Retrieval and Grounding

**RG-1: Every unit in the evidence set carries its grounding chain.** Retrieval does not strip grounding from atomic units. The evidence set preserves the full grounding chain (DAS-002 I-GND-1 through I-GND-4) for every included unit. This enables consumers to verify any claim in the evidence by tracing it to source material.

**RG-2: Retrieval may follow grounding chains to discover additional evidence.** When a T2 unit's grounding references T0 units that are not yet in the evidence set, retrieval may include those T0 units as supporting evidence. This ensures that semantic claims are accompanied by the deterministic facts they are grounded in, enabling consumers to evaluate the claim's basis.

**RG-3: Evidence provenance is distinct from unit grounding.** Unit grounding (DAS-002) records how the unit was produced — what source material or input units it derives from. Evidence provenance records why the unit was included in *this* evidence set — what retrieval rule caused its inclusion. Both are present in the annotated unit; they serve different purposes.

---

## Retrieval Correctness

### What Retrieval Must Guarantee

**RC-1: Completeness within the horizon.** For the specified scope and intent, retrieval must include all qualifying evidence within the horizon. If the intent specifies "traverse `calls` forward to depth 1," every T0 `calls` edge from the anchor must be included (within the tier range). Missing a qualifying edge is a retrieval defect.

**RC-2: Soundness.** Every unit in the evidence set exists in the DIR and matches the retrieval request's tier, confidence, and freshness filters. No fabricated units. No units from outside the specified range.

**RC-3: Consistency.** The evidence set observes a consistent DIR snapshot (DAS-002 retrieval defaults, DAS-007 I4). All units in the evidence set reflect the same DIR state. No unit reflects a later DIR change than another unit in the same set.

**RC-4: Deterministic anchor resolution.** Given the same subject and the same DIR state, anchor resolution always produces the same anchors (RS-1). This ensures that the same question asked twice produces evidence sets that differ only if the DIR has changed between requests.

### What Retrieval Does Not Guarantee

**RC-5: Retrieval does not guarantee relevance.** Retrieval gathers all qualifying evidence within the horizon. Not all of it is relevant to the consumer's specific purpose. Relevance selection is context assembly's responsibility.

**RC-6: Retrieval does not guarantee sufficiency.** The evidence set may not contain everything needed to answer the consumer's question. The question may require evidence outside the retrieval horizon, or the DIR may lack the necessary intelligence (semantic enrichment has not run). Retrieval reports what it found; it does not guarantee that what it found is enough.

---

## Retrieval Failure Modes

**RF-1: Subject not found.** The retrieval request's subject does not resolve to any entity in the DIR. Retrieval returns an empty evidence set with an error annotation. Not a system failure — the subject may be misspelled, refer to a recently deleted entity, or be outside the DIR's coverage.

**RF-2: Budget exhausted before completion.** The evidence budget is reached before all qualifying evidence within the horizon is gathered. Retrieval returns what it has gathered with a truncation annotation (ES-1). Context assembly may respond by re-requesting with a larger budget.

**RF-3: Index unavailable.** One or more index families (DAS-007) are unavailable (missing, corrupted, rebuilding). Retrieval falls back to DIR scan for the affected access pattern (DAS-007 I6 — Graceful Absence). Performance degrades but correctness is maintained.

**RF-4: Tier unavailable.** The requested tier range includes tiers that have no content for the subject (e.g., T2 enrichment has not run). Retrieval returns the available tiers and annotates the missing tiers in the evidence set metadata. This is not a failure — it is a documented gap.

**RF-5: Stale evidence.** Some or all evidence is derived from invalidated DIR units. When the freshness requirement is "tolerant," stale evidence is included with status annotation. When "current," stale evidence is excluded, potentially producing a smaller evidence set.

---

## Retrieval Observability

**RO-1: Request metrics.** For each retrieval request: subject type, intent, scope, tier range, budget, and freshness requirement. These enable analysis of retrieval usage patterns.

**RO-2: Execution metrics.** For each retrieval: total duration, per-stage duration, units gathered per stage, units filtered per stage (by tier, confidence, freshness), budget utilization (fraction of budget consumed).

**RO-3: Evidence composition.** For each evidence set: breakdown by tier (T0/T1/T2), by stage (direct/relational/scope), by distance from anchor, by unit status (active/invalidated). These enable monitoring evidence quality.

**RO-4: Truncation tracking.** How often retrieval exhausts its budget, which stages are most frequently truncated, and which predicates are most frequently partially traversed. Persistent truncation indicates budget miscalibration.

**RO-5: Staleness tracking.** How often evidence sets contain invalidated units, and at what tier. Persistent staleness at T0 indicates a freshness defect (DAS-003: T0 must be source-synchronous). Staleness at T2 is expected and healthy.

---

## Architectural Consequences

**C1: Retrieval is evidence gathering, not data fetching.** Retrieval does not return "all data about X." It returns "the evidence needed to understand X for purpose Y within scope Z." This reframing transforms retrieval from a database operation into an intelligence operation. The evidence set is structured, annotated, and purpose-aware.

**C2: All retrieval operations are expressible as compositions of the five index families.** The Entity Index serves Stage 2 (direct evidence). The Graph Index serves Stage 3 (relational evidence). The Scope Index serves Stage 4 (scope evidence). The Predicate Index and Content Index serve specialized retrieval requests (e.g., "find entities matching a predicate" or "find entities mentioning a term"). No retrieval operation requires an index outside the five families defined in DAS-007.

**C3: Intent parameterization, not intent-specific code.** Different intents produce different evidence sets not because they execute different code paths, but because they parameterize the same five stages differently. Adding a new intent (e.g., "security review") requires defining its traversal plan and budget allocation — not building new retrieval infrastructure.

**C4: Evidence provenance enables context assembly.** Because every unit in the evidence set carries evidence provenance (why it was included) and distance from anchor, context assembly can make informed selection decisions without re-deriving the relationships between units. Context assembly receives pre-structured evidence, not a flat bag of units.

**C5: Retrieval degrades gracefully across three dimensions.** Missing tiers: T2 absence produces smaller but still useful evidence sets. Missing indexes: DIR scan fallback maintains correctness. Budget exhaustion: partial evidence sets with truncation metadata. No retrieval failure produces zero output unless the subject itself does not exist.

**C6: The evidence set is the contract between retrieval and context assembly.** Retrieval produces evidence sets; context assembly consumes them. The evidence set's structure (anchors, annotated units, metadata) is the interface. This boundary ensures that retrieval and context assembly can evolve independently (DAS-001 P11).

**C7: Multi-hop traversal is explicit and bounded.** Retrieval's graph traversal has an explicit depth limit per predicate, per intent. There is no implicit traversal that follows edges indefinitely. This boundedness ensures that evidence set size is predictable and that retrieval completes in bounded time.

---

## Invariants

**I1: Evidence Soundness.**
- **Statement:** Every atomic unit in the evidence set exists in the DIR at the time of retrieval and matches the retrieval request's tier, confidence, and freshness filters.
- **Rationale:** An evidence set containing fabricated or out-of-range units produces incorrect understanding. Soundness is the minimum correctness property.
- **Verification:** For each unit in the evidence set, confirm it exists in the DIR and matches all request filters.

**I2: Horizon Completeness.**
- **Statement:** For the specified intent, scope, and tier range, retrieval includes every qualifying unit within the retrieval horizon that fits within the budget. No qualifying unit within the horizon is omitted unless the budget is exhausted.
- **Rationale:** If retrieval arbitrarily omits qualifying evidence, consumers receive an incomplete picture and make decisions based on partial information — without knowing what was omitted.
- **Verification:** For a known DIR state, compute the expected evidence set for a given request. Compare against the actual evidence set. Any difference (absent the budget exhaustion flag) is a violation.

**I3: Consistent Snapshot.**
- **Statement:** All units in a single evidence set reflect the same DIR state. No unit in the set reflects a later DIR change than another unit in the same set.
- **Rationale:** A mixed-state evidence set produces contradictions — a unit may reference an entity that another unit says was deleted. Snapshot consistency eliminates temporal contradictions.
- **Verification:** Record the DIR version at retrieval start. Confirm that all units in the evidence set were active (or validly invalidated) at that version.

**I4: Deterministic Anchor Resolution.**
- **Statement:** Given the same subject and the same DIR state, anchor resolution produces the same anchors.
- **Rationale:** Non-deterministic resolution would make retrieval results unpredictable — the same question asked twice might produce different anchors and therefore different evidence sets, even with an unchanged DIR.
- **Verification:** Issue the same retrieval request twice against the same DIR state. Confirm identical anchor sets.

**I5: Evidence Provenance Completeness.**
- **Statement:** Every unit in the evidence set carries evidence provenance that explains why it was included. No unit has empty or missing evidence provenance.
- **Rationale:** Without provenance, context assembly cannot distinguish "this unit is a direct property of the anchor" from "this unit is a property of a 3-hop callee." The provenance is the signal that enables intelligent selection downstream.
- **Verification:** Inspect every annotated unit in the evidence set. Confirm evidence provenance is present and references a retrieval rule (direct property, relationship traversal, scope context, grounding support).

**I6: Budget Respect.**
- **Statement:** Retrieval never exceeds the evidence budget specified in the retrieval request. When the budget is exhausted, retrieval stops gathering and annotates the truncation.
- **Rationale:** Unbounded evidence gathering produces arbitrarily large evidence sets that overwhelm context assembly and consumers. The budget is an architectural constraint, not a suggestion.
- **Verification:** For each retrieval, confirm the evidence set's unit count does not exceed the requested budget. Confirm that budget exhaustion is reflected in the metadata.

**I7: Tier Monotonicity in Degradation.**
- **Statement:** When a tier is unavailable, the evidence set contains all available evidence at lower tiers. The absence of T2 evidence does not reduce the T0 or T1 evidence in the set.
- **Rationale:** This is the retrieval-level expression of DAS-003 Graceful Degradation. If T2 absence caused retrieval to also omit T0 evidence (e.g., because the retrieval path depended on a T2 classification), the system would degrade catastrophically rather than gracefully.
- **Verification:** Execute retrieval with T2 content present. Remove all T2 content. Re-execute with the same request. Confirm that all T0 and T1 units from the first set are present in the second set.

**I8: No Retrieval Side Effects.**
- **Statement:** Retrieval does not modify the DIR, does not modify indexes, does not trigger pass execution, and does not produce atomic units. Retrieval is a read-only operation.
- **Rationale:** If retrieval had side effects (e.g., triggering lazy enrichment), retrieval timing would affect DIR state, making the system's behavior order-dependent and difficult to reason about. The separation between "produce intelligence" (passes) and "retrieve intelligence" (retrieval) must be absolute.
- **Verification:** Snapshot the DIR and all indexes before retrieval. Execute retrieval. Confirm the DIR and indexes are unchanged.

---

## Non-Goals

This chapter does not:

- **Define context assembly.** How the evidence set is filtered, prioritized, and shaped for a specific consumer and purpose is a downstream concern. This chapter produces evidence sets; the next chapter selects from them.

- **Define relevance scoring.** How evidence is ranked by relevance to the consumer's specific question is a context assembly concern. Retrieval produces structured, annotated evidence; ranking is applied after retrieval.

- **Define the consumer interface.** How consumers express questions in natural language, how questions are mapped to retrieval requests, and how evidence sets are presented to consumers are delivery concerns.

- **Define how retrieval requests are constructed.** The mapping from consumer intent to retrieval request parameters (which predicates, what depth, what budget) is a configuration concern. This chapter defines the retrieval request structure and the retrieval stages; it does not define the specific parameterizations for each consumer type.

- **Define lazy enrichment triggers.** Whether retrieval should trigger semantic enrichment when T2 evidence is absent is a pass scheduling concern (DAS-006 PS-3: consumer-demand priority). Retrieval reports T2 absence; it does not act on it.

- **Define storage realization.** How evidence sets are cached, serialized, or transported is a DAS-012 concern.

- **Prescribe specific technologies.** No search engine, graph traversal algorithm, or data structure is specified. The retrieval architecture is technology-independent.

---

## Open Questions

**Q1: Should retrieval support composite subjects?** *(Non-blocking)*

A consumer asking "how do these three files work together?" has a composite subject — three entities, not one. Current retrieval supports multiple anchors (snippet resolution may produce multiple entities), but it treats each as an independent anchor with independent evidence. Composite subjects would require gathering evidence about the relationships *between* the anchors, not just evidence *from each anchor individually*. This is architecturally distinct and may warrant a composite retrieval mode.

**Investigation approach:** Enumerate consumer scenarios requiring composite subjects. If they are common (module-level questions, multi-file refactoring), define a composite retrieval mode. If rare, handle them as multiple single-anchor retrievals composed by context assembly.

**Q2: Should evidence provenance include "not found" annotations?** *(Non-blocking)*

When retrieval traverses `calls` from the anchor and finds no callees, should it annotate the evidence set with "no callees found" — or simply omit callee evidence? The "not found" annotation would help context assembly distinguish "no callees exist" (the function is a leaf) from "callees were not gathered" (the budget was exhausted before callee traversal). At current complexity, the distinction is implicit in the budget metadata. As intents become more sophisticated, explicit "not found" annotations may become necessary.

**Investigation approach:** Monitor context assembly errors. If downstream consumers frequently misinterpret absent evidence as budget truncation (or vice versa), add explicit "not found" annotations.

**Q3: Should retrieval cache evidence sets?** *(Non-blocking)*

If two consumers ask the same question about the same entity within a short time window, the second retrieval repeats the same index operations. Caching the evidence set would avoid the redundant work. However, caching introduces staleness: the cached evidence set may not reflect recent DIR changes. Given that T0 evidence is source-synchronous (DAS-003) and the cache would immediately become stale on any source change, caching is safe only for evidence sets composed entirely of unchanged T0 content — or for short time windows where DIR changes are unlikely.

**Investigation approach:** Measure retrieval latency in production. If retrieval is fast enough that caching provides negligible benefit, defer. If retrieval is a latency bottleneck, consider short-lived caches with invalidation on DIR change.

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
              ├── DAS-007 (Index Architecture)
              └── DAS-008 (this chapter — Retrieval Architecture)
                    ├── DAS-009 (Context Assembly)
                    │     └── DAS-011 (Consumer Architecture)
                    └── DAS-010 (Incremental Update Model)
```

This chapter depends on:
- DAS-000: chapter structure, review checklist
- DAS-001: D4 (understanding is relative to a question), D7 (diminishing returns per information), P5 (intelligence is grounded), P7 (relevance over completeness), P10 (scope scales independently), P11 (boundaries define independent variability), P12 (graceful degradation)
- DAS-002: atomic unit contract (units are the evidence), retrieval semantics (query defaults, point-in-time consistency), lifecycle model (Active/Invalidated status drives freshness), grounding (I-GND-1 through I-GND-4 — evidence carries grounding)
- DAS-003: tier model (T0/T1/T2 — tier floor and ceiling in retrieval requests), confidence model (confidence surfaced in evidence), freshness contracts (index freshness bounds evidence freshness), graceful degradation levels
- DAS-004: entity types (entities are subjects and anchors), containment hierarchy (scope evidence), ontology layers (cross-layer traversal in Stage 3)
- DAS-005: relationship predicates (24 predicates traversed in Stage 3), directionality (forward and inverse traversal), transitivity (multi-hop support for transitive predicates), cross-layer relationships
- DAS-006: pass architecture (passes produce the DIR content retrieval discovers), scheduling (consumer-demand priority — DAS-006 PS-3 — may trigger enrichment, but retrieval itself does not)
- DAS-007: five index families (Entity, Graph, Scope, Predicate, Content — the access mechanisms retrieval operates through), index freshness (bounds evidence freshness), consistent snapshots (I4 — retrieval inherits snapshot consistency)

This chapter is depended on by:
- DAS-009 (Context Assembly): context assembly consumes evidence sets; it depends on understanding the evidence set structure, evidence provenance, and the retrieval request contract
- DAS-010 (Incremental Update Model): incremental update must coordinate with retrieval to ensure that retrieval observes consistent snapshots during DIR updates

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub titled "Context Assembly" with section
    headings and open questions.
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the retrieval architecture.
    Renamed from "Context Assembly" to "Retrieval Architecture" — context assembly is pushed
    to the next chapter. Multi-stage evidence-first architecture selected over single-stage,
    cascading, query-planning, and iterative alternatives. Five retrieval stages defined
    (anchor resolution, direct evidence, relational evidence, scope evidence, annotation).
    Retrieval request contract defined. Evidence set structure defined. Tier handling,
    grounding, correctness, failure modes, and observability specified. Eight invariants.
    Three open questions. Supersedes the DAS-008 stub.
```
