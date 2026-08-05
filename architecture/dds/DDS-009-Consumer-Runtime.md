# DDS-009: Consumer Runtime

```
Document:      DDS-009
Title:         Consumer Runtime
Status:        Frozen
Version:       0.2
Author:        Principal Engineer
Reviewers:     —
Created:       2026-06-28
Last Revised:  2026-06-28
Depends On:    DDS-000 (Design Authoring Standard), DDS-006 (Context Assembly Runtime)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-009, DAS-011
```

## Abstract

This document specifies the engineering design of the Consumer Runtime — the subsystem that receives context frames from the Context Assembly Runtime (DDS-006) and applies purpose-specialized reasoning to produce understanding. It defines the consumer contract, the understanding contract, reasoning engine lifecycle, grounding and confidence propagation, conversation state management, consumer composition, failure handling, and observability. The Consumer Runtime realizes the consumer architecture defined in DAS-011. It is the terminal subsystem in the Decode pipeline: it consumes context frames and produces understanding for humans or machines. It does not read the DIR, does not query indexes, does not modify canonical data, and does not gather evidence.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P5 (intelligence is grounded — understanding preserves
            grounding via claim-to-context-unit references), P6
            (understanding is derived, not stored — consumers are
            stateless, understanding is transient), P7 (relevance over
            completeness — consumers produce purpose-responsive
            understanding, not exhaustive analysis), P8 (AI as consumer
            — reasoning engines consume context frames assembled from
            DIR, not raw source), P10 (scope scales independently —
            purpose is an independent axis; each purpose has its own
            reasoning engine), P11 (boundaries define independent
            variability — consumer contract enables reasoning engine
            replacement without affecting other engines or upstream
            subsystems), P12 (graceful degradation — consumers degrade
            when evidence or reasoning is limited, producing reduced
            understanding rather than nothing)
  Not addressed: P1 (DDS-002 — intelligence production), P2, P3, P4
                 (DDS-001, DDS-003 — execution ordering), P9 (DDS-001,
                 DDS-004 — incremental maintenance)

DAS-002: Decode Intermediate Representation
  Realized: Consumer contract (consumers read DIR content via retrieval
            and context assembly, do not write to DIR). Pipeline
            position (consumers are at the end of the pipeline).
  Not addressed: Atomic unit contract (DDS-002), lifecycle model
                (DDS-002), identity (DDS-002), immutability (DDS-002),
                DC-1 through DC-5 (DDS-002), I1 through I8 (DDS-002,
                DDS-001, DDS-004)

DAS-003: Tier Model
  Realized: Confidence propagation from tiers to understanding claims
            (CP-1 through CP-4 in DAS-011). Graceful degradation levels
            (missing tiers produce degraded understanding, not failure).
  Not addressed: I1 through I6 (DDS-002, DDS-001), tier assignment
                (DDS-002, DDS-003), TL-1, TL-2, TL-3 (DDS-002,
                DDS-008), freshness contracts (DDS-004, DDS-007)

DAS-009: Context Assembly
  Realized: Context frame consumption (ContextFrame as the sole input
            to consumers, per DAS-009 CL-1). Purpose alignment
            (consumer purpose matches context strategy purpose).
            Context freshness consumption (consumers report staleness
            when context epoch lags DIR epoch).
  Not addressed: Context strategy definition (DDS-006), stratum
                construction (DDS-006), evidence selection (DDS-006),
                budget management (DDS-006), coherence enforcement
                (DDS-006)

DAS-011: Consumer Architecture
  Realized: Contract-governed consumer architecture with purpose-
            specialized reasoning engines (decision). Consumer contract
            (CC-1 through CC-6). Understanding contract (UC-1 through
            UC-4). Reasoning boundary (RB-1 through RB-8). Grounding
            propagation (GP-1 through GP-3). Confidence propagation
            (CP-1 through CP-4). Consumer lifecycle (CL-1 through
            CL-6). Consumer composition (COMP-1 through COMP-4). All
            failure modes (FM-1 through FM-6). All observability
            requirements (OB-1 through OB-6). All invariants (I1
            through I8). All architectural consequences (C1 through
            C8).
  Not addressed: Specific reasoning engine implementations (out of DDS
                scope — implementation layer). Prompt design, model
                selection, inference frameworks (implementation layer).
                Question-to-purpose mapping (application layer).
                Rendering/display of understanding (presentation layer).
```

## Terminology

**Consumer** — A component that receives a context frame (DAS-009) and applies reasoning to produce understanding. A consumer is the point in the Decode pipeline where evidence becomes output: where structured, selected, bounded evidence is interpreted, synthesized, or analyzed to produce something a human or machine can act on. Consumers do not read source code, do not query the DIR, do not gather evidence, and do not assemble context. They receive a context frame and reason over it. `See DAS-011`

**Reasoning Engine** — The mechanism within a consumer that performs the transformation from context to understanding. A reasoning engine is an abstract capability — it may be implemented by an AI model, a deterministic rule system, a symbolic inference engine, a procedural algorithm, or any hybrid of these. The consumer contract defines what reasoning engines must satisfy; it does not prescribe what technology implements the contract. `See DAS-011`

**Understanding** — The output of consumer reasoning: a grounded, confidence-annotated, purpose-specific response that answers a question about software. Understanding is always derived from a specific context frame, at a specific point in time, for a specific purpose (DAS-001 P6). Understanding is transient — it is never the system of record. `See DAS-011`

**Consumer Request** — The input to a consumer: a context frame paired with an output specification and optional conversation state. The output specification declares what kind of understanding the consumer should produce, any constraints on the output, and the conversation context. `See DAS-011`

**Understanding Claim** — A discrete assertion within an understanding. Each claim is traceable to specific units in the context frame that support it. Claims are the mechanism by which understanding preserves grounding (DAS-001 P5). `See DAS-011`

**Conversation State** — An opaque, serializable, bounded record that carries the context of prior interactions in a conversation. Produced by each consumer invocation and passed as input to the next. Contains the minimum information needed for continuity — not a full transcript. Conversation state is transient runtime state: it exists only within the Consumer Runtime's process lifetime, is destroyed when the Consumer Runtime is destroyed, and is never persisted by the Storage Engine (DDS-008) or included in snapshots. `See DAS-011`

**Output Specification** — The portion of a consumer request that declares the output class (human-facing, machine-facing, or hybrid), output format, output constraints (maximum length, detail level), and conversation context (first question or follow-up). `See DAS-011`

**Reasoning Engine Registry** — The runtime registry of purpose-to-reasoning-engine mappings. Each purpose maps to exactly one active reasoning engine. The registry supports engine registration, resolution by purpose, and optional fallback engine designation. `INTRODUCED`

---

## Responsibilities

```
R1: Accept consumer requests and coordinate reasoning engine invocation.
    DAS: DAS-011 (consumer contract CC-1 through CC-6, consumer
         lifecycle CL-1 through CL-3)
    Boundary: The Consumer Runtime receives consumer requests,
              validates inputs, dispatches to the appropriate reasoning
              engine, verifies grounding on output, and returns
              understanding. It does not gather evidence (DDS-005),
              does not assemble context (DDS-006), and does not
              determine which purpose to use for a given user question
              (application layer).

R2: Own and manage the reasoning engine registry — register, resolve,
    and replace purpose-specialized reasoning engines.
    DAS: DAS-011 CC-4 (consumers are purpose-specialized), DAS-011
         C1 (adding a capability is adding a reasoning engine),
         C2 (replacing technology is replacing the engine)
    Boundary: The Consumer Runtime validates and serves reasoning
              engine registrations. It does not implement reasoning
              engines — engines are developed and registered by
              capability implementors. It does not determine which
              engine to use — purpose determines the engine.

R3: Enforce the consumer contract on all reasoning engine outputs.
    DAS: DAS-011 CC-1 through CC-6 (consumer contract rules),
         UC-1 through UC-4 (understanding contract)
    Boundary: The Consumer Runtime verifies that every understanding
              produced by a reasoning engine conforms to the contract:
              grounding completeness (UC-1), confidence appropriateness
              (UC-2), claim extractability (UC-3), completeness honesty
              (UC-4). It does not perform reasoning — it validates
              reasoning output.

R4: Propagate grounding from context frame units to understanding
    claims.
    DAS: DAS-011 GP-1 (grounding is mandatory), GP-2 (grounding is
         verifiable), GP-3 (grounding coverage is reported), DAS-001
         P5 (intelligence is grounded)
    Boundary: The Consumer Runtime ensures that every claim in the
              understanding references at least one context frame unit
              (Level 4 of the grounding chain). It does not verify the
              downstream chain (context unit → DIR unit → source
              material) — those links are established by DDS-006,
              DDS-005, and DDS-002 respectively.

R5: Propagate confidence from context frame tiers to understanding
    claims.
    DAS: DAS-011 CP-1 (tier-to-confidence mapping), CP-2 (confidence
         is monotonically non-increasing), CP-3 (degradation is
         communicated), CP-4 (confidence is granular, not aggregate)
    Boundary: The Consumer Runtime enforces that claim confidence
              does not exceed the tier of the grounding evidence.
              It does not assign tiers to evidence — tiers are
              carried through from the DIR (DDS-002) via retrieval
              (DDS-005) and context assembly (DDS-006).

R6: Manage conversation state across multi-turn interactions.
    DAS: DAS-011 CL-4 (conversation state is opaque to the pipeline),
         CL-5 (conversation state is bounded), CL-6 (conversations
         are recoverable), DAS-011 I7 (conversation state boundedness)
    Boundary: The Consumer Runtime passes conversation state between
              invocations. It does not inspect or modify conversation
              state — it is produced by reasoning engines and consumed
              by subsequent invocations. The Consumer Runtime enforces
              the boundedness constraint (CL-5).

R7: Coordinate consumer composition for multi-step reasoning.
    DAS: DAS-011 COMP-1 (sequential composition as pipeline), COMP-2
         (composition preserves consumer contract), COMP-3 (composition
         failures are isolated), COMP-4 (independent invocations are
         parallelizable)
    Boundary: The Consumer Runtime executes composition pipelines
              where each step is a standard consumer invocation. It
              does not define compositions — compositions are defined
              by capability implementors as sequences of purpose-
              invocations. It requests appropriate context frames from
              context assembly for each sub-purpose.

R8: Provide per-invocation observability.
    DAS: DAS-011 OB-1 through OB-6 (observability requirements),
         DAS-011 I8 (failure produces diagnostic output)
    Boundary: The Consumer Runtime emits per-invocation metrics
              (reasoning duration, grounding coverage, claim
              distribution, failure events, completeness assessment,
              conversation statistics). Aggregation and dashboarding
              are outside scope.

R9: Emit consumer demand signals describing degraded or insufficient
    understanding to the Update Engine.
    DAS: DAS-010 RS-6 (consumer-demand recomputation), DAS-011 CC-6
         (consumers degrade gracefully — degraded context frames may
         trigger demand for fresh T2 content)
    Boundary: When a consumer request receives a context frame with
              degraded T2 content (invalidated T2 units present), the
              Consumer Runtime emits a demand signal describing which
              entities have degraded or insufficient T2 content. The
              Consumer Runtime never schedules recomputation, never
              prioritizes recomputation, and never determines when or
              whether recomputation occurs. It emits demand signals
              only — advisory descriptions of observed degradation.
              All scheduling decisions are exclusively owned by the
              Update Engine (DDS-007). The demand signal is the
              Consumer Runtime's sole outbound effect on the pipeline.
    DDS-INTERNAL: This contract supports DAS-010 RS-6 (consumer-demand
                  recomputation triggers) and DAS-011 CC-6 (graceful
                  degradation with demand signaling). The Consumer
                  Runtime is the natural location for demand signaling
                  because it observes the degradation level at the point
                  of consumption and can assess whether the missing T2
                  content would materially improve the understanding.
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Consumer Invocation
  Direction:    Offered
  Counterparty: Application layer (coordinators, composition
                framework), scheduling subsystem
  Guarantee:    Given a consumer request (context frame + output
                specification + optional conversation state), the
                Consumer Runtime produces an understanding.

                The consumer request specifies:
                - Context frame: the output of DDS-006:PC-1. A
                  complete, bounded, purpose-calibrated context frame
                  carrying all invariants (CFI-1 through CFI-9).
                - Output specification: purpose, output class (human,
                  machine, hybrid), output constraints (maxLength,
                  detailLevel, formatRequirements).
                - Conversation state (optional): the conversation
                  state from a prior invocation for follow-up
                  continuity. Nil for first interactions.

                The understanding satisfies:
                - Every claim references at least one context frame
                  unit (DAS-011 UC-1, GP-1).
                - Claim confidence does not exceed the tier of the
                  grounding evidence (DAS-011 UC-2, CP-2).
                - Claims are extractable from content (DAS-011 UC-3).
                - Completeness is honestly reported (DAS-011 UC-4).

                The understanding contains:
                - Content: purpose-specific output in the format
                  appropriate to the output class.
                - Claims: discrete assertions with grounding references,
                  confidence levels, and claim types (factual, derived,
                  interpretive, inferred).
                - Metadata: purpose, output class, engine identifier,
                  context frame epoch, degradation level, reasoning
                  duration, grounding coverage, tier distribution,
                  completeness assessment.
                - Conversation state (optional): for follow-up
                  continuity. Nil if no conversation is active.

  Preconditions: The Consumer Runtime is in Available state. The
                 context frame is well-formed (satisfies DDS-006:PC-1
                 output contract). The output specification specifies
                 a recognized purpose. A reasoning engine is registered
                 for the specified purpose.
  Failure mode: See Failure Handling (FM-1 through FM-7). No failure
                mode produces an undiagnosable error — all produce
                either a valid (possibly degraded) understanding with
                diagnostic metadata, a failure response with the
                failure mode and diagnostic context, or a fallback
                understanding from a secondary reasoning engine.

PC-2: Reasoning Engine Registration
  Direction:    Offered
  Counterparty: Application startup, capability registration subsystem
  Guarantee:    Given a reasoning engine and its purpose identifier,
                the Consumer Runtime registers the engine in the
                reasoning engine registry. The registered engine is
                immediately available for consumer requests referencing
                its purpose.

                Registration includes:
                - Purpose identifier: the consumer purpose this engine
                  serves.
                - Engine identifier: a unique, stable identifier for
                  the reasoning engine (includes version).
                - Fallback designation (optional): whether this engine
                  is a fallback for another engine's purpose. If
                  designated as fallback, it is invoked when the
                  primary engine fails (FM-1).

                If an engine already exists for the same purpose, the
                new engine replaces the prior engine. The prior engine
                is no longer invoked for new requests. In-progress
                invocations using the prior engine complete normally.

  Preconditions: The Consumer Runtime has been created.
  Failure mode: If the purpose identifier is malformed or the engine
                is nil, registration is rejected with a diagnostic.
                The registry is unchanged.

PC-3: Reasoning Engine Catalog Query
  Direction:    Offered
  Counterparty: Diagnostic consumers, observability, application layer
  Guarantee:    Returns the current reasoning engine registry: for
                each registered purpose, the active engine (with
                identifier and version), any designated fallback
                engine, and engine-reported capability metadata
                (supported output classes, supported detail levels).
  Preconditions: None.
  Failure mode: None. The registry is always queryable — it may be
                empty if no engines have been registered.

PC-4: Consumer Demand Signal
  Direction:    Offered
  Counterparty: Update Engine (DDS-007, via DDS-007:PC-2)
  Guarantee:    When the Consumer Runtime observes degraded or
                insufficient T2 content in a context frame, it emits
                a demand signal to the Update Engine. The signal
                describes the observed degradation: the entity
                identifiers whose T2 content is invalidated or absent.

                The signal is strictly advisory. The Consumer Runtime
                does not schedule recomputation, does not prioritize
                recomputation, does not determine when recomputation
                occurs, and does not influence the Update Engine's
                scheduling decisions. All scheduling authority —
                priority ordering (DDS-007 SP-1 through SP-4), queue
                management, execution timing — belongs exclusively
                to the Update Engine (DDS-007). The Consumer Runtime
                emits demand descriptions; the Update Engine decides
                what to do with them.

                The Consumer Runtime does not block on recomputation
                completion. The current invocation proceeds with the
                available (possibly degraded) context frame.

                Consumer demand signals are deduplicated: repeated
                signals for the same entity within a configurable
                window are coalesced into a single demand.
  Preconditions: The Update Engine is in Operational state
                 (DDS-007 state model).
  Failure mode: If the Update Engine is not available (during startup
                or shutdown), the demand signal is discarded. The
                consumer invocation proceeds normally with degraded
                content. No error is surfaced — demand signaling is
                best-effort.
```

### Required Contracts

```
PC-5: Context Frame
  Direction:    Required
  Counterparty: Context Assembly Runtime (DDS-006, via DDS-006:PC-1)
  Guarantee:    The Consumer Runtime receives context frames as input
                to consumer requests. The context frame satisfies
                DDS-006:PC-1 guarantees: CFI-1 (budget compliance),
                CFI-2 (stratum partitioning), CFI-3 (coherence),
                CFI-4 (determinism), CFI-5 (grounding integrity),
                CFI-6 (priority ordering), CFI-7 (evidence soundness),
                CFI-8 (epoch consistency), CFI-9 (within-stratum
                ordering).
  Preconditions: The Context Assembly Runtime is in Available state.
                 The context frame was produced by a completed assembly
                 request.
  Failure mode: If the context frame is structurally malformed
                (missing required fields, absent metadata, violated
                invariants), the consumer request is rejected with
                FM-2 (validation failure).

PC-6: Deferred Recomputation Request
  Direction:    Required
  Counterparty: Update Engine (DDS-007, via DDS-007:PC-2)
  Guarantee:    The Consumer Runtime can submit advisory demand signals
                to the Update Engine describing invalidated T2 units
                encountered in context frames. The Update Engine
                exclusively owns all scheduling decisions — it
                determines priority (DDS-007 SP-3), timing, and
                whether to act on the signal at all. The Consumer
                Runtime has no visibility into or influence over the
                scheduling outcome.
  Preconditions: The Update Engine is in Operational state.
  Failure mode: If the Update Engine is not available, the demand
                signal is discarded. The consumer invocation proceeds
                with degraded content.
```

---

## Lifecycle

### Creation

The Consumer Runtime is created during application startup, after the Context Assembly Runtime (DDS-006) is available.

**Preconditions for creation:** The Context Assembly Runtime is in Available state.

**No persistent state.** The Consumer Runtime has no persistent state. The reasoning engine registry is populated during startup via PC-2 and is session-scoped. No consumer state, conversation state, or understanding survives across restarts.

### Startup

After creation, the Consumer Runtime registers reasoning engines via PC-2. Engines may be registered in any order. The runtime enters Available state once at least one reasoning engine is registered. It may also enter Available state with an empty registry — consumer requests will fail with FM-6 (engine not found) until engines are registered.

**Startup sequence:** Consumer Runtime creation → reasoning engine registration (one or more) → Available state → consumer requests accepted.

### Operation

The Consumer Runtime processes consumer requests (PC-1) and engine registrations (PC-2) during operation. Each consumer invocation is independent — no state is shared between invocations. Engine registrations may occur during operation (dynamic capability addition or engine replacement).

**Operational invariant:** Every understanding returned by the Consumer Runtime satisfies the understanding contract (UC-1 through UC-4) and the consumer contract (CC-1 through CC-6).

### Quiescence

When the application is shutting down:

1. No new consumer requests are accepted.
2. In-progress consumer invocations complete (including any active reasoning engine execution).
3. No cleanup is required — per-invocation resources are released upon completion.

**Quiescence ordering:** The Consumer Runtime quiesces before the Context Assembly Runtime (DDS-006) and the Retrieval Runtime (DDS-005). The upstream subsystems remain available for any in-progress invocations that are completing.

### Destruction

The Consumer Runtime is destroyed during application teardown. The reasoning engine registry is discarded. Active reasoning engine references are released.

**Destruction ordering:** The Consumer Runtime is destroyed before the Context Assembly Runtime (DDS-006). The destruction follows the pipeline's reverse order: Consumer Runtime → Context Assembly Runtime → Retrieval Runtime → Index Runtime → Update Engine → Storage Engine → DIR Runtime.

---

## State Model

The Consumer Runtime occupies one of three states:

```
Unavailable → Available → Terminated
```

**Unavailable.** The Consumer Runtime has been created but is not yet ready to process consumer requests. The Context Assembly Runtime may not yet be available, or no reasoning engines have been registered.

**Available.** The Consumer Runtime processes consumer requests and engine registrations. The engine registry may have engines for only a subset of purposes — requests for unregistered purposes fail with FM-6, but the subsystem is available.

**Terminated.** The Consumer Runtime has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Unavailable | Available | Context Assembly Runtime available | Consumer requests accepted |
| Available | Terminated | Shutdown signal and all in-progress invocations complete | Registry discarded |

**Invalid transitions:** Unavailable → Terminated (must become Available first or be destroyed without having operated). Terminated → any state. Available → Unavailable (once available, remains available until shutdown — loss of Context Assembly Runtime during operation is a failure mode, not a state transition).

---

## Execution Model

### Consumer Invocation Lifecycle

A consumer invocation passes through six phases (DAS-011 CL-1 through CL-3):

1. **Validation.** Validate the consumer request:
   - Context frame is well-formed (required fields present, strata non-empty or explicitly empty with metadata).
   - Context frame's purpose matches the output specification's purpose.
   - Essential evidence is present (purpose-specific — an explain consumer requires the anchor's identity; an impact consumer requires at least one dependency edge).
   - Conversation state, if present, is well-formed and within the boundedness limit.
   If validation fails, produce a validation failure (FM-2) without invoking the reasoning engine.

2. **Engine resolution.** Resolve the output specification's purpose to a reasoning engine via the engine registry. If no engine is registered for the purpose, produce FM-6 (engine not found).

3. **Reasoning.** Invoke the resolved reasoning engine with the context frame, output specification, and conversation state. The reasoning engine applies purpose-specific reasoning per its implementation (RB-1 through RB-4) and produces raw understanding output.

4. **Grounding verification.** Verify that every claim in the reasoning engine's output has at least one grounding reference to a context frame unit (UC-1, GP-1). For each claim:
   - If grounded: the claim is valid.
   - If ungrounded: the claim is removed from the understanding. The removal is recorded in metadata.
   If all claims are ungrounded, produce a grounding failure (FM-3).

5. **Confidence verification.** Verify that each claim's confidence does not exceed the tier of its grounding evidence (CP-2). For each claim:
   - Determine the highest (least deterministic) tier in the claim's grounding set.
   - Confirm the claim's confidence level does not exceed the confidence associated with that tier.
   - If confidence is inflated: the claim's confidence is capped at the appropriate level. The adjustment is recorded in metadata.

6. **Understanding production.** Assemble the final understanding: content, verified claims, metadata (purpose, output class, engine identifier, context frame epoch, degradation level, reasoning duration, grounding coverage, tier distribution, completeness), and conversation state. Return the understanding.

**Invocation atomicity (DAS-011 CL-3).** A consumer invocation either succeeds (produces a valid understanding) or fails (produces a failure response with diagnostic context). There is no partial state.

### Reasoning Engine Invocation

The Consumer Runtime invokes reasoning engines through a uniform contract:

**Input:** The reasoning engine receives the context frame, the output specification, and the conversation state. It does not receive any other data — no DIR access, no index queries, no file system access (RB-5, RB-6).

**Output:** The reasoning engine produces raw understanding: content, claims with grounding references, confidence assessments, completeness assessment, and conversation state for follow-up continuity (RB-4).

**Isolation.** Each reasoning engine invocation is isolated. The reasoning engine does not maintain state between invocations (CC-3, I3). Two invocations with identical inputs produce equivalent outputs (within the non-determinism bounds of the reasoning technology).

**Resource bounds.** The Consumer Runtime enforces a resource budget on reasoning engine execution: maximum wall-clock time, and any engine-specific resource limits (token budget for AI engines, inference step limit for symbolic engines). If the resource budget is exhausted, the Consumer Runtime terminates the invocation and produces a partial understanding from whatever the engine produced before exhaustion (FM-4).

### Consumer Demand Signaling

When the Consumer Runtime receives a consumer request with a context frame containing degraded T2 content:

1. **Assess degradation.** Examine the context frame metadata for degradation level. If degradation level > 0 and invalidated T2 units are present in the context frame, the Consumer Runtime considers signaling demand.

2. **Evaluate demand.** If the output specification indicates a purpose that would materially benefit from T2 content (e.g., explain, improve — purposes that synthesize semantic understanding), signal demand. If the purpose is purely structural (e.g., a deterministic analysis that uses only T0/T1), do not signal.

3. **Signal.** Emit an advisory demand signal to the Update Engine (PC-6 → DDS-007:PC-2) describing the entity identifiers whose T2 content is invalidated. The signal describes observed degradation — it does not request, schedule, or prioritize recomputation. The Update Engine (DDS-007) exclusively owns all scheduling decisions.

4. **Proceed.** Continue the consumer invocation with the available context frame. The current invocation produces understanding from the degraded context frame — it does not wait for recomputation.

Demand signaling is asynchronous, advisory, and best-effort. The consumer invocation always completes with the context frame it was given. The Consumer Runtime has no knowledge of whether or when the Update Engine acts on a demand signal.

### Conversation Management

Conversations are sequences of consumer invocations sharing a logical thread (DAS-011 CL-4 through CL-6):

**Conversation state flow.** Each invocation receives conversation state from the prior invocation and produces new conversation state for the next:

```
Invocation 1: Request(contextFrame₁, spec₁, nil)
              → Understanding₁ + ConversationState₁

Invocation 2: Request(contextFrame₂, spec₂, ConversationState₁)
              → Understanding₂ + ConversationState₂
```

**Boundedness enforcement (DAS-011 I7).** The Consumer Runtime enforces a size limit on conversation state. If a reasoning engine produces conversation state exceeding the limit, the Consumer Runtime truncates or summarizes the state to fit within the bound. The truncation preserves the most recent key claims and anchors.

**Conversation state corruption (DAS-011 FM-5).** If conversation state from a prior invocation is malformed or incompatible with the current reasoning engine version, the Consumer Runtime discards the state and processes the request as a new conversation. Continuity is lost but the invocation succeeds.

**Conversation state opacity (DAS-011 CL-4).** The Consumer Runtime does not inspect conversation state content — it enforces boundedness and validates structural well-formedness, but the semantic content is opaque. Only the reasoning engine reads and writes the conversation state content.

### Consumer Composition

Complex capabilities are composed as sequences of consumer invocations (DAS-011 COMP-1 through COMP-4):

**Sequential composition.** A composition defines a sequence of purpose-invocations. Each invocation receives a context frame assembled for its sub-purpose and the prior invocation's understanding via conversation state:

```
Step 1: Request context frame for sub-purpose A → Consumer invocation A
        → Understanding A

Step 2: Request context frame for sub-purpose B (with Understanding A
        carried in conversation state) → Consumer invocation B
        → Understanding B
```

**Composition orchestration.** The composition framework (application layer) is responsible for:
1. Requesting the appropriate context frame from context assembly (DDS-006:PC-1) for each sub-purpose.
2. Passing the prior understanding via conversation state to the next invocation.
3. Returning the final understanding from the composition's last step.

**Composition contract preservation (DAS-011 COMP-2).** Each step in a composition is a standard consumer invocation. The Consumer Runtime does not differentiate between standalone invocations and composition steps. Every step satisfies the consumer contract.

**Composition failure isolation (DAS-011 COMP-3).** If a step in a composition fails, the composition can:
- Return partial results (the understanding from steps that succeeded).
- Attempt fallback (substitute a simpler reasoning engine for the failed step).
- Abort the composition (return a failure response indicating which step failed).

The Consumer Runtime reports the failure; the composition framework decides the recovery strategy.

**Parallel composition (DAS-011 COMP-4).** When two steps in a composition do not depend on each other's output, the Consumer Runtime can execute them in parallel. Each parallel invocation is a standard consumer invocation. The composition framework merges the parallel understandings.

### Concurrency Model

**Per-invocation isolation.** Each consumer invocation is independent. Multiple invocations may execute concurrently — they share no mutable state. The reasoning engine registry is read-only during invocations (writes via PC-2 are serialized with reads).

**Reasoning engine concurrency.** The Consumer Runtime does not constrain how many concurrent invocations a reasoning engine handles. This is an engine-specific concern — an AI-based engine may be limited by API rate limits; a deterministic engine may handle unlimited concurrency.

**Demand signal concurrency.** Consumer demand signals (PC-4) are fire-and-forget. They do not block the consumer invocation. Multiple concurrent invocations may signal demand for the same entity — the deduplication window (PC-4) coalesces redundant signals.

---

## Memory and Ownership

### Owned State

**Reasoning engine registry.** Maps purpose identifiers to reasoning engine references and optional fallback designations. Owned exclusively by the Consumer Runtime. Session-scoped — discarded at shutdown.

Memory footprint: one entry per registered purpose. At alpha scale (~5 purposes): negligible (<1 KB). At practical limit (~50 purposes): negligible (<10 KB).

**Demand deduplication window.** Tracks recently signaled entity identifiers to prevent redundant demand signals. Owned exclusively by the Consumer Runtime. Window entries expire after a configurable duration (default: 30 seconds).

Memory footprint: one entry per signaled entity. At alpha scale: negligible (<10 KB). At practical limit (~1,000 concurrent entities): <100 KB.

### Borrowed State

**Context frame (per invocation).** Borrowed from the caller for the duration of a single invocation. The Consumer Runtime reads the context frame but does not modify it. Released after the invocation completes.

**Conversation state (per invocation).** Borrowed from the caller for the duration of a single invocation. The Consumer Runtime passes it to the reasoning engine, which reads it and produces new conversation state. The incoming state is not modified.

### Transient State

**Per-invocation working memory.** Each consumer invocation allocates transient memory for reasoning engine execution, grounding verification, and understanding assembly. Released after the invocation completes.

Memory footprint per invocation: proportional to the context frame size and the understanding size. At alpha scale: <1 MB per invocation (context frame ~10 KB, understanding ~50 KB, reasoning engine working memory ~500 KB for AI-based engines). At practical limit: <5 MB per invocation.

### Memory Bounds

**Total Consumer Runtime memory (excluding per-invocation).** <1 MB at all scales. The reasoning engine registry and demand deduplication window are negligible.

**Per-invocation memory.** <5 MB per invocation at practical limit. With maximum concurrency (~10 concurrent invocations at alpha): <50 MB total. The Consumer Runtime's memory footprint is dominated by reasoning engine working memory, which varies by engine type.

---

## Failure Handling

```
FM-1: Reasoning Engine Failure
  Trigger:     The reasoning engine encounters an error during
               invocation (AI service unavailable, rule engine
               exception, inference timeout, internal error).
  Detection:   The reasoning engine returns an error, throws an
               exception, or exceeds its resource budget.
  Response:    If a fallback reasoning engine is designated for the
               purpose (via PC-2 fallback designation), the Consumer
               Runtime invokes the fallback engine with the same
               consumer request. Fallback engines are typically simpler
               (e.g., a deterministic engine that produces structural
               understanding from T0/T1 evidence without AI). If no
               fallback is designated, or the fallback also fails, the
               Consumer Runtime produces a failure response with the
               failure reason, the engine identifier, and the context
               frame's anchor identifiers for diagnostic context.
  Caller observes: Either a degraded understanding (from fallback
               engine) with metadata indicating fallback was used, or
               a failure response with diagnostic context.
  Recovery:    The next invocation retries with the primary engine.
               The Consumer Runtime does not maintain failure state
               across invocations — each invocation attempts the
               primary engine first.

FM-2: Validation Failure
  Trigger:     The consumer request fails validation — context frame
               is malformed (missing required fields, absent metadata),
               purpose mismatch between context frame and output
               specification, or essential evidence is absent for the
               specified purpose.
  Detection:   Validation phase (phase 1 of invocation lifecycle).
  Response:    The Consumer Runtime produces a validation failure
               response without invoking the reasoning engine. The
               response identifies which validation check failed and
               what was missing or mismatched.
  Caller observes: A failure response with the specific validation
               violation and diagnostic context. No understanding is
               produced.
  Recovery:    The caller corrects the request (e.g., assembles a
               context frame with the correct purpose, provides
               missing evidence) and resubmits.

FM-3: Grounding Failure
  Trigger:     The reasoning engine produces claims that cannot be
               grounded to context frame units. All claims in the
               output are ungrounded.
  Detection:   Grounding verification phase (phase 4 of invocation
               lifecycle).
  Response:    If some claims are grounded and others are not, the
               ungrounded claims are removed and the understanding is
               produced with the grounded claims plus metadata
               indicating removed claims. If all claims are ungrounded,
               the Consumer Runtime produces a grounding failure
               response — the reasoning engine's output is entirely
               unverifiable.
  Caller observes: Either a partial understanding (with grounded claims
               only and metadata noting removed ungrounded claims), or
               a failure response indicating total grounding failure.
  Recovery:    For partial understanding: the caller receives usable
               output. For total grounding failure: the caller may
               retry (the reasoning engine may produce different
               output on retry for non-deterministic engines), or
               invoke a different purpose's engine.

FM-4: Reasoning Budget Exhaustion
  Trigger:     The reasoning engine's execution exceeds its resource
               budget (wall-clock timeout, token limit for AI engines,
               inference step limit for symbolic engines).
  Detection:   Resource monitoring during reasoning engine execution.
  Response:    The Consumer Runtime terminates the reasoning engine
               invocation and produces partial understanding from
               whatever the engine produced before budget exhaustion.
               The understanding metadata indicates budget exhaustion
               and reports the completeness as partial.
  Caller observes: A partial understanding with metadata indicating
               budget exhaustion. The understanding contains the claims
               produced before termination.
  Recovery:    The caller may accept the partial understanding or
               retry with a higher resource budget.

FM-5: Conversation State Corruption
  Trigger:     The conversation state from a prior invocation is
               malformed (structural validation failure) or
               incompatible with the current reasoning engine version.
  Detection:   Validation phase (phase 1 — structural validation) or
               reasoning engine (version incompatibility).
  Response:    The Consumer Runtime discards the conversation state
               and processes the request as a new conversation (first
               invocation). Continuity is lost but the invocation
               succeeds. Metadata indicates that conversation state
               was discarded.
  Caller observes: An understanding produced as if this were the first
               invocation in a conversation. Metadata indicates state
               discard.
  Recovery:    The conversation continues from this point as a new
               thread. Prior context is lost. The caller may attempt
               to re-establish context by providing a richer context
               frame.

FM-6: Reasoning Engine Not Found
  Trigger:     No reasoning engine is registered for the specified
               purpose.
  Detection:   Engine resolution phase (phase 2 of invocation
               lifecycle).
  Response:    The Consumer Runtime produces a failure response
               indicating that no engine is registered for the
               requested purpose. The response includes the requested
               purpose and the list of available purposes (from the
               engine registry).
  Caller observes: A failure response with the missing purpose and
               available alternatives. No understanding is produced.
  Recovery:    Register a reasoning engine for the purpose (PC-2) and
               retry the request.

FM-7: Context Staleness
  Trigger:     The context frame's epoch (carried in context frame
               metadata) is older than the current DIR epoch — the
               underlying intelligence has changed since the context
               was assembled.
  Detection:   Comparison of the context frame's committed epoch
               against the current DIR epoch (observable via the
               Update Engine's epoch state).
  Response:    The consumer invocation proceeds normally — staleness
               does not prevent reasoning. The understanding metadata
               includes a staleness flag indicating that the context
               frame's epoch is behind the current DIR epoch. The
               Consumer Runtime may also signal consumer demand (PC-4)
               for entities whose T2 content is invalidated.
  Caller observes: A valid understanding with a staleness flag in
               metadata. The caller can decide whether to accept the
               stale understanding or request a fresh context frame.
  Recovery:    The caller requests a new context frame from context
               assembly (which will observe the current committed
               epoch) and resubmits the consumer request.
```

---

## Performance Requirements

### Architectural Requirements

**PR-1: Consumer invocations do not write to the DIR.** Consumer invocations are read-only operations at the end of the pipeline. They do not modify the DIR, do not trigger pass execution, and do not affect index state (DAS-011 I6, RB-5, RB-6).

**PR-2: Consumer invocations are independently retriable.** Because consumers are stateless (CC-3, I3), any invocation can be retried with the same input without side effects. Failed invocations do not corrupt any system state.

**PR-3: Grounding verification does not exceed the invocation's reasoning time.** Grounding verification (phase 4) is a scan of claims and their references — it should complete in time proportional to the number of claims, not to the size of the context frame.

### Engineering Targets

**ET-1: Consumer invocation overhead (excluding reasoning).** Target: <10 ms for validation, engine resolution, grounding verification, confidence verification, and understanding assembly combined. The Consumer Runtime's overhead should be negligible compared to reasoning engine execution time.

**ET-2: Reasoning engine invocation latency.** Not specified by this DDS — reasoning engine latency is engine-specific and varies by technology. For reference: AI-based engines at alpha (DAS-011 compatible): 1-5 seconds. Deterministic engines: <50 ms.

**ET-3: Consumer demand signal latency.** Target: <5 ms from degradation assessment to demand signal submission. Demand signaling is asynchronous and must not delay the consumer invocation.

**ET-4: Conversation state validation.** Target: <1 ms for structural validation and boundedness check. Conversation state operations must not introduce perceptible latency.

**ET-5: Grounding verification latency.** Target: <5 ms for a typical understanding (~20 claims, ~50 grounding references). Proportional to claim count, not context frame size.

---

## Observability

**OB-1: Reasoning duration.** For each consumer invocation: total wall-clock time, reasoning engine execution time (excluding validation and verification overhead), engine identifier, purpose. Long durations indicate reasoning engine performance issues or excessive context frame complexity.

**OB-2: Grounding coverage.** For each understanding: the fraction of context frame units referenced by at least one understanding claim. Persistently low coverage indicates context strategy misalignment — the context assembly provides evidence the consumer doesn't use. Persistently high coverage indicates good alignment. Per DAS-011 GP-3.

**OB-3: Claim distribution.** For each understanding: count of claims by type (factual, derived, interpretive, inferred) and by confidence level. Distributions skewed toward interpretive claims in contexts with abundant T0 evidence indicate reasoning engines that over-interpret. Distributions skewed toward factual claims in contexts with T2 evidence indicate reasoning engines that under-synthesize. Per DAS-011 OB-3.

**OB-4: Failure rate.** For each reasoning engine: frequency and type of failures (FM-1 through FM-7), fallback invocation rate, fallback success rate. High FM-1 (engine failure) rates for a specific engine indicate engine instability. High FM-2 (validation failure) rates indicate context assembly misalignment. Per DAS-011 OB-4.

**OB-5: Completeness distribution.** For each purpose: frequency of complete, partial, and insufficient understandings. High insufficiency rates indicate that the context strategy for that purpose is not providing adequate evidence, or that the reasoning engine's expectations exceed what the DIR can provide. Per DAS-011 OB-5.

**OB-6: Conversation statistics.** Average conversation length, conversation abandonment rate (conversations with exactly one invocation), follow-up frequency per purpose, conversation state discard rate (FM-5 frequency). Short conversations with immediate follow-ups may indicate insufficient first understanding. Per DAS-011 OB-6.

**OB-7: Consumer demand metrics.** Consumer demand signals emitted (count per purpose), deduplication rate (signals coalesced), demand-to-recomputation latency (time from signal to fresh T2 availability, observed on subsequent invocations), purposes that most frequently trigger demand.

---

## Runtime Invariants

**RI-1: Grounding Completeness (DAS-011 I1).**
- **Statement:** Every understanding claim references at least one context frame unit. No claim in any understanding produced by the Consumer Runtime is ungrounded.
- **Rationale:** An ungrounded claim is unverifiable — it cannot be traced to evidence, cannot be audited, and cannot be debugged. Ungrounded claims violate DAS-001 P5 and break the end-to-end traceability chain from understanding to source material.
- **Verification:** For each understanding, enumerate all claims. For each claim, confirm at least one grounding reference exists and that the referenced unit exists in the context frame.

**RI-2: Confidence Monotonicity (DAS-011 I2).**
- **Statement:** No understanding claim has higher confidence than the evidence it is grounded in. A claim grounded in T2 evidence cannot have factual (T0-level) confidence.
- **Rationale:** Confidence inflation misleads consumers of understanding. If a reasoning engine claims factual confidence for an interpretation based on semantic evidence, the consumer of the understanding will treat it as a deterministic fact — which it is not.
- **Verification:** For each claim, determine the highest tier in its grounding set. Confirm that the claim's confidence level does not exceed the confidence associated with that tier.

**RI-3: Consumer Statelessness (DAS-011 I3).**
- **Statement:** No consumer maintains state between invocations. Two consumer invocations with identical consumer requests produce equivalent understandings (within the non-determinism bounds of the reasoning technology).
- **Rationale:** Stateful consumers create hidden dependencies — the output of invocation N depends not only on the request but on hidden state left by invocations 1 through N-1. Statelessness ensures that every invocation is independent and reproducible.
- **Verification:** Invoke the same consumer with identical requests at different times. Confirm outputs are structurally equivalent (same claims, same grounding, same confidence).

**RI-4: Purpose-Response Alignment (DAS-011 I4).**
- **Statement:** Every understanding addresses the purpose specified in the consumer request. An explain understanding contains explanatory content. An impact understanding contains impact analysis. No understanding addresses a purpose different from the one requested.
- **Rationale:** A consumer that produces impact analysis when asked for explanation has failed — even if the analysis is correct. Purpose alignment ensures utility.
- **Verification:** For each understanding, confirm that its content addresses the requested purpose. Purpose-specific validation criteria apply.

**RI-5: Context Frame Sufficiency Honesty (DAS-011 I5).**
- **Statement:** When the context frame lacks evidence the reasoning engine needs for complete understanding, the understanding reports completeness as partial or insufficient. No understanding claims completeness when the evidence was insufficient.
- **Rationale:** False completeness claims cause consumers of understanding to make decisions based on incomplete information without knowing it is incomplete.
- **Verification:** Inject context frames with known evidence gaps. Confirm the produced understanding reports partial or insufficient completeness.

**RI-6: No DIR Side Effects (DAS-011 I6).**
- **Statement:** Consumer invocations do not modify the DIR, do not modify indexes, do not trigger pass execution, and do not produce atomic units. Consumer demand signals (PC-4) are the sole outbound effect, and they do not modify DIR state — they request scheduling of future work.
- **Rationale:** Consumers are on the read side of the pipeline. If consumers wrote to the DIR, the system would have a read-write cycle creating non-determinism and potential infinite loops. The pipeline is unidirectional.
- **Verification:** Monitor DIR, index, and pass state before and after consumer invocations. Confirm no changes.

**RI-7: Conversation State Boundedness (DAS-011 I7).**
- **Statement:** Conversation state size does not grow unboundedly with conversation length. Each invocation produces conversation state of bounded size, regardless of the number of prior invocations.
- **Rationale:** Unbounded conversation state eventually exceeds the reasoning engine's processing capacity, causing failure at unpredictable conversation depth.
- **Verification:** Conduct conversations of increasing length (10, 50, 100 turns). Measure conversation state size at each turn. Confirm it remains below a defined bound.

**RI-8: Failure Diagnostic Completeness (DAS-011 I8).**
- **Statement:** Every consumer failure (FM-1 through FM-7) produces a diagnostic response that identifies the failure mode, the failed component, and sufficient context for debugging. No failure produces a silent error or an ambiguous response.
- **Rationale:** Silent failures are the most expensive failures — they produce incorrect or absent output without indicating what went wrong.
- **Verification:** Trigger each failure mode. Confirm that the response identifies the mode, the component, and the diagnostic context.

**RI-9: Conversation State Transience.**
- **Statement:** Conversation state is transient runtime state. It exists only within the Consumer Runtime's process lifetime. It is destroyed when the Consumer Runtime is destroyed. Conversation state is never persisted by the Storage Engine (DDS-008), never included in snapshots, and never survives process restarts. No subsystem other than the Consumer Runtime holds or manages conversation state.
- **Rationale:** Conversation state is a derivative of understanding, which is itself derived from the DIR (DAS-001 P6 — understanding is derived, not stored). Persisting conversation state would create a secondary system of record outside the DIR, violating the canonical asset principle (DAS-001 P1). After a restart, conversations begin fresh — the DIR and its intelligence survive via snapshots (DDS-008), but conversations do not.
- **Verification:** Confirm that the Storage Engine's snapshot contents (DDS-008:PC-1) do not include conversation state. Confirm that after Consumer Runtime destruction and re-creation, no conversation state from the prior lifetime is accessible. Confirm that no other subsystem (DDS-001 through DDS-008) references, stores, or manages conversation state.

---

## Testing Requirements

### Contract Tests

- PC-1 (Consumer Invocation): Given a well-formed consumer request with a valid context frame, the Consumer Runtime produces an understanding that satisfies UC-1 (grounding), UC-2 (confidence), UC-3 (extractability), and UC-4 (completeness honesty). The understanding contains content, claims with grounding references, and complete metadata.
- PC-2 (Engine Registration): Registering an engine for a purpose makes it available for consumer requests referencing that purpose. Replacing an engine for the same purpose makes the new engine active. In-progress invocations using the prior engine complete normally.
- PC-3 (Engine Catalog Query): The catalog query returns the current state of the engine registry, including active engines, fallback designations, and purpose mappings.
- PC-4 (Consumer Demand Signal): When a consumer request processes a context frame with degraded T2 content, a demand signal is emitted to the Update Engine. Repeated signals for the same entity within the deduplication window are coalesced.

### State Model Tests

- Unavailable → Available transition occurs during startup when the Context Assembly Runtime becomes available and at least one reasoning engine is registered.
- Available → Terminated transition occurs during shutdown, with all in-progress invocations completed.
- Consumer requests fail with FM-6 when no engine is registered for the requested purpose, even when the Consumer Runtime is in Available state.
- Engine registration (PC-2) is accepted in both Unavailable and Available states.

### Failure Mode Tests

- FM-1: Simulate reasoning engine failure. Confirm fallback engine is invoked when designated. Confirm failure response when no fallback exists. Confirm the next invocation retries with the primary engine.
- FM-2: Submit a consumer request with a malformed context frame (missing strata, absent metadata). Confirm validation failure response identifying the specific violation.
- FM-3: Produce a reasoning engine output with all claims ungrounded. Confirm grounding failure response. Produce output with some claims grounded and some not — confirm partial understanding with ungrounded claims removed.
- FM-4: Configure a reasoning engine with a tight resource budget. Submit a request that exceeds it. Confirm partial understanding with budget exhaustion metadata.
- FM-5: Submit a consumer request with corrupted conversation state. Confirm the invocation succeeds as a new conversation with metadata indicating state discard.
- FM-6: Submit a consumer request for an unregistered purpose. Confirm failure response listing available purposes.
- FM-7: Submit a consumer request with a context frame at an older epoch than the current DIR epoch. Confirm the understanding is produced with a staleness flag.

### Invariant Tests

- **RI-1 (Grounding Completeness):** For every understanding produced by any reasoning engine, verify that every claim has at least one grounding reference to a unit that exists in the input context frame. No understanding may contain ungrounded claims.
- **RI-2 (Confidence Monotonicity):** For every claim, verify that claim confidence does not exceed the tier of the grounding evidence. A claim grounded in T2 units must not have factual confidence.
- **RI-3 (Consumer Statelessness):** Invoke the same reasoning engine with identical consumer requests at different times. Verify structural equivalence of outputs (same claims, same grounding, same confidence — possibly different phrasing for non-deterministic engines).
- **RI-4 (Purpose-Response Alignment):** Submit requests with different purposes. Verify each understanding addresses the requested purpose. Cross-purpose contamination (explain understanding containing improvement suggestions) must not occur.
- **RI-5 (Context Frame Sufficiency Honesty):** Submit context frames with known evidence gaps (e.g., missing T2 content for an explain purpose). Verify the understanding reports partial or insufficient completeness.
- **RI-6 (No DIR Side Effects):** Monitor DIR, index, and pass state before and after 100 consumer invocations. Verify zero modifications to any canonical state. Consumer demand signals (PC-4) are permitted — they are scheduling requests, not state modifications.
- **RI-7 (Conversation State Boundedness):** Conduct a 100-turn conversation. Verify conversation state size remains below a defined bound at every turn.
- **RI-8 (Failure Diagnostic Completeness):** Trigger each failure mode (FM-1 through FM-7). Verify each failure response includes the failure mode identifier, the failed component, and sufficient diagnostic context to reproduce the issue.
- **RI-9 (Conversation State Transience):** Verify that the Storage Engine's snapshot (DDS-008:PC-1) does not contain conversation state. Destroy and re-create the Consumer Runtime; verify no conversation state from the prior lifetime is accessible. Verify no other subsystem stores conversation state.

### Integration Tests

- End-to-end pipeline: File change → synchronous pipeline → epoch advancement → retrieval → context assembly → consumer invocation → understanding produced with correct grounding to evidence derived from the changed file.
- Consumer demand: Context frame with invalidated T2 content → consumer invocation → demand signal emitted → Update Engine schedules T2 recomputation → deferred epoch → subsequent consumer invocation receives context frame with fresh T2 content → understanding quality improves.
- Conversation continuity: First question → understanding + conversation state → follow-up question with prior conversation state → second understanding reflects conversation context.
- Fallback reasoning: Primary reasoning engine failure → fallback engine produces degraded understanding → metadata indicates fallback was used → degradation level reflects the simpler engine's capability.
- Composition: Multi-step composition (understand → assess) → each step produces a valid understanding → final understanding incorporates claims from all steps → grounding chain traces through intermediate understandings to context frame units.
- Graceful degradation: Context frame with T0 only (no T1, no T2) → consumer produces structural understanding → completeness reported as partial → claims are all factual confidence.

---

## Future Evolution

**Purpose-adaptive engine selection.** At scale, a single reasoning engine per purpose may be insufficient. The natural evolution: multiple engines per purpose with adaptive selection based on context frame characteristics (evidence volume, tier distribution, degradation level). The engine registry contract (PC-2) supports multiple engines per purpose — the selection logic is an evolution of the resolution phase (phase 2).

**Understanding caching.** Understanding is currently transient — produced and discarded after consumption. At scale, caching understanding keyed by context frame content hash and purpose could avoid redundant reasoning for identical evidence. The consumer contract's determinism guarantee (RI-3) enables caching for deterministic engines. AI-based engines produce non-deterministic output, limiting cache applicability. This is a performance optimization — no contract changes needed.

**Quality feedback loop.** The current architecture reports compositional metrics (grounding coverage, claim distribution, completeness). A quality feedback loop would correlate these metrics with user satisfaction signals (follow-up rate, conversation abandonment, explicit feedback) to tune reasoning engine parameters and context strategy alignment. This requires user-facing feedback mechanisms not yet defined.

**Structured grounding annotations.** DAS-011 Q1 identifies an open question about structured vs. free-form grounding references. The current contract requires grounding references — it does not prescribe the format. Evolution toward structured references (typed pointers to specific context unit IDs) would enable automated grounding verification and claim-level staleness detection.

**Reasoning engine capability declarations.** The current contract requires reasoning engines to report completeness (complete, partial, insufficient) after reasoning. An evolution would require engines to declare upfront what kinds of context frames they can fully process — e.g., "this engine requires at least 3 strata with at least one T2 unit" — enabling pre-invocation routing or graceful pre-invocation fallback. No existing contracts would be affected. Capability declarations would be additional metadata on engine registration (PC-2). Monitor completeness reports in production; if certain engines frequently report insufficient completeness for predictable context frame profiles, capability declarations would enable pre-invocation routing.

**Speculative claim type.** The current contract (RB-7 in DAS-011) prohibits claims beyond the evidence. A future evolution could define a "speculative" claim type: claims the reasoning engine believes are likely but cannot ground to specific units. Speculative claims would be explicitly labeled, carry no confidence, and be presented as hypotheses — not assertions. This would require a DAS-011 amendment to relax RB-7 for the speculative claim type specifically, and a corresponding relaxation of RI-1 (grounding completeness) for speculative claims. Evaluate during alpha whether speculative claims improve utility for investigation-purpose understanding.

---

## Revision History

```
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions.
    (1) Clarified consumer demand ownership: strengthened R9, PC-4, PC-6,
    and Consumer Demand Signaling execution model to explicitly state that
    the Consumer Runtime never schedules recomputation, only emits advisory
    demand signals describing degraded or insufficient understanding. All
    scheduling decisions exclusively owned by the Update Engine (DDS-007).
    (2) Added RI-9 (Conversation State Transience): conversation state is
    transient runtime state, destroyed with the Consumer Runtime, never
    persisted by the Storage Engine (DDS-008), never included in snapshots.
    Updated Conversation State terminology definition. (3) Moved Q1
    (capability envelope declarations) and Q2 (speculative reasoning) from
    Open Questions to Future Evolution — both represent future capabilities,
    not unresolved engineering decisions. Open Questions section removed
    (no remaining questions). Nine runtime invariants (RI-1 through RI-9).

0.1 — 2026-06-28 — Principal Engineer — Initial specification of the
    Consumer Runtime. Realizes DAS-011 (Consumer Architecture) as the
    subsystem owning consumer invocation, reasoning engine lifecycle,
    grounding and confidence verification, conversation state management,
    consumer composition, and consumer demand signaling. Depends on
    DDS-006 (Context Assembly Runtime). Six offered and required contracts
    (PC-1 through PC-6). Nine responsibilities. Three-state model
    (Unavailable, Available, Terminated). Seven failure modes. Seven
    observability concerns. Eight runtime invariants. Two open questions.
    Completes the DDS subsystem specification: all DAS-defined subsystems
    now have corresponding DDS documents (DDS-001 through DDS-009).
```
