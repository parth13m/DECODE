# DDS-006: Context Assembly Runtime

```
Document:      DDS-006
Title:         Context Assembly Runtime
Status:        Draft
Version:       0.2
Author:        Principal Engineer
Created:       2026-06-28
Last Revised:  2026-06-28
Reviewers:     —
Depends On:    DDS-000 (Design Authoring Standard), DDS-005 (Retrieval Runtime)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-008, DAS-009
```

## Abstract

This document specifies the engineering design of the Context Assembly Runtime — the subsystem that transforms an evidence set (from DDS-005) into a purpose-calibrated, budget-constrained, coherent context frame consumable by a downstream consumer. It defines the context strategy contract, strategy validation and lifecycle, the assembly execution model, stratum-ordered evidence selection, coherence enforcement, budget management, the context frame contract, determinism guarantees, failure handling, and observability. The Context Assembly Runtime realizes the context assembly architecture from DAS-009. It is a stateless, pure-function subsystem: it never reads the DIR, never queries indexes, never modifies canonical data. Its sole input is an evidence set; its sole output is a context frame.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P7 (relevance over completeness — stratum-ordered selection
            with budget constraint selects relevant evidence, not all
            evidence), P12 (graceful degradation — absent tiers produce
            sparser frames, not failures; budget pressure produces
            smaller frames, not errors)
  Not addressed: P1, P5, P6 (DDS-002, DDS-001 — intelligence production
                and grounding), P2, P3, P4 (DDS-001, DDS-003 — execution
                ordering), P8 (DDS for Consumer Runtime — AI consumes
                context), P9 (DDS-001, DDS-004 — incremental maintenance),
                P10 (DDS for Consumer Runtime — scope parameterization),
                P11 (DDS-001 — producer independence)

DAS-002: Decode Intermediate Representation
  Realized: Consumer contract (consumers read DIR content via retrieval
            and context assembly; context assembly is the final selection
            step before consumption). Grounding preservation (I-GND-1
            through I-GND-4 — grounding chains passed through unmodified).
  Not addressed: Atomic unit contract fields (DDS-002:R2), lifecycle
                model (DDS-002:R4), identity (DDS-002:R5), immutability
                (DDS-002:R3), DC-1 through DC-5 (DDS-002, structural),
                I1 through I8 (DDS-002, DDS-001, DDS-004)

DAS-003: Tier Model
  Realized: I7 (degradation validity — context frames at any degradation
            level are valid, coherent, and consumable). Tier balancing
            within context frames per strategy tier preference. Confidence
            surfacing (CB-1: confidence surfaced, not filtered, by
            default). Freshness propagation (CFR-1: context freshness
            inherits from evidence freshness).
  Not addressed: I1 through I6 (DDS-002, DDS-001), tier assignment
                (DDS-002:R8, DDS-003), TL-1, TL-2, TL-3 (DDS-002,
                DDS for Storage Engine), freshness contracts enforcement
                (DDS-004, DDS for Update Engine)

DAS-008: Retrieval Architecture
  Realized: RC-5 (retrieval does not guarantee relevance — context
            assembly provides relevance through purpose-specific
            selection). Evidence set consumption (the evidence set is
            the contract between retrieval and context assembly, per
            DAS-008 C6). Evidence provenance consumption (selection
            criteria reference evidence provenance vocabulary).
  Not addressed: Five-stage retrieval pipeline (DDS-005), retrieval
                request construction (coordinating subsystem), index
                interaction (DDS-005, DDS-004), anchor resolution
                (DDS-005:R2), retrieval budget (DDS-005:R4)

DAS-009: Context Assembly
  Realized: Purpose-stratified context assembly architecture (decision).
            Context strategy contract (ContextStrategy, StratumDefinition).
            Context frame structure (ContextFrame, FilledStratum,
            ContextUnit). Evidence selection model (ES-1 through ES-4).
            Budget management (BM-1 through BM-3, EP-1 through EP-3).
            Tier/confidence balancing (TB-1 through TB-3, CB-1 through
            CB-3). Grounding preservation (GP-1 through GP-3). Context
            coherence (CC-1 through CC-3, CE-1 through CE-3). Context
            freshness (CFR-1 through CFR-3). Context lifecycle (CL-1
            through CL-3). All eight invariants (I1 through I8). All
            failure modes (FM-1 through FM-6). All architectural
            consequences (C1 through C8). All observability requirements
            (OB-1 through OB-5).
  Not addressed: Specific strategy definitions (illustrative in DAS-009,
                not prescribed — strategies are registered at runtime).
                Consumer architecture (DAS-011, DDS for Consumer Runtime).
                Retrieval request construction (coordinating subsystem).
```

## Terminology

**Context Strategy** — A validated, versioned engineering contract that governs how context assembly transforms an evidence set into a context frame for a specific consumer purpose. A strategy defines stratum definitions, coherence constraints, tier preference, and elision policy. Strategies are first-class engineering contracts: they are validated at registration, versioned for reproducibility, and immutable once registered. `See DAS-009`

**Context Frame** — The output of context assembly: a bounded, structured, purpose-calibrated representation of evidence ready for consumption. The context frame is a runtime contract between context assembly and consumers. It carries invariants (budget compliance, stratum partitioning, coherence, determinism, grounding integrity) that consumers may rely upon. Context frames are ephemeral — never persisted, never cached, never reused. `See DAS-009`

**Context Stratum** — A priority-ordered group of evidence within a context frame. Each stratum contains evidence serving a specific role in the context (e.g., anchor core properties, behavioral evidence, scope context). Strata are defined by the context strategy and filled in priority order during assembly. `See DAS-009`

**Context Unit** — An atomic unit within a context frame, augmented with a context role explaining why it was selected. A context unit inherits all fields from its source annotated unit (DDS-005) without modification: the atomic unit record, distance from anchor, tier, confidence, and grounding chain. `See DAS-009`

**Context Role** — An annotation on each context unit explaining why the unit was selected for the context frame and what function it serves. Context role is distinct from evidence provenance (why the unit was gathered during retrieval) and unit provenance (how the unit was produced). `See DAS-009`

**Context Budget** — The hard capacity constraint bounding a context frame. Denominated in tokens (for AI consumers) or unit count (for automated consumers). The budget is specified by the caller and enforced as a ceiling — context assembly never exceeds it. `See DAS-009`

**Coherence Constraint** — A rule within a context strategy requiring that certain units co-occur in the context frame. If a triggering unit is included, its required co-occurring unit must also be included. If both cannot fit within budget, neither is included (constraint retraction). `See DAS-009`

**Evidence Elision** — The deliberate, directed omission of evidence from the context frame when the evidence set exceeds the budget. Elision is governed by the strategy's elision policy and stratum priorities — it is purpose-aware selection under constraint, not arbitrary truncation. `See DAS-009`

**Strategy Catalog** — The runtime registry of validated, versioned context strategies. The catalog maps each purpose to its active strategy and retains superseded versions for diagnostic replay. `INTRODUCED`

**Assembly Request** — The input to a context assembly invocation: an evidence set, a context purpose, a context budget, and an optional strategy version override. `INTRODUCED`

---

## Responsibilities

```
R1: Transform evidence sets into purpose-calibrated context frames.
    DAS: DAS-009 (purpose-stratified context assembly architecture),
         DAS-008 RC-5 (retrieval does not guarantee relevance — context
         assembly provides it)
    Boundary: The Context Assembly Runtime performs the transformation.
              It does not gather evidence (DDS-005). It does not define
              consumer purposes (coordinating subsystem). It does not
              format context frames for specific consumers (DDS for
              Consumer Runtime).

R2: Own and manage the strategy catalog — validate, register, version,
    and resolve context strategies.
    DAS: DAS-009 (context strategy contract, strategy parameterization)
    Boundary: The Context Assembly Runtime validates and serves
              strategies. It does not author strategies — strategies
              are defined by engineers as part of capability development.
              It does not determine which purpose to use for a given
              user question — the coordinating subsystem maps questions
              to purposes.

R3: Enforce the context budget as a hard ceiling.
    DAS: DAS-009 BM-1 (budget is a hard ceiling), I1 (budget compliance)
    Boundary: The Context Assembly Runtime never exceeds the budget.
              It does not determine optimal budget values — the caller
              specifies the budget. It does not estimate consumer-
              specific token costs with precision — it uses conservative
              estimation.

R4: Enforce coherence constraints during evidence selection.
    DAS: DAS-009 CC-1 through CC-3 (coherence guarantees),
         CE-1 through CE-3 (coherence enforcement)
    Boundary: The Context Assembly Runtime enforces strategy-defined
              coherence constraints. It does not define universal
              coherence rules — coherence is strategy-specific. It
              resolves coherence/budget conflicts by constraint
              retraction (neither triggering unit nor required unit
              included).

R5: Apply elision under budget pressure per the strategy's elision
    policy.
    DAS: DAS-009 EP-1 through EP-3 (elision policies)
    Boundary: The Context Assembly Runtime determines what evidence to
              sacrifice when the evidence set exceeds the budget. It
              follows the strategy's elision policy. It does not
              negotiate with the caller for a larger budget.

R6: Assign context roles to selected evidence.
    DAS: DAS-009 CF-3 (every unit carries its context role),
         DAS-009 C8 (three-level traceability)
    Boundary: The Context Assembly Runtime annotates each unit with
              its selection rationale. It does not assign evidence
              provenance (DDS-005) or unit provenance (DDS-002).

R7: Preserve grounding chains without modification.
    DAS: DAS-009 GP-1 (grounding preserved), I5 (grounding integrity)
    Boundary: The Context Assembly Runtime passes through grounding
              chains from the evidence set. It does not verify
              grounding chain validity — that is DDS-002's
              responsibility at intake.

R8: Propagate freshness and degradation metadata.
    DAS: DAS-009 CFR-1 through CFR-3 (context freshness),
         DAS-003 I7 (degradation validity)
    Boundary: The Context Assembly Runtime carries forward freshness
              state from the evidence set and computes degradation
              level based on tier availability in the frame. It does
              not assess or improve freshness — it reports it.

R9: Provide per-assembly observability.
    DAS: DAS-009 OB-1 through OB-5 (observability requirements)
    Boundary: The Context Assembly Runtime emits per-assembly metrics
              (selection counts, elision counts, coherence statistics,
              tier distribution, budget utilization, assembly duration).
              Aggregation and dashboarding are outside scope.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Context Assembly
  Direction:    Offered
  Counterparty: Consumer Runtime, scheduling subsystem, coordinating
                subsystem
  Guarantee:    Given an assembly request (evidence set, context purpose,
                context budget, optional strategy version), the Context
                Assembly Runtime produces a context frame.

                The assembly request specifies:
                - Evidence set: the output of DDS-005:PC-1.
                - Context purpose: identifies the strategy to apply.
                - Context budget: amount and denomination (tokens or
                  unit count). Hard ceiling.
                - Strategy version (optional): if specified, assembly
                  uses this specific version of the strategy for the
                  given purpose. If omitted, the active (most recent
                  non-superseded) version is used. Strategy version
                  override enables replay and debugging — reproducing
                  a prior assembly by pinning the strategy version.

                The context frame satisfies:
                - CFI-1: Budget compliance (frame fits within budget).
                - CFI-2: Stratum partitioning (each unit in exactly
                  one stratum).
                - CFI-3: Coherence (all constraints satisfied or
                  retracted).
                - CFI-4: Determinism (same inputs → same frame).
                - CFI-5: Grounding integrity (chains unmodified).
                - CFI-6: Priority ordering (higher strata filled first).
                - CFI-7: Evidence soundness (all units from evidence
                  set).
                - CFI-8: Epoch consistency (single epoch).
                - CFI-9: Within-stratum ordering (deterministic per
                  fill policy).

                The context frame contains:
                - Resolved anchors (from evidence set).
                - Purpose and strategy identifier with version.
                - Filled strata in priority order, each containing
                  ordered context units with context roles.
                - Budget summary (total, used, utilization).
                - Metadata (evidence set size, selected count, elision
                  count, per-tier counts, per-stratum counts, coherence
                  statistics, degradation level, freshness state,
                  assembly duration, committed epoch).

  Preconditions: The Context Assembly Runtime is in Available state.
                 The assembly request satisfies all formal preconditions
                 (see Preconditions section).
  Failure mode: See Failure Handling (FM-1 through FM-7). No failure
                mode produces an exception — all produce either a valid
                (possibly empty or partial) context frame with
                diagnostic metadata, or a rejection with diagnostic
                identifying the specific violation.

PC-2: Strategy Registration
  Direction:    Offered
  Counterparty: Application startup, capability registration subsystem
  Guarantee:    Given a context strategy definition, the Context Assembly
                Runtime validates the strategy against all strategy
                invariants (SI-1 through SI-7) and, if valid, registers
                it in the strategy catalog. The registered strategy is
                immediately available for assembly requests referencing
                its purpose.

                If a strategy already exists for the same purpose, the
                new strategy supersedes the prior version. The prior
                version is retained for diagnostic replay but is no
                longer the active version for new assembly requests.

  Preconditions: The Context Assembly Runtime is in Available state.
                 The strategy definition contains all required
                 components (CS-R1 through CS-R6).
  Failure mode: If the strategy fails any validation check (SI-1
                through SI-7), registration is rejected with a
                diagnostic identifying the specific invariant
                violation. The strategy catalog is unchanged.

PC-3: Strategy Catalog Query
  Direction:    Offered
  Counterparty: Diagnostic consumers, observability, coordinating
                subsystem
  Guarantee:    Returns the current strategy catalog: for each
                registered purpose, the active strategy (with version)
                and any superseded versions. Includes stratum
                definitions, coherence constraints, tier preference,
                and elision policy for each strategy.
  Preconditions: None.
  Failure mode: None. The catalog is always queryable — it may be
                empty if no strategies have been registered.
```

### Required Contracts

```
PC-4: Evidence Set
  Direction:    Required
  Counterparty: Retrieval Runtime (DDS-005, via DDS-005:PC-1)
  Guarantee:    The Context Assembly Runtime receives evidence sets
                as input to assembly requests. The evidence set
                satisfies DDS-005:PC-1 guarantees: RC-1 (completeness
                within horizon), RC-2 (soundness), RC-3 (consistent
                snapshot), RC-4 (deterministic anchor resolution).
                The evidence set is in canonical deterministic order
                (DDS-005 Evidence Ordering).
  Preconditions: The Retrieval Runtime is in Available state. The
                 evidence set was produced by a completed retrieval
                 request.
  Failure mode: If the evidence set is structurally malformed (missing
                required fields, absent metadata), the assembly
                request is rejected (FM-7). If the evidence set is
                empty (zero units), this is valid input producing an
                empty context frame (FM-1).
```

---

## Context Strategy Contract

### Required Components

A valid context strategy must contain all of the following:

```
CS-R1: Purpose identifier
  A unique, stable identifier for the consumer purpose this strategy
  serves. One purpose maps to exactly one active strategy. No two
  active strategies share a purpose.

CS-R2: Stratum definitions
  An ordered list of one or more stratum definitions. Each stratum
  specifies:
  - Name: unique within the strategy.
  - Priority: integer, 1 = highest. Unique within the strategy.
  - Selection criteria: predicates over evidence annotations
    (evidence provenance, predicate type, distance from anchor,
    tier, confidence, entity type). Compose conjunctively.
  - Budget fraction: float (0.0–1.0).
  - Fill policy: exactly one of distance-first, tier-first,
    confidence-first, entity-completeness.
  - Essential flag: boolean. If true, evidence matching this
    stratum's selection criteria is protected from elision.

CS-R3: Coherence constraints
  Zero or more constraints. Each specifies:
  - Trigger pattern: a predicate on annotated units.
  - Requirement pattern: a predicate on annotated units that must
    co-occur when the trigger is satisfied.
  Both patterns reference the evidence annotation vocabulary.

CS-R4: Tier preference
  Exactly one of:
  - Tier ordering (e.g., T0 > T1 > T2).
  - Tier ratio targets (e.g., "at least 40% T0").
  Secondary to stratum priority (DAS-009 CS-4).

CS-R5: Elision policy
  Exactly one of: stratum-first, distance-first, confidence-first,
  proportional.

CS-R6: Strategy version
  A version identifier that changes whenever any component changes.
  Recorded in context frame metadata for reproducibility.
```

### Strategy Invariants

```
SI-1: Budget Fraction Totality
  Statement:   The sum of all stratum budget fractions equals 1.0.
  Rationale:   Over-allocation double-counts budget; under-allocation
               wastes budget. Either violates the strategy's ability
               to distribute budget predictably across strata.
  Verification: Sum all stratum budget fractions. Confirm equals 1.0
               (within floating-point tolerance).

SI-2: Selection Criteria Mutual Exclusivity
  Statement:   For any annotated unit in any valid evidence set, the
               unit matches the selection criteria of at most one
               stratum.
  Rationale:   If a unit could match multiple strata, stratum
               assignment is ambiguous, breaking DAS-009 I2 (stratum
               partitioning) and determinism.
  Verification: For each pair of strata, confirm that their selection
               criteria cannot both match the same unit. The criteria
               vocabularies must produce disjoint partitions.

SI-3: Priority Uniqueness
  Statement:   No two strata share a priority value.
  Rationale:   Ambiguous priority makes stratum ordering undefined,
               breaking determinism (DAS-009 I4).
  Verification: Confirm all priority values are distinct.

SI-4: Coherence Constraint Termination
  Statement:   No cycle exists in the coherence constraint graph.
  Rationale:   A cyclic constraint graph produces infinite loops
               during assembly — satisfying constraint A triggers
               constraint B, which triggers constraint A.
  Verification: Build a directed graph where each constraint is a
               node and an edge exists from constraint X to
               constraint Y if satisfying X's requirement could
               trigger Y. Confirm the graph is acyclic.

SI-5: Essential Stratum Singularity
  Statement:   At most one stratum is marked essential.
  Rationale:   Multiple essential strata create ambiguity when the
               budget cannot accommodate all essential evidence from
               all essential strata — which essential stratum takes
               precedence is undefined.
  Verification: Count strata with essential flag true. Confirm ≤ 1.

SI-6: Strategy-Purpose Bijection
  Statement:   Each purpose maps to exactly one active strategy. Each
               strategy serves exactly one purpose.
  Rationale:   Ambiguous strategy resolution (multiple strategies for
               one purpose) breaks determinism. Unreachable strategies
               (strategy with no purpose) waste catalog space and
               create confusion.
  Verification: Confirm no two active strategies share a purpose.

SI-7: Stratum Reachability
  Statement:   Every stratum's selection criteria can match at least
               one valid annotated unit. No stratum has selection
               criteria that are logically unsatisfiable.
  Rationale:   An unreachable stratum consumes a budget fraction that
               will always go unused (flowing to subsequent strata).
               This misrepresents the strategy's budget intent — the
               strategy author allocated budget to a stratum that can
               never receive evidence, distorting the effective budget
               distribution for reachable strata. Unreachable strata
               indicate a strategy authoring error.
  Verification: For each stratum, confirm that its selection criteria
               are satisfiable — there exists a valid combination of
               evidence provenance, predicate type, distance, tier,
               confidence, and entity type that matches the criteria.
               Criteria referencing non-existent provenance categories,
               impossible tier/distance combinations, or contradictory
               conjunctions are unsatisfiable.
```

### Strategy Lifecycle

**Registration.** Strategies are registered via PC-2. Registration
includes validation of all invariants (SI-1 through SI-7). A strategy
that fails validation is rejected — it is never available for assembly.
Registration may occur during application startup (batch registration
of all strategies) or at runtime (dynamic capability addition).

**Availability.** A registered, validated strategy is immediately
available for assembly requests referencing its purpose. The strategy
is available until it is superseded or the Context Assembly Runtime
is terminated.

**Immutability.** Strategies are immutable once registered. To change
a strategy, a new version is registered for the same purpose. This
ensures that in-progress assemblies are not affected by strategy
changes and that context frames can be reproduced by re-assembling
with the same strategy version.

**Supersession.** When a new version of a strategy for the same
purpose is registered, the prior version is superseded. The prior
version is retained in the catalog for diagnostic replay (via the
strategy version override in assembly requests) but is not used for
new assembly requests unless explicitly requested by version.

**Disposal.** Strategies are session-scoped. They are loaded at
startup and discarded at shutdown. No persistent strategy state
survives across restarts (consistent with DAS-012 ephemeral
realization).

### Strategy Ownership

The Context Assembly Runtime owns the strategy catalog at runtime:
it validates, stores, resolves, and versions strategies. The Context
Assembly Runtime does not own strategy definitions — definitions are
authored by engineers as part of capability development. The runtime
validates and serves them; it does not create them.

---

## Preconditions

### Formal Preconditions for Context Assembly

```
PRE-1: Evidence Set Structural Validity
  Statement:   The evidence set must be a well-formed output of
               DDS-005:PC-1. Each annotated unit carries a complete
               atomic unit record (all 10 DAS-002 fields plus
               lifecycle status), evidence provenance, distance from
               anchor, tier, and confidence. The evidence set carries
               metadata including the committed epoch. All annotated
               units observe the same epoch (DDS-005:RI-3). The
               evidence set is in canonical deterministic order
               (DDS-005 Evidence Ordering).
  Guarantor:   Retrieval Runtime (DDS-005). The evidence set is the
               output of DDS-005:PC-1, which guarantees RC-1 through
               RC-4 and the evidence ordering contract.
  If violated: The assembly request is rejected with a diagnostic
               identifying the structural defect. No context frame
               is produced.
  Note:        An empty evidence set (zero units, anchors present or
               absent) is not a violation. It is valid input that
               produces an empty context frame (FM-1).

PRE-2: Retrieval Intent / Context Purpose Compatibility
  Statement:   The evidence set's retrieval intent should be
               compatible with the requested context purpose.
               Compatibility means the evidence gathered under the
               retrieval intent contains evidence that the context
               strategy's selection criteria can match.
  Guarantor:   Coordinating subsystem (outside DDS-005 and DDS-006
               scope). The coordinating subsystem maps user questions
               to both retrieval requests (with intent) and assembly
               requests (with purpose) and must ensure alignment.
  If violated: Context Assembly proceeds — it does not reject on
               intent/purpose mismatch. The selection criteria may
               match few or no units. The result is a sparse or
               empty context frame with high elision ratio and low
               budget utilization. This is observable degradation,
               not failure. Metadata signals: low stratum utilization,
               high elision count, budget underutilization.

PRE-3: Budget Validity
  Statement:   The context budget must specify a positive amount
               (> 0) and a denomination (tokens or unit count).
  Guarantor:   Caller (coordinating subsystem or consumer interface).
  If violated: Zero, negative, or missing budget: assembly request
               is rejected with a diagnostic. No context frame is
               produced.
  Note:        A budget that is positive but too small for essential
               evidence is not a precondition violation. It is a
               valid scenario producing FM-2 (budget insufficient).

PRE-4: Strategy Availability
  Statement:   A valid, non-superseded strategy must exist for the
               requested context purpose. If a strategy version
               override is specified, that specific version must
               exist in the catalog (active or superseded).
  Guarantor:   Context Assembly Runtime (via strategy registration
               and validation, PC-2) and coordinating subsystem
               (requests only registered purposes).
  If violated: No strategy for the purpose: FM-4 (strategy not
               found). No context frame is produced. Specified
               version not found: FM-4 with version-specific
               diagnostic.
```

---

## Lifecycle

### Creation

The Context Assembly Runtime is created during application startup,
after the Retrieval Runtime (DDS-005) is available.

**Preconditions for creation:** The Retrieval Runtime is in Available
state (DDS-005 state model).

**No persistent state.** The Context Assembly Runtime has no persistent
state. The strategy catalog is populated during startup via PC-2
(strategy registration) and is session-scoped. No assembly state
survives across requests or restarts.

### Startup

After creation, the Context Assembly Runtime registers context
strategies via PC-2. Strategies may be registered in any order. The
runtime enters Available state once at least one strategy is
registered. It may also enter Available state with an empty catalog
— assembly requests will fail with FM-4 (strategy not found) until
strategies are registered.

### Operation

The Context Assembly Runtime processes assembly requests (PC-1) and
strategy registrations (PC-2) during operation. Each assembly request
is independent — no state is shared between requests. Strategy
registrations may occur during operation (dynamic capability addition).

**Operational invariant:** Every context frame returned by the Context
Assembly Runtime satisfies all context frame invariants (CFI-1 through
CFI-9).

### Quiescence

When the application is shutting down:

1. No new assembly requests are accepted.
2. In-progress assembly requests complete.
3. No cleanup is required — per-request resources are released upon
   request completion.

### Destruction

The Context Assembly Runtime is destroyed during application teardown.
The strategy catalog is discarded.

**Destruction ordering:** The Context Assembly Runtime is destroyed
before the Retrieval Runtime (DDS-005). The Retrieval Runtime remains
available for any in-progress assembly that requires evidence set
re-reads (though assembly does not perform re-reads — this ordering
preserves the dependency hierarchy).

---

## State Model

The Context Assembly Runtime occupies one of three states:

```
Unavailable → Available → Terminated
```

**Unavailable.** The Context Assembly Runtime has been created but
is not yet ready to process assembly requests. The Retrieval Runtime
may not yet be available.

**Available.** The Context Assembly Runtime processes assembly
requests and strategy registrations. The strategy catalog may be
empty — requests for unregistered purposes fail with FM-4, but the
subsystem is available.

**Terminated.** The Context Assembly Runtime has been destroyed. No
operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Unavailable | Available | Retrieval Runtime available | Assembly requests accepted |
| Available | Terminated | Shutdown signal and all in-progress requests complete | Catalog discarded |

**Invalid transitions:** Unavailable → Terminated (must become
Available first or be destroyed without having operated). Terminated
→ any state. Available → Unavailable (once available, remains
available until shutdown).

---

## Execution Model

### Assembly Request Lifecycle

An assembly request passes through the following phases:

1. **Precondition validation.** Validate all formal preconditions
   (PRE-1 through PRE-4). Reject the request if any hard
   precondition is violated. PRE-2 (intent/purpose compatibility)
   is a soft precondition — it produces degradation, not rejection.

2. **Strategy resolution.** Resolve the context purpose to a
   context strategy. If a strategy version override is specified,
   resolve to that specific version. If omitted, resolve to the
   active version for the purpose. If no strategy is found, return
   FM-4.

3. **Budget computation.** Compute per-stratum budget allocations
   by multiplying each stratum's budget fraction by the total
   budget.

4. **Stratum-ordered selection.** For each stratum in priority order:

   a. **Candidate identification.** Apply the stratum's selection
      criteria to the evidence set. The result is the set of
      candidate units for this stratum.

   b. **Candidate ordering.** Apply the stratum's fill policy to
      order candidates deterministically. Ties within the fill
      policy are broken by ascending unit identifier (DAS-009
      ES-4).

   c. **Per-candidate processing.** For each candidate in fill
      order:
      - **Coherence check.** If including this candidate triggers
        a coherence constraint, identify the required co-occurring
        unit. If the required unit belongs to this stratum, include
        both (budget permitting). If the required unit belongs to
        a later stratum, reserve it for inclusion when that stratum
        is processed.
      - **Budget check.** Estimate the candidate's size in the
        budget denomination. If the stratum's remaining allocation
        (plus any budget overflow from prior strata) can accommodate
        the candidate and its coherence requirements, include it.
        If not, apply the elision policy: skip this candidate and
        try the next (for within-stratum elision), or stop filling
        this stratum (for stratum-first elision).
      - **Context role assignment.** If included, assign the context
        role explaining why this unit was selected.

   d. **Budget overflow.** Unused budget from this stratum flows to
      the next stratum's allocation (DAS-009 CS-2). Budget never
      flows upward.

5. **Cross-stratum coherence resolution.** Process reserved units
   in their target strata. Reserved units are included first,
   before the stratum's own candidates, consuming the stratum's
   budget. If a stratum's budget cannot accommodate its reserved
   units, the triggering unit in the earlier stratum is removed
   (constraint retraction per DAS-009 CE-2), and the reserved
   unit is released.

6. **Deduplication.** If a unit was identified as a candidate in
   multiple strata (should not occur if SI-2 holds, but defensive),
   it appears only in the stratum where it was first selected.

7. **Within-stratum ordering.** Context units within each stratum
   are in fill-policy order (already established during selection).

8. **Metadata assembly.** Compute all metadata fields: evidence set
   size, selected count, elision count, per-tier counts, per-stratum
   counts, coherence constraints fired/satisfied/retracted,
   degradation level, freshness state, budget utilization, assembly
   duration, strategy version, committed epoch.

9. **Context frame construction.** Assemble the context frame:
   anchors, purpose, strategy identifier and version, filled strata,
   budget summary, metadata.

10. **Return.** The context frame is returned to the caller. No
    reference is retained.

### Unit Size Estimation

Context assembly estimates the size of each unit in the budget's
denomination to enforce budget compliance.

**Token estimation.** When the budget is denominated in tokens, the
Context Assembly Runtime estimates each unit's token cost. The
estimate is conservative — it overestimates rather than underestimates
(DAS-009 BM-1). The exact token count depends on the consumer's
tokenizer, which context assembly does not know. The estimation
function is an internal engineering mechanism, not a public contract.

`DDS-INTERNAL` — Unit size estimation is necessary to realize
DAS-009 I1 (budget compliance) but is not traced to a specific
DAS counterparty. It is an internal engineering concern.

**Unit count estimation.** When the budget is denominated in unit
count, each unit costs exactly 1. No estimation is needed.

### Concurrency and Isolation

**Request isolation.** Each assembly request executes independently.
No state is shared between concurrent requests. Each request resolves
its own strategy, computes its own budget allocations, and maintains
its own selection state.

**Strategy catalog concurrency.** Strategy registrations (PC-2) and
assembly requests (PC-1) may occur concurrently. A strategy
registration that completes during an in-progress assembly does not
affect that assembly — the assembly uses the strategy resolved at
phase 2 (strategy resolution). New assemblies after the registration
use the new strategy.

**Strategy snapshot semantics.** An assembly binds to exactly one
immutable strategy snapshot during phase 2 (strategy resolution).
Once bound, the strategy snapshot is fixed for the duration of the
assembly. Subsequent strategy registrations, supersessions, or
catalog mutations that occur after phase 2 never affect the bound
assembly. The strategy snapshot includes all strategy components
(stratum definitions, coherence constraints, tier preference,
elision policy, version). Deterministic reproducibility (CFI-4)
depends on this snapshot guarantee: given the same evidence set,
the same strategy version, and the same budget, the assembly
produces the same frame regardless of concurrent catalog mutations
that occur after binding.

**Read-only guarantee.** The Context Assembly Runtime never writes to
the DIR (DDS-002), never modifies indexes (DDS-004), never triggers
pass execution (DDS-001). All interactions with the evidence set are
read-only. No assembly operation has side effects on canonical data
(DAS-009 I7, CL-3).

---

## Context Frame Contract

### Required Contents

Every context frame produced by PC-1 must contain:

```
CF-R1: Anchors
  The resolved entity anchors from the evidence set. May be empty
  (if the evidence set had empty anchors). Unmodified by context
  assembly.

CF-R2: Purpose
  The context purpose for which this frame was assembled. Matches
  the requested purpose.

CF-R3: Strategy identifier and version
  The strategy used for assembly, including its version (CS-R6).
  Enables reproducibility: given the same evidence set and the same
  strategy version, the same frame is produced.

CF-R4: Filled strata
  An ordered list of filled strata in priority order. Each stratum
  contains:
  - Stratum name (matching the strategy's stratum definition).
  - Priority (matching the strategy).
  - Ordered list of context units (CF-R5).
  - Budget allocated to this stratum (including overflow received).
  - Budget used by this stratum.
  Empty strata (no evidence matched or budget exhausted before
  reaching this stratum) are included with zero units and zero used
  budget. This distinguishes "no evidence available" from "stratum
  elided by budget pressure."

CF-R5: Context units
  Each context unit contains:
  - The complete atomic unit record (all 10 DAS-002 fields plus
    lifecycle status). Unmodified from the evidence set.
  - Context role: why this unit was selected.
  - Distance from anchor: inherited from evidence annotation.
    Unmodified.
  - Tier and confidence: inherited from the atomic unit. Unmodified.
  - Grounding chain: complete, inherited from the atomic unit.
    Unmodified (DAS-009 GP-1, I5).

CF-R6: Budget summary
  Total budget, budget denomination, used budget, utilization ratio
  (used / total).

CF-R7: Metadata
  - Evidence set size (total annotated units received).
  - Selected count (units in the frame).
  - Elision count (evidence set size minus selected count).
  - Per-tier unit counts (T0, T1, T2) in the frame.
  - Per-stratum unit counts.
  - Coherence constraints fired, satisfied, and retracted.
  - Degradation level (full / T0+T1 only / T0 only).
  - Freshness state (fresh / partially stale / stale).
  - Assembly duration.
  - Strategy version used.
  - Committed epoch (inherited from evidence set metadata).
  - Budget sufficiency flag (true unless FM-2 triggered).
```

### Context Frame Invariants

```
CFI-1: Budget Compliance
  Statement:   The total used budget does not exceed the total budget.
  Rationale:   Budget overflow causes consumer failure — tokens are
               lost, computations overflow, attention is saturated.
               The budget is a hard ceiling (DAS-009 I1).
  Verification: Confirm used budget ≤ total budget for every frame.

CFI-2: Stratum Partitioning
  Statement:   Every context unit belongs to exactly one stratum. The
               sets of unit identifiers across all strata are disjoint.
  Rationale:   Duplicate units waste budget and make elision
               unpredictable (DAS-009 I2).
  Verification: Confirm the unit identifier sets across all strata
               are disjoint and their union equals the full unit set.

CFI-3: Coherence
  Statement:   For every coherence constraint defined by the strategy:
               either (a) the constraint is satisfied (triggering unit
               and required unit both present), or (b) the constraint
               is retracted (triggering unit absent). No frame contains
               a triggering unit without its required unit.
  Rationale:   Incoherent context misleads consumers — unresolvable
               references and unsupported claims are worse than a
               smaller coherent frame (DAS-009 I3).
  Verification: Evaluate every coherence constraint against the frame.
               Confirm each is satisfied or retracted.

CFI-4: Deterministic Assembly
  Statement:   Given the same evidence set, the same strategy version,
               and the same budget, context assembly produces the same
               context frame — same units, same strata, same order,
               same metadata (except assembly duration).
  Rationale:   Non-deterministic assembly makes identical questions
               produce different context, leading to different outputs
               (DAS-009 I4).
  Verification: Assemble twice with identical inputs. Confirm
               identical output (excluding assembly duration).

CFI-5: Grounding Integrity
  Statement:   Every context unit carries the identical grounding
               chain as its source annotated unit in the evidence set.
               Context assembly does not modify, truncate, or strip
               grounding.
  Rationale:   Grounding enables consumers to verify claims. Truncated
               grounding prevents traceability (DAS-009 I5).
  Verification: For each context unit, confirm grounding chain equality
               with the corresponding evidence set unit.

CFI-6: Stratum Priority Ordering
  Statement:   If a frame contains evidence in stratum N (priority P)
               and stratum M (priority Q, Q > P), then stratum N's
               candidates were exhausted or its budget was fully
               consumed. No lower-priority stratum receives evidence
               while a higher-priority stratum has remaining budget
               and unfilled candidates.
  Rationale:   Including less important evidence at the expense of
               more important evidence defeats the purpose of priority
               ordering (DAS-009 I6).
  Verification: Confirm no stratum with unfilled candidates and
               remaining budget is followed by a stratum that received
               evidence. Exception: reserved units from coherence
               constraints.

CFI-7: Evidence Soundness
  Statement:   Every context unit in the frame originated from the
               evidence set. Context assembly does not synthesize,
               fabricate, or modify atomic units. The frame is a
               strict subset of the evidence set with added context
               roles.
  Rationale:   Fabricated units are ungrounded and unverifiable.
  Verification: For each context unit, confirm its unit identifier
               exists in the evidence set with identical field values.

CFI-8: Epoch Consistency
  Statement:   All context units in the frame observe the same
               committed epoch, inherited from the evidence set. The
               frame's metadata epoch matches the evidence set's epoch.
  Rationale:   Mixed-epoch evidence produces inconsistent consumer
               views.
  Verification: Confirm all units share the evidence set's epoch.

CFI-9: Within-Stratum Ordering
  Statement:   Context units within each stratum are ordered according
               to the stratum's fill policy. Ties are broken by
               ascending unit identifier. The ordering is deterministic
               and part of the contract.
  Rationale:   Consumers that process units in order within a stratum
               process the most important units first per the fill
               policy. Non-deterministic ordering within strata would
               break reproducibility.
  Verification: Confirm unit ordering within each stratum matches the
               fill policy with unit-identifier tie-breaking.
```

### What Consumers May Rely Upon

Consumers of the context frame may rely on:

1. Stratum ordering reflects priority — the first stratum is the
   highest-priority evidence.
2. Within-stratum ordering reflects the fill policy — the first unit
   in a stratum is the most important per the policy.
3. Coherence — if a relationship edge is present, its target entity's
   identity is present (per strategy-defined constraints).
4. Budget compliance — the frame fits within the declared budget.
5. Grounding completeness — every unit has its full grounding chain.
6. Tier and confidence accuracy — values are unmodified from the DIR.
7. Epoch consistency — all evidence is from the same DIR state.
8. Metadata accuracy — tier distribution, budget utilization,
   degradation level, and all other metadata fields accurately
   describe the frame's composition.
9. Context roles — every unit carries a context role explaining its
   selection.
10. Determinism — same inputs produce the same frame.

### What Consumers Must Never Assume

Consumers must NOT assume:

1. Completeness — the frame may omit evidence elided by budget
   constraint. DAS-008 RC-6 propagates: retrieval does not guarantee
   sufficiency, and context assembly does not either.
2. That all strata contain evidence — strata may be empty due to
   missing evidence or budget exhaustion.
3. That T2 evidence is present — T2 depends on semantic enrichment
   having run. The degradation level indicates tier availability.
4. That coherence targets are in the same stratum as the triggering
   unit — cross-stratum coherence may place required units in
   different strata.
5. Specific stratum names or structure — different strategies define
   different strata. Process by priority position, not by name.
6. That the frame can be modified and re-submitted — there is no
   "refine this frame" contract. Construct a new assembly request.
7. That units are in evidence set order — the frame uses stratum
   and fill-policy ordering, not retrieval ordering.
8. That the frame is stable across strategy versions — a version
   change may change which units appear.
9. That assembly duration is deterministic — all other metadata
   fields are deterministic given the same inputs.

### Context Frame Ownership

**Producer:** The Context Assembly Runtime produces the context frame.
Once returned, the frame is owned by the caller. The frame is a
value — not a reference to shared mutable state.

**No retained reference.** Context Assembly does not retain a reference
to any frame it produces. The frame is fully detached upon return.

**No persistence.** Context frames are never persisted, cached, or
stored (DAS-009 CL-1, CL-2). They are ephemeral, single-use artifacts.

---

## Memory and Ownership

### Owned Resources

**Strategy catalog.** The Context Assembly Runtime exclusively owns
the in-memory strategy catalog. The catalog stores all registered
strategies (active and superseded) indexed by purpose. No other
subsystem directly reads or writes the catalog. All access is through
PC-2 (registration) and PC-3 (query).

### Per-Request Resources

**Selection state.** Allocated per request: per-stratum candidate
lists, budget counters, coherence reservation lists, context role
assignments. Released when the request completes. Size is proportional
to the evidence set size and the number of strata.

**Context frame accumulator.** Allocated per request to collect
context units during selection. Size is bounded by the context budget.
Released after the frame is constructed and returned.

### Borrowed Resources

**Evidence set (read).** The Context Assembly Runtime borrows the
evidence set for the duration of a single assembly request. The
evidence set is immutable — context assembly never modifies it.

### Shared Resources

None. The Context Assembly Runtime does not share mutable state with
any other subsystem. All interactions are through contracts.

### Memory Bounds

**Strategy catalog.** Proportional to the number of registered
strategies × stratum count × coherence constraint count. At expected
scale (~10 purposes, ~4 strata each, ~5 coherence constraints each):
<10 KB. Negligible.

**Per-request memory.** Proportional to the evidence set size (for
candidate identification) plus the context budget (for the frame
accumulator). Each context unit carries the full atomic unit record
(~100–300 bytes per DDS-002 Memory Bounds) plus context role
annotation (~30 bytes). At the maximum expected budget of ~1,000
units: ~330 KB per request. Selection state (candidate lists, budget
counters): proportional to evidence set size, ~100 KB at 1,000
evidence units. Total per-request: ~430 KB.

**Concurrent requests.** At alpha scale, assembly requests are
user-triggered and sequential. At N concurrent requests: ~430 KB × N.

**Subsystem overhead.** Strategy catalog + contract references.
<20 KB. Negligible.

### Eviction

Per-request resources are released when the request completes.
Strategy catalog is session-scoped and released on shutdown. No
eviction policy is needed — all resources are request-scoped or
session-scoped.

---

## Runtime Invariants

```
RI-1: Budget Compliance
  Statement:   Every context frame's total used budget does not exceed
               the context budget specified in the assembly request.
  Rationale:   Budget overflow causes consumer failure (DAS-009 I1).
  Verification: For each frame, confirm used ≤ total. Use conservative
               unit size estimation; actual size may be lower but must
               not be higher.

RI-2: Stratum Partitioning
  Statement:   Every context unit belongs to exactly one stratum.
  Rationale:   Duplicates waste budget and break elision predictability
               (DAS-009 I2).
  Verification: Confirm disjoint unit identifier sets across strata.

RI-3: Coherence
  Statement:   Every coherence constraint is either satisfied or
               retracted. No frame contains a triggering unit without
               its required unit.
  Rationale:   Incoherent context misleads consumers (DAS-009 I3).
  Verification: Evaluate all constraints against each frame.

RI-4: Deterministic Assembly
  Statement:   Same evidence set + same strategy version + same budget
               → same frame (excluding assembly duration).
  Rationale:   Non-determinism makes debugging impossible (DAS-009 I4).
  Verification: Assemble twice with identical inputs. Confirm identical
               output.

RI-5: Grounding Integrity
  Statement:   All grounding chains passed through unmodified.
  Rationale:   Truncated grounding prevents claim verification
               (DAS-009 I5).
  Verification: Confirm grounding equality with evidence set source.

RI-6: Stratum Priority Ordering
  Statement:   Higher-priority strata are filled before lower-priority
               strata.
  Rationale:   Priority ordering expresses importance (DAS-009 I6).
  Verification: Confirm no priority inversion in stratum filling.

RI-7: No Side Effects
  Statement:   No assembly operation modifies the DIR, indexes,
               evidence set, or triggers pass execution.
  Rationale:   Side effects couple read and write paths (DAS-009 I7).
  Verification: Snapshot all state before assembly. Confirm unchanged
               after.

RI-8: Tier Monotonicity in Degradation
  Statement:   Absent higher tiers do not reduce lower-tier evidence
               in the frame. T2 absence does not reduce T0 or T1
               evidence.
  Rationale:   Degradation should reduce richness, not prevent
               retrieval of available facts (DAS-009 I8).
  Verification: Assemble with all tiers. Remove T2. Re-assemble.
               Confirm T0/T1 units from first frame are present in
               second (excluding units included only via coherence
               with T2 units).

RI-9: Evidence Soundness
  Statement:   Every context unit originated from the evidence set.
               No units synthesized or fabricated.
  Rationale:   Fabricated units are ungrounded and unverifiable.
  Verification: Confirm every context unit's identifier exists in
               the evidence set with identical field values.

RI-10: Epoch Consistency
  Statement:    All context units observe the same committed epoch.
  Rationale:    Mixed-epoch evidence produces inconsistent views.
  Verification: Confirm epoch uniformity.

RI-11: Strategy Validity
  Statement:    Every strategy in the catalog satisfies all strategy
                invariants (SI-1 through SI-7). No invalid strategy
                is ever available for assembly.
  Rationale:    An invalid strategy produces defective frames that
                satisfy assembly invariants while being useless.
  Verification: Re-validate all catalog strategies periodically.
                Confirm no invariant violations.
```

---

## Failure Handling

```
FM-1: Evidence Set Empty
  Trigger:     The evidence set contains zero annotated units (subject
               not found during retrieval, or DIR unpopulated for the
               relevant scope).
  Detection:   Evidence set unit count = 0 during precondition
               validation.
  Response:    Context Assembly produces an empty context frame with
               all strata empty. Metadata indicates "no evidence."
               Budget utilization is 0%. This is not a failure — it
               is a valid (empty) result propagated from retrieval.
  Caller observes: A valid context frame with zero context units and
               metadata explaining the absence.
  Recovery:    None required. The caller decides whether to retry
               with a different subject or report the absence.

FM-2: Budget Insufficient for Essential Evidence
  Trigger:     The context budget is too small to accommodate the
               essential evidence (the essential stratum's candidates
               that matched selection criteria).
  Detection:   During essential stratum filling, the estimated size
               of essential candidates exceeds the total budget.
  Response:    Context Assembly includes as much essential evidence
               as the budget allows. The frame's metadata includes
               a budgetInsufficient flag. The frame is valid but
               partial — the consumer must decide whether to proceed
               with partial essential evidence or re-request with a
               larger budget.
  Caller observes: A valid context frame with budgetInsufficient =
               true and fewer units than expected in the essential
               stratum.
  Recovery:    The caller may re-request with a larger budget.

FM-3: Coherence Constraint Unsatisfiable
  Trigger:     A coherence constraint requires a unit that does not
               exist in the evidence set (e.g., "include callee
               identity" but the callee was not gathered by retrieval).
  Detection:   During coherence check, the required unit is not found
               in the evidence set.
  Response:    The triggering unit is retracted — it is excluded from
               the context frame. This preserves CFI-3: no frame
               contains a triggering unit without its required unit.
               The frame's metadata records the coherence retraction:
               the constraint identity, the triggering unit that was
               retracted, and the required unit that was absent.
               The root cause is retrieval/context misalignment — the
               retrieval intent did not gather evidence that the
               strategy's coherence constraints require. Context
               Assembly never emits an incoherent frame.
  Caller observes: A valid, coherent context frame. Metadata includes
               coherence retraction records identifying which
               constraints were retracted due to absent required
               evidence. The frame is smaller than it would have been
               (the triggering units are absent), but fully coherent.
  Recovery:    None required by Context Assembly. The coherence
               retraction metadata signals retrieval/context
               misalignment. The coordinating subsystem may adjust the
               retrieval scope to gather the missing evidence and
               re-request assembly.

FM-4: Strategy Not Found
  Trigger:     No strategy exists for the requested context purpose,
               or the specified strategy version does not exist in the
               catalog.
  Detection:   Strategy resolution fails during phase 2 of the
               assembly lifecycle.
  Response:    The assembly request is rejected. No context frame is
               produced. A diagnostic identifies the missing purpose
               or version.
  Caller observes: A rejection with diagnostic. No frame.
  Recovery:    Register a strategy for the missing purpose (PC-2).
               If a version was specified, verify the version exists
               or omit the version to use the active strategy.

FM-5: Tier Degradation
  Trigger:     The evidence set contains no T2 evidence (AI
               unavailable) or no T1 evidence (rule engine
               unavailable).
  Detection:   During candidate identification, strata that select
               higher-tier evidence find no candidates.
  Response:    Context Assembly proceeds with available tiers. Strata
               that exclusively select unavailable tiers are empty.
               The frame's metadata reports the degradation level
               (full, T0+T1 only, T0 only).
  Caller observes: A valid context frame with reduced richness.
               Degradation level in metadata.
  Recovery:    None required. Degradation resolves when higher-tier
               evidence becomes available (semantic enrichment runs).

FM-6: Evidence Set Exceeds Budget Significantly
  Trigger:     The evidence set is many times larger than the budget
               (e.g., 500 units for a 40-unit budget). Elision ratio
               exceeds 90%.
  Detection:   After selection completes, elision count / evidence
               set size > 0.9.
  Response:    This is not a failure — it is the normal case for large
               codebases. Context Assembly's elision policy handles the
               reduction. The frame's metadata reports the elision
               ratio for observability.
  Caller observes: A valid context frame with high elision ratio in
               metadata. The frame contains the highest-priority
               evidence that fit within the budget.
  Recovery:    None required. High elision ratios may indicate the
               retrieval scope was too broad for the consumer's budget.
               Observable for diagnosis.

FM-7: Evidence Set Malformed
  Trigger:     The evidence set is structurally malformed: missing
               required fields on annotated units, absent epoch
               metadata, or other violations of DDS-005:PC-1
               guarantees.
  Detection:   Structural validation during precondition check
               (PRE-1).
  Response:    The assembly request is rejected. No context frame is
               produced. A diagnostic identifies the structural defect.
  Caller observes: A rejection with diagnostic. No frame.
  Recovery:    The caller must provide a valid evidence set. A
               malformed evidence set indicates a defect in the
               Retrieval Runtime or an invalid manual construction.
```

---

## Performance Requirements

Performance requirements are classified as follows:

- **Architectural requirement** — a bound mandated by DAS invariants
  or freshness contracts. Violation breaks an architectural guarantee.
- **Engineering target** — an initial numeric bound based on expected
  workload and reasoning, not yet validated by measurement. Must be
  validated through benchmarking before promotion to firm requirements.

```
PR-1: End-to-End Assembly Latency
  Operation:   Complete context assembly (all phases) for a typical
               assembly request
  Category:    Engineering target
  Bound:       Upper bound 10ms at alpha scale
  Assumptions: Evidence set ≤ 500 units. Strategy with ≤ 6 strata
               and ≤ 10 coherence constraints. Budget ≤ 1,000 units.
               All operations in memory — no I/O.
  Rationale:   Context assembly is on the critical path between
               retrieval and consumer invocation. Total latency
               (retrieval + assembly + consumer reasoning) must
               remain interactive. Retrieval is ≤50ms (DDS-005:PR-1).
               Consumer reasoning dominates at ~2-5 seconds. Assembly
               must be a negligible fraction. Validate by benchmarking
               representative assembly requests.

PR-2: Strategy Resolution Latency
  Operation:   Resolve purpose to strategy (catalog lookup)
  Category:    Engineering target
  Bound:       Upper bound 100μs
  Assumptions: Strategy catalog contains ≤ 20 strategies. O(1)
               hash-based lookup by purpose.
  Rationale:   Strategy resolution is the first step of assembly.
               Must be effectively instantaneous relative to
               selection.

PR-3: Selection Latency
  Operation:   Stratum-ordered selection across all strata for a
               single assembly request
  Category:    Engineering target
  Bound:       Upper bound 8ms at alpha scale
  Assumptions: Evidence set ≤ 500 units. ≤ 6 strata. Each stratum's
               candidate identification is O(N) over the evidence set.
               Candidate ordering is O(K log K) where K is the
               candidate count. Coherence checks are O(C) per
               candidate where C is the constraint count.
  Rationale:   Selection is the core computation. It must complete
               within the overall assembly budget. Validate by
               benchmarking with evidence sets at the upper bound of
               expected size.

PR-4: Strategy Validation Latency
  Operation:   Validate a strategy against all invariants (SI-1
               through SI-7) during registration
  Category:    Engineering target
  Bound:       Upper bound 5ms per strategy
  Assumptions: ≤ 6 strata. ≤ 10 coherence constraints. SI-4
               (constraint termination) requires cycle detection on
               a small graph. SI-2 (mutual exclusivity) requires
               pairwise comparison of ≤ 15 criteria pairs.
  Rationale:   Strategy validation occurs at registration, not on
               the assembly critical path. 5ms is acceptable even
               for batch registration of all strategies at startup.

PR-5: Assembly Memory
  Operation:   Peak memory consumption during a single assembly
               request
  Category:    Engineering target
  Bound:       Upper bound 500 KB per request at alpha scale
  Assumptions: Evidence set ≤ 500 units. Context budget ≤ 1,000
               units. ~330 bytes per context unit. Selection state
               ~100 KB.
  Rationale:   Assembly is request-scoped. Memory must be bounded.
               At alpha scale with sequential requests, 500 KB is
               negligible.
```

---

## Observability

The Context Assembly Runtime emits the following observable
information:

**Per-Assembly Metrics (DAS-009 OB-1).** For each completed assembly
request:
- Purpose and strategy version used.
- Evidence set size (input unit count).
- Context frame size (selected unit count).
- Budget: total, used, utilization ratio.
- Assembly duration.

**Selection Metrics (DAS-009 OB-2).** For each assembly:
- Per-stratum: candidates identified, candidates selected, candidates
  elided.
- Elision policy applied and units elided by each dimension (distance,
  confidence, stratum priority).
- Coherence constraints: fired, satisfied, retracted.

**Tier Distribution (DAS-009 OB-3).** For each context frame:
- Overall tier breakdown (T0, T1, T2 unit counts).
- Per-stratum tier breakdown.
- Degradation level.

**Budget Pressure (DAS-009 OB-4).** Aggregate statistics:
- Assemblies where budget was fully consumed (all strata filled or
  all budget used).
- Assemblies where budget was underutilized (<50% used).
- Assemblies where essential evidence flag triggered (FM-2).
- Average and maximum elision ratios.

**Coherence Health (DAS-009 OB-5).** Aggregate statistics:
- Assemblies with coherence violations (FM-3 count).
- Most frequently violated constraints (by constraint pattern).
- Most frequently retracted constraints (by stratum).

**Strategy Catalog Metrics.** Queryable on demand:
- Number of registered purposes.
- Number of active strategies and superseded versions.
- Per-strategy: stratum count, coherence constraint count, version
  history.

**Overhead.** Observability data collection does not block assembly
execution. Metrics are collected as side effects of normal operations
(counters incremented during selection, timestamps at phase
boundaries), not as separate processing steps.

---

## Testing Requirements

**Strategy validation tests (R2, SI-1 through SI-7):**
- A strategy with budget fractions summing to 1.0 is accepted.
- A strategy with budget fractions summing to 0.8 is rejected (SI-1).
- A strategy with budget fractions summing to 1.2 is rejected (SI-1).
- A strategy with overlapping selection criteria across two strata is
  rejected (SI-2).
- A strategy with two strata sharing the same priority is rejected
  (SI-3).
- A strategy with a cyclic coherence constraint graph is rejected
  (SI-4).
- A strategy with two essential strata is rejected (SI-5).
- Registering two strategies for the same purpose supersedes the
  prior version (SI-6).
- A strategy with a stratum whose selection criteria are logically
  unsatisfiable is rejected (SI-7).
- A strategy with all invariants satisfied is accepted and available
  for assembly.

**Strategy lifecycle tests:**
- A registered strategy is immediately available for assembly.
- A superseded strategy is no longer the active version.
- A superseded strategy is accessible via version override in assembly
  requests.
- Strategies are immutable — the catalog entry does not change after
  registration.

**Precondition tests (PRE-1 through PRE-4):**
- An assembly with a valid evidence set, registered purpose, and
  positive budget succeeds.
- An assembly with a malformed evidence set is rejected (PRE-1).
- An assembly with a mismatched intent/purpose produces a sparse
  frame with high elision, not a rejection (PRE-2).
- An assembly with zero budget is rejected (PRE-3).
- An assembly with a negative budget is rejected (PRE-3).
- An assembly with an unregistered purpose returns FM-4 (PRE-4).
- An assembly with a nonexistent strategy version returns FM-4
  (PRE-4).

**Selection tests (R1):**
- For a 2-stratum strategy (priority 1 and 2), stratum 1 is filled
  before stratum 2.
- A unit matching stratum 1's criteria appears in stratum 1, not
  stratum 2.
- A unit matching no stratum's criteria is excluded from the frame.
- Within a stratum, units are ordered per the fill policy.
- Ties within a fill policy are broken by ascending unit identifier.

**Budget enforcement tests (R3):**
- A frame with budget = 10 (unit count) contains at most 10 units.
- Unused budget from stratum 1 flows to stratum 2.
- Budget never flows upward: stratum 1 cannot use stratum 2's
  allocation.
- Budget exhaustion in stratum 1 leaves stratum 2 with only its
  allocation plus any overflow.
- Essential evidence is included before non-essential evidence.
- When essential evidence exceeds the budget, FM-2 flag is set.

**Coherence tests (R4):**
- Including a relationship edge triggers the coherence constraint
  requiring the target entity's identity.
- Both triggering unit and required unit are included when budget
  permits.
- When budget cannot accommodate both, neither is included
  (constraint retraction).
- A coherence constraint requiring a unit in a later stratum
  reserves that unit.
- A reserved unit is included when its stratum is processed.
- If the reserved unit's stratum cannot accommodate it, the
  triggering unit in the earlier stratum is removed.
- A coherence constraint whose required unit does not exist in the
  evidence set causes the triggering unit to be retracted (FM-3).
  The frame remains coherent — no triggering unit appears without
  its required unit.

**Elision tests (R5):**
- Stratum-first elision: lowest-priority strata are emptied before
  higher strata are reduced.
- Distance-first elision: within a stratum, furthest evidence is
  elided first.
- Confidence-first elision: within a stratum, lowest-confidence
  evidence is elided first.
- Proportional elision: all strata are reduced proportionally.

**Context role tests (R6):**
- Every context unit in the frame has a non-empty context role.
- Context roles accurately reflect the selection rationale (e.g.,
  "anchor primary signature," "callee identity for coherence").

**Grounding tests (R7):**
- Every context unit's grounding chain is identical to its source
  annotated unit's grounding chain.
- No grounding chain is modified, truncated, or stripped.

**Determinism tests (RI-4):**
- Two assemblies with identical inputs (evidence set, strategy
  version, budget) produce identical frames.
- Determinism holds across concurrent requests.
- Strategy version override produces the same frame as when that
  version was active.

**Tier degradation tests (R8, RI-8):**
- With T2 absent, assembly returns T0 and T1 evidence with metadata
  noting degradation.
- With T1 and T2 absent, assembly returns T0 evidence.
- T2 absence does not reduce T0 or T1 evidence in the frame.
- Degradation level is correctly reported in metadata.

**Context frame contract tests (CFI-1 through CFI-9):**
- Budget compliance: used ≤ total for every frame.
- Stratum partitioning: no unit appears in multiple strata.
- Coherence: all constraints satisfied or retracted.
- Epoch consistency: all units share the evidence set's epoch.
- Evidence soundness: every unit exists in the evidence set.
- Within-stratum ordering: matches fill policy.
- Priority ordering: no priority inversion.

**Failure mode tests (FM-1 through FM-7):**
- Empty evidence set produces empty frame with "no evidence"
  metadata.
- Budget insufficient for essential evidence produces partial frame
  with budgetInsufficient flag.
- Unsatisfiable coherence constraint retracts the triggering unit
  and records the retraction in metadata.
- Missing strategy returns FM-4 rejection.
- Tier degradation produces frame with degradation level metadata.
- High elision ratio is recorded in metadata.
- Malformed evidence set is rejected.

**Integration tests:**
- An end-to-end flow: DDS-005:PC-1 produces an evidence set → PC-1
  assembles a context frame. Verify frame invariants, stratum
  contents, and metadata consistency.
- An assembly during Index Runtime construction: evidence set
  contains fallback metadata → context frame propagates fallback
  metadata in freshness state.
- An assembly with strategy version override reproduces a prior
  frame given the same evidence set.
- Two concurrent assembly requests with different purposes produce
  independent, valid frames.

---

## Future Evolution

**Module Intelligence (DAS Roadmap Phase 2).** As Module Intelligence
introduces module-level entities, context strategies will include
strata for module-level evidence (module role, module cohesion,
cross-module relationships). The Context Assembly Runtime's
architecture is strategy-parameterized — new strata are defined in
new or updated strategy versions, not in new assembly infrastructure.
No architectural changes are needed.

**Project Intelligence (DAS Roadmap Phase 3).** System-scope context
frames will include system-level strata. The primary concern is
budget management: system-level evidence competes for budget with
entity-level and module-level evidence. The stratum priority
mechanism inherently resolves this competition — system-level strata
are assigned a priority, and the budget allocation determines their
share. Strategy tuning (budget fractions, stratum priorities) may be
needed; assembly mechanism changes are not.

**Strategy Composition (DAS-009 Q1).** If multi-purpose consumer
scenarios (e.g., follow-up after explanation) produce a combinatorial
explosion of strategies, a lightweight composition mechanism could
allow combining two strategies. The current design handles this with
dedicated strategies (the Follow-up strategy includes a "Prior
Context" stratum). If composition becomes necessary, it would be
specified as an extension to the strategy contract, not a change to
the assembly mechanism.

**Iterative Refinement (DAS-009 Q2).** The current design is
single-pass: one evidence set, one strategy, one frame. If
"re-request with a larger budget" becomes common, a refinement
mechanism could take the prior frame and adjustments as input. The
current stateless model handles this by constructing a new assembly
request. If refinement is needed, it would be an additional contract
(PC-4: Refinement) that accepts a prior frame reference and
adjustment parameters.

**Quality Estimation (DAS-009 Q3).** Context frame metadata currently
reports composition facts (tier distribution, budget utilization,
degradation level) but not a quality estimate. Heuristic quality
indicators (essential evidence present + T2 available + budget not
exhausted = high quality) could be added as a metadata field. This
would be a minor contract extension (new metadata field), not an
architectural change.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial draft
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions:
      (1) FM-3 coherence constraint unsatisfiable: retract triggering
          unit when required unit absent, preserving CFI-3 coherence
          invariant. Context Assembly never emits an incoherent frame.
      (2) Strategy snapshot semantics: assembly binds to one immutable
          strategy snapshot at phase 2; later registrations/supersessions
          never affect that assembly; reproducibility depends on this
          guarantee.
```
