# DDS-000: Design Authoring Standard

```
Document:      DDS-000
Title:         Design Authoring Standard
Status:        Draft
Version:       0.3
Author:        Principal Engineer
Reviewers:     —
Created:       2026-06-28
Last Revised:  2026-06-28
Depends On:    DAS-000 (Architecture Authoring Standard)
Depended By:   (derived — all DDS documents depend on DDS-000 by definition)
DAS Trace:     DAS-000 through DAS-012 (governing architecture)
```

## Abstract

This document defines the mandatory structure, authoring rules, traceability requirements, and review criteria for the Decode Design Specification (DDS). Every DDS document must conform to this standard. It is the constitutional document of the engineering specification layer — the rules by which runtime subsystem designs are specified.

## Motivation

The Decode Architecture Specification (DAS) defines *what* the system's architecture is and *why* each decision was made. It is intentionally implementation-agnostic: it speaks of atomic units, passes, indexes, and consumers without reference to any programming language, framework, or operating system.

But between "the DIR has immutable atomic units with 10 fields" (DAS-002) and a running process that manages memory, handles failures, and responds to user input, there is a necessary engineering layer. This layer answers questions that the DAS intentionally defers:

- What are the runtime boundaries of the subsystem that implements retrieval?
- What does it own? What does it borrow? What does it share?
- What states can it be in? What transitions are valid?
- How does it fail? How does the caller detect failure? How does the system recover?
- What is the concurrency model? What runs in parallel? What must be serialized?
- What are the performance requirements? What are the memory bounds?

Without a governing standard, design specifications degrade into one of three failure modes:

1. **Architecture restated.** The document repeats DAS content at a lower level of abstraction, adding nothing that the DAS didn't already say.
2. **Implementation narrated.** The document describes what the current code does, binding the specification to today's implementation and preventing clean evolution.
3. **Requirements listed.** The document enumerates what the subsystem should do without specifying the engineering contracts, state models, and failure modes that make the requirements realizable.

DDS-000 defines the process that prevents all three.

---

## 1. Document Hierarchy

### 1.1 The Three Layers

Decode's engineering documentation exists in three layers. Each layer has a distinct purpose, a distinct audience, and a distinct rate of change.

```
DAS  (Architecture)    — WHAT the system is and WHY
DDS  (Design)          — HOW runtime subsystems realize the architecture
Implementation         — The code, tests, and configuration that realize the design
```

**DAS is canonical.** When a DDS conflicts with the DAS, the DDS is defective. When implementation conflicts with the DDS, the implementation is defective. The hierarchy is absolute.

**The layers address different questions:**

| Question | Answered By |
|----------|-------------|
| What is the canonical asset? | DAS |
| What invariants must hold? | DAS |
| What are the entity types? | DAS |
| What predicates exist? | DAS |
| How do passes compose? | DAS |
| What subsystem implements the pass scheduler? | DDS |
| What does the pass scheduler own? | DDS |
| What are the pass scheduler's failure modes? | DDS |
| How does the pass scheduler manage concurrency? | DDS |
| What data structure holds the pass DAG? | Implementation |
| What programming language is the scheduler written in? | Implementation |
| What test framework validates the scheduler? | Implementation |

### 1.2 What Belongs in DDS

A DDS document specifies the engineering design of a runtime subsystem. It defines:

- The subsystem's responsibilities and boundaries.
- The contracts it offers to other subsystems and the contracts it requires from them.
- The lifecycle of the subsystem and the resources it manages.
- The state model: what states exist, what transitions are valid, what triggers them.
- The execution model: what runs concurrently, what must be serialized, what isolation guarantees exist.
- The ownership model: what the subsystem owns exclusively, what it shares, what it borrows.
- The failure model: what can fail, how failure is detected, how the system recovers or degrades.
- The performance envelope: what operations must complete within what bounds.
- The observability surface: what the subsystem exposes for monitoring, diagnosis, and debugging.
- The testing requirements: what properties must be verified and at what level.

### 1.3 What Does NOT Belong in DDS

A DDS document must never contain:

| Prohibited Content | Why | Where It Belongs |
|-------------------|-----|-----------------|
| Architectural decisions or invariants | DDS does not make architecture; it realizes it | DAS |
| New abstractions not derived from DAS | DDS does not invent architecture | RFC, then DAS |
| Programming language syntax or idioms | DDS is implementation-agnostic | Implementation |
| Framework-specific patterns | DDS survives technology changes | Implementation |
| Library or dependency names | DDS does not prescribe tools | Implementation |
| API signatures with language-specific types | DDS specifies contracts, not interfaces | Implementation |
| Database schemas or wire formats | These are realization details | Implementation |
| Test code or test assertions | DDS specifies what to test, not how | Implementation |
| Product requirements or user stories | DDS specifies engineering design, not product behavior | Product specification |
| Rationale for why the DAS is correct | DDS assumes the DAS; it does not re-derive it | DAS |

**The litmus test:** If changing the programming language, the operating system, or the storage engine would require revising a DDS document, the document contains implementation leakage. A well-written DDS survives technology migration.

### 1.4 The Boundary Between DDS and Implementation

DDS specifies *what contracts the implementation must satisfy.* It does not specify *how the implementation satisfies them.*

**DDS says:** "The pass scheduler must execute passes in topological order of the pass DAG. No pass may execute before all of its declared input dependencies have completed."

**DDS does not say:** "The pass scheduler uses Kahn's algorithm with a priority queue sorted by tier."

**DDS says:** "The snapshot writer must guarantee atomic persistence: at no point does the on-disk state represent a partial snapshot."

**DDS does not say:** "The snapshot writer uses write-to-temp plus POSIX rename."

When the boundary is ambiguous, apply this rule: *If two competent engineers could satisfy the contract with fundamentally different implementations, the contract is at the right level. If the contract admits only one implementation, it is too specific.*

---

## 2. Design Principles

These principles govern the authoring of DDS documents. They are ordered by precedence: when principles conflict, the lower-numbered principle prevails.

### DP-1: Architecture Conformance

Every DDS document derives its authority from the DAS. A DDS section that cannot be traced to at least one DAS chapter, invariant, or consequence is either (a) specifying architecture (prohibited — file an RFC) or (b) specifying implementation detail at the wrong level (move to implementation). The exception is DDS-internal engineering contracts (e.g., failure handling patterns) that are necessary to realize the DAS but are not themselves architectural decisions.

**Test:** For every contract in a DDS, ask: "Which DAS invariant or consequence requires this contract to exist?" If the answer is "none," the contract falls into exactly one of three categories: (a) an implementation detail elevated to specification level (move it down), (b) an architectural gap not yet captured by the DAS (file an RFC), or (c) a DDS-internal engineering contract necessary to coordinate between subsystems in service of the DAS (permitted — must be explicitly marked `DDS-INTERNAL` with a justification stating which DAS obligation it supports, per Section 4.1).

### DP-2: Contracts Over Descriptions

A DDS that describes how a subsystem works is less valuable than a DDS that states what contracts the subsystem honors. Descriptions become stale as implementation evolves. Contracts are testable, stable, and enforceable.

**Test:** If every contract in a DDS were extracted into a test suite, and every description were deleted, would the remaining document still constrain implementation? If yes, the contracts are doing real work. If the tests would be trivial or empty, the DDS is a narrative, not a specification.

### DP-3: Subsystem Isolation

Each DDS document specifies exactly one runtime subsystem. The subsystem's boundary must be explicitly defined: what is inside, what is outside, and what contracts govern the boundary crossings. A DDS that specifies multiple subsystems creates coupling at the specification level — changes to one subsystem's design propagate to another subsystem's document.

**Test:** If two independent teams could implement the subsystem described by a DDS without coordinating on anything other than the published contracts, the DDS has correct isolation. If implementation requires knowledge not in the DDS, the specification is incomplete.

### DP-4: Failure as a First-Class Concern

Every DDS must specify failure modes, not just success paths. A subsystem design that addresses only the happy path is incomplete. For every external dependency, for every resource acquisition, and for every concurrent operation, the DDS must specify: what can fail, how failure is detected, what the subsystem does in response, and what the caller observes.

**Test:** Take every interaction in the DDS and ask: "What happens if this fails?" If the answer is "undefined," the DDS is incomplete.

### DP-5: Explicit Ownership

Every resource managed by a subsystem (memory, file handles, network connections, cached state, background tasks) must have an explicit owner. Shared ownership must be explicitly documented with the sharing protocol (who reads, who writes, who invalidates, who disposes). Implicit sharing is the most common source of defects in concurrent systems.

**Test:** For every piece of mutable state in the subsystem, can you answer: "Who creates it? Who can read it? Who can write it? Who destroys it? What happens if two actors try to write simultaneously?" If any answer is "it depends" or "unclear," the ownership model is incomplete.

### DP-6: Technology Neutrality

DDS documents must be expressible without reference to any specific programming language, framework, library, operating system, or hardware platform. Technology-specific concerns belong in implementation. DDS documents that survive a complete technology migration are at the right level of abstraction.

**Exception:** When the subsystem's fundamental purpose is technology-specific (e.g., a DDS for macOS accessibility capture), the technology reference is part of the domain constraint, not an implementation leak. In such cases, the DDS should isolate the technology-specific requirements in a clearly marked section and ensure all contracts are stated in terms of capabilities, not APIs.

### DP-7: Minimal Specification

A DDS should specify the minimum set of contracts necessary to realize the DAS obligations assigned to its subsystem. Every additional contract constrains the implementation space without providing architectural value. When in doubt, omit the contract and let the implementation decide.

**Test:** For every contract in a DDS, ask: "Would removing this contract allow an implementation that violates a DAS invariant?" If no, the contract may be over-specifying.

---

## 3. Document Structure

Every DDS document must contain the following sections in the specified order. Sections marked **mandatory** must always be present. Sections marked **conditional** must be present when the stated condition applies.

### 3.1 Front Matter (mandatory)

```
Document:      DDS-NNN
Title:         [document title]
Status:        Draft | Under Review | Approved | Deprecated | Superseded
Version:       [semantic version: major.minor]
Author:        [name]
Reviewers:     [names]
Created:       [date]
Last Revised:  [date]
Depends On:    [list of DDS documents this document assumes]
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     [list of DAS chapters this document realizes]
```

**DAS Trace** is unique to DDS front matter. It declares which DAS chapters provide the architectural authority for this DDS. Every DDS must trace to at least one DAS chapter.

**Depended By** is derived metadata, not a maintained specification field. It is populated by inspecting the `Depends On` declarations of all authored DDS documents. A DDS document must never require revision solely because another DDS document is authored that depends on it. The marker `(derived — see DDS dependency graph)` indicates that the actual dependents are determined by the graph, not by manual maintenance.

### 3.2 Abstract (mandatory)

One paragraph. Maximum 150 words. States what subsystem the document specifies, what DAS obligations it realizes, and what scope it covers. No reasoning, no justification — just scope.

### 3.3 DAS Traceability (mandatory)

This section explicitly maps the DDS document's scope to the DAS architecture. For each DAS chapter referenced in the front matter, this section must state:

- Which specific DAS invariants, consequences, or contracts this DDS realizes.
- Which aspects of the DAS chapter are NOT addressed by this DDS (and which other DDS, if any, addresses them).

This section prevents both gaps (DAS obligations with no DDS realization) and overlaps (multiple DDS documents claiming the same obligation).

Format:

```
DAS-NNN: [chapter title]
  Realized: I1, I3, C2, C4
  Not addressed: I2 (addressed by DDS-MMM), I4 (deferred to Phase N)
```

### 3.4 Terminology (mandatory)

Every term that the DDS introduces or uses in a non-obvious way must be defined here. Terms defined in DAS chapters must be referenced, not redefined. Terms introduced by this DDS must be marked `INTRODUCED` and should be used only when no existing DAS or DDS term covers the concept.

DDS terminology must never contradict DAS terminology. If a DDS needs a term that conflicts with a DAS term, this indicates either a misunderstanding of the DAS or a gap in the DAS terminology. In either case, the resolution path is an RFC, not a DDS redefinition.

### 3.5 Responsibilities (mandatory)

A concise enumeration of what the subsystem does and does not do. Each responsibility must be:

- **Singular:** One responsibility per item.
- **Bounded:** Clear about what is included and what is excluded.
- **Traceable:** Linked to a specific DAS obligation (invariant, consequence, or contract).

Format:

```
R1: [responsibility statement]
    DAS: [DAS-NNN invariant/consequence ID]
    Boundary: [what is explicitly excluded]
```

The responsibilities section serves as the table of contents for the rest of the document. Every subsequent section should trace back to at least one responsibility.

### 3.6 Public Contracts (mandatory)

The contracts that this subsystem offers to other subsystems and the contracts it requires from other subsystems.

Each contract must specify:

- **Contract ID:** Stable identifier (e.g., `PC-1`).
- **Direction:** Offered (this subsystem provides) or Required (this subsystem depends on).
- **Counterparty:** Which other subsystem or boundary this contract applies to.
- **Guarantee:** What is promised, stated as a universally quantified assertion.
- **Preconditions:** What must be true before the contract applies.
- **Failure mode:** What happens when the contract cannot be honored.

Contracts are the primary mechanism by which DDS documents compose. When DDS-A offers contract `PC-3` and DDS-B requires that contract, the documents are linked by a verifiable obligation.

**Cross-document references.** Contract IDs (e.g., `PC-1`) are scoped to the document that defines them. When a contract is referenced from another DDS document, the reference must be fully qualified: `DDS-NNN:PC-M`. Within the defining document, the short form (`PC-M`) is sufficient.

### 3.7 Lifecycle (mandatory)

Defines the creation, operation, and destruction of the subsystem and the resources it manages.

Must answer:

- When is the subsystem created?
- What preconditions must be met before creation?
- What initialization is performed? What is deferred?
- When is the subsystem operational?
- When and how is the subsystem destroyed or quiesced?
- What cleanup is performed on destruction?
- What happens if the subsystem is accessed before initialization or after destruction?

### 3.8 State Model (mandatory)

Defines the states the subsystem can be in and the valid transitions between them.

Must include:

- A finite enumeration of states.
- For each transition: the trigger, the preconditions, the postconditions, and any side effects.
- The initial state.
- The terminal state(s), if any.
- What happens if an invalid transition is attempted.

The state model must be consistent with the lifecycle (Section 3.7). If the subsystem has no meaningful state (pure stateless service), this section must explicitly state so and explain why no state is required.

### 3.9 Execution Model (mandatory)

Defines the concurrency, isolation, and scheduling characteristics of the subsystem.

Must answer:

- What operations run concurrently?
- What operations must be serialized?
- What isolation boundary contains the subsystem's mutable state?
- What happens when the subsystem is accessed from outside its isolation boundary?
- What resources are shared with other subsystems? What is the sharing protocol?
- What ordering guarantees exist between operations?

### 3.10 Memory and Ownership (mandatory)

Defines what the subsystem owns, borrows, and shares, and the lifecycle of each resource.

Must answer:

- What does the subsystem allocate?
- What does the subsystem receive from outside? Is it owned (transferred), borrowed (must not outlive), or shared (reference-counted or equivalent)?
- What is the retention policy for cached or computed data?
- What is the upper bound on memory consumption? Under what assumptions?
- What triggers eviction or disposal?

### 3.11 Failure Handling (mandatory)

Defines every failure mode the subsystem recognizes and the response to each.

For each failure mode:

- **Failure ID:** Stable identifier (e.g., `FM-1`).
- **Trigger:** What causes this failure.
- **Detection:** How the subsystem detects the failure.
- **Response:** What the subsystem does (retry, degrade, propagate, log).
- **Caller observes:** What the caller sees (error value, timeout, partial result, fallback).
- **Recovery:** How the system returns to a non-failed state, if applicable.

### 3.12 Performance Requirements (conditional: required when the subsystem has latency, throughput, or resource constraints)

Defines measurable performance expectations.

Each requirement must be:

- **Measurable:** Expressed as a number with units (milliseconds, bytes, operations per second).
- **Scoped:** Tied to a specific operation or resource.
- **Bounded:** Specifying at least an upper or lower bound.
- **Conditioned:** Stating the assumptions (input size, concurrency level, hardware class) under which the bound holds.

### 3.13 Observability (mandatory)

Defines what the subsystem exposes for monitoring, diagnosis, and debugging.

Must answer:

- What events does the subsystem emit?
- What metrics are tracked?
- What diagnostic state is available on inspection?
- What information is included when a failure is reported?
- What is the observability overhead?

### 3.14 Testing Requirements (mandatory)

Defines what properties must be verified and at what level.

Must specify:

- **Contract tests:** Tests that verify the public contracts (Section 3.6).
- **State model tests:** Tests that verify all valid and invalid state transitions.
- **Failure mode tests:** Tests that verify each failure mode's detection and response.
- **Integration tests:** Tests that verify the subsystem's interaction with its required contracts.

Does NOT specify test implementations, test frameworks, or test code.

### 3.15 Security Considerations (conditional: required when the subsystem handles credentials, user data, permissions, or external communication)

Defines the security-relevant properties of the subsystem.

Must answer:

- What sensitive data does the subsystem handle?
- What is the threat model? (What could an adversary do if this subsystem were compromised?)
- What mitigations are required?
- What is the principle of least privilege for this subsystem?

### 3.16 Future Evolution (conditional: required when known upcoming changes will affect the subsystem)

Describes anticipated changes and how the current design accommodates or constrains them. Each entry must reference a specific DAS milestone or roadmap phase. This section must not contain design decisions — it identifies areas where the design was intentionally left flexible and explains what was preserved.

### 3.17 Open Questions (conditional: required when unresolved engineering decisions exist)

Lists engineering questions that the author could not resolve and that remain open. Each question must include:

- **The question itself.**
- **Impact:** What contracts, states, or failure modes are weakened or incomplete because this question is unresolved.
- **Resolution path:** How the question might be investigated (not answered — investigated).

Open Questions are distinct from Future Evolution (Section 3.16). Future Evolution describes *anticipated changes* where the current design is intentionally flexible. Open Questions describe *current uncertainty* where the design is incomplete because a decision could not yet be made.

A DDS document may advance to Under Review with non-blocking Open Questions. Blocking Open Questions — those whose resolution could change a public contract — must be resolved before the document advances.

### 3.18 Revision History (mandatory)

A log of substantive changes. Format:

```
[version] — [date] — [author] — [summary of change]
```

Formatting changes, typo fixes, and non-substantive edits do not require entries.

---

## 4. Traceability Rules

### 4.1 Downward Traceability (DAS → DDS)

Every DDS document must trace downward to the DAS. Specifically:

- Every DDS responsibility (Section 3.5) must reference at least one DAS invariant, consequence, or contract.
- Every DDS public contract (Section 3.6) must be derivable from a DAS contract or invariant.
- Every DDS failure mode (Section 3.11) must reference the DAS degradation or isolation requirement it realizes.

A DDS responsibility that cannot be traced to the DAS is one of:

1. An implementation detail elevated to specification level (move it down to implementation).
2. A genuine engineering requirement not captured by the DAS (file an RFC to add the requirement to the DAS, then trace to the new DAS content).
3. An internal engineering contract necessary to coordinate between DDS-specified subsystems (permitted, but must be explicitly marked as DDS-internal with justification).

### 4.2 Upward Traceability (DDS → DAS)

The DAS must be fully covered by the DDS layer. Every DAS invariant, consequence, and contract must be realized by at least one DDS document. The DAS traceability sections (Section 3.3) across all DDS documents must collectively cover every DAS obligation.

A DAS obligation not traced by any DDS is an unrealized architectural requirement. This is a defect in the DDS layer, not the DAS.

### 4.3 Lateral Traceability (DDS ↔ DDS)

When one DDS document's public contract is required by another DDS document, both documents must reference the contract:

- The offering DDS lists the contract in its "Offered" public contracts.
- The requiring DDS lists the same contract in its "Required" public contracts, using the fully qualified form (`DDS-NNN:PC-M`) as defined in Section 3.6.

Circular dependencies between DDS documents (DDS-A requires DDS-B, DDS-B requires DDS-A) are prohibited. They indicate that two subsystems should be merged or that the shared concern should be extracted into a separate DDS.

---

## 5. Dependency Rules

### 5.1 DDS Dependency Graph

DDS documents form a directed acyclic graph of dependencies. Each DDS document declares its dependencies in the front matter. Dependencies flow through "Required" public contracts: if DDS-A requires a contract offered by DDS-B, then DDS-A depends on DDS-B.

### 5.2 Acyclicity

The DDS dependency graph must be acyclic. A cycle indicates architectural coupling that the DDS layer has failed to resolve. Resolution options:

1. **Merge:** Combine the cyclic DDS documents into one (the subsystems are not truly independent).
2. **Extract:** Identify the shared concern and define it in a separate DDS that both depend on.
3. **Interface:** Define an abstract contract in a shared DDS that both subsystems conform to, breaking the direct dependency.

### 5.3 Stability Ordering

DDS documents that are depended on by many other DDS documents must be more stable (change less frequently) than DDS documents with few dependents. When designing the DDS graph, prefer structures where:

- Foundation documents (DIR store, epoch model, pass scheduler) are stable and rarely revised.
- Leaf documents (specific consumers, specific frontends) are free to evolve independently.

### 5.4 Draft Dependencies

A DDS document may depend on another DDS document that is still Draft. However:

- The dependency must be explicitly noted in the front matter.
- The depending document must state which contracts from the Draft document it relies on.
- If the Draft document changes those contracts, the depending document must be re-evaluated.

---

## 6. RFC Requirements

### 6.1 When an RFC Is Required

An RFC must be filed before making any of the following changes:

1. **New DAS content.** A DDS author discovers that the DAS does not define an invariant, consequence, or contract that is necessary for the DDS to be complete. The RFC proposes the addition to the DAS.
2. **DAS contradiction.** A DDS author discovers that two DAS chapters contradict each other, or that a DAS invariant cannot be satisfied by any implementation. The RFC identifies the contradiction and proposes a resolution.
3. **New architectural abstraction.** A DDS author needs a concept (entity type, predicate, pass type, index family) that does not exist in the DAS. The RFC proposes the addition.
4. **DAS invariant relaxation.** A DDS author determines that a DAS invariant is too strong to be practically realizable. The RFC proposes a weaker invariant with justification.
5. **Cross-DDS architectural coupling.** Two DDS documents discover a shared concern that cannot be resolved by contracts alone. The RFC proposes an architectural structure to address the coupling.

### 6.2 When an RFC Is NOT Required

- Adding a new DDS document that realizes existing DAS content.
- Defining DDS-internal engineering contracts that do not modify the DAS.
- Specifying failure modes, performance requirements, or observability for a subsystem.
- Revising a DDS document to improve clarity without changing contracts.

### 6.3 RFC Format

RFCs follow the format defined in the project's `architecture/rfc/` directory. They are exploratory and persuasive. They become normative only when their recommendations are adopted into a DAS chapter through the DAS change process (DAS-000, Section 8).

---

## 7. Terminology

DDS documents use the following terms in addition to all terms defined in the DAS.

**DDS** — The Decode Design Specification. The complete set of engineering design documents governing Decode's runtime subsystem designs. Each DDS document specifies one subsystem. `INTRODUCED`

**DDS Document** — A single document within the DDS specifying one runtime subsystem. `INTRODUCED`

**Subsystem** — A cohesive unit of runtime behavior with a defined boundary, a defined lifecycle, and published contracts. A subsystem is smaller than an architectural layer and larger than a class or module. It is the unit of engineering design. `INTRODUCED`

**Contract** — A guarantee offered by one subsystem to another, or required by one subsystem from another. Contracts are the coupling points between subsystems. A contract includes a guarantee (what is promised), preconditions (what must be true), and a failure mode (what happens when the contract cannot be honored). `INTRODUCED`

**Responsibility** — A statement of what a subsystem does, bounded by what it does not do, and traced to a DAS obligation. `INTRODUCED`

**Failure Mode** — A defined way in which a subsystem can fail, including the trigger, detection mechanism, response, and what the caller observes. `INTRODUCED`

**Ownership** — The relationship between a subsystem and a resource. The owner creates, manages, and destroys the resource. Non-owners may borrow or share but do not control lifecycle. `INTRODUCED`

**Isolation Boundary** — The boundary within which mutable state is contained. Access from outside the boundary requires a defined protocol. `INTRODUCED`

**Lifecycle** — The sequence of phases a subsystem passes through from creation to destruction: construction, initialization, operation, quiescence, and disposal. The lifecycle of a subsystem (Section 3.7) is distinct from the lifecycle of a DDS *document* (Section 9). `INTRODUCED`

**State Model** — A finite enumeration of the states a subsystem can occupy, together with the valid transitions between them, their triggers, preconditions, and postconditions. A state model defines what configurations are legal; it does not prescribe a particular implementation mechanism. `INTRODUCED`

**Execution Model** — The concurrency, isolation, and scheduling characteristics of a subsystem: what runs concurrently, what must be serialized, what isolation boundary contains mutable state, and what ordering guarantees exist between operations. `INTRODUCED`

**Performance Envelope** — The set of measurable bounds (latency, throughput, memory, resource consumption) within which a subsystem must operate, stated with explicit assumptions about input size, concurrency level, and hardware class. `INTRODUCED`

**Observability Surface** — The set of events, metrics, and diagnostic state that a subsystem exposes for monitoring, diagnosis, and debugging. Defines what is visible to operators and tooling without modifying the subsystem's behavior. `INTRODUCED`

---

## 8. Review and Acceptance Criteria

### 8.1 Review Checklist

A DDS document must pass all of the following checks before advancing from Draft to Under Review:

**Structural Checks:**

- [ ] All mandatory sections (3.1–3.11, 3.13–3.14, 3.18) are present.
- [ ] All conditional sections are present when their conditions apply.
- [ ] Front matter is complete, including DAS Trace.
- [ ] Abstract is under 150 words.
- [ ] Section ordering matches the template (Section 3).

**Traceability Checks:**

- [ ] Every responsibility traces to a DAS obligation.
- [ ] Every public contract is derivable from a DAS contract or invariant.
- [ ] The DAS Traceability section covers all referenced DAS chapters.
- [ ] No DAS obligation within scope is unaddressed (or explicitly deferred with justification).

**Contract Checks:**

- [ ] Every offered contract has a guarantee, preconditions, and failure mode.
- [ ] Every required contract references a specific offered contract in another DDS using the fully qualified form (`DDS-NNN:PC-M`).
- [ ] No circular dependencies exist in the DDS dependency graph.
- [ ] Contract identifiers are stable and unique within the document.
- [ ] DDS-internal engineering contracts are explicitly marked `DDS-INTERNAL` with justification (Section 4.1).

**Completeness Checks:**

- [ ] The state model covers all states and transitions.
- [ ] The failure handling covers all external dependencies and resource acquisitions.
- [ ] The testing requirements cover all contracts, state transitions, and failure modes.
- [ ] The lifecycle covers creation, operation, and destruction.

**Leakage Checks:**

- [ ] No programming language, framework, or library is named or implied.
- [ ] No database schema, wire format, or API signature appears.
- [ ] No DAS decisions are re-argued or re-derived.
- [ ] No product requirements or user stories appear.
- [ ] The document would survive a complete technology migration without revision.

### 8.2 Acceptance Criteria

A DDS document advances from Under Review to Approved when:

1. It passes all review checklist items.
2. All DDS documents it depends on are Approved or Under Review.
3. All DAS chapters it traces to are Approved.
4. At least one reviewer (who is not the author) has signed off.
5. No unresolved contradictions with other Approved DDS documents exist.

### 8.3 Versioning

DDS documents use two-part version numbers: `major.minor`.

- **Minor** increment: Clarification, additional examples, non-substantive rewording. Does not require re-review.
- **Major** increment: Change to any contract, responsibility, state transition, or failure mode. Requires full re-review, including review of all dependent DDS documents for consistency.

### 8.4 Change Process

Changes to Approved DDS documents are proposed through **Design Change Proposals (DCPs)**. A DCP is lighter than a DAS Architecture Change Request: DDS documents change more frequently, and the change process must not create a barrier to necessary evolution.

A DCP must include:

1. **Target:** Which DDS document and which sections are affected.
2. **Motivation:** Why the current design is insufficient — what new information, implementation experience, or DAS change motivates the revision.
3. **Proposed change:** The specific modification, stated precisely enough that a reviewer can assess scope and impact.
4. **Impact assessment:** Which dependent DDS documents are affected by the change. For each, state whether the dependent document requires revision or remains compatible.
5. **Classification:** Whether the change is **minor** (no contract, responsibility, state, or failure mode changes — does not require re-review) or **major** (changes any of these — requires full re-review per Section 8.3).

**Approval:** Minor DCPs are approved by the document's author or any reviewer. Major DCPs require approval by the technical lead or designated authority, following the same criteria as initial acceptance (Section 8.2). Major DCPs that affect dependent documents must not be approved until the impact on each dependent document has been assessed and acknowledged by the dependent document's author.

**Supersession:** When a change is too large to express as a revision — when the subsystem boundary itself is being redrawn — the correct action is not a DCP but a new DDS document that supersedes the original (Section 9.2).

### 8.5 Contradiction Resolution

When two Approved DDS documents make incompatible claims — conflicting contracts, overlapping responsibilities, or inconsistent state assumptions — the contradiction must be resolved.

**Detection.** A contradiction exists when:

- Two DDS documents offer contracts with incompatible guarantees for the same concern.
- Two DDS documents both claim responsibility for the same DAS obligation without acknowledging the overlap in their DAS Traceability sections.
- A required contract in one DDS assumes properties that conflict with the offered contract in another DDS.

**Resolution workflow:**

1. **Identify the conflict explicitly.** State which claim in DDS-A contradicts which claim in DDS-B.
2. **Determine the source.** Trace both claims to their DAS origins. If both trace to the same DAS obligation, the DDS layer has introduced the contradiction — one or both DDS documents are defective. If they trace to different DAS obligations that are themselves in tension, the resolution path is an RFC against the DAS (Section 6.1).
3. **Resolve at the DDS level.** The DDS dependency graph does not impose a precedence order for contradiction resolution — unlike the DAS layer hierarchy, DDS documents within the same dependency tier have no inherent priority. Instead, file a DCP (Section 8.4) against one or both documents. The DCP must resolve the contradiction, not merely acknowledge it.
4. **Until resolved,** the contradiction must be flagged in both documents' front matter as a known issue. Implementation that touches the contradicted area must be reviewed against both documents and the resolution DCP.

---

## 9. Document Lifecycle

### 9.1 States

Every DDS document exists in exactly one of five states:

```
Draft → Under Review → Approved → Deprecated
                                 → Superseded
```

### 9.2 State Definitions

**Draft.** The document is being authored. It may be incomplete and may contain open questions. Draft documents are visible to all contributors but carry no authority — implementation may reference Draft documents for direction but is not bound by them.

**Under Review.** The document is complete in the author's judgment and has been submitted for review. It must pass all review checklist items (Section 8.1) before advancing.

**Approved.** The document has passed review and is authoritative. Implementation must conform to Approved DDS documents. Changes require a Design Change Proposal (Section 8.4) and follow the versioning process (Section 8.3).

**Deprecated.** The document is no longer the recommended design but has not been replaced. Existing implementation is not required to change immediately, but new implementation must not rely on Deprecated designs.

**Superseded.** The document has been replaced by a newer DDS document. The superseding document is identified in the front matter. Superseded documents are retained for historical reference.

### 9.3 Transition Rules

| Transition | Who | Conditions |
|------------|-----|------------|
| Draft → Under Review | Author | Passes all structural and traceability checks |
| Under Review → Draft | Reviewer | Review identifies defects requiring substantive changes |
| Under Review → Approved | Technical lead or designated authority | Passes review checklist; no unresolved contradictions |
| Approved → Deprecated | Technical lead | Design determined to be incorrect or superseded by new understanding |
| Approved → Superseded | Technical lead | Replacement DDS document has been Approved |

---

## 10. Anti-Patterns

The following patterns indicate a defective DDS document. Each anti-pattern includes a detection heuristic.

### AP-1: Architecture Restatement

**Symptom:** The DDS document repeats DAS content using slightly different words. The responsibilities section reads like a summary of a DAS chapter.

**Detection:** Delete the DDS document. If a reader could reconstruct its content entirely from the DAS chapters it references, the DDS adds nothing.

**Resolution:** The DDS must add engineering-specific content: state models, failure modes, concurrency constraints, performance bounds. If none of these are relevant, the subsystem may not need a DDS.

### AP-2: Implementation Journal

**Symptom:** The DDS describes what the current code does. Contracts are written in terms of specific types, methods, or data structures from the current implementation.

**Detection:** Imagine reimplementing the subsystem in a different language. If the DDS would need revision, it contains implementation leakage.

**Resolution:** Replace implementation-specific language with contract-level language. "The scheduler executes passes in topological order" not "The scheduler calls `executePasses()` on the `PassDAG` struct."

### AP-3: Requirements List

**Symptom:** The DDS lists what the subsystem should do ("shall support," "must handle") without specifying how correctness is defined, how failure is handled, or what contracts govern interactions.

**Detection:** Could a developer implement the subsystem from this document alone (given the DAS)? If the answer is "only if they also know the rest of the codebase," the document is incomplete.

**Resolution:** Add state models, contracts, failure modes, and lifecycle specifications.

### AP-4: Gold Plating

**Symptom:** The DDS specifies more contracts, failure modes, or performance requirements than necessary to realize the DAS obligations.

**Detection:** For every contract, ask: "Which DAS invariant breaks if this contract is removed?" If the answer is "none," the contract may be over-specification.

**Resolution:** Remove or demote to "Implementation Guidance" (non-binding notes in Future Evolution).

### AP-5: Implicit Coupling

**Symptom:** The DDS assumes properties of another subsystem without declaring a required contract. "The scheduler assumes the DIR is available" without listing DIR availability as a required contract.

**Detection:** List every noun in the DDS that refers to something outside the subsystem. Each must correspond to a required contract.

**Resolution:** Make every external dependency explicit as a required contract.

---

## 11. DDS Numbering

### 11.1 Numbering Scheme

DDS documents are numbered sequentially: DDS-000, DDS-001, DDS-002, etc. Numbers are never reused, even if a document is superseded.

### 11.2 Naming Convention

Each DDS document file is named:

```
DDS-NNN-[Subsystem-Name].md
```

The subsystem name uses kebab-case and is descriptive of the subsystem, not the DAS chapter it realizes. Example: `DDS-003-Pass-Scheduler.md` (not `DDS-003-DAS-006-Realization.md`).

### 11.3 Foundational Documents

DDS-000 (this document) is the design authoring standard. It is not a runtime subsystem specification and therefore does not follow the full section template. All other DDS documents must follow the full template defined in Section 3.

---

## 12. Relationship to DAS-000

This document (DDS-000) is the DDS analog of DAS-000 (Architecture Authoring Standard). The two documents govern different layers of the documentation hierarchy:

| Concern | DAS-000 | DDS-000 |
|---------|---------|---------|
| Governs | Architecture chapters | Design documents |
| Content type | Architectural decisions, invariants, domain models | Engineering contracts, state models, failure modes |
| Abstraction level | Implementation-agnostic, technology-neutral | Implementation-agnostic, engineering-specific |
| Rate of change | Very slow (years) | Moderate (months) |
| Authority source | Domain analysis, first principles | DAS chapters |
| Audience | Architects, senior engineers | Engineers implementing subsystems |

DDS-000 inherits DAS-000's principles by reference and does not re-derive them. Where DAS-000 defines rules for architectural documents, DDS-000 defines rules for engineering specifications that realize those architectural documents.

---

## Revision History

```
0.1 — 2026-06-28 — Principal Engineer — Initial draft
0.2 — 2026-06-29 — Principal Engineer — CTO review revisions: added DCP change process (§8.4), contradiction resolution (§8.5), Open Questions template section (§3.17), qualified contract references (§3.6, §4.3), structural terminology (§7), fixed DP-1 test consistency
0.3 — 2026-06-28 — Principal Engineer — Platform consistency cleanup:
      Depended By field redefined as derived metadata (§3.1). Frozen
      specifications should not require revision when new dependents
      are authored.
```
