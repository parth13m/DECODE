# DAS-000: Architecture Authoring Standard

```
Chapter:       DAS-000
Title:         Architecture Authoring Standard
Status:        Draft
Version:       0.1
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    None
Depended By:   All DAS chapters
Supersedes:    —
Superseded By: —
Layer:         Meta
```

## Abstract

This chapter defines the mandatory structure, authoring rules, review process, and governance for the Decode Architecture Specification (DAS). Every DAS chapter must conform to this standard. It is the constitutional document of the specification itself — the rules by which rules are written.

## Motivation

Without a governing standard, architecture documents degrade into one of three failure modes: (1) implementation journals that describe what the code does rather than prescribing what it must do, (2) aspirational essays that express vision without constraining design, or (3) inconsistent collections where each chapter uses different terminology, different levels of abstraction, and different decision formats, making cross-chapter reasoning impossible.

The DAS must serve as a stable foundation for a decade of architectural evolution. This requires that every chapter be internally consistent, externally compatible, reviewable by someone who did not author it, and versionable without ambiguity. DAS-000 defines the process that makes this possible.

## Terminology

**DAS** — The Decode Architecture Specification. The complete set of architectural chapters governing Decode's design. `INTRODUCED`

**DAS Chapter** — A single document within the DAS addressing one architectural concern. `INTRODUCED`

**RFC** — Request for Comments. An exploratory document that investigates an architectural question and recommends a decision. RFCs are persuasive; DAS chapters are normative. `INTRODUCED`

**ACR** — Architecture Change Request. A formal proposal to change an Approved DAS chapter. `INTRODUCED`

**Invariant** — A statement that must hold true at all times once the containing chapter is Approved. Violation of an invariant is an architectural defect. `INTRODUCED`

**Consequence** — A specific, testable implication that follows from an architectural decision. `INTRODUCED`

**Layer** — One of six levels of architectural concern (L0–L5) that organize the DAS. Dependencies flow strictly downward. `INTRODUCED`

**Architectural Leakage** — The contamination of one layer's concerns into another layer's chapter. `INTRODUCED`

---

## 1. Purpose

### 1.1 Why the DAS Exists

The Decode Architecture Specification exists to answer one question for every engineering decision: **why**.

Code answers *what*. Tests answer *whether*. Commits answer *when*. The DAS answers *why* — why this abstraction exists, why this boundary is here, why this alternative was rejected, why this invariant must hold. Without a persistent, versioned record of architectural reasoning, each new engineer (or the same engineer six months later) must re-derive the reasoning from first principles or, more commonly, accept the existing structure as given and work around its constraints without understanding them.

The DAS serves three functions:

1. **Decision record.** It captures the reasoning behind architectural choices so they can be evaluated, challenged, and revised with full context rather than partial memory.
2. **Consistency enforcement.** It defines the abstractions, boundaries, and invariants that all implementation must respect. Code that violates DAS invariants is defective by definition, regardless of whether it passes tests.
3. **Communication substrate.** It provides a shared vocabulary and mental model that enables architectural discussion without ambiguity. When the DAS defines a term, that definition is authoritative.

### 1.2 What Problems It Solves

| Problem | How the DAS addresses it |
|---------|------------------------|
| **Architectural amnesia** — decisions are made, reasons are forgotten, decisions are revisited without context | Every decision records its alternatives, evaluation criteria, and rejection rationale |
| **Vocabulary drift** — the same concept is called different things, or different concepts share a name | The terminology registry is authoritative; no chapter may introduce a term without defining it |
| **Implementation capture** — the architecture becomes whatever the code currently does | The DAS is written *before* implementation; code conforms to the DAS, not the reverse |
| **Invisible coupling** — dependencies between components are implicit and discovered only when something breaks | The DAS explicitly defines boundaries, allowed dependencies, and composition rules |
| **Unjustified complexity** — abstractions exist because someone added them, not because the domain requires them | Every abstraction must justify its existence against the alternative of not having it |

### 1.3 What the DAS Must Never Become

- **An implementation guide.** The DAS defines *what* and *why*, never *how*. If a chapter specifies a programming language, a framework, a data format, or an algorithm, it has failed.
- **A requirements document.** The DAS does not define what the product should do. It defines the architectural structure within which product requirements are fulfilled.
- **A historical narrative.** The DAS is not a journal of how the architecture evolved. It describes the architecture *as it should be now*. Historical context belongs in decision rationale sections, not in the main body.
- **An aspirational vision.** Every statement in the DAS must be either *currently true* (for Approved chapters) or *intended to become true upon implementation* (for Draft chapters). Speculative future capabilities belong in RFCs, not the DAS.
- **A style guide.** The DAS does not govern coding conventions, formatting, naming patterns, or other implementation-level concerns.

---

## 2. Guiding Principles

These principles govern the authoring of the DAS itself. They are ordered by precedence: when principles conflict, the higher-numbered principle yields to the lower.

### P1: Domain Before Structure

Architecture derives from the problem domain, not from software patterns. The first question is always "what does the domain require?" — never "what pattern should we apply?" If the domain has a natural structure, the architecture mirrors it. If the domain has no natural structure in some area, the architecture does not impose one.

**Test:** If you removed all technical terminology from a chapter and a domain expert could still follow the reasoning, the chapter adheres to this principle. If the reasoning is only intelligible to engineers, the chapter has likely imposed structure rather than discovered it.

### P2: Decisions Require Alternatives

No architectural choice is valid unless at least one alternative was explicitly considered and rejected with stated reasons. A "decision" with no alternatives is an assumption. Assumptions are permitted only when explicitly labeled as such, with a stated condition under which the assumption should be revisited.

**Test:** Every `Decision` section in a chapter must reference at least one rejected alternative with a non-trivial rejection rationale. "We didn't consider alternatives" is a defect.

### P3: Abstractions Justify Their Cost

Every abstraction — every boundary, every indirection, every named concept — imposes a cost: cognitive load, maintenance burden, and constraint on future options. An abstraction is justified only when the cost of *not* having it exceeds the cost of having it. The burden of proof is on the abstraction, not on its absence.

**Test:** For every abstraction defined in a chapter, ask: "What goes wrong if we remove this and inline its responsibilities?" If nothing concrete goes wrong, the abstraction is not justified.

### P4: Invariants Over Descriptions

A chapter that describes how something works is less valuable than a chapter that states what must always be true. Descriptions become stale; invariants are testable. Wherever possible, express architectural constraints as invariants rather than narratives.

**Test:** If every invariant in a chapter were removed, would the remaining text still constrain implementation? If yes, the invariants are redundant. If no, the invariants are doing real work and the descriptions may be the redundant part.

### P5: Explicit Uncertainty Over False Precision

When the correct architectural choice is unknown, the DAS must say so rather than commit to an insufficiently justified decision. A chapter with clearly marked open questions is superior to a chapter that papers over uncertainty with confident-sounding but unsupported claims.

**Test:** Read the chapter as a skeptic. If any claim provokes the reaction "how do you know that?" and the chapter doesn't address it, the chapter is falsely precise.

### P6: Stability of Abstractions Over Stability of Implementation

The DAS should define abstractions that remain valid even when the underlying technology changes. If a chapter would need revision because a database was swapped, a language was changed, or an AI model was upgraded, it contains implementation leakage.

**Test:** Imagine replacing every technology in the current stack. If the chapter still makes sense, it is at the right level of abstraction.

### P7: Composition Over Taxonomy

Prefer defining small, composable concepts over large, hierarchical taxonomies. Taxonomies are brittle — every new case that doesn't fit requires reclassification. Composable concepts are resilient — new cases are assembled from existing primitives.

**Test:** If adding a new capability to the system requires modifying an existing taxonomy (adding a new case to an enum, a new type to a hierarchy), the architecture is taxonomic. If the new capability can be expressed as a new combination of existing concepts, the architecture is compositional.

---

## 3. Chapter Structure

Every DAS chapter must contain the following sections in this order. Sections marked **mandatory** must be present. Sections marked **conditional** must be present when the stated condition applies.

### 3.1 Front Matter (mandatory)

```
Chapter:       DAS-NNN
Title:         [chapter title]
Status:        Draft | Under Review | Approved | Deprecated | Superseded
Version:       [semantic version: major.minor]
Author:        [name]
Reviewers:     [names]
Created:       [date]
Last Revised:  [date]
Depends On:    [list of DAS chapters this chapter assumes]
Depended By:   [list of DAS chapters that assume this chapter]
Supersedes:    [chapter ID, if applicable]
Superseded By: [chapter ID, if applicable]
Layer:         [L0 | L1 | L2 | L3 | L4 | L5 | Meta]
```

### 3.2 Abstract (mandatory)

One paragraph. Maximum 150 words. States what the chapter defines, what architectural question it answers, and what scope it covers. No reasoning, no justification, no history — just scope.

### 3.3 Motivation (mandatory)

Answers: *Why does this chapter need to exist?* Identifies the specific architectural ambiguity, risk, or decision that this chapter resolves. Must reference concrete consequences of *not* having this chapter — what goes wrong, what becomes inconsistent, what requires ad-hoc judgment.

### 3.4 Terminology (mandatory)

Every term that the chapter introduces or uses in a non-obvious way must be defined here. Terms already defined in prior DAS chapters must be referenced, not redefined. See Section 6 for terminology rules.

Format:

> **Term** — Definition. [If introduced by this chapter: `INTRODUCED`] [If defined in another chapter: `See DAS-NNN`]

### 3.5 Domain Analysis (mandatory)

The chapter must establish the domain context before proposing any architectural structure. This section answers: *What is true about the problem domain, independent of any software system?* It contains only domain facts and domain constraints — not design choices.

**Requirement:** At least one domain fact must be non-obvious. If every fact in the Domain Analysis is trivially known to every engineer, the analysis is too shallow.

### 3.6 Candidates (mandatory for decision chapters)

When the chapter makes an architectural decision, all considered alternatives must be presented here. Each candidate must include:

- **Definition:** What it is, in one paragraph.
- **Implications:** What architectural consequences follow from choosing it.
- **Strengths:** What problems it solves well.
- **Weaknesses:** What problems it solves poorly or creates.
- **Disqualifying condition (if any):** A single property that, if confirmed, eliminates this candidate regardless of its strengths.

Minimum: two candidates. There is no maximum, but more than five suggests the decision space has not been sufficiently narrowed.

### 3.7 Evaluation (mandatory for decision chapters)

A structured comparison of candidates against explicitly stated criteria. Criteria must be derived from the Domain Analysis and the Motivation — not introduced ad hoc. The evaluation must make the reasoning *reproducible*: a reader who disagrees with the conclusion should be able to identify exactly which criterion or which judgment they dispute.

Format: matrix, prose, or both — but the criteria, the candidates, and the assessments must all be explicit.

### 3.8 Decision (mandatory for decision chapters)

States the chosen alternative in one or two sentences. References the evaluation. Does not re-argue — the argument belongs in the Evaluation.

### 3.9 Architectural Consequences (mandatory)

States what follows from the decision. Every consequence must be:

- **Specific:** "All X must Y" rather than "X should generally Y."
- **Testable:** An engineer can determine whether the consequence is honored by inspecting the system.
- **Non-trivial:** The consequence must exclude at least one plausible design that someone might otherwise pursue.

Consequences are numbered C1, C2, ... for stable referencing.

### 3.10 Invariants (mandatory)

Statements that must hold true *at all times* once this chapter is Approved. Invariants are the strongest claims in the DAS. Violating an invariant is an architectural defect, not a style issue.

Each invariant must include:

- **Statement:** The invariant itself, phrased as a universally quantified assertion ("Every X must Y" or "No X may Y").
- **Rationale:** Why this invariant is necessary — what breaks if it is violated.
- **Verification:** How a reviewer can determine whether the invariant holds (not how to implement it, but how to check it).

Invariants are numbered I1, I2, ... for stable referencing.

### 3.11 Non-Goals (mandatory)

Explicit statements of what this chapter does *not* address, does *not* decide, and must *not* be interpreted as implying. Non-goals prevent scope creep and prevent readers from drawing conclusions the author did not intend.

### 3.12 Open Questions (conditional: required when uncertainty exists)

Questions that the author could not resolve and that remain open for future work. Each question must include:

- **The question itself.**
- **Why it matters:** What decisions are blocked or weakened by not knowing the answer.
- **Suggested approach:** How the question might be investigated (not answered — investigated).

### 3.13 Dependency Map (conditional: required when chapter references or is referenced by other chapters)

A listing of which other DAS chapters this chapter depends on (concepts it assumes) and which chapters depend on it (concepts it defines that others use). This must be consistent with the front matter and kept current.

### 3.14 Revision History (mandatory)

A log of substantive changes. Format:

```
[version] — [date] — [author] — [summary of change]
```

Formatting changes, typo fixes, and other non-substantive edits do not require entries.

---

## 4. Architectural Decision Rules

### 4.1 What Qualifies as a First-Principles Argument

An argument is from first principles if it derives its conclusion from domain properties, stated constraints, and logical inference — without appealing to authority, convention, or precedent. Specifically:

- **Valid first-principles premises:** Domain constraints ("software changes over time"), stated requirements ("the system must support multiple languages"), logical necessities ("if A depends on B and B depends on C, then A transitively depends on C"), and observed properties of the problem space.
- **Invalid first-principles premises:** "This is how X does it," "this is industry best practice," "this is the standard approach," "most systems use Y." These are appeals to convention, not reasoning.

A first-principles argument may reach the same conclusion as convention. The distinction is in the *derivation*, not the *conclusion*.

### 4.2 When Industry Practice May Be Referenced

Industry practice may be cited in two contexts:

1. **As evidence, not authority.** "System X made this choice and observed these consequences" is legitimate evidence. "System X does this, therefore we should" is not.
2. **As a default when analysis is inconclusive.** If the first-principles analysis cannot distinguish between candidates, industry practice may serve as a tiebreaker — but this must be stated explicitly: "We could not distinguish these alternatives on architectural grounds; we default to the more common approach to reduce the novelty burden."

Industry practice must never override a first-principles argument that points to a different conclusion.

### 4.3 How Competing Alternatives Are Evaluated

1. **State the evaluation criteria before examining candidates.** Criteria derived after seeing the candidates are suspect — they may be unconsciously chosen to favor a preferred option.
2. **Weight the criteria explicitly.** If some criteria matter more than others, say so and say why.
3. **Evaluate every candidate against every criterion.** A missing cell in the evaluation matrix is a defect.
4. **Distinguish disqualifying weaknesses from acceptable weaknesses.** A candidate may be weak in one area and still be the best choice overall. But some weaknesses are disqualifying — the chapter must state which and why.
5. **Prefer the candidate that is *least wrong* over the candidate that is *most appealing*.** Robustness under adversarial conditions (the domain turns out differently than expected) matters more than optimality under assumed conditions.

### 4.4 How Uncertainty Is Represented

Uncertainty must be explicit, never implicit. The DAS uses three levels:

| Level | Meaning | How to express |
|-------|---------|---------------|
| **Decided** | The analysis is conclusive and the choice is committed | Normal declarative prose in Decision and Consequences |
| **Provisional** | The analysis favors one option but key assumptions are untested | Decision section states the choice; an Open Question identifies the untested assumption and the condition that would trigger reconsideration |
| **Unresolved** | The analysis cannot distinguish candidates or insufficient information exists | No Decision section; the chapter remains Draft with Open Questions that block resolution |

A chapter may be Approved with Provisional decisions but not with Unresolved decisions.

### 4.5 When a Chapter Should Remain Draft

A chapter must remain Draft (and cannot advance to Under Review) if any of the following are true:

- It contains an Unresolved decision.
- Its Terminology section uses terms that are not defined in this chapter or in any Approved chapter.
- Its Invariants are not verifiable (no reviewer could check them).
- Its Dependency Map references chapters that are themselves Draft and whose decisions could change this chapter's reasoning.

---

## 5. Layer Separation

The DAS is organized into six architectural layers. Each layer addresses a distinct concern. Chapters must declare which layer they belong to. A chapter may span two adjacent layers if the boundary between them is the subject of the chapter.

### 5.1 The Layers

```
L0  Philosophy     — Why does Decode exist? What is the canonical asset?
                     What principles constrain all decisions?

L1  Domain Model   — What are the fundamental entities, relationships,
                     and operations in Decode's problem space?

L2  Intelligence   — How is intelligence built, composed, maintained,
                     and versioned? What are the layers of intelligence?

L3  Retrieval      — How is intelligence queried, filtered, projected,
                     and delivered to consumers?

L4  Delivery       — How are outputs (understanding, analysis, action
                     recommendations) produced from retrieved intelligence?

L5  Realization    — How do L1–L4 map to concrete subsystems, interfaces,
                     and deployment structures?
```

### 5.2 Dependency Direction

Dependencies flow strictly downward: a chapter at layer N may depend on chapters at layers 0 through N, but never on chapters at layers N+1 or above. This constraint prevents implementation details from influencing domain decisions or philosophical principles.

**Exception:** L5 (Realization) chapters may identify constraints that propagate upward as new domain facts. When this occurs, the constraint must be added to the relevant L1 chapter through the change process (Section 8), not absorbed silently into the L5 chapter.

### 5.3 Leakage Detection

Architectural leakage occurs when a chapter at layer N contains concerns that belong to layer M (where M != N). Common leakage patterns:

| Leakage | Symptom | Example |
|---------|---------|---------|
| **Upward** (implementation into domain) | A domain chapter mentions a specific technology, protocol, or storage mechanism | "Intelligence is stored in a graph database" in an L1 chapter |
| **Downward** (philosophy into implementation) | A realization chapter re-argues philosophical principles instead of citing them | An L5 chapter that re-derives why intelligence is the canonical asset |
| **Lateral** (cross-concern contamination) | A retrieval chapter defines delivery formats; a delivery chapter defines storage structures | An L3 chapter specifying JSON response schemas |

The review checklist (Section 9) includes specific tests for leakage.

### 5.4 Layer-Specific Constraints

**L0 (Philosophy):** Must contain no architectural structures — only principles, values, and constraints. Must be stable across major version changes. A Philosophy chapter that needs frequent revision is at the wrong layer.

**L1 (Domain Model):** Must be expressible without any software terminology. If the domain model requires words like "service," "handler," "cache," or "pipeline," it has been contaminated by implementation thinking. Domain models use domain language.

**L2 (Intelligence):** Must define what intelligence *is* and how it *behaves* — not how it is *computed*. Computation is an L5 concern.

**L3 (Retrieval):** Must define what queries are possible and what guarantees they provide — not how queries are *executed*. Execution is an L5 concern.

**L4 (Delivery):** Must define what outputs look like semantically — not how they are *rendered*. Rendering is an L5 concern.

**L5 (Realization):** Must not introduce new abstractions. Every abstraction used in L5 must be defined in L0–L4. L5 maps existing abstractions to concrete implementations.

---

## 6. Terminology Rules

### 6.1 Introduction of New Terms

A new term may be introduced in the DAS only when all of the following conditions are met:

1. **No existing term covers the concept.** The author must demonstrate that no previously defined DAS term, no standard industry term, and no natural-language word already captures the intended meaning.
2. **The concept requires frequent reference.** A concept mentioned once does not need a term. A concept referenced across multiple sections or chapters justifies a term.
3. **The definition is precise.** A term definition must be specific enough that two readers, given the same system, would agree on whether a given thing is or is not an instance of the term.
4. **The term is introduced in exactly one chapter.** Other chapters reference the defining chapter; they do not redefine.

### 6.2 Term Format

Every term definition must include:

- **Term:** The word or phrase.
- **Definition:** What it means, in one to three sentences.
- **Distinguishing example:** At least one example of something that *is* an instance and one example of something that is *not* but might be confused for one.
- **Layer:** Which DAS layer the term belongs to.

### 6.3 Duplicate Prevention

Before introducing a term, the author must:

1. Search all existing DAS chapters for the concept (not just the word — the concept may exist under a different name).
2. If a related term exists, explicitly state the relationship: "X is a specialization of Y," "X replaces Y," or "X is distinct from Y because..."

### 6.4 Term Evolution

Terms may evolve through the standard change process (Section 8). When a term's definition changes:

- The defining chapter is revised with a new version number.
- All chapters that use the term are reviewed for consistency with the new definition.
- The revision history records the old definition and the reason for change.

When a term is retired:

- The defining chapter marks the term as `DEPRECATED` with a pointer to the replacement (if any).
- The term remains in the chapter's Terminology section (for historical reference) but is struck through.

### 6.5 Terminology Registry

A standalone document, **[TERMS.md](../glossary/TERMS.md)**, serves as the master index of all terms defined across the DAS. It contains no definitions itself — only pointers to the defining chapter. It is mechanically derivable from the chapters and should be regenerated, not hand-maintained.

---

## 7. Lifecycle

### 7.1 States

Every DAS chapter exists in exactly one of five states:

```
Draft → Under Review → Approved → Deprecated
                                 → Superseded
```

### 7.2 State Definitions

**Draft.** The chapter is being authored. It may be incomplete, contain unresolved questions, and lack full review. Draft chapters are visible to all contributors but carry no authority — implementation must not depend on Draft chapters.

**Under Review.** The chapter is complete in the author's judgment and has been submitted for review. It must pass all mandatory section checks (Section 3) and all review checklist items (Section 9) before advancing. Under Review chapters may be cited by other Draft chapters but still carry no implementation authority.

**Approved.** The chapter has passed review and is authoritative. Implementation must conform to Approved chapters. Approved chapters may only be changed through the change process (Section 8).

**Deprecated.** The chapter is no longer the recommended approach but has not been replaced. This occurs when a decision is reversed without a replacement being finalized. Deprecated chapters should not be used for new implementation but existing implementation is not required to change immediately.

**Superseded.** The chapter has been replaced by a newer chapter. The superseding chapter is identified in the front matter. Superseded chapters are retained for historical reference but carry no authority.

### 7.3 Transition Rules

| Transition | Who | Conditions |
|------------|-----|------------|
| Draft → Under Review | Author | All mandatory sections present; all Open Questions classified as either blocking or non-blocking; no undefined terms |
| Under Review → Draft | Reviewer | Review identifies structural defects (missing sections, unverifiable invariants, evaluation gaps) |
| Under Review → Approved | CTO or designated authority | Passes review checklist (Section 9); no blocking Open Questions; all dependencies are Approved or Provisional |
| Approved → Deprecated | CTO | A decision in the chapter is determined to be incorrect or no longer applicable, and no replacement is ready |
| Approved → Superseded | CTO | A replacement chapter has been Approved |
| Deprecated → Superseded | CTO | A replacement chapter has been Approved |
| Any → Draft | CTO | Emergency reversal; requires written justification appended to revision history |

### 7.4 Versioning

Chapters use two-part version numbers: `major.minor`.

- **Minor** increment: clarification, additional examples, non-substantive rewording, resolution of a non-blocking Open Question. Does not require re-review.
- **Major** increment: change to any Decision, Consequence, or Invariant. Requires full re-review, including review of all dependent chapters for consistency.

---

## 8. Change Process

### 8.1 Proposing Changes

Changes to Approved chapters are proposed through **Architecture Change Requests (ACRs)**. An ACR must include:

1. **Target:** Which chapter and which sections are affected.
2. **Motivation:** Why the current architecture is insufficient — what new information, changed requirements, or discovered defect motivates the change.
3. **Proposed change:** The specific textual change, written as a diff against the current chapter.
4. **Impact analysis:** Which other chapters are affected by the change and how.
5. **Backward compatibility assessment:** Whether existing implementation that conforms to the current chapter will violate the proposed change.

### 8.2 Relationship Between RFCs and the DAS

RFCs and DAS chapters serve different purposes:

| | RFC | DAS Chapter |
|---|-----|------------|
| **Purpose** | Explore a question, propose an answer | Define authoritative architecture |
| **Tone** | Investigative, discursive | Declarative, precise |
| **Lifecycle** | Written, discussed, accepted or rejected | Written, reviewed, approved, maintained |
| **Authority** | Persuasive (arguments may be accepted or rejected) | Normative (approved chapters constrain implementation) |

The typical flow:

1. An RFC explores an architectural question, considers alternatives, and recommends a decision.
2. If the RFC's recommendation is accepted, the relevant DAS chapter is authored (or revised) to incorporate the decision.
3. The DAS chapter cites the RFC as the source of the analysis but does not reproduce it in full.
4. The RFC is archived. It is not updated when the DAS chapter evolves.

**An RFC is never authoritative.** Only DAS chapters, once Approved, constrain implementation. An accepted RFC that has not yet been incorporated into a DAS chapter is a commitment to act, not a binding specification.

### 8.3 Resolving Contradictions

When two Approved chapters contradict each other:

1. **Identify the conflict explicitly.** State which claim in Chapter A contradicts which claim in Chapter B.
2. **Determine precedence.** The chapter at the lower DAS layer (closer to L0) takes precedence, because higher layers derive from lower layers. If both chapters are at the same layer, neither takes precedence — the contradiction must be resolved through an ACR.
3. **File an ACR** against the chapter that must change. The ACR must resolve the contradiction, not merely acknowledge it.
4. **Until resolved,** the contradiction must be flagged in both chapters' front matter as a known issue. Implementation that touches the contradicted area must be reviewed against both chapters and the resolution ACR.

---

## 9. Review Checklist

The following checklist is applied by the reviewing authority before approving any chapter. Every item must be satisfied. Failure on any item returns the chapter to Draft with specific feedback.

### 9.1 Structural Completeness

- [ ] All mandatory sections (per Section 3) are present.
- [ ] Front matter is complete with all fields populated.
- [ ] Dependency Map is consistent with front matter `Depends On` / `Depended By`.
- [ ] Revision history is current.

### 9.2 Reasoning Quality

- [ ] The Motivation identifies a concrete problem, not a vague aspiration.
- [ ] The Domain Analysis contains at least one non-obvious domain fact.
- [ ] Every decision has at least two evaluated alternatives.
- [ ] Evaluation criteria are stated before candidates are assessed, not derived post hoc.
- [ ] The Decision follows from the Evaluation — a reader who accepts the criteria and the assessments would reach the same conclusion.
- [ ] No rejected alternative is dismissed with a single sentence. Each rejection identifies what specifically disqualified the alternative.

### 9.3 Abstraction Quality

- [ ] Every introduced abstraction passes the removal test: something concrete goes wrong if it is removed.
- [ ] No abstraction is introduced solely to mirror an existing implementation structure.
- [ ] Abstractions compose rather than taxonomize (Principle P7).
- [ ] The chapter does not define an abstraction that duplicates a concept in another chapter under a different name.

### 9.4 Invariant Quality

- [ ] Every invariant is phrased as a universal assertion ("Every X must Y" or "No X may Y").
- [ ] Every invariant has a rationale (what breaks if violated).
- [ ] Every invariant has a verification method (how to check it).
- [ ] No invariant is trivially true (always satisfied regardless of design choices).
- [ ] No invariant is impossibly strict (no design could satisfy it in all cases).

### 9.5 Layer Discipline

- [ ] The chapter declares its layer (L0–L5).
- [ ] The chapter does not reference concepts from higher layers.
- [ ] The chapter does not contain implementation-specific language (technology names, data formats, protocol details, algorithm specifications) unless it is an L5 chapter.
- [ ] An L1 chapter could be understood by a non-engineer domain expert.
- [ ] An L5 chapter does not introduce new abstractions — it only maps abstractions defined at L0–L4.

### 9.6 Terminology Discipline

- [ ] Every non-obvious term used in the chapter is defined in the Terminology section or referenced to its defining chapter.
- [ ] No term is redefined — terms defined in prior chapters are cited, not restated.
- [ ] Every new term meets the introduction criteria (Section 6.1): no existing term suffices, the concept recurs, the definition is precise.
- [ ] Distinguishing examples (is / is-not) are provided for each new term.

### 9.7 Consistency

- [ ] No claim in this chapter contradicts any claim in an Approved chapter.
- [ ] All referenced chapters are at status Approved or Under Review (not Draft).
- [ ] The chapter's conclusions do not depend on assumptions made in Draft chapters that could change.

### 9.8 Anti-Pattern Detection

- [ ] The chapter does not exhibit any anti-pattern listed in Section 10.
- [ ] Specifically: no implementation capture, no technology-first reasoning, no premature optimization, no naming-driven architecture, no abstraction without justification, no speculative generality, no inverted dependency, no false dichotomy, no scope inflation, no cargo-cult structure.

### 9.9 Completeness

- [ ] The Non-Goals section is present and non-trivial (it excludes something a reasonable reader might expect to be in scope).
- [ ] Open Questions are classified as blocking or non-blocking.
- [ ] No blocking Open Questions remain (for Approved status).
- [ ] The chapter does not use hedging language ("might," "could," "possibly," "it seems") in Decisions, Consequences, or Invariants. Uncertainty belongs in Open Questions, not in authoritative statements.

---

## 10. Anti-Patterns

The following anti-patterns must be actively avoided in all DAS chapters. The review checklist tests for their presence.

### AP1: Implementation Capture

**Description.** The architecture is derived from what the code currently does rather than from what the domain requires. The existing implementation is treated as evidence of architectural intent.

**Symptom.** The chapter's abstractions map one-to-one to existing classes or modules. The chapter would need revision if the code were refactored without changing behavior.

**Remedy.** Write the chapter as if no implementation exists. Then compare with the existing implementation — divergence is expected and healthy. The implementation should change to match the architecture, not the reverse.

### AP2: Technology-First Architecture

**Description.** An architectural decision is justified by the properties of a specific technology ("we use X because it supports Y") rather than by domain requirements ("the domain requires Y; the realization layer selects X to provide it").

**Symptom.** Remove all technology names from the chapter. If the reasoning collapses, the architecture is technology-first.

**Remedy.** Rewrite the reasoning in technology-neutral terms. If the reasoning cannot be expressed without technology, it belongs at L5, not at the layer where it currently sits.

### AP3: Premature Optimization

**Description.** Architectural complexity is introduced to solve a performance problem that has not been observed and may not exist.

**Symptom.** Phrases like "for performance reasons," "to avoid the overhead of," or "to enable future scaling" without supporting evidence. Caching layers, denormalization strategies, or batching mechanisms defined before the baseline cost is known.

**Remedy.** State the performance requirement as a constraint in the Domain Analysis. If no performance requirement exists, the optimization is premature. If a requirement exists, justify the architectural response against the measured (or rigorously estimated) cost.

### AP4: Naming-Driven Architecture

**Description.** A concept is introduced because a good name was found for it, not because the domain requires it. The name gives the illusion of necessity.

**Symptom.** The chapter introduces a term, defines an abstraction around it, but the abstraction's responsibilities are either trivial (it wraps a single operation) or vague (its boundary is not testable). Removing the named concept and distributing its responsibilities elsewhere would simplify the system.

**Remedy.** Apply the removal test (P3). If the name can be removed without architectural consequence, the concept does not deserve to exist as a named abstraction.

### AP5: Abstraction Without Justification

**Description.** An architectural boundary, layer, or interface is introduced without a stated reason. It exists "because good architecture has layers" or "for separation of concerns" without identifying which concerns are being separated or why separating them matters.

**Symptom.** The chapter defines a boundary but cannot articulate a scenario in which one side of the boundary changes independently of the other. The boundary imposes cost (indirection, interface definition, communication overhead) without enabling independence.

**Remedy.** For every boundary, state the independent variability it enables: "Side A may change (in these ways) without requiring changes to Side B." If no such variability exists, the boundary is unjustified.

### AP6: Speculative Generality

**Description.** The architecture is designed to accommodate future requirements that are hypothetical, not planned. Extension points, plugin architectures, and generic abstractions are introduced "in case we need them."

**Symptom.** The chapter discusses capabilities that are not in the current roadmap and introduces architectural structure to support them. The word "might" appears in justifications.

**Remedy.** Design for what is known and planned. If a future capability is sufficiently likely and its architectural impact sufficiently large, it may be noted in Open Questions — but it does not justify structural complexity in the current chapter.

### AP7: Inverted Dependency

**Description.** A lower-layer chapter (closer to L0) depends on decisions made in a higher-layer chapter (closer to L5). The domain model is shaped by implementation constraints rather than the reverse.

**Symptom.** An L1 chapter references an L3 or L5 concept. A philosophical principle (L0) is justified by an implementation constraint (L5).

**Remedy.** Restructure the dependency. If an implementation constraint genuinely affects the domain model, promote the constraint to a domain fact (through the change process) and derive the architectural consequence from the domain fact, not from the implementation.

### AP8: False Dichotomy

**Description.** The chapter presents two alternatives and chooses one, when a third option (often a synthesis or a reframing of the problem) would be superior. Binary framing is used to manufacture decisiveness.

**Symptom.** Exactly two candidates in the Candidates section. The evaluation reads as "A is bad because X, therefore B." No exploration of whether the X problem can be solved within A, or whether a hybrid approach exists.

**Remedy.** Actively search for at least one more candidate before finalizing the evaluation. Consider whether the question itself is framed correctly — sometimes the right answer is to redefine the decision space, not to choose within it.

### AP9: Scope Inflation

**Description.** A chapter that should address one architectural concern gradually absorbs adjacent concerns until it is trying to define too much. The chapter becomes a monolith.

**Symptom.** The chapter is longer than 3000 words (excluding front matter and terminology). The Dependency Map shows the chapter is depended on by more than five other chapters. The chapter's scope cannot be stated in one sentence.

**Remedy.** Split the chapter. Each chapter should make one decision or define one concept. If a chapter must make two decisions, it should be two chapters — even if they are closely related.

### AP10: Cargo-Cult Structure

**Description.** Architectural patterns are adopted because they are associated with "good architecture" in general, not because they serve a specific purpose in this system. Layers, services, repositories, factories, and other patterns are introduced by reflex rather than by reasoning.

**Symptom.** The chapter justifies a structural choice with "this is a standard pattern" or "this follows clean architecture" without explaining what *specific problem in Decode's domain* the pattern solves.

**Remedy.** For every structural choice, complete the sentence: "This structure exists because, without it, [specific concrete problem] would occur." If the sentence cannot be completed with a Decode-specific problem, the structure is cargo cult.

---

## Non-Goals

- This chapter does not define Decode's architecture. It defines how Decode's architecture is *documented*.
- This chapter does not prescribe any specific architectural pattern, style, or structure for the system itself.
- This chapter does not govern implementation-level documentation (code comments, API docs, README files).
- This chapter does not define a development process (sprints, releases, deployment). It governs only architectural documentation.

---

## Dependency Map

```
DAS-000 (this chapter)
  └── Depended on by: ALL other DAS chapters
```

---

## Revision History

```
0.1 — 2026-06-25 — Principal Architect — Initial draft
```
