# RFC-001: Decode Identity

```
RFC:           RFC-001
Title:         Decode Identity
Status:        Accepted
Author:        Principal Architect
Created:       2026-06-25
Target DAS:    DAS-001 (Architectural Principles)
```

## Abstract

This RFC answers the question: *What is Decode?* — not as a product question, but as an architectural question. It evaluates seven candidate architectural identities and recommends one.

## Candidates Evaluated

1. **AI Coding Assistant** — Rejected. Conversation-centric, stateless, no accumulating intelligence. Commoditizing rapidly.
2. **Repository Intelligence Engine** — Rejected as identity; retained as infrastructure. Optimizes for code-as-artifact, not code-as-understood.
3. **Software Knowledge Platform** — Rejected. Optimizes for breadth of coverage when the user need is depth at the point of confusion. Knowledge decay is architecturally toxic.
4. **Software Reasoning Engine** — Rejected. Creates correctness obligations the system cannot honor with current AI capabilities.
5. **Context Intelligence Platform** — Rejected as identity; retained as core mechanism. Context assembly is *how* Decode works, not *what* Decode is.
6. **Software Operating System** — Rejected. Unbounded scope. Competes with everything.
7. **Software Understanding Engine** — Recommended.

## Decision

**Decode is a Software Understanding Engine.**

Its architectural purpose is to make software comprehensible — transforming code from opaque text into structured understanding, calibrated to what a specific developer needs to know at a specific moment, at whatever level of granularity the question demands.

## Relationship to RFC-000

RFC-000 (Canonical Asset) establishes that Intelligence is the canonical asset — what Decode *builds and owns*.

RFC-001 (this RFC) establishes that Understanding is the canonical output — what Decode *delivers*.

Together:
- **What Decode builds:** Intelligence (the canonical asset)
- **What Decode delivers:** Understanding (the canonical output, derived from intelligence)
- **The primary abstraction:** Intelligence — layered, composable, incrementally maintained
- **The primary output:** Understanding — derived from intelligence, calibrated to query

The distinction matters because it tells engineers where to invest. You invest in better *intelligence*, and understanding improves as a consequence.

## Key Architectural Consequences

- **C1:** The Understanding is the unit of output. All external-facing operations produce understandings.
- **C2:** Understanding, not information, is the output contract.
- **C3:** Scope scales along defined axes (subject, scope, depth, perspective).
- **C4:** Context assembly is infrastructure, not identity.
- **C5:** Code generation is out of scope. Code improvement is in scope.
- **C6:** The system offers understanding; it does not assert truth.
- **C7:** Understandings compose upward.

## Incorporation Status

This RFC's decisions are to be incorporated into:
- [DAS-001: Architectural Principles](../das/DAS-001-Architectural-Principles.md) — architectural identity, scope boundaries, output contract

*Full analysis available in the RFC discussion record.*
