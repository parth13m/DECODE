# DAS-002: Decode Intermediate Representation (DIR)

```
Chapter:       DAS-002
Title:         Decode Intermediate Representation (DIR)
Status:        Frozen
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001
Depended By:   DAS-003, DAS-004, DAS-005, DAS-006, DAS-007, DAS-008, DAS-009, DAS-010, DAS-011, DAS-012
Supersedes:    DAS-002 (Decode Knowledge Model — stub, never approved)
Superseded By: —
Layer:         L1
```

## Abstract

This chapter defines the Decode Intermediate Representation (DIR) — the canonical internal representation of software that Decode constructs, maintains, and projects into every capability. The DIR is the single source of truth inside Decode. It sits between source code (the input) and understanding (the output), serving the same architectural role that LLVM IR serves in a compiler or a logical plan serves in a database. Every downstream capability — explanation, investigation, impact analysis, refactoring, improvement, AI-assisted reasoning — consumes the DIR. This chapter defines the DIR's purpose, its atomic unit, its structural invariants, its pipeline architecture, and its relationships to all downstream systems.

## Motivation

Without a canonical internal representation, Decode faces a combinatorial explosion: every input format (programming language, configuration format, markup language) must be independently connected to every output capability (explanation, improvement, impact analysis, investigation). With N input formats and M capabilities, this requires N×M integration paths — each with its own parsing logic, its own intermediate structures, and its own assumptions about what information is available.

A canonical intermediate representation reduces this to N+M: N frontends that translate source into DIR, and M backends that consume DIR to produce outputs. Adding a new language requires one new frontend, not M new integrations. Adding a new capability requires one new backend, not N new parsers.

But the value of the DIR extends beyond combinatorial reduction. The DIR is the **point of maximum leverage**: any improvement to the DIR — richer structure, better grounding, more precise confidence — improves every downstream capability simultaneously. Engineering effort invested in the DIR multiplies across all consumers. Engineering effort invested in a specific output path benefits only that path.

Without this chapter, the system has no defined internal contract. Subsystems will independently invent their own representations, leading to inconsistency, duplication, and the architectural leakage identified in DAS-000 AP1.

**Source RFCs:**
- [RFC-000: Canonical Asset](../rfc/RFC-000-Canonical-Asset.md) — establishes the canonical asset and its properties
- [RFC-002: Canonical Asset — Adversarial Review](../rfc/RFC-002-Canonical-Asset-Adversarial-Review.md) — confirms the asset and identifies its graph-theoretic foundation
- [RFC-005: Contract of the Atomic Unit](../rfc/RFC-005-Atomic-Unit-Contract.md) — defines the structural and behavioral contract of the DIR's atom
- [RFC-006: The Intermediate Representation Hypothesis](../rfc/RFC-006-DIR-Hypothesis.md) — establishes the DIR framing over the Intelligence framing

## Terminology

**DIR (Decode Intermediate Representation)** — The canonical internal representation of software inside Decode. The DIR is a collection of atomic units, each carrying tiered, grounded, provenanced metadata about a software entity or a relationship between entities. The DIR is the single source of truth from which all outputs are derived. The DIR is Decode's canonical asset (DAS-001 P1). *Is:* a structured, queryable, versionable, incrementally maintainable representation of everything Decode knows about a codebase. *Is not:* source code, an AST, a database schema, or an AI model's output. `INTRODUCED`

**Atomic Unit** — The smallest indivisible element of knowledge in the DIR. Each atomic unit is a single claim about a software entity or pair of entities, carrying a typed predicate, a typed value, tier classification, provenance, confidence, grounding, version, and lifecycle status. Atomic units are immutable once created. *Is:* "function `authenticate` has return type `Bool`" with all associated metadata. *Is not:* a raw AST node, a line of source code, or a parsed token. `INTRODUCED`

**Frontend** — A component that reads source material (in a specific language or format) and emits atomic units into the DIR. Each frontend is language-specific; the DIR is language-independent. *Is:* the Swift frontend that parses Swift source files and produces structural and relational atomic units. *Is not:* a general-purpose parser, a linter, or an IDE extension. `INTRODUCED`

**Enrichment Pass** — A component that reads existing atomic units in the DIR and produces new atomic units at the same or higher tier. Passes are independent, composable transformations. *Is:* a semantic enrichment pass that reads structural and relational units and produces behavioral and interpretive units. *Is not:* a frontend (passes do not read source directly), a query (passes write to the DIR, queries only read). `INTRODUCED`

**Backend** — A component that reads DIR content (via retrieval and context assembly) and produces output for a consumer. Backends do not write to the DIR. *Is:* the AI explanation backend that assembles DIR context and produces understanding for a developer. *Is not:* an enrichment pass (backends do not write to the DIR). `INTRODUCED`

**Index** — A derived, query-optimized structure built from DIR content. Indexes accelerate retrieval but carry no authority — the DIR is always the source of truth. If an index and the DIR disagree, the index is rebuilt. *Is:* an entity lookup index that maps entity identifiers to their atomic units. *Is not:* a separate knowledge store, a cache of AI responses, or a replacement for the DIR. `INTRODUCED`

**Predicate** — An identifier that classifies what kind of claim an atomic unit makes. Each predicate has a defined domain (knowledge domain per DAS-003), expected value type, subject arity (single entity or entity pair), and maximum deterministic tier. Predicates are drawn from a versioned, append-only registry. *Is:* `hasReturnType`, `calls`, `hasPurpose`, `hasLineRange`. *Is not:* a value, a subject, or a tier. `INTRODUCED`

**Tier** — An ordered classification of an atomic unit's objectivity. Lower tiers are deterministic (algorithmically derived, provably correct). Higher tiers are semantic (inference-derived, interpretively valid). Every atomic unit declares its tier at creation; the tier is immutable. The specific tiers and their properties are defined in DAS-003. `INTRODUCED`

**Provenance** — A record of what produced an atomic unit: the producer identity, the production method, the timestamp, and the input units or source material consumed. Provenance is immutable and machine-interpretable. `INTRODUCED`

**Grounding** — The chain of evidence connecting an atomic unit to source material. A directly extracted unit is grounded at a source position. A derived unit is grounded through the units it was derived from. Every grounding chain is finite, acyclic, and terminates at source material. `See DAS-001`

## Domain Analysis

**DA-1: Every system that processes complex structured input creates an intermediate representation.** Compilers create IR between source and machine code. Databases create logical plans between SQL and physical execution. Search engines create indexes between documents and query results. Language servers create symbol graphs between source files and IDE features. This is not a design choice — it is a structural inevitability. Any system that transforms complex input into multiple outputs will create an internal canonical form, whether deliberately designed or accidentally accumulated. A deliberately designed IR is superior to an accidentally accumulated one because it can be optimized for internal operations, governed by explicit invariants, and evolved through a controlled process.

**DA-2: The value of an IR is proportional to the number of independent consumers.** An IR with one consumer is overhead — you might as well couple the producer directly to the consumer. An IR with ten consumers saves ten independent integration paths. Decode's consumers include: explanation, follow-up conversation, code improvement, impact analysis, investigation, refactoring assistance, autonomous agents, onboarding assistance, and code review. This is a large and growing consumer set, making a canonical IR highly valuable.

**DA-3: IRs succeed when they capture the domain's essential structure, not the input's syntax.** LLVM IR succeeds because it captures computation (instructions, basic blocks, functions) rather than C syntax or Rust syntax. SQL logical plans succeed because they capture relational algebra rather than SQL grammar. An IR that mirrors its input's syntax is just a parsed copy; an IR that captures the domain's structure enables operations that no single input format could support. For Decode, the domain's essential structure is: software entities, their typed relationships, and tiered properties ranging from deterministic to interpretive.

**DA-4: IRs fail when they try to be complete representations of the input.** An IR that preserves every syntactic detail of the source is no simpler than the source itself. The IR's power comes from *selective abstraction* — capturing what downstream operations need and discarding what they don't. Decode's DIR must capture structural facts, relationships, and semantic properties; it need not preserve formatting, comments, or syntactic sugar.

**DA-5: The most successful IRs are defined by a small, stable contract with an extensible property system.** LLVM IR has a fixed instruction set but extensible metadata. Property graphs have a fixed structure (nodes, edges) but extensible properties. This pattern — stable skeleton, extensible properties — enables the IR to evolve without breaking existing consumers.

## Candidates

### Candidate A: No IR — Direct Pipeline

Each input format is directly connected to each output capability through bespoke transformation logic.

**Implications:** N×M integration paths. Each path must independently parse, analyze, and structure the source for its specific output. No shared representation.

**Strengths:** No abstraction overhead. Each path can be optimized for its specific input-output pair. Simple for N=1, M=1.

**Weaknesses:** Combinatorial explosion as N and M grow. No shared investment — improving one path does not improve others. Impossible to ensure consistency across paths. Adding a language requires M new integrations; adding a capability requires N new parsers.

**Disqualifying condition:** Decode has multiple input languages and multiple output capabilities. N×M coupling is untenable.

### Candidate B: Per-Capability IR

Each output capability defines its own intermediate representation, optimized for its specific needs. The explanation engine has an explanation IR; the impact analysis engine has an impact IR.

**Implications:** N×K integration paths (N languages × K distinct IRs), with each IR consumed by a subset of capabilities. Better than N×M but still multiplicative.

**Strengths:** Each IR is optimized for its consumer. No single IR must satisfy all consumers.

**Weaknesses:** Duplication of extraction work across IRs. Consistency not guaranteed — the explanation IR and the impact IR may represent the same function differently. Adding a language requires K new frontends (one per IR). Shared improvements are impossible.

**Disqualifying condition:** DAS-001 P1 requires a single canonical asset. Multiple IRs violate this principle directly.

### Candidate C: Canonical IR (DIR)

A single intermediate representation consumed by all capabilities. Input-specific frontends translate source into the DIR. Capability-specific backends consume the DIR. Enrichment passes transform the DIR to add higher-tier content.

**Implications:** N+M integration paths. One IR contract that all producers and consumers must satisfy. Shared investment across all capabilities.

**Strengths:** N+M coupling instead of N×M. Single point of investment — improving the DIR improves all capabilities. Consistency guaranteed — all capabilities see the same representation of the same software. Adding a language requires one frontend. Adding a capability requires one backend. Enrichment passes benefit all consumers.

**Weaknesses:** The DIR must be general enough to serve all consumers, which may make it suboptimal for any specific consumer. The DIR contract is a coordination point — changes to it affect all producers and consumers.

**Disqualifying condition:** None identified.

## Evaluation

| Criterion | No IR | Per-Capability IR | Canonical IR (DIR) |
|-----------|-------|-------------------|-------------------|
| Satisfies DAS-001 P1 (single canonical asset) | No | No | **Yes** |
| Satisfies DAS-001 P9 (incremental) | Per-path | Per-IR | **Yes** |
| Satisfies DAS-001 P11 (independent variability) | No (paths are coupled end-to-end) | Partial (each IR is independent) | **Yes** (frontends, DIR, passes, indexes, backends vary independently) |
| Scales with languages (N) | O(N×M) | O(N×K) | **O(N)** |
| Scales with capabilities (M) | O(N×M) | O(K×M/K) | **O(M)** |
| Engineering leverage | None | Per-IR | **Maximum** |
| Consistency | Unenforceable | Per-IR only | **System-wide** |

The Canonical IR dominates on every criterion. Per-Capability IR is disqualified by DAS-001 P1. No IR is disqualified by combinatorial scaling.

## Decision

**Decode's canonical asset is the Decode Intermediate Representation (DIR)** — a single, canonical, intermediate representation of software constructed by frontends, enriched by passes, indexed for query, and consumed by backends to produce all outputs.

---

## DIR Architecture

### The Pipeline

The DIR sits at the center of a pipeline with five stages. Each stage is independently replaceable (DAS-001 P11).

```
Stage 1        Stage 2        Stage 3        Stage 4        Stage 5
FRONTENDS  →   DIR        →   PASSES     →   INDEXES    →   BACKENDS
(per-language   (canonical     (enrichment    (query-        (per-capability
 extraction)     store)         transforms)    optimized      consumption)
                                              structures)
```

**Boundary 1: Frontend → DIR.** Frontends vary by language. The DIR is language-independent. This boundary enables adding a new language without changing the DIR, any pass, any index, or any backend. The variability is: *source language syntax on the left, canonical structure on the right.*

**Boundary 2: DIR → Passes.** The DIR stores the current state. Passes read the DIR and produce new atomic units (written back to the DIR). This boundary enables adding new passes without changing the DIR contract, any frontend, or any backend. The variability is: *enrichment logic on the right, stable data contract on the left.*

**Boundary 3: DIR → Indexes.** Indexes are derived views optimized for specific query patterns. This boundary enables adding new indexes without changing the DIR, any pass, or any backend. The variability is: *query optimization strategy on the right, canonical data on the left.* Indexes may be rebuilt from the DIR at any time without data loss.

**Boundary 4: Indexes → Backends.** Backends read from indexes (which are projections of the DIR) via the retrieval layer. This boundary enables adding new backends without changing the DIR, any frontend, or any pass. The variability is: *output capability on the right, structured query results on the left.*

### What the DIR Contains

The DIR is a collection of atomic units. It is not a monolithic data structure — it is a set of individual, immutable, independently queryable units that collectively represent everything Decode knows about a codebase.

The DIR does not contain:
- Source code (that is the input, not the representation).
- Understanding (that is the output, not the representation).
- Index structures (those are derived, not canonical).
- UI state (that is presentation, not knowledge).

---

## Atomic Unit Contract

Every element of the DIR conforms to the following contract. This contract is the constitutional law of the DIR — it is the interface that all frontends must produce, all passes must read and write, all indexes must derive from, and all backends must ultimately consume.

### Required Fields

```
AtomicUnit {
    id           : UniqueIdentifier
    subject      : EntityReference | EntityPair
    predicate    : PredicateIdentifier
    value        : TypedValue
    tier         : Tier
    provenance   : ProvenanceRecord
    confidence   : ConfidenceLevel
    grounding    : GroundingChain
    version      : VersionStamp
    status       : LifecycleStatus
}
```

### Identity (`id`)

Every atomic unit has a globally unique, immutable, opaque identifier assigned at creation.

- **I-ID-1:** No two units in the system share an identifier.
- **I-ID-2:** An identifier, once assigned, is never reassigned to a different unit.
- **I-ID-3:** The identifier carries no semantic content. It is not derived from the unit's fields. It encodes no ordering, no hierarchy, no classification.

Opaque identifiers decouple identity from content. If content is corrected, identity does not change, and references from other units remain valid.

### Subject (`subject`)

The subject identifies what entity or entities the unit is about. It is a reference, not an embedded copy.

**Single-entity subject** (`EntityReference`): The unit is about one entity. A unit recording a function's return type has a single-entity subject referencing that function.

**Paired-entity subject** (`EntityPair`): The unit is about the relationship between two entities. A unit recording that function A calls function B has a paired subject with explicit source (A) and target (B). The pair is ordered: (A, B) ≠ (B, A).

- **I-SUB-1:** Every subject references an entity that exists (or has existed) in the system. Orphaned units — those whose subject references a nonexistent entity — must be garbage-collected.
- **I-SUB-2:** Paired subjects have explicit source and target. Directionality is carried by pair ordering.
- **I-SUB-3:** There is no ternary or higher-arity subject. Relationships involving three or more entities must be decomposed into multiple binary units.

I-SUB-3 ensures that the DIR's relational structure is a directed graph, not a hypergraph. Every relationship in software that has been analyzed — calls, conforms-to, inherits, imports, owns, contains, overrides, depends-on, tests — is binary. The constraint preserves graph-theoretic tractability without losing expressiveness.

### Predicate (`predicate`)

The predicate identifies what kind of claim the unit makes about its subject.

- **I-PRED-1:** Predicates are drawn from a finite, extensible, versioned, append-only registry. New predicates can be added. Existing predicates can be deprecated but never removed. This ensures that existing units remain interpretable.
- **I-PRED-2:** Each predicate declares:
  - Its **domain** — which knowledge domain it belongs to (defined in DAS-003).
  - Its **expected value type** — what kind of value the unit carries.
  - Its **subject arity** — single-entity or paired-entity.
  - Its **maximum deterministic tier** — the highest tier at which this predicate can be deterministically established. A predicate like `hasReturnType` has maximum deterministic tier equal to the lowest tier (fully deterministic). A predicate like `hasPurpose` has maximum deterministic tier of zero (never deterministic).
- **I-PRED-3:** Two units with the same subject and predicate represent competing claims. The system must resolve competition through the lifecycle model (supersession).

### Value (`value`)

The value is what is being claimed. The value type is declared by the predicate.

Permitted value types:
- **Scalar:** string, integer, boolean, float.
- **Enumerated:** one of a predefined set.
- **Text:** free-form text (used for semantic predicates).
- **Reference:** a reference to another entity.
- **Structured:** a compound value with named sub-fields (permitted only when sub-fields are never independently queried — see I-VAL-2).

- **I-VAL-1:** The value is immutable once the unit is created. To change a value, the old unit is invalidated and a new unit is created.
- **I-VAL-2:** If a structured value contains independently queryable sub-fields, those sub-fields must be separate units with separate predicates.

Immutability (I-VAL-1) eliminates mutation tracking, concurrent modification, and version ambiguity. The unit's lifecycle model (creation, supersession, garbage collection) handles all state changes.

### Tier (`tier`)

The tier declares the objectivity level of the unit. The specific tiers are defined by DAS-003 (Tier Model). The contract requires:

- **I-TIER-1:** Tiers are totally ordered. Lower tiers are more objective, more stable, and cheaper to produce.
- **I-TIER-2:** At least two tiers exist: one fully deterministic and one semantic. Finer gradations are permitted.
- **I-TIER-3:** Every unit declares its tier at creation. The tier is immutable for the lifetime of the unit.
- **I-TIER-4:** A unit's tier must not exceed the predicate's maximum deterministic tier unless the predicate permits semantic tiers. A deterministic predicate (e.g., `hasReturnType`) at a semantic tier is an error.
- **I-TIER-5:** No unit at tier N may be derived from a unit at tier M where M > N. Derivation flows from lower tiers to higher tiers, never downward. (This is the unit-level expression of DAS-001 P2.)

### Provenance (`provenance`)

Provenance records what produced the unit.

Every provenance record includes:
- **Producer:** identifier of the subsystem that created the unit (a specific frontend, a specific pass, a human annotator).
- **Method:** the production method category (extraction, inference, derivation, annotation).
- **Timestamp:** when the unit was created.
- **Inputs:** references to the units or source material consumed to produce this unit (empty for units extracted directly from source).

- **I-PROV-1:** Provenance is immutable. If the production method changes, a new unit is created with new provenance; the old unit is superseded.
- **I-PROV-2:** Producer and method are machine-interpretable. The system can programmatically identify all units produced by a specific frontend version, a specific pass, or a specific inference engine.

Machine-interpretable provenance (I-PROV-2) enables batch invalidation: when a parser is upgraded, all units produced by the old parser version can be identified and re-evaluated.

### Confidence (`confidence`)

Confidence quantifies the system's assessment of the unit's correctness.

- **I-CONF-1:** Confidence is a value on an ordered scale with at least two values: **deterministic** (provably correct given correct source) and **inferred** (produced by non-deterministic inference). Finer granularity is permitted but not required.
- **I-CONF-2:** Confidence is bounded by tier. A unit at the lowest (most deterministic) tier must have deterministic confidence. A unit at the highest (most semantic) tier must have inferred confidence.
- **I-CONF-3:** Confidence is immutable. Changed confidence requires a new unit.
- **I-CONF-4:** Confidence is machine-interpretable. A consumer can programmatically determine whether a unit is deterministically established or probabilistically inferred.

Confidence is not a probability. It does not mean "80% chance of being true." It means "produced by a method with this level of reliability." The distinction matters because probabilities require calibration; confidence levels require only ordering.

### Grounding (`grounding`)

Grounding connects the unit to source material through a verifiable evidence chain.

- **I-GND-1:** Every unit has a grounding chain that terminates at source material:
  - **Direct:** extracted from a specific position in a specific source file at a specific version.
  - **Derived:** derived from other units (which have their own grounding, recursively).
  - **Inferred:** produced by semantic inference from input units plus an inference method.
- **I-GND-2:** The grounding chain is finite and acyclic. Every chain terminates at source material within a bounded number of steps.
- **I-GND-3:** If any unit in a grounding chain is invalidated, all units that transitively depend on it are candidates for invalidation.
- **I-GND-4:** Grounding is traversable. Given any unit, a consumer can programmatically walk the grounding chain to its source.

Grounding is the mechanism by which DAS-001 P5 (Intelligence Is Grounded) is enforced at the unit level. It makes every claim in the DIR auditable, debuggable, and invalidatable.

### Version (`version`)

Version identifies what source state the unit was derived from.

- **I-VER-1:** Every unit records the version of the source material it was derived from. For units extracted from a specific file, this is the file's content hash. For derived units, this is the set of source versions from its grounding chain.
- **I-VER-2:** Version enables staleness detection. The system can determine whether a unit's version matches the current source state (fresh) or an older state (stale).
- **I-VER-3:** Version is content-addressed, not counter-based. Two source states with identical content produce the same version. This prevents unnecessary invalidation when a file is saved without changes or when a branch is switched and switched back.
- **I-VER-4:** Version is granular to the source artifact. A unit about a function in file X carries the version of file X, not the version of the entire repository. This enables per-file incrementality (DAS-001 P9).

### Lifecycle Status (`status`)

Every unit exists in exactly one lifecycle state:

```
Created → Active → Invalidated → [Garbage Collected]
                 → Superseded  → [Garbage Collected]
```

- **Active:** The unit is current and available for query, composition, and delivery.
- **Invalidated:** The unit's source material has changed and the unit may no longer be correct. Invalidated units remain queryable (with an invalidation flag) until replaced. This supports graceful degradation (DAS-001 P12).
- **Superseded:** A new unit with the same subject and predicate has been created. The superseded unit retains a reference to its successor for version history.
- **Garbage Collected:** Permanently removed. A storage concern (DAS-012), not a DIR concern.

- **I-LC-1:** Units are created in Active status.
- **I-LC-2:** Invalidation is triggered only by defined triggers: source change, grounding collapse (a unit in the grounding chain was invalidated), or producer upgrade.
- **I-LC-3:** Supersession is triggered by creation of a replacement unit with the same subject and predicate.
- **I-LC-4:** Status transitions are irreversible. An invalidated unit cannot return to Active. If the source reverts, a new unit is created rather than reactivating the old one.
- **I-LC-5:** Immutability applies to all fields except status. Once created, a unit's id, subject, predicate, value, tier, provenance, confidence, and grounding never change.

---

## Producers

### Frontends

Frontends are the entry point to the DIR. Each frontend is specific to a source language or format. Frontends read source material and emit atomic units at deterministic tiers.

**Frontend contract:**
- A frontend reads a source file (or a defined subset of files) and produces a set of atomic units.
- All units produced by a frontend must be at deterministic tiers. Frontends do not perform semantic inference (DAS-001 P3).
- A frontend's output is reproducible: the same source file at the same content hash produces the same set of units (DAS-001 P3, deterministic completeness).
- A frontend emits units with direct grounding — each unit references the source position from which it was extracted.
- Frontends are independently replaceable. A new Swift frontend can replace the old one; the DIR contract is unchanged; no pass, index, or backend is affected.

### Enrichment Passes

Enrichment passes read existing DIR content and produce new atomic units at the same or higher tier. Passes are the mechanism by which the DIR grows from deterministic extraction toward semantic understanding.

**Pass contract:**
- A pass reads units from the DIR (via the query semantics defined below) and produces new units.
- A pass must declare its **tier output range** — the tiers at which it produces units.
- A pass must declare its **input dependencies** — what predicates, tiers, or entity types it reads.
- A pass's output units must have grounding chains that reference the input units (and ultimately, source material). No pass may produce ungrounded units.
- Passes are independently addable, removable, and replaceable. Adding a new pass does not affect existing passes, frontends, or backends.

**Pass ordering:**
- Passes have declared input dependencies. If pass B reads units produced by pass A, pass B must run after pass A.
- The system topologically sorts passes based on declared dependencies. No circular dependencies are permitted.
- Passes with no mutual dependencies may run concurrently.
- Pass ordering is not hardcoded — it is derived from dependency declarations. Adding a new pass does not require editing a global pass order.

**Examples of passes** (illustrative, not prescriptive):
- *Relationship resolution pass:* reads structural units (entity declarations, imports) and produces relational units (calls, conforms-to, inherits) at tier 2.
- *Semantic enrichment pass:* reads structural and relational units and produces behavioral and interpretive units at tiers 3–4 (using AI inference, per DAS-001 P8).
- *Composition pass:* reads entity-level units and produces scope-level units (module-level and system-level emergent properties) at the tier of its highest-tier input.
- *Pattern detection pass:* reads structural and relational units and produces architectural pattern units (e.g., "these entities form a pipeline," "this entity implements the observer pattern").

---

## Relationship Between DIR and Indexes

Indexes are derived, query-optimized structures built from DIR content.

**Index contract:**
- An index is a projection of the DIR, not a parallel store. It contains no information that is not derivable from the DIR.
- An index may be rebuilt from the DIR at any time without data loss.
- An index is optimized for specific query patterns. Different indexes serve different access needs.
- If an index and the DIR disagree, the index is stale and must be rebuilt. The DIR is always authoritative.

**Index examples** (illustrative, not prescriptive):
- *Entity lookup index:* maps entity identifiers to their atomic units. Optimized for "give me everything about entity E."
- *Relationship traversal index:* adjacency structure over paired-subject units. Optimized for "what does entity E call / what calls entity E?"
- *Predicate index:* maps predicates to the units that carry them. Optimized for "find all units of type P."
- *Full-text index:* over text-type values. Optimized for keyword search within semantic properties.

Indexes are a DAS-007 (Retrieval) concern. This chapter defines only the relationship: indexes are derived from the DIR, governed by the DIR's authority, and invalidated when the DIR changes.

---

## Relationship Between DIR and Retrieval

Retrieval is the process of querying the DIR (via indexes) to select units.

Every field on an atomic unit is queryable:
- By subject (all units about entity E).
- By predicate (all units of type P).
- By tier (all deterministic units).
- By status (all active units; all active-or-invalidated units).
- By confidence (all units above a confidence threshold).
- By version (all units derived from source version V).
- By provenance (all units produced by producer X).
- By conjunction of the above.

**Retrieval defaults:**
- Queries return only Active units unless the consumer explicitly requests Invalidated or Superseded units.
- Query results are unordered unless an explicit ordering is requested.
- Queries are point-in-time consistent: a single query observes a consistent snapshot of the DIR.

**Retrieval does not include context assembly.** Retrieval selects units. Context assembly (DAS-008) determines which selected units are relevant for a specific consumer and purpose. These are separate operations.

The full retrieval model is defined in DAS-007. This chapter establishes the minimum query semantics that the DIR must support.

---

## Relationship Between DIR and Context Assembly

Context assembly is the process of selecting, filtering, and shaping retrieved DIR content for a specific consumer at a specific moment for a specific purpose.

Context assembly sits between retrieval and backends:

```
DIR → Indexes → Retrieval (select) → Context Assembly (filter, shape) → Backend (consume)
```

Context assembly is governed by DAS-001 P7 (Relevance Over Completeness): the goal is to deliver the most relevant subset of DIR content, not the most complete.

Context assembly is defined in DAS-008. This chapter establishes the relationship: context assembly reads from the DIR (via retrieval), it does not write to the DIR, and it produces a context frame that is consumed by a backend.

---

## Relationship Between DIR and Consumers

Consumers are backends that read DIR content (via retrieval and context assembly) and produce outputs. The DIR does not know about its consumers. It publishes a query contract; consumers conform to it.

**Consumer contract:**
- A consumer reads DIR content via the retrieval and context assembly layers. It does not read source code directly (DAS-001 P8: AI receives structured intelligence, not raw source).
- A consumer does not write to the DIR. A consumer produces output (understanding, analysis results, action plans) that is external to the DIR.
- A consumer can request DIR content at any tier. If higher-tier content is unavailable, the consumer receives only lower-tier content and must degrade gracefully (DAS-001 P12).

**Exception: Enrichment passes that use AI.** A semantic enrichment pass is architecturally a pass (it reads and writes DIR), not a backend. The AI model within the pass is a tool used by the pass, not a consumer of the DIR. The pass contract governs its behavior, not the backend contract.

**Consumer examples** (illustrative, not prescriptive):
- *Explanation backend:* assembles DIR context about a code entity and produces a human-readable explanation.
- *Impact analysis backend:* traverses DIR relationships from a changed entity and produces a list of affected entities with risk assessments.
- *Improvement backend:* reads DIR content about a code entity and produces improvement suggestions.
- *Investigation backend:* accepts a question, queries the DIR for relevant entities and relationships, and produces an analytical response.
- *Autonomous agent backend:* reads DIR context and produces action plans (refactoring operations, migration steps).

Every current and future Decode capability is a backend that consumes the DIR. This is the architectural guarantee of DAS-001 P1: the DIR is the single asset from which all outputs are derived.

---

## Why Every Capability Consumes the DIR

This is not an organizational preference. It is an architectural necessity derived from first principles.

**From DAS-001 P1 (Single Canonical Asset):** If a capability bypasses the DIR — if it reads source code directly, or maintains its own representation, or caches intermediate results independently — then the system has two sources of truth. Two sources of truth diverge. Divergence produces inconsistency. Inconsistency produces wrong outputs.

**From DAS-001 P3 (Deterministic Before Semantic):** If a capability performs its own parsing instead of reading deterministic DIR content, it duplicates extraction work and may produce results inconsistent with the DIR. The DIR is the single point where deterministic extraction is performed and validated.

**From DAS-001 P5 (Grounding):** If a capability's output is not traceable to the DIR, it is not traceable to source material. Ungrounded outputs cannot be audited or debugged.

**From DAS-001 P7 (Relevance Over Completeness):** Context assembly, which selects relevant DIR content, is a shared infrastructure operation. If each capability implements its own relevance logic, the logic will diverge and some capabilities will deliver irrelevant or missing context.

**From DAS-001 P9 (Incremental):** When source changes, the DIR is incrementally updated. Capabilities that consume the DIR automatically see the updated content. Capabilities that maintain independent representations must independently detect and respond to source changes — duplicating the incremental update infrastructure.

The DIR is not a convenience. It is the mechanism by which the principles are enforced across all capabilities.

---

## Design Constraints

The following constraints govern the DIR's design and evolution. They are derived from DAS-001 principles and the domain analysis.

**DC-1: Language independence.** The DIR does not contain language-specific constructs. A function in Swift and a function in Python produce structurally identical DIR units (same predicates, same value types, same relationship types). Language-specific information is captured in value fields (e.g., a `language` predicate), not in structural differences. This constraint is what makes frontends independently replaceable.

**DC-2: Selective abstraction.** The DIR captures what downstream operations need and discards what they don't. Specifically:
- **Captured:** entity identity, entity properties (signature, parameters, return type, visibility, line range), typed relationships between entities, behavioral characterizations, interpretive assessments.
- **Not captured:** source formatting, whitespace, comments (unless semantically significant), syntactic sugar, encoding details.

The line between captured and not-captured is governed by consumer need, not by input completeness.

**DC-3: Stable contract, extensible predicates.** The atomic unit contract (fields, invariants, lifecycle) is stable and changes rarely. The predicate registry is extensible and changes frequently (new predicates added as new knowledge types are identified). This separation enables evolution without disruption: adding a new predicate does not change the contract; changing the contract affects all producers and consumers.

**DC-4: The DIR exists independently of any query.** The DIR is populated by frontends and passes regardless of whether any consumer has requested information. This is not a statement about eager vs. lazy computation (which is an implementation concern) — it is a statement about architectural independence. The DIR's content is determined by what the source contains, not by what consumers have asked. A consumer may trigger computation of semantic-tier units, but the DIR's structural and relational content exists as a consequence of source analysis, not consumer demand.

**DC-5: The DIR is rebuildable from source.** If the entire DIR is lost, it can be reconstructed from source material by re-running frontends and passes. No DIR content is irreplaceable. Semantic enrichment passes that use AI may produce different results on rebuild (AI is non-deterministic), but the structural and relational tiers are reproduced identically. This constraint ensures that the DIR is never a single point of irreversible failure.

---

## Architectural Consequences

**C1: The DIR is the single investment target.** Any improvement to the DIR — richer predicates, better grounding, more precise confidence, new enrichment passes — improves every backend simultaneously. Engineering effort should be prioritized on DIR quality over output formatting.

**C2: Adding a language is adding a frontend.** A new language support does not require changes to any pass, index, or backend. It requires one new frontend that emits atomic units conforming to the DIR contract.

**C3: Adding a capability is adding a backend.** A new output capability does not require changes to any frontend, pass, or the DIR itself. It requires one new backend that consumes DIR content via retrieval and context assembly.

**C4: The system has exactly two classes of persistent state.** Source material (the input) and the DIR (the canonical asset). Indexes are derived from the DIR. Outputs are transient. UI state is ephemeral. There are no other persistent stores that are not derived from these two.

**C5: The DIR contract is the system's most critical interface.** It is the contract that all producers and all consumers must satisfy. Changes to this contract are the most expensive changes in the system and must go through the DAS change process (DAS-000 Section 8). The contract should change rarely.

**C6: Frontends, passes, indexes, and backends are independently deployable.** Because they communicate only through the DIR contract (and the index/retrieval contracts derived from it), they can be developed, tested, deployed, upgraded, and replaced independently.

---

## Invariants

**I1: DIR Completeness.**
- **Statement:** All persistent, non-source state in the system is either DIR content, derived from DIR content (indexes, caches), or transient (UI state, in-flight computations).
- **Rationale:** Multiple sources of truth produce inconsistency. Any persistent state that is not DIR content and not derived from DIR content is a shadow store that will diverge.
- **Verification:** Enumerate all persistent stores. For each, confirm it is (a) source material, (b) DIR content, (c) derived from DIR with an explicit invalidation path, or (d) explicitly transient.

**I2: Atomic Unit Immutability.**
- **Statement:** Once created, an atomic unit's id, subject, predicate, value, tier, provenance, confidence, and grounding fields never change. Only the status field transitions, and only in permitted directions (Active → Invalidated, Active → Superseded).
- **Rationale:** Mutable units require mutation tracking, concurrent modification control, and version ambiguity resolution. Immutable units eliminate these concerns.
- **Verification:** Audit all write operations on the DIR. Confirm that no operation modifies any field of an existing unit except status, and that status transitions follow the permitted directions.

**I3: Grounding Termination.**
- **Statement:** Every atomic unit's grounding chain terminates at source material within a finite number of steps. No grounding chain contains a cycle.
- **Rationale:** Circular grounding is meaningless. Infinite grounding is untraversable. Both prevent auditability and invalidation.
- **Verification:** Select random units. Walk their grounding chains. Confirm termination at source positions.

**I4: Tier Monotonicity.**
- **Statement:** No atomic unit at tier N is derived from a unit at tier M where M > N.
- **Rationale:** A unit at a lower (more deterministic) tier that depends on a unit at a higher (more semantic) tier inherits the higher tier's uncertainty. It is not actually deterministic.
- **Verification:** For each unit, compare its tier to the tiers of all units in its provenance inputs. Confirm that no input has a higher tier.

**I5: Predicate Registry Append-Only.**
- **Statement:** Predicates are never removed from the registry. They may be deprecated but must remain interpretable.
- **Rationale:** Removing a predicate makes existing units with that predicate uninterpretable. The registry is the schema of the DIR; schema evolution must be non-destructive.
- **Verification:** Confirm that the predicate registry contains all predicates ever defined, with deprecated predicates marked but present.

**I6: Frontend Determinism.**
- **Statement:** A frontend produces identical output for identical input. The same source file at the same content hash produces the same set of atomic units (ignoring opaque identifiers and timestamps).
- **Rationale:** Non-deterministic frontends would produce different DIR content on each run, breaking incrementality and making the DIR unreproducible.
- **Verification:** Run a frontend twice on the same source file. Confirm that the produced units are structurally identical (same subjects, predicates, values, tiers).

**I7: Pass Grounding.**
- **Statement:** Every unit produced by an enrichment pass has a grounding chain that references the input units the pass consumed.
- **Rationale:** Ungrounded pass output is unauditable and uninvalidatable. If the input changes and the output has no grounding reference to the input, the system cannot detect that the output is stale.
- **Verification:** For each unit produced by a pass, confirm that its grounding chain includes at least one unit that the pass declared as input.

**I8: Index Derivability.**
- **Statement:** Every index can be rebuilt from the DIR without data loss.
- **Rationale:** Indexes that contain non-derivable data are shadow stores, violating I1 (DIR Completeness).
- **Verification:** Delete an index. Rebuild it from the DIR. Confirm that it is functionally identical to the original.

---

## Non-Goals

This chapter does not:

- **Define the tier model.** The specific tiers (structural, relational, behavioral, interpretive — or any other decomposition), their properties, and their freshness contracts are defined in DAS-003. This chapter requires only that tiers exist and are ordered.

- **Define the entity model.** What entities exist (functions, types, files, modules, systems), at what granularities, and with what predicates are defined in DAS-004. This chapter requires only that entities exist and serve as subjects of atomic units.

- **Define the relationship model.** What relationship types exist (calls, conforms-to, imports, owns) and their properties are defined in DAS-005. This chapter requires only that relationships are represented as atomic units with paired-entity subjects.

- **Define the pass architecture in detail.** Pass ordering, dependency resolution, incremental re-execution, and AI integration within passes are defined in DAS-006. This chapter defines only the pass contract (reads DIR, writes DIR, declares dependencies, produces grounded output).

- **Define the retrieval model.** The full query algebra, index selection strategy, and cross-scope query semantics are defined in DAS-007 (Index Architecture) and DAS-008 (Retrieval Architecture). This chapter defines only the minimum query semantics that the DIR must support.

- **Define the context assembly model.** Relevance filtering, budget management, and purpose-aware selection are defined in DAS-009 (Context Assembly). This chapter defines only the relationship: context assembly reads from the DIR, does not write to it.

- **Define the consumer architecture.** Output formats, consumer contracts, reasoning boundaries, and understanding contracts are defined in DAS-011 (Consumer Architecture). This chapter defines only the consumer contract: reads DIR via retrieval and context assembly, does not write to DIR.

- **Define the incremental update model.** Change detection, invalidation propagation, cascade boundaries, and recomputation strategies are defined in DAS-010. This chapter defines only the lifecycle model that update operates on.

- **Define the storage realization.** How the DIR is persisted, partitioned, and managed on disk is defined in DAS-012 (Storage Realization). This chapter is technology-independent.

- **Prescribe implementation technologies.** No specific parser, database, programming language, AI model, or data format is specified or implied.

---

## Open Questions

**Q1: Should the predicate registry be flat or hierarchical?** *(Non-blocking)*

A flat registry is simpler. A hierarchical registry (e.g., `structural.type.returnType`) enables prefix queries and taxonomic organization. The DIR contract does not depend on this choice. Deferred to DAS-003/DAS-004 when specific predicates are enumerated.

**Q2: What is the confidence scale?** *(Non-blocking)*

The contract requires an ordered scale with at least two values (deterministic and inferred). Whether the scale is binary, ordinal (deterministic > high > moderate > low), or continuous ([0.0, 1.0]) is deferred to DAS-003. The choice affects context assembly (higher-confidence units may be preferred) but not the DIR contract itself.

**Q3: Should the DIR carry a schema version?** *(Non-blocking)*

As the predicate registry evolves, older DIR content may use predicates that newer consumers don't expect, and newer DIR content may use predicates that older consumers don't recognize. A schema version on the DIR (or on individual units) would enable version-aware consumption. Deferred to DAS-010/DAS-012.

**Q4: How should the DIR handle source material that is not source code?** *(Non-blocking)*

Configuration files, documentation, build definitions, and infrastructure-as-code are part of a repository but may not have the same entity structure as source code. The DIR contract is general enough (arbitrary predicates, arbitrary value types) to accommodate these, but dedicated predicates and possibly dedicated frontends may be needed. Deferred to DAS-004.

**Q5: Should composition passes produce units with new subjects (scope-level entities) or units with existing subjects (additional properties on existing entities)?** *(Blocking for DAS-006)*

When a composition pass identifies that three files form a subsystem, it could: (a) create a new entity representing the subsystem and attach units to it, or (b) attach "belongs to subsystem X" units to the existing file entities. Option (a) creates new subjects; option (b) enriches existing subjects. The emergent properties requirement (DAS-001 P4) suggests (a), since the subsystem itself has properties not present in any constituent. Deferred to DAS-006.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (this chapter — DIR)
              ├── DAS-003 (Tier Model)
              ├── DAS-004 (Entity Model)
              │     └── DAS-005 (Relationship Model)
              ├── DAS-006 (Pass Architecture)
              ├── DAS-007 (Index Architecture)
              │     └── DAS-008 (Retrieval Architecture)
              │           └── DAS-009 (Context Assembly)
              │                 └── DAS-011 (Consumer Architecture)
              ├── DAS-010 (Incremental Update Model)
              └── DAS-012 (Storage Realization)
```

All L1–L5 chapters depend on this chapter. This chapter depends only on DAS-000 (authoring rules) and DAS-001 (principles).

---

## Revision History

```
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the Decode Intermediate
    Representation. Incorporates RFC-005 (atomic unit contract) and RFC-006 (DIR hypothesis).
    Supersedes the DAS-002 stub ("Decode Knowledge Model") which was never approved.
```
