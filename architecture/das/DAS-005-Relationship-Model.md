# DAS-005: Relationship Model

```
Chapter:       DAS-005
Title:         Relationship Model
Status:        Frozen
Version:       2.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-004
Depended By:   DAS-006, DAS-007, DAS-008
Supersedes:    DAS-005 (Relationship Model — stub, never approved)
Superseded By: —
Layer:         L1
```

## Abstract

This chapter defines the relationship model — the typed, directed connections between entities in the DIR. Relationships are first-class DIR content: each relationship is an atomic unit with a paired-entity subject, a relationship predicate, and all the standard atomic unit fields (tier, provenance, confidence, grounding, version, status). The chapter defines what a relationship is, establishes the canonical relationship taxonomy across six categories, specifies the structural rules governing relationships, and defines the invariants that make the DIR a well-formed semantic graph.

## Motivation

DAS-002 defines two kinds of atomic unit subjects: single-entity subjects (claims about one entity) and paired-entity subjects (claims about the connection between two entities). DAS-004 defines the eighteen entity types that serve as subjects. This chapter defines the *vocabulary of connections* — what kinds of typed edges exist between entities.

Without this chapter, three problems arise:

1. **The DIR is a collection of isolated facts.** A DIR that knows "function A exists" and "function B exists" but cannot express "A calls B" is structurally useless for understanding software. Understanding is primarily relational — a developer's question "what does this function do?" is almost always answered by what it *calls*, what *calls it*, what *type* it belongs to, and what *module* contains it. Single-entity predicates provide the nouns; relationships provide the verbs. Without verbs, the language cannot form sentences.

2. **Cross-layer connections are undefined.** DAS-004 defines seven ontology layers and notes that they are "causally connected" (DA-3). But how? If a Commit changes a Function, what relationship type expresses that connection? If a ConfigEntry parameterizes a Service, what is the edge? Without a relationship taxonomy, the cross-layer architecture promised by DAS-004 is aspirational, not operational.

3. **Impact analysis, composition, and retrieval are impossible.** DAS-001 P4 (composition produces emergence) requires traversing relationships to compose entities into scopes. DAS-001 P9 (incremental by design) requires invalidation propagation along relationship edges. DAS-007 (Retrieval) requires graph traversal queries. All of these depend on a well-defined, typed relationship model.

The relationship model is the third and final L1 chapter. Together with the DIR contract (DAS-002), the tier model (DAS-003), and the entity model (DAS-004), it completes the domain model of the DIR.

## Terminology

**Relationship** — A typed, directed connection between two entities in the DIR, represented as an atomic unit with a paired-entity subject. A relationship is a claim that a specific connection of a specific kind exists between a source entity and a target entity. *Is:* "function `authenticate` calls function `validateCredentials`" — a typed (calls), directed (authenticate → validateCredentials) connection. *Is not:* a similarity score, a co-occurrence statistic, or an undirected association. `INTRODUCED`

**Relationship Predicate** — A predicate (DAS-002) that applies to paired-entity subjects, classifying what kind of connection exists between the source and target entities. Relationship predicates are drawn from the same predicate registry as property predicates (DAS-002 I-PRED-1) but are distinguished by their subject arity: they apply to entity pairs, not single entities. `INTRODUCED`

**Relationship Category** — A grouping of related relationship predicates by the aspect of software reality they describe. Categories align with the ontology layers (DAS-004) and organize the relationship taxonomy for comprehension without constraining the DIR's structure. *Is:* Structural, Behavioral, Dependency, Operational, Evolutionary, Knowledge. *Is not:* an ontology layer (categories organize relationships; layers organize entity types). `INTRODUCED`

**Source Entity** — The first entity in a paired-entity subject. In a directed relationship, the source is the entity from which the connection originates. In `A calls B`, A is the source. `See DAS-002`

**Target Entity** — The second entity in a paired-entity subject. In a directed relationship, the target is the entity to which the connection points. In `A calls B`, B is the target. `See DAS-002`

**Observed Relationship** — A relationship that can be deterministically established by analyzing artifacts (source code, configuration, build files, VCS history, runtime instrumentation). Observed relationships are at T0 (DAS-003) with deterministic confidence. *Is:* `authenticate calls validateCredentials` (observable from the call site in source); `Service-A calls Endpoint /api/users` (observable from runtime trace). *Is not:* `authenticate is architecturally coupled to tokenGenerator` (requires interpretive inference). `INTRODUCED`

**Derived Relationship** — A relationship computed from T0 facts by deterministic algorithms that apply patterns, rules, or conventions. The computation is reproducible but the conclusion is not provably correct — the patterns may not reflect the actual nature of the software. Derived relationships are at T1 (DAS-003) with non-deterministic confidence (high, moderate, or low). *Is:* `testFoo tests foo` (derived from naming convention — deterministic algorithm, possibly wrong); `Module Auth dependsOn Module Crypto` (derived from aggregated import analysis — deterministic computation, but the dependency may be incidental). *Is not:* `authenticate calls validateCredentials` (provable from source, hence T0). `INTRODUCED`

**Inferred Relationship** — A relationship that requires interpretive analysis to establish. Inferred relationships are at T2 (DAS-003) with non-deterministic confidence. *Is:* `SessionManager is architecturally responsible for SessionResolver` (inferred from usage patterns). *Is not:* `SessionManager contains resolveSession` (deterministically observable). `INTRODUCED`

**Inverse Relationship** — The relationship obtained by reversing source and target. For every directed relationship `A → B`, the inverse `B ← A` exists conceptually but is not stored independently — it is derived by query. The inverse of `A calls B` is `B is-called-by A`. `INTRODUCED`

**Transitive Relationship** — A relationship where if `A → B` and `B → C`, then `A → C` is logically implied. Transitivity is a property of specific relationship predicates, not of relationships in general. `INTRODUCED`

## Domain Analysis

**DA-1: Software is a graph, not a tree.** A type conforms to multiple protocols. A function calls multiple other functions. A file imports multiple modules. A module depends on multiple other modules. While containment (DAS-004) forms a tree, the full structure of software is a directed graph with rich cross-cutting edges. Any representation that flattens software to a tree — a file tree, a class hierarchy, a module hierarchy — loses the cross-cutting connections that are essential for understanding. The relationship model must represent the full graph.

**DA-2: Relationships carry more comprehension value than properties.** Knowing that a function has return type `Bool` is useful. Knowing that the function calls an authentication service, conforms to a protocol, is tested by three test functions, and was last changed in a commit that also modified the token validator — that is understanding. Studies of developer comprehension consistently show that understanding software requires understanding connections: call graphs, dependency chains, conformance hierarchies, and data flows. A relationship-poor DIR is a comprehension-poor DIR.

**DA-3: Relationships have the same metadata requirements as properties.** A relationship "A calls B" has a tier (deterministic if extracted from source), a confidence (deterministic if the call site is explicit), a provenance (produced by the Swift parser), a grounding (the call site at line 47), and a version (derived from file version). These are exactly the fields of an atomic unit (DAS-002). Relationships are not second-class citizens that ride alongside "real" knowledge — they ARE knowledge. This is why DAS-002 represents relationships as atomic units with paired-entity subjects rather than as a separate data model.

**DA-4: Not all connections are equally observable.** "A calls B" is deterministic — a parser can identify every call site. "A is architecturally coupled to B" is interpretive — it requires analyzing usage patterns, co-change frequency, and structural similarity. "A tests B" is deterministic if test annotations or naming conventions are parsed, but may require inference in codebases without conventions. The relationship model must distinguish observable relationships (deterministic tier) from inferred relationships (semantic tier), consistent with DAS-001 P3 (deterministic before semantic).

**DA-5: Relationships span ontology layers.** A Commit (Evolution) changes a Function (Logical Software). A ConfigEntry (Operational) parameterizes a Service (Operational). A Decision (Human Knowledge) governs a Module (Logical Software). An Endpoint (External World) is implemented by a Function (Logical Software). Cross-layer relationships are not exceptions — they are the norm. The relationship model must support connections between entities in any pair of ontology layers.

**DA-6: Inverses are derivable; storing them is redundant.** If `A calls B` exists, then `B is-called-by A` is logically implied. Storing both doubles the DIR's size for zero information gain. The relationship model should define direction and let retrieval (DAS-007) handle inverse queries.

**DA-7: Some relationships are transitive; most are not.** `A contains B` and `B contains C` implies `A contains C` — containment is transitive. `A calls B` and `B calls C` does NOT imply `A calls C` — calls is not transitive (A may never reach C). Transitivity is a property of specific relationship predicates that the model must declare per predicate.

## Candidates

The architectural question is: **how should relationships be represented in the DIR?**

### Candidate A: Relationships as Separate Data Model

Relationships are represented in a dedicated relationship store, separate from the atomic unit model. Each relationship has its own fields (source, target, type, weight) but does not carry tier, provenance, confidence, grounding, or version.

**Strengths:** Simple schema. Relationships are structurally distinct from property units, making them easy to query separately.

**Weaknesses:** Relationships lose the metadata that makes them trustworthy. If a relationship has no provenance, it cannot be audited. If it has no tier, it cannot be distinguished from an inference. If it has no version, it cannot be invalidated when source changes. The relationship store becomes a shadow data model outside the DIR's governance.

**Disqualifying condition:** Violates DAS-002 I1 (DIR Completeness — all non-source state is DIR content or derived from it). A separate relationship store is a parallel data model, not DIR content.

### Candidate B: Relationships as Atomic Units with Paired-Entity Subjects

Relationships are atomic units. They use the same contract (id, subject, predicate, value, tier, provenance, confidence, grounding, version, status). The subject is a paired-entity subject (DAS-002 I-SUB-2). The predicate is a relationship predicate from the predicate registry. The value may carry relationship-specific metadata (e.g., call site location for a `calls` relationship).

**Strengths:** Unified model. Relationships inherit all DIR governance: tiering, provenance, confidence, grounding, versioning, lifecycle. No parallel data model. Relationships are queryable, versionable, and invalidatable by the same mechanisms as properties. The predicate registry (DAS-002 I-PRED-1) governs both property and relationship predicates.

**Weaknesses:** Relationship units are more complex than simple edge records. The value field must carry relationship-specific metadata (call site, import specifier, override resolution) that varies by predicate.

**Disqualifying condition:** None.

### Candidate C: Relationships as Implicit Derivations

Relationships are not stored at all. They are computed on demand by analyzing property units. "A calls B" is derived by finding a `hasCallTarget: B` property on A. No paired-entity units exist.

**Strengths:** No relationship storage. No relationship lifecycle management.

**Weaknesses:** Every relationship query requires re-derivation. Cross-entity queries ("what calls function X?") require scanning all entities — there is no direct edge from X to its callers. Inferred relationships (which require semantic analysis) would need to be re-inferred on every query. This violates DAS-001 P9 (incremental by design): the cost of answering relationship queries scales with DIR size, not with change size.

**Disqualifying condition:** Makes relationship queries computationally unbounded. Also violates DA-3: relationships need provenance, tier, and confidence — which they cannot carry if they are derived on the fly.

## Evaluation

| Criterion | Separate Model | Atomic Units | Implicit Derivation |
|-----------|---------------|-------------|-------------------|
| DIR completeness (DAS-002 I1) | No — parallel store | **Yes** | Partial — no persistent representation |
| Metadata (tier, provenance, confidence) | No | **Yes** | No |
| Incremental queries (DAS-001 P9) | Yes | **Yes** | No — re-derivation required |
| Unified governance | No — separate lifecycle | **Yes** | N/A |
| Query efficiency | Yes | **Yes** | No — scan required |

Atomic Units dominates on every criterion.

## Decision

**Relationships are atomic units with paired-entity subjects.** Every relationship in the DIR is an atomic unit conforming to the full DAS-002 contract. The predicate identifies the relationship type. The value carries relationship-specific metadata. Relationships are governed by the same lifecycle, versioning, and invalidation rules as property units.

This is not a design choice — it is the only representation consistent with DAS-002. The paired-entity subject exists in the atomic unit contract precisely to represent relationships. This chapter defines the *vocabulary* of relationship predicates and the *rules* governing their use.

---

## Relationship Structure

Every relationship in the DIR has the following structure, inherited from the atomic unit contract:

```
Relationship (an Atomic Unit) {
    id           : UniqueIdentifier           — unique, opaque
    subject      : EntityPair(source, target)  — ordered, directed
    predicate    : RelationshipPredicate       — from the taxonomy below
    value        : RelationshipMetadata        — predicate-specific metadata
    tier         : Tier                        — deterministic or semantic
    provenance   : ProvenanceRecord            — what produced this relationship
    confidence   : ConfidenceLevel             — how certain the claim is
    grounding    : GroundingChain              — evidence chain to source
    version      : VersionStamp                — source state at extraction
    status       : LifecycleStatus             — active, invalidated, superseded
}
```

**The value field.** For property units, the value is the claimed property (e.g., a return type string). For relationship units, the value carries relationship-specific metadata that varies by predicate:

- A `calls` relationship's value may include: call site location (file, line, column), whether the call is conditional or unconditional, whether it is direct or via dynamic dispatch.
- A `contains` relationship's value may include: the containment kind (syntactic declaration vs. compositional grouping).
- A `configures` relationship's value may include: the configuration mechanism (environment variable, file entry, flag).
- A `changed` relationship's value may include: the change type (created, modified, deleted).

The value field is typed per predicate (DAS-002 I-PRED-2). A predicate that requires no additional metadata uses an empty or unit value.

---

## Relationship Taxonomy

The relationship taxonomy defines every relationship predicate recognized by the DIR. Predicates are organized into six categories that correspond to the aspects of software reality the relationships describe.

For each relationship predicate:
- **Semantics:** What the relationship means.
- **Source → Target:** Which entity types may serve as source and target.
- **Cardinality:** How many targets a single source may have (and vice versa).
- **Direction:** What flows from source to target.
- **Tier Eligibility:** Which tiers (T0/T1/T2 per DAS-003) the relationship may occupy, and under what conditions.
- **Transitivity:** Whether the relationship is transitive.

---

### Category 1: Structural Relationships

Structural relationships describe the static organization and composition of software — how entities are arranged, grouped, and typed. These relationships are overwhelmingly deterministic: they are observable from source code, project structure, or package manifests.

---

**`contains`** — The source entity structurally contains the target entity. Containment defines the structural hierarchy (DAS-004 CONT-1 through CONT-4). This is the relationship that forms the containment tree for Logical Software entities.

| Property | Value |
|----------|-------|
| Semantics | Source is the structural parent of target |
| Source → Target | System → Package, Package → Module, Module → File, File → Type/Function/Property, Type → Type/Function/Property |
| Cardinality | Source: one-to-many. Target: exactly-one (tree constraint) |
| Direction | Parent → child |
| Tier Eligibility | T0 (from file system, manifests, source syntax) |
| Transitivity | Yes — if A contains B and B contains C, then A transitively contains C |

---

**`conformsTo`** — The source type declares conformance to the target type (protocol, interface, trait, abstract class contract).

| Property | Value |
|----------|-------|
| Semantics | Source satisfies the contract declared by target |
| Source → Target | Type → Type |
| Cardinality | Many-to-many (a type conforms to multiple protocols; a protocol has multiple conformers) |
| Direction | Conformer → protocol/interface |
| Tier Eligibility | T0 (from inheritance clauses, implements declarations) |
| Transitivity | Yes — if A conforms to B and B conforms to C, then A conforms to C |

*Note on ambiguity:* In Swift, the syntax `class A: B, C` uses the same syntax for inheritance (B is a class) and conformance (B is a protocol). Without type resolution, the parser cannot distinguish them. DAS-001 P3 requires deterministic extraction; when disambiguation is impossible, the producer records `conformsTo` as the default and flags the ambiguity. A type-resolution pass may later refine this to `inherits`.

---

**`inherits`** — The source type inherits implementation from the target type (class inheritance, struct embedding in Go).

| Property | Value |
|----------|-------|
| Semantics | Source extends target's implementation (not just its contract) |
| Source → Target | Type → Type |
| Cardinality | Source: one target (single inheritance in most languages; multiple in C++/Python). Target: many sources |
| Direction | Subclass → superclass |
| Tier Eligibility | T0 (from inheritance declarations) |
| Transitivity | Yes — if A inherits B and B inherits C, then A inherits C |

---

**`overrides`** — The source entity provides a specialized implementation of the target entity (method override, protocol default override, property override).

| Property | Value |
|----------|-------|
| Semantics | Source replaces target's implementation in the dispatch chain |
| Source → Target | Function → Function, Property → Property |
| Cardinality | Source: typically one target. Target: may have multiple overriders |
| Direction | Overriding → overridden |
| Tier Eligibility | T0 (from override annotations, virtual method tables) |
| Transitivity | No — A overrides B and B overrides C does not imply A overrides C directly |

---

**`imports`** — The source entity declares a dependency on the target entity's public interface, making the target's declarations available within the source's scope.

| Property | Value |
|----------|-------|
| Semantics | Source makes target's declarations accessible |
| Source → Target | File → Module/Package, Module → Module/Package |
| Cardinality | Many-to-many |
| Direction | Importer → imported |
| Tier Eligibility | T0 (from import statements, include directives, require/import declarations) |
| Transitivity | No — in languages where imports have transitive effects (e.g., C++ includes), the frontend emits explicit `imports` edges for each transitively included target. Transitivity is a producer concern, not a predicate property. |

---

### Category 2: Behavioral Relationships

Behavioral relationships describe how entities interact at execution time — what calls what, what reads or writes what, and how entities participate in execution flows. These relationships capture the dynamic verbs of software.

---

**`calls`** — The source entity invokes the target entity during execution. At the source-code level, this is a function calling a function. At the operational level, this includes a function or service invoking an endpoint, or a service calling another service through a defined interface.

| Property | Value |
|----------|-------|
| Semantics | Source invokes target — dispatches a request, call, or message that target handles |
| Source → Target | Function → Function, Function → Endpoint, Service → Endpoint, Service → Service |
| Cardinality | Many-to-many (a function calls many targets; a target is called by many sources) |
| Direction | Caller → callee |
| Tier Eligibility | T0 (from call sites in source, route invocations, runtime traces, API client analysis). Value metadata: call site location, conditional/unconditional, direct/dynamic dispatch, invocation mechanism (direct call, HTTP, gRPC, message) |
| Transitivity | No — A calls B and B calls C does not mean A calls C |

---

**`reads`** — The source function reads the value of the target property.

| Property | Value |
|----------|-------|
| Semantics | Source accesses target for its value without modifying it |
| Source → Target | Function → Property |
| Cardinality | Many-to-many |
| Direction | Reader → property |
| Tier Eligibility | T0 (from property access expressions in source) |
| Transitivity | No |

---

**`writes`** — The source function modifies the value of the target property.

| Property | Value |
|----------|-------|
| Semantics | Source assigns or mutates target's value |
| Source → Target | Function → Property |
| Cardinality | Many-to-many |
| Direction | Writer → property |
| Tier Eligibility | T0 (from assignment expressions in source) |
| Transitivity | No |

---

**`participatesIn`** — The source entity is a participant in the target flow. This is the relationship that connects Logical Software entities to Behavioral entities.

| Property | Value |
|----------|-------|
| Semantics | Source entity is involved in the execution path described by target flow |
| Source → Target | Function/Type/Endpoint/DataStore/Service → Flow |
| Cardinality | Many-to-many (a function participates in many flows; a flow has many participants) |
| Direction | Participant → flow |
| Tier Eligibility | T0 (from runtime traces — a distributed tracer observes actual execution paths), T1 (from deterministic call-graph traversal — algorithmic flow discovery that is reproducible but whose flow boundary identification is heuristic), T2 (from semantic flow inference — AI identifies coherent flows from structural and behavioral patterns). Value metadata: participant role (initiator, handler, terminator), ordering position |
| Transitivity | No |

---

**`triggers`** — The source entity causes the target entity to begin execution or become active. Distinct from `calls` in that the mechanism may be asynchronous, event-driven, or indirect.

| Property | Value |
|----------|-------|
| Semantics | Source causes target to execute through indirect or asynchronous mechanism |
| Source → Target | Function → Function, Endpoint → Function, ConfigEntry → Function |
| Cardinality | Many-to-many |
| Direction | Trigger → triggered |
| Tier Eligibility | T0 (from event subscription declarations in source), T1 (from deterministic pattern analysis of pub/sub or observer structures), T2 (from semantic inference of causal triggering) |
| Transitivity | No |

---

### Category 3: Dependency Relationships

Dependency relationships describe what entities require to function — what they depend on, what they consume, and what they reference. These relationships are the edges along which change impact propagates.

---

**`dependsOn`** — The source entity requires the target entity to function correctly. This is the general-purpose dependency edge. More specific relationships (`calls`, `imports`, `conformsTo`) imply `dependsOn` but carry richer semantics.

| Property | Value |
|----------|-------|
| Semantics | Source cannot function without target |
| Source → Target | Module → Module, Package → Package, Module → Dependency, System → Dependency, BuildTarget → Dependency |
| Cardinality | Many-to-many |
| Direction | Dependent → dependency |
| Tier Eligibility | T0 (from manifests, import graphs, build files), T1 (from aggregated usage-pattern analysis — deterministic computation of module-level dependencies from file-level imports), T2 (from semantic inference of implicit or architectural dependencies) |
| Transitivity | Yes — if A depends on B and B depends on C, then A transitively depends on C |

---

**`references`** — The source entity mentions or uses the target entity without establishing a structural, behavioral, or dependency connection strong enough for a more specific predicate. This is the catch-all connection for relationships that exist but don't fit a more specific category.

| Property | Value |
|----------|-------|
| Semantics | Source mentions or uses target in a way that is not captured by a more specific predicate |
| Source → Target | Any → Any (within type-compatibility constraints) |
| Cardinality | Many-to-many |
| Direction | Referencing → referenced |
| Tier Eligibility | T0 (from source analysis — explicit mentions), T1 (from deterministic cross-referencing of names and identifiers), T2 (from semantic content analysis of documentation or comments) |
| Transitivity | No |

*Usage note:* `references` is the relationship of last resort. If a more specific predicate applies (`calls`, `imports`, `conformsTo`, `reads`, `writes`), that predicate MUST be used instead. `references` captures connections like: a comment mentioning a type name, a configuration key referencing an endpoint path, or documentation citing a module.

---

### Category 4: Operational Relationships

Operational relationships describe how software is deployed, configured, and operated — the connections between logical structure and running infrastructure.

---

**`deploys`** — The source entity deploys or instantiates the target entity in an operational environment.

| Property | Value |
|----------|-------|
| Semantics | Source is the operational instantiation of target |
| Source → Target | Service → System/Module, Service → Artifact |
| Cardinality | Many-to-many (a service deploys a module; a module may be deployed by multiple services in different environments) |
| Direction | Service → what it deploys |
| Tier Eligibility | T0 (from deployment configuration, infrastructure-as-code), T1 (from deterministic analysis of deployment scripts or container definitions), T2 (from semantic inference of deployment relationships) |
| Transitivity | No |

---

**`configures`** — The source configuration entry controls or parameterizes the behavior of the target entity.

| Property | Value |
|----------|-------|
| Semantics | Source parameter modifies target's behavior at deployment time |
| Source → Target | ConfigEntry → Function/Type/Module/Service/DataStore |
| Cardinality | Many-to-many (a config entry may affect multiple entities; an entity may be configured by multiple entries) |
| Direction | Configuration → configured entity |
| Tier Eligibility | T0 (from explicit config key references in source), T1 (from deterministic name-matching between config keys and entity names), T2 (from semantic inference of configuration relationships). Value metadata: configuration mechanism (env var, file, flag) |
| Transitivity | No |

---

**`accesses`** — The source entity reads from or writes to the target data store.

| Property | Value |
|----------|-------|
| Semantics | Source performs I/O operations against target persistent store |
| Source → Target | Function/Service → DataStore |
| Cardinality | Many-to-many |
| Direction | Accessor → store |
| Tier Eligibility | T0 (from ORM usage, query construction in source, runtime traces), T1 (from deterministic analysis of data access patterns), T2 (from semantic inference of indirect data access). Value metadata: access type (read, write, read-write) |
| Transitivity | No |

---

**`exposes`** — The source entity makes the target entity available through an external interface.

| Property | Value |
|----------|-------|
| Semantics | Source publishes target as an externally callable surface |
| Source → Target | Service/Module → Endpoint |
| Cardinality | One-to-many (a service exposes many endpoints; an endpoint is exposed by one service) |
| Direction | Exposer → exposed |
| Tier Eligibility | T0 (from route definitions, API declarations, OpenAPI specs) |
| Transitivity | No |

---

**`implements`** — The source function or module provides the implementation behind the target endpoint.

| Property | Value |
|----------|-------|
| Semantics | Source is the code that executes when target is invoked |
| Source → Target | Function/Module → Endpoint |
| Cardinality | Many-to-one (an endpoint is implemented by one or few functions; a function may implement multiple endpoints) |
| Direction | Implementation → endpoint |
| Tier Eligibility | T0 (from route handler registration, controller annotations) |
| Transitivity | No |

---

### Category 5: Evolutionary Relationships

Evolutionary relationships connect the temporal dimension to all other layers — they record how entities change over time.

---

**`changed`** — The source commit created, modified, or deleted the target entity.

| Property | Value |
|----------|-------|
| Semantics | Source change record includes a modification to target |
| Source → Target | Commit → Any entity type |
| Cardinality | Many-to-many (a commit changes many entities; an entity is changed by many commits) |
| Direction | Commit → changed entity |
| Tier Eligibility | T0 (from VCS diff analysis). Value metadata: change type (created, modified, deleted), lines added/removed |
| Transitivity | No |

---

**`includes`** — The source release includes the target commit in its change set.

| Property | Value |
|----------|-------|
| Semantics | Target commit is part of source release's change set |
| Source → Target | Release → Commit |
| Cardinality | One-to-many (a release includes many commits; a commit belongs to one release in linear history, potentially multiple in branching models) |
| Direction | Release → commit |
| Tier Eligibility | T0 (from VCS tag/release analysis) |
| Transitivity | No |

---

**`produces`** — The source build or release produces the target artifact.

| Property | Value |
|----------|-------|
| Semantics | Source assembly process creates target deployable unit |
| Source → Target | BuildTarget → Artifact, Release → Artifact |
| Cardinality | One-to-many (a build target may produce multiple artifacts for different platforms) |
| Direction | Producer → produced |
| Tier Eligibility | T0 (from build system output, release pipeline) |
| Transitivity | No |

---

### Category 6: Knowledge Relationships

Knowledge relationships connect human intent and rationale to the entities they govern.

---

**`governs`** — The source decision constrains or explains the design of the target entity.

| Property | Value |
|----------|-------|
| Semantics | Source decision determined or constrained the structure, behavior, or existence of target |
| Source → Target | Decision → Any entity type |
| Cardinality | Many-to-many (a decision may govern many entities; an entity may be governed by many decisions) |
| Direction | Decision → governed entity |
| Tier Eligibility | T0 (from explicit governance declarations in ADRs linking to specific entities), T2 (from semantic inference of which entities a decision constrains, via design docs, commit messages, or code-pattern analysis). Value metadata: governance strength (determines, constrains, influences) |
| Transitivity | No |

---

**`supersedes`** — The source decision replaces the target decision. This records the evolution of architectural reasoning.

| Property | Value |
|----------|-------|
| Semantics | Source decision replaces target as the active governing choice |
| Source → Target | Decision → Decision |
| Cardinality | One-to-one (a decision supersedes at most one predecessor; a decision is superseded by at most one successor) |
| Direction | New decision → old decision |
| Tier Eligibility | T0 (from explicit supersession declarations in ADRs), T2 (from semantic inference of contradictory or replacing decisions) |
| Transitivity | Yes — if A supersedes B and B supersedes C, then A transitively supersedes C |

---

**`tests`** — The source function (with verification role) verifies the correctness of the target entity.

| Property | Value |
|----------|-------|
| Semantics | Source is a test that exercises and verifies target |
| Source → Target | Function → Function/Type/Module/Endpoint |
| Cardinality | Many-to-many (a test may verify multiple entities; an entity may be tested by multiple tests) |
| Direction | Test → tested entity |
| Tier Eligibility | T0 (from explicit test annotations such as `@Test`, test-target declarations), T1 (from deterministic naming-convention matching — e.g., `testFoo` tests `foo` — reproducible but possibly wrong), T2 (from semantic inference via coverage analysis or call-graph interpretation). Value metadata: test kind (unit, integration, end-to-end) |
| Transitivity | No |

---

**`documents`** — The source entity provides documentation or description for the target entity.

| Property | Value |
|----------|-------|
| Semantics | Source contains human-authored description of target |
| Source → Target | File → Function/Type/Module/System/Endpoint, Decision → Any |
| Cardinality | Many-to-many (a file may document multiple entities; an entity may be documented in multiple places) |
| Direction | Documentation source → documented entity |
| Tier Eligibility | T0 (from doc-comment association — syntactically adjacent documentation), T1 (from deterministic proximity rules — README in same directory documents the module), T2 (from semantic content analysis — AI determines what a document describes) |
| Transitivity | No |

---

## Summary of Relationship Predicates

| # | Predicate | Category | Source Types | Target Types | Tier Range | Transitive? |
|---|-----------|----------|-------------|-------------|-----------|------------|
| 1 | `contains` | Structural | System, Package, Module, File, Type | Package, Module, File, Type, Function, Property | T0 | Yes |
| 2 | `conformsTo` | Structural | Type | Type | T0 | Yes |
| 3 | `inherits` | Structural | Type | Type | T0 | Yes |
| 4 | `overrides` | Structural | Function, Property | Function, Property | T0 | No |
| 5 | `imports` | Structural | File, Module | Module, Package | T0 | No |
| 6 | `calls` | Behavioral | Function, Service | Function, Endpoint, Service | T0 | No |
| 7 | `reads` | Behavioral | Function | Property | T0 | No |
| 8 | `writes` | Behavioral | Function | Property | T0 | No |
| 9 | `participatesIn` | Behavioral | Function, Type, Endpoint, DataStore, Service | Flow | T0, T1, T2 | No |
| 10 | `triggers` | Behavioral | Function, Endpoint, ConfigEntry | Function | T0, T1, T2 | No |
| 11 | `dependsOn` | Dependency | Module, Package, System, BuildTarget | Module, Package, Dependency | T0, T1, T2 | Yes |
| 12 | `references` | Dependency | Any | Any | T0, T1, T2 | No |
| 13 | `deploys` | Operational | Service | System, Module, Artifact | T0, T1, T2 | No |
| 14 | `configures` | Operational | ConfigEntry | Function, Type, Module, Service, DataStore | T0, T1, T2 | No |
| 15 | `accesses` | Operational | Function, Service | DataStore | T0, T1, T2 | No |
| 16 | `exposes` | Operational | Service, Module | Endpoint | T0 | No |
| 17 | `implements` | Operational | Function, Module | Endpoint | T0 | No |
| 18 | `changed` | Evolutionary | Commit | Any | T0 | No |
| 19 | `includes` | Evolutionary | Release | Commit | T0 | No |
| 20 | `produces` | Evolutionary | BuildTarget, Release | Artifact | T0 | No |
| 21 | `governs` | Knowledge | Decision | Any | T0, T2 | No |
| 22 | `supersedes` | Knowledge | Decision | Decision | T0, T2 | Yes |
| 23 | `tests` | Knowledge | Function | Function, Type, Module, Endpoint | T0, T1, T2 | No |
| 24 | `documents` | Knowledge | File, Decision | Any | T0, T1, T2 | No |

**24 relationship predicates across 6 categories.** 13 are T0-only (fully deterministic). 11 span multiple tiers — their tier is determined per-instance by production method (DAS-003 TA-1). No predicate is T2-only; every relationship type has at least one deterministic or derived production path.

---

## Relationship Properties

### Directionality

Every relationship in the DIR is directed. The source and target are ordered (DAS-002 I-SUB-2). The direction is semantic: `A calls B` is fundamentally different from `B calls A`.

**R-DIR-1: Every relationship has exactly one direction.** There are no undirected relationships. If a connection is logically symmetric ("A is coupled to B"), it is represented as two directed relationships or as a single directed relationship with the convention that the more dependent entity is the source.

**R-DIR-2: Inverses are derived, not stored.** For every relationship `A → B`, the inverse `B ← A` is answerable by query reversal. The DIR does not store inverse relationship units. Storing `B is-called-by A` alongside `A calls B` doubles storage for zero information gain. Retrieval (DAS-007) must support inverse queries natively.

### Cardinality

Cardinality is declared per relationship predicate in the taxonomy above. Cardinality constrains the valid topology:

**R-CARD-1: Containment cardinality is enforced.** The `contains` predicate's target-side cardinality (exactly one container per entity) is a structural invariant (DAS-004 I2). Violation is an architectural defect.

**R-CARD-2: Other cardinalities are descriptive.** For predicates other than `contains`, cardinality describes the expected topology but is not structurally enforced. A `conformsTo` relationship that appears to violate single-inheritance expectations is not an error — it is a correct representation of the source code.

### Transitivity

Transitivity is declared per predicate. The following five predicates are transitive:

- `contains` — A contains B contains C implies A contains C.
- `conformsTo` — A conforms to B conforms to C implies A conforms to C.
- `inherits` — A inherits B inherits C implies A inherits C.
- `dependsOn` — A depends on B depends on C implies A depends on C.
- `supersedes` — A supersedes B supersedes C implies A supersedes C.

All other predicates, including `imports`, are non-transitive. Languages with transitive import effects (e.g., C++ `#include`) are handled by frontends emitting explicit `imports` edges for each transitively included target.

**R-TRANS-1: Transitive closure is derived, not stored.** If `A contains B` and `B contains C`, the DIR stores two units. The transitive fact `A contains C` is derivable by query traversal. Storing transitive closures is a DAS-007 (Index Architecture) or DAS-012 (Storage Realization) concern, not a relationship model concern.

### Tier Eligibility

Each relationship predicate declares a tier range — the set of tiers (T0, T1, T2 per DAS-003) at which instances of that predicate may exist. The tier of a specific relationship instance is determined by how it was produced (DAS-003 TA-1), not by the predicate alone.

- **T0 (Observed):** The relationship is provably correct from artifact analysis — source code, configuration, manifests, VCS history, runtime instrumentation. Confidence: deterministic.
- **T1 (Derived):** The relationship is computed from T0 facts by a deterministic algorithm that applies patterns, rules, or conventions. The computation is reproducible but the conclusion is not provably correct. Confidence: high, moderate, or low.
- **T2 (Inferred):** The relationship requires interpretive analysis to establish. Non-deterministic — different inference engines may produce different valid results. Confidence: high, moderate, or low.

**R-OBS-1: T0 relationships are produced by frontends, deterministic passes, and runtime observers.** A parser that identifies `A calls B` from a call site in source produces a T0 relationship. A distributed tracer that observes `Service-X calls Endpoint /api/users` produces a T0 relationship.

**R-OBS-2: T1 relationships are produced by rule-based passes.** A pass that derives `testFoo tests foo` from naming conventions produces a T1 relationship. A pass that computes `Module Auth dependsOn Module Crypto` by aggregating file-level imports produces a T1 relationship.

**R-OBS-3: T2 relationships are produced by semantic enrichment passes.** A pass that infers `SessionManager governs SessionResolver` from usage-pattern analysis produces a T2 relationship.

**R-OBS-4: Tier is per-instance, not per-predicate.** A `tests` relationship is T0 when derived from `@Test` annotations, T1 when derived from naming conventions, and T2 when inferred from coverage analysis. The predicate's declared tier range indicates the range of possibilities; the specific instance's tier and confidence record the actuality.

---

## Cross-Layer Relationships

DAS-004 DA-3 establishes that ontology layers are causally connected. The relationship taxonomy is designed to make every cross-layer connection expressible. The following table shows which relationship predicates connect which layers:

| Source Layer | Target Layer | Relationship Predicates |
|-------------|-------------|----------------------|
| Logical ↔ Logical | `contains`, `conformsTo`, `inherits`, `overrides`, `imports`, `calls`, `reads`, `writes` |
| Logical → Behavioral | `participatesIn` |
| Logical → External | `calls` (Function → Endpoint), `implements` (→ Endpoint), `dependsOn` (→ Dependency) |
| Operational → Logical | `deploys`, `configures` |
| Operational → Operational | `calls` (Service → Service) |
| Operational → External | `calls` (Service → Endpoint), `exposes` (→ Endpoint), `accesses` (→ DataStore) |
| Operational → Behavioral | `participatesIn` (Service → Flow) |
| Delivery → Logical | `contains` (BuildTarget → File/Module, expressed via `dependsOn`) |
| Delivery → Delivery | `produces` (BuildTarget → Artifact) |
| Evolution → Any | `changed` (Commit → any entity), `includes` (Release → Commit) |
| Evolution → Delivery | `produces` (Release → Artifact) |
| Knowledge → Any | `governs`, `documents`, `tests` |
| Knowledge → Knowledge | `supersedes` (Decision → Decision) |
| External → Logical | Inverse of `implements` and `calls` — derived by query reversal |
| Behavioral → Operational | `participatesIn` can include Endpoints, DataStores, and Services as flow participants |

**R-CROSS-1: No layer pair is disconnected.** For every pair of ontology layers, at least one relationship predicate connects entities across those layers (directly or through one intermediate layer). This ensures that the cross-layer architecture promised by DAS-004 is operational.

**R-CROSS-2: Cross-layer relationships follow the same atomic unit contract.** A relationship between a Commit (Evolution) and a Function (Logical Software) is an atomic unit with the same fields, governance, and lifecycle as a relationship between two Functions. The ontology layer boundary does not affect the relationship's structure.

---

## Relationship Composition

Relationships compose to produce emergent understanding — this is how the DIR goes from individual edges to architectural insight.

**Composition by traversal.** Following a chain of relationships produces derived understanding:
- `A calls B`, `B calls C`, `C calls D` → A's transitive call chain reaches D.
- `Module M contains File F`, `File F contains Type T`, `Type T conformsTo Protocol P` → Module M contains a type conforming to P.

**Composition by aggregation.** Collecting all relationships of a type produces structural insight:
- All `calls` edges into function F → F's caller set (who depends on F?).
- All `contains` edges from module M → M's constituent entities.
- All `changed` edges from commit C → C's change surface.

**Composition by pattern.** Recognizing structural patterns in the relationship graph produces emergent understanding (DAS-001 P4):
- A set of `calls` edges forming a cycle → a circular dependency.
- A set of `conformsTo` edges converging on a single protocol → a dependency inversion boundary.
- A cluster of `calls` edges between two modules with no edges to other modules → a tightly coupled pair.

Pattern detection is an enrichment pass concern (DAS-006). This chapter defines the graph structure that patterns operate on.

---

## Relationship Lifecycle

Relationships follow the atomic unit lifecycle (DAS-002):

**Created → Active → Invalidated → [Garbage Collected]**
**Created → Active → Superseded → [Garbage Collected]**

**RL-1: Relationships are invalidated when their source changes.** When the file containing a call site is edited, the `calls` relationship extracted from that call site is a candidate for invalidation. The updated file is re-parsed, and new relationships are extracted. Old relationships not confirmed by re-extraction are superseded.

**RL-2: Relationships are invalidated when either endpoint entity is invalidated.** If entity A is deleted (no longer exists after re-parsing), all relationships where A is source or target are invalidated. This is the relationship-level expression of DAS-002 I-SUB-1 (every subject references an entity that exists).

**RL-3: Relationship versioning follows source entity versioning.** A `calls` relationship between functions in file X carries the version of file X (DAS-002 I-VER-4). A `changed` relationship from a commit carries the commit's version.

**RL-4: Semantic relationships have independent freshness.** An inferred `participatesIn` relationship produced by an enrichment pass carries the version of the pass's input units, not the version of any specific file. When input units change, the inferred relationship is a candidate for re-evaluation by the pass.

---

## Relationship Metadata

The question "can relationships carry metadata?" is answered by the atomic unit contract: the value field is present on every unit, including relationship units. Relationship-specific metadata is carried in the value field.

**RM-1: Metadata is typed per predicate.** Each relationship predicate declares its value type (DAS-002 I-PRED-2). A `calls` predicate may declare a value type with fields: `callSiteFile`, `callSiteLine`, `isConditional`, `dispatchKind`. A `contains` predicate may declare a value type with field: `containmentKind`.

**RM-2: Metadata is immutable.** As with all atomic unit fields, the value is immutable once the unit is created (DAS-002 I-VAL-1). If metadata changes (e.g., a call site moves to a different line), the old relationship unit is superseded and a new one is created.

**RM-3: Not every relationship requires metadata.** Some predicates carry minimal or no metadata. A `conformsTo` relationship between Type A and Protocol B may need no value beyond the predicate itself — the connection is the entire claim. These predicates declare an empty or unit value type.

---

## Architectural Consequences

**C1: Twenty-four relationship predicates, governed by amendment.** The DIR recognizes exactly twenty-four relationship predicates across six categories. Adding a new predicate requires amending this chapter through DAS-000 Section 8. Like entity types (DAS-004 C1), this prevents predicate proliferation while allowing controlled evolution.

**C2: The relationship taxonomy is the graph schema.** Every edge in the DIR's semantic graph is typed by one of the twenty-four predicates. This makes the graph queryable, traversable, and analyzable with strong typing guarantees. A consumer asking "what does entity X call?" can be answered definitively because `calls` is a defined predicate with declared source and target types.

**C3: Inverses are query concerns, not storage concerns.** The DIR stores `A calls B` but not `B is-called-by A`. Retrieval (DAS-007) must support bidirectional traversal: "what does X call?" and "what calls X?" are both valid queries over the same stored relationship.

**C4: Transitive closures are derived, not stored.** The DIR stores direct edges. Transitive queries ("does A transitively depend on B?") are computed by traversal at query time or pre-computed by indexes (DAS-007). The relationship model defines which predicates are transitive; the retrieval model determines how transitive queries are executed.

**C5: `references` is the relationship of last resort.** When a more specific predicate applies, it MUST be used. `references` exists to prevent information loss when a connection is real but doesn't match a specific predicate. A DIR where most relationships are `references` is under-analyzed — producers should be extracting more specific predicates.

**C6: Relationships are the substrate for impact analysis.** When entity A changes, the impact set is computed by traversing relationships outward from A: what depends on A (`dependsOn`), what calls A (`calls` inverse), what tests A (`tests` inverse), what A configures (`configures`). The typed relationship graph makes impact analysis precise — different relationship types imply different impact severities.

**C7: Relationships enable composition.** DAS-001 P4 requires that composition produces emergence. Composition passes traverse relationships (`contains`, `calls`, `conformsTo`, `imports`) to identify interaction patterns, dependency structures, and architectural boundaries that become emergent properties on scope-level entities. Without typed relationships, composition passes have no structure to analyze.

**C8: Cross-layer relationships unify the ontology.** The relationship taxonomy ensures that no ontology layer is an island. Every layer connects to at least one other layer through defined relationship predicates. This makes the seven-layer ontology (DAS-004) a connected graph, not seven disconnected subgraphs.

---

## Invariants

**I1: Binary Relationships Only.**
- **Statement:** Every relationship in the DIR connects exactly two entities (DAS-002 I-SUB-3). No ternary or higher-arity relationships exist. Connections involving three or more entities are decomposed into multiple binary relationships.
- **Rationale:** Binary relationships produce a directed graph, which is computationally tractable. Hypergraph relationships require fundamentally different traversal, query, and storage mechanisms. Every software relationship analyzed — calls, conforms-to, inherits, imports, contains, tests, deploys, configures, changes — is naturally binary.
- **Verification:** Query all paired-entity units. Confirm each has exactly two entity references.

**I2: Typed Edges.**
- **Statement:** Every relationship in the DIR has a predicate drawn from the twenty-four defined relationship predicates. No untyped edges exist.
- **Rationale:** Untyped edges ("A is connected to B") carry no semantic information. They cannot be traversed purposefully, cannot inform impact analysis, and cannot be used for composition. Typing is what makes the graph a semantic graph rather than a co-occurrence graph.
- **Verification:** Query all paired-entity units. Confirm each predicate is one of the twenty-four defined predicates.

**I3: Source-Target Type Compatibility.**
- **Statement:** For every relationship, the source entity's type and the target entity's type are compatible with the predicate's declared source and target types. A `calls` relationship with a File as source is a structural error.
- **Rationale:** Type compatibility is the enforcement mechanism for the relationship taxonomy. Without it, the taxonomy is descriptive (guidance) rather than prescriptive (enforced).
- **Verification:** For each relationship unit, confirm the source entity's type is in the predicate's source type set and the target entity's type is in the predicate's target type set.

**I4: Containment Tree Consistency.**
- **Statement:** The `contains` relationships form a tree rooted at the System entity. Every Logical Software entity except the root has exactly one incoming `contains` edge. No cycles exist in `contains` edges.
- **Rationale:** This is the relationship-level enforcement of DAS-004 I2 (Structural Containment Tree). The tree structure guarantees unambiguous qualified names, deterministic scoped queries, and well-defined invalidation propagation.
- **Verification:** Enumerate all `contains` relationships. Confirm no Logical Software entity has more than one incoming `contains` edge. Confirm no cycles.

**I5: Specificity Over Generality.**
- **Statement:** When a more specific relationship predicate applies, it MUST be used instead of a less specific one. If `A calls B`, the relationship is `calls`, not `references`. If `A conforms to B`, the relationship is `conformsTo`, not `dependsOn`.
- **Rationale:** General predicates (`references`, `dependsOn`) lose semantic precision. Impact analysis, composition, and retrieval all depend on specific typing. A graph where every edge is `references` is useless for understanding.
- **Verification:** For each `references` or `dependsOn` relationship, confirm no more specific predicate applies to the same entity pair.

**I6: Relationship Grounding.**
- **Statement:** Every relationship unit has a grounding chain that terminates at source material (DAS-002 I-GND-1 through I-GND-4). A deterministic relationship is grounded at the source position where the connection is declared (call site, import statement, inheritance clause). A semantic relationship is grounded through the units it was inferred from.
- **Rationale:** Ungrounded relationships are unverifiable claims. "A calls B" without a grounding reference to the call site is unauditable and uninvalidatable.
- **Verification:** For each relationship unit, traverse the grounding chain. Confirm it terminates at source material.

**I7: Cross-Layer Completeness.**
- **Statement:** For every pair of ontology layers that have defined relationship predicates connecting them, the corresponding relationship predicates are in the predicate registry and are usable by producers.
- **Rationale:** DAS-004 promises cross-layer connections. If the relationship predicates connecting two layers are defined but cannot be produced, the cross-layer architecture is aspirational, not operational.
- **Verification:** For each cross-layer predicate, confirm at least one producer can emit relationships of that type (current or planned).

**I8: No Inverse Storage.**
- **Statement:** The DIR does not store inverse relationship units. If `A calls B` exists, `B is-called-by A` is not stored as a separate unit. Inverse access is a retrieval concern (DAS-007).
- **Rationale:** Inverse storage doubles relationship count for zero information gain. Consistency between forward and inverse is a maintenance burden that adds complexity without value.
- **Verification:** Confirm no predicate pair exists where one is the inverse of the other (e.g., no `calledBy` predicate alongside `calls`).

---

## Non-Goals

This chapter does not:

- **Define how relationships are traversed or queried.** Graph traversal algorithms, query syntax, and index structures are DAS-007 (Retrieval Model) concerns.

- **Define how relationships are stored.** Edge storage, adjacency structures, and partitioning strategies are DAS-012 (Storage Realization) concerns.

- **Define how relationship patterns are detected.** Identifying cycles, hubs, coupling clusters, and architectural patterns from the relationship graph is a DAS-006 (Pass Architecture) concern. This chapter defines the graph; passes analyze it.

- **Define relationship weights or scores.** Relationships are typed, not weighted. "A calls B with high frequency" is expressed by a runtime predicate on the relationship's value metadata or as a separate property unit, not as a weight on the edge. Scoring is a DAS-008 (Context Assembly) concern.

- **Define relationship visualization.** How the semantic graph is rendered for human consumption is an L5 concern.

- **Enumerate every valid source-target combination.** The taxonomy table lists primary source and target types. Edge cases (e.g., can a Property `reference` a Dependency?) are resolved by the general rule: if the connection is real and passes the type-compatibility invariant, it is valid.

---

## Open Questions

**Q1: Should `reads` and `writes` be merged into a single `accesses` predicate for properties?** *(Non-blocking)*

Separating reads from writes enables precise mutation analysis ("which functions modify this property?"). Merging them simplifies the taxonomy. Current decision: separate, because the mutation distinction is architecturally significant (thread safety, immutability analysis). Revisit if producers consistently have difficulty distinguishing reads from writes.

**Q2: How are dynamic dispatch relationships represented?** *(Non-blocking)*

When function A calls `protocol.method()`, the actual callee depends on the runtime type. The parser can identify the protocol method but not the concrete implementation. Options: (a) record `A calls Protocol.method` with dispatch metadata, (b) record `A calls` each known implementor with conditional metadata, (c) both. Current inclination: (a) for deterministic extraction, with an enrichment pass producing (b) when type information is available.

**Q3: Should `compiles` be a relationship between BuildTarget and File?** *(Non-blocking)*

The taxonomy uses `dependsOn` for BuildTarget → File/Module connections. A dedicated `compiles` predicate would be more specific (I5: specificity over generality). However, build systems express this as dependency rather than compilation. Deferred until build-system producers are implemented.

**Q4: How are implicit relationships represented?** *(Non-blocking)*

Some relationships are implicit in language semantics but not declared in source. Example: in Swift, all types in the same module can access each other's `internal` members — this is an implicit `imports` relationship not declared by any import statement. Current approach: implicit relationships are producer-specific; the producer decides whether to emit them as deterministic (language rule) or semantic (inferred) units.

**Q5: Should relationship predicates be hierarchical?** *(Non-blocking)*

A flat predicate list of 24 items works at current scale. If the predicate count grows significantly, a hierarchical organization (e.g., `behavioral.calls`, `behavioral.reads`) would enable prefix queries and taxonomic reasoning. Related to DAS-002 Q1 (flat vs. hierarchical predicate registry). Deferred to the same resolution.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              └── DAS-004 (Entity Model)
                    └── DAS-005 (this chapter — Relationship Model)
                          ├── DAS-006 (Pass Architecture)
                          └── DAS-007 (Retrieval Model)
```

This chapter depends on:
- DAS-000: chapter structure, P7 (composition over taxonomy)
- DAS-001: P4 (composition produces emergence), P5 (intelligence is grounded), P9 (incremental by design)
- DAS-002: paired-entity subjects (I-SUB-2, I-SUB-3), predicate registry (I-PRED-1, I-PRED-2), atomic unit contract, lifecycle model
- DAS-003: tier model (T0/T1/T2 classification, tier assignment rules TA-1 through TA-5, confidence bounds per tier)
- DAS-004: entity types (the eighteen types that relationships connect), ontology layers, containment rules

This chapter is depended on by:
- DAS-006: pass architecture (passes produce relationship units, traverse relationship graph)
- DAS-007: retrieval model (relationship traversal queries, inverse queries, transitive closure)

---

## Revision History

```
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the Relationship Model.
    Twenty-four relationship predicates across six categories. Relationships as
    atomic units with paired-entity subjects. Directionality, cardinality,
    transitivity, and observation status defined per predicate. Cross-layer
    relationship coverage verified. Eight invariants. Supersedes the DAS-005
    stub which defined section headings only.
2.0 — 2026-06-25 — Principal Architect — CTO-approved amendment package.
    (1) Replaced binary observation model (Deterministic/Semantic) with DAS-003
    three-tier model (Observed T0, Derived T1, Inferred T2). All 24 predicates
    updated with explicit tier eligibility ranges. Added "Derived Relationship"
    term. (2) Extended `calls` source/target types: Function→Function,
    Function→Endpoint, Service→Endpoint, Service→Service. (3) Extended
    `overrides` to support Property→Property. (4) Extended `participatesIn` to
    T0 (runtime-observed), T1 (deterministic flow discovery), T2 (semantic
    inference). Added Service as source type. (5) Made `imports` explicitly
    non-transitive; language-specific transitive effects are a producer concern.
    (6) Added DAS-003 as dependency. Updated cross-layer relationship table.
    Predicate count unchanged at 24.
```
