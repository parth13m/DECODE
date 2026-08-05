# DAS-003: Tier Model

```
Chapter:       DAS-003
Title:         Tier Model
Status:        Frozen
Version:       1.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002
Depended By:   DAS-004, DAS-005, DAS-006, DAS-007, DAS-008, DAS-009, DAS-010
Supersedes:    DAS-003 (Knowledge Domains — stub, never approved)
Superseded By: —
Layer:         L1
```

## Abstract

This chapter defines the tier model — the ordered classification of atomic unit objectivity within the Decode Intermediate Representation (DIR). It enumerates three tiers (Deterministic, Derived, Semantic), defines their properties — objectivity, reproducibility, confidence model, freshness contract, computation cost, and AI dependency — and establishes the rules governing tier assignment, cross-tier dependency, and predicate domain classification. The tier model is the mechanism by which DAS-001 P2 (layered intelligence with downward dependency) and P3 (deterministic before semantic) are enforced at the atomic unit level.

## Motivation

DAS-002 requires that every atomic unit in the DIR declares a tier (I-TIER-1 through I-TIER-5) but does not enumerate the specific tiers. It establishes the contract: tiers are totally ordered, at least two exist, every unit declares one at creation, and derivation flows from lower tiers to higher tiers. This chapter fulfills that contract by answering:

1. **How many tiers exist, and why?** Too few tiers conflate knowledge with genuinely different reliability characteristics. Too many create classification burden without architectural benefit. The number must be justified by distinct objectivity boundaries, not by taxonomic aesthetics.

2. **What properties distinguish each tier?** A tier is not merely a label — it determines how a unit is produced, how it is trusted, how quickly it must be updated, what happens when it is unavailable, and what confidence a consumer may assign to it. Without explicit properties, tier assignment devolves into subjective judgment.

3. **What rules govern tier assignment?** If two producers independently analyze the same source and assign the same claim to different tiers, the DIR is inconsistent. Tier assignment must be derivable from the predicate and the production method, not from producer discretion.

4. **How do tiers interact?** DAS-002 I-TIER-5 establishes that derivation flows upward (lower tiers to higher tiers), but the full implications — for freshness propagation, invalidation cascades, and graceful degradation — require elaboration.

Without this chapter, the tier field on every atomic unit is an opaque integer with no defined semantics. Producers cannot assign tiers consistently, consumers cannot interpret them reliably, and the principles P2 and P3 cannot be verified.

**Source dependencies:**
- [DAS-001 P2](DAS-001-Architectural-Principles.md) — intelligence is layered with strict downward dependency
- [DAS-001 P3](DAS-001-Architectural-Principles.md) — deterministic before semantic
- [DAS-001 P12](DAS-001-Architectural-Principles.md) — graceful degradation
- [DAS-002](DAS-002-Decode-Intermediate-Representation.md) — atomic unit contract, tier field invariants (I-TIER-1 through I-TIER-5), confidence invariants (I-CONF-1 through I-CONF-4)

## Terminology

**Tier** — An ordered classification of an atomic unit's objectivity within the DIR. Each tier defines a level of epistemic reliability: how certainly the claim is known to be true, given well-formed source material. Tiers are totally ordered (T0 < T1 < T2). Lower tiers are more objective, more stable, cheaper to produce, and more reliably correct. Higher tiers are more interpretive, more volatile, more expensive, and less certain. *Is:* T0 (Deterministic) — a parsed function signature. T1 (Derived) — a file role classification computed by rules. T2 (Semantic) — an AI-produced behavioral characterization. *Is not:* a quality judgment ("tier 0 is better"), a knowledge domain ("structural" vs. "behavioral"), or a priority ranking. `See DAS-002`

**Deterministic Tier (T0)** — The lowest tier. Claims at T0 are provably correct given well-formed source material. They are extracted by algorithmic analysis that any conforming producer would reproduce identically. T0 claims are grounded directly to source positions. *Is:* "function `authenticate` has return type `Bool`" (verifiable by inspecting the declaration); "class `UserManager` calls function `validate`" (verifiable by inspecting the call site). *Is not:* "function `authenticate` handles login logic" (requires interpretation of what "login logic" means). `INTRODUCED`

**Derived Tier (T1)** — The middle tier. Claims at T1 are computed from T0 facts by deterministic algorithms that apply patterns, rules, conventions, or metrics. The computation is reproducible (same algorithm + same T0 input = same T1 output), but the conclusion is not provably correct — the patterns may not reflect the actual nature of the software. T1 claims are grounded through the T0 units they were computed from. *Is:* "file `SessionCoordinator.swift` has role `coordinator`" (classified by naming pattern + dependency structure — reproducible but possibly wrong); "module `Auth` has high internal cohesion" (computed from relationship density — deterministic metric but interpretive label). *Is not:* "function `authenticate` has return type `Bool`" (this is provable, hence T0); "this module exists to isolate authentication concerns from the rest of the system" (this requires interpretive judgment, hence T2). `INTRODUCED`

**Semantic Tier (T2)** — The highest tier. Claims at T2 are produced by interpretive inference — analysis that requires judgment, synthesis, or reasoning beyond what deterministic algorithms can establish. T2 claims are non-deterministic in general: different inference engines (or the same engine at different times) may produce different but equally valid outputs. T2 claims are grounded through the lower-tier units they interpret plus the inference method that produced them. *Is:* "function `authenticate` exists to bridge the legacy auth system with the new token-based flow" (requires understanding intent); "the design trade-off in `CacheManager` favors memory efficiency over access latency" (requires evaluating design decisions). *Is not:* "function `authenticate` calls `validateToken`" (deterministically observable, hence T0); "file `CacheManager.swift` has role `service`" (rule-derivable, hence T1). `INTRODUCED`

**Objectivity** — The degree to which a claim's truth is independent of the observer or the method used to establish it. A fully objective claim is true regardless of who evaluates it or how. A fully subjective claim depends on the evaluator's judgment. The tier model quantifies objectivity as an ordered classification, not a continuous measure. `INTRODUCED`

**Reproducibility** — The property that the same production method applied to the same input produces the same output. T0 and T1 claims are reproducible (deterministic algorithms). T2 claims are not reproducible in general (different inference engines may produce different outputs). Reproducibility determines whether a claim can be verified by re-execution and whether it can serve as a stable foundation for higher-tier derivation. `INTRODUCED`

**Freshness Contract** — The guarantee that a specific tier provides about how current its content is relative to the source material it was derived from. Each tier has a distinct freshness contract reflecting its computation cost and update characteristics. `See DAS-001`

**Predicate Domain** — A classification of what aspect of software a predicate describes, independent of its tier. Predicates within the same domain address the same dimension of software (structure, behavior, design, etc.). A predicate's domain determines which tiers it may occupy; some domains are confined to a single tier, others span multiple tiers. `INTRODUCED`

## Domain Analysis

**DA-1: Knowledge about software exists on a spectrum of objectivity, but the spectrum has natural breakpoints.** At one extreme: "this function takes two `String` parameters." This is not a matter of opinion — anyone examining the source reaches the same conclusion. At the other extreme: "this function exists to work around a framework limitation that was never properly fixed." This is an interpretation that different analysts may disagree about. Between these extremes lie claims like "this file serves as a coordinator" — produced by systematic analysis but not provably correct. The objectivity spectrum is not uniform; it has at least two natural breakpoints that separate qualitatively different kinds of knowledge.

**DA-2: Objectivity determines trust, and trust determines how consumers should use knowledge.** A consumer building an impact analysis chain — "if function A changes, what else breaks?" — needs T0 relationships (call edges, conformance, containment) that are provably correct. Using interpretive claims ("A is architecturally coupled to B") in an automated impact chain produces unreliable results. A consumer explaining code to a developer can tolerate and benefit from interpretive claims. Trust requirements vary by consumer and by use case, and they vary along objectivity lines.

**DA-3: Objectivity correlates with — but is not identical to — several other properties.** More objective claims are also typically cheaper to produce, faster to update, available without external services, and reproducible across implementations. Less objective claims are typically expensive, slow to update, dependent on external services (AI), and non-reproducible. These correlations are not accidental — they reflect the fundamental difference between reading a fact from source and inferring a meaning from context. But they are correlations, not identities: the defining property of a tier is objectivity, and the other properties follow as consequences.

**DA-4: Not all deterministic computation produces provably correct results.** A parser extracting a function's parameter list produces a provably correct result — the parameters are what the parser says they are. A rule engine classifying a file as a "coordinator" based on its naming pattern and dependency structure produces a deterministic result (the same rules on the same input always produce the same output), but the classification is not provably correct — the file might not actually be a coordinator. This distinction matters architecturally: the first kind of claim can be trusted absolutely; the second can be trusted conditionally. Conflating them under a single "deterministic" classification misleads consumers about reliability.

**DA-5: AI independence is an architectural boundary, not just a property difference.** When AI services are unavailable — due to network failure, cost constraints, rate limits, or offline operation — the system must still function (DAS-001 P12). This requires a clear boundary between claims that need AI and claims that do not. If the tier model does not capture this boundary, the system cannot determine what to serve during AI outages. The boundary is binary: a claim either requires AI or it does not. This binary property must be visible in the tier classification.

**DA-6: Freshness requirements differ categorically, not merely quantitatively.** When a developer saves a file, structural facts about that file (entities, signatures, relationships) must be updated before the next query. A five-second delay in structural freshness produces visibly wrong results. But an interpretive claim like "this file's design reflects a strategy pattern" can tolerate minutes or hours of staleness — the design assessment doesn't change on every save. These are not different points on the same freshness scale; they represent fundamentally different freshness regimes. The tier model must capture this difference.

**DA-7: The objectivity gradient is stable across producers and across time.** If a Swift parser and a Python parser both extract function signatures, both produce T0 claims. If a rule-based classifier and a different rule-based classifier both classify file roles, both produce T1 claims. If two different AI models both produce behavioral characterizations, both produce T2 claims. The tier assignment depends on the nature of the claim and the nature of the method — not on the identity of the producer. This stability is what makes the tier model a durable architectural classification rather than a producer-specific annotation.

## Candidates

The architectural question is: **how many tiers should the DIR define, and what should they represent?**

### Candidate A: Two Tiers (Deterministic, Semantic)

Two tiers representing the fundamental dichotomy: claims that are algorithmically provable versus claims that require interpretive inference.

- **T0 — Deterministic:** Everything extractable or computable by algorithm with certainty. Includes parsed facts, resolved relationships, computed metrics, rule-based classifications.
- **T1 — Semantic:** Everything requiring interpretive inference. Includes AI-derived purpose, behavioral characterization, design assessment.

**Strengths:** Maximum simplicity. The boundary is clear and unambiguous. Every claim is either provable or it is not. Satisfies the minimum required by DAS-002 I-TIER-2. No classification ambiguity within tiers.

**Weaknesses:** Conflates two fundamentally different kinds of deterministic claims: provably correct facts (a function's parameter list) and deterministic-but-fallible conclusions (a file's role classification). DAS-002 I-CONF-2 requires that "a unit at the lowest (most deterministic) tier must have deterministic confidence." Under this model, rule-based classifications would have deterministic confidence — misrepresenting their reliability. Consumers cannot distinguish between claims they can trust absolutely and claims that are merely reproducible.

**Disqualifying condition:** The confidence invariant (DAS-002 I-CONF-2) forces all units at the lowest tier to carry deterministic confidence. Rule-based classifications do not deserve deterministic confidence. Placing them at T0 violates the spirit of the confidence model. Placing them at T1 (Semantic) misrepresents their AI independence and reproducibility.

### Candidate B: Three Tiers (Deterministic, Derived, Semantic)

Three tiers representing three qualitatively distinct objectivity levels: provably correct, reproducibly inferred, and interpretively inferred.

- **T0 — Deterministic:** Claims provably correct from source analysis. Directly grounded to source positions.
- **T1 — Derived:** Claims computed from T0 facts by deterministic methods. Reproducible and AI-independent, but not provably correct.
- **T2 — Semantic:** Claims produced by interpretive inference. Non-deterministic, AI-dependent.

**Strengths:** Captures both critical boundaries identified in DA-4 and DA-5: the trust boundary (T0 is provable; T1 is not) and the AI-availability boundary (T0 and T1 are AI-independent; T2 is not). Each tier has a distinct confidence profile, freshness contract, and degradation behavior. Graceful degradation (DAS-001 P12) has two fallback levels: full system (T0+T1+T2), AI-independent (T0+T1), minimal (T0).

**Weaknesses:** More complex than two tiers. The T0/T1 boundary requires judgment: is a specific deterministic computation "provably correct" or merely "reproducible"? Some edge cases exist (e.g., a metric that is mathematically precise but whose interpretation is subjective).

**Disqualifying condition:** None identified.

### Candidate C: Four Tiers (Extracted, Relational, Behavioral, Interpretive)

Four tiers following the original RFC-000 proposal, decomposing knowledge into progressively more interpretive layers.

- **T0 — Extracted:** Single-entity facts parsed from source (signatures, types, line ranges).
- **T1 — Relational:** Cross-entity facts resolved from source (calls, conformsTo, imports).
- **T2 — Behavioral:** Characterizations of how software behaves (control flow, state transitions, side effects).
- **T3 — Interpretive:** Assessments of why software exists and whether its design is sound (purpose, trade-offs, architectural role).

**Strengths:** Fine-grained. Each tier has a clear domain focus. Progression is intuitive.

**Weaknesses:** The T0/T1 boundary is not an objectivity boundary. "Function `foo` has return type `Bool`" (T0) and "function `foo` calls function `bar`" (T1) are equally objective — both are deterministically extractable from source, both are provably correct, both have identical confidence. The distinction between them is derivation scope (single entity vs. cross-entity), not objectivity. This violates the tier model's defining criterion: tiers must represent objectivity levels, not knowledge domains. Additionally, T2 and T3 are both non-deterministic and AI-dependent; splitting them doubles the classification burden without enabling different architectural treatment (both have the same freshness contract, the same AI dependency, the same confidence model).

**Disqualifying condition:** The T0/T1 boundary does not represent an objectivity difference. Both are deterministic with identical reliability. Separating them into different tiers conflates knowledge domain (structural vs. relational) with objectivity (how certainly it is known). Knowledge domains are a classification concern for predicates, not for tiers.

### Candidate D: Continuous Scale

Rather than discrete tiers, each unit carries a continuous objectivity score on [0.0, 1.0].

**Strengths:** Maximum granularity. No classification boundary disputes. Each unit carries exact objectivity information.

**Weaknesses:** Objectivity is not measurable on a continuous scale. What does 0.73 objectivity mean? How does a producer assign 0.73 versus 0.74? Continuous scales require calibration, and there is no ground truth to calibrate against. Every architectural decision that depends on tier (freshness contract, degradation behavior, confidence model) would require arbitrary thresholds, reintroducing discrete boundaries. The DAS-002 invariants (I-TIER-1 through I-TIER-5) are defined for ordered discrete tiers, not for continuous values.

**Disqualifying condition:** Objectivity is not continuously measurable. A continuous scale introduces arbitrary precision that does not correspond to any architectural distinction.

## Evaluation

The evaluation criteria are derived from the domain analysis and DAS-001/DAS-002 constraints:

| Criterion | Two Tiers (A) | Three Tiers (B) | Four Tiers (C) | Continuous (D) |
|-----------|---------------|-----------------|-----------------|----------------|
| Each boundary is an objectivity boundary | Yes (1 boundary) | **Yes (2 boundaries)** | No (T0/T1 is scope, not objectivity) | N/A (no boundaries) |
| Satisfies DAS-002 I-CONF-2 (confidence bounded by tier) | No — forces deterministic confidence on heuristic claims | **Yes — each tier has natural confidence range** | Partial — T0/T1 both deterministic | No — requires arbitrary confidence thresholds |
| Enables graceful degradation (DAS-001 P12) | 1 fallback level | **2 fallback levels** | 2 fallback levels | No discrete fallback levels |
| Captures AI-availability boundary (DA-5) | Yes | **Yes** | Yes | Requires arbitrary threshold |
| Captures trust boundary (DA-4) | No — conflates provable and heuristic | **Yes** | Partial — splits provable unnecessarily | Requires arbitrary threshold |
| Minimal classification burden | **Minimal** | Low | Moderate | High (calibration needed) |
| Tier assignment is derivable, not discretionary | Yes | **Yes** | Partially (T2 vs T3 unclear) | No (continuous assignment requires judgment) |

Candidate A (Two Tiers) fails on the trust boundary: it cannot distinguish provably correct facts from deterministic-but-fallible conclusions without violating DAS-002 I-CONF-2.

Candidate C (Four Tiers) fails on the objectivity criterion: the T0/T1 boundary represents derivation scope, not objectivity. The T2/T3 boundary duplicates AI-dependent tiers without enabling different architectural treatment.

Candidate D (Continuous) fails on measurability: objectivity is not continuously quantifiable, and a continuous scale reintroduces discrete boundaries through arbitrary thresholds.

Candidate B (Three Tiers) satisfies every criterion. Each boundary represents a genuine objectivity transition. The model is minimally complex while capturing the two critical architectural boundaries.

## Decision

**The DIR defines three tiers: T0 (Deterministic), T1 (Derived), and T2 (Semantic).** Each tier represents a qualitatively distinct level of objectivity. The two boundaries between tiers capture the two critical architectural distinctions: the trust boundary (provably correct vs. not provably correct) and the AI-availability boundary (AI-independent vs. AI-dependent). The three-tier model is the minimum classification that captures both boundaries.

---

## Tier Definitions

### T0 — Deterministic

**Definition.** A claim is at T0 if and only if it is provably correct given well-formed source material. "Provably correct" means: any conforming producer analyzing the same source material at the same version will produce the same claim. The claim can be verified by direct inspection of the source.

**Properties.**

| Property | T0 Value |
|----------|----------|
| Objectivity | Absolute — claim is either true or source is malformed |
| Reproducibility | Full — same input, same output, any conforming producer |
| AI dependency | None — T0 claims require no AI |
| Computation cost | Low — parsing and algorithmic analysis |
| Confidence | Deterministic — the claim is as certain as the source |
| Typical producers | Frontends (language parsers), deterministic analysis passes |

**Examples.**
- "Function `authenticate` has return type `Bool`" — verifiable at the declaration site
- "Class `UserManager` contains method `resolveUser`" — verifiable from AST structure
- "File `AuthService.swift` imports module `Foundation`" — verifiable from import declaration
- "Function `login` calls function `validateCredentials`" — verifiable from the call site
- "Type `SessionManager` conforms to protocol `Observable`" — verifiable from the conformance declaration
- "Function `process` has line range 42–87" — verifiable from source positions

**Boundary rule.** A claim is T0 if a reviewer can point to a specific location (or set of locations) in source and confirm: "this source structure proves the claim." If the reviewer must reason about patterns, apply conventions, or exercise judgment to confirm the claim, it is not T0.

### T1 — Derived

**Definition.** A claim is at T1 if and only if it is computed from T0 facts by a deterministic algorithm, but the conclusion is not provably correct from source alone. The algorithm is reproducible (same algorithm applied to the same T0 input produces the same T1 output), but the conclusion involves applying patterns, rules, conventions, or heuristics that may not reflect the actual nature of the software.

**Properties.**

| Property | T1 Value |
|----------|----------|
| Objectivity | High — deterministic process, fallible conclusion |
| Reproducibility | Full — same algorithm + same input = same output |
| AI dependency | None — T1 claims require no AI |
| Computation cost | Low to moderate — algorithmic analysis over T0 facts |
| Confidence | Bounded: not deterministic (the conclusion may be wrong), not inferred (the process is deterministic). Confidence within T1 may vary (high, moderate, low) based on the strength of pattern match. |
| Typical producers | Rule-based classifiers, pattern detectors, metric computers, convention analyzers |

**Examples.**
- "File `SessionCoordinator.swift` has role `coordinator`" — classified by naming pattern (`*Coordinator`) and dependency structure (many outgoing calls, few incoming). The classification is deterministic but the file might not actually be a coordinator.
- "Module `Auth` has high internal cohesion" — computed from the ratio of intra-module to inter-module relationships. The metric is deterministic but the label "high cohesion" applies a threshold that is conventional, not proven.
- "This file's purpose is dependency injection" — derived from the pattern: the file's primary entity constructs and provides instances of protocol-conforming types. The derivation is algorithmic but the purpose attribution is not provable.
- "These three files form a pipeline pattern" — detected by analyzing relationship topology: A calls B, B calls C, data flows linearly. The topology analysis is deterministic but the "pipeline" classification is a pattern match that may not reflect the developers' intent.

**Boundary rule.** A claim is T1 if: (a) it is computed from T0 facts without AI, AND (b) a reviewer could plausibly disagree with the conclusion while accepting all the T0 facts it was derived from. If the reviewer cannot disagree without disputing the source itself, the claim is T0. If the computation requires AI, the claim is T2.

### T2 — Semantic

**Definition.** A claim is at T2 if and only if it is produced by interpretive inference — analysis that requires judgment, synthesis, or reasoning beyond what deterministic algorithms can establish. T2 claims are non-deterministic in general: different inference engines, or the same engine at different times, may produce different but equally valid outputs.

**Properties.**

| Property | T2 Value |
|----------|----------|
| Objectivity | Variable — depends on the quality of inference and the nature of the claim |
| Reproducibility | None in general — different producers may produce different valid outputs |
| AI dependency | Typically required — T2 claims are the primary consumer of AI inference |
| Computation cost | High — inference, synthesis, reasoning |
| Confidence | Inferred — ranges from high-confidence inference (strong grounding, clear evidence) to low-confidence inference (weak grounding, ambiguous evidence). Never deterministic. |
| Typical producers | Semantic enrichment passes (AI-based), human annotators |

**Examples.**
- "Function `authenticate` exists to bridge the legacy auth system with the new token-based flow" — requires understanding architectural history and design intent
- "The design trade-off in `CacheManager` favors memory efficiency over access latency" — requires evaluating competing design concerns
- "This error handling strategy is defensive because the upstream API has undocumented failure modes" — requires understanding the relationship between implementation decisions and external constraints
- "The `SessionResolver` uses a scoring approach rather than strict matching because session disambiguation is inherently ambiguous" — requires understanding why a design choice was made

**Boundary rule.** A claim is T2 if producing it requires reasoning that goes beyond applying deterministic rules to T0 facts. If the claim could be produced by a deterministic algorithm (even a complex one) without AI, it belongs at T0 or T1. The key test: does the production require *understanding* the software, or only *analyzing* it?

---

## Predicate Domain Classification

DAS-002 I-PRED-2 requires that each predicate declares "its domain — which knowledge domain it belongs to." A predicate domain classifies what aspect of software a predicate describes, independent of its tier.

### Domains

**Structural.** Predicates about what exists and how it is organized. Entity properties: names, signatures, types, visibility, line ranges, containment. These predicates are typically T0 — the facts they capture are directly observable from source.

**Relational.** Predicates about connections between entities. Calls, conformsTo, inherits, imports, dependsOn, contains. These predicates are typically T0 — the relationships they capture are deterministically extractable from source.

**Classificatory.** Predicates about the categorization of entities based on their structural and relational properties. File roles, architectural patterns, cohesion levels, entity classifications. These predicates are typically T1 — their values are computed by rules but not provable from source.

**Behavioral.** Predicates about how software behaves at runtime — control flow, state transitions, side effects, data flow. Some behavioral predicates are T0 (directly observable control flow), some are T1 (inferred data flow patterns), and some are T2 (characterized side effect semantics).

**Interpretive.** Predicates about why software exists, what trade-offs it embodies, and how its design should be evaluated. Purpose, design rationale, architectural role justification, quality assessment. These predicates are always T2 — they require interpretive judgment.

### Domain-Tier Affinity

Each predicate domain has a natural tier affinity — the tier at which most predicates in that domain reside. Some domains span tiers; some are confined to one tier.

```
Domain           Typical Tier    Tier Range
─────────────────────────────────────────────
Structural       T0              T0 only
Relational       T0              T0 only
Classificatory   T1              T1 (possibly T0 if convention-free)
Behavioral       T0–T2           T0 (observable), T1 (pattern-derived), T2 (characterized)
Interpretive     T2              T2 only
```

### Maximum Deterministic Tier

DAS-002 I-PRED-2 requires each predicate to declare its "maximum deterministic tier" — the highest tier at which the predicate can be established deterministically. This chapter defines the concept:

**Maximum Deterministic Tier (MDT)** — For a given predicate, the highest tier at which a unit carrying that predicate can be produced by a deterministic (reproducible) method. Units at or below the MDT have reproducible provenance. Units above the MDT have non-reproducible provenance.

- Structural and relational predicates: MDT = T0.
- Classificatory predicates: MDT = T1.
- Behavioral predicates: MDT varies (T0 for directly observable behavior, T1 for pattern-derived behavior).
- Interpretive predicates: MDT = none (no deterministic method can produce them; they are always T2).

A unit whose tier exceeds its predicate's MDT is valid only if the predicate permits semantic-tier production. A predicate with MDT = T0 (e.g., `hasReturnType`) at T1 or T2 is an error — the claim should have been established deterministically. A predicate with no MDT (e.g., `hasPurpose`) is always T2.

---

## Freshness Contracts Per Tier

Each tier provides a distinct freshness contract — a guarantee about how quickly its content is updated after the source material it derives from changes. Freshness contracts reflect the computation cost and update characteristics of each tier.

### T0 Freshness: Source-Synchronous

T0 claims must be updated whenever their source material changes, before the changed content is served to any consumer. "Before served" means: a consumer querying the DIR after a source change must not receive stale T0 claims about the changed source. T0 freshness is synchronous with source — not real-time-synchronous (which is an implementation concern), but query-synchronous (no stale T0 claims are served).

**Rationale.** T0 claims are cheap to produce (parsing is fast). Stale T0 claims are worse than missing claims — a consumer that receives "function `foo` has return type `Int`" when the source now says `Bool` is actively misled. The cost of T0 freshness is bounded by the cost of re-parsing changed files, which is small relative to the harm of serving stale deterministic facts.

### T1 Freshness: Source-Synchronous with Propagation Delay

T1 claims must be updated whenever the T0 facts they derive from change. Because T1 computation depends on T0 output, T1 freshness is synchronous with T0 — but T1 may lag T0 by the time needed to recompute after T0 updates. T1 claims that are stale relative to their T0 inputs must be marked as invalidated (DAS-002 lifecycle) until recomputed.

**Rationale.** T1 computation is fast (rule application, pattern matching) but depends on T0 output. The update is a cascade: source changes → T0 recomputed → T1 inputs may change → T1 recomputed. The invalidation model (DAS-002 I-LC-2, I-GND-3) handles the intermediate state: T1 units are marked invalidated, triggering recomputation.

### T2 Freshness: Eventual

T2 claims tolerate staleness. When source changes, T2 claims derived from the changed source are marked invalidated but need not be immediately recomputed. Recomputation occurs when a consumer requests T2 content or when the system proactively enriches in the background. The maximum tolerable staleness is a policy decision, not an architectural constant, but the architecture guarantees:

1. T2 claims are never served without an indication of their freshness state (active vs. invalidated).
2. Stale T2 claims are preferable to no T2 claims (DAS-001 P12).
3. T2 recomputation is triggered by the same invalidation cascade as T1 (DAS-002 I-GND-3), but the recomputation schedule is decoupled from the invalidation event.

**Rationale.** T2 computation is expensive (AI inference). Re-running AI enrichment on every file save would be prohibitively costly and wasteful — most saves do not change the interpretive nature of the code. The eventual freshness contract allows the system to batch, defer, and prioritize T2 recomputation without violating correctness guarantees. The consumer always knows whether it is seeing fresh or stale T2 content.

### Freshness Summary

| Tier | Freshness Contract | Stale Content Served? | Recomputation Trigger |
|------|-------------------|----------------------|----------------------|
| T0 | Source-synchronous | Never — stale T0 is architectural defect | Source change (immediate) |
| T1 | Source-synchronous with propagation delay | Briefly, during recomputation — marked invalidated | T0 input change (cascaded) |
| T2 | Eventual | Yes, marked invalidated — preferable to absent | Consumer request or background policy |

---

## Confidence Model Per Tier

DAS-002 I-CONF-1 requires an ordered confidence scale. DAS-002 I-CONF-2 requires that confidence is bounded by tier. This section defines the confidence model within and across tiers.

### Confidence Scale

The DIR uses a four-value ordered confidence scale:

```
deterministic > high > moderate > low
```

**Deterministic.** The claim is provably correct given well-formed source material. Reserved exclusively for T0 claims.

**High.** The claim is produced by a reliable method with strong supporting evidence. The method may be deterministic (T1 with strong pattern match) or non-deterministic (T2 with clear grounding and high-quality inference). The claim is likely correct but not provably so.

**Moderate.** The claim is produced by a method with supporting evidence, but the evidence is partial, ambiguous, or the method has known limitations. The claim is plausible but uncertain.

**Low.** The claim is produced by a method with weak evidence or from patterns that frequently produce incorrect results. The claim is speculative.

### Tier-Confidence Bounds

Each tier defines which confidence values are permissible:

| Tier | Permitted Confidence | Rationale |
|------|---------------------|-----------|
| T0 | `deterministic` only | T0 claims are provably correct. Any T0 claim with less than deterministic confidence is either miscategorized (should be T1) or its producer is flawed. |
| T1 | `high`, `moderate`, `low` | T1 claims are reproducible but fallible. `deterministic` is forbidden (they are not provable). The confidence value reflects the strength of the pattern match or rule application. |
| T2 | `high`, `moderate`, `low` | T2 claims are interpretive. `deterministic` is forbidden (they are not provable). The confidence value reflects the quality of inference and grounding. |

**I-CONF-2 enforcement.** A T0 unit with confidence other than `deterministic` is an error. A T1 or T2 unit with `deterministic` confidence is an error. These are verifiable invariants.

### Confidence and Consumption

Consumers may filter by confidence. A consumer performing automated impact analysis may require `deterministic` confidence (T0 only). A consumer producing explanations for a developer may accept all confidence levels, annotating lower-confidence claims appropriately. The confidence field enables this filtering without requiring consumers to understand tier semantics directly — though tier and confidence are correlated, the confidence field is the consumer-facing signal.

---

## Tier Assignment Rules

Tier assignment must be derivable from the predicate and the production method, not from producer discretion. The following rules govern tier assignment:

**TA-1: Assignment by production method.** A unit's tier is determined by how it was produced:
- Extracted or computed from source with provable correctness → T0
- Computed from T0 facts by deterministic algorithm without provable correctness → T1
- Produced by interpretive inference → T2

**TA-2: Assignment is immutable.** A unit's tier is declared at creation and never changes (DAS-002 I-TIER-3). If the same claim could be established at multiple tiers (e.g., a file's purpose derived by rules at T1 and by AI at T2), the system may hold both units. They are competing claims resolved by the lifecycle model (DAS-002 I-PRED-3).

**TA-3: Tier must not exceed predicate's maximum deterministic tier without semantic authorization.** If a predicate's MDT is T0, all units with that predicate must be T0. Producing a `hasReturnType` unit at T1 or T2 is an error — the claim should be deterministically established. If a predicate has no MDT (interpretive predicates), units must be T2.

**TA-4: Tier is a property of the unit, not of the predicate.** A predicate may appear at multiple tiers (if its domain spans tiers). The predicate `hasBehavior` might have T0 units (directly observable control flow), T1 units (pattern-derived behavioral classification), and T2 units (AI-characterized behavioral semantics). Each unit declares its own tier based on how it was produced.

**TA-5: The lowest valid tier takes precedence.** If a claim can be established deterministically (T0), it must be established deterministically (DAS-001 P3). A producer must not establish a T1 or T2 claim when a T0 establishment is possible. This is the unit-level expression of "deterministic before semantic."

---

## Cross-Tier Dependencies

### Derivation Direction

DAS-002 I-TIER-5 establishes: no unit at tier N may be derived from a unit at tier M where M > N. This chapter elaborates:

**CTD-1: T0 units derive only from source material.** T0 units are grounded directly to source positions. They do not depend on T1 or T2 units. This is what makes T0 the foundation: it is self-sufficient.

**CTD-2: T1 units derive from T0 units and possibly from other T1 units.** T1 computation reads T0 facts (entities, relationships, structural properties) and may read other T1 facts (a classification that depends on another classification). T1 units never derive from T2 units.

**CTD-3: T2 units derive from T0 units, T1 units, and possibly other T2 units.** Semantic inference consumes deterministic facts and derived classifications as input. A T2 behavioral characterization may reference T0 relationships and T1 role classifications. A T2 design assessment may build on a T2 purpose characterization. Derivation within T2 is permitted (DAS-002 I-TIER-5 only prohibits downward derivation).

### Invalidation Cascade

When source changes, invalidation propagates upward through the tier hierarchy:

1. Source change invalidates T0 units grounded to the changed source (DAS-002 I-LC-2).
2. Invalidated T0 units cascade to T1 units that derive from them (DAS-002 I-GND-3).
3. Invalidated T1 units cascade to T2 units that derive from them.
4. Invalidated T2 units cascade to other T2 units that derive from them.

Invalidation always flows upward (T0 → T1 → T2), never downward (T2 changes cannot invalidate T0). This is a direct consequence of the derivation direction: only a unit's inputs can trigger its invalidation.

### Graceful Degradation Levels

The three-tier model provides two levels of degradation (DAS-001 P12):

**Level 0 (Full system): T0 + T1 + T2.** All tiers available. Consumers receive provable facts, derived classifications, and semantic interpretations.

**Level 1 (AI unavailable): T0 + T1.** Semantic tier unavailable or entirely stale. Consumers receive provable facts and derived classifications. Loss: no purpose explanations, no behavioral characterization, no design assessment. Gain: all deterministic and rule-based knowledge remains available. System can still answer "what is this?" and "what is its role?" but not "why does this exist?"

**Level 2 (Minimal): T0 only.** Derived tier also unavailable (rule engine failure, fresh install before classification runs). Consumers receive only provable facts. Loss: no classifications, no patterns, no semantic content. Gain: structural truth. System can answer "what exists?" and "how does it connect?" but not "what role does it play?" or "why?"

Each degradation level is architecturally valid — the system does not have a "broken" state where it serves nothing. It has states where it serves less, and it communicates the depth of what it serves.

---

## Tier Lifecycle Interaction

The tier model interacts with the atomic unit lifecycle (DAS-002) as follows:

**TL-1: Tier determines recomputation priority.** When multiple invalidated units require recomputation, T0 units are recomputed first (cheapest, most foundational), then T1 (depends on T0), then T2 (most expensive, depends on T0 and T1). This ordering is a consequence of the derivation direction, not a policy choice.

**TL-2: Supersession respects tier.** When a new unit supersedes an old unit (DAS-002 I-LC-3), both must be at the same tier. A T2 unit cannot supersede a T0 unit — they represent different kinds of claims about the same subject. If a T0 and a T2 unit make competing claims about the same subject and predicate, both coexist; the consumer chooses which to use based on the confidence model and the use case.

**TL-3: Tier affects garbage collection eligibility.** T0 and T1 units are cheap to recompute; their invalidated predecessors may be garbage-collected aggressively. T2 units are expensive to recompute; their invalidated predecessors may be retained longer as stale-but-useful content (DAS-001 P12). Garbage collection policy is a DAS-012 concern; this chapter establishes only that tier informs the policy.

---

## Architectural Consequences

**C1: Every atomic unit is classifiable by a small, stable set of objectivity levels.** The three tiers (T0, T1, T2) are few enough to learn immediately and stable enough to last indefinitely. The tier set changes only if a new objectivity boundary is discovered — which is unlikely given that the two identified boundaries (trust and AI-availability) are fundamental.

**C2: Consumer trust is tier-mediated.** A consumer that needs provable facts filters for T0. A consumer that accepts reproducible classifications includes T1. A consumer that wants full understanding includes T2. No consumer needs to inspect provenance to determine trust level — tier encodes it.

**C3: AI outages affect only T2.** When AI services are unavailable, T0 and T1 continue to function. The system degrades from "understanding" to "classification" to "facts" — each level useful, each level independent of the levels above it.

**C4: Freshness cost scales with tier.** T0 freshness is cheap (re-parse on change). T1 freshness is cheap (re-run rules on T0 change). T2 freshness is expensive (re-run AI on T0/T1 change). The architecture ensures that the expensive tier tolerates staleness while the cheap tiers stay current.

**C5: The predicate registry (DAS-002) gains domain and MDT classification.** Every predicate in the registry must declare its domain and its maximum deterministic tier. This enables automated tier validation: a producer that assigns a tier exceeding the predicate's MDT is producing an error.

**C6: Invalidation cascades are bounded by tier ordering.** Because derivation flows upward, invalidation cascades flow upward. A T2 change never invalidates T0 or T1 content. This ensures that the most foundational knowledge is the least volatile.

---

## Invariants

**I1: Tier Totality.**
- **Statement:** Every atomic unit in the DIR declares exactly one tier from {T0, T1, T2}.
- **Rationale:** An untiered unit has undefined objectivity. Consumers cannot assess its reliability, the freshness contract is unknown, and the confidence model does not apply. Multi-tiered units would create ambiguity in every tier-dependent decision.
- **Verification:** Query the DIR for units with tier outside {T0, T1, T2} or with no tier. The result set must be empty.

**I2: T0 Deterministic Confidence.**
- **Statement:** Every T0 unit has confidence = `deterministic`. No unit at T1 or T2 has confidence = `deterministic`.
- **Rationale:** `deterministic` confidence means provably correct. T0 claims are provably correct; T1 and T2 claims are not. Allowing `deterministic` confidence at T1 or T2 would misrepresent reliability. Allowing non-deterministic confidence at T0 would indicate a producer that cannot prove its own output, which violates the T0 definition.
- **Verification:** For each T0 unit, confirm confidence = `deterministic`. For each T1/T2 unit, confirm confidence ≠ `deterministic`.

**I3: Derivation Monotonicity.**
- **Statement:** No unit at tier N is derived from a unit at tier M where M > N.
- **Rationale:** A lower-tier unit that depends on a higher-tier unit inherits the higher tier's uncertainty. A T0 unit derived from a T2 unit is not actually deterministic — it is, at best, T2. Allowing downward derivation would undermine the entire tier hierarchy.
- **Verification:** For each unit, examine its provenance inputs. Confirm that no input has a higher tier than the unit itself. This is a restatement of DAS-002 I-TIER-5 applied to the three-tier model.

**I4: MDT Compliance.**
- **Statement:** No unit's tier exceeds its predicate's maximum deterministic tier unless the predicate permits semantic-tier production. Specifically: if a predicate's MDT is T0, all units with that predicate must be T0. If a predicate's MDT is T1, units may be T0 or T1 but not T2 (unless the predicate explicitly allows T2).
- **Rationale:** A predicate like `hasReturnType` (MDT = T0) produced at T1 means someone used heuristic inference to determine a return type that should have been parsed. This is a producer error — the claim should have been established deterministically (DAS-001 P3).
- **Verification:** For each unit, compare its tier to its predicate's MDT. If tier > MDT and the predicate does not permit higher tiers, flag as a violation.

**I5: Freshness Ordering.**
- **Statement:** T0 freshness is at least as current as T1 freshness, which is at least as current as T2 freshness. No higher-tier claim may be fresher than the lower-tier claims it derives from.
- **Rationale:** If a T2 claim is fresh but the T0 claims it was derived from are stale, the T2 claim is grounded in outdated evidence. It may be "fresh" in timestamp but "stale" in meaning. The freshness ordering ensures that foundations are always at least as current as the conclusions built on them.
- **Verification:** For each T1 unit, confirm its T0 inputs are active (not invalidated). For each T2 unit, confirm its T0/T1 inputs are active. If a lower-tier input is invalidated but the higher-tier unit is active, the higher-tier unit must be invalidated.

**I6: Tier Immutability.**
- **Statement:** A unit's tier, once assigned at creation, never changes.
- **Rationale:** If a unit's tier could change, all downstream decisions based on that tier (confidence bounds, freshness contracts, consumer trust) become unreliable. Tier changes would require re-evaluating every consumer's use of the unit. Creating a new unit at a different tier (superseding the old one) achieves the same effect without retroactive inconsistency.
- **Verification:** Audit all DIR write operations. Confirm no operation modifies the tier field of an existing unit. This is a restatement of DAS-002 I-TIER-3.

**I7: Degradation Validity.**
- **Statement:** The DIR at any degradation level — T0+T1+T2, T0+T1, or T0 only — is a valid, queryable, self-consistent subset of the full DIR. No query against a degraded DIR produces an error due to missing tiers.
- **Rationale:** Graceful degradation (DAS-001 P12) requires that each tier's absence reduces quality but does not break the system. If T2 absence caused query failures in T0/T1 content, the system would not degrade gracefully.
- **Verification:** Remove all T2 units. Confirm all queries against T0/T1 content still succeed. Remove all T1 units. Confirm all queries against T0 content still succeed.

---

## Non-Goals

This chapter does not:

- **Enumerate specific predicates.** Which predicates exist, what their value types are, and which entities they apply to are defined in DAS-004 (entity model) and DAS-005 (relationship model). This chapter defines the tier system that those predicates are classified within.

- **Define pass ordering or execution.** How producers are scheduled, how they declare dependencies, and how they are re-executed on source change are defined in DAS-006 (pass architecture). This chapter defines the tier constraints that passes must satisfy.

- **Define the invalidation algorithm.** How invalidation propagates through the DIR, how cascade boundaries are determined, and how recomputation is prioritized are defined in DAS-010 (incremental update model). This chapter defines the tier-based freshness contracts that the invalidation algorithm must honor.

- **Define storage strategies per tier.** How each tier's content is persisted, partitioned, or cached is defined in DAS-012 (Storage Realization). This chapter defines the freshness and lifecycle properties that storage must support.

- **Prescribe specific algorithms, technologies, or tools.** No parser, classifier, AI model, or rule engine is specified. The tier model is technology-independent.

- **Define how consumers select tiers.** How a consumer specifies minimum acceptable tier, how context assembly filters by confidence, and how degradation is communicated to the user are defined in DAS-007 (retrieval model) and DAS-008 (context assembly). This chapter defines what the tiers mean; those chapters define how they are used.

---

## Open Questions

**Q1: Should the confidence scale be finer than four values?** *(Non-blocking)*

The four-value scale (deterministic, high, moderate, low) may be insufficient for some consumers. A consumer performing impact analysis may need to distinguish "high confidence from strong pattern match" from "high confidence from weak pattern match with corroborating evidence." A finer scale (e.g., numeric within each tier's range) would enable this. However, finer scales require calibration — what does confidence 0.82 mean? The four-value scale avoids calibration by using qualitative ordinal values. Deferred to DAS-007/DAS-008 to determine whether consumer needs require finer granularity.

**Investigation approach:** Analyze consumer use cases. If more than two consumers need finer-than-four-value discrimination, consider per-tier numeric subscales.

**Q2: Can a predicate span all three tiers?** *(Non-blocking)*

The behavioral domain is described as spanning T0–T2. This implies a predicate like `hasBehavior` could appear at any tier. But what does a "T0 behavioral claim" look like versus a "T2 behavioral claim"? If they are genuinely different kinds of claims, they should be different predicates. If they are the same claim at different objectivity levels, the predicate-spanning-tiers model is correct. This question affects predicate registry design.

**Investigation approach:** Enumerate behavioral predicates. Determine whether T0 behavioral claims and T2 behavioral claims are the same predicate with different tiers or different predicates at fixed tiers. The answer likely varies by predicate.

**Q3: How should human-annotated claims be tiered?** *(Non-blocking)*

A human developer who annotates code with "this function handles authentication" is making a claim. Is this T0 (the human is a source of truth), T1 (the human is applying a classification), or T2 (the human is interpreting)? The answer depends on whether human annotations are treated as source material or as inference. If treated as source, human annotations are T0. If treated as inference, they are T1 or T2 depending on the nature of the claim.

**Investigation approach:** Define the boundary between "source material" and "inference." A structured annotation in a code comment (e.g., `// @purpose: authentication`) may qualify as source material. A free-text annotation may not.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (Decode Intermediate Representation)
              └── DAS-003 (this chapter — Tier Model)
                    ├── DAS-004 (Entity Model) — predicates classified by tier
                    ├── DAS-005 (Relationship Model) — relationships carry tiers
                    ├── DAS-006 (Pass Architecture) — passes declare tier output ranges
                    ├── DAS-007 (Retrieval Model) — queries filter by tier
                    └── DAS-010 (Incremental Update Model) — freshness contracts per tier
```

DAS-003 depends on DAS-000, DAS-001, and DAS-002. It is depended upon by DAS-004, DAS-005, DAS-006, DAS-007, and DAS-010.

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial stub with section headings and open questions
1.0 — 2026-06-25 — Principal Architect — Complete chapter defining three-tier model
    (Deterministic, Derived, Semantic). Incorporates tier enumeration, freshness contracts,
    confidence model, predicate domain classification, cross-tier dependency rules, and
    7 invariants. Supersedes DAS-003 stub ("Knowledge Domains").
```
