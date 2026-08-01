# CRL-001: Context Resolution Layer Architecture Specification

**Status**: Canonical  
**Version**: 1.0  
**Date**: 2026-08-02  
**Scope**: Cross-capability context resolution infrastructure  
**Audience**: Any engineer implementing or consuming context resolution in Decode  

---

## Table of Contents

1. [Vision](#1-vision)
2. [Problem Statement](#2-problem-statement)
3. [Design Goals](#3-design-goals)
4. [Architectural Principles](#4-architectural-principles)
5. [Core Concepts](#5-core-concepts)
6. [Context Signals](#6-context-signals)
7. [Context Request](#7-context-request)
8. [Context Contribution](#8-context-contribution)
9. [Context Provider](#9-context-provider)
10. [Cost Tiers](#10-cost-tiers)
11. [Context Resolver](#11-context-resolver)
12. [Resolution Algorithm](#12-resolution-algorithm)
13. [Signal Merging](#13-signal-merging)
14. [Confidence Model](#14-confidence-model)
15. [Budget Model](#15-budget-model)
16. [Provider Lifecycle](#16-provider-lifecycle)
17. [Example Providers](#17-example-providers)
18. [Example Consumers](#18-example-consumers)
19. [Example Resolution Flow](#19-example-resolution-flow)
20. [Sequence Diagrams](#20-sequence-diagrams)
21. [Extensibility](#21-extensibility)
22. [Performance Considerations](#22-performance-considerations)
23. [Failure Handling](#23-failure-handling)
24. [Why This Architecture Was Chosen](#24-why-this-architecture-was-chosen)
25. [Comparison Against Alternatives](#25-comparison-against-alternatives)
26. [Future Evolution](#26-future-evolution)

---

## 1. Vision

Context is a resource, not a coordinator concern.

Every Decode capability — Explain, Improve, Follow-up, Enhanced Explanation, and every future capability — needs context about the user's code. Today, each coordinator assembles its own context through bespoke, hardcoded paths. The Context Resolution Layer makes context resolution a shared infrastructure service.

The resolver is generic infrastructure. It contains no business logic about what any capability needs. It does not know what "Explanation" or "Session" or "Project Intelligence" means. Its only job is: receive a request declaring desired context signals, execute providers that produce those signals, merge results, and return a unified context object.

Consumers declare what they need. Providers declare what they produce. The resolver connects them. No component knows about the others.

---

## 2. Problem Statement

### 2.1 Context Silos

Decode's three primary coordinators assemble context through independent, non-overlapping paths:

| Context Signal | Selection Mode | Session Mode | Project Intelligence |
|---|---|---|---|
| Selected text | Direct | Direct | N/A |
| File path | Not available | Via workspace | Via index |
| Parsed entities | Not available | Via workspace | Via index |
| Surrounding code | Not available | ContextBuilderService | Via file read |
| File intelligence | Not available | SemanticEnrichmentService | KnowledgeArtifactStore |
| Visual context | VisualContextExtractor | Not available | Not available |
| Working memory | VirtualSessionManager | VirtualSessionManager | Not available |
| Code health | Not available | SnippetHealthClassifier | Not available |

Selection Mode is context-impoverished because it was built before Session Mode. The vision model was added to compensate — a 2000ms LLM call working around a missing 5ms local lookup.

Session Mode has no access to visual context (e.g., compiler errors visible on screen), even though it could benefit.

### 2.2 The Vision Tax

Enhanced Explanation calls the vision LLM on every request (~2000ms, non-trivial cost). In 70-85% of cases, the same information is available locally — from workspace entities, file reads, or AX window titles. The vision model should be a last resort, not the default path.

### 2.3 Coordinator Coupling

Each coordinator hardcodes which services it calls, in what order, and how it merges their results. Adding a new context source (e.g., git blame information, documentation search) requires modifying every coordinator that should use it.

---

## 3. Design Goals

1. **Generic resolver** — The ContextResolver contains zero business logic about what constitutes "enough context" for any capability. No mode switches, no capability-specific sufficiency rules.

2. **Consumer autonomy** — Each consumer declares what context signals it needs and what cost it's willing to pay. The resolver doesn't need to know why.

3. **Provider independence** — Each provider declares what signals it produces and when it can contribute. Providers don't know which consumers exist.

4. **Automatic optimization** — Vision is called only when cheaper providers haven't satisfied the requested signals. This happens through set arithmetic, not a "Smart Vision Gate."

5. **Incremental adoption** — Existing coordinators can migrate to the resolver one at a time. The resolver can coexist with legacy context assembly during migration.

6. **Proportional complexity** — The architecture handles Decode's current ~7 providers without requiring a DAG planner, scheduler, or query optimizer.

---

## 4. Architectural Principles

### P1: Sufficiency is Set Arithmetic

The consumer says "I want signals {A, B, C}." Providers produce signals. When {A, B, C} are all present in the partial context, stop. This is generic infrastructure — the resolver performs a set difference, not a business rule evaluation.

### P2: Cost Ordering Replaces Dependency Planning

Providers are dispatched in cost-tier order (free → cheap → expensive). Providers self-exclude via `canContribute()` when their prerequisites aren't met. This achieves the same execution ordering as a dependency graph planner, without the planner.

### P3: The Platform Does Not Know Its Consumers

The DIR doesn't know about Explain, Improve, or Follow-up. The Understanding Pipeline doesn't know what reasoning engines exist. The Context Resolution Layer doesn't know what capabilities request which signals.

### P4: Providers Self-Govern

A provider decides whether it can contribute by inspecting the current request and the already-resolved partial context. The resolver never tells a provider to run or not run. Provider self-exclusion replaces both dependency metadata (`requires`) and policy-based dispatch (`shouldDispatch`).

### P5: Confidence Replaces Priority

When multiple providers produce the same signal, the highest-confidence value wins. There is no priority ranking between providers. Confidence is a property of the result, not the provider.

---

## 5. Core Concepts

### 5.1 Terminology

| Term | Definition |
|---|---|
| **Context Signal** | A named category of contextual information (e.g., `filePath`, `containingEntity`, `visualObservations`). |
| **Signal Kind** | An enum case identifying a context signal category. The vocabulary shared by consumers and providers. |
| **Signal Value** | A typed payload associated with a signal kind. |
| **Context Request** | A consumer's declaration of desired signal kinds, budget constraints, and optional hints. |
| **Context Contribution** | A provider's output: a set of signal values, confidence, and latency measurement. |
| **Partial Context** | The accumulating state during resolution: all signal values received so far, with their confidences. |
| **Resolved Context** | The final output: all signal values, metadata about which providers contributed, and overall resolution statistics. |
| **Cost Tier** | A coarse categorization of provider expense: free (in-memory), cheap (I/O), expensive (LLM/network). |
| **Consumer** | Any Decode component that requests context (coordinators, reasoning engines, future capabilities). |
| **Provider** | Any Decode component that produces context signals (workspace, file path, vision, working memory). |

### 5.2 Component Relationships

```
┌─────────────────────────────────────────────────────────┐
│                     CONSUMERS                            │
│  SelectionModeCoordinator, SessionQuestionCoordinator,   │
│  future capabilities                                     │
└────────────────────┬────────────────────────────────────┘
                     │  ContextRequest(desiredSignals, budget)
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  ContextResolver                         │
│                                                          │
│  Generic infrastructure. No business logic.              │
│  Algorithm: filter → dispatch → merge → check → repeat   │
└──┬──────┬──────┬──────┬──────┬──────┬───────────────────┘
   │      │      │      │      │      │
   ▼      ▼      ▼      ▼      ▼      ▼
┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐
│Work ││File ││Snip ││File ││Visu ││Work │
│space││Path ││pet  ││Intl ││al   ││ing  │
│Prov.││Prov.││Loc. ││Prov.││Prov.││Mem. │
│     ││     ││Prov.││     ││     ││Prov.│
└─────┘└─────┘└─────┘└─────┘└─────┘└─────┘
  free   cheap  cheap  cheap  expns  free
```

### 5.3 Layer Placement

The Context Resolution Layer sits within the Application layer. It does not introduce a new architectural layer.

```
Presentation → Application → Domain → Infrastructure
                    │
                    ├── Coordinators (consumers of context)
                    ├── Context Resolution Layer
                    │       ContextResolver
                    │       ContextProvider protocol
                    │       ContextRequest / ResolvedContext
                    │       Provider implementations
                    └── Existing services (providers delegate to)
                            ContextBuilderService
                            WorkspaceResolver
                            SemanticEnrichmentService
                            VisualContextExtractor
                            VirtualSessionManager
                            SnippetHealthClassifier
```

---

## 6. Context Signals

### 6.1 ContextSignalKind

The shared vocabulary between consumers and providers. Both sides speak the same language without knowing about each other.

```
enum ContextSignalKind {
    case filePath
    case containingEntity
    case surroundingCode
    case fileOutline
    case fileIntelligence
    case codeHealth
    case workingMemory
    case visualObservations
    case annotations
}
```

### 6.2 Signal Descriptions

| Signal Kind | Description | Typical Source |
|---|---|---|
| `filePath` | Absolute path to the file containing the snippet | Workspace resolution, AX window title |
| `containingEntity` | The function, class, or struct that contains the snippet | Entity match via AST parse |
| `surroundingCode` | Code lines immediately before and after the snippet | File read + text search |
| `fileOutline` | Hierarchical structure outline of the file's entities | AST parse |
| `fileIntelligence` | Semantic understanding layers (identity, purpose, behavior, safety, design) | KnowledgeArtifactStore, SemanticEnrichmentService |
| `codeHealth` | Parse health classification of the snippet | Tree-sitter parse |
| `workingMemory` | Virtual Session investigation memory | VirtualSessionManager |
| `visualObservations` | Vision model observations from screenshot | VisualContextExtractor |
| `annotations` | Nearby comments, TODOs, FIXMEs, MARK sections | File read + pattern scan |

### 6.3 ContextSignalValue

A typed wrapper so the resolver merges values without parsing them.

```
enum ContextSignalValue {
    case filePath(String)
    case containingEntity(EntityContext)
    case surroundingCode(SurroundingCode)
    case fileOutline(String)
    case fileIntelligence(FileIntelligenceContext)
    case codeHealth(HealthClassification)
    case workingMemory(String)
    case visualObservations(String)
    case annotations([String])
}
```

### 6.4 Adding a New Signal

Adding a new signal kind is a vocabulary expansion, not a logic change. It requires:
1. One new case in `ContextSignalKind`
2. One new case in `ContextSignalValue`
3. One corresponding field on `ResolvedContext`
4. One provider that produces it (new or existing)
5. One consumer that requests it (new or existing)

The resolver does not change.

---

## 7. Context Request

### 7.1 Structure

```
struct ContextRequest {
    let snippet: String
    let sourcePID: pid_t
    let sourceAppName: String?
    let desiredSignals: Set<ContextSignalKind>
    let hints: ContextHints
    let budget: ContextBudget
    let requestId: UUID
}
```

### 7.2 DesiredSignals

Replaces `ContextMode`. The consumer declares which context signals would improve its output. It does not declare a "mode" — the resolver doesn't need to know what capability is asking.

The consumer knows what context will improve its output. It doesn't know or care which providers produce it.

### 7.3 ContextHints

Optional information the consumer already possesses, passed through to providers to avoid redundant work.

```
struct ContextHints {
    let knownFilePath: String?
    let knownWorkspaceId: UUID?
}
```

If the consumer already knows the file path (e.g., Session Mode has a resolved workspace), it passes it as a hint. Providers can use this to skip their own resolution logic.

### 7.4 Request Immutability

A `ContextRequest` is immutable after creation. The resolver does not modify it. Providers read it but cannot change it.

---

## 8. Context Contribution

### 8.1 Structure

What a single provider returns after execution.

```
struct ContextContribution {
    let providerIdentifier: String
    let signals: [ContextSignalKind: ContextSignalValue]
    let confidence: Double
    let latencyMs: Int
}
```

### 8.2 Semantics

- `signals` — The signal values this provider produced. May be a subset of what the provider is capable of producing (a provider may produce only the signals that are relevant to this specific request).
- `confidence` — A value from 0.0 to 1.0 representing the reliability of this contribution. See §14 Confidence Model.
- `latencyMs` — Wall-clock time the provider took to execute. For diagnostics and optimization.
- `providerIdentifier` — String identifier for diagnostics. Must be unique across all registered providers.

### 8.3 Empty Contributions

A provider may return a contribution with an empty `signals` dictionary. This indicates that the provider executed but found nothing to contribute (e.g., WorkspaceProvider ran but no workspace matched the snippet). This is a valid, non-error outcome. The resolver records it in the resolution metadata for diagnostics.

---

## 9. Context Provider

### 9.1 Protocol

```
protocol ContextProvider: Sendable {
    var identifier: String { get }
    var produces: Set<ContextSignalKind> { get }
    var cost: CostTier { get }

    func canContribute(
        request: ContextRequest,
        resolved: PartialContext
    ) -> Bool

    func resolve(
        request: ContextRequest,
        resolved: PartialContext
    ) async -> ContextContribution
}
```

### 9.2 `identifier`

A unique string identifying this provider. Used for diagnostics, metadata, and deduplication. Convention: lowercase with hyphens (e.g., `"workspace-provider"`, `"visual-provider"`).

### 9.3 `produces`

The set of signal kinds this provider is capable of producing. This is a static declaration — the provider may not produce all of these signals on every invocation, but it will never produce signals outside this set.

Used by the resolver to filter providers: a provider is only eligible for dispatch if `produces` intersects with the remaining desired signals.

### 9.4 `cost`

The cost tier of this provider. See §10 Cost Tiers. Determines dispatch order.

### 9.5 `canContribute`

A synchronous, fast check (no I/O) that returns whether this provider can meaningfully contribute right now, given the current request and what has already been resolved.

This is the self-governance mechanism. Providers self-exclude based on:
- Whether their prerequisites are met (e.g., SnippetLocationProvider requires `filePath` in resolved context)
- Whether their output is already present (e.g., FilePathProvider skips if `filePath` already resolved)
- Whether the request is compatible (e.g., VisualProvider checks that `visualObservations` is in `desiredSignals`)

### 9.6 `resolve`

The async execution method. Called only after `canContribute()` returned `true`. Must return a `ContextContribution` — never throws. Failures are expressed as empty signal dictionaries with confidence 0.0.

The `resolved: PartialContext` parameter is a snapshot of the accumulated context at dispatch time. Providers may read values from it (e.g., SnippetLocationProvider reads the resolved `filePath`).

### 9.7 What Is NOT in the Protocol

- **No `requires`.** Providers don't declare dependencies on other providers' outputs. Instead, they inspect `resolved: PartialContext` in `canContribute()` and return `false` if what they need isn't there yet. This is simpler, more honest, and doesn't require a separate dependency resolution phase.

- **No `estimatedLatencyMs`.** Latency estimation is unreliable (network conditions, cache state, file size). `CostTier` is a coarse but honest proxy.

- **No `priority`.** Confidence replaces priority. When multiple providers produce the same signal, the highest-confidence value wins (§13).

---

## 10. Cost Tiers

### 10.1 Definition

```
enum CostTier: Int, Comparable {
    case free = 0
    case cheap = 1
    case expensive = 2
}
```

### 10.2 Semantics

| Tier | Typical Latency | Examples | Description |
|---|---|---|---|
| `free` | <1ms | In-memory lookups, derived values | No I/O, no computation beyond what's already cached in memory |
| `cheap` | <50ms | File reads, AX queries, AST parsing | Local I/O or computation, no network calls |
| `expensive` | >500ms | LLM API calls, network requests | Involves external services with unpredictable latency and monetary cost |

### 10.3 Ordering

The resolver dispatches providers in ascending cost order: all `free` providers first, then `cheap`, then `expensive`. This ensures that low-cost providers have the opportunity to satisfy signals before high-cost providers are invoked.

### 10.4 Cost vs Latency

`CostTier` correlates with latency but is not a latency prediction. A `cheap` file read might take 100ms for a large file. An `expensive` LLM call with a warm cache might respond in 200ms. The resolver does not attempt to predict or guarantee latency — it uses cost as a proxy for "try the cheap thing first."

---

## 11. Context Resolver

### 11.1 Structure

```
struct ContextResolver: Sendable {
    private let providers: [ContextProvider]

    init(providers: [ContextProvider])
    func resolve(_ request: ContextRequest) async -> ResolvedContext
}
```

### 11.2 Responsibilities

The resolver has exactly four responsibilities:
1. **Filter** — Which providers produce remaining signals, are within budget, and say they can contribute?
2. **Dispatch** — Run eligible providers in parallel within their cost tier.
3. **Merge** — Incorporate contributions into the partial context.
4. **Check** — Are all desired signals satisfied? If yes, stop. If no, proceed to the next tier.

### 11.3 What the Resolver Does NOT Do

- Does not know what any capability needs
- Does not contain sufficiency heuristics or mode-specific rules
- Does not know what any provider does internally
- Does not tell providers when to run or not run (providers self-govern)
- Does not plan execution order beyond cost-tier grouping
- Does not retry failed providers

---

## 12. Resolution Algorithm

### 12.1 Pseudocode

```
func resolve(_ request: ContextRequest) async -> ResolvedContext {

    var partial = PartialContext()
    var contributions: [ContextContribution] = []
    var remaining = request.desiredSignals

    let tiers: [CostTier] = [.free, .cheap, .expensive]

    for tier in tiers {

        // Budget check: skip this tier if it exceeds the cost budget.
        guard tier <= request.budget.maxCost else { break }

        // Find providers in this tier that produce at least one remaining signal
        // and that say they can contribute.
        let candidates = providers.filter { provider in
            provider.cost == tier
            && !provider.produces.isDisjoint(with: remaining)
            && provider.canContribute(request: request, resolved: partial)
        }

        guard !candidates.isEmpty else { continue }

        // Dispatch all candidates in this tier in parallel.
        let results = await dispatchParallel(candidates, request: request, partial: partial)

        // Merge results into partial context.
        for result in results {
            contributions.append(result)
            partial.merge(result)
        }

        // Update remaining signals.
        remaining = request.desiredSignals.subtracting(partial.satisfiedSignals)

        // Early termination: all desired signals satisfied.
        if remaining.isEmpty { break }
    }

    return ResolvedContext(partial: partial, contributions: contributions)
}
```

### 12.2 Parallel Dispatch Within Tiers

All eligible providers within a single cost tier are dispatched concurrently using a `TaskGroup`. This maximizes parallelism among providers of similar cost.

```
func dispatchParallel(
    _ candidates: [ContextProvider],
    request: ContextRequest,
    partial: PartialContext
) async -> [ContextContribution] {
    await withTaskGroup(of: ContextContribution.self) { group in
        for provider in candidates {
            group.addTask {
                await provider.resolve(request: request, resolved: partial)
            }
        }
        var collected: [ContextContribution] = []
        for await result in group {
            collected.append(result)
        }
        return collected
    }
}
```

### 12.3 Sequential Between Tiers

Tiers execute sequentially. The `free` tier must complete before the `cheap` tier begins. This is essential: cheap providers (e.g., SnippetLocationProvider) may depend on values produced by free providers (e.g., WorkspaceProvider's `filePath`). Sequential tier execution makes these dependencies work without requiring explicit `requires` declarations.

### 12.4 Why Not a Planner?

A dependency-graph planner would automatically resolve provider ordering. But Decode has ~7 providers with a simple dependency structure: most are independent, one depends on `filePath`. Cost-tier ordering + `canContribute()` self-exclusion achieves the same result with zero infrastructure. If Decode ever reaches 30+ providers with complex interdependencies, a planner can be introduced as a resolver implementation detail without changing the external interface.

---

## 13. Signal Merging

### 13.1 Rule: Highest Confidence Wins

When multiple providers produce the same signal kind, the value with the highest confidence is kept. First arrival breaks ties.

```
func merge(_ contribution: ContextContribution) {
    for (signal, value) in contribution.signals {
        let existingConfidence = confidenceBySignal[signal] ?? 0
        if contribution.confidence > existingConfidence {
            signals[signal] = value
            confidenceBySignal[signal] = contribution.confidence
        }
    }
    satisfiedSignals.formUnion(contribution.signals.keys)
}
```

### 13.2 Satisfaction vs Replacement

A signal is "satisfied" as soon as any provider produces it, regardless of confidence. Satisfaction is tracked for the purpose of early termination — all desired signals are present. Replacement (overwriting a low-confidence value with a high-confidence one) happens independently of satisfaction.

### 13.3 Example

1. FilePathProvider produces `.filePath("/foo/bar.swift")` at confidence 0.9
2. WorkspaceProvider produces `.filePath("/foo/bar.swift")` at confidence 1.0

Both are in the `free` tier and run in parallel. Regardless of arrival order, the confidence-1.0 value from WorkspaceProvider wins. The signal is satisfied after the first arrival.

---

## 14. Confidence Model

### 14.1 Scale

| Score | Meaning | Example |
|---|---|---|
| 1.0 | Deterministic, verified | File path from workspace with entity match |
| 0.9 | Deterministic, high certainty | File path parsed from AX window title, snippet found in file |
| 0.7 | Deterministic, partial | File path parsed but snippet not found in file |
| 0.5 | Heuristic | Window title parsed but ambiguous (multiple matches) |
| 0.3 | Best-effort | Vision model output (may hallucinate) |
| 0.0 | Failed / empty | Provider could not produce anything |

### 14.2 Confidence Is Per-Contribution, Not Per-Signal

A `ContextContribution` has a single `confidence` value that applies to all signals in that contribution. This is a simplification — in theory, a provider could have different confidence levels for different signals. In practice, a provider's signals are derived from the same underlying data source and share the same reliability characteristics.

If a future provider needs per-signal confidence, the `ContextContribution` struct can be extended with an optional `signalConfidences: [ContextSignalKind: Double]` field without changing the merge algorithm (fall back to the contribution-level confidence when per-signal confidence is absent).

### 14.3 Confidence and the Vision Gate

The "Smart Vision Gate" — deciding whether to skip the vision model — emerges naturally from confidence-based merging. If WorkspaceProvider produces `.filePath` at confidence 1.0, and VisualProvider would produce `.filePath` at confidence 0.3, the workspace value always wins. The vision call still runs (if `.visualObservations` was requested and is in the remaining set), but its contribution to `.filePath` is superseded.

The real savings come from early termination: if all desired signals are satisfied after the `free` tier, the `expensive` tier (where VisualProvider lives) is never reached.

---

## 15. Budget Model

### 15.1 Structure

```
struct ContextBudget {
    let maxLatencyMs: Int
    let maxCost: CostTier
}
```

### 15.2 maxCost

The maximum cost tier the resolver is allowed to dispatch. Providers in higher tiers are skipped entirely.

| maxCost | Effect |
|---|---|
| `.free` | Only in-memory providers run. Zero I/O. Sub-millisecond resolution. |
| `.cheap` | In-memory + local I/O providers. No LLM/network calls. Typically <50ms. |
| `.expensive` | All providers eligible. Full resolution including vision LLM. |

### 15.3 maxLatencyMs

An advisory budget. The resolver does not enforce a hard timeout at this level — individual providers are responsible for their own timeouts (e.g., `VisualContextExtractor` already has a `visionTimeoutSeconds` limit).

`maxLatencyMs` is recorded in `ResolutionMetadata` for diagnostics: if actual resolution latency exceeds the budget, this is visible in the metadata and can inform future budget adjustments.

### 15.4 Budget and the Vision Skip

A consumer that wants fast local-only context sets `maxCost: .cheap`. The resolver never reaches the `.expensive` tier, so `VisualProvider` never runs. No gate logic, no special cases — the budget naturally excludes expensive providers.

A consumer that wants full context sets `maxCost: .expensive`. The resolver runs all tiers. If the `free` and `cheap` tiers already satisfied all desired signals, the `expensive` tier still runs but only for providers whose `produces` intersects with the remaining (empty) set — which means no expensive providers are dispatched. Early termination achieves the skip.

---

## 16. Provider Lifecycle

### 16.1 Registration

Providers are registered with the `ContextResolver` at initialization. The resolver stores them as an array. Registration order does not affect dispatch order (cost tiers determine order).

```
let resolver = ContextResolver(providers: [
    workspaceProvider,
    filePathProvider,
    snippetLocationProvider,
    fileIntelligenceProvider,
    codeHealthProvider,
    workingMemoryProvider,
    visualProvider
])
```

Registration happens in `AppDependencies.performDeferredStartup()`, following the same pattern as reasoning engine and context strategy registration.

### 16.2 Provider Initialization

Providers capture references to the services they delegate to (WorkspaceResolver, VisualContextExtractor, etc.) at construction time. They do not own or manage the lifecycle of these services.

### 16.3 Provider Statefulness

Providers should be stateless or effectively stateless. They receive everything they need via `request` and `resolved` parameters. Providers should not accumulate state across invocations.

### 16.4 Thread Safety

All providers must conform to `Sendable`. The resolver dispatches providers concurrently within a cost tier. Providers must not mutate shared state.

---

## 17. Example Providers

### 17.1 WorkspaceProvider

| Property | Value |
|---|---|
| Identifier | `"workspace-provider"` |
| Produces | `{filePath, containingEntity, surroundingCode, fileOutline, fileIntelligence, annotations}` |
| Cost | `.free` |

**Behavior:** Wraps `WorkspaceResolver`. If workspaces are available and the snippet matches an entity, this single provider can satisfy nearly the entire request at confidence 1.0.

**canContribute:** Returns `true` if workspaces are available (the workspace provider closure returns non-nil). Returns `false` if no workspaces exist.

**Key insight:** This is the "Session Mode path" made available to all consumers. Selection Mode gains Session Mode's rich context for free when a workspace is open.

### 17.2 FilePathProvider

| Property | Value |
|---|---|
| Identifier | `"file-path-provider"` |
| Produces | `{filePath}` |
| Cost | `.cheap` |

**Behavior:** Extracts file path from the AX window title of the source application. Parses editor-specific title formats:
- VS Code / Cursor: `FileName.swift — FolderName`
- Xcode: `FileName.swift — ProjectName`
- Sublime Text: `FileName.swift • FolderName`

Returns confidence 0.9 if unambiguous, 0.5 if ambiguous.

**canContribute:** Returns `true` if `filePath` is not yet satisfied and `sourcePID` is available. Returns `false` if `filePath` is already resolved (a free-tier provider already produced it).

### 17.3 SnippetLocationProvider

| Property | Value |
|---|---|
| Identifier | `"snippet-location-provider"` |
| Produces | `{containingEntity, surroundingCode, fileOutline, annotations}` |
| Cost | `.cheap` |

**Behavior:** Given a file path and snippet text, reads the file, parses with SwiftSyntax/TreeSitter, and runs snippet location logic (reusing `ContextBuilderService.locateSnippet()` and `buildLocalContext()`). Extracts nearby comments, TODOs, MARK sections as annotations.

**canContribute:** Returns `true` if `filePath` is resolved AND `containingEntity` is not yet satisfied. Returns `false` if the entity is already known (WorkspaceProvider produced it) or if no file path is available.

### 17.4 FileIntelligenceProvider

| Property | Value |
|---|---|
| Identifier | `"file-intelligence-provider"` |
| Produces | `{fileIntelligence}` |
| Cost | `.cheap` |

**Behavior:** Checks `KnowledgeArtifactStore` for cached semantic enrichment. Returns the cached result if available.

**canContribute:** Returns `true` if `filePath` is resolved and `fileIntelligence` is not yet satisfied. Does not trigger LLM-based enrichment (that would be `.expensive`).

### 17.5 CodeHealthProvider

| Property | Value |
|---|---|
| Identifier | `"code-health-provider"` |
| Produces | `{codeHealth}` |
| Cost | `.cheap` |

**Behavior:** Wraps `SnippetHealthClassifier`. Parses the snippet with tree-sitter and classifies edge vs interior errors.

**canContribute:** Returns `true` if `filePath` is resolved (for grammar detection from filename) and `codeHealth` is not yet satisfied.

### 17.6 WorkingMemoryProvider

| Property | Value |
|---|---|
| Identifier | `"working-memory-provider"` |
| Produces | `{workingMemory}` |
| Cost | `.free` |

**Behavior:** Wraps `VirtualSessionManager.workingMemoryBlock()`. Always instant. Returns confidence 1.0 if enabled and non-empty.

**canContribute:** Returns `true` if Virtual Session is enabled and working memory is non-empty.

### 17.7 VisualProvider

| Property | Value |
|---|---|
| Identifier | `"visual-provider"` |
| Produces | `{visualObservations}` |
| Cost | `.expensive` |

**Behavior:** Captures screenshot via ScreenCaptureKit (using `WindowSelector`), sends to vision LLM via `VisualContextExtractor`. Returns the validated vision output as a string.

**canContribute:** Returns `true` if `visualObservations` is in `desiredSignals`, is not yet satisfied, and `sourcePID` is available.

---

## 18. Example Consumers

### 18.1 Selection Mode (Enhanced Explanation)

```
let request = ContextRequest(
    snippet: text,
    sourcePID: pid,
    sourceAppName: sourceAppName,
    desiredSignals: [.filePath, .containingEntity, .surroundingCode,
                     .workingMemory, .visualObservations],
    hints: ContextHints(),
    budget: ContextBudget(
        maxLatencyMs: enhancedEnabled ? 3000 : 200,
        maxCost: enhancedEnabled ? .expensive : .cheap
    ),
    requestId: UUID()
)
let resolved = await contextResolver.resolve(request)
```

When `enhancedEnabled` is false: `maxCost` is `.cheap`, so VisualProvider is never reached. Selection Mode gets local-only context.

When `enhancedEnabled` is true: `maxCost` is `.expensive`. If free/cheap providers already satisfied all signals, VisualProvider still runs (`.visualObservations` is only in the remaining set, and only VisualProvider produces it). But `.filePath` and `.containingEntity` come from cheaper providers at higher confidence.

### 18.2 Session Mode

```
let request = ContextRequest(
    snippet: snippetText,
    sourcePID: pid,
    sourceAppName: sourceAppName,
    desiredSignals: [.filePath, .containingEntity, .fileOutline,
                     .fileIntelligence, .codeHealth, .workingMemory],
    hints: ContextHints(knownWorkspaceId: workspace.id),
    budget: ContextBudget(maxLatencyMs: 500, maxCost: .cheap),
    requestId: UUID()
)
let resolved = await contextResolver.resolve(request)
```

Session Mode knows which workspace to use (passes it as a hint) and doesn't want vision (`.cheap` budget). The resolver produces the same context that `SessionQuestionCoordinator` currently assembles manually.

### 18.3 Future: Code Review Capability

```
let request = ContextRequest(
    snippet: diffHunk,
    sourcePID: pid,
    sourceAppName: "GitHub Desktop",
    desiredSignals: [.filePath, .fileIntelligence, .containingEntity],
    hints: ContextHints(knownFilePath: diffFilePath),
    budget: ContextBudget(maxLatencyMs: 200, maxCost: .free),
    requestId: UUID()
)
let resolved = await contextResolver.resolve(request)
```

A code review capability only needs lightweight context — file intelligence and entity context. With `maxCost: .free` and a known file path hint, resolution is sub-millisecond.

### 18.4 Future: Proactive Suggestions

```
let request = ContextRequest(
    snippet: currentEditorContent,
    sourcePID: pid,
    sourceAppName: "Xcode",
    desiredSignals: [.filePath, .fileOutline, .containingEntity],
    hints: ContextHints(),
    budget: ContextBudget(maxLatencyMs: 100, maxCost: .cheap),
    requestId: UUID()
)
let resolved = await contextResolver.resolve(request)
```

Proactive suggestions need to be fast. A `.cheap` budget with minimal desired signals gives a snappy response.

---

## 19. Example Resolution Flow

### 19.1 Selection Mode — File in Workspace

```
Request:
  snippet = "guard let provider = aiProvider()..."
  sourcePID = 1234
  desiredSignals = {filePath, containingEntity, surroundingCode, workingMemory, visualObservations}
  budget = {maxLatencyMs: 3000, maxCost: .expensive}

Tier .free (parallel, ~2ms):
  WorkspaceProvider:
    canContribute? → true (workspaces exist)
    resolve → filePath ✓, containingEntity ✓, surroundingCode ✓, fileOutline (bonus)
    confidence: 1.0
  WorkingMemoryProvider:
    canContribute? → true (VS enabled, non-empty)
    resolve → workingMemory ✓
    confidence: 1.0

Merge → satisfiedSignals = {filePath, containingEntity, surroundingCode, fileOutline, workingMemory}
Remaining = {visualObservations}

Tier .cheap:
  FilePathProvider:
    produces ∩ remaining = ∅ → FILTERED OUT
  SnippetLocationProvider:
    canContribute? → false (containingEntity already satisfied) → FILTERED OUT
  (no candidates)

Tier .expensive:
  VisualProvider:
    produces ∩ remaining = {visualObservations} → eligible
    canContribute? → true (visualObservations requested, not satisfied)
    resolve → visualObservations ✓
    confidence: 0.3

Merge → satisfiedSignals = {filePath, containingEntity, surroundingCode, fileOutline, workingMemory, visualObservations}
Remaining = ∅ → DONE

Result:
  filePath: "/path/to/SelectionModeCoordinator.swift" (confidence 1.0, from workspace-provider)
  containingEntity: handleExplainSelection(event:generation:) (confidence 1.0, from workspace-provider)
  surroundingCode: ±30 lines (confidence 1.0, from workspace-provider)
  workingMemory: "Investigating auth flow..." (confidence 1.0, from working-memory-provider)
  visualObservations: "File tab shows SelectionModeCoordinator.swift" (confidence 0.3, from visual-provider)
  metadata:
    totalLatencyMs: 2100
    providersUsed: [workspace-provider, working-memory-provider, visual-provider]
    providersSkipped: [file-path-provider, snippet-location-provider]
    visionWasNeeded: true (but only for visual observations — file path came locally)
```

### 19.2 Selection Mode — No Workspace (Safari)

```
Request:
  snippet = "some code"
  sourcePID = 5678 (Safari)
  desiredSignals = {filePath, containingEntity, workingMemory, visualObservations}
  budget = {maxLatencyMs: 3000, maxCost: .expensive}

Tier .free:
  WorkspaceProvider:
    canContribute? → false (no workspaces) → FILTERED OUT
  WorkingMemoryProvider:
    canContribute? → true
    resolve → workingMemory ✓

Remaining = {filePath, containingEntity, visualObservations}

Tier .cheap:
  FilePathProvider:
    canContribute? → true (filePath not satisfied, PID available)
    resolve → can't parse Safari title → empty contribution, confidence 0.0
  SnippetLocationProvider:
    canContribute? → false (no filePath) → FILTERED OUT

Remaining = {filePath, containingEntity, visualObservations}

Tier .expensive:
  VisualProvider:
    canContribute? → true
    resolve → visualObservations ✓ (confidence 0.3)

Remaining = {filePath, containingEntity} — unsatisfied

Result:
  workingMemory: "..." (confidence 1.0)
  visualObservations: "Code appears to be JavaScript..." (confidence 0.3)
  filePath: nil
  containingEntity: nil
  metadata:
    totalLatencyMs: 2200
    unsatisfiedSignals: {filePath, containingEntity}
```

The consumer receives whatever was available. It formats its prompt with the partial context. This is graceful degradation — identical to the current behavior when vision returns useful observations but file context is unavailable.

---

## 20. Sequence Diagrams

### 20.1 Happy Path — Full Resolution

```
Consumer          ContextResolver       WorkspaceProvider   WorkingMemoryProvider   VisualProvider
   │                    │                      │                    │                    │
   │ ContextRequest     │                      │                    │                    │
   │ ──────────────────>│                      │                    │                    │
   │                    │                      │                    │                    │
   │                    │ ── Tier .free ─────── │                    │                    │
   │                    │  canContribute?       │                    │                    │
   │                    │ ────────────────────> │                    │                    │
   │                    │ <──── true ────────── │                    │                    │
   │                    │  canContribute?       │                    │                    │
   │                    │ ───────────────────────────────────────── >│                    │
   │                    │ <──── true ───────────────────────────── ──│                    │
   │                    │                      │                    │                    │
   │                    │ ── dispatch parallel ─│                    │                    │
   │                    │  resolve()            │                    │                    │
   │                    │ ────────────────────> │                    │                    │
   │                    │  resolve()            │                    │                    │
   │                    │ ───────────────────────────────────────── >│                    │
   │                    │ <── contribution ──── │                    │                    │
   │                    │ <── contribution ──────────────────────── ─│                    │
   │                    │                      │                    │                    │
   │                    │ ── merge ───────────  │                    │                    │
   │                    │ ── check remaining ── │                    │                    │
   │                    │ (visualObservations   │                    │                    │
   │                    │  still remaining)     │                    │                    │
   │                    │                      │                    │                    │
   │                    │ ── Tier .cheap ────── │                    │                    │
   │                    │ (no eligible providers)                    │                    │
   │                    │                      │                    │                    │
   │                    │ ── Tier .expensive ── │                    │                    │
   │                    │  canContribute?       │                    │                    │
   │                    │ ──────────────────────────────────────────────────────────────> │
   │                    │ <──── true ────────────────────────────────────────────────── ──│
   │                    │  resolve()            │                    │                    │
   │                    │ ──────────────────────────────────────────────────────────────> │
   │                    │ <── contribution ──────────────────────────────────────────── ──│
   │                    │                      │                    │                    │
   │                    │ ── merge ───────────  │                    │                    │
   │                    │ ── remaining = ∅ ───  │                    │                    │
   │                    │                      │                    │                    │
   │ <─ ResolvedContext │                      │                    │                    │
   │                    │                      │                    │                    │
```

### 20.2 Early Termination — All Signals Satisfied in Free Tier

```
Consumer          ContextResolver       WorkspaceProvider   WorkingMemoryProvider
   │                    │                      │                    │
   │ ContextRequest     │                      │                    │
   │ (desired: filePath,│                      │                    │
   │  containingEntity, │                      │                    │
   │  workingMemory)    │                      │                    │
   │ ──────────────────>│                      │                    │
   │                    │                      │                    │
   │                    │ ── Tier .free ─────── │                    │
   │                    │  dispatch parallel    │                    │
   │                    │ ────────────────────> │                    │
   │                    │ ───────────────────────────────────────── >│
   │                    │ <── {filePath,        │                    │
   │                    │      containingEntity}│                    │
   │                    │ <── {workingMemory} ───────────────────── ─│
   │                    │                      │                    │
   │                    │ ── remaining = ∅ ──── │                    │
   │                    │ ── EARLY TERMINATION  │                    │
   │                    │                      │                    │
   │ <─ ResolvedContext │    (cheap + expensive │                    │
   │    (~2ms total)    │     tiers never run)  │                    │
   │                    │                      │                    │
```

### 20.3 Budget Constraint — maxCost Prevents Expensive Tier

```
Consumer          ContextResolver       WorkspaceProvider   VisualProvider
   │                    │                      │                  │
   │ ContextRequest     │                      │                  │
   │ (budget.maxCost    │                      │                  │
   │  = .cheap)         │                      │                  │
   │ ──────────────────>│                      │                  │
   │                    │                      │                  │
   │                    │ ── Tier .free ─────── │                  │
   │                    │ ── Tier .cheap ────── │                  │
   │                    │                      │                  │
   │                    │ ── Tier .expensive ── │                  │
   │                    │ ── SKIPPED (budget) ──│                  │
   │                    │                      │  (never called)  │
   │                    │                      │                  │
   │ <─ ResolvedContext │                      │                  │
   │  (may have         │                      │                  │
   │   unsatisfied      │                      │                  │
   │   signals)         │                      │                  │
   │                    │                      │                  │
```

---

## 21. Extensibility

### 21.1 Adding a New Provider

1. Implement `ContextProvider` protocol
2. Declare `produces`, `cost`, `canContribute()`, `resolve()`
3. Register in `ContextResolver` initialization

Zero changes to the resolver. Zero changes to existing providers. Zero changes to existing consumers (unless they want to request the new signal).

### 21.2 Adding a New Signal Kind

1. Add case to `ContextSignalKind`
2. Add case to `ContextSignalValue`
3. Add corresponding field to `ResolvedContext`
4. Create or update a provider that produces it
5. Update consumers that want it (add to `desiredSignals`)

Zero changes to the resolver algorithm.

### 21.3 Adding a New Consumer

1. Construct a `ContextRequest` with the desired signals and budget
2. Call `contextResolver.resolve(request)`
3. Use the `ResolvedContext`

Zero changes to the resolver. Zero changes to providers.

### 21.4 Example: Future Git Provider

```
struct GitBlameProvider: ContextProvider {
    var identifier: String { "git-blame-provider" }
    var produces: Set<ContextSignalKind> { [.annotations] }
    var cost: CostTier { .cheap }

    func canContribute(request: ContextRequest, resolved: PartialContext) -> Bool {
        resolved.filePath != nil && resolved.annotations == nil
    }

    func resolve(request: ContextRequest, resolved: PartialContext) async -> ContextContribution {
        guard let filePath = resolved.filePath else {
            return ContextContribution(providerIdentifier: identifier, signals: [:], confidence: 0.0, latencyMs: 0)
        }
        // Run git blame on the snippet's line range...
        let blameAnnotations = await runGitBlame(filePath: filePath)
        return ContextContribution(
            providerIdentifier: identifier,
            signals: [.annotations: .annotations(blameAnnotations)],
            confidence: 0.8,
            latencyMs: measured
        )
    }
}
```

Register it. Done. All consumers that request `.annotations` automatically receive git blame data. No coordinator changes.

---

## 22. Performance Considerations

### 22.1 Resolution Latency by Scenario

| Scenario | Expected Latency | Why |
|---|---|---|
| All signals satisfied by free tier | <5ms | In-memory lookups only |
| File path needed from AX + snippet parse | <50ms | AX query + file read + AST parse |
| Vision needed | ~2000-3000ms | LLM API call (dominant cost) |
| No workspace, no title, vision fallback | ~2000-3000ms | Full vision pipeline |

### 22.2 PartialContext Read Safety

Providers in the same cost tier receive the same `PartialContext` snapshot (the state before the tier began). They cannot see each other's outputs. This is correct: parallel providers in the same tier should not depend on each other's results.

### 22.3 Memory

`PartialContext` holds signal values by reference (strings, structs). The total memory footprint is negligible — a few kilobytes at most per resolution.

### 22.4 Provider Timeout

The resolver does not enforce per-provider timeouts. Each provider is responsible for its own timeout behavior. `VisualContextExtractor` already has `visionTimeoutSeconds`. File reads have inherent OS-level timeouts. If a provider hangs, the `TaskGroup` will wait for it. A future enhancement could add a per-tier timeout to the resolver, but this is not required at launch.

---

## 23. Failure Handling

### 23.1 Provider Failures Are Non-Fatal

A provider that fails returns a `ContextContribution` with an empty `signals` dictionary and confidence 0.0. The resolver continues with other providers. No exceptions propagate from providers to the resolver.

### 23.2 Partial Resolution

If some desired signals cannot be satisfied by any provider, the resolver returns a `ResolvedContext` with the partial results. The consumer decides how to handle missing signals:

- Missing `filePath` → consumer falls back to snippet-only explanation
- Missing `visualObservations` → consumer proceeds without visual context
- Missing `workingMemory` → consumer proceeds without investigation history

This matches Decode's existing graceful degradation pattern.

### 23.3 Total Provider Failure

If all providers fail (all return empty contributions), the resolver returns a `ResolvedContext` with no signals. The consumer proceeds with snippet-only behavior — identical to Selection Mode's current non-enhanced path.

### 23.4 ResolutionMetadata

Every `ResolvedContext` includes metadata for diagnostics:

```
struct ResolutionMetadata {
    let contributions: [ContextContribution]
    let totalLatencyMs: Int
    let providersUsed: [String]
    let providersSkipped: [String]
    let unsatisfiedSignals: Set<ContextSignalKind>
}
```

This enables:
- Latency profiling: which providers are slow?
- Skip analysis: how often is vision skipped?
- Coverage analysis: which signals are consistently unsatisfied?

---

## 24. Why This Architecture Was Chosen

### 24.1 The Fundamental Insight

Sufficiency is not business logic — it's set arithmetic. The consumer says "I want {A, B, C}." Providers produce signals. When {A, B, C} are all present, stop. This is generic infrastructure.

### 24.2 Design Derivation

The architecture was derived through three iterations:

1. **Smart Vision Gate** (rejected) — a binary decision "should I call vision?" embedded in SelectionModeCoordinator. Solves the immediate problem but doesn't generalize.

2. **Policy-Based Resolver** (rejected) — consumer provides a policy object encoding sufficiency rules. Moves the business logic out of the resolver but couples policies to provider identifiers.

3. **Signal-Demand Resolver** (adopted) — consumers declare desired signals, providers declare produced signals, resolver performs set arithmetic. Zero business logic in the resolver.

### 24.3 Alignment with Decode Principles

- **Deterministic first** (CLAUDE.md Principle #1): local providers produce deterministic context. Vision is the semantic fallback.
- **The platform doesn't know its consumers** (DAS pattern): the resolver doesn't know what capabilities exist.
- **Compose, do not aggregate** (DAS-001 P4): providers compose independently. The resolver doesn't aggregate them into a monolithic service.
- **Incremental shipping** (CLAUDE.md Principle #6): each provider can be implemented and tested independently. Migration is incremental.

---

## 25. Comparison Against Alternatives

### 25.1 Smart Vision Gate

A binary function in `SelectionModeCoordinator` that decides "skip vision" or "use vision."

| Dimension | Smart Vision Gate | Signal-Demand Resolver |
|---|---|---|
| Scope | Single decision in one coordinator | Universal context for all capabilities |
| Scalability | New context sources require gate changes | New provider, register, done |
| Maintainability | Logic embedded in coordinator | Standalone, testable service |
| Extensibility | Each new capability duplicates gate logic | New capability submits request |
| Session Mode benefit | None | Gains visual context, unified resolution |
| Testing | Test gate conditions + vision pipeline | Test each provider + resolver composition |

**Verdict:** The gate solves the immediate problem (skip vision when local context suffices) but doesn't generalize. Every future capability that needs multi-source context would re-derive the gate pattern.

### 25.2 Policy-Based Resolver

Consumer provides a `ContextPolicy` object with `isSufficient()` and `shouldDispatch()` methods.

| Dimension | Policy-Based | Signal-Demand |
|---|---|---|
| Resolver logic | Delegates to policy | Set arithmetic |
| Consumer responsibility | Create request + policy | Create request (just signal set + budget) |
| Policy coupling | `shouldDispatch()` names specific providers | No coupling to providers |
| New capability cost | Write consumer + policy + test both | Write consumer + signal set |
| Debugging | Read policy code | Read signal sets + contribution log |

**Verdict:** The policy separates concerns but introduces `shouldDispatch()` — which couples the policy to the provider catalog. Adding a new provider requires auditing every policy. The signal-demand approach avoids this entirely: providers self-govern via `canContribute()`.

### 25.3 Planner-Based Resolver

Providers declare `provides`, `requires`, estimated latency. A planner builds an execution DAG.

| Dimension | Planner-Based | Signal-Demand |
|---|---|---|
| Provider interface | Rich (provides, requires, latency, cost) | Moderate (produces, cost, canContribute) |
| Dependency handling | Automated DAG resolution | Cost tiers + self-exclusion |
| Resolver complexity | High (~300 lines planner + executor) | Low (~50 lines) |
| Debugging | Inspect execution plan | Read contribution list |
| Risk of over-engineering | High | Low |
| Handles 6 providers | Overkill | Comfortably |
| Handles 60 providers | Shines | Still works (cost tiers scale) |

**Verdict:** Architecturally elegant but disproportionate to the problem. Decode has ~7 providers with a simple dependency structure. The planner can be introduced as a resolver implementation detail later if provider count grows significantly.

### 25.4 Summary Table

| | Gate | Policy | Planner | Signal-Demand |
|---|---|---|---|---|
| Lines of infrastructure | ~30 | ~100 + policy/consumer | ~300 | ~50 |
| New provider cost | Gate change | Policy audits | Metadata declaration | Register |
| New capability cost | Duplicate gate | Policy + consumer | Consumer | Consumer |
| Consumer↔Provider coupling | High | Medium | Low | None |
| Proportional to problem | Yes | Yes | No | Yes |

---

## 26. Future Evolution

### 26.1 Per-Signal Confidence

If a provider needs to report different confidence levels for different signals, extend `ContextContribution` with an optional `signalConfidences: [ContextSignalKind: Double]` dictionary. The merge algorithm falls back to the contribution-level confidence when per-signal confidence is absent. This is backward-compatible.

### 26.2 Streaming Resolution

If a consumer wants to display partial results as they arrive (e.g., show file path while waiting for vision), the resolver could expose an `AsyncStream<PartialContext>` interface. This would require refactoring the tier-based loop to yield after each merge. Not needed at launch.

### 26.3 Provider-Level Timeout

If provider hangs become a reliability issue, add an optional `timeoutMs` to the `ContextBudget` or per-tier. The resolver wraps each provider dispatch in a `Task` with a timeout race. Not needed at launch — providers own their own timeouts.

### 26.4 Planner Upgrade

If Decode reaches 20+ providers with complex interdependencies, replace the cost-tier loop with a DAG planner that resolves `requires → produces` chains. The external interface (`ContextRequest → ResolvedContext`) does not change. The planner is an implementation detail of the resolver.

### 26.5 Analytics Integration

Resolution metadata (`providersUsed`, `totalLatencyMs`, `unsatisfiedSignals`) can be reported to the analytics pipeline. This enables:
- Vision skip rate tracking
- Provider latency monitoring
- Signal coverage analysis across user populations

### 26.6 New Signal Kinds (Anticipated)

| Signal Kind | Description | Likely Provider |
|---|---|---|
| `gitHistory` | Recent commit messages, blame data for the snippet's lines | GitProvider |
| `documentation` | Doc comments for the containing entity | DocProvider |
| `testCoverage` | Whether the snippet/entity has test coverage | TestCoverageProvider |
| `relatedFiles` | Files that import or are imported by the current file | ProjectGraphProvider |

Each would follow the standard extension pattern: add signal kind, create provider, register. Resolver unchanged.

---

## Appendix A: ResolvedContext Structure

```
struct ResolvedContext {
    // Resolved signal values
    let filePath: String?
    let fileName: String?
    let containingEntity: EntityContext?
    let surroundingCode: SurroundingCode?
    let fileOutline: String?
    let fileIntelligence: FileIntelligenceContext?
    let codeHealth: HealthClassification?
    let workingMemory: String?
    let visualObservations: String?
    let annotations: [String]?

    // Resolution metadata
    let metadata: ResolutionMetadata
    let confidence: Double              // Minimum confidence across all satisfied signals

    // Convenience
    var isEmpty: Bool                   // No signals satisfied
    var isComplete: Bool                // All requested signals satisfied
}
```

## Appendix B: PartialContext Structure

```
struct PartialContext {
    var signals: [ContextSignalKind: ContextSignalValue]
    var confidenceBySignal: [ContextSignalKind: Double]
    var satisfiedSignals: Set<ContextSignalKind>

    // Convenience accessors for providers
    var filePath: String?
    var containingEntity: EntityContext?
    var annotations: [String]?
    // ... one computed property per signal kind

    mutating func merge(_ contribution: ContextContribution)
}
```

## Appendix C: EntityContext Structure

```
struct EntityContext {
    let name: String
    let kind: String
    let signature: String
    let sourceText: String?
    let lineRange: ClosedRange<Int>?
    let parentName: String?
}
```

## Appendix D: SurroundingCode Structure

```
struct SurroundingCode {
    let before: String
    let after: String
    let lineRange: ClosedRange<Int>
}
```

## Appendix E: FileIntelligenceContext Structure

```
struct FileIntelligenceContext {
    let identity: FileIdentity?
    let purpose: String?
    let behavior: String?
    let safety: String?
    let design: String?
    let imports: [ImportDeclaration]?
}
```
