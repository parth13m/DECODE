# DAS-011: Consumer Architecture

```
Chapter:       DAS-011
Title:         Consumer Architecture
Status:        Frozen
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003, DAS-006, DAS-008, DAS-009
Depended By:   DAS-012
Supersedes:    —
Superseded By: —
Layer:         L4
```

## Abstract

This chapter defines the consumer architecture — how structured context is transformed into understanding. A consumer receives a context frame (DAS-009) and produces understanding: a grounded, confidence-annotated, purpose-specific output that answers a question about software. Consumers are the point in the pipeline where reasoning occurs. This chapter defines reasoning as an abstract capability — not a specific technology. A reasoning engine may be deterministic, semantic, symbolic, or hybrid. The architecture is agnostic to the reasoning technology and must function identically regardless of what performs the reasoning. This chapter defines what a consumer is, what it receives, what it produces, what invariants it honors, how understanding inherits grounding and confidence from the context frame, how conversations span multiple consumer invocations, and how consumers are composed. It selects a contract-governed consumer architecture with purpose-specialized reasoning engines over monolithic, strategy-parameterized, and capability-composed alternatives.

## Motivation

DAS-009 defines context assembly — how an evidence set is transformed into a bounded, coherent, purpose-calibrated context frame. But context is not understanding. A context frame containing 40 organized units about function `authenticate` — its signature, callees, behavioral characterization, design role — is evidence prepared for reasoning. It is not an explanation. It is not an improvement suggestion. It is not an impact analysis. The gap between context and understanding is the consumer architecture.

Without this chapter, five problems arise:

1. **The boundary between context and understanding is undefined.** Context assembly produces a context frame. Something consumes it and produces output. What is that something? What contract does it obey? What properties must its output have? Without a defined consumer contract, the transformation from context to output is ad hoc — each consumer implements its own interpretation of what a context frame means, what reasoning to apply, and what the output should look like. The result is inconsistency across capabilities: the explain consumer interprets grounding one way, the impact consumer interprets it another, and the improvement consumer ignores it entirely.

2. **Reasoning is conflated with reasoning technology.** If the architecture assumes that reasoning is performed by an AI model, then AI availability becomes an architectural dependency. When AI is unavailable, no reasoning occurs and no understanding is produced — violating DAS-001 P12 (graceful degradation). When a new reasoning technology becomes available (a symbolic reasoner, a deterministic rule engine, a hybrid system), integrating it requires architectural changes rather than adding a new reasoning engine behind an existing contract. The architecture must treat reasoning as an abstract capability, not a technology binding.

3. **Understanding has no contract.** The system produces outputs: explanations, improvement suggestions, impact analyses, investigation results, action plans. Each output has different structure, different content, different confidence guarantees. Without a unifying understanding contract, there is no way to guarantee that all outputs share essential properties: grounding (traceability to evidence), confidence (reliability assessment), provenance (what produced this output and from what input), and staleness (whether the underlying intelligence has changed since the output was produced). Without these guarantees, consumers of understanding (humans, other systems, downstream agents) cannot assess the quality of what they receive.

4. **Follow-up interactions have no model.** A user asks "what does this function do?" and receives an explanation. Then asks "what would break if I renamed it?" The second question requires the first question's context — but the consumer that produced the explanation is gone. Without an architectural model for conversation continuity, follow-up interactions are either impossible (each question is independent) or ad hoc (the consumer maintains hidden state that the architecture cannot manage, invalidate, or observe).

5. **Consumer composition is unaddressed.** An improvement suggestion requires both understanding (what the code does) and assessment (what could be better). An autonomous agent requires understanding, assessment, planning, and action generation. These are not single reasoning operations — they are compositions of multiple reasoning steps. Without a composition model, complex capabilities either implement everything monolithically (duplicating the explain logic within the improvement consumer) or are built ad hoc (chaining consumers without a defined contract for how outputs flow between them).

**Source dependencies:**
- [DAS-001 P1](DAS-001-Architectural-Principles.md) — intelligence is the canonical asset; understanding is derived from it
- [DAS-001 P5](DAS-001-Architectural-Principles.md) — intelligence is grounded; understanding must preserve grounding
- [DAS-001 P6](DAS-001-Architectural-Principles.md) — understanding is derived, not stored
- [DAS-001 P7](DAS-001-Architectural-Principles.md) — relevance over completeness
- [DAS-001 P8](DAS-001-Architectural-Principles.md) — AI is a consumer of intelligence, not its source of truth
- [DAS-001 P10](DAS-001-Architectural-Principles.md) — scope scales along independent axes; perspective is an independent dimension
- [DAS-001 P11](DAS-001-Architectural-Principles.md) — boundaries define independent variability
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — consumer contract (reads DIR via retrieval and context assembly, does not write to DIR), pipeline position
- [DAS-003](DAS-003-Tier-Model.md) — tier definitions, confidence model, graceful degradation levels
- [DAS-009](DAS-009-Context-Assembly.md) — context frame contract (ContextFrame, FilledStratum, ContextUnit, ContextBudget, ContextFrameMetadata), context strategy, purpose-stratified architecture

## Terminology

**Consumer** — A component that receives a context frame (DAS-009) and applies reasoning to produce understanding. A consumer is the point in the Decode pipeline where evidence becomes output: where structured, selected, bounded evidence is interpreted, synthesized, or analyzed to produce something a human or machine can act on. Consumers do not read source code, do not query the DIR, do not gather evidence, and do not assemble context. They receive a context frame and reason over it. *Is:* a component that receives a context frame about function `authenticate` assembled for an explain purpose and produces a human-readable explanation of what `authenticate` does, why it exists, and how it works. *Is not:* a retrieval engine (that gathers evidence); context assembly (that selects and organizes evidence); a pass (that produces DIR content); a rendering layer (that formats understanding for display). `INTRODUCED`

**Reasoning Engine** — The mechanism within a consumer that performs the transformation from context to understanding. A reasoning engine is an abstract capability — it may be implemented by an AI model, a deterministic rule system, a symbolic inference engine, a procedural algorithm, or any hybrid of these. The consumer architecture defines the contract that reasoning engines must satisfy; it does not prescribe what technology implements the contract. *Is:* the component that, given a context frame, produces an explanation, an impact analysis, an improvement suggestion, or an action plan. *Is not:* a specific AI model (GPT, Claude, Gemini); a specific inference framework; a specific rule engine. `INTRODUCED`

**Understanding** — The output of consumer reasoning: a grounded, confidence-annotated, purpose-specific response that answers a question about software. Understanding is always derived from a specific context frame, at a specific point in time, for a specific purpose (DAS-001 P6). Understanding is transient — it is never the system of record. If the underlying intelligence changes, the understanding is stale and must be regenerated. *Is:* "function `authenticate` validates credentials against the auth service, returns a session token, and is the sole entry point for user authentication in this module — here is why, and here are the evidence sources." *Is not:* the context frame (which is evidence, not understanding); a cached explanation (which is a stale derivative); intelligence (which is the canonical asset from which understanding is derived). `INTRODUCED`

**Consumer Request** — The input to a consumer: a context frame paired with an output specification. The output specification declares what kind of understanding the consumer should produce, any constraints on the output (format, length, detail level), and the conversation context (if this is a follow-up interaction). *Is:* "here is an explain-purpose context frame about function `authenticate` — produce a human-readable explanation at detail level 'standard', this is the first question in a new conversation." *Is not:* a retrieval request (which parameterizes evidence gathering); a context strategy (which parameterizes evidence selection). `INTRODUCED`

**Understanding Claim** — A discrete assertion within an understanding. Each claim is traceable to specific units in the context frame that support it. Claims are the mechanism by which understanding preserves grounding (DAS-001 P5): every statement in the understanding can be traced to evidence, which can be traced to the DIR, which can be traced to source material. *Is:* "authenticate delegates credential validation to AuthService.verify" — grounded in the `calls` relationship unit between `authenticate` and `AuthService.verify` in the context frame. *Is not:* ungrounded assertions; opinions; claims that reference evidence not present in the context frame. `INTRODUCED`

**Conversation** — A sequence of consumer invocations that share a logical thread. Each invocation in a conversation has access to the prior invocations' understanding and context via the conversation state, which is carried in the consumer request — not maintained within the consumer. Conversations enable follow-up questions, iterative refinement, and multi-turn interactions. *Is:* "what does this function do?" followed by "what would break if I renamed it?" — two invocations sharing the context of the first explanation. *Is not:* consumer state (consumers are stateless); a session (which is a scope-level concept in the application layer); a stored history (conversation state is transient). `INTRODUCED`

**Conversation State** — An opaque, serializable record that carries the context of prior interactions in a conversation. Conversation state is produced by each consumer invocation and passed as input to the next. It contains the minimum information needed for the next invocation to maintain continuity — typically the prior understanding's key claims, the prior context frame's anchors, and the conversational thread. Conversation state is not a full transcript. *Is:* "the prior question was about function `authenticate`, the explanation covered its purpose and callee structure, the key claims were X, Y, Z." *Is not:* a full copy of all prior context frames; a transcript of all prior outputs; consumer-internal state. `INTRODUCED`

**Output Specification** — The portion of a consumer request that declares what kind of understanding to produce. An output specification includes the output class (human-facing or machine-facing), the output format (natural language, structured data, action plan), output constraints (maximum length, detail level), and the conversation context (first question or follow-up). *Is:* "produce a human-facing explanation in natural language, maximum 500 words, detail level 'standard', no prior conversation." *Is not:* a context strategy (which governs evidence selection); a prompt (which is an implementation detail of AI-based reasoning engines). `INTRODUCED`

## Domain Analysis

### The Reasoning Problem

The Decode pipeline produces structured evidence about software: entities, relationships, classifications, and semantic characterizations, organized into purpose-calibrated context frames. But evidence is not understanding. Understanding requires reasoning — the cognitive or computational process of interpreting evidence, synthesizing patterns, resolving ambiguities, and producing output that answers a question.

The reasoning problem has five sub-problems:

**Sub-problem 1: What is reasoning, architecturally?** Reasoning is the transformation of evidence into output. Given a context frame containing the function's signature, its callees, its behavioral characterization, and its scope role, reasoning produces "this function validates user credentials by delegating to the auth service and returning a session token." The transformation is not mechanical (that would be formatting) and it is not retrieval (that has already occurred). It is interpretation: the reasoning engine must understand the relationships between the evidence units, resolve their implications, and compose them into a coherent answer. This interpretation may be performed by an AI model, a rule engine, a symbolic reasoner, or a human. The architecture must abstract over the implementation.

**Sub-problem 2: What makes understanding valid?** Not all outputs of reasoning are valid understanding. An explanation that claims "this function handles payment processing" when the context frame contains no payment-related evidence is invalid — it is a hallucination (in the case of AI) or an error (in the case of a rule engine). Valid understanding has three properties: it is **grounded** (every claim traces to evidence in the context frame), it is **confidence-appropriate** (claims derived from T0 evidence are presented as facts; claims derived from T2 evidence are presented as interpretations), and it is **purpose-responsive** (it addresses the question that was asked, not a different question).

**Sub-problem 3: How does understanding relate to the DIR's tiered intelligence?** The context frame contains units at different tiers: T0 structural facts, T1 derived classifications, T2 semantic characterizations. The reasoning engine must handle this heterogeneity. A claim based entirely on T0 evidence ("this function takes two parameters") has different confidence than a claim synthesizing T2 evidence ("this function exists to work around a framework limitation"). The understanding must propagate this tier information — not as raw tier labels (which are meaningless to human consumers) but as appropriate confidence framing: certainty for deterministic facts, assessment for derived properties, interpretation for semantic claims.

**Sub-problem 4: How do conversations work without consumer state?** DAS-001 P6 states that understanding is derived, not stored. But conversations require continuity — the second question depends on the first answer. If consumers are stateless (as the pipeline model suggests), conversation continuity must be carried externally. DAS-009 defines a Follow-up Context Strategy that includes prior context in the new frame. But this handles only the context side — the understanding side (what was previously said, what thread the conversation is following) must also be carried. The consumer architecture must define how conversation state flows through the pipeline.

**Sub-problem 5: When reasoning fails, what happens?** Reasoning engines can fail: an AI model returns an error, a rule engine encounters an unhandled case, a symbolic reasoner exceeds its inference budget. The architecture must define failure semantics: does the consumer return nothing? A partial result? A fallback output from a simpler reasoning engine? DAS-001 P12 (graceful degradation) requires that failure produces reduced output, not no output.

### Consumer Classification

Consumers differ along three independent axes:

**Axis 1: Purpose.** What question is the consumer answering? Explain, improve, investigate, analyze impact, plan refactoring, execute actions. Purpose determines which context strategy was used (DAS-009) and what the understanding should contain. Purpose is the primary differentiator between consumers.

**Axis 2: Output class.** Who or what receives the understanding? Human-facing consumers produce output for human cognition: natural language, visualizations, annotated code. Machine-facing consumers produce output for programmatic consumption: structured data, typed results, action specifications. Hybrid consumers produce output consumed by both (a structured analysis with human-readable annotations).

**Axis 3: Reasoning technology.** How does the consumer reason? AI-based reasoning uses a language model or inference service. Deterministic reasoning applies rules or algorithms. Symbolic reasoning uses logic or constraint solving. Hybrid reasoning combines multiple approaches (deterministic analysis augmented by AI synthesis). The architecture must not constrain this axis — adding a new reasoning technology must not require architectural changes.

These axes are independent (DAS-001 P10): an explain consumer may be human-facing with AI reasoning, or machine-facing with deterministic reasoning (producing a structured summary from T0/T1 evidence without AI). An impact consumer may be machine-facing with deterministic reasoning (traversing dependency chains) or human-facing with AI reasoning (producing a narrative impact assessment). The architecture must support all combinations.

### The Grounding Requirement

DAS-001 P5 requires that every intelligence claim traces to source material. The consumer architecture extends this requirement to understanding: every claim in the understanding must trace to the context frame, which traces to the evidence set (DAS-008), which traces to the DIR (DAS-002), which traces to source material.

This creates a four-level traceability chain:

```
Understanding Claim
  → Context Frame Unit (why this claim was made)
    → DIR Atomic Unit (what evidence supports it)
      → Source Material (where the evidence comes from)
```

The consumer architecture is responsible for the first link: connecting understanding claims to context frame units. The downstream links are already established by DAS-009, DAS-008, and DAS-002.

Grounding is not optional. An understanding that cannot be traced to evidence is architecturally invalid — it may be factually correct, but it is unverifiable and undebuggable. When understanding is wrong, the grounding chain is the diagnostic path: the claim traces to a context unit, the unit traces to a DIR fact, the fact traces to source — and the error is identifiable.

### Consumer-Independent Pipeline

The pipeline upstream of the consumer is consumer-independent:

```
Question → Retrieval Request → Retrieval → Evidence Set → Context Assembly → Context Frame
```

The context frame is the handoff point. Everything before it is governed by DAS-002 through DAS-009. Everything after it — reasoning, understanding production, conversation management — is governed by this chapter.

The consumer does not know how the context frame was assembled. It does not know which indexes were queried, which retrieval stages executed, which evidence was elided. It receives the context frame as a self-describing contract (DAS-009 CF-1) and reasons over it. This boundary enables independent variability (DAS-001 P11): context assembly can change how evidence is selected without affecting consumers; consumers can change how they reason without affecting context assembly.

## Candidates

This section evaluates four candidate architectures for the consumer layer.

### Candidate A: Monolithic Consumer

A single consumer component handles all purposes. It receives the context frame and a purpose parameter, and internally dispatches to purpose-specific reasoning logic. All reasoning technology, output formatting, and conversation management is encapsulated in the monolithic consumer.

**Strengths:** Simple deployment — one component to manage. Shared infrastructure (context parsing, output formatting, error handling) is implemented once. No inter-consumer communication needed.

**Weaknesses:** Violates DAS-001 P11 (boundaries define independent variability). Adding a new purpose requires modifying the monolithic consumer. Upgrading the reasoning technology for one purpose (e.g., switching the explain purpose from AI to a hybrid engine) requires changing the same component that serves all other purposes. Testing is coupled — a change to impact analysis logic risks breaking explanation logic. The monolithic consumer cannot use different reasoning technologies for different purposes without internal technology multiplexing (selecting AI for explain, deterministic for impact), which is consumer composition without the architectural clarity.

**Disqualifying condition:** Violates P11. Both sides of the consumer boundary (context assembly on one side, understanding rendering on the other) must be able to evolve independently. A monolithic consumer couples all purposes into one evolution unit, eliminating independent variability along the purpose axis.

### Candidate B: Strategy-Parameterized Consumer

A single consumer architecture with purpose-specific reasoning strategies, mirroring the strategy pattern in DAS-009. Each purpose provides a reasoning strategy that parameterizes the consumer's behavior. The consumer itself is a generic reasoning framework; the strategy provides purpose-specific logic.

**Strengths:** Mirrors DAS-009's architecture — consistent conceptual model. Adding a new purpose requires a new strategy, not a new consumer. Shared framework (context interpretation, grounding tracking, output formatting) is implemented once.

**Weaknesses:** The strategy metaphor is misleading. A context strategy (DAS-009) is a data parameterization — it defines strata, selection criteria, and budget fractions. These are declarative specifications that the assembly algorithm interprets. A reasoning strategy would need to define *how to reason* — which is procedural, not declarative. A declarative specification of reasoning ("first analyze the signature, then interpret the callees, then synthesize the behavioral characterization into a narrative") is either so detailed that it is the reasoning implementation, or so vague that it provides no value. Reasoning varies along a fundamentally different dimension than context selection: context selection varies by what to include; reasoning varies by how to think.

**Disqualifying condition:** The strategy pattern requires that the parameterization is separable from the execution. For context assembly, this works — strata, priorities, and criteria are data that the assembly algorithm processes. For reasoning, the parameterization *is* the execution — the reasoning logic differs fundamentally between explaining a function, analyzing impact, and planning a refactoring. Forcing these differences into a strategy parameterization produces either a trivial strategy (that just names the purpose) or an over-constrained one (that prescribes reasoning steps the architecture cannot enforce).

### Candidate C: Capability-Composed Consumer

Consumers are composed from reusable reasoning capabilities: "interpret entities," "synthesize relationships," "assess quality," "generate narrative," "produce structured output." Each capability is a small, reusable component. A consumer is a composition of capabilities assembled for a specific purpose: the explain consumer composes entity interpretation + relationship synthesis + narrative generation; the impact consumer composes entity interpretation + dependency traversal + structured output.

**Strengths:** Maximum reuse — capabilities shared across purposes. Fine-grained independent variability — each capability can evolve independently. The composition model expresses multi-step reasoning naturally.

**Weaknesses:** The decomposition granularity is wrong. "Interpret entities" is not a reusable capability that means the same thing across purposes — entity interpretation for explanation (describe what the entity does) is fundamentally different from entity interpretation for improvement (identify what could be better about the entity). The apparent reuse is illusory: each capability must be purpose-parameterized, which reduces to Candidate B with finer granularity. The composition model also creates a coordination problem: when capability A produces output that capability B consumes, what is the contract between them? This is a secondary pipeline within the consumer, with its own contract management overhead.

**Disqualifying condition:** Illusory reuse. The capabilities that are actually shared (parsing the context frame, tracking grounding, formatting output) are infrastructure, not reasoning capabilities. The capabilities that are purpose-specific (how to reason about entities, how to synthesize relationships) are not reusable across purposes without purpose-parameterization — which collapses to Candidate B.

### Candidate D: Contract-Governed Consumer with Purpose-Specialized Reasoning Engines

Define a consumer contract: what a consumer receives (context frame + output specification), what it produces (understanding), what invariants it must honor (grounding, confidence, purpose-responsiveness), and what lifecycle it follows. Each purpose is served by a purpose-specialized reasoning engine that conforms to the consumer contract. Reasoning engines are independently developed, tested, deployed, and replaced. The consumer architecture defines the contract; reasoning engines implement it.

**Strengths:** Clean architectural boundary: the consumer contract is stable, reasoning engines vary. Satisfies P11 — each reasoning engine can evolve independently. Different engines can use different reasoning technologies without architectural changes. The contract guarantees consistent properties across all understanding outputs (grounding, confidence, provenance) regardless of the engine that produced them. Adding a new purpose requires adding a new reasoning engine — no existing engines are affected.

**Weaknesses:** The contract must be precisely specified — vague contracts produce vague compliance. Each reasoning engine independently implements contract-mandated behaviors (grounding tracking, confidence propagation), which creates potential duplication. However, this duplication is infrastructure that can be provided as a shared library without architectural coupling.

**Disqualifying condition:** None identified.

## Evaluation

| Criterion | Monolithic (A) | Strategy-Parameterized (B) | Capability-Composed (C) | Contract-Governed (D) |
|-----------|---------------|---------------------------|------------------------|----------------------|
| Independent variability (P11) | **No** — all purposes coupled | Partial — strategies decouple purposes from framework | Partial — capabilities decouple, composition couples | **Yes** — each engine independent |
| Reasoning technology agnosticism | No — one technology serves all | Partial — strategy constrains technology | Yes — per-capability technology | **Yes** — per-engine technology |
| New purpose addition cost | Modify monolith | Add strategy | Compose capabilities | **Add engine** |
| Contract consistency | Ad hoc | Framework-enforced | Capability-interface-enforced | **Contract-enforced** |
| Composition support | Internal dispatch | Strategy composition (undefined) | Native (but illusory reuse) | **Explicit (sequential pipeline)** |
| Failure isolation | No — failure affects all purposes | Framework-level isolation | Per-capability isolation | **Per-engine isolation** |
| Graceful degradation (P12) | All-or-nothing | Per-strategy degradation | Per-capability degradation | **Per-engine degradation + fallback** |
| Complexity | Low | Moderate | High (coordination overhead) | **Moderate** |

Candidate A is disqualified by coupling. Candidate B is disqualified by the fundamental incompatibility between declarative strategy parameterization and procedural reasoning logic. Candidate C is disqualified by illusory reuse and coordination overhead.

Candidate D satisfies every criterion. The consumer contract provides consistent guarantees. Purpose-specialized reasoning engines provide independent variability. Technology agnosticism is structural — the contract does not reference any reasoning technology.

## Decision

**The consumer architecture uses a contract-governed model where each purpose is served by a purpose-specialized reasoning engine that conforms to a universal consumer contract.** The consumer contract defines the input (context frame + output specification), the output (understanding), the invariants (grounding, confidence, purpose-responsiveness), and the lifecycle. Reasoning engines implement the contract using any reasoning technology appropriate to their purpose. Adding a new purpose requires adding a new reasoning engine. Replacing the reasoning technology for an existing purpose requires replacing the reasoning engine — no other engine is affected.

---

## Consumer Contract

The consumer contract is the architectural interface between context assembly and understanding. Every reasoning engine must conform to this contract.

### Contract Definition

```
ConsumerRequest {
    contextFrame         : ContextFrame          (DAS-009)
    outputSpecification  : OutputSpecification
    conversationState    : ConversationState?     (nil for first interaction)
}

OutputSpecification {
    purpose              : ConsumerPurpose
    outputClass          : OutputClass            (human | machine | hybrid)
    constraints          : OutputConstraints
}

OutputConstraints {
    maxLength            : Integer?               (purpose-specific units)
    detailLevel          : DetailLevel            (minimal | standard | comprehensive)
    formatRequirements   : [FormatRequirement]    (purpose-specific)
}
```

### Contract Rules

**CC-1: Input is a context frame.** The consumer receives exactly one context frame as its evidence input. The consumer does not query the DIR, does not access indexes, does not read source code, and does not invoke retrieval. All evidence the consumer may use is in the context frame. This constraint ensures that context assembly is the sole evidence selection mechanism and that the consumer's reasoning is bounded by the evidence provided.

**CC-2: Output is understanding.** The consumer produces exactly one understanding as its output. The understanding conforms to the understanding contract (defined below). The consumer does not write to the DIR, does not modify indexes, does not trigger pass execution, and does not produce atomic units. The consumer's output is external to the DIR pipeline.

**CC-3: Consumers are stateless.** A consumer does not maintain state between invocations. Each invocation receives a complete consumer request and produces a complete understanding. Conversation continuity is carried in the conversation state field of the consumer request, not in consumer-internal state. This constraint ensures that consumers are independently restartable, replaceable, and scalable — a failed consumer invocation can be retried without state corruption.

**CC-4: Consumers are purpose-specialized.** Each reasoning engine serves one purpose. The purpose determines the engine's reasoning logic, its output structure, and its quality requirements. A reasoning engine that serves the explain purpose does not also serve the impact purpose — these require different reasoning, different output structures, and different quality criteria. Purpose specialization ensures that each engine can be optimized, tested, and validated independently.

**CC-5: Consumers honor the context frame's boundaries.** The consumer reasons only over evidence present in the context frame. A consumer that introduces claims not traceable to the context frame violates the grounding requirement (DAS-001 P5). A consumer may apply world knowledge (e.g., "this follows the strategy pattern") to interpret the evidence, but the interpretation must be anchored to specific evidence in the context frame — the consumer must identify which entities and relationships constitute the pattern, not assert the pattern without evidence.

**CC-6: Consumers degrade gracefully.** When the context frame is incomplete (degradation level > 0, as reported in ContextFrameMetadata), the consumer must produce understanding appropriate to the available evidence. A consumer that receives only T0 evidence (no T1 classifications, no T2 characterizations) produces structural understanding: what the entity is, what its properties are, what it connects to. A consumer that receives T0+T1 evidence adds derived understanding: what role the entity plays, what patterns it follows. A consumer that receives T0+T1+T2 evidence produces full understanding. The understanding's quality level communicates the degradation state to the consumer of the understanding.

---

## Understanding Contract

The understanding is the output of consumer reasoning. Every understanding, regardless of the purpose or reasoning engine that produced it, conforms to this contract.

### Understanding Definition

```
Understanding {
    content              : UnderstandingContent
    claims               : [UnderstandingClaim]
    metadata             : UnderstandingMetadata
    conversationState    : ConversationState?     (for follow-up continuity)
}

UnderstandingClaim {
    assertion            : String
    groundingReferences  : [ContextUnitReference]
    confidenceLevel      : ClaimConfidence
    claimType            : ClaimType
}

UnderstandingMetadata {
    purpose              : ConsumerPurpose
    outputClass          : OutputClass
    engineIdentifier     : EngineIdentifier
    contextFrameEpoch    : UpdateEpoch           (DAS-010)
    degradationLevel     : DegradationLevel
    reasoningDuration    : Duration
    groundingCoverage    : Float (0.0–1.0)
    tierDistribution     : {T0: Float, T1: Float, T2: Float}
    completeness         : CompletenessLevel
}
```

### Understanding Fields

**Content** (`content`): The primary output of the consumer in its purpose-specific format. For human-facing consumers, this is natural language text, annotated code, or a visual representation. For machine-facing consumers, this is a typed data structure (an impact graph, a list of improvement suggestions, an action plan). The content format is purpose-specific and defined by the reasoning engine — the understanding contract does not prescribe content structure beyond requiring that claims are extractable from it.

**Claims** (`claims`): The discrete assertions that constitute the understanding, each traceable to evidence. Claims are the grounding mechanism: they connect the understanding to the context frame. Not every sentence in a human-readable explanation is a separate claim — claims represent the substantive assertions that the understanding makes about the software. A claim may be:

- **Factual** (`fact`): Derived from T0 or T1 evidence. "This function takes two parameters: `username: String` and `password: String`." Grounded in the entity's `hasSignature` and `hasParameters` units.
- **Derived** (`derived`): Derived from T1 classifications or cross-evidence synthesis. "This function serves as the authentication entry point." Grounded in the entity's role classification and its position in the call graph.
- **Interpretive** (`interpretation`): Derived from T2 evidence or from the reasoning engine's synthesis of multiple evidence sources. "This function exists to isolate authentication logic from the session management layer." Grounded in the entity's design assessment and the scope's architectural characterization.
- **Inferred** (`inference`): Produced by the reasoning engine from evidence patterns, not from a single unit. "Renaming this function would require updates in 7 call sites across 3 files." Grounded in the relationship units that establish the dependency chain. Inferred claims are the reasoning engine's primary contribution — they go beyond what any single evidence unit states.

**UC-1: Every claim has at least one grounding reference.** A claim with no grounding reference is an ungrounded assertion. Ungrounded assertions are architecturally invalid — they cannot be traced to evidence, cannot be verified, and cannot be debugged.

**UC-2: Claim confidence reflects evidence tier.** A claim grounded entirely in T0 evidence has factual confidence. A claim grounded in T1 evidence has derived confidence. A claim grounded in T2 evidence or in cross-evidence inference has interpretive confidence. A claim that synthesizes evidence across tiers carries the confidence of the highest (least deterministic) tier in its grounding chain.

**UC-3: Claims are extractable from content.** For any understanding, the claims must be independently identifiable — not embedded in narrative without boundary markers. For human-facing output, this means the system can identify which portions of the text correspond to which claims. For machine-facing output, claims are first-class fields. This extractability enables grounding verification, confidence display, and claim-level staleness detection.

### Metadata Fields

**Grounding coverage** (`groundingCoverage`): The fraction of the context frame's units that are referenced by at least one claim. High coverage indicates that the understanding used most of the evidence provided. Low coverage indicates that much evidence was irrelevant to the reasoning — which may signal a context strategy mismatch (the strategy provided evidence the consumer didn't need) or a reasoning gap (the consumer ignored relevant evidence).

**Completeness** (`completeness`): The consumer's assessment of whether the context frame contained sufficient evidence to answer the question fully. Three levels:
- **Complete:** The context frame contained all evidence needed. The understanding fully answers the question.
- **Partial:** The context frame was missing evidence that would have improved the understanding. The understanding answers the question but with acknowledged gaps.
- **Insufficient:** The context frame lacked essential evidence. The understanding provides what it can but explicitly flags the insufficiency.

Completeness is the consumer's counterpart to context assembly's degradation level. A context frame at degradation level 0 may still produce partial understanding if the reasoning engine determines that the evidence, while complete in the DIR's terms, is insufficient for the specific question. A context frame at degradation level 2 (T0 only) always produces at most partial understanding for purposes that require T2 evidence.

**UC-4: Completeness is honest.** The consumer must not report complete understanding when the context frame's evidence was insufficient. Overstating completeness misleads consumers of the understanding. Understating completeness is acceptable — it is conservative.

---

## Reasoning Boundary

The reasoning boundary defines what reasoning engines are permitted and prohibited from doing.

### What Reasoning Engines Do

**RB-1: Interpret evidence.** Reasoning engines read the context frame's units and interpret them in the context of the purpose. Interpretation means understanding the relationships between units (entity A calls entity B, entity B conforms to protocol P), synthesizing patterns (A delegates authentication to B, which follows the strategy pattern), and resolving ambiguities (the `calls` relationship combined with the behavioral characterization suggests delegation, not mere invocation).

**RB-2: Synthesize understanding.** Reasoning engines combine interpreted evidence into a coherent output that answers the question posed by the purpose. Synthesis is the engine's primary contribution — it produces understanding that no single evidence unit contains. The synthesis may involve: natural language generation (for human-facing output), structured data construction (for machine-facing output), logical inference (for impact analysis), or procedural reasoning (for action planning).

**RB-3: Assess confidence.** Reasoning engines assess the confidence of their output based on the evidence tiers, confidence levels, and degradation state present in the context frame. A reasoning engine that produces an explanation from T0-only evidence should indicate that the explanation covers structural properties but lacks behavioral interpretation. This assessment is not a quality judgment — it is a factual report on the evidence basis of the understanding.

**RB-4: Produce conversation state.** When the consumer request is part of a conversation, the reasoning engine produces a conversation state that captures the essential context for the next invocation. The conversation state is a summary, not a transcript — it captures the key claims, the anchors, and the thread direction. The conversation state is the mechanism by which stateless consumers support conversational continuity.

### What Reasoning Engines Must Not Do

**RB-5: Must not access external state.** Reasoning engines do not read from the DIR, do not query indexes, do not access the file system, and do not call retrieval. All evidence is in the context frame. Accessing external state would bypass context assembly's selection logic, create undeclared dependencies, and make the consumer's output non-reproducible.

**RB-6: Must not write to the DIR.** Reasoning engines do not produce atomic units, do not modify unit status, and do not trigger pass execution. A consumer's output is external to the DIR pipeline. If a consumer's reasoning reveals something that should be recorded as intelligence (e.g., a pattern detection that should become a T2 unit), the appropriate mechanism is a pass, not a consumer write-back.

**RB-7: Must not make claims beyond the evidence.** Reasoning engines may apply world knowledge (language conventions, design pattern definitions, common idioms) to interpret evidence, but may not make claims about the software that are not supported by evidence in the context frame. "This follows the observer pattern" is valid if the context frame contains evidence of a subject, observers, and notification methods. "This follows the observer pattern" is invalid if the context frame contains only a class with a list field — the evidence is insufficient, and the claim is speculative.

**RB-8: Must not suppress evidence.** Reasoning engines must not systematically ignore evidence in the context frame. If the context frame contains evidence that contradicts the reasoning engine's synthesis (e.g., a design assessment says "well-structured" but the structural evidence shows circular dependencies), the engine must present both — not suppress the contradicting evidence. The consumer of the understanding makes the judgment; the reasoning engine presents the evidence.

---

## Grounding and Confidence Propagation

### Grounding Propagation

The grounding chain from understanding to source material passes through four levels:

```
Level 4: Understanding Claim → references context frame units
Level 3: Context Frame Unit → carries evidence provenance (DAS-008) and context role (DAS-009)
Level 2: DIR Atomic Unit → carries provenance and grounding chain (DAS-002)
Level 1: Source Material → the ultimate ground truth
```

The consumer architecture is responsible for Level 4: connecting understanding claims to context frame units.

**GP-1: Grounding is mandatory.** Every understanding claim must reference at least one context frame unit (UC-1). The reasoning engine must track which units support each claim during reasoning.

**GP-2: Grounding is verifiable.** For any claim in the understanding, the grounding references identify specific context units. These units carry their own grounding chains (DAS-002). A consumer of the understanding can traverse the full chain from claim to source material.

**GP-3: Grounding coverage is reported.** The understanding metadata reports grounding coverage — what fraction of the context frame's evidence was used. This metric enables system-level optimization: if a reasoning engine consistently uses only 30% of the context frame's units, the context strategy may be providing too much evidence (wasting context budget) or evidence of the wrong kind (misaligned stratum priorities).

### Confidence Propagation

Confidence flows from the context frame's tiers through reasoning into the understanding's claims.

**CP-1: Tier-to-confidence mapping.** The context frame carries tier annotations on every unit (DAS-009 ContextUnit). The reasoning engine maps tiers to claim confidence:
- Claims grounded exclusively in T0 units: **factual** confidence.
- Claims grounded in T0 and T1 units: **derived** confidence.
- Claims grounded in any T2 units: **interpretive** confidence.
- Claims synthesized across multiple units: confidence of the highest (least deterministic) tier in the grounding set.

**CP-2: Confidence is monotonically non-increasing.** The reasoning process cannot increase the confidence of its input. A claim derived from T2 evidence cannot have factual confidence, even if the reasoning engine is certain the evidence is correct. Confidence reflects the evidence basis, not the engine's subjective assessment. This constraint ensures that the understanding's confidence accurately represents the reliability of the evidence, not the reasoning engine's self-evaluation.

**CP-3: Degradation is communicated.** When the context frame is degraded (missing T1 or T2 evidence), the understanding communicates the impact of degradation on its quality. The degradation level is reported in the understanding metadata. The reasoning engine may also annotate specific claims with degradation notes: "this characterization would normally be based on behavioral analysis, but only structural evidence was available."

**CP-4: Confidence is granular, not aggregate.** Confidence is per-claim, not per-understanding. An understanding may contain factual claims (from T0 evidence), derived claims (from T1 evidence), and interpretive claims (from T2 evidence). An aggregate confidence level would obscure this heterogeneity. Per-claim confidence enables consumers of the understanding to assess each assertion independently.

---

## Consumer Lifecycle

### Single Invocation

A single consumer invocation follows this lifecycle:

```
1. Receive      ConsumerRequest (context frame + output specification + conversation state?)
2. Validate     Context frame well-formedness, essential evidence presence
3. Reason       Apply purpose-specific reasoning to produce understanding
4. Ground       Verify grounding: every claim references context frame units
5. Annotate     Assess confidence, completeness, degradation
6. Produce      Return Understanding (content + claims + metadata + conversation state?)
```

**CL-1: Validation before reasoning.** The consumer validates the context frame before reasoning. Validation checks: (a) the context frame is well-formed (required fields present, strata non-empty), (b) the context frame's purpose matches the consumer's purpose, (c) essential evidence is present (purpose-specific — an explain consumer requires the anchor's identity; an impact consumer requires at least one dependency edge). If validation fails, the consumer produces a validation failure (see Failure Modes) without invoking the reasoning engine.

**CL-2: Grounding verification after reasoning.** After the reasoning engine produces its output, the consumer verifies that every claim has at least one grounding reference (UC-1). If any claim is ungrounded, the consumer either requests the reasoning engine to provide grounding, removes the claim, or flags the claim as ungrounded in the understanding metadata. The consumer must not return ungrounded claims as if they were grounded.

**CL-3: Invocation is atomic.** A consumer invocation either succeeds (produces a valid understanding) or fails (produces a failure response). There is no partial state — a consumer does not produce "half an understanding." If reasoning fails partway through, the consumer returns a failure or a degraded understanding (see Failure Modes).

### Conversation Lifecycle

A conversation is a sequence of consumer invocations sharing a logical thread:

```
Invocation 1: ConsumerRequest(contextFrame₁, spec₁, nil)
              → Understanding₁ + ConversationState₁

Invocation 2: ConsumerRequest(contextFrame₂, spec₂, ConversationState₁)
              → Understanding₂ + ConversationState₂

Invocation N: ConsumerRequest(contextFrameₙ, specₙ, ConversationStateₙ₋₁)
              → Understandingₙ + ConversationStateₙ
```

**CL-4: Conversation state is opaque to the pipeline.** The pipeline (retrieval, context assembly) does not inspect or modify the conversation state. It is produced by the consumer, carried through the request, and consumed by the next consumer invocation. The only pipeline component that reads the conversation state is the reasoning engine.

**CL-5: Conversation state is bounded.** The conversation state must not grow unboundedly with conversation length. Each invocation produces a conversation state that summarizes the relevant context — it does not accumulate full transcripts. The maximum size of conversation state is an implementation constraint, but the architecture requires boundedness. A conversation state that grows linearly with conversation length will eventually exceed processing capacity.

**CL-6: Conversations are recoverable.** If a consumer invocation fails mid-conversation, the conversation can continue from the last successful invocation's state. The prior conversation state is immutable — the failed invocation does not corrupt it. The next invocation can retry with the same or a different context frame.

---

## Consumer Composition

Some capabilities require multiple reasoning steps. An improvement suggestion requires understanding (what the code does) before assessment (what could be better). An autonomous agent requires understanding, assessment, planning, and action specification — a chain of reasoning steps where each step's output informs the next.

### Sequential Composition

**COMP-1: Sequential composition as a pipeline.** Complex capabilities are composed as a sequence of consumer invocations. Each invocation receives a context frame assembled for its specific sub-purpose and the prior invocation's understanding (carried in the conversation state). The composition is:

```
Context Frame₁ → Consumer₁ (understand) → Understanding₁
Context Frame₂ + Understanding₁ → Consumer₂ (assess) → Understanding₂
Context Frame₃ + Understanding₂ → Consumer₃ (plan) → Understanding₃
```

Each consumer in the composition is a standard consumer invocation. The composition framework is responsible for:
1. Requesting the appropriate context frame for each sub-purpose (from context assembly).
2. Passing the prior understanding via conversation state.
3. Merging the final understanding from the composition's last consumer.

**COMP-2: Composition preserves the consumer contract.** Each consumer in a composition conforms to the consumer contract. The composition does not introduce new contracts or bypass existing ones. Grounding, confidence, and provenance flow through the composition: the final understanding's claims trace through the intermediate understandings to the context frame units.

**COMP-3: Composition failures are isolated.** If a consumer in a composition fails, the composition can return partial results (the understanding produced by the consumers that succeeded) or attempt fallback (substitute a simpler reasoning engine for the failed step). The composition does not propagate failure to unrelated consumers.

### Parallel Composition

**COMP-4: Independent consumer invocations are parallelizable.** When two consumers in a composition do not depend on each other's output (e.g., structural analysis and semantic assessment over the same context frame), they may execute in parallel. The composition merges their understandings into a combined output. Parallel composition is an optimization, not an architectural requirement — sequential composition produces identical results.

---

## Failure Modes

**FM-1: Reasoning engine failure.** The reasoning engine encounters an error (AI service unavailable, rule engine exception, inference timeout). The consumer produces a failure response with the failure reason. If a fallback reasoning engine is available (e.g., a deterministic engine that produces structural understanding when the AI engine fails), the consumer may invoke the fallback and produce degraded understanding.

**FM-2: Validation failure.** The context frame fails validation (missing essential evidence, purpose mismatch, malformed structure). The consumer produces a validation failure response without invoking the reasoning engine. The failure identifies which validation check failed and what evidence was missing.

**FM-3: Grounding failure.** The reasoning engine produces claims that cannot be grounded to context frame units. The consumer removes ungrounded claims from the understanding and reports the grounding failure in metadata. If all claims are ungrounded, the consumer produces a grounding failure response — the reasoning engine's output is entirely unverifiable.

**FM-4: Budget exhaustion.** The reasoning engine's processing exceeds its resource budget (computation time, token limit for AI engines, inference steps for symbolic engines). The consumer produces partial understanding — the claims produced before budget exhaustion — and reports the exhaustion in metadata. Partial understanding is preferable to no understanding (DAS-001 P12).

**FM-5: Conversation state corruption.** The conversation state from a prior invocation is malformed or incompatible with the current reasoning engine version. The consumer discards the conversation state and processes the request as a new conversation (first invocation). Continuity is lost but the invocation succeeds.

**FM-6: Context staleness.** The context frame's epoch (DAS-010) is older than the current DIR epoch — the underlying intelligence has changed since the context was assembled. The consumer produces the understanding but annotates the metadata with a staleness flag. The consumer of the understanding can decide whether to accept stale understanding or request fresh context.

---

## Observability

**OB-1: Reasoning duration.** The time elapsed between receiving the consumer request and producing the understanding. Long durations indicate reasoning engine performance issues or excessive context frame complexity.

**OB-2: Grounding coverage.** The fraction of context frame units referenced by understanding claims. Persistently low coverage indicates context strategy misalignment — the context assembly provides evidence the consumer doesn't use. Persistently high coverage indicates good alignment between the context strategy and the reasoning engine's needs.

**OB-3: Claim distribution.** The count of claims by type (factual, derived, interpretive, inferred) and by confidence level. Distributions skewed toward interpretive claims in contexts with abundant T0 evidence indicate reasoning engines that over-interpret. Distributions skewed toward factual claims in contexts with T2 evidence indicate reasoning engines that under-synthesize.

**OB-4: Failure rate.** The frequency and type of failures (FM-1 through FM-6) per reasoning engine. High failure rates for a specific engine indicate engine instability. High FM-2 (validation failure) rates indicate context assembly misalignment.

**OB-5: Completeness distribution.** The frequency of complete, partial, and insufficient understandings per purpose. High insufficiency rates indicate that the context strategy for that purpose is not providing adequate evidence, or that the reasoning engine's expectations exceed what the DIR can provide.

**OB-6: Conversation statistics.** Average conversation length, conversation abandonment rate, and follow-up question frequency per purpose. Short conversations with immediate follow-ups may indicate that the first understanding was insufficient. Long productive conversations indicate effective conversational reasoning.

---

## Architectural Consequences

**C1: Adding a capability is adding a reasoning engine.** The consumer architecture is purpose-specialized. When a new capability is needed (security review, migration planning, documentation generation), a new reasoning engine is developed that conforms to the consumer contract. No existing engines are affected. No pipeline changes are needed. A new context strategy (DAS-009) may also be needed to provide purpose-appropriate evidence. This is the consumer-side expression of DAS-002 C3: adding a capability is adding a backend.

**C2: Replacing the reasoning technology for a purpose is replacing the reasoning engine.** When a better reasoning technology becomes available for a specific purpose (a more capable AI model, a new symbolic reasoner, a deterministic engine that replaces AI for a well-understood purpose), the reasoning engine for that purpose is replaced. No other engines are affected. The consumer contract ensures that the replacement engine produces understanding with the same structural guarantees (grounding, confidence, provenance). This is the consumer-side expression of DAS-001 P11: the boundary between the consumer contract and the reasoning engine enables independent variability.

**C3: Understanding quality is bounded by context quality.** A reasoning engine cannot produce understanding better than the evidence supports. If the context frame is degraded (missing T2 evidence), the understanding is structurally limited — no amount of reasoning sophistication compensates for missing evidence. This is the consumer-side expression of DAS-001 P1: intelligence is the canonical asset. Improving understanding quality requires improving intelligence (richer DIR content, better enrichment passes), not improving the reasoning engine.

**C4: Grounding is end-to-end.** The four-level grounding chain (understanding claim → context unit → DIR unit → source material) means that every assertion in every understanding is traceable to source code. This is not a feature — it is an architectural invariant. It enables: auditability (verify any claim by traversing the chain), debuggability (trace incorrect output to the evidence that produced it), and staleness detection (if the source changes, the grounding chain identifies which claims are affected).

**C5: Consumers are stateless; conversations are state-carried.** The consumer contract's statelesness (CC-3) means consumers have no memory and no hidden state. Conversation continuity is explicit — carried in the conversation state field of the consumer request. This design has three architectural benefits: (a) any consumer invocation can be retried without side effects, (b) any reasoning engine for a purpose can handle any invocation of that purpose (no engine-specific state), and (c) conversation state is observable and debuggable (it is data, not hidden internal state).

**C6: Graceful degradation is multi-level.** Degradation can occur at multiple points: missing T2 evidence in the context frame (context-level degradation), reasoning engine failure with fallback to a simpler engine (engine-level degradation), and partial understanding due to budget exhaustion (output-level degradation). Each level is independent and cumulative. The worst case — T0-only context, deterministic fallback engine, partial output — still produces structural understanding about the software. The best case — full T0+T1+T2 context, primary reasoning engine, complete output — produces comprehensive understanding. The architecture smoothly degrades between these extremes.

**C7: The consumer contract is the system's second most critical interface.** The DIR contract (DAS-002) is the most critical — it governs all intelligence production and consumption. The consumer contract is the second — it governs all understanding production. Changes to the consumer contract affect every reasoning engine and every consumer of understanding. The contract should change rarely and through the DAS change process.

**C8: Consumer composition enables complex capabilities without monolithic reasoning.** An autonomous agent is not a single reasoning engine — it is a composition of understanding, assessment, planning, and action-specification engines. Each engine is independently developed, tested, and replaceable. The composition is explicit (a sequential pipeline with conversation state carrying the thread), not implicit (hidden internal state in a monolithic engine). This makes complex capabilities architecturally tractable: each step is a standard consumer invocation, and the composition is a standard orchestration pattern.

---

## Invariants

**I1: Grounding Completeness.**
- **Statement:** Every understanding claim references at least one context frame unit. No claim in any understanding is ungrounded.
- **Rationale:** An ungrounded claim is unverifiable — it cannot be traced to evidence, cannot be audited, and cannot be debugged. Ungrounded claims in understanding violate DAS-001 P5 (intelligence is grounded) and break the end-to-end traceability chain from understanding to source material.
- **Verification:** For each understanding, enumerate all claims. For each claim, confirm at least one grounding reference exists and that the referenced unit exists in the context frame.

**I2: Confidence Monotonicity.**
- **Statement:** No understanding claim has higher confidence than the evidence it is grounded in. A claim grounded in T2 evidence cannot have factual (T0-level) confidence.
- **Rationale:** Confidence inflation misleads consumers of understanding. If a reasoning engine claims factual confidence for an interpretation based on semantic evidence, the consumer of the understanding will treat it as a deterministic fact — which it is not. Confidence monotonicity ensures that the understanding accurately represents the reliability of its evidence basis.
- **Verification:** For each claim, determine the highest tier in its grounding set. Confirm that the claim's confidence level is not higher than the confidence associated with that tier.

**I3: Consumer Statelessness.**
- **Statement:** No consumer maintains state between invocations. Two consumer invocations with identical ConsumerRequests produce identical Understandings (within the non-determinism bounds of the reasoning technology).
- **Rationale:** Stateful consumers create hidden dependencies — the output of invocation N depends not only on the request but on the hidden state left by invocations 1 through N-1. Hidden state is unobservable, undebuggable, and unrecoverable. Statelessness ensures that every invocation is independent and reproducible (modulo reasoning technology non-determinism).
- **Verification:** Invoke the same consumer with identical requests at different times. Confirm that outputs are equivalent (for deterministic engines: identical; for non-deterministic engines: structurally equivalent — same claims, same grounding, same confidence, possibly different phrasing).

**I4: Purpose-Response Alignment.**
- **Statement:** Every understanding addresses the purpose specified in the consumer request. An explain understanding contains explanatory content. An impact understanding contains impact analysis. No understanding addresses a purpose different from the one requested.
- **Rationale:** A consumer that produces impact analysis when asked for an explanation has failed — even if the impact analysis is correct. Purpose alignment ensures that the understanding is useful to the consumer of the understanding, who requested a specific kind of output.
- **Verification:** For each understanding, confirm that its content addresses the requested purpose. This is a semantic verification (not a syntactic one) and requires purpose-specific criteria.

**I5: Context Frame Sufficiency Honesty.**
- **Statement:** When the context frame lacks evidence that the reasoning engine needs for complete understanding, the understanding reports its completeness as partial or insufficient (UC-4). No understanding claims completeness when the evidence was insufficient.
- **Rationale:** False completeness claims cause consumers of understanding to make decisions based on incomplete information without knowing it is incomplete. Honest incompleteness enables consumers to seek additional evidence or defer decisions.
- **Verification:** Inject context frames with known evidence gaps. Confirm that the produced understanding reports partial or insufficient completeness, not complete.

**I6: No DIR Side Effects.**
- **Statement:** Consumer invocations do not modify the DIR, do not modify indexes, do not trigger pass execution, and do not produce atomic units.
- **Rationale:** Consumers are on the read side of the pipeline. If consumers wrote to the DIR, the system would have a read-write cycle (consumer reads context → reasons → writes to DIR → context changes → consumer reads different context), creating non-determinism and potential infinite loops. The pipeline is unidirectional: source → DIR → passes → indexes → retrieval → context → consumer → understanding.
- **Verification:** Monitor DIR, index, and pass state before and after consumer invocations. Confirm no changes.

**I7: Conversation State Boundedness.**
- **Statement:** Conversation state size does not grow unboundedly with conversation length. Each invocation produces conversation state of bounded size, regardless of the number of prior invocations.
- **Rationale:** Unbounded conversation state eventually exceeds the reasoning engine's processing capacity, causing failure at an unpredictable conversation depth. Bounded state ensures that conversations of any length are processable (though distant context may be summarized or lost).
- **Verification:** Conduct conversations of increasing length (10, 50, 100 turns). Measure conversation state size at each turn. Confirm it remains below a defined bound.

**I8: Failure Produces Diagnostic Output.**
- **Statement:** Every consumer failure (FM-1 through FM-6) produces a diagnostic response that identifies the failure mode, the failed component, and sufficient context for debugging. No failure produces a silent error or an ambiguous response.
- **Rationale:** Silent failures are the most expensive failures — they produce incorrect or absent output without indicating what went wrong. Every consumer failure must be identifiable by the system and by the human operator.
- **Verification:** Trigger each failure mode. Confirm that the response identifies the mode, the component, and the diagnostic context.

---

## Non-Goals

This chapter does not:

- **Define specific reasoning engines.** The logic by which an AI model produces an explanation, a rule engine assesses impact, or a symbolic reasoner plans a refactoring is implementation-specific. This chapter defines the contract those engines must satisfy, not their internal operation.

- **Define prompts, templates, or model configurations.** How a reasoning engine that uses an AI model constructs its prompt, selects its model, or configures its parameters is an implementation detail. This chapter requires only that the output conforms to the understanding contract.

- **Define how context frames are serialized for reasoning engines.** The serialization of a context frame into a format consumable by a specific reasoning engine (XML for one AI model, JSON for another, a typed data structure for a rule engine) is an implementation concern. This chapter defines the semantic contract of the context frame as input; serialization is downstream.

- **Define rendering or display.** How an understanding is rendered for a human — fonts, colors, layout, interactive elements — is a presentation concern. This chapter defines the understanding contract; presentation translates understanding into visual output.

- **Define how questions are mapped to purposes.** The mechanism by which a user's natural language question is classified into a consumer purpose (explain, improve, investigate) is an application-layer concern. This chapter assumes the purpose has been determined before the consumer is invoked.

- **Define retrieval, context assembly, or the DIR pipeline.** These are governed by DAS-002 through DAS-009. This chapter consumes the output of context assembly (the context frame) and does not influence how that output is produced.

- **Define how AI models are selected, provisioned, or managed.** Model selection, API management, cost optimization, and provider fallback are infrastructure concerns. This chapter treats reasoning as an abstract capability, regardless of the infrastructure that provides it.

- **Prescribe specific technologies.** No AI model, rule engine, inference framework, or programming language is specified. The consumer architecture is technology-independent.

---

## Open Questions

**Q1: Should consumers produce structured grounding annotations or free-form references?** *(Non-blocking)*

The current contract requires each claim to reference context frame units. The reference could be structured (a typed pointer to a specific unit ID in the context frame) or free-form (a textual description of which evidence supports the claim, e.g., "grounded in the function's signature and callee list"). Structured references enable automated grounding verification. Free-form references are easier for AI-based reasoning engines to produce but harder to verify.

**Investigation approach:** Implement both formats for the explain reasoning engine. Measure the accuracy of structured vs. free-form grounding. If AI engines can produce accurate structured references, adopt structured format universally. If not, define a hybrid format (structured when available, free-form as fallback with post-hoc resolution).

**Q2: Should reasoning engines declare their capability envelope?** *(Non-blocking)*

The current contract requires reasoning engines to report completeness (complete, partial, insufficient). An alternative would require engines to declare upfront what kinds of context frames they can fully process — e.g., "this engine requires at least 3 strata with at least one T2 unit" — enabling the system to select or configure the engine based on the context frame's characteristics before invoking it.

**Investigation approach:** Monitor completeness reports in production. If certain engines frequently report insufficient completeness for predictable context frame profiles, capability declarations could enable pre-invocation routing. If insufficiency is unpredictable, declarations add complexity without benefit.

**Q3: Should the understanding contract define a quality metric?** *(Non-blocking)*

The current contract reports completeness, degradation, and grounding coverage — compositional metrics about the understanding's structure. It does not report a quality metric: "this explanation is good." Quality is subjective and purpose-dependent. However, proxy metrics (grounding density, claim-to-evidence ratio, tier coverage) could provide coarse quality signals without subjective evaluation.

**Investigation approach:** Correlate compositional metrics with user satisfaction signals (if available). If strong correlations exist, define a composite quality proxy. If not, the compositional metrics are sufficient for system health monitoring, and quality assessment is deferred to user-facing evaluation mechanisms.

**Q4: Should consumers support speculative reasoning?** *(Non-blocking)*

The current contract (RB-7) prohibits claims beyond the evidence. An alternative would allow a "speculative" claim type: claims the reasoning engine believes are likely based on patterns in the evidence but cannot ground to specific units. Speculative claims would be explicitly labeled, carry no confidence, and be presented as hypotheses rather than assertions. This would be useful for investigation purposes ("based on the naming patterns, this module may also handle session refresh — but no direct evidence confirms this").

**Investigation approach:** Evaluate whether speculative claims improve the utility of investigation-purpose understanding. If users find speculative claims helpful (they open investigation threads), define a speculative claim type with strict labeling requirements. If users find them confusing (they blur the line between evidence and conjecture), maintain the current no-speculation constraint.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              ├── DAS-006 (Pass Architecture)
              ├── DAS-008 (Retrieval Architecture)
              │     └── DAS-009 (Context Assembly)
              │           └── DAS-011 (this chapter — Consumer Architecture)
              └── ...
```

This chapter depends on:
- DAS-000: chapter structure, review checklist
- DAS-001: P1 (intelligence is canonical asset — understanding is derived from it), P5 (grounding — understanding must trace to evidence), P6 (understanding is derived, not stored — consumers do not persist understanding), P7 (relevance over completeness — consumers produce relevant output, not exhaustive output), P8 (AI is a consumer of intelligence — reasoning engines consume intelligence, they are not its source), P10 (scope scales independently — purpose is an independent axis), P11 (boundaries define independent variability — consumer contract enables reasoning engine replacement), P12 (graceful degradation — consumers degrade when evidence or reasoning is limited)
- DAS-002: consumer contract (consumers read DIR via retrieval and context assembly, do not write to DIR), pipeline position (consumers are at the end of the pipeline), atomic unit contract (units are the evidence that understanding claims reference)
- DAS-003: tier model (T0/T1/T2 — confidence propagation from tiers to claims), confidence model (confidence levels map to claim types), graceful degradation levels (missing tiers produce degraded understanding)
- DAS-006: pass architecture (passes produce DIR content — consumers consume it; enrichment passes that use AI are passes, not consumers)
- DAS-008: retrieval architecture (retrieval gathers evidence — consumers do not), evidence set contract (the input to context assembly, not to consumers)
- DAS-009: context frame contract (ContextFrame, FilledStratum, ContextUnit, ContextBudget, ContextFrameMetadata — the input to consumers), context strategy (purpose-specific parameterization — the consumer's purpose aligns with the strategy that produced the context frame), purpose-stratified architecture (each purpose has a strategy and a reasoning engine)

This chapter is depended on by:
- DAS-012 (Storage Realization): storage may need to support conversation state persistence, understanding caching (as a disposable derivative), and consumer metrics

---

## Revision History

```
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining the consumer architecture.
    Contract-governed consumer architecture with purpose-specialized reasoning engines selected
    over monolithic, strategy-parameterized, and capability-composed alternatives. Consumer
    contract defined (CC-1 through CC-6). Understanding contract defined (UC-1 through UC-4).
    Reasoning boundary defined (RB-1 through RB-8). Grounding propagation (GP-1 through GP-3)
    and confidence propagation (CP-1 through CP-4). Consumer lifecycle (CL-1 through CL-6).
    Consumer composition (COMP-1 through COMP-4). Six failure modes. Six observability concerns.
    Eight invariants. Eight architectural consequences. Four open questions. Twelve terms defined.
```
