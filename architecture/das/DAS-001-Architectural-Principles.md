# DAS-001: Architectural Principles

```
Chapter:       DAS-001
Title:         Architectural Principles
Status:        Draft
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000
Depended By:   DAS-002, DAS-003, DAS-004, DAS-005, DAS-006, DAS-007, DAS-008, DAS-009, DAS-010, DAS-011, DAS-012
Supersedes:    —
Superseded By: —
Layer:         L0
```

## Abstract

This chapter defines the architectural principles that govern every design decision in Decode. It establishes Decode's canonical asset (Intelligence), its canonical output (Understanding), and the twelve engineering principles that constrain all downstream architecture. Every DAS chapter at layers L1–L5 must demonstrate conformance to these principles. A principle stated here overrides any conflicting decision in a higher-layer chapter.

## Motivation

Without explicit architectural principles, design decisions devolve into local optimization. Each team, each feature, each deadline produces a locally rational choice that is globally incoherent. Over time, the system accumulates structural contradictions: one subsystem assumes intelligence is lazily computed while another assumes it is eagerly available; one boundary treats AI output as authoritative while another treats it as advisory; one component stores raw source while another stores derived facts, and neither knows which is canonical.

Principles prevent this. They are the small set of commitments that make the majority of downstream decisions *derivable* rather than *debatable*. A well-chosen principle doesn't just constrain — it *decides*. When an engineer faces a design choice and a principle unambiguously resolves it, the principle has done its job.

This chapter must answer three questions that every downstream chapter will depend on:

1. **What does Decode build?** (The canonical asset.)
2. **What does Decode deliver?** (The canonical output.)
3. **What rules govern how the asset is built and the output is delivered?** (The principles.)

If this chapter is wrong, every chapter that depends on it is wrong. If this chapter is vague, every chapter that depends on it will resolve the vagueness differently, producing inconsistency.

**Source RFCs:**
- [RFC-000: Canonical Asset](../rfc/RFC-000-Canonical-Asset.md) — establishes Intelligence as the canonical asset
- [RFC-001: Decode Identity](../rfc/RFC-001-Decode-Identity.md) — establishes Decode as a Software Understanding Engine

## Terminology

**Intelligence** — A layered, composable, incrementally maintainable representation of software that spans from deterministic structural facts to semantically derived interpretation. Intelligence is the canonical asset of Decode — the durable thing the system builds, owns, maintains, and evolves. Intelligence is *not* a synonym for AI. It refers to the structured knowledge that Decode accumulates about software, regardless of whether AI was involved in producing it. *Is:* the system's multi-layered model of a codebase, including structural facts, relationships, behavioral characterizations, and interpretive assessments. *Is not:* a raw AI response, a user-facing explanation, or a database dump of parsed symbols. `INTRODUCED`

**Understanding** — A structured, purpose-calibrated output derived from Intelligence and delivered to a consumer. Understanding is the canonical output of Decode — what the system produces for the developer. Understanding is always *about* a subject, *within* a scope, *at* a depth, and *for* a perspective. *Is:* an explanation of why a coordinator delegates to a service, calibrated to a developer who is debugging a timeout. *Is not:* a list of function signatures, a raw AI completion, or an internal intelligence record. `INTRODUCED`

**Canonical Asset** — The single architectural asset that a system creates, owns, maintains, and evolves, from which all outputs are derived. Decode's canonical asset is Intelligence. `See RFC-000`

**Canonical Output** — The primary deliverable that a system produces for its consumers, derived from the canonical asset. Decode's canonical output is Understanding. `See RFC-001`

**Intelligence Layer** — One of the ordered strata within Intelligence, each with distinct objectivity, stability, computation cost, and confidence characteristics. Lower layers are more objective and stable; higher layers are more interpretive and volatile. `INTRODUCED`

**Composition** — The process by which intelligence at a smaller scope combines to produce intelligence at a larger scope, generating emergent properties that do not exist at the smaller scope. Composition is *not* aggregation (collecting parts) or concatenation (joining parts end-to-end). *Is:* combining file-level intelligence to reveal that three files form a subsystem with a specific interaction pattern. *Is not:* appending three files' intelligence records into a list. `INTRODUCED`

**Projection** — The process of selecting, filtering, and shaping Intelligence for a specific consumer and purpose. A projection reduces Intelligence to the subset relevant for a particular Understanding. `INTRODUCED`

**Deterministic Intelligence** — Intelligence that can be produced by algorithmic analysis of source artifacts without probabilistic inference. Given the same input, any conforming implementation produces identical output. `INTRODUCED`

**Semantic Intelligence** — Intelligence that requires interpretive inference to produce. Given the same input, different inference engines (or the same engine at different times) may produce different but equally valid output. `INTRODUCED`

**Freshness Contract** — The guarantee that a specific intelligence layer provides about how current its content is relative to the source material it was derived from. Different layers may have different freshness contracts. `INTRODUCED`

**Grounding** — The property that every claim within Intelligence traces to identifiable source material. A grounded claim can be verified by inspecting its source. An ungrounded claim cannot. `INTRODUCED`

## Domain Analysis

The following properties of software and software comprehension are true independent of any system, and constrain Decode's architecture.

**D1: Software is text that behaves.** Source code is simultaneously a textual artifact (readable, parseable, diffable) and a behavioral specification (executable, stateful, side-effecting). Any system that understands software must account for both dimensions. A system that treats code only as text will miss behavior. A system that treats code only as behavior will miss structure.

**D2: Software structure is objectively knowable; software intent is not.** A function's parameters, return type, call targets, and control flow can be determined with certainty by analyzing the source. Why the function exists, whether its design is sound, and what trade-offs were accepted are matters of interpretation. These two categories of knowledge have fundamentally different reliability characteristics and must not be conflated.

**D3: Software changes continuously, unevenly, and unpredictably.** A codebase is not a static artifact. Files change at different rates. Some files are stable for years; others change daily. A system that represents software must account for change as a primary concern, not an afterthought. Any representation that assumes stability will degrade.

**D4: Understanding is always relative to a question.** There is no "the understanding" of a piece of software. A developer debugging a race condition needs different understanding of the same function than a developer adding a feature. Understanding is produced *for* a purpose, not *in general*.

**D5: Software meaning is layered.** A function can be understood at multiple levels: its syntax, its local behavior, its role in a module, its position in the architecture, its historical evolution. Each level builds on the ones below it. Skipping levels produces shallow or misleading understanding.

**D6: The relationship between parts is not derivable from the parts alone.** Knowing everything about File A and everything about File B does not tell you how A and B interact, what contract they share, or whether they form a coherent subsystem. Cross-entity understanding requires explicit analysis of relationships — it does not emerge automatically from per-entity analysis.

**D7: Comprehension has diminishing returns per unit of information.** Beyond a certain volume, additional information actively impairs comprehension. The developer who receives 500 lines of context understands less than the developer who receives the 30 most relevant lines. Context selection is as important as context generation.

**D8: AI inference is powerful, expensive, non-deterministic, and untrustworthy in isolation.** AI can synthesize, interpret, and explain in ways that algorithmic analysis cannot. It can also hallucinate, contradict itself, and produce plausible-sounding nonsense. Any architecture that treats AI output as authoritative will produce unreliable systems. Any architecture that excludes AI will produce shallow systems.

## Decision

### Canonical Asset

**The canonical asset of Decode is Intelligence** — a layered, composable, incrementally maintainable representation of software (RFC-000).

Decode builds Intelligence. Decode owns Intelligence. Decode maintains Intelligence. Decode evolves Intelligence. All outputs are derived from Intelligence. The quality of every output is bounded by the quality of the Intelligence from which it is derived.

### Canonical Output

**The canonical output of Decode is Understanding** — a structured, purpose-calibrated representation of what software is, does, and means, derived from Intelligence and delivered to a consumer (RFC-001).

### Relationship

Intelligence is what Decode *accumulates*. Understanding is what Decode *delivers*. Engineering investment targets Intelligence quality; output quality follows as a consequence. This relationship is not symmetric — improving output formatting does not improve Intelligence, but improving Intelligence improves every output.

---

## Architectural Principles

The following principles are ordered by precedence. When two principles conflict in a specific design decision, the lower-numbered principle takes priority.

---

### P1: Intelligence Is the Canonical Asset

**Statement.** Decode builds, owns, maintains, and evolves one asset: Intelligence. Every other artifact — explanations, analyses, context frames, UI state, cached outputs — is derived from Intelligence and is disposable. If the derived artifacts are lost, they can be regenerated from Intelligence. If Intelligence is lost, the system must rebuild it from source.

**Motivation.** A system with multiple competing sources of truth produces inconsistency. If explanations are cached independently of the intelligence that produced them, they drift. If context is assembled from raw source rather than from intelligence, the assembly logic duplicates knowledge that intelligence already contains. A single canonical asset eliminates this class of defect.

**Consequences.**
- C1.1: All persistent state that is not source code is either Intelligence or derivable from Intelligence.
- C1.2: No subsystem may build a parallel representation of software that is not part of the Intelligence model.
- C1.3: When a derived artifact and Intelligence disagree, Intelligence is authoritative and the derived artifact must be regenerated.

**Enables.** A single investment target. Engineers know that improving Intelligence improves everything. Cache invalidation is tractable because there is one source, not many.

**Forbids.** Shadow data structures that represent software independently of Intelligence. Subsystem-local caches that are not derived from and invalidated by Intelligence. "Shortcut" paths that bypass Intelligence to produce outputs directly from source.

---

### P2: Intelligence Is Layered with Strict Downward Dependency

**Statement.** Intelligence is organized into ordered layers. Each layer depends only on the layers below it, never on the layers above it. Lower layers are more objective, more stable, and cheaper to compute. Higher layers are more interpretive, more volatile, and more expensive to compute.

**Motivation (from D2, D5, D8).** Software structure is objectively knowable; software intent is not (D2). Software meaning is layered (D5). Mixing objective and interpretive claims in a single undifferentiated store makes it impossible to assess reliability. A structural fact ("this function takes two parameters") and an interpretive claim ("this function exists to work around a framework limitation") have different confidence, different freshness requirements, and different computation costs. They must be architecturally distinguishable.

**Consequences.**
- C2.1: Each intelligence layer declares its objectivity (deterministic or semantic), its freshness contract, and its confidence model.
- C2.2: No layer may depend on a layer above it. Structural intelligence never consults behavioral intelligence. Relational intelligence never consults interpretive intelligence.
- C2.3: The failure or absence of a higher layer does not affect the validity of lower layers.

**Enables.** Graceful degradation: if semantic intelligence is unavailable, deterministic intelligence still functions. Independent evolution: a new interpretation engine can be deployed without affecting structural extraction. Transparent confidence: a consumer can distinguish between what is *known* and what is *inferred*.

**Forbids.** Circular dependencies between intelligence layers. Structural analysis that requires AI inference. Behavioral intelligence that invalidates structural facts. Any design in which removing the highest layer breaks the system.

---

### P3: Deterministic Before Semantic

**Statement.** When a property of software can be determined by algorithmic analysis of its source, it must be determined algorithmically — never by probabilistic inference. Semantic intelligence may augment deterministic intelligence but never replace it, override it, or serve as a substitute for it.

**Motivation (from D2, D8).** Deterministic analysis is reproducible, verifiable, and cheap. Semantic analysis is none of these. If the system uses AI to determine that a function takes two parameters — something a parser can determine with certainty — it has introduced non-determinism, cost, and potential error for zero benefit. Worse, it has created a dependency on AI availability for basic functionality.

**Consequences.**
- C3.1: Every property that can be deterministically extracted is deterministically extracted, regardless of whether AI could also produce it.
- C3.2: Semantic intelligence operates on top of deterministic intelligence, never in place of it.
- C3.3: If deterministic analysis and semantic analysis disagree about a property that is deterministically knowable, the deterministic result is authoritative.

**Enables.** Offline operation (deterministic intelligence requires no external services). Testability (deterministic outputs are verifiable by assertion). Cost control (the most common intelligence queries are the cheapest to serve).

**Forbids.** Using AI to extract information that can be parsed. Treating AI-generated structural claims as authoritative. Designing features that require AI availability for deterministic operations. Presenting semantic claims with the same confidence level as deterministic claims.

**Example.** The system must determine a function's parameter list by parsing, not by asking an AI model. The system *may* use AI to explain *why* those parameters were chosen — that is a genuinely semantic question.

---

### P4: Composition Produces Emergence

**Statement.** When intelligence at a smaller scope is composed into intelligence at a larger scope, the composition must produce properties that do not exist at the smaller scope. If a composition step produces no emergent properties, the larger-scope intelligence is merely aggregation and does not justify its existence as a distinct architectural entity.

**Motivation (from D6).** The relationship between parts is not derivable from the parts alone (D6). File A is a resolver. File B is a manager. File C is a coordinator. None of these files' intelligence contains the fact that "A, B, and C form a session subsystem in which C orchestrates user interactions, delegates disambiguation to A, and lifecycle management to B." That is an emergent property of the composition. If the system merely concatenates three files' intelligence, it has not composed — it has aggregated.

**Consequences.**
- C4.1: Every composition level must define what emergent properties it is expected to produce (interaction patterns, contracts, boundaries, architectural roles).
- C4.2: A composition that produces no emergent properties is architecturally invalid and must not be introduced.
- C4.3: Emergent properties are new intelligence, not summaries of existing intelligence.

**Enables.** Module-level insight that exceeds the sum of file-level insight. System-level architectural understanding that cannot be derived from any single module.

**Forbids.** "Module intelligence" that is merely a list of file intelligence records. Composition operations that produce only aggregates (counts, lists, unions). Treating concatenation as composition.

**Example.** Composing file intelligence into module intelligence must reveal properties such as: "these files form a pipeline where data flows A→B→C with transformation at each stage," or "B defines a protocol that A and C both conform to, establishing a dependency inversion boundary." These properties exist in no single file.

---

### P5: Intelligence Is Grounded

**Statement.** Every claim within Intelligence must trace to identifiable source material. A structural claim traces to a source position. A relational claim traces to the structural claims it connects. A behavioral claim traces to the structural and relational evidence it interprets. An interpretive claim traces to the lower-layer intelligence it synthesizes. No intelligence is ungrounded.

**Motivation (from D8).** AI inference is powerful but untrustworthy in isolation (D8). If a semantic intelligence layer claims that a function "handles authentication," and this claim cannot be traced to specific structural or relational evidence (the function calls an auth service, receives credentials as parameters, returns a token), the claim is unverifiable. Unverifiable claims accumulate into an intelligence base that cannot be audited, cannot be debugged, and cannot be trusted.

**Consequences.**
- C5.1: Every intelligence claim carries a reference to its source — a source position for deterministic claims, lower-layer intelligence references for semantic claims.
- C5.2: A consumer can traverse the grounding chain from any claim to the ultimate source material.
- C5.3: If the source material changes, all claims grounded in it are subject to invalidation.

**Enables.** Auditability: any intelligence claim can be verified by inspecting its grounding chain. Debuggability: when intelligence is wrong, the grounding chain identifies where the error was introduced. Invalidation precision: when source changes, only claims grounded in the changed source need re-evaluation.

**Forbids.** Intelligence claims with no provenance. AI-generated claims that cannot be traced to the specific intelligence they were derived from. "Floating" interpretations that reference no evidence.

---

### P6: Understanding Is Derived, Not Stored

**Statement.** Understanding is produced on demand by projecting Intelligence through a query's subject, scope, depth, and perspective. Understanding is never the system of record. If Understanding and Intelligence disagree, the Understanding is stale and must be regenerated.

**Motivation (from D4).** Understanding is always relative to a question (D4). There is no "the understanding" of a function — there is the understanding *for debugging*, the understanding *for code review*, the understanding *for onboarding*. Storing understandings creates a combinatorial explosion (every subject × every scope × every depth × every perspective) and a staleness problem (stored understandings drift from the intelligence they were derived from).

**Consequences.**
- C6.1: The system does not persist Understanding as a first-class entity. Understanding may be cached for performance but the cache is always a disposable derivative.
- C6.2: Every Understanding includes (or can reconstruct) the Intelligence version from which it was derived, enabling staleness detection.
- C6.3: Two Understandings of the same subject may differ if they were requested with different scope, depth, or perspective. This is correct behavior, not a defect.

**Enables.** Freshness without maintenance: Understanding is always as current as the Intelligence it is derived from. Perspective flexibility: the same Intelligence supports unlimited perspectives without storing each one.

**Forbids.** Treating cached explanations as authoritative. Building features that depend on Understanding persistence. Designing data models that give Understanding the same lifecycle as Intelligence.

---

### P7: Relevance Over Completeness

**Statement.** When assembling intelligence for delivery, the system must optimize for the relevance of what is included, not for the completeness of coverage. A smaller, highly relevant selection of intelligence produces better understanding than an exhaustive dump. Omission of irrelevant intelligence is a feature, not a defect.

**Motivation (from D7).** Comprehension has diminishing returns per unit of information (D7). A developer asking "what does this function do?" does not need the full type hierarchy, the module's architectural rationale, and the project's historical evolution. They need the function's behavior, its immediate context, and perhaps its most critical dependency. Including more degrades comprehension by burying the relevant signal in irrelevant noise.

**Consequences.**
- C7.1: Context assembly is a selection problem, not a collection problem. The architecture must support efficient relevance filtering, not just efficient retrieval.
- C7.2: The system must be capable of explaining *why* specific intelligence was included in a context frame (traceability of relevance decisions).
- C7.3: Token budgets, display limits, and other resource constraints are architectural parameters of context assembly, not afterthoughts.

**Enables.** Scalability: as codebases grow, intelligence volume grows, but context size remains bounded by relevance. Quality: every piece of intelligence in a context frame earns its inclusion.

**Forbids.** Assembling context by including "everything we have." Treating context size as a proxy for context quality. Designing retrieval systems that optimize for recall at the expense of precision.

---

### P8: AI Is a Consumer of Intelligence, Not Its Source of Truth

**Statement.** AI models consume Intelligence as input and produce Understanding as output. AI does not define what the system knows — Intelligence does. AI may contribute to semantic intelligence layers, but its contributions are tagged as semantic, carry provenance, and are subject to the same grounding requirements as any other intelligence claim.

**Motivation (from D8).** AI inference is powerful, expensive, non-deterministic, and untrustworthy in isolation (D8). If AI output is treated as the system's knowledge — if the system "knows" something only because an AI said it — then the system's knowledge is non-reproducible, non-auditable, and subject to model-specific biases. By positioning AI as a consumer of intelligence (it reads the structured intelligence and produces understanding) rather than the source of intelligence (it tells the system what is true), the architecture insulates itself from AI-specific failure modes.

**Consequences.**
- C8.1: AI models receive structured intelligence as input, not raw source code. Intelligence mediates between the codebase and AI.
- C8.2: AI output that contributes to Intelligence (e.g., semantic enrichment) is labeled with its provenance, tagged as semantic, and subject to the freshness contract of the semantic layer.
- C8.3: The system's deterministic and relational intelligence layers must function without any AI model.

**Enables.** AI model substitution: the AI model can be replaced without rebuilding Intelligence. Reliability: deterministic intelligence is unaffected by AI outages, regressions, or model changes. Cost control: AI is invoked for semantic operations, not for structural ones.

**Forbids.** Sending raw source code to AI without intelligence mediation. Treating AI responses as deterministic intelligence. Requiring AI availability for operations that can be served from deterministic intelligence alone. Building intelligence pipelines where AI output at one stage is the only input to the next.

**Example.** When a developer asks about a function, the system does not send the raw file to the AI and ask "what does this function do?" Instead, it assembles the function's structural intelligence (signature, parameters, body), relational intelligence (callers, callees, conformances), and any available behavioral and interpretive intelligence, then sends this *structured* intelligence to the AI for synthesis into understanding.

---

### P9: Incremental by Design

**Statement.** Every operation in the architecture — intelligence extraction, composition, invalidation, retrieval, and delivery — must be expressible as an incremental operation over a prior state. No operation may require processing the entire codebase from scratch as its normal mode.

**Motivation (from D3).** Software changes continuously, unevenly, and unpredictably (D3). If extracting intelligence requires re-parsing every file, or if composing module intelligence requires re-analyzing every file in the module, the system's cost scales with codebase size on every change. For large codebases, this makes the system unusable. Incrementality is not an optimization — it is a survival requirement.

**Consequences.**
- C9.1: Intelligence extraction must support per-file (or finer) granularity. Changing one file must not require re-extracting intelligence from unchanged files.
- C9.2: Intelligence invalidation must propagate precisely. Changing a file invalidates that file's intelligence and the composed intelligence of scopes containing it, but not the intelligence of unrelated files or scopes.
- C9.3: Composition must be incrementally updatable. Adding or removing a file from a module's scope must update the module intelligence without recomposing from scratch.

**Enables.** Responsiveness: the system reflects code changes within a bounded, predictable time. Scalability: cost scales with *change size*, not with *codebase size*.

**Forbids.** Full-codebase re-analysis as a normal operation (it may exist as a recovery mechanism). Composition algorithms that require all constituent intelligence to be present simultaneously. Invalidation strategies that conservatively invalidate everything.

---

### P10: Scope Scales Along Independent Axes

**Statement.** The architecture defines intelligence and understanding across multiple independent dimensions — subject (what entity), scope (how much surrounding context), depth (how many layers of "why"), and perspective (for what purpose). Each dimension scales independently. Scaling one dimension does not require scaling another.

**Motivation (from D4, D5).** Understanding is relative to a question (D4) and software meaning is layered (D5). A system that conflates these dimensions — that can only provide "deep understanding of a single function" or "shallow understanding of a whole module" but not "deep understanding of a module" or "shallow understanding of a function" — is artificially constrained. The dimensions must be orthogonal.

**Consequences.**
- C10.1: The intelligence model, the retrieval model, and the delivery model must support independent parameterization of subject, scope, depth, and perspective.
- C10.2: Adding a new scope level (e.g., "subsystem" between "module" and "system") must not require redesigning the intelligence model — it must be expressible as a new composition boundary.
- C10.3: Adding a new perspective (e.g., "security review") must not require new intelligence layers — it must be expressible as a new projection over existing intelligence.

**Enables.** The File → Module → Project roadmap is a progression along the scope axis. New use cases (debugging, review, onboarding) are progressions along the perspective axis. Each can evolve independently.

**Forbids.** Hardcoding a fixed set of scopes. Conflating scope with depth ("module-level understanding" implying a specific depth). Requiring perspective-specific intelligence (separate intelligence stores for "explanation intelligence" vs. "review intelligence").

---

### P11: Boundaries Define Independent Variability

**Statement.** Every architectural boundary in the system must enable independent variability on at least one side. If both sides of a boundary must change together, the boundary is unjustified overhead and must be removed.

**Motivation (from DAS-000 P3, AP5).** Abstractions justify their cost (DAS-000 P3). A boundary between two components is justified only when one component can change — be replaced, be reimplemented, evolve — without requiring changes to the other. Boundaries without independent variability are organizational fiction: they impose the cost of indirection (interfaces, serialization, protocol negotiation) without delivering its benefit (isolation).

**Consequences.**
- C11.1: Every boundary in the system must declare what varies independently on each side. "The extraction boundary separates source parsing (which varies by language) from intelligence storage (which varies by storage engine)."
- C11.2: If a change on one side of a boundary routinely requires a change on the other side, the boundary is a candidate for removal.
- C11.3: Boundaries between DAS layers (L0–L5) must satisfy this principle — each layer must be able to evolve without forcing changes in the layers above or below it.

**Enables.** Replacing the parsing engine without affecting intelligence storage. Replacing the AI model without affecting intelligence extraction. Replacing the storage engine without affecting retrieval logic. Each substitution is meaningful because the boundary enables it.

**Forbids.** Boundaries that exist "for organizational clarity" without enabling independent variability. Interfaces whose implementations are all known at design time and will never change. Layers introduced by convention rather than by identified variability.

---

### P12: Graceful Degradation over Graceful Nothing

**Statement.** When a subsystem is unavailable, slow, or produces an error, the system must deliver reduced-quality output rather than no output. The intelligence stack is designed so that each layer's absence reduces quality but does not eliminate function.

**Motivation (from P2, D8).** Intelligence is layered (P2) and AI is unreliable (D8). If the semantic layers depend on an AI service that is unavailable, the system still has deterministic and relational intelligence. That intelligence may not answer "why does this exist?" but it can answer "what is this, what are its properties, and what does it connect to?" — which is vastly more useful than an error message.

**Consequences.**
- C12.1: Every output path must define its behavior when operating with only deterministic intelligence (the minimum viable intelligence).
- C12.2: The system must communicate the quality level of its output — whether full intelligence was available or only partial intelligence was used.
- C12.3: Degradation must be *invisible to the architecture*. The same retrieval and delivery paths serve both full and degraded intelligence. There is no separate "offline mode" or "fallback mode" — there is a single mode with varying intelligence depth.

**Enables.** Offline operation with deterministic intelligence. Resilience to AI service disruption. Fast responses when semantic intelligence is not yet computed (serve deterministic immediately, enrich later).

**Forbids.** Binary availability: "either full intelligence is available or nothing is." Separate code paths for degraded operation. Error responses when partial intelligence could produce partial (but useful) output.

---

## Architectural Consequences

The following consequences are derived from the principles collectively. They apply to all DAS chapters and all implementation.

**C-Global-1: The intelligence pipeline is the primary engineering investment.** Principles P1, P3, P5, and P8 establish that intelligence quality bounds output quality, that intelligence must be grounded and layered, and that AI is a consumer of intelligence. The implication: engineering effort should focus on intelligence extraction, composition, freshness, and grounding — not on output formatting, prompt engineering, or UI polish. These downstream concerns improve automatically as intelligence improves.

**C-Global-2: The system has exactly two classes of persistent state.** Source material (code, configuration, documentation — the system's input) and Intelligence (the system's canonical asset). Everything else — understanding, context frames, cached outputs, UI state — is transient and derivable.

**C-Global-3: The number of AI calls is proportional to semantic intelligence, not to total intelligence.** Principles P3 and P8 ensure that deterministic and relational intelligence require no AI. Only behavioral and interpretive intelligence involve AI inference. As the ratio of deterministic-to-semantic intelligence grows (larger codebases with relatively fewer semantic queries), the cost efficiency improves.

**C-Global-4: The architecture supports the File → Module → Project roadmap without redesign.** Principles P4, P9, and P10 ensure that new scope levels (module, project) are composition boundaries, not architectural redesigns. Adding module intelligence is an instance of P4 (composition with emergence) at a new scope level (P10), computed incrementally (P9).

---

## Invariants

**I1: Single Canonical Asset.**
- **Statement:** All persistent, non-source state in the system is either Intelligence or derivable from Intelligence.
- **Rationale:** Multiple sources of truth produce inconsistency. If a derived artifact (a cached explanation, a precomputed summary) persists independently of Intelligence, it will eventually diverge.
- **Verification:** Enumerate all persistent stores. For each, confirm it is either (a) source material, (b) an Intelligence store, or (c) a cache with an explicit invalidation path tied to Intelligence.

**I2: Downward Layer Dependency.**
- **Statement:** No intelligence layer may depend on any layer above it.
- **Rationale:** Upward dependency creates circular reasoning (structural facts depending on interpretive claims) and prevents graceful degradation (removing the top layer breaks the bottom layer).
- **Verification:** For each intelligence layer, enumerate its inputs. Confirm all inputs are from the same layer or lower.

**I3: Deterministic Completeness.**
- **Statement:** Every property of software that can be determined by algorithmic analysis of its source is determined algorithmically.
- **Rationale:** Deterministic analysis is cheaper, faster, more reliable, and reproducible. Omitting a deterministic extraction and substituting AI inference introduces cost, latency, non-determinism, and potential error for zero benefit.
- **Verification:** For each AI-produced intelligence claim, ask: "Could this have been determined by parsing?" If yes, the invariant is violated.

**I4: Grounding Completeness.**
- **Statement:** Every intelligence claim traces to identifiable source material through a finite chain of references.
- **Rationale:** Ungrounded claims cannot be audited, debugged, or invalidated. They accumulate as unverifiable assertions that degrade trust in the intelligence base.
- **Verification:** Select any intelligence claim. Follow its grounding chain. Confirm it terminates at a source position or at deterministic intelligence that itself terminates at a source position.

**I5: Composition Emergence.**
- **Statement:** Every composition level produces at least one property that does not exist in any of its constituents.
- **Rationale:** Composition without emergence is aggregation, which adds cost (storage, computation, maintenance) without adding value.
- **Verification:** For each composed intelligence entity, identify at least one property that cannot be found in any of its constituent entities.

**I6: Incremental Expressibility.**
- **Statement:** Every intelligence operation (extraction, invalidation, composition, retrieval) is expressible as an incremental operation over a prior state.
- **Rationale:** Full-codebase operations do not scale. If any operation requires processing the entire codebase, the system becomes unusable on large codebases.
- **Verification:** For each operation, confirm it can accept a delta (changed files, changed entities) and produce a result without accessing unchanged state beyond what is needed for the delta's impact.

**I7: AI Independence of Deterministic Layers.**
- **Statement:** All deterministic and relational intelligence layers must function without any AI model being available.
- **Rationale:** AI availability is not guaranteed (service outages, cost constraints, network isolation). The majority of intelligence (structural facts, relationships) does not require AI. Making these layers depend on AI creates an unnecessary single point of failure.
- **Verification:** Disable all AI access. Confirm that structural and relational intelligence extraction, storage, retrieval, and composition still function.

---

## Non-Goals

This chapter does not:

- **Define the intelligence layers.** The specific layers (structural, relational, behavioral, interpretive — or any other decomposition) are defined in [DAS-003: Knowledge Domains](DAS-003-Knowledge-Domains.md) and [DAS-005: Intelligence Model](DAS-005-Intelligence-Model.md). This chapter establishes that intelligence *is* layered and that layers have strict downward dependency, but does not enumerate the layers.

- **Define the composition boundaries.** What constitutes a "module" or a "system" for composition purposes is defined in [DAS-005: Intelligence Model](DAS-005-Intelligence-Model.md). This chapter establishes that composition must produce emergence, but does not define the scopes.

- **Define the retrieval model.** How intelligence is queried, filtered, and projected is defined in [DAS-006: Retrieval Model](DAS-006-Retrieval-Model.md). This chapter establishes that relevance is prioritized over completeness, but does not define the query algebra.

- **Define the delivery model.** How understanding is produced from intelligence is defined in [DAS-008: AI Consumption Model](DAS-008-AI-Consumption-Model.md). This chapter establishes that understanding is derived and not stored, but does not define the delivery contract.

- **Prescribe implementation.** No principle in this chapter specifies a technology, a data structure, an algorithm, or a programming language. Principles constrain *what* and *why*; implementation determines *how*.

---

## Open Questions

**Q1: Is there a principle governing multi-language support?** *(Non-blocking)*

Decode must support multiple programming languages. This is implicitly covered by P11 (the extraction boundary separates parsing from intelligence) and P3 (deterministic extraction is language-specific in mechanism but language-independent in output). However, a principle explicitly governing language-independence of intelligence — that intelligence about a Swift function and intelligence about a Python function have the same structure — may strengthen the architecture. Deferred to DAS-002 and DAS-003 to determine whether this is a domain model concern or a principle.

**Q2: Should there be a principle governing the relationship between Intelligence and version control?** *(Non-blocking)*

Software has a temporal dimension (git history, branches, diffs). Intelligence could be versioned against commits, against working-tree state, or against both. This question has significant implications for DAS-010 (Incremental Update Model) but may not rise to the level of a principle. Deferred to DAS-010.

**Q3: Is "Understanding is the canonical output" a principle or a consequence?** *(Non-blocking)*

This chapter treats it as a consequence of P1 (Intelligence is the canonical asset) combined with P6 (Understanding is derived). An alternative framing would elevate it to a principle in its own right. The current framing was chosen because the constraint on Understanding follows logically from the principles about Intelligence — it does not require independent justification.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (this chapter)
        ├── DAS-002 (Decode Intermediate Representation)
        │     ├── DAS-003 (Tier Model)
        │     ├── DAS-004 (Entity Model)
        │     │     └── DAS-005 (Relationship Model)
        │     ├── DAS-006 (Pass Architecture)
        │     ├── DAS-007 (Index Architecture)
        │     ├── DAS-008 (Retrieval Architecture)
        │     │     └── DAS-009 (Context Assembly)
        │     │           └── DAS-011 (Consumer Architecture)
        │     ├── DAS-010 (Incremental Update Model)
        │     └── DAS-012 (Storage Realization)
```

All DAS chapters at L1–L5 depend on this chapter. No chapter depends on this chapter that this chapter also depends on (no circularity).

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub with section headings and open questions
1.0 — 2026-06-25 — Principal Architect — Full chapter: 12 principles, 7 invariants, domain analysis, consequences
```
