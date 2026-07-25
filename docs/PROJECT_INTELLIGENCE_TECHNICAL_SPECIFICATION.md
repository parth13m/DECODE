# Decode — Project Intelligence
# Capability Specification

**Version**: 0.1
**Date**: 2026-07-01
**Phase**: File Intelligence Complete · Project Intelligence Active
**Audience**: Senior software engineer implementing this epic
**Authority**: This is a capability specification. It does not modify DAS, DDS, or IAG.

---

## Table of Contents

1. [Purpose](#1-purpose)
2. [Relationship to the Software Intelligence Platform](#2-relationship-to-the-software-intelligence-platform)
3. [Relationship to Session Mode](#3-relationship-to-session-mode)
4. [Scope](#4-scope)
5. [Engineering Principles](#5-engineering-principles)
6. [Product Goals](#6-product-goals)
7. [Capability Boundaries](#7-capability-boundaries)
8. [Module Intelligence](#8-module-intelligence)
9. [Project Intelligence](#9-project-intelligence)
10. [What Does NOT Belong in This Epic](#10-what-does-not-belong-in-this-epic)
11. [Capability Evolution](#11-capability-evolution)
12. [Milestone Roadmap](#12-milestone-roadmap)
13. [Success Criteria](#13-success-criteria)
14. [Non-Goals](#14-non-goals)
15. [Future Evolution Toward Living Intelligence](#15-future-evolution-toward-living-intelligence)

---

## 1. Purpose

File Intelligence understands files in isolation. A developer asking "what does this code do?" gets an answer grounded in the file's structure, purpose, behavior, safety, and design. But files do not exist in isolation. A coordinator calls services. Services conform to protocols defined elsewhere. A model is created in one file, transformed in another, and persisted in a third.

Project Intelligence closes this gap. It gives Decode the ability to understand how files relate to each other (Module Intelligence), and how groups of files form an architecture (Project Intelligence). The result is that explanations, improvements, and follow-up answers can be grounded not only in what a file does, but in *where it fits* and *what depends on it*.

The product value is concrete: when a developer selects a protocol method and asks "what does this do?", Decode can answer not only what the method's contract is, but which types implement it, how callers use it, and what would break if the signature changed. This is the understanding that an experienced senior engineer has after working in a codebase for months — and Decode delivers it instantly.

---

## 2. Relationship to the Software Intelligence Platform

Project Intelligence is a **consumer** of the completed Software Intelligence Platform. It does not modify the platform.

The platform provides:

- **ProducerRuntime** — registers and executes frontends and passes. Project Intelligence adds new producers; it does not change the runtime.
- **IndexRuntime** — maintains five index families. The index architecture is entity-type-agnostic (DDS-004). Module and System entities are indexed by the same families that index File and Function entities.
- **RetrievalRuntime** — retrieves evidence by anchor resolution. The retrieval architecture is scope-agnostic (DDS-005). Cross-file and cross-module retrieval use the same pipeline.
- **ContextAssembly** — assembles context frames from evidence using registered strategies. Project Intelligence registers new strategies for module-scope and project-scope context.
- **ConsumerRuntime** — invokes reasoning engines. Project Intelligence may enhance existing engines or register new ones. The runtime is purpose-agnostic (Decision #19).
- **UpdateEngine** — coordinates the write pipeline. Grounding chains will span more files; no architectural change is needed (DDS-007).
- **StorageEngine** — persists DIR snapshots. No changes.
- **DIRCore** — foundation types. No changes.

The platform was designed for this. IAG-004 §18: "Populating the pipeline with domain-specific producers, index families, and reasoning engines is product development work that uses the pipeline, not pipeline implementation work."

All Project Intelligence code lives in the **application layer** (`Decode/Application/` or `Decode/App/`), not in pipeline modules (`Decode/Understanding/`). It registers into the pipeline at startup via `AppDependencies.performDeferredStartup()`, following the precedent of SwiftSyntaxFrontend, TreeSitterFrontend, ExplainReasoningEngine, ImproveReasoningEngine, FollowUpReasoningEngine, and ContextStrategies.

---

## 3. Relationship to Session Mode

Session Mode is the interaction surface through which Project Intelligence delivers value. Project Intelligence does not create a new interaction mode. It enriches the understanding that Session Mode's existing flows — Explain, Improve, Follow-Up — already deliver.

Today, Session Mode opens a file, parses it, builds File Intelligence, and uses that understanding to anchor explanations. With Project Intelligence, Session Mode will additionally understand where that file fits in a module, what it collaborates with, and how the module fits in the project's architecture. The user experience does not change — the same hotkeys, the same HUD, the same follow-up and improve flows. The explanations become deeper.

Concretely:

- A Session Question about a protocol method can include which types implement it and where.
- A Session Question about a coordinator can explain the module it coordinates and the services it orchestrates, even when those services are in different files.
- An Improve suggestion can warn about downstream impact — "changing this signature would break 3 callers in 2 other files."
- A Follow-Up question like "what calls this?" can be answered with evidence, not inference.

Selection Mode and Screenshot Mode are unaffected by this epic. They operate without file context and will not gain Module or Project Intelligence.

---

## 4. Scope

This epic has two phases that build on each other:

**Phase 1: Module Intelligence** — Understanding how related files work together. Cross-file relationships, module boundary detection, module-level emergent properties. A module is the first composition level above files (DAS-004).

**Phase 2: Project Intelligence** — Understanding the whole codebase as architecture. System-level composition, architectural patterns, module interaction maps, dependency direction. A system is the top-level entity representing the entire codebase (DAS-004).

Phase 2 depends on Phase 1. Module Intelligence is the foundation that Project Intelligence composes over — the same way that File Intelligence is the foundation that Module Intelligence composes over.

The epic is complete when Session Mode explanations can draw on project-wide architectural understanding. The specific milestones are defined in the [Milestone Roadmap](#12-milestone-roadmap).

---

## 5. Engineering Principles

These principles govern the Project Intelligence epic. They extend — not replace — the engineering principles in CLAUDE.md.

### 5.1 Compose, Do Not Aggregate

Module Intelligence is not "File Intelligence applied to N files." It is emergent understanding that no single file possesses (DAS-001 P4, DAS-006 CP-4). A module's interaction patterns, cohesion characteristics, and architectural role are properties of the *group*, not of any constituent file. Composition passes that merely concatenate file summaries or count entities violate this principle.

### 5.2 Deterministic Before Semantic, Again

The same principle that governs File Intelligence (CLAUDE.md Engineering Principle #1) applies at module and project scope. Cross-file relationships, module boundaries derived from project structure, and containment hierarchies are deterministic. Semantic understanding (module purpose, architectural role, design trade-offs) builds on top of the deterministic foundation. Never ask an LLM to determine what can be computed from the AST and file system.

### 5.3 Reuse the Platform

Every new capability is a new producer, pass, context strategy, or reasoning engine registered into the existing pipeline. No new framework targets. No new actor types. No new pipeline modules. If a capability seems to require platform modification, it is either a genuine specification defect (file an RFC per IAG-004 §21.3) or a misunderstanding of the existing contracts.

### 5.4 Incremental Value Delivery

Each milestone delivers measurable user-facing value. No milestone exists solely for infrastructure. Even the earliest milestones — cross-file relationship resolution — should improve explanation quality by giving the reasoning engines evidence about what calls a function and what implements a protocol.

### 5.5 Graceful Degradation at Every Scope

File Intelligence works when semantic enrichment fails (deterministic fallback). Module Intelligence must work when module boundaries are ambiguous (fallback to file-only context). Project Intelligence must work when only some modules are analyzed (partial architectural understanding is better than none). The user never sees an error from incomplete intelligence — they see progressively richer understanding as more intelligence becomes available.

### 5.6 Budget-Aware Context

Module and project scope mean more candidate information for context frames. More information does not mean larger prompts. Context strategies must respect token budgets (DDS-006 R3) and select the most relevant cross-file evidence for the user's specific question. Shipping the entire module's intelligence to the LLM defeats the platform's context assembly architecture.

---

## 6. Product Goals

### What the User Experiences Today (File Intelligence)

When a developer asks about a protocol method, Decode explains what the method's contract is, what the protocol's role is in the file, and how it relates to sibling methods. The explanation is grounded in one file.

### What the User Should Experience After Module Intelligence

When a developer asks about a protocol method, Decode additionally explains which types implement this protocol (and where), how callers use it, and what the protocol's role is in the broader module — coordinator/service boundary, data access contract, or event dispatch interface. The explanation connects the method to its ecosystem.

### What the User Should Experience After Project Intelligence

When a developer asks about a protocol method, Decode additionally explains how this protocol fits the project's architecture — is it a public API contract at a module boundary, an internal implementation detail, or a cross-cutting concern used by multiple modules? The explanation gives the developer the architectural perspective that typically requires months of codebase familiarity.

### The Progression

| Scope | Question: "What does this protocol method do?" |
|-------|-----------------------------------------------|
| File Intelligence | "This method defines a contract for AI completion. The protocol has 3 methods covering streaming and non-streaming use." |
| + Module Intelligence | "...This protocol is implemented by `DecodeGatewayProvider` in Infrastructure. It is called by 3 coordinators in Application. It is the AI abstraction boundary for the module." |
| + Project Intelligence | "...This protocol is the single point of AI access for the entire project. All 3 interaction modes (Selection, Screenshot, Session) depend on it. Changing this signature affects 4 files across 2 architectural layers." |

---

## 7. Capability Boundaries

### What This Epic Builds

- Cross-file relationship resolution (which entities in other files are connected)
- Module boundary detection (which files form coherent groups)
- Module entity creation with emergent properties
- Module-scope context strategies for richer explanations
- System entity creation with architectural properties
- Project-scope context strategies
- Enhanced reasoning engine prompts that leverage cross-file and module-level evidence

### What This Epic Does NOT Build

- New interaction modes (no new hotkeys, no new UI panels)
- New HUD rendering capabilities (the existing tag vocabulary and rendering pipeline are sufficient)
- New pipeline modules or framework targets
- Modifications to existing DDS contracts
- Modifications to existing reasoning engine identifiers or protocol surfaces
- Background analysis or continuous monitoring (that is Living Intelligence)
- Multi-repository analysis
- Build system integration or CI/CD awareness

### The Litmus Test

Every piece of code in this epic must satisfy: "This is a new producer, pass, context strategy, reasoning engine enhancement, or orchestration service that registers into the existing pipeline." If it does not, it does not belong in this epic.

---

## 8. Module Intelligence

Module Intelligence is the first phase of the Project Intelligence epic. It answers the question: *how do related files work together?*

### 8.1 Cross-File Relationship Resolution

File Intelligence extracts relationships within a single file — which entities call which, which types conform to which protocols. But `targetName` in a `.calls` or `.conformsTo` relationship is a symbolic name. The target may be defined in a different file.

Module Intelligence resolves these symbolic names to actual entities across files. When `SessionQuestionCoordinator` has a `.calls` relationship targeting `resolve`, and `SessionResolver` defines a method named `resolve`, Module Intelligence connects them. This is deterministic — it requires only entity name matching across the DIR, not LLM inference.

Resolution confidence varies. An exact match on a unique name is high confidence. A match on a common name (`init`, `configure`, `update`) is lower confidence. Resolution strategies must handle ambiguity explicitly rather than guessing.

### 8.2 Module Boundary Detection

A module is a cohesive grouping of files (DAS-004). Boundaries may come from:

- **Explicit declaration**: build targets, package manifests, project groups
- **Project structure**: directory hierarchy (files in the same directory are likely related)
- **Analytical discovery**: relationship clustering (files that reference each other heavily likely belong together)

The simplest and most deterministic source is project structure. Directory boundaries are explicit and objective. Relationship-based clustering is a higher-tier capability that can refine directory-based boundaries.

Module boundary detection is a producer concern (DAS-004). It produces Module entities in the DIR via composition passes (DAS-006 CP-1).

### 8.3 Module-Level Emergent Properties

A composition pass that creates or enriches a Module entity must produce emergence (DAS-006 CP-4). Properties that exist only at the module level, not on any constituent file:

- **Interaction patterns**: how files in the module collaborate (layered delegation, event-driven, pipeline)
- **Internal cohesion**: how tightly coupled the module's files are to each other versus to external files
- **Public interface surface**: which entities are referenced by files outside the module
- **Architectural role**: the module's responsibility in the larger system (data access, coordination, presentation)
- **Boundary characteristics**: how the module communicates with other modules (protocols, direct calls, events)

These are not summaries of file-level properties. They are properties of the group that no single file possesses.

### 8.4 Module-Scope Context

When a user asks a Session Question about an entity in a module, the context assembly should include relevant cross-file evidence:

- Other files that implement the same protocol
- Callers of the selected entity from other files in the module
- The module's architectural role (if it provides useful framing)

This is a new context strategy registered via the existing `StrategyManagement` protocol. It competes for budget alongside the existing direct/relational/scope strata. The strategy must be selective — not every question benefits from module context. A question about a simple utility function does not need the module's interaction patterns.

---

## 9. Project Intelligence

Project Intelligence is the second phase. It answers the question: *how does the whole codebase work as an architecture?*

Project Intelligence depends on Module Intelligence. It composes module-level understanding into system-level understanding, the same way Module Intelligence composes file-level understanding into module-level understanding.

### 9.1 System Entity Creation

A System entity represents the entire codebase (DAS-004). It is created by a module → system composition pass (DAS-006). The System entity carries properties that no individual module possesses:

- **Architecture style**: layered, hexagonal, modular monolith, microservices
- **Dependency direction**: which layers depend on which, where violations occur
- **Cross-cutting patterns**: patterns that span modules (dependency injection, event dispatch, error handling)
- **Module interaction map**: which modules communicate and through what contracts
- **Technology distribution**: languages, frameworks, infrastructure choices across the system

### 9.2 Architectural Understanding

Project Intelligence enables explanations grounded in architectural context. When a developer asks about a file, Decode can explain not just what the file does in its module, but how that module fits the project's architecture:

- "This is the Infrastructure layer. It implements protocols defined in Domain. It is consumed by Application layer coordinators."
- "This module has 3 inbound dependencies and 12 outbound dependencies — it is a high-coupling hub."
- "This protocol crosses the Domain/Infrastructure boundary — it is a dependency inversion seam."

### 9.3 Project-Scope Context

A project-scope context strategy provides architectural framing for explanations. It selects system-level evidence when the user's question would benefit from architectural perspective:

- Questions about protocols → include implementor distribution and layer crossing information
- Questions about modules or entry points → include dependency direction and module role
- Questions about patterns → include cross-cutting pattern evidence

As with module-scope context, this strategy competes for budget and must be selective.

---

## 10. What Does NOT Belong in This Epic

| Item | Why Not | Where It Belongs |
|------|---------|-----------------|
| New DAS chapters | DAS-004 and DAS-006 already define Module, System, and composition passes | DAS is frozen |
| New DDS documents | All 8 runtime subsystems confirm no changes needed for Module/Project Intelligence | DDS is frozen |
| New IAG documents | IAG governs platform implementation, not capability development | IAG is frozen |
| Platform module modifications | The pipeline is complete and frozen | RFC required per IAG-004 §21.3 |
| New framework targets | All 8 modules exist; new code lives in the application layer | IAG-001 §2 is frozen |
| New actor types | Actor placement is frozen (IAG-003) | RFC required |
| Background continuous analysis | That is Living Intelligence (Phase 4) | Future epic |
| Git integration (blame, history, change frequency) | Valuable but out of scope; adds infrastructure dependency | Future capability |
| Multi-repository analysis | Decode currently operates on a single codebase | Future capability |
| Build system integration | Requires framework-specific parsers (SPM, npm, Cargo) | Future capability |
| New interaction modes | Selection/Screenshot/Session are sufficient | Not planned |
| Persistent enrichment cache | Useful at scale but not required for alpha | Deferred (CLAUDE.md) |
| New HUD UI components | The existing HUD, dock, and tag vocabulary are sufficient | Not needed |
| Server-side changes | The backend gateway and analytics pipeline need no modification | Not needed |
| AI model changes | Production model (claude-haiku-4-5) is unchanged | Not needed |

---

## 11. Capability Evolution

Project Intelligence builds incrementally. Each capability layer adds to the one before it.

```
Layer 0: File Intelligence (complete)
    Individual files understood in isolation.
    Entities, relationships, imports within a single file.
    Five understanding layers: Identity, Purpose, Behavior, Safety, Design.

        │
        ▼

Layer 1: Cross-File Resolution
    Symbolic relationship targets resolved to actual entities across files.
    "This method calls resolve()" becomes "This method calls SessionResolver.resolve()
    in SessionResolver.swift."

        │
        ▼

Layer 2: Module Boundaries
    Files grouped into modules via project structure and relationship analysis.
    Module entities created in the DIR with containment relationships.

        │
        ▼

Layer 3: Module Emergent Properties
    Interaction patterns, cohesion, public interface surface, architectural role.
    Properties that exist only at the module level.

        │
        ▼

Layer 4: Module-Scope Explanations
    Session Mode explanations enriched with cross-file and module-level evidence.
    "This protocol is implemented by 3 types across the module."

        │
        ▼

Layer 5: System Composition
    Modules composed into a System entity with architectural properties.
    Dependency direction, cross-cutting patterns, architecture style.

        │
        ▼

Layer 6: Project-Scope Explanations
    Session Mode explanations enriched with architectural context.
    "This module is the infrastructure layer. It has 5 consumers in Application."
```

Each layer delivers user-facing value. No layer exists solely as infrastructure for a later layer.

---

## 12. Milestone Roadmap

Milestones are ordered. Each builds on the previous. Titles only — implementation details belong in the implementation status document.

| # | Milestone | Phase |
|---|-----------|-------|
| 1 | Cross-File Entity Resolution | Module Intelligence |
| 2 | Directory-Based Module Boundary Detection | Module Intelligence |
| 3 | Module Entity Creation via Composition Pass | Module Intelligence |
| 4 | Module Emergent Properties | Module Intelligence |
| 5 | Module-Scope Context Strategy | Module Intelligence |
| 6 | Module-Aware Explanation Enhancement | Module Intelligence |
| 7 | Module Intelligence Validation | Module Intelligence |
| 8 | System Entity Creation via Composition Pass | Project Intelligence |
| 9 | System Emergent Properties | Project Intelligence |
| 10 | Project-Scope Context Strategy | Project Intelligence |
| 11 | Architecture-Aware Explanation Enhancement | Project Intelligence |
| 12 | Project Intelligence Validation | Project Intelligence |

Milestones 1–7 constitute Module Intelligence. Milestones 8–12 constitute Project Intelligence. The validation milestones (7 and 12) verify that the accumulated capabilities produce measurably better explanations.

---

## 13. Success Criteria

### Module Intelligence Is Complete When

1. Cross-file relationships are resolved with confidence scores in the DIR.
2. Module boundaries are detected from project structure for the Decode codebase itself.
3. Module entities exist in the DIR with emergent properties (not mere aggregations).
4. Session Mode explanations include cross-file evidence when relevant to the user's question.
5. Explanation quality for cross-file questions is measurably better than file-only explanations.
6. No platform module has been modified.
7. All existing tests continue to pass.

### Project Intelligence Is Complete When

1. A System entity exists in the DIR representing the analyzed codebase.
2. The System entity carries architectural properties (dependency direction, architecture style, module interaction map).
3. Session Mode explanations include architectural context when relevant to the user's question.
4. A developer can ask "where does this fit?" and receive an answer grounded in actual project structure, not LLM inference.
5. Explanation quality for architectural questions is measurably better than module-only explanations.
6. No platform module has been modified.
7. All existing tests continue to pass.

### How "Measurably Better" Is Assessed

At alpha scale (5–50 users), formal A/B testing is impractical. "Measurably better" means:

- The explanation contains information that was previously absent (cross-file callers, module role, architectural context).
- The information is grounded in DIR evidence, not hallucinated.
- The explanation does not become longer or noisier — the additional context replaces less specific content, it does not merely append.

---

## 14. Non-Goals

These are capabilities that might seem related to Project Intelligence but are explicitly excluded from this epic.

| Non-Goal | Rationale |
|----------|-----------|
| Real-time file watching across the entire project | Living Intelligence concern. This epic analyzes files that have open sessions or are referenced by open sessions. |
| Automatic background indexing of unvisited files | Living Intelligence concern. Analysis is demand-driven, triggered by user questions. |
| Dependency vulnerability scanning | Security tooling, not understanding. |
| Code quality scoring or metrics dashboards | Analysis, not understanding. Decode explains; it does not grade. |
| Refactoring suggestions beyond the existing Improve feature | The Improve feature may benefit from module context, but new refactoring capabilities are out of scope. |
| Cross-repository dependency analysis | Single-codebase scope for this epic. |
| Natural language project search ("find where auth happens") | Potentially valuable but a separate capability. |
| IDE integration for navigation ("jump to implementors") | Decode is editor-independent. It does not provide navigation. |

---

## 15. Future Evolution Toward Living Intelligence

Project Intelligence is Phase 3 of the four-phase intelligence progression defined in VISION.md. The fourth phase — Living Intelligence — is understanding that stays current as the codebase evolves.

Living Intelligence will likely require:

- **Persistent intelligence cache**: Module and System entities surviving app restarts (currently in-memory only).
- **Background re-analysis**: When files change, affected module and system properties are recomputed without waiting for a user question.
- **Change impact awareness**: Proactive notification of what a code change affects — "this edit breaks 2 callers in another module."
- **Incremental parsing**: Re-parsing only the changed portions of a file, not the entire file.
- **Temporal intelligence**: Understanding how the codebase changes over time — which modules are active, which are stable, which are accumulating complexity.

This epic does not build Living Intelligence. But it must not make Living Intelligence harder. Specifically:

- Module and System entities in the DIR must be designed for incremental update, not full rebuild.
- Composition passes must be invalidation-aware (DAS-006 PINV-1, PINV-2) so that file changes trigger targeted recomputation.
- Context strategies must degrade gracefully when intelligence is stale rather than failing.

These are constraints on how Project Intelligence is implemented, not additional capabilities to build.

---

*End of Capability Specification*
*Decode — Project Intelligence v0.1*
