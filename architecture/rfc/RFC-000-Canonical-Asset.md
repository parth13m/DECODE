# RFC-000: Canonical Asset

```
RFC:           RFC-000
Title:         Canonical Asset
Status:        Accepted
Author:        Principal Architect
Created:       2026-06-25
Target DAS:    DAS-001 (Architectural Principles), DAS-002 (Decode Knowledge Model)
```

## Abstract

This RFC answers the question: *What is the canonical asset that Decode creates, owns, maintains, and evolves?*

Eight candidate assets were evaluated: Facts, Evidence, Knowledge, Understanding, Intelligence, Models, Context, and Insights. Each was assessed against seven properties: objectivity, stability, composability, retrievability, reasoning support, action support, and incremental freshness.

## Decision

**The canonical asset of Decode is Intelligence.**

Intelligence is a layered, composable, incrementally maintainable representation of software that spans from deterministic structural facts to semantically derived interpretation.

Decode builds intelligence. Decode owns intelligence. Decode maintains intelligence. Decode evolves intelligence. Everything else — explanations, investigations, improvements, analyses — is derived from intelligence.

## Key Findings

### Intelligence is Layered

```
Layer 4: Interpretive    — Why does this exist? What are the trade-offs?
Layer 3: Behavioral      — What does this do? How does it interact?
Layer 2: Relational      — What connects to what? What depends on what?
Layer 1: Structural      — What is here? What are its properties?
```

Each layer has a different freshness contract, confidence level, and computation cost — and the system knows this.

### Intelligence Composes Upward with Emergent Properties

When entity-level intelligence composes into scope-level intelligence, new properties emerge that do not exist at the lower level: interaction patterns, contracts, boundaries. This emergent composition is what distinguishes intelligence from all other candidate assets.

### Intelligence Supports the Full Capability Horizon

Explanation, investigation, impact analysis, code review, refactoring, autonomous agents, and onboarding are all derivable from intelligence without architectural contortion.

## Architectural Consequences

- **C1:** Intelligence is the system of record. All other outputs are projections.
- **C2:** Intelligence is layered with explicit confidence boundaries.
- **C3:** Intelligence composes upward; it does not aggregate.
- **C4:** Intelligence has a freshness contract per layer.
- **C5:** Intelligence is the input to reasoning, not the output.
- **C6:** The quality of every output is bounded by the quality of the intelligence.

## Invariants

- **I1:** Intelligence exists independently of any query.
- **I2:** Every layer of intelligence traces to its source.
- **I3:** Intelligence at level N never requires intelligence at level N+1.
- **I4:** Composition produces; it does not merely collect.
- **I5:** Intelligence is versioned.

## Incorporation Status

This RFC's decisions are to be incorporated into:
- [DAS-001: Architectural Principles](../das/DAS-001-Architectural-Principles.md) — canonical asset definition and governing constraints
- [DAS-002: Decode Knowledge Model](../das/DAS-002-Decode-Knowledge-Model.md) — entity structure derived from the intelligence model

*Full analysis available in the RFC discussion record.*
