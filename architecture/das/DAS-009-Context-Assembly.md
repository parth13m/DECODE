# DAS-009: Context Assembly

```
Chapter:       DAS-009
Title:         Context Assembly
Status:        Frozen
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005, DAS-006, DAS-007, DAS-008
Depended By:   DAS-010, DAS-011
Supersedes:    DAS-009 (Backend Architecture — stub, never approved)
Superseded By: —
Layer:         L3
```

## Abstract

This chapter defines context assembly — how an evidence set (DAS-008) is transformed into a context frame consumable by a downstream backend. Context assembly is a constrained representation problem: given an evidence set that may contain more evidence than any consumer can process, select, organize, and bound the evidence into a coherent, purpose-calibrated, budget-respecting context frame. This chapter defines what a context frame is, how evidence is selected into it, how budget constraints are enforced, and what invariants govern context correctness. It selects a purpose-stratified context assembly architecture over flat, ranked, hierarchical, progressive, layered, and evidence-graph alternatives.

## Motivation

DAS-008 defines the retrieval architecture — how evidence is gathered from the DIR through indexes into an evidence set. But retrieval makes two explicit non-guarantees: it does not guarantee relevance (RC-5) and it does not guarantee sufficiency (RC-6). Retrieval gathers *all qualifying evidence within the horizon*. The evidence set is sound and complete within its bounds, but it is not shaped for any specific consumer.

The gap between evidence and understanding is context assembly. Without this chapter, four problems arise:

1. **Consumers receive evidence, not context.** An evidence set for explaining a function may contain 200 annotated units: the function's 15 direct properties, 30 relationship edges, 50 properties of related entities, 40 scope context units, and 65 semantic characterizations. An AI consumer with a 4,000-token budget cannot process 200 units. A human consumer scanning a summary cannot absorb 200 facts. Without context assembly, every consumer must independently solve the selection problem — which units matter, which are noise, what fits in the budget — and each will solve it differently, producing inconsistent results across capabilities.

2. **The budget constraint is architecturally undefined.** Every consumer has a processing budget: token limits for AI consumers, attention limits for human consumers, computation limits for automated consumers. Retrieval has its own budget (DAS-008 RR-5), but the retrieval budget governs evidence *volume*, not evidence *relevance*. A retrieval budget of 200 units may produce 200 units that, when assembled for a specific purpose, should be reduced to 40. Without an architecture that defines how budget constraints flow from consumers into evidence selection, budget management is ad hoc — some consumers will overflow, others will underutilize.

3. **Purpose-specific evidence selection is undone.** Retrieval parameterizes evidence gathering by intent (DAS-008 RR-2) — an "explain" intent traverses different predicates than an "impact" intent. But the evidence set still contains units from all traversed paths. Context assembly must complete the purpose-specific selection: from the explain-intent evidence set, include the function's behavioral characterization but not the module's cohesion metric; from the impact-intent evidence set, include every dependent's identity but not their behavioral characterizations. Without this second level of purpose-aware selection, the intent-specific parameterization in retrieval is wasted.

4. **Evidence coherence is not guaranteed.** A randomly selected subset of evidence is not a coherent context. Including a relationship edge "A calls B" without B's identity (at minimum, its name and signature) leaves the consumer with an unresolvable reference. Including a T2 behavioral characterization without the T0 structural evidence it interprets leaves the consumer unable to evaluate the characterization. Coherence — the property that the context frame is self-contained enough for the consumer to use — requires deliberate selection, not arbitrary truncation.

**Source dependencies:**
- [DAS-001 D7](DAS-001-Architectural-Principles.md) — comprehension has diminishing returns per unit of information
- [DAS-001 P1](DAS-001-Architectural-Principles.md) — intelligence is the canonical asset; context is derived
- [DAS-001 P6](DAS-001-Architectural-Principles.md) — understanding is derived, not stored
- [DAS-001 P7](DAS-001-Architectural-Principles.md) — relevance over completeness
- [DAS-001 P10](DAS-001-Architectural-Principles.md) — scope scales along independent axes
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — DIR pipeline: context assembly sits between retrieval and backends
- [DAS-003](DAS-003-Tier-Model.md) — tier definitions, confidence model, freshness contracts, graceful degradation levels
- [DAS-008](DAS-008-Retrieval-Architecture.md) — evidence set contract, annotated units, evidence provenance, retrieval request

## Terminology

**Context Assembly** — The process of transforming an evidence set (DAS-008) into a context frame consumable by a downstream backend. Context assembly selects, prioritizes, balances, compresses, and organizes evidence to satisfy a purpose within a budget. It is a constrained representation problem: the input (evidence set) may be large and general; the output (context frame) must be bounded, coherent, and purpose-calibrated. *Is:* given 200 units of evidence about function `authenticate` gathered for an explain intent, select and organize the 40 most relevant units into a coherent frame that fits within a 4,000-token budget. *Is not:* retrieval (that gathers evidence); formatting (that renders context into a specific syntax); prompting (that tells a consumer how to use the context). `INTRODUCED`

**Context Frame** — The output of context assembly: a bounded, structured, purpose-calibrated representation of evidence ready for consumption by a backend. A context frame is the contract between context assembly and backends, just as the evidence set (DAS-008) is the contract between retrieval and context assembly. A context frame is transient and derived — it is never the system of record (DAS-001 P6). *Is:* 40 organized units about function `authenticate`, structured into strata (core properties, behavioral evidence, scope context), annotated with tier, confidence, and grounding, fitting within a 4,000-token budget. *Is not:* the evidence set (which is larger and unselected); a prompt (which is a consumer's internal formatting); an explanation (which is a consumer's output). `INTRODUCED`

**Context Strategy** — A purpose-specific parameterization that governs how context assembly transforms an evidence set into a context frame. A strategy defines: which strata to create, what evidence belongs in each stratum, the priority ordering of strata, the budget allocation across strata, tier preferences, and coherence requirements. Each consumer purpose has a corresponding strategy. *Is:* the explain strategy, which prioritizes the anchor's direct properties, then behavioral evidence, then scope context, then design assessment. *Is not:* a fixed algorithm; an intent (which parameterizes retrieval, not context assembly); a prompt template. `INTRODUCED`

**Context Stratum** — A priority-ordered group of evidence within a context frame. Each stratum contains evidence serving a specific role in the context (e.g., core properties, behavioral evidence, scope context). Strata are ordered by priority: the highest-priority stratum is filled first, and the lowest-priority stratum is dropped first when budget is constrained. *Is:* the "core" stratum containing the anchor's signature, parameters, return type, and line range. *Is not:* a tier (which classifies objectivity); an evidence provenance category (which records why evidence was retrieved); a section heading (which is a formatting concern). `INTRODUCED`

**Context Budget** — The capacity constraint that bounds a context frame. The budget is specified by the consumer (or by the consumer's configuration) and expressed in units that correspond to the consumer's processing capacity (token count for AI consumers, unit count for automated consumers). Context assembly must produce a frame that fits within the budget. The budget is a hard constraint, not a target. *Is:* "this context frame must not exceed 4,000 tokens" or "this context frame must not exceed 60 units." *Is not:* the retrieval budget (which bounds evidence gathering, not evidence selection); a quality target; a suggestion. `INTRODUCED`

**Context Role** — An annotation on each unit in the context frame explaining why the unit was included and what function it serves in the context. Context role is distinct from evidence provenance (DAS-008): evidence provenance records why the unit was gathered during retrieval; context role records why the unit was selected during assembly. *Is:* "included as the anchor's primary signature" or "included to identify the callee referenced by relationship R." *Is not:* evidence provenance; a tier; a relevance score. `INTRODUCED`

**Coherence Constraint** — A rule requiring that certain units co-occur in the context frame. If unit A is included, coherence may require that unit B also be included. Coherence constraints prevent the context frame from containing unresolvable references or unsupported claims. *Is:* "if a relationship edge 'A calls B' is included, entity B's identity (name and type) must also be included." *Is not:* a completeness guarantee (coherence does not require all evidence); a budget override (coherence constraints compete for budget, they do not exceed it). `INTRODUCED`

**Evidence Elision** — The deliberate omission of evidence from the context frame when the evidence set exceeds the budget. Elision is directed: the context strategy determines which evidence is elided first (lowest-priority strata, lowest-confidence units, greatest distance from anchor). Elision is not truncation — it is purpose-aware selection under constraint. *Is:* omitting the module's cohesion metric from an explain context because the budget is better spent on the function's callee signatures. *Is not:* dropping the last N units to fit the budget; removing entire tiers; corruption or loss. `INTRODUCED`

## Domain Analysis

**DA-1: Evidence is not context.** An evidence set (DAS-008) is a collection of all qualifying evidence within the retrieval horizon. A context frame is a representation of the evidence a specific consumer needs for a specific purpose within a specific budget. The gap between them is not quantitative (context is "less evidence") — it is qualitative (context is *selected, organized, and bounded* evidence). A library contains all relevant books. A reading list for a specific essay contains the books the student needs to read, in the order they should be read, within the time available. Context assembly is the selection process, not the library.

**DA-2: Context has a hard budget, and the budget is non-negotiable.** AI consumers have token limits imposed by model architecture. Human consumers have attention limits imposed by cognitive capacity. Automated consumers have memory and computation limits. These budgets cannot be exceeded — an AI consumer that receives 10,000 tokens when it can process 4,000 does not process the extra 6,000 gracefully; it loses them, misprocesses them, or fails entirely. The budget is an architectural constraint that context assembly must satisfy, not a preference it should approximate. Every context frame must fit within its budget.

**DA-3: Relevance is multidimensional and purpose-dependent.** A unit's relevance to a context frame depends on at least four dimensions: its relationship to the anchor (distance, predicate type), its tier (T0 facts vs. T2 interpretations), its confidence level, and the consumer's purpose. The same unit may be essential for one purpose and noise for another. A callee's behavioral characterization is essential for "explain" but irrelevant for "impact analysis." No single relevance score captures these dimensions. A scalar ranking loses the structure that purpose-specific selection requires.

**DA-4: Context must be coherent — internally consistent and self-contained enough for the consumer to use.** A context frame that includes "function A calls function B" but does not include B's identity leaves the consumer with an unresolvable reference. A frame that includes a T2 design assessment but not the T0 structural evidence supporting it leaves the consumer unable to evaluate the assessment. Coherence means: every reference in the context frame is resolvable within the frame, and every claim is supported by evidence present in the frame. Coherence is not completeness — the frame need not contain everything, but what it contains must be internally consistent.

**DA-5: The value of evidence decreases non-linearly with distance from the anchor.** Direct properties of the anchor (distance 0) are almost always relevant regardless of purpose. Properties of immediate neighbors (distance 1) are relevant for most purposes. Properties of neighbors' neighbors (distance 2) are relevant for a few purposes (impact analysis, refactoring). Properties at distance 3+ are rarely relevant for any purpose. This decay is not linear — the first hop contributes substantially more value than the second, which contributes substantially more than the third. Context assembly must exploit this decay by allocating budget preferentially to closer evidence.

**DA-6: Tier balance is purpose-determined, not universally optimal.** An impact analysis requires high T0 density — impact chains are only as reliable as the relationships they traverse. An explanation benefits from high T2 density — the consumer wants interpretive context, not just structural facts. An improvement context needs both: T0 facts (to identify what exists) and T2 assessments (to identify what could be better). There is no universally correct tier balance. The strategy must specify the tier preference, and context assembly must honor it.

**DA-7: Compression requires choosing what to sacrifice.** When the evidence set exceeds the budget, context assembly cannot include everything. It must choose what to sacrifice. The choices are: (a) elide low-priority evidence entirely, (b) represent some evidence in reduced form (identity-only instead of full properties), (c) elide higher-distance evidence before lower-distance, (d) elide lower-confidence evidence before higher-confidence, (e) elide enriching evidence before essential evidence. These choices interact and must be governed by a defined strategy, not by ad hoc decisions.

**DA-8: Deduplication is semantic, not syntactic.** An evidence set may contain overlapping claims: a T0 unit "function A calls function B" and a T2 unit "function A delegates credential validation to function B." These are syntactically distinct units carrying different predicates at different tiers. Semantically, they convey overlapping information. Including both in a budget-constrained context wastes budget without adding information. Context assembly must detect and resolve this overlap — not by discarding one (both carry distinct value: the T0 unit is grounded fact, the T2 adds interpretive framing), but by recognizing that their combined budget cost should be discounted relative to two fully independent units.

**DA-9: Some evidence is essential — its absence makes the context frame useless.** If the context frame for "explain function A" does not include A's signature, no consumer can produce a useful explanation. If the context frame for "is it safe to refactor A?" does not include A's dependents, no consumer can assess safety. Essential evidence is purpose-specific but identifiable: it is the minimum set without which the consumer cannot begin its task. Context assembly must guarantee that essential evidence is always present (within the coherence and budget constraints). All other evidence is enriching — its presence improves output quality, but its absence does not prevent output entirely.

**DA-10: Context assembly is deterministic within a strategy.** Given the same evidence set and the same context strategy, context assembly must produce the same context frame. Non-deterministic assembly would mean that the same question asked twice about the same code produces different context, leading to different outputs — confusing users and making debugging impossible. The strategy is the parameterization; assembly is the deterministic function.

## Candidates

The architectural question is: **how should context assembly organize evidence from the evidence set into a budget-constrained context frame?**

### Candidate A: Flat Context

All selected evidence is placed in a single unstructured sequence. Selection is by inclusion threshold: units above a relevance threshold are included; units below are excluded. No grouping, no hierarchy, no ordering beyond the threshold.

**Strengths:** Maximum simplicity. No structural overhead. Easy to implement.

**Weaknesses:** No purpose-awareness — the threshold is the same for all purposes. No coherence guarantee — units are included independently, so a relationship edge may be included without its target entity. Budget management is all-or-nothing: if the selected set exceeds the budget, units must be arbitrarily dropped. No structure for the consumer to navigate — the consumer receives an undifferentiated list of facts.

**Disqualifying condition:** Violates DA-4 (context must be coherent). Independent inclusion decisions cannot guarantee that references are resolvable within the frame. Violates DA-3 (relevance is purpose-dependent) by applying a single threshold regardless of purpose.

### Candidate B: Ranked Context

Evidence is scored by a single relevance metric, sorted by score, and the top-K units are included (where K is determined by the budget). The relevance score combines distance, tier, confidence, and purpose into a single scalar.

**Strengths:** Simple budget management (take top-K). Deterministic ordering. Easy to understand.

**Weaknesses:** Collapsing multidimensional relevance into a single score loses critical information (DA-3). A unit with high structural relevance and low semantic relevance may score the same as a unit with low structural relevance and high semantic relevance — but they serve different purposes. Coherence is not guaranteed: the top-K set may include a relationship to entity B but not B's identity, because B's identity scored at position K+1. The ranking function must be purpose-specific, but a single ranking function per purpose is too coarse — it cannot express "I need at least one unit from category X" or "never include Y without Z."

**Disqualifying condition:** Single-score ranking cannot express coherence constraints (DA-4) or purpose-specific balancing requirements (DA-6). These require structural organization, not positional ranking.

### Candidate C: Hierarchical Context

Evidence is organized as a tree rooted at the anchor. The anchor's direct properties are children of the root. Related entities are children of the relevant relationship edge. Scope context is a subtree at the top level. Budget is allocated top-down: the root is always included, then first-level children, then second-level children, until the budget is exhausted.

**Strengths:** Natural distance-based structure — closer evidence is higher in the tree and allocated budget first. Consumer can traverse the tree depth-first. Coherence is partially guaranteed by the parent-child structure.

**Weaknesses:** Evidence relationships are a graph, not a tree. When entity B is both a callee of the anchor and a member of the same scope, where does B appear in the tree? Duplication (include B in both places — wastes budget) or arbitrary choice (pick one — loses the other relationship). Cross-cutting concerns (tier balance, scope context, semantic enrichment) do not map to a tree structure. Purpose-specific organization requires different tree shapes per purpose, making the tree unstable across purposes.

**Disqualifying condition:** The DIR's relational structure is a graph (DAS-002 I-SUB-3: relationships are binary edges in a directed graph). A tree cannot faithfully represent graph relationships without duplication or loss. Evidence that is reachable through multiple relationship paths is either duplicated (budget waste) or arbitrarily placed (information loss).

### Candidate D: Progressive Context

Evidence is organized in concentric rings radiating from the anchor. Ring 0 is the anchor's essential properties. Ring 1 is the anchor's immediate relationships and their targets. Ring 2 is scope context. Ring 3 is semantic enrichment. Budget is allocated ring-by-ring: Ring 0 is always fully included, Ring 1 fills next, and outer rings receive whatever budget remains.

**Strengths:** Natural priority ordering. Budget allocation is simple and predictable. Distance-based decay (DA-5) is architecturally embedded.

**Weaknesses:** The ring structure is fixed — all purposes share the same rings. An impact analysis purpose needs dependents (Ring 1 in the fixed model) but also needs transitive dependents (which might be Ring 2 or Ring 3), and scope context (normally Ring 2) is less important. The fixed ring ordering cannot be rearranged per purpose. Adding a new evidence category (e.g., evolutionary evidence from version history) requires adding a new ring, changing the ring count and potentially the budget allocation for all purposes.

**Disqualifying condition:** Fixed ring ordering (DA-3, DA-6). Different purposes require different evidence categories at different priorities. A fixed concentric structure cannot be rearranged per purpose without becoming, in effect, a purpose-specific structure — which is Candidate F.

### Candidate E: Layered Context

Evidence is organized by knowledge dimension: a structural layer (entities, signatures, types), a relational layer (edges, dependencies), a behavioral layer (control flow, side effects), and an interpretive layer (purpose, design, trade-offs). Each layer is independently includable or excludable. Budget is allocated per layer.

**Strengths:** Natural alignment with the DIR's predicate domains (DAS-003). Tier balance is partially addressed by layer structure (structural ≈ T0, behavioral ≈ T0/T1, interpretive ≈ T2). Consumers that need only structural information can receive only the structural layer.

**Weaknesses:** Knowledge dimension is not the same as purpose priority. An explain context needs the function's signature (structural), its callees (relational), and its purpose (interpretive) — cutting across all layers. An impact context needs the function's dependents (relational) and their test coverage (classificatory) but not the function's purpose (interpretive). Layers do not naturally express "include the anchor's signature and its callee signatures, but not the callees' callees' signatures" — that is a distance constraint, not a layer constraint. Coherence constraints cross layers: including a behavioral characterization without the structural evidence supporting it violates DA-4.

**Disqualifying condition:** Layer boundaries are orthogonal to purpose priorities (DA-3). Purpose-specific selection requires selecting across layers based on distance, relevance, and the specific question — not selecting whole layers. Layers solve a different problem (what kind of knowledge) than context assembly's core problem (what evidence for this purpose).

### Candidate F: Purpose-Stratified Context

Evidence is organized into purpose-defined strata — ordered priority groups where each stratum contains evidence serving a specific role in the context. Strata are defined by the context strategy, not by a fixed architecture. Each strategy specifies: which strata exist, what evidence belongs in each, the priority ordering, and the budget allocation. Budget is allocated top-down: the highest-priority stratum is filled first, then the next, until the budget is exhausted or all strata are filled. Coherence constraints are defined per strategy and enforced during filling.

The strata for an "explain" strategy might be: (1) Anchor Core — the anchor's identity, signature, and structural properties; (2) Behavior — callees, behavioral characterization, control flow; (3) Context — containing scope role, module position; (4) Design — purpose, trade-offs, architectural assessment. The strata for an "impact" strategy might be: (1) Anchor Core; (2) Dependents — all direct dependents; (3) Transitive — multi-hop dependents; (4) Coverage — test evidence, safety annotations.

**Strengths:** Purpose-specific by construction — each purpose defines its own strata. Budget allocation is natural: fill high-priority strata first. Coherence constraints are strategy-specific and enforced during assembly. Distance decay (DA-5) is embedded: higher-priority strata typically contain closer evidence. Tier balance (DA-6) is strategy-specific: explain strategies include T2 strata; impact strategies emphasize T0 strata. New purposes require new strategies (a set of stratum definitions), not new assembly infrastructure. Deterministic: given the same evidence set and strategy, the same frame is produced.

**Weaknesses:** Strategy design requires judgment — a poorly designed strategy produces poor context. The number of strategies grows with the number of purposes. Coherence constraints that cross strata (e.g., a behavioral claim in stratum 2 requiring structural support in stratum 1) require cross-stratum coordination during filling.

**Disqualifying condition:** None identified.

## Evaluation

| Criterion | Flat (A) | Ranked (B) | Hierarchical (C) | Progressive (D) | Layered (E) | Purpose-Stratified (F) |
|-----------|----------|------------|-------------------|------------------|-------------|----------------------|
| Purpose-specific selection (DA-3) | No | Partial (per-purpose scoring) | No (fixed tree) | No (fixed rings) | No (fixed layers) | **Yes** (per-purpose strata) |
| Coherence guarantee (DA-4) | No | No | Partial (tree-local) | No | No (cross-layer) | **Yes** (strategy-defined constraints) |
| Budget management (DA-2) | Arbitrary | Top-K | Top-down tree | Ring-by-ring | Per-layer | **Stratum-by-stratum** |
| Distance decay (DA-5) | No | Embedded in score | Yes (tree depth) | Yes (ring order) | No | **Yes** (stratum priority) |
| Tier balance (DA-6) | No | Embedded in score | No | Fixed | Partial (layer ≈ tier) | **Yes** (strategy-defined) |
| Graph structure fidelity | Yes (no structure) | No (flattened) | No (forced tree) | No (forced rings) | Partial | **Yes** (strategy-flexible) |
| Deterministic assembly (DA-10) | Yes | Yes | Yes | Yes | Yes | **Yes** |
| Extensibility (new purposes) | N/A | New scoring function | New tree shape | Fixed | Fixed | **New strategy** |
| Complexity | **Low** | Low | Moderate | Low | Moderate | **Moderate** |

Candidate A is disqualified by lack of coherence and purpose-awareness. Candidate B is disqualified by scalar ranking's inability to express coherence constraints. Candidate C is disqualified by tree structure's inability to represent graph relationships without duplication. Candidate D is disqualified by fixed ring ordering across purposes. Candidate E is disqualified by layer boundaries being orthogonal to purpose priorities.

Candidate F satisfies every criterion. Purpose-specific strata provide purpose-aware selection. Stratum-ordered budget allocation embeds distance decay. Strategy-defined coherence constraints guarantee internal consistency. New purposes require new strategies, not new infrastructure.

## Decision

**Context assembly uses a purpose-stratified architecture where evidence is organized into priority-ordered strata defined by a context strategy.** Each consumer purpose has a corresponding strategy that specifies the strata, their priority, their budget allocation, their fill policy, and their coherence constraints. Budget is allocated top-down across strata: the highest-priority stratum is filled first. The architecture is strategy-parameterized, not structure-parameterized — changing how context is assembled for a new purpose requires defining a new strategy, not building new assembly infrastructure.

---

## Context Strategy

A context strategy is a purpose-specific parameterization that governs how context assembly transforms an evidence set into a context frame.

### Strategy Contract

```
ContextStrategy {
    purpose              : ContextPurpose
    strata               : [StratumDefinition]
    coherenceConstraints : [CoherenceConstraint]
    tierPreference       : TierPreference
    elisionPolicy        : ElisionPolicy
}

StratumDefinition {
    name                 : StratumIdentifier
    priority             : Integer (1 = highest)
    selectionCriteria    : SelectionCriteria
    budgetFraction       : Float (0.0–1.0)
    fillPolicy           : FillPolicy
}
```

### Strategy Fields

**Purpose** (`purpose`): The consumer purpose this strategy serves. A purpose is a named classification of what kind of output the consumer will produce from the context. The context assembly architecture does not define a closed set of purposes. It defines the strategy contract; purposes are enumerated by their strategies.

**Strata** (`strata`): An ordered list of stratum definitions. Each stratum specifies:

- **Name**: A unique identifier within the strategy (e.g., `anchor_core`, `behavior`, `dependents`).
- **Priority**: An integer ordering. Priority 1 is filled first. If the budget is exhausted, lower-priority strata receive no evidence.
- **Selection criteria**: What evidence from the evidence set belongs in this stratum. Criteria reference evidence provenance (DAS-008), distance from anchor, predicate type, tier, and confidence.
- **Budget fraction**: The maximum fraction of the total context budget allocated to this stratum. The sum of all budget fractions must equal 1.0. A stratum may use less than its allocation; unused budget flows to the next stratum.
- **Fill policy**: How evidence within the stratum is ordered for inclusion. Options: by distance (closer first), by tier (T0 first), by confidence (higher first), by entity completeness (fill all properties of one entity before starting the next).

**CS-1: Strata partition the evidence set.** Every unit in the evidence set that is selected for the context frame belongs to exactly one stratum. No unit appears in multiple strata. The strategy's selection criteria must be mutually exclusive across strata.

**CS-2: Budget flows downward.** When a higher-priority stratum uses less than its allocated budget, the remaining budget flows to the next stratum. Budget never flows upward: a lower-priority stratum cannot claim budget from a higher-priority stratum that is already filled.

**Coherence constraints** (`coherenceConstraints`): Rules that require co-occurrence of units. Each constraint is of the form: "if unit matching pattern X is included, then a unit matching pattern Y must also be included." Coherence constraints are evaluated during assembly, not after. When including a unit triggers a coherence constraint, the required unit is included at the priority of the stratum that triggered the constraint, drawing from the budget of whichever stratum the required unit belongs to.

**CS-3: Coherence constraints cannot exceed the budget.** If satisfying all triggered coherence constraints would exceed the budget, the triggering unit is not included. An incoherent frame is worse than a smaller coherent frame. The assembly process never produces a frame that violates its own coherence constraints.

**Tier preference** (`tierPreference`): A guidance (not a hard constraint) for tier balance within the context frame. The preference specifies target ratios (e.g., "at least 50% T0") or tier ordering (e.g., "prefer T0 over T1 over T2" or "T2 preferred when available"). Tier preference influences the fill policy within strata but does not override stratum priority.

**CS-4: Tier preference guides, budget constrains.** Tier preference is a secondary consideration after stratum priority and coherence. A strategy that prefers T2 will not include T2 evidence in a low-priority stratum before T0 evidence in a high-priority stratum.

**Elision policy** (`elisionPolicy`): How evidence is elided when the evidence set exceeds the budget. Options: distance-first (elide furthest evidence first), confidence-first (elide lowest-confidence evidence first), stratum-first (elide lowest-priority strata entirely before reducing higher strata), proportional (reduce all strata proportionally). The elision policy governs the degradation behavior of the context frame under budget pressure.

### Illustrative Strategies

The following strategies are illustrative, not prescriptive. They demonstrate how the strategy contract is parameterized for different purposes.

**Explain Strategy:**

| Stratum | Priority | Selection | Budget | Fill Policy |
|---------|----------|-----------|--------|-------------|
| Anchor Core | 1 | Direct properties of anchor: signature, parameters, return type, line range, entity type | 25% | Distance first |
| Behavior | 2 | Callees (relationship + target identity), behavioral characterization (T2), control flow | 30% | Entity completeness |
| Context | 3 | Containing scope identity, file role, module role, purpose | 25% | Tier (T1 first, then T2) |
| Design | 4 | Design assessment, trade-offs, architectural role, pattern identification | 20% | Confidence first |

Coherence: if a callee relationship is included, the callee's identity (name + type) must be included. If a T2 characterization is included, at least one supporting T0 fact must be included.

Tier preference: all tiers accepted; T2 valued in Behavior and Design strata.

**Impact Strategy:**

| Stratum | Priority | Selection | Budget | Fill Policy |
|---------|----------|-----------|--------|-------------|
| Anchor Core | 1 | Direct properties of anchor: signature, entity type, scope | 15% | Distance first |
| Direct Dependents | 2 | All entities connected by inverse `calls`, `conformsTo`, `dependsOn`, `overrides` at hop 1 — identity and relationship edge | 40% | Distance first |
| Transitive Dependents | 3 | Entities at hop 2+ along same predicates — identity only | 25% | Distance first |
| Coverage | 4 | Test evidence (`tests` predicate), safety annotations | 20% | Confidence first |

Coherence: if a dependency chain A→B→C is included, all intermediate links must be present. Every included entity must have its identity (name + type).

Tier preference: T0 strongly preferred. T1 accepted. T2 included only if budget permits after T0/T1 strata are filled.

**Improve Strategy:**

| Stratum | Priority | Selection | Budget | Fill Policy |
|---------|----------|-----------|--------|-------------|
| Anchor Full | 1 | All direct properties of anchor including full structural detail | 35% | Distance first |
| Assessment | 2 | Behavioral characterization, design assessment, safety assessment (T2) | 30% | Confidence first |
| Context | 3 | Containing scope, role, purpose, sibling entities | 20% | Tier (T1 first) |
| Comparison | 4 | Similar entities in scope for pattern reference | 15% | Distance first |

Coherence: Assessment evidence (T2) must be accompanied by the T0 structural evidence it characterizes. If sibling entities are included, their roles must be included.

Tier preference: all tiers essential. T2 critical for Assessment stratum.

**Follow-up Strategy:**

| Stratum | Priority | Selection | Budget | Fill Policy |
|---------|----------|-----------|--------|-------------|
| Prior Context | 1 | Anchor and evidence from the preceding interaction | 30% | As prior frame |
| Delta | 2 | Evidence responsive to the follow-up question — new relationships, new entities, new semantic characterizations not in prior context | 40% | Distance first |
| Expanded Context | 3 | Additional scope or relational evidence prompted by the follow-up direction | 30% | Distance first |

Coherence: Prior context units are included as-is (not re-selected). Delta evidence must not contradict prior context evidence (if it does, both are included with tier annotations for the consumer to resolve).

Tier preference: match the prior context's tier distribution.

**Investigation Strategy:**

| Stratum | Priority | Selection | Budget | Fill Policy |
|---------|----------|-----------|--------|-------------|
| Anchor Core | 1 | Direct properties of anchor | 15% | Distance first |
| Evidence Trail | 2 | Relationship-traversed evidence along all predicates, broad traversal | 45% | Entity completeness |
| Cross-Scope | 3 | Evidence from adjacent scopes, cross-module relationships | 25% | Distance first |
| Semantic | 4 | T2 characterizations of all included entities | 15% | Confidence first |

Coherence: every relationship edge included must have both endpoints' identities present. Cross-scope evidence must include the scope boundary crossing (which edge crosses from one scope to another).

Tier preference: all tiers equally valued. Breadth of evidence preferred over depth.

**Refactoring Strategy:**

| Stratum | Priority | Selection | Budget | Fill Policy |
|---------|----------|-----------|--------|-------------|
| Anchor Core | 1 | All direct properties of anchor | 20% | Distance first |
| All Consumers | 2 | Every entity that references the anchor through any predicate (inverse traversal), with relationship type | 40% | Distance first |
| Contract Evidence | 3 | Conformances, overrides, interface constraints on the anchor | 25% | Confidence first |
| Test Coverage | 4 | Test evidence for anchor and its direct consumers | 15% | Distance first |

Coherence: every consumer entity must include its relationship edge type. If override evidence is present, the overridden entity must be identified.

Tier preference: T0 strongly preferred. T2 accepted only in Test Coverage stratum.

---

## Context Frame Structure

The context frame is the output of context assembly. It is the contract between context assembly and backends.

```
ContextFrame {
    anchors              : [EntityReference]
    purpose              : ContextPurpose
    strategy             : StrategyIdentifier
    strata               : [FilledStratum]
    budget               : ContextBudget
    metadata             : ContextFrameMetadata
}

FilledStratum {
    name                 : StratumIdentifier
    priority             : Integer
    units                : [ContextUnit]
    allocated            : BudgetAmount
    used                 : BudgetAmount
}

ContextUnit {
    unit                 : AtomicUnit
    contextRole          : ContextRole
    distanceFromAnchor   : Integer
    tier                 : Tier
    confidence           : ConfidenceLevel
    grounding            : GroundingChain
}

ContextBudget {
    total                : BudgetAmount
    unit                 : BudgetUnit (tokens | unitCount)
    used                 : BudgetAmount
    utilization          : Float (0.0–1.0)
}

ContextFrameMetadata {
    evidenceSetSize      : Integer
    selectedCount        : Integer
    elisionCount         : Integer
    unitsByTier          : {T0: Integer, T1: Integer, T2: Integer}
    unitsByStratum       : {StratumIdentifier: Integer, ...}
    coherenceConstraintsFired : Integer
    coherenceConstraintsSatisfied : Integer
    degradationLevel     : DegradationLevel
    freshness            : FreshnessState
    assemblyDuration     : Duration
}
```

**CF-1: The context frame is self-describing.** The metadata enables consumers to understand the context frame's composition without scanning every unit. A consumer can determine: how much evidence was selected from the evidence set, what was elided, what tier balance exists, what degradation level is in effect, and whether the frame is fresh.

**CF-2: The context frame preserves stratum structure.** Units are grouped by stratum, and strata are ordered by priority. A consumer that processes the context frame in stratum order processes the highest-priority evidence first. If the consumer is interrupted or truncated, it has processed the most important evidence.

**CF-3: Every unit carries its context role.** The context role explains why the unit was selected for the frame. This is distinct from evidence provenance (why the unit was gathered during retrieval) and from unit provenance (how the unit was produced). Context role enables consumers and downstream analysis to understand the assembly logic without re-deriving it.

---

## Evidence Selection Model

Evidence selection is the core operation of context assembly: given an evidence set and a context strategy, which units are included in the context frame?

### Selection Process

**ES-1: Stratum-ordered selection.** Selection proceeds stratum-by-stratum in priority order. For each stratum:

1. **Candidate identification.** Apply the stratum's selection criteria to the evidence set. The result is the set of candidate units for this stratum.
2. **Ordering.** Apply the stratum's fill policy to order the candidates. The fill policy determines which candidates are included first if the stratum's budget cannot accommodate all candidates.
3. **Coherence check.** For each candidate in fill order, check whether including it triggers any coherence constraints. If a constraint requires including a unit that belongs to this stratum, include both. If a constraint requires including a unit that belongs to another stratum, reserve that unit in the other stratum (it will be included when that stratum is processed, and it will not consume this stratum's budget).
4. **Budget check.** Include the candidate if the stratum's remaining budget can accommodate it. If not, apply the elision policy: skip this candidate and try the next, or stop filling this stratum.
5. **Repeat** until all candidates are processed or the stratum's budget is exhausted.

**ES-2: Unused budget flows forward.** If a stratum uses less than its allocated budget, the unused portion is added to the next stratum's allocation. This ensures that high-priority strata with sparse evidence do not waste budget.

**ES-3: Cross-stratum coherence is resolved during selection.** When a coherence constraint in stratum N requires a unit that belongs to stratum M (where M > N), the required unit is marked as reserved. When stratum M is processed, reserved units are included first, before the stratum's own candidates. Reserved units consume stratum M's budget. If stratum M's budget cannot accommodate its reserved units, the triggering unit in stratum N is removed, and the coherence constraint is resolved by exclusion.

### Selection Criteria

Selection criteria reference the evidence set's annotations (DAS-008 Stage 5: Annotation):

- **By evidence provenance:** "include units with provenance 'direct property of anchor'" or "include units with provenance 'relationship via calls, hop 1.'"
- **By predicate type:** "include units with predicate in {hasSignature, hasReturnType, hasParameters}" or "include relationship units with predicate calls."
- **By distance from anchor:** "include units at distance ≤ 1" or "include units at distance ≤ 2."
- **By tier:** "include T0 units" or "include T0 and T1 units."
- **By confidence:** "include units with confidence ≥ moderate."
- **By entity type:** "include units whose subject is of type Function" or "include units about entities of type Module."

Criteria compose conjunctively: "include T0 units with predicate calls at distance ≤ 1."

### Fill Policies

Fill policies determine the ordering of candidates within a stratum:

- **Distance first:** Candidates at lower distance are included before those at higher distance. Within the same distance, ordered by tier (T0 first).
- **Tier first:** Candidates at lower tier are included before those at higher tier. Within the same tier, ordered by distance.
- **Confidence first:** Candidates at higher confidence are included before those at lower confidence.
- **Entity completeness:** All properties of entity E are included before any properties of entity F. Entities are ordered by their distance from the anchor. This policy prevents fragmentary evidence about many entities in favor of complete evidence about fewer entities.

**ES-4: Fill policies are deterministic.** Given the same candidates and the same fill policy, the same units are selected in the same order. Ties are broken by a canonical ordering on unit identifiers (DAS-002 I-ID-1). This ensures deterministic assembly (DA-10).

---

## Budget Management

The context budget is the hard constraint that bounds the context frame.

### Budget Units

The budget is expressed in units meaningful to the consumer:

- **Token count:** For AI consumers, the budget is denominated in tokens. Context assembly must estimate the token cost of each unit and allocate accordingly. Token estimation is approximate — the exact token count depends on the consumer's tokenizer, which context assembly does not know. The estimation must be conservative (overestimate rather than underestimate).
- **Unit count:** For automated consumers, the budget may be denominated in the number of atomic units. Simpler than token estimation.

**BM-1: The budget is a hard ceiling.** Context assembly never exceeds the budget. If exact compliance is impossible (because the minimum coherent frame exceeds the budget), assembly produces the best-effort frame and annotates the metadata with a budget violation flag.

**BM-2: Budget allocation is stratum-driven.** Each stratum declares a budget fraction. The fraction represents the maximum share of the total budget that the stratum may consume. Allocations are computed at assembly time by multiplying the fraction by the total budget.

**BM-3: Budget utilization is observable.** The context frame's metadata includes the total budget, the used budget, and the utilization ratio. Persistent low utilization indicates that the evidence set is sparse relative to the budget (the retrieval scope may be too narrow). Persistent full utilization with elision indicates that the evidence set is rich relative to the budget (the strategy may need rebalancing or the budget may need increasing).

### Elision Under Budget Pressure

When the evidence set contains more evidence than the budget can accommodate, the elision policy determines what is sacrificed:

**EP-1: Stratum-first elision.** Lowest-priority strata are emptied before higher-priority strata are reduced. This preserves the most important evidence at the cost of background and enriching evidence. The priority ordering of strata is the primary elision dimension.

**EP-2: Within-stratum elision.** When a stratum must be reduced (either because stratum-first elision has emptied all lower strata and the remaining strata still exceed the budget, or because the proportional elision policy is in effect), evidence is elided within the stratum by the reverse of the fill policy: the last-filled unit is the first-elided.

**EP-3: Essential evidence is never elided.** Some evidence within the highest-priority stratum is essential — its absence makes the context frame unusable (DA-9). Essential evidence is marked in the stratum definition. Essential units are included before all non-essential units and are protected from elision. If the budget cannot accommodate the essential evidence, assembly reports a budget-insufficiency failure (see Failure Modes).

---

## Tier and Confidence Balancing

Context assembly inherits tier-aware evidence from the evidence set (DAS-008 TC-1 through TC-5). Its responsibility is to balance tier representation within the context frame according to the strategy's tier preference.

### Tier Balancing

**TB-1: Tier balance is strategy-defined, not universally optimal.** The explain strategy values T2 evidence (behavioral characterization, purpose, design assessment). The impact strategy values T0 evidence (deterministic relationships). Context assembly applies the strategy's tier preference during fill: when two candidates of equal priority compete for budget, the preferred tier is included first.

**TB-2: T0 evidence anchors the context frame.** Regardless of tier preference, every context frame includes T0 evidence about the anchor. T0 evidence is the foundation — it establishes what exists, what it is, and how it connects. Without T0 evidence, higher-tier characterizations are ungrounded within the context frame itself (even if they are grounded in the DIR through their grounding chains).

**TB-3: T2 absence reduces quality, not correctness.** When T2 evidence is unavailable (semantic enrichment has not run, AI outage), context assembly produces a context frame with T0 and T1 evidence only. The frame's metadata reports the degradation level (DAS-003 Graceful Degradation). The frame is smaller and less rich but not incorrect. This is the context-assembly-level expression of DAS-001 P12.

### Confidence Balancing

**CB-1: Confidence is surfaced, not filtered, by default.** Context assembly includes all confidence levels that the evidence set contains (which may already be filtered by the retrieval request — DAS-008 TC-4). The consumer decides how to treat low-confidence evidence.

**CB-2: A context strategy may specify a confidence floor.** When specified, units below the confidence floor are excluded during selection. This is primarily used by strategies serving automated consumers (impact analysis, refactoring) that require high-confidence evidence for correctness.

**CB-3: Confidence influences within-stratum ordering.** When the fill policy is "confidence first," higher-confidence evidence is included before lower-confidence evidence. Under budget pressure, this naturally elides low-confidence evidence first.

---

## Grounding Preservation

**GP-1: Context assembly preserves grounding chains.** Every unit in the context frame carries its full grounding chain (DAS-002 I-GND-1 through I-GND-4), inherited from the evidence set. Context assembly does not modify, truncate, or strip grounding. The grounding chain enables consumers to verify any claim by tracing it to source material.

**GP-2: Grounding targets need not be present in the context frame.** A T2 unit's grounding chain may reference T0 units that are not included in the context frame (because they were elided or belong to a lower-priority stratum). This is acceptable — the grounding chain is a DIR reference, not a context-frame-internal reference. A consumer that needs to verify the claim can query the DIR through retrieval; it does not need the grounding targets to be co-present in the frame.

**GP-3: Coherence constraints may require grounding co-presence.** A strategy may define a coherence constraint: "if a T2 behavioral characterization is included, at least one T0 supporting fact from its grounding chain must also be included." This is not a general rule — it is a strategy-specific coherence constraint applied when the consumer benefits from seeing the evidence basis alongside the claim. The constraint consumes budget like any other coherence constraint.

---

## Context Coherence

Coherence is the property that the context frame is internally consistent and self-contained enough for the consumer to use.

### Coherence Guarantees

**CC-1: Reference resolution.** If the context frame includes a relationship edge (A, predicate, B), then entity B's identity (at minimum: name and entity type) must be present in the frame. A relationship to an unidentified entity is not usable — the consumer cannot interpret "A calls ???." This is enforced as a coherence constraint in every strategy.

**CC-2: Claim support.** If the context frame includes a T2 interpretive claim about an entity, the entity's T0 structural identity must be present. A design assessment of an entity whose name and type are absent is not evaluable. This is enforced as a coherence constraint when the strategy includes T2 strata.

**CC-3: Scope anchoring.** If the context frame includes scope context (file role, module role), the scope's identity (file name, module name) must be present. Scope context without scope identity is disorienting.

### Coherence Enforcement

**CE-1: Coherence constraints are enforced during selection, not after.** Context assembly does not select evidence and then check coherence. It checks coherence as each unit is considered for inclusion. This prevents the situation where a unit is included and its coherence target is later elided by budget pressure.

**CE-2: Coherence and budget interact through constraint retraction.** If including unit A triggers coherence constraint C, requiring unit B, and including both A and B would exceed the budget, then neither A nor B is included. The constraint is retracted, and assembly continues with the next candidate. This ensures the frame is always coherent: no unit is included without its coherence dependencies.

**CE-3: Coherence is strategy-defined.** Different strategies impose different coherence requirements. The explain strategy requires callee identification for every callee relationship. The impact strategy requires identity for every dependent. The investigation strategy requires identity for every entity at any distance. Coherence constraints are part of the strategy contract, not a fixed property of context assembly.

---

## Context Freshness

**CFR-1: Context freshness inherits from evidence freshness.** The evidence set carries freshness metadata (DAS-008 ES-1: staleness information). Context assembly passes this through to the context frame. If the evidence set contains invalidated units (included under the "tolerant" freshness requirement), those units carry their invalidation status into the context frame.

**CFR-2: Context frames are not cached.** Context frames are transient, derived artifacts (DAS-001 P6). They are produced on demand and discarded after consumption. There is no context frame cache to become stale. Each assembly produces a fresh frame from the current evidence set.

**CFR-3: Context freshness is communicated in metadata.** The context frame's metadata includes: the number of active vs. invalidated units, the degradation level, and a freshness state indicator (fresh, partially stale, stale). Consumers use this to calibrate their output quality.

---

## Context Lifecycle

A context frame has a simple lifecycle with no persistent state:

```
Requested → Assembled → Consumed → Discarded
```

**CL-1: Context frames are ephemeral.** A context frame exists only for the duration of a single consumer interaction. It is not stored, not versioned, not referenced by future operations. If the same question is asked again, a new context frame is assembled from the current evidence set.

**CL-2: Context frames are idempotent within a snapshot.** Given the same evidence set (same DIR snapshot) and the same context strategy, assembling the frame twice produces identical results (DA-10, ES-4). This enables debugging: a context frame can be reproduced by replaying the evidence set and strategy.

**CL-3: Context frames do not modify the DIR.** Context assembly is a read-only operation over the evidence set. It does not produce atomic units, does not modify indexes, and does not trigger pass execution. The separation between "produce intelligence" (passes), "organize intelligence" (indexes), "gather evidence" (retrieval), and "assemble context" (this chapter) is maintained.

---

## Failure Modes

**FM-1: Evidence set empty.** The evidence set from retrieval contains no units (the subject was not found, or the DIR is unpopulated for the relevant scope). Context assembly produces an empty context frame with metadata indicating "no evidence." This is not a context assembly failure — it is a retrieval outcome propagated through.

**FM-2: Budget insufficient for essential evidence.** The context budget is too small to accommodate the essential evidence defined by the strategy's highest-priority stratum. Context assembly cannot produce a usable frame. It returns a frame containing whatever essential evidence fits, with a `budgetInsufficient` flag in the metadata. The consumer must decide whether to proceed with partial essential evidence or to increase the budget and re-request.

**FM-3: Coherence constraints unsatisfiable.** A coherence constraint requires a unit that does not exist in the evidence set (e.g., "include callee identity" but the callee was not gathered by retrieval). The constraint cannot be satisfied. Context assembly includes the triggering unit without its coherence target and annotates the frame with a `coherenceViolation` flag identifying the unsatisfied constraint. The consumer receives a partially incoherent frame and can decide how to handle it.

**FM-4: Strategy not found.** The requested purpose has no corresponding context strategy. Context assembly cannot proceed. This is a configuration error, not a runtime failure. Assembly returns an error with no frame.

**FM-5: Tier degradation.** The evidence set contains no T2 evidence (AI unavailable) or no T1 evidence (rule engine unavailable). Context assembly proceeds with available tiers, filling strata with whatever tier-appropriate evidence exists. Strata that exclusively select higher-tier evidence (e.g., a "Design" stratum selecting only T2) will be empty. The frame's metadata reports the degradation level.

**FM-6: Evidence set exceeds budget significantly.** The evidence set is many times larger than the budget (e.g., 500 units for a 40-unit budget). This is not a failure — it is the normal case for large codebases. Context assembly's elision policy handles the reduction. However, very high elision ratios (>90%) may indicate that the retrieval scope was too broad for the consumer's budget, and the metadata reports the elision ratio for observability.

---

## Observability

**OB-1: Assembly metrics.** For each context assembly: purpose, strategy used, evidence set size, context frame size, budget, budget utilization, assembly duration. These enable analysis of context assembly efficiency.

**OB-2: Selection metrics.** For each assembly: units selected per stratum, units elided per stratum, units elided by elision policy (distance, confidence, stratum), coherence constraints fired, coherence constraints satisfied, coherence constraints retracted. These enable diagnosis of strategy effectiveness.

**OB-3: Tier distribution.** For each context frame: breakdown by tier (T0/T1/T2) overall and per stratum. Persistent absence of T2 in frames for purposes that value T2 indicates semantic enrichment coverage issues. Persistent absence of T0 in frames indicates structural extraction issues.

**OB-4: Budget pressure.** How often the budget is exhausted (all strata filled), how often it is underutilized (less than 50% used), and how often the essential evidence flag is triggered. Persistent budget exhaustion with high elision indicates the budget is too small or the strategy allocates budget to too many strata. Persistent underutilization indicates the retrieval scope is too narrow or the strategy defines too many strata.

**OB-5: Coherence health.** How often coherence constraints are violated (FM-3), which constraints are most frequently violated, and which strata trigger the most constraint retractions. Frequent coherence violations indicate either retrieval-assembly misalignment (retrieval does not gather what coherence constraints require) or strategy misconfiguration (coherence constraints reference evidence that the retrieval intent does not seek).

---

## Architectural Consequences

**C1: Context assembly is a selection problem, not a generation problem.** Context assembly does not create new information. It selects, organizes, and bounds existing evidence. Every unit in the context frame exists in the evidence set and ultimately in the DIR. Context assembly is the realization of DAS-001 P7 (relevance over completeness): it is the mechanism by which the system optimizes for what is included, not for how much is gathered.

**C2: Purpose determines context structure.** Two different purposes applied to the same evidence set produce two different context frames. This is not a defect — it is the architectural expression of DAS-001 D4 (understanding is relative to a question). The strategy is the mechanism by which purpose flows through context assembly into the context frame.

**C3: Adding a new purpose requires a new strategy, not new infrastructure.** The context assembly architecture is strategy-parameterized. When a new consumer type is introduced (e.g., "security review," "migration planning"), a new context strategy is defined — specifying strata, priorities, selection criteria, coherence constraints, and tier preferences. The assembly mechanism itself does not change. This satisfies DAS-001 P10 (scope scales independently) along the perspective axis.

**C4: The context frame is the contract between context assembly and backends.** Context assembly produces context frames; backends consume them. The context frame's structure (strata, units, metadata) is the interface. This boundary ensures that context assembly and backends evolve independently (DAS-001 P11). Context assembly can change how evidence is selected without affecting backends. Backends can change how they consume context without affecting context assembly.

**C5: Context assembly degrades gracefully across two dimensions.** Missing tiers: T2 absence produces sparser strata but the frame is still valid. Budget pressure: high elision ratios produce smaller frames but the frame is still coherent (within coherence constraints). No context assembly failure produces zero output unless the evidence set is empty (FM-1) or the strategy is missing (FM-4).

**C6: Coherence constraints prevent context fragmentation.** Without coherence constraints, budget-pressured assembly could include relationship edges without endpoints, claims without evidence, and scope context without scope identity — producing a frame that is internally fragmentary. Coherence constraints ensure that what is included can be used. They transform context assembly from "include the top-K units" to "include the top-K units that form a coherent representation."

**C7: Budget management is architecturally explicit.** The budget is not an implementation detail — it is a first-class parameter of context assembly. Budget allocation across strata, budget flow from underutilized strata, budget sufficiency for essential evidence, and budget utilization metrics are all defined at the architectural level. This prevents the common failure mode where budget constraints are handled by arbitrary truncation at the implementation layer.

**C8: Evidence provenance and context role provide full traceability.** For any unit in a context frame, the system can answer three questions: (1) How was this unit produced? (Unit provenance, DAS-002.) (2) Why was this unit gathered? (Evidence provenance, DAS-008.) (3) Why was this unit selected? (Context role, this chapter.) This three-level traceability supports DAS-001 P5 (intelligence is grounded) and C7.1 (the system can explain why specific intelligence was included).

---

## Invariants

**I1: Budget Compliance.**
- **Statement:** Every context frame's total evidence volume does not exceed the context budget specified in the assembly request.
- **Rationale:** Budget overflow causes consumer failure — tokens are lost, computations overflow, attention is saturated. The budget is a hard constraint, not a target. Context assembly that overflows the budget produces a frame that cannot be consumed as intended.
- **Verification:** For each context frame, confirm that the total budget used (as reported in metadata) does not exceed the total budget allocated. Use conservative token estimation; actual token count may be lower but must not be higher.

**I2: Stratum Partitioning.**
- **Statement:** Every unit in the context frame belongs to exactly one stratum. No unit appears in multiple strata.
- **Rationale:** Duplicate units waste budget. Ambiguous stratum membership makes elision decisions unpredictable. A unit that appears in two strata is elided from neither when it should have been elided from one.
- **Verification:** For each context frame, confirm that the sets of unit identifiers across all strata are disjoint and their union equals the full set of units in the frame.

**I3: Coherence.**
- **Statement:** For every coherence constraint defined by the strategy, either (a) the constraint is satisfied (both the triggering unit and the required unit are present), or (b) the constraint is retracted (neither unit is present). No context frame contains a triggering unit without its required unit.
- **Rationale:** A frame with unresolvable references or unsupported claims is worse than a smaller frame without those claims. Incoherent context misleads consumers.
- **Verification:** For each context frame, evaluate every coherence constraint. Confirm that each constraint is either satisfied (both present) or retracted (triggering unit absent). Report any constraint where the triggering unit is present but the required unit is absent as a violation.

**I4: Deterministic Assembly.**
- **Statement:** Given the same evidence set and the same context strategy, context assembly produces the same context frame.
- **Rationale:** Non-deterministic assembly means the same question asked twice about the same code produces different context, leading to different outputs. This is confusing, undebuggable, and prevents reproducible analysis.
- **Verification:** Assemble the same evidence set with the same strategy twice. Confirm identical output (same units, same strata, same order, same metadata).

**I5: Grounding Preservation.**
- **Statement:** Every unit in the context frame carries its complete grounding chain as defined in the DIR (DAS-002 I-GND-1 through I-GND-4). Context assembly does not modify, truncate, or strip grounding from any unit.
- **Rationale:** Grounding enables consumers to verify claims. If context assembly truncates grounding, consumers cannot trace claims to source material, violating DAS-001 P5.
- **Verification:** For each unit in the context frame, confirm that its grounding chain is identical to the grounding chain on the same unit in the evidence set and in the DIR.

**I6: Stratum Priority Ordering.**
- **Statement:** If a context frame contains evidence in stratum N (priority P) and stratum M (priority Q where Q > P, meaning M is lower priority), then stratum N is fully filled (all candidates that fit within its budget are included, or its budget is exhausted). No lower-priority stratum receives evidence while a higher-priority stratum has budget remaining and unfilled candidates.
- **Rationale:** If a low-priority stratum is filled while a high-priority stratum has unfilled candidates, the context frame includes less important evidence at the expense of more important evidence. The priority ordering is the strategy's primary mechanism for expressing importance.
- **Verification:** For each context frame, confirm that no stratum with unfilled candidates and remaining budget is followed by a stratum that received evidence. (Exception: reserved units from coherence constraints may appear in lower strata even when higher strata have budget; this is the cross-stratum coherence mechanism, not a priority violation.)

**I7: No Side Effects.**
- **Statement:** Context assembly does not modify the DIR, does not modify indexes, does not trigger pass execution, does not produce atomic units, and does not modify the evidence set. Context assembly is a pure transformation from evidence set to context frame.
- **Rationale:** Context assembly that has side effects couples the "read intelligence" path (retrieval → context assembly → backend) with the "produce intelligence" path (frontends → passes → DIR). This coupling violates the pipeline boundaries defined in DAS-002 and makes the system's behavior order-dependent.
- **Verification:** Snapshot the DIR, all indexes, and the evidence set before context assembly. Execute assembly. Confirm that all three are unchanged.

**I8: Tier Monotonicity in Degradation.**
- **Statement:** When a tier is unavailable, the context frame contains all available evidence at lower tiers that would have been selected had the missing tier been present. The absence of T2 evidence does not reduce the T0 or T1 evidence in the frame.
- **Rationale:** This is the context-assembly-level expression of DAS-003 Graceful Degradation. If T2 absence caused the explain strategy's "Behavior" stratum to be empty, and this emptiness somehow caused the "Anchor Core" stratum to also shrink, the system would degrade catastrophically.
- **Verification:** Assemble a context frame with all tiers present. Remove all T2 evidence from the evidence set. Re-assemble. Confirm that all T0 and T1 units from the first frame are present in the second frame (those that were selected for their tier, not for co-occurrence with T2 evidence). T0 and T1 units that were included only because of coherence constraints with T2 evidence may be absent — this is expected.

---

## Non-Goals

This chapter does not:

- **Define retrieval.** How evidence is gathered from the DIR is defined in DAS-008. Context assembly consumes evidence sets; it does not gather them.

- **Define consumer architecture.** How consumers process context frames and produce outputs is a downstream concern (DAS-011). This chapter produces context frames; what consumers do with them is out of scope.

- **Define specific consumer interfaces.** How consumers express questions, how questions are mapped to purposes, and how context frames are rendered into consumer-specific formats are delivery concerns.

- **Define the set of purposes.** The context assembly architecture defines the strategy contract. The enumeration of specific purposes and their strategies is a configuration concern, not an architectural one. The illustrative strategies in this chapter are examples, not a closed set.

- **Define how token budgets are estimated.** The mechanism for estimating a unit's token cost (which depends on the consumer's tokenizer) is an implementation concern. This chapter requires only that estimates are conservative.

- **Prescribe specific technologies.** No ranking algorithm, scoring function, data structure, or processing framework is specified.

- **Define context formatting.** How a context frame is serialized into a specific syntax (XML, JSON, plain text) for a specific consumer is a backend concern. This chapter defines the semantic structure of the context frame, not its serialized form.

---

## Open Questions

**Q1: Should context strategies be composed?** *(Non-blocking)*

A follow-up question after an explanation involves two purposes: the original explain purpose (for continuity) and the follow-up purpose (for the new question). The illustrative follow-up strategy handles this by defining a "Prior Context" stratum. An alternative approach would be to compose two strategies: the explain strategy for the base context and a delta strategy for the new evidence. Strategy composition would be more general (any purpose could have a follow-up) but more complex (how do two strategies interact?).

**Investigation approach:** Enumerate multi-purpose consumer scenarios. If most can be handled by dedicated strategies (as the follow-up strategy demonstrates), composition is unnecessary. If a combinatorial explosion of strategies emerges, consider a lightweight composition mechanism.

**Q2: Should context assembly support iterative refinement?** *(Non-blocking)*

The current architecture is single-pass: one evidence set, one strategy, one context frame. An alternative would allow the consumer to request refinement: "the context frame was insufficient — re-assemble with a larger budget" or "include more evidence from the Behavior stratum." Refinement is currently handled by constructing a new retrieval request (with different scope or budget) and re-assembling. A dedicated refinement mechanism could be more efficient (reuse the evidence set, adjust only the strategy parameters) but introduces statefulness into an otherwise stateless operation.

**Investigation approach:** Monitor the frequency of "re-request with larger budget" patterns in production. If common, consider a refinement mechanism that takes the prior frame and a set of adjustments as input. If rare, the current stateless model is sufficient.

**Q3: Should context frames carry quality estimates?** *(Non-blocking)*

The current metadata reports composition facts: tier distribution, budget utilization, elision count, degradation level. It does not report a quality estimate: "this context frame is likely sufficient for the consumer to produce a correct output." Quality estimation would require understanding what the consumer will do with the context — which is a backend concern, not a context assembly concern. However, heuristic quality indicators (e.g., "essential evidence present + T2 enrichment available + budget not exhausted = high quality") could be useful for routing or prioritization.

**Investigation approach:** Define heuristic quality indicators based on metadata signals. Test whether they correlate with consumer output quality. If they do, promote to a formal metadata field. If not, the metadata already provides sufficient compositional information for consumers to make their own quality assessments.

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
              ├── DAS-008 (Retrieval Architecture)
              └── DAS-009 (this chapter — Context Assembly)
                    └── DAS-011 (Consumer Architecture)
```

This chapter depends on:
- DAS-000: chapter structure, review checklist
- DAS-001: D7 (diminishing returns), P1 (canonical asset), P6 (understanding is derived), P7 (relevance over completeness), P10 (scope scales independently), P11 (boundaries define independent variability), P12 (graceful degradation)
- DAS-002: DIR pipeline (context assembly sits between retrieval and backends), atomic unit contract (units are the content of context frames), grounding (I-GND-1 through I-GND-4 — context preserves grounding)
- DAS-003: tier model (T0/T1/T2 — tier balancing in strategies), confidence model (confidence balancing), freshness contracts (context freshness inherits evidence freshness), graceful degradation levels (context frames degrade by tier)
- DAS-004: entity types (entities are subjects and anchors in context), containment hierarchy (scope context strata)
- DAS-005: relationship predicates (coherence constraints reference relationship edges and targets)
- DAS-006: pass architecture (passes produce the DIR content that ultimately appears in context frames — but context assembly does not interact with passes)
- DAS-007: index architecture (indexes are traversed by retrieval, which produces the evidence sets context assembly consumes — but context assembly does not interact with indexes)
- DAS-008: evidence set contract (AnnotatedUnit, EvidenceSetMetadata, evidence provenance — the input to context assembly), retrieval request (the purpose/intent that maps to context strategies), retrieval correctness (RC-5: retrieval does not guarantee relevance — context assembly provides it; RC-6: retrieval does not guarantee sufficiency — context assembly cannot guarantee it either but optimizes for it)

This chapter is depended on by:
- DAS-011 (Consumer Architecture): consumers consume context frames; they depend on understanding the context frame structure, strata, and metadata
- DAS-010 (Incremental Update Model): incremental update may need to invalidate or re-assemble context frames when the underlying evidence changes — but since context frames are ephemeral (CL-1), this dependency is minimal

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub titled "Backend Architecture" with section
    headings and open questions.
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the context assembly
    architecture. Renamed from "Backend Architecture" to "Context Assembly" — backend
    architecture is pushed to the next chapter. Purpose-stratified context assembly selected
    over flat, ranked, hierarchical, progressive, layered, and evidence-graph alternatives.
    Context strategy contract defined. Context frame structure defined. Evidence selection
    model (stratum-ordered with coherence), budget management, tier/confidence balancing,
    grounding preservation, coherence model, and context lifecycle defined. Eight invariants.
    Three open questions. Eight architectural consequences. Supersedes the DAS-009 stub.
```
