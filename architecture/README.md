# Decode Architecture Specification (DAS)

## Purpose

The Decode Architecture Specification is the single source of truth for Decode's architecture. It captures *why* every architectural decision was made, *what* alternatives were considered and rejected, and *what invariants* must hold across all implementations.

The DAS is not a description of the current codebase. It is a prescriptive specification that the codebase must conform to. When the DAS and the code disagree, the code is wrong — unless an Architecture Change Request (ACR) has been filed to revise the DAS.

## Document Types

### DAS Chapters

DAS chapters are **normative**. Once Approved, they constrain all implementation. Each chapter addresses a single architectural concern, follows the mandatory structure defined in [DAS-000](das/DAS-000-Architecture-Authoring-Standard.md), and is reviewed against the checklist therein.

### RFCs

RFCs are **investigative**. They explore architectural questions, evaluate alternatives, and recommend decisions. An RFC is persuasive, not authoritative — its analysis may be accepted, rejected, or revised. When an RFC's recommendation is accepted, the decision is incorporated into the relevant DAS chapter. The RFC is then archived; it is not updated as the architecture evolves.

### Glossary

The [Glossary](glossary/TERMS.md) is a **derived index** of all terms defined across DAS chapters. It contains pointers to defining chapters, not definitions themselves. It must be kept consistent with the chapters but carries no independent authority.

## How Documents Relate

```
RFCs (exploratory)
  │
  │  analysis accepted
  ▼
DAS Chapters (authoritative)
  │
  │  terms extracted
  ▼
Glossary (derived index)
```

- RFCs feed analysis into DAS chapters but are never themselves authoritative.
- DAS chapters depend on other DAS chapters in a strict layer order (L0 → L5).
- The Glossary is mechanically derivable from DAS chapters.

## Layer Structure

The DAS is organized into six architectural layers. Dependencies flow strictly downward.

```
L0  Philosophy        Why Decode exists. What principles constrain all decisions.
L1  Domain Model      The DIR, its atomic units, entities, relationships, tiers.
L2  Intelligence      Pass architecture, enrichment, incremental update.
L3  Retrieval         Indexes, query model, context assembly.
L4  Delivery          Consumer architecture, reasoning boundary, understanding contracts.
L5  Realization       Storage, persistence, deployment.
```

## Core Architectural Concept

The **Decode Intermediate Representation (DIR)** is the canonical asset of Decode — the single internal representation of software from which all capabilities are derived. The DIR sits between source code (the input) and understanding (the output), analogous to LLVM IR in a compiler.

```
Source Code → Frontends → DIR → Passes → Indexes → Retrieval → Context → Backends → Understanding
```

See [DAS-002](das/DAS-002-Decode-Intermediate-Representation.md) for the complete definition.

## Chapter Inventory

| Chapter | Title | Layer | Status | Dependencies |
|---------|-------|-------|--------|-------------|
| [DAS-000](das/DAS-000-Architecture-Authoring-Standard.md) | Architecture Authoring Standard | Meta | Frozen | None |
| [DAS-001](das/DAS-001-Architectural-Principles.md) | Architectural Principles | L0 | Frozen | DAS-000 |
| [DAS-002](das/DAS-002-Decode-Intermediate-Representation.md) | Decode Intermediate Representation (DIR) | L1 | Frozen | DAS-000, DAS-001 |
| [DAS-003](das/DAS-003-Tier-Model.md) | Tier Model | L1 | Frozen | DAS-000, DAS-001, DAS-002 |
| [DAS-004](das/DAS-004-Entity-Model.md) | Entity Model | L1 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003 |
| [DAS-005](das/DAS-005-Relationship-Model.md) | Relationship Model | L1 | Frozen | DAS-000, DAS-001, DAS-002, DAS-004 |
| [DAS-006](das/DAS-006-Pass-Architecture.md) | Pass Architecture | L2 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003 |
| [DAS-007](das/DAS-007-Index-Architecture.md) | Index Architecture | L3 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005, DAS-006 |
| [DAS-008](das/DAS-008-Retrieval-Architecture.md) | Retrieval Architecture | L3 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005, DAS-006, DAS-007 |
| [DAS-009](das/DAS-009-Context-Assembly.md) | Context Assembly | L3 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003, DAS-004, DAS-005, DAS-006, DAS-007, DAS-008 |
| [DAS-010](das/DAS-010-Incremental-Update-Model.md) | Incremental Update Model | L2 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003, DAS-006, DAS-007 |
| [DAS-011](das/DAS-011-Consumer-Architecture.md) | Consumer Architecture | L4 | Frozen | DAS-000, DAS-001, DAS-002, DAS-003, DAS-006, DAS-008, DAS-009 |
| [DAS-012](das/DAS-012-Storage-Realization.md) | Storage Realization | L5 | Frozen | DAS-000, DAS-001, DAS-002, DAS-007, DAS-010, DAS-011 |

## RFC Inventory (Archived)

All RFCs have been accepted and their conclusions incorporated into DAS chapters. They are archived in `rfc/archive/` and are no longer updated.

| RFC | Title | Status | Target DAS Chapters |
|-----|-------|--------|-------------------|
| [RFC-000](rfc/archive/RFC-000-Canonical-Asset.md) | Canonical Asset | Archived | DAS-001, DAS-002 |
| [RFC-001](rfc/archive/RFC-001-Decode-Identity.md) | Decode Identity | Archived | DAS-001 |
| [RFC-002](rfc/archive/RFC-002-Canonical-Asset-Adversarial-Review.md) | Canonical Asset — Adversarial Review | Archived | DAS-001, DAS-002 |
| [RFC-005](rfc/archive/RFC-005-Atomic-Unit-Contract.md) | Contract of the Atomic Unit | Archived | DAS-002 |
| [RFC-006](rfc/archive/RFC-006-DIR-Hypothesis.md) | The Intermediate Representation Hypothesis | Archived | DAS-001, DAS-002 |

## Feature Architecture Specifications

Feature-level architecture specifications define cross-platform behavior for application-layer features that sit alongside the understanding pipeline.

| Spec | Title | Status |
|------|-------|--------|
| [VAS-001](VAS-001-VirtualSessionArchitecture.md) | Virtual Session Architecture | Canonical |
| [VISUAL_CONTEXT](VISUAL_CONTEXT_ARCHITECTURE.md) | Visual Context Architecture | Canonical |

## Dependency Order

Chapters must be authored and approved in dependency order. The critical path is:

```
DAS-000 (Authoring Standard)
  └─▶ DAS-001 (Principles)
        └─▶ DAS-002 (DIR)
              ├─▶ DAS-003 (Tier Model)
              │     └─▶ DAS-004 (Entity Model)
              │           └─▶ DAS-005 (Relationship Model)
              ├─▶ DAS-006 (Pass Architecture)
              │     └─▶ DAS-010 (Incremental Update)
              ├─▶ DAS-007 (Index Architecture)
              │     └─▶ DAS-008 (Retrieval Architecture)
              │           └─▶ DAS-009 (Context Assembly)
              │                 └─▶ DAS-011 (Consumer Architecture)
              └─▶ DAS-012 (Storage Realization)
```

## Approval Process

1. **Author** writes or revises a chapter following [DAS-000](das/DAS-000-Architecture-Authoring-Standard.md).
2. **Author** self-checks against the Review Checklist (DAS-000 Section 9).
3. **Author** advances status to `Under Review`.
4. **Reviewers** evaluate against the Review Checklist.
5. **CTO** (or designated authority) approves or returns to Draft with specific feedback.
6. On approval, the Glossary is updated to reflect any new or changed terms.

## Change Process

Changes to Approved chapters require an Architecture Change Request (ACR). See [DAS-000 Section 8](das/DAS-000-Architecture-Authoring-Standard.md) for the full process.

## Architectural Modification Process

All DAS, DDS, and feature architecture specifications are **frozen**. Changing a frozen specification requires an explicit RFC that includes:

1. **Which document and section** is proposed for modification.
2. **What the current specification says** (exact text).
3. **What the proposed modification is** (exact replacement text).
4. **Why the current specification is incorrect** — not inconvenient, not suboptimal, but incorrect (produces a system violating a DAS invariant, a DDS contract, or containing an internal contradiction).
5. **What implementation evidence** demonstrates the incorrectness (failing test, provable violation, or contradiction found during implementation).
6. **What downstream impact** the modification has on other frozen documents.

The RFC is reviewed and approved before any code is written against the modified specification. Implementation continues against the current frozen specification until the RFC is approved. Implementation convenience is never a valid reason for modification.

## Archived Documents

Historical documents that informed the architecture but are no longer authoritative are preserved in archive directories:

- `rfc/archive/` — Accepted RFCs whose conclusions have been incorporated into DAS chapters.
- `iag/archive/` — Implementation Architecture Guides consumed during pipeline construction.

## Conventions

- Cross-references use relative links: `[DAS-001](das/DAS-001-Architectural-Principles.md)`.
- Terms defined in the DAS are capitalized on first use in each section and linked to the Glossary.
- All dates use ISO 8601 format (YYYY-MM-DD).
- Chapter file names follow the pattern `DAS-NNN-Title-With-Hyphens.md`.
