# DAS-006: Pass Architecture

```
Chapter:       DAS-006
Title:         Pass Architecture
Status:        Draft
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005
Depended By:   DAS-007, DAS-008, DAS-009, DAS-010
Supersedes:    DAS-006 (Pass Architecture — stub, never approved)
Superseded By: —
Layer:         L2
```

## Abstract

This chapter defines the pass architecture — the model by which the DIR grows from deterministic extraction toward progressively richer intelligence. A pass is a declared, isolated transformation that reads existing DIR content and produces new atomic units. Passes declare their inputs and outputs, are ordered by dependency, execute incrementally over changed content, and compose to build intelligence that no single pass could produce alone. This chapter defines what a pass is, why passes exist, how they relate to each other, how they execute, how they fail, and what invariants govern their behavior.

## Motivation

DAS-002 introduces two kinds of DIR producers: frontends (which read source material and emit deterministic atomic units) and enrichment passes (which read existing atomic units and produce new ones). The frontend contract is straightforward — a frontend is a language-specific parser with deterministic output. The pass contract is not.

Without this chapter, four problems arise:

1. **Passes are uncoordinated.** If pass B reads units produced by pass A, B must run after A. If both are added independently, who ensures ordering? Without a declared dependency model, pass ordering is either hardcoded (fragile — adding a pass requires editing a global list) or undeclared (broken — passes may read absent inputs).

2. **Incremental execution is undefined.** When a source file changes, frontends re-extract. But which passes must re-run? A pass that reads only entities in the changed file should re-run. A pass that reads cross-file relationships should re-run if the changed file's relationships changed. A composition pass over the containing module should re-run if the module's constituent intelligence changed. Without a defined model for pass inputs and their granularity, incremental re-execution is either conservative (re-run everything — violates DAS-001 P9) or optimistic (re-run nothing — produces stale intelligence).

3. **Semantic passes are ungoverned.** A pass that invokes AI to produce T2 units has fundamentally different properties from a pass that applies deterministic rules to produce T1 units: it is non-deterministic, expensive, latency-sensitive, externally dependent, and failure-prone. Without architectural governance, semantic passes will be treated identically to deterministic passes, producing brittleness when AI is unavailable and unpredictable costs when it is.

4. **Composition is unspecified.** DAS-001 P4 requires that composition produces emergence. DAS-002 Q5 asks whether composition passes create new scope-level entities or enrich existing ones. This chapter must answer that question and define how composition passes operate on the DIR's entity and relationship structure.

**Source dependencies:**
- [DAS-001 P2](DAS-001-Architectural-Principles.md) — layered intelligence with downward dependency
- [DAS-001 P3](DAS-001-Architectural-Principles.md) — deterministic before semantic
- [DAS-001 P4](DAS-001-Architectural-Principles.md) — composition produces emergence
- [DAS-001 P8](DAS-001-Architectural-Principles.md) — AI is a consumer of intelligence, not its source of truth
- [DAS-001 P9](DAS-001-Architectural-Principles.md) — incremental by design
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — atomic unit contract, enrichment pass definition, pass contract, lifecycle model
- [DAS-003](DAS-003-Tier-Model.md) — tier assignment rules, freshness contracts, confidence model
- [DAS-004](DAS-004-Entity-Model.md) — entity types (subjects of atomic units produced by passes)
- [DAS-005](DAS-005-Relationship-Model.md) — relationship predicates (edges produced and traversed by passes)

## Terminology

**Pass** — A declared, isolated transformation that reads existing DIR content and produces new atomic units. A pass is the unit of intelligence production in the DIR pipeline. Every pass declares what it reads (input contract), what it produces (output contract), and what tier its output occupies. Passes do not read source material directly — that is a frontend concern. Passes read the DIR and write to the DIR. *Is:* a relationship resolution pass that reads entity declarations and produces `calls` edges; a semantic enrichment pass that reads structural facts and produces behavioral characterizations. *Is not:* a frontend (frontends read source, not DIR); a query (queries read DIR but do not write); an index builder (indexes are derived views, not DIR content). `INTRODUCED`

**Pass Contract** — The declared specification of a pass's inputs, outputs, tier range, and execution constraints. The pass contract is what makes a pass composable: other passes and the scheduling system interact with the contract, not with the pass's internals. `See DAS-002`

**Pass Graph** — The directed acyclic graph formed by pass dependency declarations. Nodes are passes; edges are "depends on" relationships (pass B depends on pass A if B reads units that A produces). The pass graph determines execution order. *Is:* a compile-time structure derived from pass contracts. *Is not:* the DIR's entity-relationship graph (which is the data passes operate on). `INTRODUCED`

**Input Contract** — The portion of a pass contract that declares what DIR content the pass reads. An input contract specifies predicates, tiers, entity types, or relationship types that the pass consumes. The input contract determines when the pass must re-execute: if no input matching the contract has changed, the pass need not re-run. `INTRODUCED`

**Output Contract** — The portion of a pass contract that declares what DIR content the pass produces. An output contract specifies the predicates, tiers, and entity/relationship types that the pass emits. The output contract enables other passes to declare dependencies and enables the scheduling system to determine downstream effects. `INTRODUCED`

**Pass Scope** — The granularity at which a pass operates: per-entity, per-file, per-module, per-system, or global. The scope determines the unit of incremental re-execution — when inputs change, only pass invocations whose scope includes the changed inputs need to re-run. *Is:* "this pass operates per-file, so when file X changes, only the invocation for file X re-runs." *Is not:* entity scope or module scope in the DAS-004 sense — pass scope is an execution granularity, not an ontological classification. `INTRODUCED`

**Deterministic Pass** — A pass that produces output at T0 or T1 (DAS-003). Deterministic passes use algorithmic analysis — rules, pattern matching, graph traversal, metric computation — and require no AI. Their output is reproducible: same input, same output. `INTRODUCED`

**Semantic Pass** — A pass that produces output at T2 (DAS-003). Semantic passes use interpretive inference, typically involving AI. Their output is non-deterministic in general: different executions may produce different but equally valid results. `INTRODUCED`

**Composition Pass** — A pass that reads intelligence about entities at a smaller scope and produces intelligence about a larger-scope entity, generating emergent properties that do not exist at the smaller scope (DAS-001 P4). A composition pass may create new scope-level entities (Module, System) or enrich existing ones. `INTRODUCED`

**Invalidation Surface** — The set of DIR content that, when changed, requires a specific pass invocation to re-execute. Derived from the pass's input contract and scope. *Is:* "for this pass invocation over module M, the invalidation surface is all T0 relationship units between entities contained in M." *Is not:* the full set of units the pass might ever read — it is the set whose change triggers re-execution. `INTRODUCED`

## Domain Analysis

**DA-1: Intelligence production is a pipeline, not a monolith.** A system that extracts entities, resolves relationships, classifies roles, detects patterns, characterizes behavior, and interprets purpose in a single monolithic step is impossible to maintain, impossible to extend, and impossible to reason about. Each of these operations has different inputs, different outputs, different computation costs, different freshness requirements, and different failure modes. The natural decomposition is into discrete transformations — each one consuming the output of prior transformations and producing input for subsequent ones. This is not a software engineering preference; it is a reflection of the domain: intelligence about software is built in layers, and each layer depends on the layers below it (DAS-001 P2, DAS-003).

**DA-2: The dependencies between intelligence-producing operations are not arbitrary.** Role classification cannot run before entity extraction. Pattern detection cannot run before relationship resolution. Behavioral characterization cannot run before structural analysis. These ordering constraints are intrinsic to the domain — they follow from the tier model (DAS-003): T1 units derive from T0 units, and T2 units derive from T0 and T1 units. Any scheduling model must respect these constraints.

**DA-3: Different intelligence-producing operations have fundamentally different execution properties.** Parsing a file is fast, cheap, deterministic, and local. Classifying a file's role is fast, cheap, deterministic, and local. Characterizing a module's behavioral patterns is slow, expensive, non-deterministic, and requires AI. These are not quantitative differences on a single scale — they are qualitative differences that require different scheduling, different failure handling, and different freshness expectations. A scheduling model that treats all operations identically will either over-provision for simple operations or under-provision for complex ones.

**DA-4: Intelligence production must be incremental.** A codebase with 10,000 files cannot re-analyze all 10,000 files when one file changes (DAS-001 P9). But incrementality is not just about re-running the parser on one file. It cascades: the parser produces new T0 units; the relationship resolver must re-run on the affected entities; the role classifier must re-evaluate the affected file; the composition pass must re-evaluate the affected module. The incremental unit is not "the whole pipeline" — it is "each operation, scoped to the affected inputs." This requires that each operation declares its inputs at sufficient granularity to determine what is affected.

**DA-5: Some intelligence-producing operations create new entities; others enrich existing ones.** A frontend creates Function, Type, and File entities. A composition pass may need to create Module or System entities that do not yet exist. A pattern detection pass produces units about existing entities (e.g., "this entity participates in a pipeline pattern") — it does not create new entities. The architecture must distinguish passes that create entities from passes that only annotate existing ones, because entity creation has containment and identity implications (DAS-004).

**DA-6: Failure in one intelligence-producing operation must not prevent other operations from completing.** If the AI service is down, semantic enrichment fails. But structural extraction, relationship resolution, role classification, and pattern detection are all AI-independent and should proceed normally (DAS-001 P12). If a rule-based classifier encounters an unrecognized pattern, it should skip that entity — not abort the entire pipeline. Isolation between operations is not optional; it is required for graceful degradation.

**DA-7: The set of intelligence-producing operations is open-ended.** Today Decode has a handful of passes. In a year it may have dozens: git history analysis, documentation extraction, configuration analysis, runtime profile integration, security pattern detection, dependency vulnerability assessment. The architecture must support adding new operations without modifying existing ones or redesigning the scheduling model.

## Candidates

The architectural question is: **how should passes be organized and scheduled?**

### Candidate A: Fixed Pipeline (Explicitly Ordered)

Passes are listed in a fixed, explicit sequence. Each pass runs after the one before it completes. The sequence is defined by the system, not by the passes themselves.

**Strengths:** Maximum simplicity. No dependency resolution needed. Easy to reason about execution order. Easy to debug — just follow the list.

**Weaknesses:** Adding a pass requires editing the global sequence. Removing or replacing a pass requires editing the sequence. Two independent passes cannot run concurrently — they are forced into serial order. The sequence encodes implicit assumptions about dependencies that are never made explicit. If a pass's inputs change (it now reads something produced by a later pass), the sequence silently breaks.

**Disqualifying condition:** Violates DA-7 (open-ended pass set). Every new pass requires editing a global artifact. Also violates DAS-001 P11 (independent variability): passes cannot be added or removed independently.

### Candidate B: Dependency-Declared DAG

Each pass declares what it reads (input contract) and what it produces (output contract). The system constructs a directed acyclic graph from these declarations and topologically sorts it to determine execution order. Passes with no mutual dependency may run concurrently.

**Strengths:** Adding a pass requires only declaring its contract — no global artifact changes. Ordering is derived from declarations, not maintained manually. Independent passes are identified automatically. The dependency structure is explicit, inspectable, and verifiable. DAS-002 recommends this model.

**Weaknesses:** Requires each pass to accurately declare its inputs and outputs. A pass with an under-declared input (reads something it doesn't declare) will not be scheduled after the pass that produces it. Cycle detection is needed to reject invalid dependency structures.

**Disqualifying condition:** None identified.

### Candidate C: Event-Driven (Reactive)

Passes subscribe to events: "when a T0 unit with predicate `hasReturnType` is created, run pass X." There is no global ordering. Each pass reacts to the specific events it cares about.

**Strengths:** Maximum decoupling. Passes know nothing about each other. Execution is naturally incremental — each event triggers only the passes that care about it. Supports dynamic pass addition without any coordination.

**Weaknesses:** Execution order is emergent, not inspectable. If pass B reacts to units produced by pass A, the ordering is correct — but if A produces units that trigger B, which produces units that trigger C, which produces units that trigger A, the system has a cycle that is invisible in the event subscriptions. Debugging execution order requires tracing event chains, not inspecting a graph. Batch operations (re-process all files) require synthesizing events, which is awkward. The freshness contracts (DAS-003) require ordered tier processing (T0 before T1 before T2); event-driven systems make tier ordering implicit rather than explicit.

**Disqualifying condition:** Cycles are invisible. The tier ordering constraint (DAS-003 TL-1: T0 recomputed first, then T1, then T2) requires explicit ordering by tier, which event-driven systems cannot guarantee without effectively reimplementing a DAG scheduler.

### Candidate D: Hybrid (DAG + Reactive Incremental Trigger)

Passes declare dependencies (forming a DAG) and are topologically ordered for batch execution. Incremental re-execution uses change events to determine *which* passes need to re-run, but the re-execution order follows the DAG — not the event arrival order.

**Strengths:** Combines the inspectability and ordering guarantees of the DAG model with the precision of event-driven incremental triggers. The DAG governs ordering; events govern scoping. Adding a pass requires declaring its contract. Cycles are detected at declaration time. Tier ordering is explicit in the DAG structure. Incremental execution re-runs only affected passes in the correct order.

**Weaknesses:** Two coordination mechanisms instead of one. Slightly more complex than a pure DAG. The event mechanism must be consistent with the DAG — an event cannot trigger a pass before its DAG predecessors have processed the same change.

**Disqualifying condition:** None identified.

## Evaluation

The evaluation criteria are derived from the domain analysis and governing principles:

| Criterion | Fixed Pipeline (A) | DAG (B) | Event-Driven (C) | Hybrid DAG + Events (D) |
|-----------|-------------------|---------|-------------------|------------------------|
| Pass independence (DAS-001 P11) | No — global sequence | **Yes** — contract-declared | **Yes** — event subscriptions | **Yes** — contract-declared |
| Explicit ordering guarantees | Yes — but manual | **Yes** — derived from declarations | No — emergent | **Yes** — derived from declarations |
| Tier ordering (DAS-003 TL-1) | Manual | **Yes** — tier constraints in DAG | No — not guaranteed | **Yes** — tier constraints in DAG |
| Cycle detection | N/A (linear) | **Yes** — at declaration time | No — cycles invisible | **Yes** — at declaration time |
| Incremental precision | Coarse — re-run full pipeline | Moderate — re-run affected subgraph | **Fine** — re-run individual passes | **Fine** — events scope, DAG orders |
| Open-ended pass set (DA-7) | No — edit global list | **Yes** | **Yes** | **Yes** |
| Debuggability | High (but fragile) | **High** — inspect DAG | Low — trace event chains | **High** — inspect DAG + events |
| Concurrent execution | No | Yes — independent subgraphs | Yes — independent events | **Yes** — independent subgraphs |

Candidate A (Fixed Pipeline) is disqualified by pass independence and open-endedness requirements.

Candidate C (Event-Driven) is disqualified by invisible cycles and inability to guarantee tier ordering.

Candidate B (Pure DAG) satisfies all requirements but has coarser incremental precision — it re-runs the affected subgraph of the DAG but may re-run passes whose specific inputs within that subgraph did not actually change.

Candidate D (Hybrid) satisfies all requirements and adds fine-grained incremental precision: change events identify which specific pass invocations are affected, and the DAG determines the order in which they re-run.

The difference between B and D is incremental precision. At current scale (alpha, small codebases), B suffices. At target scale (large codebases, many passes), D is necessary. Choosing B now would require redesigning the scheduling model later; choosing D now incurs modest additional complexity that pays forward.

## Decision

**Passes are organized as a dependency-declared DAG with event-driven incremental triggers.** Each pass declares its input and output contracts. The system constructs a DAG from these declarations, detects cycles, and derives execution order by topological sort. When DIR content changes, change events identify which pass invocations are affected; re-execution follows DAG order over the affected subgraph. This is Candidate D — the hybrid model that combines the ordering guarantees of the DAG with the incremental precision of events.

---

## Pass Contract

Every pass in the system conforms to the following contract. This contract is the interface between a pass and the scheduling system. The scheduling system interacts only with the contract — it does not inspect pass internals.

### Contract Fields

```
Pass {
    id              : PassIdentifier
    inputContract   : InputContract
    outputContract  : OutputContract
    scope           : PassScope
    tierRange       : TierRange
    determinism     : Deterministic | Semantic
    idempotency     : Idempotent | NonIdempotent
}
```

### Pass Identity (`id`)

Every pass has a unique, stable identifier. The identifier is used in provenance records (DAS-002 I-PROV-2): every atomic unit records which pass produced it. Pass identity enables batch invalidation: when a pass is upgraded, all units produced by the old version can be identified and re-evaluated.

### Input Contract (`inputContract`)

The input contract declares what DIR content the pass reads. It specifies one or more of:

- **Predicates:** the specific predicates the pass reads (e.g., `hasReturnType`, `calls`, `hasRole`).
- **Tiers:** the tiers of units the pass reads (e.g., T0 only, T0 and T1).
- **Entity types:** the entity types whose units the pass reads (e.g., Function, Type, File).
- **Relationship types:** the relationship predicates the pass traverses (e.g., `contains`, `calls`, `conformsTo`).

**PC-IN-1: The input contract is complete.** A pass may read only DIR content matching its declared input contract. Reading undeclared content is a contract violation — the scheduling system cannot guarantee that the undeclared input was produced before the pass runs, and cannot trigger re-execution when the undeclared input changes.

**PC-IN-2: The input contract determines the invalidation surface.** When DIR content changes, the scheduling system compares the change against each pass's input contract. If the change matches the contract, the pass is a candidate for re-execution. If no change matches, the pass is unaffected.

### Output Contract (`outputContract`)

The output contract declares what DIR content the pass produces. It specifies:

- **Predicates:** the specific predicates the pass emits.
- **Tiers:** the tiers at which the pass produces units.
- **Entity types or relationship types:** what kinds of subjects the produced units have.

**PC-OUT-1: The output contract is complete.** A pass may produce only units matching its declared output contract. Producing undeclared output is a contract violation — downstream passes may not expect it, and the scheduling system may not propagate invalidation correctly.

**PC-OUT-2: The output contract enables downstream dependency.** Other passes declare input contracts that reference the predicates and tiers in this pass's output contract. This is the mechanism by which the pass DAG is constructed.

### Pass Scope (`scope`)

The scope declares the granularity at which the pass operates and re-executes:

- **Per-entity:** The pass operates on one entity at a time. When entity E's input units change, only the invocation for E re-runs.
- **Per-file:** The pass operates on one file's entities. When file F changes, only the invocation for F re-runs.
- **Per-module:** The pass operates on all entities within a module. When any entity in module M changes, the invocation for M re-runs.
- **Per-system:** The pass operates on all entities within a system. When any entity in the system changes, the invocation re-runs.

**PC-SCOPE-1: Scope determines incremental granularity.** A per-file pass re-runs only for changed files. A per-module pass re-runs for any change within the module. The scheduling system uses scope to determine the blast radius of a change.

**PC-SCOPE-2: Scope must be the narrowest granularity that produces correct output.** A pass that could operate per-file but declares per-system scope wastes re-execution effort on unchanged content. A pass that declares per-entity scope but reads cross-entity relationships produces incorrect output because its scope is narrower than its actual data dependency.

### Tier Range (`tierRange`)

The tier range declares the tiers at which the pass produces output. This must be consistent with DAS-003:

**PC-TIER-1: A pass's output tier must satisfy tier assignment rules.** If a pass produces T0 output, its production method must be provably correct (DAS-003 TA-1). If it produces T1 output, its method must be deterministic but fallible. If it produces T2 output, its method uses interpretive inference.

**PC-TIER-2: A pass's input tier must be at or below its output tier.** A pass producing T1 output may read T0 and T1 input. A pass producing T2 output may read T0, T1, and T2 input. No pass producing T0 output may read T1 or T2 input (DAS-002 I-TIER-5, DAS-003 I3).

### Determinism (`determinism`)

Declares whether the pass is deterministic or semantic:

- **Deterministic:** Same input produces same output (T0 or T1). Requires no external services. Output is reproducible and verifiable by re-execution.
- **Semantic:** Output may vary across executions (T2). Typically requires AI services. Output is non-reproducible in general.

**PC-DET-1: Determinism classification must be consistent with tier range.** A pass that declares `Deterministic` must produce only T0 or T1 output. A pass that declares `Semantic` produces T2 output (and may also produce T0 or T1 output when the pass can deterministically establish some claims while requiring inference for others).

### Idempotency (`idempotency`)

Declares whether running the pass twice on the same input produces the same DIR state:

- **Idempotent:** Re-running the pass on unchanged input produces the same units (same predicates, same values, same tiers). The second run supersedes the first run's units with identical successors, producing no net change.
- **NonIdempotent:** Re-running may produce different units (different values, different confidence). This applies to semantic passes where AI inference is non-deterministic.

**PC-IDEM-1: Deterministic passes must be idempotent.** A deterministic pass that produces different output on identical input is defective — it violates the definition of determinism (DAS-003 T0/T1 reproducibility).

**PC-IDEM-2: Semantic passes are presumed non-idempotent unless declared otherwise.** A semantic pass may declare idempotency if its inference is deterministic for a fixed model version, but this is unusual.

---

## Pass Dependencies

### Dependency Declaration

Passes declare dependencies through their input and output contracts. If pass B's input contract references predicates or tiers that appear in pass A's output contract, B depends on A.

**PD-1: Dependencies are declared, not discovered.** The scheduling system constructs the pass DAG from contract declarations. It does not inspect pass internals, observe runtime behavior, or infer dependencies from execution traces. Declaration makes dependencies explicit, inspectable, and verifiable.

**PD-2: Dependencies are predicate-level, not pass-level.** Pass B does not declare "I depend on pass A." It declares "I read units with predicate `hasRole` at tier T1." The scheduling system determines that pass A is the producer of those units and establishes the dependency. This indirection is essential: if pass A is replaced by pass A', the dependency is automatically resolved to A' — no downstream passes need to be updated.

**PD-3: Dependencies respect tier ordering.** A pass producing T1 output depends (transitively or directly) on passes producing T0 output. A pass producing T2 output depends on passes producing T0 and/or T1 output. The pass DAG is consistent with the tier hierarchy: T0-producing passes are roots or near-roots; T2-producing passes are leaves or near-leaves.

### The Pass DAG

The pass DAG is constructed as follows:

1. Collect all registered pass contracts.
2. For each pass, match its input contract against all other passes' output contracts.
3. Create an edge from producer to consumer for each match.
4. Verify acyclicity. If a cycle is detected, the conflicting passes have incompatible contracts — this is a registration-time error.
5. Topologically sort the DAG to produce a valid execution order.

**PD-4: The pass DAG is acyclic.** Cycles would mean pass A requires output from pass B, and pass B requires output from pass A. This is irresolvable. Cycles are detected at registration time and are a fatal configuration error.

**PD-5: The pass DAG has a deterministic topological order within each tier.** Multiple valid topological orders may exist. The system selects one deterministically (e.g., by pass identifier within each tier level) to ensure reproducible execution order.

**PD-6: Frontends are implicit roots.** Frontends are not passes — they are a separate pipeline stage (DAS-002). But passes that read T0 structural and relational units implicitly depend on frontends having run first. The scheduling system ensures frontends complete before any pass executes.

### Dependency Visualization

The pass DAG is inspectable. The system can produce a visualization of all passes, their dependency edges, their tier ranges, and their scopes. This visualization is an operational tool, not an architectural artifact — it changes whenever passes are added or removed.

---

## Pass Execution

### Execution Order

Passes execute in topological order of the pass DAG. Within a single topological level (passes with no mutual dependencies), execution may be concurrent.

**PE-1: Tier-level ordering is respected.** All T0-producing passes complete before any T1-producing pass begins. All T1-producing passes complete before any T2-producing pass begins. This is a consequence of DAG ordering combined with the tier dependency constraint (PC-TIER-2), but it is stated explicitly because it enforces DAS-003 TL-1 (recomputation priority).

**PE-2: Concurrent execution is permitted within a topological level.** Two passes at the same level with no mutual dependency may execute concurrently. The scheduling system is not required to exploit this concurrency — it is permitted, not mandated.

### Incremental Execution

When DIR content changes (due to a frontend re-extracting a file, or a pass producing new output), the scheduling system determines which downstream passes must re-execute.

**PE-3: Re-execution is scoped, not global.** When file F changes, the scheduling system:
1. Identifies which pass invocations have F (or entities in F) in their invalidation surface.
2. Re-executes those invocations in DAG order.
3. If a re-executed pass produces changed output, propagates the change to the next DAG level.
4. If a re-executed pass produces identical output (no net change), propagation stops.

**PE-4: Change propagation terminates.** Because the pass DAG is acyclic and finite, and because each pass operates on a finite set of inputs, change propagation always terminates. In the worst case, every pass in the DAG re-executes. In the common case, propagation stops early because most passes produce unchanged output for localized changes.

**PE-5: Deterministic passes enable early termination.** When a deterministic pass re-executes and produces output identical to its prior output (same predicates, same values), no downstream pass needs to re-execute for that input. This is because deterministic passes are idempotent (PC-IDEM-1): identical input produces identical output, so downstream passes would also produce identical output. Early termination is the primary mechanism by which incremental re-execution avoids full-pipeline cost.

**PE-6: Semantic passes do not enable early termination by default.** When a semantic pass re-executes, it may produce different output even if its input is unchanged (AI non-determinism). The scheduling system must propagate changes from semantic passes conservatively. However, if the semantic pass's output is structurally identical to its prior output (same predicates, same values — different only in non-semantic metadata), early termination applies.

### Batch Execution

Batch execution is the mode where all passes run over the full DIR — either on initial construction (first-time analysis of a codebase) or on recovery (DIR rebuild from source). In batch mode:

1. All frontends run, populating T0 content.
2. All passes execute in DAG order, from T0-producing to T2-producing.
3. No incremental scoping is applied — every pass runs over its full scope.

Batch execution is the recovery mechanism guaranteed by DAS-002 DC-5 (DIR is rebuildable from source). It is not the normal mode of operation.

---

## Pass Isolation

### Failure Isolation

**PI-1: A pass failure does not prevent other passes from executing.** If pass A fails (throws an error, times out, or produces invalid output), passes that do not depend on A proceed normally. Passes that depend on A are skipped for the current execution cycle — they retain their prior output (which may be stale but is better than absent, per DAS-001 P12).

**PI-2: A semantic pass failure does not affect deterministic passes.** Because deterministic passes (T0, T1) never depend on semantic passes (T2) — the tier dependency constraint (PC-TIER-2, DAS-003 CTD-1/CTD-2) guarantees this — AI outages affect only the T2 layer. The deterministic layer continues to operate normally.

**PI-3: Failure is recorded, not silent.** When a pass fails, the scheduling system records the failure (pass identity, scope, error category, timestamp). Pass output from the prior successful execution remains in the DIR as stale-but-available content. The failure record enables monitoring, alerting, and debugging without requiring the failure to propagate as broken state.

### State Isolation

**PI-4: Passes share no mutable state.** A pass reads the DIR (which is immutable — units do not change once created, per DAS-002 I-LC-5). A pass produces new units (which are appended to the DIR). No pass modifies units produced by another pass. No pass communicates with another pass except through the DIR. This eliminates race conditions, shared-state bugs, and implicit coupling between passes.

**PI-5: A pass's output is attributable.** Every unit produced by a pass carries the pass's identity in its provenance record (DAS-002 I-PROV-2). The system can enumerate all units produced by a specific pass, enabling targeted invalidation on pass upgrade, removal, or failure recovery.

---

## Deterministic Passes

Deterministic passes produce T0 or T1 output using algorithmic analysis. They are the workhorse of the DIR pipeline — they produce the intelligence that semantic passes build on.

### Properties

- **Reproducible:** Same input produces same output. Any conforming implementation would produce the same result.
- **AI-independent:** Require no external services. Execute locally.
- **Fast:** Computation cost is bounded by input size.
- **Idempotent:** Re-execution on unchanged input produces no net change.
- **Verifiable:** Output can be tested by assertion against expected output for known input.

### Categories of Deterministic Passes

**T0-producing passes** operate directly on frontend output to extract additional deterministic facts that require cross-entity analysis. A frontend parses one file at a time; a T0 pass may analyze relationships between entities across files (e.g., resolving that `A calls B` where B is defined in a different file from A). T0-producing passes are still provably correct — the claims they produce can be verified by inspection — but they require a broader view than a single-file frontend provides.

**T1-producing passes** apply rules, patterns, conventions, or metrics to T0 facts to produce derived classifications. A T1 pass that classifies file roles reads entity types, relationship counts, naming patterns, and import structures (all T0) and produces role classifications (T1). The computation is deterministic but the conclusion is not provably correct — the patterns may not reflect the actual nature of the software (DAS-003 T1 definition).

### Deterministic Pass Contract Constraints

**DP-1: A deterministic pass must not invoke AI services.** If it does, it is a semantic pass and must be classified as such. This constraint is architecturally load-bearing: it is what guarantees that the T0 and T1 layers function without AI (DAS-001 I7, DAS-003 Graceful Degradation Level 1).

**DP-2: A deterministic pass must be testable by input-output assertion.** Given a known input (a set of DIR units), the pass must produce a predictable output (a set of DIR units). This enables automated verification of pass correctness.

---

## Semantic Passes

Semantic passes produce T2 output using interpretive inference. They are the mechanism by which the DIR acquires behavioral characterization, design assessment, purpose explanation, and other intelligence that requires judgment beyond algorithmic analysis.

### Properties

- **Non-reproducible:** Different executions may produce different valid results.
- **AI-dependent:** Typically require an AI service.
- **Expensive:** Computation cost includes AI inference latency and cost.
- **Non-idempotent (typically):** Re-execution may produce different output even on identical input.
- **Failure-prone:** Subject to AI service outages, rate limits, timeouts, and model degradation.

### Semantic Pass Contract Constraints

**SP-1: A semantic pass must function within the DIR pipeline.** It reads DIR content (not raw source) as input, consistent with DAS-001 P8 (AI is a consumer of intelligence, not its source of truth). The AI within the pass receives structured intelligence — entity signatures, relationships, structural facts — not raw source code.

**SP-2: A semantic pass must produce grounded output.** Every T2 unit produced by a semantic pass must have a grounding chain that references the T0 and T1 units the pass consumed (DAS-002 I7, DAS-001 P5). The AI model's response is not self-grounding — the pass must construct the grounding chain from its input units.

**SP-3: A semantic pass must degrade gracefully on failure.** When the AI service is unavailable, the pass must: (a) not crash or block the pipeline, (b) leave prior T2 output in the DIR as stale-but-available content, and (c) record the failure for observability. The pass does not produce empty or placeholder output — it produces nothing, and the prior output serves (DAS-001 P12).

**SP-4: A semantic pass must declare its cost model.** Semantic passes consume external resources (AI tokens, API calls). The pass contract must declare the cost characteristics — per-entity, per-file, or per-scope — so the scheduling system can apply budget constraints and prioritization. The cost model is a declaration, not an enforcement mechanism — it informs scheduling decisions.

**SP-5: A semantic pass must tag its output with inference provenance.** The provenance record of a T2 unit must include the inference method (which model, which prompt structure) in addition to the producer identity. This enables batch re-evaluation when the inference method changes (e.g., model upgrade).

---

## Composition Passes

Composition passes implement DAS-001 P4 (composition produces emergence). They read intelligence about entities at one scope level and produce intelligence about entities at a higher scope level.

### Composition and Entity Creation

DAS-002 Q5 asks: should composition passes create new scope-level entities or enrich existing ones? This chapter resolves the question:

**CP-1: Composition passes create scope-level entities when those entities do not already exist.** When a composition pass identifies that a set of files forms a module, and no Module entity exists for that set, the pass creates the Module entity and attaches it to the containment hierarchy (DAS-004). The Module entity is the subject of the emergent properties the pass discovers.

**CP-2: Composition passes enrich scope-level entities when they already exist.** When a Module entity already exists (created by a prior composition pass or by a frontend analyzing a package manifest), the composition pass adds new units to the existing entity — emergent properties such as interaction patterns, coupling characteristics, and architectural role.

**CP-3: Entity creation by composition passes must respect the containment tree.** A Module entity created by a composition pass must be placed in the containment hierarchy (DAS-004 I2). It must have exactly one containing entity (a Package or System) and must contain the entities that constitute it. The pass must establish the `contains` relationships that integrate the new entity into the tree.

**CP-4: Composition passes must produce emergence.** A composition pass that merely aggregates constituent intelligence (counts entities, lists relationships, concatenates descriptions) violates DAS-001 P4. The pass must produce at least one property on the scope-level entity that does not exist on any constituent entity: an interaction pattern, a coupling metric, a boundary identification, an architectural role, or a design characterization.

### Composition Pass Scope

Composition passes have inherently broader scope than extraction or classification passes:

- A **file → module** composition pass has per-module scope: it reads intelligence about all entities in a module and produces module-level intelligence.
- A **module → system** composition pass has per-system scope: it reads intelligence about all modules and produces system-level intelligence.

Broader scope means coarser incremental granularity: any change within a module triggers the module composition pass. This is an inherent cost of composition — emergent properties depend on the full constituent set.

---

## Pass Invalidation

### When Passes Re-Execute

A pass invocation re-executes when its invalidation surface changes. The invalidation surface is determined by the pass's input contract and scope:

**PINV-1: Frontend output change triggers T0 passes.** When a frontend re-extracts a file, the new T0 units may differ from the old ones. T0-producing passes whose input contracts match the changed predicates or entity types are candidates for re-execution.

**PINV-2: T0 pass output change triggers T1 passes.** When a T0 pass produces changed output (new relationship edges, corrected entity properties), T1-producing passes whose input contracts match the changes are candidates for re-execution.

**PINV-3: T0 or T1 pass output change triggers T2 passes.** When T0 or T1 content changes, T2-producing passes whose input contracts match the changes are candidates for re-execution. However, T2 re-execution follows the eventual freshness contract (DAS-003): T2 passes are not required to re-execute immediately.

**PINV-4: Pass upgrade triggers re-execution.** When a pass is upgraded (new version with changed logic), all units produced by the old version are candidates for re-evaluation. The scheduling system identifies these units by provenance (DAS-002 I-PROV-2) and re-executes the pass over its full scope. This is equivalent to batch execution for the upgraded pass only.

**PINV-5: Pass removal triggers garbage collection.** When a pass is removed, all units produced by it are candidates for garbage collection (unless another pass now produces equivalent units). The scheduling system identifies orphaned units by provenance.

### Invalidation and Early Termination

When a pass re-executes and produces output identical to its prior output:

- The prior output units are superseded by identical successors.
- Downstream passes are not triggered — no change propagated.
- This is the early termination mechanism (PE-5) that bounds the cascade cost.

When a pass re-executes and produces different output:

- The prior output units are superseded by the new units.
- Downstream passes whose input contracts match the changed predicates are triggered.
- The cascade continues until it reaches passes with no downstream dependents or until output stabilizes.

---

## Pass Scheduling

### Scheduling Priorities

The scheduling system must balance multiple concerns when deciding what to execute and when:

**PS-1: Tier-level priority.** T0 passes have highest priority — their output is the foundation for everything else and stale T0 content is an architectural defect (DAS-003 Freshness: T0 is source-synchronous). T1 passes have second priority — their output should be current before consumers query. T2 passes have lowest priority — their freshness contract is eventual.

**PS-2: Change-proximity priority.** Within a tier level, passes whose inputs were most recently changed should execute first. This ensures that the most recently edited code has the most current intelligence.

**PS-3: Consumer-demand priority.** When a consumer requests DIR content that is stale (units are invalidated but not yet recomputed), the pass that would refresh that content may be prioritized. This is the mechanism by which lazy T2 enrichment is triggered: a consumer requests behavioral characterization, the content is absent or stale, and the semantic enrichment pass is scheduled.

**PS-4: Budget constraints.** Semantic passes have cost. The scheduling system respects budget constraints: per-pass invocation limits, per-time-window limits, and aggregate limits. Budget exhaustion does not cause failure — it causes deferral. The scheduling system defers low-priority semantic pass invocations until budget is available.

### Scheduling and Freshness Contracts

The scheduling system is the enforcement mechanism for DAS-003's freshness contracts:

- **T0 (source-synchronous):** T0 passes execute as part of the change-processing pipeline. When a file changes, T0 passes on the affected content execute before any consumer query is served.
- **T1 (source-synchronous with propagation delay):** T1 passes execute after T0 passes, as part of the same change-processing pipeline. A brief delay is tolerable (DAS-003: "T1 may lag T0 by the time needed to recompute").
- **T2 (eventual):** T2 passes execute when triggered by consumer demand or background scheduling. They are not part of the synchronous change-processing pipeline.

---

## Pass Observability

### What the System Must Know About Passes

**PO-1: Execution metrics.** For each pass invocation: input size (number of units read), output size (number of units produced), execution duration, success or failure, and change delta (how many units changed compared to prior invocation).

**PO-2: DAG health.** The current state of the pass DAG: number of registered passes, dependency structure, any passes in failed state, any passes with stale output.

**PO-3: Freshness state.** For each tier: how many units are active (fresh), how many are invalidated (stale), and what the oldest stale unit is. This enables monitoring of freshness contract compliance.

**PO-4: Cost accounting.** For semantic passes: cumulative cost (tokens consumed, API calls made) over configurable time windows. This enables budget monitoring and alerting.

---

## Cross-Pass Contracts

### What Passes May Assume About Each Other

Passes interact only through the DIR. A pass may assume:

**CPC-1: Declared inputs are present.** If a pass declares an input contract, and the scheduling system runs the pass, the declared inputs are present in the DIR (either as active or invalidated units). The scheduling system guarantees this by running producers before consumers.

**CPC-2: Declared inputs conform to the atomic unit contract.** Every unit in the DIR conforms to DAS-002. A pass does not need to validate that units have proper provenance, grounding, or tier classification — that is guaranteed by the DIR contract and enforced by the scheduling system.

**CPC-3: No other pass modifies my output.** A pass's output units are identified by their provenance (pass identity). No other pass produces units with the same provenance. If two passes produce units with the same subject and predicate, those units are competing claims resolved by the lifecycle model (DAS-002 I-PRED-3) — not by one pass overwriting the other.

### What Passes Must Not Assume

**CPC-4: Pass execution order is not observable.** A pass must not depend on running before or after a specific other pass by identity. It depends on its input contract being satisfied — which pass satisfies it is not the consumer's concern.

**CPC-5: Other passes' internals are not observable.** A pass must not inspect another pass's implementation, configuration, or state. It reads the DIR, not other passes. This is the information hiding that enables pass independence (DAS-001 P11).

---

## Architectural Consequences

**C1: Every intelligence-producing operation in Decode is a pass.** The only exceptions are frontends (which read source, not DIR) and index builders (which produce derived views, not DIR content). Every other transformation — classification, pattern detection, behavioral analysis, composition, semantic enrichment — is a pass conforming to the pass contract.

**C2: Adding a new pass requires only declaring its contract.** No global configuration changes, no existing pass modifications, no pipeline redesign. The new pass declares its input contract, output contract, scope, and tier range. The scheduling system integrates it into the DAG automatically.

**C3: The pass DAG is the system's intelligence production plan.** Inspecting the DAG reveals: what intelligence the system produces, in what order, with what dependencies, at what tiers. The DAG is a first-class operational artifact.

**C4: AI outages affect exactly the semantic tier.** Because deterministic passes never depend on semantic passes (tier ordering), and because semantic passes fail gracefully (SP-3), an AI outage removes the T2 layer while T0 and T1 continue to function. This is the pass-level expression of DAS-003's graceful degradation.

**C5: Incremental re-execution cost is proportional to change size, not codebase size.** Per-file and per-entity scopes ensure that a single file change triggers re-execution only in passes whose inputs include the changed content. Early termination (PE-5) stops propagation when output is unchanged. The common case — a small edit to one file — triggers minimal re-execution.

**C6: Composition passes answer DAS-002 Q5.** Composition passes create scope-level entities when they don't exist and enrich them when they do. The emergent properties produced by composition are new DIR content attached to the scope-level entity. This resolves the blocking open question from DAS-002.

**C7: Pass contracts are the enforcement mechanism for tier invariants.** The tier dependency constraint (no lower-tier unit derives from a higher-tier unit) is enforced by PC-TIER-2: a pass producing T0 output cannot declare T1 or T2 input. This makes the constraint structurally enforceable at DAG construction time rather than requiring runtime validation of every unit.

---

## Invariants

**I1: Pass DAG Acyclicity.**
- **Statement:** The pass dependency graph is a directed acyclic graph. No cycle exists in pass dependencies.
- **Rationale:** A cycle means pass A requires output from pass B, and pass B requires output from pass A (transitively). This is irresolvable — neither can run first. Cycles in the pass DAG prevent the system from constructing a valid execution order.
- **Verification:** At pass registration time, construct the DAG and run cycle detection. If a cycle is found, reject the registration.

**I2: Input Completeness.**
- **Statement:** Every pass reads only DIR content matching its declared input contract. No pass reads undeclared content.
- **Rationale:** Undeclared reads break the dependency model. The scheduling system cannot order passes whose true dependencies are invisible. Undeclared reads also break incremental re-execution: the scheduling system cannot trigger re-execution for changes it doesn't know the pass cares about.
- **Verification:** Audit pass implementations against their declared input contracts. A pass that queries DIR content outside its contract is defective.

**I3: Output Completeness.**
- **Statement:** Every pass produces only atomic units matching its declared output contract. No pass produces undeclared content.
- **Rationale:** Undeclared output is invisible to the dependency model. Downstream passes cannot declare dependencies on output that is not in any pass's output contract. The scheduling system cannot propagate changes from undeclared output.
- **Verification:** Audit pass implementations against their declared output contracts. A pass that emits units outside its contract is defective.

**I4: Tier Consistency.**
- **Statement:** Every pass produces output at tiers within its declared tier range, and no pass reads input at a tier higher than its output tier.
- **Rationale:** This is the pass-level enforcement of DAS-003 I3 (derivation monotonicity). A T0-producing pass that reads T2 input produces a T0 unit derived from T2 content — which is not actually deterministic.
- **Verification:** At DAG construction time, verify that no pass's input contract references tiers higher than its output tier range.

**I5: Grounded Output.**
- **Statement:** Every atomic unit produced by a pass has a grounding chain that references the input units the pass consumed (DAS-002 I7).
- **Rationale:** Ungrounded pass output is unauditable — when the output is wrong, there is no way to trace the error to its source. Ungrounded output is also uninvalidatable — when input changes, the system cannot determine which output depends on the changed input.
- **Verification:** For each unit produced by a pass, confirm its grounding chain includes at least one unit from the pass's input set.

**I6: Failure Isolation.**
- **Statement:** The failure of any single pass does not prevent the execution of passes that do not depend on it.
- **Rationale:** The pass pipeline must degrade gracefully (DAS-001 P12). A failure in a T2 semantic pass must not block T0 or T1 passes. A failure in one T1 classification pass must not block other independent T1 passes.
- **Verification:** Simulate failure of each pass individually. Confirm that all non-dependent passes execute normally.

**I7: Provenance Attribution.**
- **Statement:** Every atomic unit in the DIR produced by a pass carries the producing pass's identity in its provenance record.
- **Rationale:** Without provenance attribution, batch invalidation on pass upgrade is impossible (which units did the old pass produce?), cost accounting is impossible (which pass consumed how many resources?), and failure diagnosis is impossible (which pass produced the incorrect unit?).
- **Verification:** For each unit in the DIR, confirm that its provenance.producer identifies either a frontend or a registered pass.

**I8: Deterministic Pass AI Independence.**
- **Statement:** No deterministic pass (producing T0 or T1 output) invokes AI services or depends on AI availability.
- **Rationale:** This is the pass-level enforcement of DAS-001 I7 (AI independence of deterministic layers) and the mechanism for DAS-003 Graceful Degradation Level 1 (T0+T1 without AI). If a deterministic pass secretly calls AI, the system's degradation guarantees are violated.
- **Verification:** Audit deterministic pass implementations. Confirm no AI service calls, no network requests to inference endpoints, and no dependencies on AI availability.

---

## Non-Goals

This chapter does not:

- **Define specific passes.** Which passes exist, what each one does, and what predicates each one produces are implementation decisions. This chapter defines the contract that all passes must satisfy and the scheduling model that governs their execution.

- **Define how passes are implemented.** The internal logic of a pass — what algorithms it uses, what data structures it constructs, how it formats AI prompts — is not governed by this chapter. Only the pass contract (input, output, scope, tier, determinism, idempotency) is architecturally prescribed.

- **Define the retrieval model.** How consumers query the DIR — what query language, what indexes, what optimization — is a DAS-007 concern. Passes write to the DIR; retrieval reads from it. The boundary between them is the DIR itself.

- **Define the incremental update model in full.** Change detection, invalidation propagation algorithms, cascade boundaries, and recomputation scheduling policies are DAS-010 concerns. This chapter defines the pass-level contracts that DAS-010 operates on (input contracts, scopes, invalidation surfaces).

- **Define storage realization.** How pass state, execution history, and the pass DAG are persisted is a DAS-012 concern.

- **Prescribe implementation technologies.** No scheduler, message broker, task queue, AI provider, or programming language is specified. The pass architecture is technology-independent.

---

## Open Questions

**Q1: Should passes declare estimated cost?** *(Non-blocking)*

The pass contract includes a cost model for semantic passes (SP-4). But should deterministic passes also declare estimated cost (in terms of computation time or input size)? At alpha scale, this is unnecessary — all deterministic passes are fast. At scale, cost estimates would enable smarter scheduling (e.g., deferring an expensive deterministic pass during interactive editing). Deferred until scale demands it.

**Investigation approach:** Monitor deterministic pass execution times. If any consistently exceed interactive latency thresholds (>100ms per invocation), consider adding cost declarations.

**Q2: Should the pass DAG support conditional edges?** *(Non-blocking)*

The current model has unconditional edges: if B depends on A, B always runs after A (when triggered). A conditional edge would mean: B runs after A only if A's output meets a condition (e.g., "run the security analysis pass only if the changed file contains network-related entities"). Conditional edges would reduce unnecessary re-execution but add complexity to the scheduling model.

**Investigation approach:** Implement the unconditional DAG first. If profiling reveals significant wasted re-execution from passes that frequently produce empty output, consider conditional edges as an optimization.

**Q3: How should passes handle conflicting output?** *(Non-blocking)*

If two passes produce units with the same subject and predicate at different tiers (e.g., a T1 rule-based purpose classification and a T2 AI-derived purpose), DAS-002 I-PRED-3 says these are competing claims resolved by the lifecycle model. But the resolution policy (which claim wins? both coexist? consumer chooses?) is not fully defined. Deferred to DAS-007 (retrieval) and DAS-008 (context assembly), which define how consumers select among competing claims.

**Investigation approach:** Define the resolution policy when consumer use cases are better understood. The DIR stores both claims; the consumer's query parameters (minimum tier, minimum confidence) determine which is returned.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              ├── DAS-004 (Entity Model)
              │     └── DAS-005 (Relationship Model)
              └── DAS-006 (this chapter — Pass Architecture)
                    ├── DAS-007 (Retrieval Model)
                    └── DAS-010 (Incremental Update Model)
```

This chapter depends on:
- DAS-000: chapter structure, review checklist
- DAS-001: P2 (layered intelligence), P3 (deterministic before semantic), P4 (composition produces emergence), P8 (AI as consumer), P9 (incremental by design), P11 (boundaries define independent variability), P12 (graceful degradation), I7 (AI independence of deterministic layers)
- DAS-002: atomic unit contract, enrichment pass definition, pass contract sketch, lifecycle model (I-LC-1 through I-LC-5), provenance (I-PROV-1, I-PROV-2), grounding (I-GND-1 through I-GND-4), tier invariants (I-TIER-1 through I-TIER-5), Q5 (composition entity creation — resolved by CP-1/CP-2)
- DAS-003: tier definitions (T0, T1, T2), tier assignment rules (TA-1 through TA-5), freshness contracts (source-synchronous, propagation delay, eventual), confidence model, cross-tier dependencies (CTD-1 through CTD-3), recomputation priority (TL-1), graceful degradation levels
- DAS-004: entity types (subjects of units produced by passes), containment tree (CP-3), scope-level entities (Module, System) created by composition passes
- DAS-005: relationship predicates (edges produced and traversed by passes), relationship categories, cross-layer relationships

This chapter is depended on by:
- DAS-007 (Retrieval Model): retrieval queries read the DIR content that passes produce; retrieval depends on understanding what passes produce and at what tiers
- DAS-010 (Incremental Update Model): incremental update operates on the pass contracts, scopes, and invalidation surfaces defined here; the invalidation cascade algorithm uses the pass DAG to determine re-execution order

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub with section headings and open questions
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the pass architecture.
    Hybrid DAG + event-driven model selected over fixed pipeline, pure DAG, and pure
    event-driven alternatives. Pass contract defined (input, output, scope, tier range,
    determinism, idempotency). Deterministic, semantic, and composition passes distinguished.
    Resolves DAS-002 Q5: composition passes create scope-level entities and produce
    emergent properties. Eight invariants. Three open questions. Supersedes the DAS-006
    stub which defined section headings only.
```
