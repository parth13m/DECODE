# DAS-004: Entity Model

```
Chapter:       DAS-004
Title:         Entity Model
Status:        Draft
Version:       3.0
Author:        Principal Architect
Reviewers:     —
Created:       2026-06-25
Last Revised:  2026-06-25
Depends On:    DAS-000, DAS-001, DAS-002, DAS-003
Depended By:   DAS-005, DAS-006, DAS-007, DAS-008
Supersedes:    DAS-004 v2.0 (flat-domain ontology), DAS-004 v1.0 (source-structural model)
Superseded By: —
Layer:         L1
```

## Abstract

This chapter defines the entity model — the complete ontology of what "things" can exist in the DIR as subjects of atomic units. Entities are organized into seven ontology layers representing the fundamental dimensions of software reality: Logical Software, Behavioral, Operational, Delivery, Evolution, Human Knowledge, and External World. Eighteen entity types are defined across these layers. The ontology is producer-independent and designed to remain stable for a decade regardless of what producers are added.

## Motivation

DAS-002 defines the atomic unit contract: every unit has a subject that references an entity. But DAS-002 deliberately does not define what entities exist, deferring that to this chapter.

The critical question is: **what is an entity?** The answer must not be "what a parser can extract." That answer confuses a producer's current capability with the domain's actual structure. A parser can extract functions and types. But software also contains API endpoints, build targets, deployment services, configuration parameters, design decisions, execution flows, and evolutionary history. These are not speculative features — they are real elements of software that developers reason about, modify, debug, and depend on every day.

If the entity model defines only what today's parsers produce, three problems follow:

1. **The ontology must be redesigned for every new producer.** When Decode gains a git producer, a build-system producer, or a runtime profiler, the entity model must be amended. Each amendment ripples through DAS-005 (relationships), DAS-006 (passes), and DAS-007 (retrieval). This is architectural instability — the opposite of what the DAS exists to provide.

2. **Cross-layer questions are unanswerable.** "Which configuration parameter controls this function's behavior?" connects the Operational layer to the Logical Software layer. If configuration entities don't exist in the model, this connection is inexpressible. The DIR cannot represent what its ontology does not define.

3. **The DIR captures source-code reality, not software reality.** Source code is one artifact of software. Software also exists as deployed services, as build pipelines, as documented decisions, as operational infrastructure. An ontology that sees only source code is like a map that shows only roads — it is useful but fundamentally incomplete.

The entity model must define **what software is**, not **what we can parse today**. The set of producers will grow over a decade. The ontology of software will not change.

## Terminology

**Entity** — A named, identifiable element of software that can serve as the subject of atomic units in the DIR. An entity is something about which the DIR makes claims. Entities exist across all seven ontology layers. *Is:* a function, a deployment service, a build target, a design decision. *Is not:* an AST node, a line of code, a token, a predicate, an atomic unit. `INTRODUCED`

**Entity Type** — A classification that determines what kind of software element an entity represents. Each entity has exactly one type, assigned at creation and immutable. Entity types constrain which predicates are applicable and which relationships are valid. *Is:* Function, Type, File, Service, Endpoint, Decision. *Is not:* a tier (tiers classify units, not entities), a predicate (predicates classify claims, not subjects), an ontology layer (layers classify entity types, not individual entities). `INTRODUCED`

**Ontology Layer** — One of seven dimensions of software reality that organize entity types. Each layer represents a distinct aspect of what software is, does, or depends on. Ontology layers organize the entity space and define how different dimensions of software relate to each other. They are distinct from DAS layers (L0–L5), which organize the DAS itself, and from tiers (DAS-003), which classify atomic unit objectivity. *Is:* Logical Software, Behavioral, Operational, Delivery, Evolution, Human Knowledge, External World. *Is not:* a DAS chapter layer (L0–L5), a tier, or a module. `INTRODUCED`

**Producer Independence** — The property that the entity model defines what exists in the domain of software, not what any specific producer can currently discover. A producer (parser, profiler, git analyzer, CI/CD integrator) populates entities; the entity model does not depend on which producers exist. `INTRODUCED`

**Structural Containment** — The tree-structured relationship in which one Logical Software entity is declared or composed within the scope of another. Containment applies only to the Logical Software layer. Entities in other layers are connected to Logical Software entities via scope associations (relationships), not containment. `INTRODUCED`

**Qualified Name** — The sequence of names from the containment root to a Logical Software entity, forming a unique path. *Is:* `System/Module/File::Type::Function`. *Is not:* the entity's simple name, which may be ambiguous. `INTRODUCED`

**Scope Association** — A relationship connecting a non-Logical-Software entity to the Logical Software entities it is associated with. Unlike containment, scope associations are many-to-many. *Is:* a Flow associated with the Functions it spans; a Commit associated with the entities it changed. *Is not:* containment (which is one-to-one and tree-structured). `INTRODUCED`

## Domain Analysis

**DA-1: Software is a multi-layered reality.** Software simultaneously exists as logical structure (source code), dynamic behavior (execution), operational infrastructure (deployed services), delivered artifacts (binaries, containers), evolutionary history (version control), human-understood intent (decisions and documentation), and boundary interactions (APIs, dependencies). No single layer captures what software is. These layers are not arbitrary groupings — they correspond to distinct aspects of reality that have different rates of change, different producers, and different consumers.

**DA-2: The layers of software have different rates of change.** Logical structure changes with every commit. Configuration changes between deployments. Infrastructure changes quarterly. Design decisions change yearly. Version history is append-only. An ontology that models all layers must accommodate this variance — some entities are volatile, others are stable.

**DA-3: The layers are causally connected.** A structural change (renaming a function) may invalidate a behavioral entity (a flow that included that function), require an operational update (the endpoint's documentation references the old name), and produce an evolution entity (the commit recording the rename). The ontology must define entities across layers so that these cross-layer connections are expressible as relationships (DAS-005).

**DA-4: What exists in software is independent of how it's discovered.** A deployment service exists whether or not Decode has a cloud provider integration. An API endpoint exists whether or not Decode parses route definitions. A design decision exists whether or not anyone wrote an ADR. The ontology defines what exists in the domain. Producers discover instances of what the ontology defines. This separation — ontology from discovery — is what makes the entity model stable across a decade of producer evolution.

**DA-5: Entities originate through four distinct mechanisms.** Some entities are **declared** — they appear explicitly in artifacts (functions in source, targets in build files). Some are **discovered** — they exist but must be identified by analyzing relationships between declared entities (flows, architectural patterns). Some are **observed** — they are known only through instrumentation of running systems (service health, runtime characteristics). Some are **recorded** — they exist because a human documented them (design decisions, architecture rationale). All four origins produce equally real entities.

**DA-6: The granularity threshold for entity-hood is comprehension value, not syntactic existence.** Parameters, enum cases, local variables, and individual statements exist syntactically but are understood as components of their containing entity, not independently. The question "what does this parameter do?" is always answered in the context of its function. The question "what does this function do?" is answered independently. The threshold is: does understanding this element independently contribute to understanding the software?

## Candidates

The architectural question is: **what should the scope of the entity model be?**

### Candidate A: Source-Structural Ontology

The entity model defines only entities extractable from source code by parsing: functions, types, properties, files, and groupings of files. All other aspects of software are represented as predicates on structural entities or deferred.

**Strengths:** Minimal entity set. Every entity has an obvious producer.

**Weaknesses:** Cross-layer questions are inexpressible. Every new producer requires ontology redesign. The entity model becomes the system's most frequently amended chapter.

**Disqualifying condition:** Defines source-code reality, not software reality. Violates DAS-002's motivation: the DIR represents *software*, not source code.

### Candidate B: Software-Complete Ontology

The entity model defines entities across all dimensions of software reality. The model is producer-independent: it covers what software *is*, regardless of what any producer can currently extract.

**Strengths:** Producer-independent. Cross-layer queries expressible. Decade-stable. New producers populate existing types without amendment.

**Weaknesses:** Some entity types will be unpopulated until producers are built.

**Disqualifying condition:** None. Unpopulated entity types impose zero runtime cost — they are definitions, not allocations. An entity type no producer yet populates is a word not yet spoken, not a feature not yet built.

### Candidate C: Open-Extension Ontology

No fixed entity types. Any producer introduces entity types dynamically.

**Strengths:** Never needs revision.

**Weaknesses:** No shared vocabulary. Queries cannot assume entity types exist. Predicate applicability is unenforceable.

**Disqualifying condition:** DAS-002 DC-3 requires a stable contract. Dynamic entity types make the DIR a generic graph database with no guarantees.

## Evaluation

| Criterion | Source-Structural | Software-Complete | Open-Extension |
|-----------|------------------|-------------------|----------------|
| Covers software reality (DA-1) | Partial | **Yes** | Theoretically |
| Cross-layer queries (DA-3) | No | **Yes** | Depends on producers |
| Producer independence (DA-4) | No | **Yes** | Yes, but ungoverned |
| Stable contract (DAS-002 DC-3) | Yes — too narrow | **Yes** | No |
| Decade stability | No | **Yes** | Ungoverned |

Software-Complete Ontology dominates.

## Decision

**The DIR's entity model is a software-complete ontology organized into seven ontology layers.** Eighteen entity types span all dimensions of software reality. The ontology is producer-independent: it defines what exists in the domain of software, not what any current producer can discover. New producers populate existing entity types without amending the ontology.

---

## The Entity-Hood Test

An element of software qualifies as a DIR entity type if and only if all five conditions hold:

1. **Domain existence.** The element exists as a recognizable "thing" in the domain of software — developers name it, reason about it, modify it, and depend on it.
2. **Multiple independent claims.** The element can be the subject of multiple independent predicates spanning different knowledge concerns.
3. **Relationship participation.** The element participates in typed relationships (DAS-005) with other entities across the same or different layers.
4. **Independent identity.** The element can be uniquely identified and referenced from outside its declaration context.
5. **Comprehension contribution.** Understanding the element independently contributes to understanding the software. A developer would meaningfully ask "what is this?" or "how does this relate to the rest?"

Elements that fail any condition are represented as predicate values on their containing entity, not as independent entities.

---

## Ontology Layers

The eighteen entity types are organized into seven ontology layers. Each layer represents a distinct dimension of software reality. The layers are not a strict dependency hierarchy — they are interconnected dimensions, with the Logical Software layer serving as the gravitational center to which all other layers connect.

```
┌───────────────────────────────────────────────────────┐
│           Layer 6: Human Knowledge                    │
│           Decisions, intent, rationale                │
│           (references any layer)                      │
└───────────────────────┬───────────────────────────────┘
                        │
┌───────────────────────┴───────────────────────────────┐
│           Layer 5: Evolution                          │
│           Temporal history of change                  │
│           (records changes to Layers 1–4)             │
└───────────────────────┬───────────────────────────────┘
                        │
┌──────────────┬────────┴────────┬──────────────────────┐
│  Layer 3:    │   Layer 4:      │   Layer 7:           │
│  Operational │   Delivery      │   External World     │
│  (how it     │   (how it's     │   (what's outside)   │
│   runs)      │    built)       │                      │
└──────┬───────┘────────┬────────┘───────────┬──────────┘
       │                │                    │
┌──────┴────────────────┴────────────────────┴──────────┐
│           Layer 2: Behavioral                         │
│           Dynamic execution patterns                  │
│           (what it does)                              │
└───────────────────────┬───────────────────────────────┘
                        │
┌───────────────────────┴───────────────────────────────┐
│           Layer 1: Logical Software                   │
│           Static structure and organization           │
│           (what it is)                                │
└───────────────────────────────────────────────────────┘
```

---

### Layer 1: Logical Software

**Why this layer exists.** Software has an abstract logical structure — the types, functions, data members, and organizational units that constitute its architecture. This structure exists whether the software is running, built, deployed, or sitting uncompiled in a repository. It is the most fundamental dimension: every other layer ultimately references logical structure. A flow spans functions. A service deploys modules. A commit changes files. A decision governs types. Remove this layer and no other layer has anything to attach to.

**What belongs here.** Entities that constitute the static, logical architecture of software: the declarations developers write and the organizational units that contain them. These entities are language-independent (DAS-002 DC-1) — a function in Swift and a function in Python are the same entity type.

**How it relates to other layers.** Layer 1 is the gravitational center of the ontology. Every other layer connects to it:
- Behavioral entities (Flows) are composed of Logical Software entities.
- Operational entities (Services, DataStores) deploy and configure Logical Software.
- Delivery entities (BuildTargets, Artifacts) compile and package Logical Software.
- Evolution entities (Commits) record changes to Logical Software.
- Human Knowledge entities (Decisions) explain and govern Logical Software.
- External World entities (Endpoints, Dependencies) define the boundary of Logical Software.

---

**Function.** A callable unit of behavior with a defined signature — inputs, outputs, and a body. Includes named functions, methods (instance and static), constructors, destructors, and named closures. Anonymous closures that lack stable names fail the identity test and are not entities.

*Cross-language:* Swift `func`, Python `def`, Java/C# method, JavaScript `function`/named arrow, C function, Go `func`.

*Example claims:* signature, return type, visibility, complexity, line range, behavioral purpose, thread safety, error-handling strategy.

*Potential producers:* source parser, runtime profiler (latency, frequency), test runner (coverage), AI enrichment pass (purpose).

---

**Type.** A named type declaration that introduces a classification of data. Includes classes, structs, enums, protocols/interfaces, type aliases, and unions. The specific kind (class vs. struct vs. enum) is a predicate value (`hasTypeKind`), not a separate entity type — kinds compose rather than taxonomize (DAS-000 P7).

*Cross-language:* Swift `class`/`struct`/`enum`/`protocol`, Python `class`, Java `class`/`interface`/`enum`, TypeScript `class`/`interface`/`type`, C `struct`/`union`, Go `struct`/`interface`.

*Example claims:* type kind, visibility, member count, generic parameters, conformances, purpose, design pattern, thread-safety model.

*Potential producers:* source parser, AI enrichment pass (design role, pattern detection).

---

**Property.** A named data member of a type — a stored or computed value associated with an instance or the type itself. Properties hold the state that drives behavior; understanding a type requires understanding its key properties.

*Cross-language:* Swift `var`/`let`/computed property, Python instance/class attribute, Java field, TypeScript property, C struct member, Go struct field.

*Example claims:* declared type, visibility, mutability, static/instance, default value, purpose, thread-safety implications.

*Potential producers:* source parser, runtime profiler (access frequency, mutation patterns), AI enrichment pass (state role).

---

**File.** A source artifact — the atomic unit of editing, version control, and collaboration. Files are the boundary between the file system and the code. Every sub-file entity is anchored to exactly one file. Files are the unit at which change detection operates (DAS-002 I-VER-4).

*Example claims:* path, language, line count, file role (coordinator, model, view, test, configuration), architectural layer, code health.

*Potential producers:* file-system scanner, source parser, git producer (change frequency, ownership), AI enrichment pass (role, purpose).

---

**Module.** A cohesive grouping of files that together serve a related purpose. The first composition level above files. Modules carry emergent properties — interaction patterns, internal contracts, cohesion characteristics — that no constituent file possesses individually (DAS-001 P4).

Module boundaries may be determined by explicit declaration (package manifest, build target), project structure (directory hierarchy), or analytical discovery (relationship clustering). This chapter defines what a Module *is*; boundary detection is a producer concern.

*Example claims:* purpose, public interface surface, internal coupling, cohesion assessment, architectural role, interaction patterns.

*Potential producers:* project-structure analyzer, composition pass, build-system parser, AI enrichment pass.

---

**Package.** A versioned, distributable unit of software that can be consumed by other software. Packages are the unit of reuse and distribution. A Package may contain one or more Modules. The distinction from Module: a Module is an internal organizational unit; a Package is a distributable unit with a version, a public API contract, and external consumers.

*Example claims:* version, license, public API surface, dependency count, size, platform support.

*Potential producers:* package-manifest parser (SPM, npm, pip, Cargo), registry API client (vulnerability data, download stats).

---

**System.** The top-level entity representing the entire codebase or a major independently deployable subsystem. The root of the structural containment tree. One root System per analyzed codebase; monorepos may contain multiple System entities for distinct deployment targets.

*Example claims:* architecture style, technology stack, language distribution, cross-cutting patterns, overall health assessment.

*Potential producers:* composition pass, CI/CD integrator, AI enrichment pass (architectural assessment).

---

### Layer 2: Behavioral

**Why this layer exists.** Software *does* things. The logical structure tells you what exists — functions, types, their organization. It does not tell you what happens when the software executes. Execution paths cross structural boundaries: a single user action may traverse a coordinator, a resolver, a service, and a data access layer, each in a different module. These cross-entity execution patterns are real — developers name them ("the auth flow"), debug them ("the request fails somewhere in the pipeline"), and optimize them ("the hot path through the session resolver"). They cannot be represented as properties of any single structural entity because they are properties of the *interaction* between structural entities.

**What belongs here.** Entities that represent dynamic execution patterns spanning multiple Logical Software entities. Behavioral entities are derived — they do not appear in any single file but are discovered by analyzing relationships across structural entities.

**How it relates to other layers.** Layer 2 depends on Layer 1: flows are composed of functions and types. Layer 2 connects to Layer 3: flows may cross service boundaries and include endpoints. Layer 2 connects to Layer 5: commits may break or modify flows. Runtime observations (latency, throughput) from profilers and tracers are predicates on behavioral entities, not new entities.

---

**Flow.** A named execution path that spans multiple structural entities, representing a coherent user-facing or system-facing operation. A flow has participants (the entities involved), ordering (the sequence of interactions), and emergent properties (end-to-end latency, error-handling strategy, data transformations).

Flows are the behavioral counterpart to modules: where a module groups entities by structural cohesion, a flow groups entities by behavioral participation. A single function may participate in multiple flows. A flow may span multiple modules.

*Examples:* "user authentication flow" (AuthController → AuthService → CredentialValidator → TokenGenerator), "request processing pipeline" (Router → Middleware → Handler → Serializer), "session resolution" (HotkeyService → SessionQuestionCoordinator → SessionResolver → ContextBuilder).

*Example claims:* participants, ordering, end-to-end latency, error-handling strategy, data transformations, security boundaries crossed.

*Potential producers:* static analysis pass (call-graph traversal), runtime tracer (observed execution paths), AI enrichment pass (flow identification), developer annotation.

---

### Layer 3: Operational

**Why this layer exists.** Software doesn't just exist as code — it *runs*. It runs on servers, connects to databases, reads configuration, and exposes its capabilities through defined interfaces. These operational realities are part of what software IS. A function that writes to a PostgreSQL database is meaningfully different from a function that writes to Redis — and understanding that difference requires knowing about the data store. A configuration parameter that controls connection pool size is as architecturally significant as the code that uses the pool. The operational dimension is invisible to source parsers but real to every developer who deploys, monitors, or debugs the software.

**What belongs here.** Entities that represent the deployed, running, and configured aspects of software. These entities bridge the gap between "what the code says" (Logical Software) and "what happens in production."

**How it relates to other layers.** Layer 3 depends on Layer 1: services deploy modules, config entries parameterize structural entities, data stores are accessed by functions. Layer 3 connects to Layer 2: operational entities participate in flows (a flow may include a database write or a cache lookup). Layer 3 connects to Layer 4: artifacts are deployed as services. Runtime observations (CPU utilization, request rates, health status) are predicates on operational entities from runtime producers.

---

**Service.** A deployed, running instance of software that serves requests. A service has health status, resource allocations, and relationships to the Logical Software entities it instantiates. A service is the operational manifestation of a System or Module.

*Examples:* `decode-api` (FastAPI backend on Railway), `decode-worker` (background job processor), `decode-gateway` (API gateway).

*Example claims:* name, environment (production, staging), health status, resource allocation, deployment version, uptime, replica count.

*Potential producers:* cloud provider integration (AWS, GCP, Railway), container orchestrator (Kubernetes), deployment pipeline, health-check monitor.

---

**DataStore.** A persistent data backend — a database, cache, message queue, object store, or search index. Data stores hold the state that survives process restarts. Understanding data stores answers: "where does this data live?", "what schema does this table follow?", "which services write here?"

*Examples:* `decode-postgres` (PostgreSQL database), `decode-redis` (Redis cache), `user-events` (Kafka topic), `decode-assets` (S3 bucket).

*Example claims:* type (relational, document, key-value, queue), schema, retention policy, access patterns, connected services, size.

*Potential producers:* infrastructure-as-code parser, database schema introspector, cloud provider integration, ORM/migration analyzer.

---

**ConfigEntry.** A named setting that controls software behavior. Includes environment variables, configuration file entries, feature flags, command-line parameters with defaults, and secret references. A ConfigEntry has a name, a type, a default value (if any), a scope (global, per-environment), and — critically — what structural entities it affects.

*Examples:* `DATABASE_URL` (connection string), `AI_MODEL` (model selection), `MAX_POOL_SIZE` (connection pool limit), `enable_new_auth` (feature flag).

*Example claims:* name, type, default value, scope, sensitivity (secret vs. public), what it controls, valid value range.

*Potential producers:* config-file parser (.env, YAML, TOML), infrastructure-as-code parser, feature-flag service, source parser (detecting environment variable references).

---

### Layer 4: Delivery

**Why this layer exists.** Software must be assembled from source into deployable units. The build process, its targets, and its produced artifacts are not implementation details — they are architectural facts. A build target determines what is compiled together (which files, which dependencies, which flags). An artifact is what actually ships — the binary, the container, the package. Understanding delivery answers questions that no amount of source analysis can: "what does this binary contain?", "which dependency versions are pinned?", "how long does the build take?"

**What belongs here.** Entities that represent the compilation, packaging, and distribution process — the pipeline from source to deployable artifact.

**How it relates to other layers.** Layer 4 depends on Layer 1: build targets compile files and modules. Layer 4 connects to Layer 3: artifacts are deployed as services. Layer 4 connects to Layer 5: releases are associated with artifacts, commits trigger builds. Layer 4 connects to Layer 7: build targets declare external dependencies.

---

**BuildTarget.** A named unit of compilation or packaging. A build target declares its inputs (source files, resources, dependencies), its outputs (libraries, executables, test bundles), and its configuration (compiler flags, platform constraints).

*Examples:* Xcode scheme `Decode`, npm script `build`, Gradle module `app`, Cargo target `decode-cli`.

*Example claims:* target name, target type (library, executable, test), source inputs, dependencies, platform, build duration.

*Potential producers:* build-system parser (Xcode project, package.json, build.gradle, Cargo.toml), CI/CD log analyzer (build times, failure rates).

---

**Artifact.** A produced, deployable unit — the output of a build target. Artifacts are what gets deployed, distributed, or consumed. An artifact has a version, a size, a platform, and a lineage (which build target and source version produced it).

*Examples:* `Decode.app` (macOS application bundle), `decode-backend:latest` (Docker image), `decode-core-1.2.0.tgz` (npm package).

*Example claims:* name, version, size, platform, signing status, contained modules, source version, vulnerability scan results.

*Potential producers:* build-system output analyzer, container registry integration, package registry integration, signing service.

---

### Layer 5: Evolution

**Why this layer exists.** Software has a temporal dimension. How it arrived at its current state — which changes were made, by whom, and why — is essential for understanding it. The current code is a snapshot; the history reveals intent, trajectory, and the consequences of past decisions. When a developer asks "who changed this and why?" or "when was this bug introduced?", they are querying the evolution layer. Without this layer, the DIR represents software as a frozen instant, not as a living artifact with a past and a trajectory.

**What belongs here.** Entities that represent the change history and versioned milestones of software.

**How it relates to other layers.** Layer 5 references Layers 1–4: commits record changes to structural entities, configuration, build targets, and operational parameters. Layer 5 connects to Layer 6: commits may reference decisions; decisions may be revisited based on evolutionary patterns. Layer 5 connects to Layer 4: releases are associated with artifacts.

---

**Commit.** An atomic change record in the software's history. A commit has an author, a timestamp, a message (intent), and a set of entity-level changes (which entities were created, modified, or deleted). Commits connect the temporal dimension to all other layers — they are the mechanism by which entities evolve.

*Examples:* `4416bc1 session mode, file intelligence complete`, `314419e Initial commit from MVP`.

*Example claims:* hash, author, timestamp, message, changed files, changed entities, risk assessment, related issue/PR, review status.

*Potential producers:* git analyzer (commit metadata, diffs), PR/MR integration (review context, linked issues), AI enrichment pass (risk assessment, change categorization).

---

**Release.** A versioned snapshot of software marked for distribution or deployment. A release has a version number, a set of included commits since the prior release, release notes, and a deployment status. Releases are the milestones of evolution — they define "what the user gets."

*Examples:* `v1.0.0` (initial public release), `v1.2.0-beta.1` (beta for module intelligence), `2026-06-25.1` (daily deploy).

*Example claims:* version, included commits, release notes, deployment status, associated artifacts, breaking changes.

*Potential producers:* git tag/release analyzer, CI/CD pipeline integration, release management tool, changelog generator.

---

### Layer 6: Human Knowledge

**Why this layer exists.** Code tells you *what*. Human knowledge tells you *why*. The most architecturally significant facts about software are often not encoded in any artifact: why manual DI was chosen over a framework, why the explanation prompt is frozen at V7, why a particular trade-off was accepted. These decisions shape every structural choice in the codebase, but they exist in human minds, in informal documents, in chat histories, and in project conventions. Without this layer, the DIR can describe every function and type in the codebase and still fail to answer the most important question a new engineer asks: "why is it like this?"

**What belongs here.** Entities that represent human intent, rationale, and assessment that explain the *why* behind software's current state. This is the most interpretive layer — and the most valuable for deep understanding.

**How it relates to other layers.** Layer 6 can reference any other layer: a decision may govern structural choices (Layer 1), constrain operational parameters (Layer 3), or justify delivery strategy (Layer 4). Layer 6 connects to Layer 5: decisions are introduced and superseded through evolutionary changes. Layer 6 is the only layer that receives from all others — any aspect of software can be the subject of human judgment.

---

**Decision.** An architectural or design choice with stated alternatives, rationale, and consequences. Decisions explain why the software has a particular structure, why an alternative was rejected, and what trade-offs were accepted. Decisions may be formally recorded (Architecture Decision Records, RFCs, design docs) or discovered by analyzing code patterns and inferring intent.

The Decision entity subsumes ADRs: an ADR is a *File* (Layer 1) that records a *Decision* (Layer 6). The file is the artifact; the decision is the intellectual content. Both exist as entities in their respective layers, connected by a relationship (DAS-005).

*Examples:* "Manual DI over framework — framework's code generation conflicts with strict concurrency" (from CLAUDE.md), "V7 prompt frozen until real-user evidence justifies changes" (project constraint), "SwiftSyntax chosen for Swift parsing for type-system fidelity" (inferred from dependency choice).

*Example claims:* question addressed, alternatives considered, chosen alternative, rationale, consequences, affected entities, date, decision maker, status (active, superseded, under review).

*Potential producers:* ADR/RFC parser, design-doc analyzer, AI enrichment pass (inferring decisions from code patterns), developer annotation, CLAUDE.md/README parser.

---

### Layer 7: External World

**Why this layer exists.** Software does not exist in isolation. It consumes external libraries, exposes API surfaces, integrates with third-party services, and depends on packages maintained by others. The boundary between "our software" and "everything else" is architecturally critical — it defines what we control and what we depend on. Security vulnerabilities, breaking changes, license conflicts, and API deprecations all originate at this boundary. Without this layer, the DIR has no vocabulary for the things that most frequently cause production incidents: a dependency upgrade that breaks the build, an API change that breaks integration, a library vulnerability that requires emergency patching.

**What belongs here.** Entities that represent the boundary between the software and the outside world — what the software exposes and what it consumes.

**How it relates to other layers.** Layer 7 connects to Layer 1: endpoints are implemented by functions and modules; dependencies provide packages consumed by modules. Layer 7 connects to Layer 2: flows may cross endpoint boundaries (an external API call is part of a flow). Layer 7 connects to Layer 3: endpoints are served by services; dependencies may include external services. Layer 7 connects to Layer 4: dependencies are declared in build targets; artifacts may be published to external registries.

---

**Endpoint.** An API surface — a defined point of interaction between software and its consumers or between internal components. Endpoints have URLs or addresses, methods or operations, request/response schemas, authentication requirements, and rate limits. Endpoints are the contract between a service and its callers.

*Examples:* `POST /api/explain` (explanation API), `GET /admin` (admin dashboard), `gRPC DecodeService.Explain` (gRPC method), `POST /hooks/github` (webhook receiver).

*Example claims:* URL/path, HTTP method or protocol, request schema, response schema, authentication requirement, rate limit, deprecation status.

*Potential producers:* source parser (route definitions), OpenAPI/Swagger parser, API gateway configuration, runtime traffic analyzer.

---

**Dependency.** An external package, library, or service that this software consumes. A dependency has a version constraint, a license, a purpose (what capability it provides), and known vulnerabilities. Dependencies are the inward-facing counterpart to endpoints — where endpoints define what the software *exposes*, dependencies define what the software *requires*.

*Examples:* `GRDB 7.5.0` (database access), `SwiftSyntax 600.0.1` (Swift parsing), `FastAPI 0.100+` (web framework), `anthropic` (AI provider SDK).

*Example claims:* name, version constraint, resolved version, license, purpose, vulnerability status, transitive dependency count, update availability.

*Potential producers:* package-manifest parser (Package.swift, requirements.txt, package.json, Cargo.toml), vulnerability database integration, license scanner, dependency-graph analyzer.

---

## Cross-Cutting Enrichment

Three aspects of software reality enrich entities across multiple layers but do not introduce new entity types. They contribute *predicates* to existing entities rather than creating new subjects.

**Runtime.** Observations from running software — latency, throughput, error rates, resource utilization, hot-path identification. Runtime producers (APM tools, profilers, distributed tracers) add predicates to Function entities (execution frequency, average latency), Flow entities (end-to-end p99), Service entities (CPU utilization, request rate), and others. Runtime does not introduce entity types because its observations are *about* existing entities: a function's average latency is a claim about the function.

**Documentation.** Human-authored descriptions — API docs, READMEs, architecture guides, inline comments. Documentation producers add predicates to the entities they describe: a function's API documentation is a claim about the function, a module's README content is a claim about the module. Documentation does not introduce entity types because it *describes* existing entities rather than introducing new ones. This avoids the duplication problem where a Document entity and the Function it describes carry overlapping claims with divergent freshness.

**Testing.** Verification and quality assurance — pass/fail status, coverage, flakiness, assertion counts. Tests are structurally Functions and Files in Layer 1. Their semantic distinction (verification rather than implementation) is expressed through predicates (`role: test`, `tests: EntityRef`) and relationships (`tests`, `covers`), not separate entity types. Creating a TestCase entity type would violate DAS-000 P7 (composition over taxonomy): the test distinction composes with the Function type via predicates.

---

## Entity-Hood Review: Candidate Types

Four candidate elements were evaluated against the entity-hood test and rejected.

### Requirement

A requirement is a statement of what software should do or satisfy — "the system must support multiple programming languages" or "response latency must be under 200ms."

| Condition | Assessment |
|-----------|-----------|
| Domain existence | Yes — developers reference requirements |
| Multiple claims | Moderate — description, priority, status, acceptance criteria |
| Relationships | Yes — implemented-by Functions, tracked-by Issues |
| Independent identity | Yes — REQ-001, ticket numbers |
| Comprehension contribution | **Fails** — requirements describe what software *should be*, not what software *is* |

**Rejection.** The DIR represents software reality — what exists, how it behaves, how it's deployed. Requirements represent *desired* reality — what someone wants software to become. A requirement that has been implemented is encoded in the structural entities that implement it. A requirement that has not been implemented does not exist in the software. The connection between a requirement and the software is better expressed as: a Decision (Layer 6) cites a requirement as rationale for a structural choice. Requirements live in external project-management systems (Linear, Jira, Notion); they are references in provenance and decision rationale, not DIR entities.

### Feature

A feature is a named user-facing capability — "File Intelligence," "Session Mode," "Screenshot Capture."

| Condition | Assessment |
|-----------|-----------|
| Domain existence | Yes — developers talk about features |
| Multiple claims | Moderate — name, status, scope, description |
| Relationships | Yes — implemented-by Modules/Functions, introduced-in Release |
| Independent identity | Yes — feature names |
| Comprehension contribution | **Fails** — features are emergent capabilities, not independent things |

**Rejection.** A feature is not a thing in the software — it is a *description* of what the software does, observed from the user's perspective. "File Intelligence" is the emergent result of SemanticEnrichmentService, FileIdentityClassifier, FilePurposeDeriver, ContextBuilderService, and a dozen other structural entities working together. Making "File Intelligence" an entity separate from these structural entities creates a shadow representation. The feature is better expressed as an emergent predicate on the Module or System entity: `provides_capability: "File Intelligence"`. This is consistent with DAS-001 P4 (composition produces emergence) — the capability is an emergent property of the composition, not an independent entity.

### Issue

An issue is a tracked work item — a bug report, a task, a feature request — in a project-management system.

| Condition | Assessment |
|-----------|-----------|
| Domain existence | Yes — developers work on issues daily |
| Multiple claims | Yes — title, severity, status, assignee, description |
| Relationships | Yes — affects Function/Type, fixed-by Commit |
| Independent identity | Yes — ISSUE-123, linear IDs |
| Comprehension contribution | **Fails** — issues are process artifacts, not software entities |

**Rejection.** Issues are about the *process* of developing software, not about the software itself. An open bug ("race condition in SessionResolver") is a claim about a structural entity (SessionResolver has a race condition) — the structural entity is the subject, the bug is a predicate. A resolved issue is historical process data. Issues live in external tracking systems; they are references in Commit metadata and Decision rationale, not DIR entities. The DIR represents software reality; project-management workflow is outside its domain.

### ADR (Architecture Decision Record)

An ADR is a document that records an architectural decision — its context, alternatives, decision, and consequences.

| Condition | Assessment |
|-----------|-----------|
| Domain existence | Yes — ADRs are widely used |
| Multiple claims | Yes — title, status, date, content |
| Relationships | Yes — records a Decision, describes structural entities |
| Independent identity | Yes — file path, ADR number |
| Comprehension contribution | Yes — ADRs help developers understand why |

**Rejection — but not as a new entity type.** An ADR passes all five conditions, but it is not *structurally distinct* from existing entity types. An ADR is a File (Layer 1) that records a Decision (Layer 6). The file is the artifact — it has a path, a language (markdown), a line count. The decision is the intellectual content — it has alternatives, rationale, consequences. Both already exist in the ontology. What an ADR adds is a *relationship* between a File and a Decision: "this file records this decision." That relationship is expressible in DAS-005 without a new entity type. Creating a separate ADR entity type would mean every formalized record (RFC, design doc, post-mortem) needs its own type — a taxonomic proliferation that violates DAS-000 P7.

---

## Summary of Entity Types

| # | Entity Type | Ontology Layer | Origin |
|---|------------|---------------|--------|
| 1 | Function | Logical Software | Declared in source |
| 2 | Type | Logical Software | Declared in source |
| 3 | Property | Logical Software | Declared in source |
| 4 | File | Logical Software | Exists in file system |
| 5 | Module | Logical Software | Composed/declared |
| 6 | Package | Logical Software | Declared in manifest |
| 7 | System | Logical Software | Composed |
| 8 | Flow | Behavioral | Discovered by analysis |
| 9 | Service | Operational | Observed/declared |
| 10 | DataStore | Operational | Observed/declared |
| 11 | ConfigEntry | Operational | Declared in config |
| 12 | BuildTarget | Delivery | Declared in build system |
| 13 | Artifact | Delivery | Produced by build |
| 14 | Commit | Evolution | Recorded in VCS |
| 15 | Release | Evolution | Recorded in VCS |
| 16 | Decision | Human Knowledge | Recorded/inferred |
| 17 | Endpoint | External World | Declared/observed |
| 18 | Dependency | External World | Declared in manifest |

**Cross-cutting enrichment** (predicates on existing entities, not new types):
- **Runtime** — performance and resource predicates from profilers and APM tools
- **Documentation** — descriptive predicates from doc parsers
- **Testing** — verification predicates from test runners and coverage tools

---

## Structural Containment

Logical Software entities form a containment tree — a hierarchy where each entity is declared or composed within exactly one parent.

```
System
├── Package
│   └── Module
│       └── File
│           ├── Type
│           │   ├── Property
│           │   ├── Function (method)
│           │   └── Type (nested)
│           ├── Function (free function)
│           └── Property (top-level)
```

### Containment Rules

**CONT-1: Tree structure.** Every Logical Software entity except the root System has exactly one container. Containment is acyclic and connected.

**CONT-2: Granularity monotonicity.** Containment flows from coarser to finer. System → Package → Module → File → sub-file entities. Within sub-file, Type may contain nested Types, Functions, and Properties.

**CONT-3: File as extraction boundary.** Below the file, containment is deterministic — it mirrors syntactic declaration structure and is populated by source parsers. Above the file, containment is compositional — it is determined by project structure, package manifests, or composition passes.

**CONT-4: Distributed declarations.** When language features distribute a type's members across files (Swift extensions, C# partial classes), the canonical type entity is contained in its primary declaration file. Extension-contributed members are sub-file entities in their respective files, linked to the canonical type via relationships (DAS-005).

### Non-Logical-Software Entity Associations

Entities in Layers 2–7 do not participate in the containment tree. They have **scope associations** — many-to-many relationships connecting them to Logical Software entities:

- A **Flow** is associated with the Functions it spans and the Modules it crosses.
- A **Service** is associated with the System or Module it deploys.
- A **DataStore** is associated with the Services that access it.
- A **ConfigEntry** is associated with the structural entities it parameterizes.
- A **BuildTarget** is associated with the Files and Modules it compiles.
- An **Artifact** is associated with the BuildTarget that produces it.
- A **Commit** is associated with the entities it changed.
- A **Release** is associated with the Commits it includes and the Artifacts it produces.
- A **Decision** is associated with the entities it governs.
- An **Endpoint** is associated with the Function or Module that implements it.
- A **Dependency** is associated with the Package that declares it.

These scope associations are relationships (DAS-005), not containment.

---

## Entity Identity

### Identity by Layer

Different layers require different identity mechanisms because the nature of naming differs across dimensions of software reality.

| Layer | Identity Scheme | Example |
|-------|----------------|---------|
| Logical Software | Qualified name (containment path) | `Decode/Application/SessionManager.swift::SessionManager::resolveSession(for:)` |
| Behavioral | Content-addressed or producer-assigned name | `flow/session-resolution`, `flow:hash(abc123)` |
| Operational | Operational name | `decode-api-prod`, `decode-postgres-prod`, `AI_MODEL` |
| Delivery | Build-system name or artifact tag | `Decode` (scheme), `decode-backend:v1.2.0` |
| Evolution | VCS identifier | `4416bc1` (commit hash), `v1.2.0` (version tag) |
| Human Knowledge | Title or content-addressed | `decision/manual-di-over-framework` |
| External World | External identifier | `POST /api/explain`, `GRDB@7.5.0` |

### Identity Invariants

**I-IDENT-1: Uniqueness within type.** No two active entities of the same type share the same identifier. Entities of different types may have overlapping identifiers.

**I-IDENT-2: Rename creates new identity.** When an entity is renamed, the old entity is superseded and a new entity is created. Rename-tracking is an enrichment concern, not an identity concern.

**I-IDENT-3: Content-independent identity.** An entity's identity is determined by its name/path, not by its content. Content changes affect atomic units about the entity, not the entity's identity.

---

## Entity Lifecycle

**LC-1: Implicit existence.** An entity exists in the DIR if and only if at least one Active or Invalidated atomic unit references it as a subject. No entity registry exists independent of atomic units.

**LC-2: Producer-triggered creation.** Entities come into existence when a producer emits the first atomic unit about them. A parser creates Logical Software entities. A git analyzer creates Commits. A cloud integration creates Services. The entity model defines entity types; producers populate them.

**LC-3: Invalidation cascade.** When the underlying reality changes (a file is edited, a service is redeployed, a configuration is updated), the affected entity's units are candidates for re-evaluation by the responsible producer. The invalidation model is defined in DAS-010.

**LC-4: Cross-layer lifecycle independence.** Entities in different layers have independent lifecycles. A Commit persists even after the code it changed is further modified. A Decision persists even after the entities it governs are refactored. History and knowledge are append-only even when structure is mutable.

---

## Architectural Consequences

**C1: Eighteen entity types across seven layers, governed by amendment.** Adding a new entity type requires amending this chapter through DAS-000 Section 8.

**C2: The ontology is the completeness contract.** For each layer that a producer covers, the producer must emit entities for all applicable entity types. A source parser that extracts Functions but not Properties is incomplete.

**C3: New producers populate existing types.** A runtime profiler adds predicates to existing Function and Flow entities. A cloud integration populates existing Service and DataStore types. No ontology amendment required.

**C4: Cross-layer queries are expressible.** "Which ConfigEntry controls this Function?" is a relationship query between Operational and Logical Software. "Which Commit introduced this Endpoint?" connects Evolution to External World. These are expressible because entities exist in all layers.

**C5: Unpopulated entity types impose zero cost.** Entity type definitions are vocabulary, not allocations. The cost of defining Service entities when no cloud integration exists is zero.

**C6: Ontology layers organize the entity space.** The seven layers are not implementation boundaries — all entities coexist as peers in the DIR. Layers organize the ontology for human comprehension and serve as a guide for producer development: each layer represents a class of producers that can be developed independently.

**C7: Three cross-cutting concerns are predicate-only.** Runtime, Documentation, and Testing enrich existing entities with domain-specific predicates. This reflects the domain truth that these aspects are *about* existing entities, not independent entities.

**C8: The entity-hood test is the amendment criterion.** Any future candidate entity type must pass all five conditions. Candidates that represent process artifacts (Issues), desired state (Requirements), emergent capabilities (Features), or formatted records of existing types (ADRs) do not qualify.

---

## Invariants

**I1: Exhaustive Entity Typing.**
- **Statement:** Every entity in the DIR has exactly one entity type drawn from the eighteen defined types. No entity exists without a type. No entity has multiple types.
- **Rationale:** Untyped entities cannot be validated. Multi-typed entities create predicate-applicability ambiguity.
- **Verification:** Query all entity references. Confirm each has one of the eighteen types.

**I2: Structural Containment Tree.**
- **Statement:** Every Logical Software entity except the root System is contained in exactly one other Logical Software entity. Containment forms a tree.
- **Rationale:** Graph-structured containment breaks identity, invalidation, and scoped queries.
- **Verification:** For every non-root Logical Software entity, confirm exactly one containment relationship. Confirm no cycles.

**I3: Producer Independence.**
- **Statement:** No entity type definition references a specific producer, technology, or implementation mechanism.
- **Rationale:** Producer-dependent definitions create ontology instability.
- **Verification:** Each entity type definition is meaningful with the "Potential producers" section deleted.

**I4: Layer Completeness.**
- **Statement:** Every ontology layer contains at least one entity type or is explicitly designated as a cross-cutting enrichment concern.
- **Rationale:** Gaps in the ontology create inexpressible cross-layer queries.
- **Verification:** Confirm all seven layers have entity types. Confirm all three cross-cutting concerns are documented.

**I5: Entity Existence Requires Units.**
- **Statement:** An entity exists in the DIR if and only if at least one Active or Invalidated atomic unit references it as a subject.
- **Rationale:** An independent registry is a shadow store violating DAS-002 I1.
- **Verification:** No entity is queryable with zero referencing units.

**I6: Cross-Layer Relationship Expressibility.**
- **Statement:** For any two entity types in the ontology, a typed relationship between entities of those types is structurally expressible as an atomic unit with a paired-entity subject.
- **Rationale:** DA-3 establishes that software dimensions are causally connected.
- **Verification:** For sample cross-layer entity pairs, confirm a relationship can be represented.

**I7: Scope Entity Emergence.**
- **Statement:** Every composition-level Logical Software entity (Module, Package, System) must carry at least one emergent property not present in any constituent.
- **Rationale:** DAS-001 P4 requires composition to produce emergence.
- **Verification:** For every scope entity, identify at least one emergent predicate.

**I8: Candidate Rejection Stability.**
- **Statement:** Elements rejected by the entity-hood test (Requirements, Features, Issues, ADRs as separate types) remain rejected unless the entity-hood test itself is amended.
- **Rationale:** Prevents entity-type proliferation through ad-hoc exceptions. Changes to the ontology boundary require amending the test, not bypassing it.
- **Verification:** Confirm no entity type exists that would fail the current entity-hood test.

---

## Non-Goals

This chapter does not:

- **Define relationships between entities.** Relationships (calls, tests, deploys, contains, controls, depends-on) are defined in DAS-005.

- **Define specific predicates per entity type.** Predicate-to-entity-type mapping is a joint concern of this chapter, DAS-003, and the predicate registry.

- **Define producers.** Which producers populate which types is illustrative, not normative. Producer architecture is a DAS-006 concern.

- **Define a producer roadmap.** The order in which producers are built is a product decision.

- **Define entity storage.** Persistence and indexing are DAS-012 concerns.

- **Prescribe sub-entity granularity.** Parameters, enum cases, local variables, and closure captures are predicate values, not entities.

- **Define project-management entities.** Requirements, issues, sprints, epics, and other process artifacts are outside the DIR's domain. The DIR represents software reality, not development workflow.

---

## Open Questions

**Q1: Should enum cases be promoted to entities?** *(Non-blocking)*

Enum cases are borderline: they have names, types (associated values), and participate in pattern-matching relationships. Current decision: predicate values on the owning Type. Revisit if developers frequently ask about individual enum cases in isolation.

**Q2: How are entity types extended?** *(Non-blocking)*

The model fixes eighteen types. When a genuinely new category is identified (passing the entity-hood test and structurally distinct from all eighteen), the amendment cost through DAS-005, DAS-006, and DAS-007 should be assessed.

**Q3: How do entity types map to the predicate registry?** *(Blocking for DAS-003/predicate registry)*

Each entity type supports specific predicates. This mapping must be defined — in this chapter, in DAS-003, or in a dedicated predicate registry. Deferred to DAS-003 authoring.

**Q4: What is the identity scheme for behavioral entities?** *(Non-blocking)*

Flows are discovered, not declared. Their identity is inherently unstable. Should identity be content-addressed (hash of participants + ordering) or human-assigned? Requires prototyping.

**Q5: How are cross-codebase entities handled?** *(Non-blocking)*

A Dependency references an external Package. If Decode analyzes both codebases, two DIR instances exist. Entity unification across instances is deferred to DAS-007 or a future cross-repository chapter.

---

## Dependency Map

```
DAS-000 (Architecture Authoring Standard)
  └── DAS-001 (Architectural Principles)
        └── DAS-002 (DIR)
              ├── DAS-003 (Tier Model)
              └── DAS-004 (this chapter — Entity Model)
                    └── DAS-005 (Relationship Model)
```

This chapter depends on:
- DAS-000: chapter structure, P7 (composition over taxonomy)
- DAS-001: P3 (deterministic before semantic), P4 (composition produces emergence), P10 (scope scales independently), P11 (boundaries define independent variability)
- DAS-002: atomic unit contract (subject field, entity references, DC-1 language independence, DC-3 stable contract)
- DAS-003: tier model (entities carry units across tiers; predicate applicability is tier-bounded)

This chapter is depended on by:
- DAS-005: relationship model (relationships connect entity types defined here)

---

## Revision History

```
1.0 — 2026-06-25 — Principal Architect — Initial source-structural entity model.
    Six entity types across three granularity bands.
2.0 — 2026-06-25 — Principal Architect — Complete rewrite as software-complete ontology.
    Eighteen entity types across eleven flat domains.
3.0 — 2026-06-25 — Principal Architect — Final revision. Restructured into seven
    ontology layers with explicit inter-layer relationships. Entity-hood review
    of Requirement, Feature, Issue, and ADR (all rejected with analysis).
    Three cross-cutting enrichment concerns (Runtime, Documentation, Testing).
    Invariant I8 (candidate rejection stability) added. Entity count unchanged
    at eighteen. This is the canonical ontology of software reality.
```
