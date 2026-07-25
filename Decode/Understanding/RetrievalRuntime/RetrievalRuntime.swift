// RetrievalRuntime.swift — M4
// DDS-005: Retrieval Runtime — five-stage evidence retrieval from indexes and DIR
// IAG-003 §1.2: No actor — stateless. Each request is independent.
// IAG-004 §6.1: Phase 4 implementation

import Foundation
import os
import DIRCore
import IndexRuntime

/// Stateless evidence retrieval service implementing the five-stage pipeline.
///
/// DDS-005: Executes anchor resolution → direct evidence → relational evidence →
/// scope evidence → annotation against the DIR and indexes.
///
/// No persistent state (DDS-005 Lifecycle). Holds references to required contracts
/// (IndexQuerying, IndexFreshness, DIRReadAccess) and processes requests statelessly.
public struct RetrievalService: EvidenceRetrieval, Sendable {

    private let indexQuerying: any IndexQuerying
    private let indexFreshness: any IndexFreshness
    private let dirAccess: any DIRReadAccess
    private let logger = Logger(subsystem: "com.decode.understanding", category: "retrieval")

    public init(
        indexQuerying: any IndexQuerying,
        indexFreshness: any IndexFreshness,
        dirAccess: any DIRReadAccess
    ) {
        self.indexQuerying = indexQuerying
        self.indexFreshness = indexFreshness
        self.dirAccess = dirAccess
    }

    // MARK: — EvidenceRetrieval

    public func retrieve(_ request: RetrievalRequest) async -> EvidenceSet {
        // Phase 1: Validation
        guard request.budget > 0, request.tierFloor <= request.tierCeiling else {
            return emptyEvidenceSet(request: request, epoch: await dirAccess.committedEpoch, subjectNotFound: false)
        }

        // Phase 2: Epoch capture (DDS-005 RC-3 — consistent snapshot)
        let epoch = await dirAccess.committedEpoch

        // Phase 3: Query plan construction
        let plan = buildQueryPlan(for: request)

        // Stage 1: Anchor resolution
        let anchors = await resolveAnchorsInternal(for: request.subject, epoch: epoch)
        if anchors.isEmpty {
            logger.debug("Subject not found for retrieval request")
            return emptyEvidenceSet(request: request, epoch: epoch, subjectNotFound: true)
        }

        // Execute stages 2–4 with budget tracking
        var accumulator = EvidenceAccumulator(totalBudget: request.budget, plan: plan)
        var fallbackFamilies: Set<IndexFamily> = []

        // Stage 2: Direct evidence
        await gatherDirectEvidence(
            anchors: anchors,
            plan: plan,
            epoch: epoch,
            accumulator: &accumulator,
            fallbackFamilies: &fallbackFamilies
        )

        // Stage 3: Relational evidence
        await gatherRelationalEvidence(
            anchors: anchors,
            plan: plan,
            epoch: epoch,
            accumulator: &accumulator,
            fallbackFamilies: &fallbackFamilies
        )

        // Stage 4: Scope evidence
        await gatherScopeEvidence(
            anchors: anchors,
            plan: plan,
            epoch: epoch,
            accumulator: &accumulator,
            fallbackFamilies: &fallbackFamilies
        )

        // Stage 5: Annotation and ordering (pure computation — no index queries)
        let sortedEvidence = canonicalSort(accumulator.evidence)

        // Determine tier availability
        let availableTiers = Set(sortedEvidence.map(\.unit.tier))
        let requestedTiers = Set(Tier.allCases.filter { $0 >= plan.tierFloor && $0 <= plan.tierCeiling })
        let absentTiers = requestedTiers.subtracting(availableTiers)

        let metadata = EvidenceSetMetadata(
            completedStages: accumulator.completedStages,
            truncatedStages: accumulator.truncatedStages,
            budgetAllocated: request.budget,
            budgetConsumed: accumulator.consumed,
            fallbackFamilies: fallbackFamilies,
            availableTiers: availableTiers,
            absentTiers: absentTiers,
            observedEpoch: epoch,
            excludedUnitCount: accumulator.excludedUnitCount,
            subjectNotFound: false
        )

        return EvidenceSet(
            anchors: anchors,
            request: request,
            evidence: sortedEvidence,
            metadata: metadata
        )
    }

    public func resolveAnchors(for subject: SubjectReference) async -> [EntityReference] {
        let epoch = await dirAccess.committedEpoch
        return await resolveAnchorsInternal(for: subject, epoch: epoch)
    }

    // MARK: — Stage 1: Anchor Resolution

    /// Resolves a subject reference to concrete entity anchors.
    ///
    /// DDS-005 RC-4: Deterministic — same subject + DIR state = same anchors.
    /// Never synthesizes anchors — only resolves to existing DIR entities.
    private func resolveAnchorsInternal(
        for subject: SubjectReference,
        epoch: Epoch
    ) async -> [EntityReference] {
        switch subject {
        case .entity(let entityRef):
            // EntityReference: query Entity Index — if entity has units, it's a valid anchor
            let result = await indexQuerying.queryEntity(entityRef, predicate: nil, tier: nil, status: .active)
            if !result.entries.isEmpty {
                return [entityRef]
            }
            return []

        case .snippet(let snippetRef):
            // SnippetReference: find entities whose source range contains the snippet position.
            // We scan active units for entities grounded to the same file with overlapping line ranges.
            return await resolveSnippetAnchors(snippetRef)

        case .scope(let scopeRef):
            // ScopeReference: query Scope Index for the scope entity
            let result = await indexQuerying.queryScope(scopeRef)
            if !result.entries.isEmpty {
                return [scopeRef]
            }
            // Also check if the scope entity has any units directly
            let entityResult = await indexQuerying.queryEntity(scopeRef, predicate: nil, tier: nil, status: .active)
            if !entityResult.entries.isEmpty {
                return [scopeRef]
            }
            return []
        }
    }

    /// Resolves a snippet reference to entity anchors by finding entities whose
    /// source range contains the snippet position.
    private func resolveSnippetAnchors(_ snippet: SnippetReference) async -> [EntityReference] {
        // Get all active units and find entities grounded to the same file
        // whose source range overlaps the snippet's line range
        let allActive = await dirAccess.activeUnits()

        // Collect entities and their source ranges from grounding data
        var entityRanges: [EntityReference: (startLine: Int, endLine: Int)] = [:]

        for unit in allActive {
            guard case .entity(let entityRef) = unit.subject else { continue }
            guard case .direct(let position) = unit.grounding else { continue }
            guard position.filePath == snippet.filePath else { continue }

            // Track the widest range for each entity (across all its units)
            if let existing = entityRanges[entityRef] {
                entityRanges[entityRef] = (
                    startLine: min(existing.startLine, position.startLine),
                    endLine: max(existing.endLine, position.endLine)
                )
            } else {
                entityRanges[entityRef] = (startLine: position.startLine, endLine: position.endLine)
            }
        }

        // Find entities whose range contains the snippet
        var containingEntities: [EntityReference] = []
        for (entity, range) in entityRanges {
            if range.startLine <= snippet.startLine && range.endLine >= snippet.endLine {
                containingEntities.append(entity)
            }
        }

        if !containingEntities.isEmpty {
            // Sort for determinism (RC-4)
            return containingEntities.sorted { $0.qualifiedName < $1.qualifiedName }
        }

        // Fallback: file-level scope entity
        // Look for a scope entity representing this file
        let fileEntity = EntityReference(qualifiedName: snippet.filePath)
        let fileResult = await indexQuerying.queryEntity(fileEntity, predicate: nil, tier: nil, status: .active)
        if !fileResult.entries.isEmpty {
            return [fileEntity]
        }

        return []
    }

    // MARK: — Stage 2: Direct Evidence

    /// Gathers all atomic units directly about the resolved anchors.
    ///
    /// DDS-005 Stage 2: For each anchor, query Entity Index for all units with
    /// that entity as subject. Filter by tier and confidence. Distance = 0.
    private func gatherDirectEvidence(
        anchors: [EntityReference],
        plan: QueryPlan,
        epoch: Epoch,
        accumulator: inout EvidenceAccumulator,
        fallbackFamilies: inout Set<IndexFamily>
    ) async {
        let stageBudget = accumulator.budgetForStage(.direct)

        for anchor in anchors {
            let result = await indexQuerying.queryEntity(anchor, predicate: nil, tier: nil, status: .active)
            if result.usedFallback {
                fallbackFamilies.insert(.entity)
            }

            for entry in result.entries {
                guard accumulator.canGather(stage: .direct, stageBudget: stageBudget) else {
                    accumulator.markTruncated(.direct)
                    return
                }
                guard passesTierFilter(entry.tier, plan: plan) else { continue }

                // Resolve unit from DIR
                guard let unit = await dirAccess.unit(for: entry.unitId) else {
                    accumulator.excludedUnitCount += 1
                    continue
                }
                guard unit.status == .active else { continue }
                guard passesConfidenceFilter(unit.confidence, plan: plan) else { continue }

                let provenance = EvidenceProvenance(stage: .direct, path: ["direct"])
                let annotated = AnnotatedUnit(unit: unit, provenance: provenance, distance: 0)
                accumulator.add(annotated, stage: .direct)
            }
        }
        accumulator.markCompleted(.direct)
    }

    // MARK: — Stage 3: Relational Evidence

    /// Traverses typed relationship edges from anchors per the traversal plan.
    ///
    /// DDS-005 Stage 3: Breadth-first traversal. Each hop increments distance.
    /// Both relationship units (edges) and evidence about traversed entities (nodes) included.
    private func gatherRelationalEvidence(
        anchors: [EntityReference],
        plan: QueryPlan,
        epoch: Epoch,
        accumulator: inout EvidenceAccumulator,
        fallbackFamilies: inout Set<IndexFamily>
    ) async {
        let stageBudget = accumulator.budgetForStage(.relational)

        for anchor in anchors {
            for config in plan.traversalPlan.predicateConfigs {
                // BFS traversal from anchor
                var visited: Set<EntityReference> = Set(anchors)
                var frontier: [(entity: EntityReference, depth: Int, pathSoFar: [String])] = [
                    (entity: anchor, depth: 0, pathSoFar: ["anchor"])
                ]

                while !frontier.isEmpty {
                    guard accumulator.canGather(stage: .relational, stageBudget: stageBudget) else {
                        accumulator.markTruncated(.relational)
                        return
                    }

                    var nextFrontier: [(entity: EntityReference, depth: Int, pathSoFar: [String])] = []

                    for (currentEntity, currentDepth, currentPath) in frontier {
                        guard currentDepth < config.maxDepth else { continue }

                        let graphResult = await indexQuerying.queryGraph(
                            entity: currentEntity,
                            predicate: config.predicate,
                            direction: config.direction
                        )
                        if graphResult.usedFallback {
                            fallbackFamilies.insert(.graph)
                        }

                        for graphEntry in graphResult.entries {
                            guard accumulator.canGather(stage: .relational, stageBudget: stageBudget) else {
                                accumulator.markTruncated(.relational)
                                return
                            }

                            let neighbor = graphEntry.neighbor
                            let newDepth = currentDepth + 1
                            let newPath = currentPath + [config.predicate.name, neighbor.qualifiedName]

                            // Include the relationship unit (edge) if it passes filters
                            if passesTierFilter(graphEntry.tier, plan: plan) {
                                if let edgeUnit = await dirAccess.unit(for: graphEntry.unitId) {
                                    if edgeUnit.status == .active && passesConfidenceFilter(edgeUnit.confidence, plan: plan) {
                                        let provenance = EvidenceProvenance(stage: .relational, path: newPath)
                                        let annotated = AnnotatedUnit(unit: edgeUnit, provenance: provenance, distance: newDepth)
                                        accumulator.add(annotated, stage: .relational)
                                    }
                                } else {
                                    accumulator.excludedUnitCount += 1
                                }
                            }

                            // Gather evidence about the neighbor entity (node)
                            if !visited.contains(neighbor) {
                                visited.insert(neighbor)

                                let entityResult = await indexQuerying.queryEntity(neighbor, predicate: nil, tier: nil, status: .active)
                                if entityResult.usedFallback {
                                    fallbackFamilies.insert(.entity)
                                }

                                var entityCount = 0
                                for entry in entityResult.entries {
                                    guard entityCount < plan.traversalPlan.perEntityBudget else { break }
                                    guard accumulator.canGather(stage: .relational, stageBudget: stageBudget) else {
                                        accumulator.markTruncated(.relational)
                                        return
                                    }
                                    guard passesTierFilter(entry.tier, plan: plan) else { continue }

                                    if let unit = await dirAccess.unit(for: entry.unitId) {
                                        if unit.status == .active && passesConfidenceFilter(unit.confidence, plan: plan) {
                                            let provenance = EvidenceProvenance(stage: .relational, path: newPath)
                                            let annotated = AnnotatedUnit(unit: unit, provenance: provenance, distance: newDepth)
                                            accumulator.add(annotated, stage: .relational)
                                            entityCount += 1
                                        }
                                    } else {
                                        accumulator.excludedUnitCount += 1
                                    }
                                }

                                // Add to next frontier for deeper traversal
                                if newDepth < config.maxDepth {
                                    nextFrontier.append((entity: neighbor, depth: newDepth, pathSoFar: newPath))
                                }
                            }
                        }
                    }
                    frontier = nextFrontier
                }
            }
        }
        accumulator.markCompleted(.relational)
    }

    // MARK: — Stage 4: Scope Evidence

    /// Gathers evidence about the anchor's containing scope.
    ///
    /// DDS-005 Stage 4: Scope breadth determines which scope levels are included.
    /// Narrow = no scope evidence.
    private func gatherScopeEvidence(
        anchors: [EntityReference],
        plan: QueryPlan,
        epoch: Epoch,
        accumulator: inout EvidenceAccumulator,
        fallbackFamilies: inout Set<IndexFamily>
    ) async {
        guard plan.scope != .narrow else {
            accumulator.markCompleted(.scope)
            return
        }

        let stageBudget = accumulator.budgetForStage(.scope)

        for anchor in anchors {
            // Find scope entities containing this anchor by scanning active units
            // for scope-level entities that contain the anchor in their scope
            let activeUnits = await dirAccess.activeUnits()

            // Find file-level scope entity for this anchor
            let anchorUnits = activeUnits.filter {
                if case .entity(let ref) = $0.subject { return ref == anchor }
                return false
            }

            // Determine the file path from grounding
            var scopeEntities: [EntityReference] = []
            for unit in anchorUnits {
                if case .direct(let position) = unit.grounding {
                    let fileScope = EntityReference(qualifiedName: position.filePath)
                    if !scopeEntities.contains(fileScope) && fileScope != anchor {
                        scopeEntities.append(fileScope)
                    }
                    break
                }
            }

            // Gather scope evidence for identified scope entities
            for scopeEntity in scopeEntities {
                guard accumulator.canGather(stage: .scope, stageBudget: stageBudget) else {
                    accumulator.markTruncated(.scope)
                    return
                }

                let scopeResult = await indexQuerying.queryEntity(scopeEntity, predicate: nil, tier: nil, status: .active)
                if scopeResult.usedFallback {
                    fallbackFamilies.insert(.entity)
                }

                for entry in scopeResult.entries {
                    guard accumulator.canGather(stage: .scope, stageBudget: stageBudget) else {
                        accumulator.markTruncated(.scope)
                        return
                    }
                    guard passesTierFilter(entry.tier, plan: plan) else { continue }

                    if let unit = await dirAccess.unit(for: entry.unitId) {
                        if unit.status == .active && passesConfidenceFilter(unit.confidence, plan: plan) {
                            let provenance = EvidenceProvenance(stage: .scope, path: ["scope", scopeEntity.qualifiedName])
                            let annotated = AnnotatedUnit(unit: unit, provenance: provenance, distance: 1)
                            accumulator.add(annotated, stage: .scope)
                        }
                    } else {
                        accumulator.excludedUnitCount += 1
                    }
                }
            }
        }
        accumulator.markCompleted(.scope)
    }

    // MARK: — Stage 5: Canonical Ordering

    /// Sorts evidence into canonical deterministic order.
    ///
    /// DDS-005 Evidence Ordering:
    /// 1. Stage: direct < relational < scope
    /// 2. Distance from anchor: ascending
    /// 3. Unit identifier: ascending (stable tie-breaker)
    private func canonicalSort(_ evidence: [AnnotatedUnit]) -> [AnnotatedUnit] {
        evidence.sorted { a, b in
            if a.provenance.stage != b.provenance.stage {
                return a.provenance.stage < b.provenance.stage
            }
            if a.distance != b.distance {
                return a.distance < b.distance
            }
            return a.unit.id < b.unit.id
        }
    }

    // MARK: — Query Plan Construction

    /// Builds a deterministic query plan from the retrieval request.
    ///
    /// DDS-005: Same request always produces the same plan.
    private func buildQueryPlan(for request: RetrievalRequest) -> QueryPlan {
        let (directWeight, relationalWeight, scopeWeight) = budgetWeights(for: request.intent)
        let totalWeight = directWeight + relationalWeight + scopeWeight

        // Reservation-based budget allocation
        let directBudget = (request.budget * directWeight) / totalWeight
        let relationalBudget = (request.budget * relationalWeight) / totalWeight
        let scopeBudget = request.budget - directBudget - relationalBudget

        let traversalPlan = buildTraversalPlan(for: request.intent)

        return QueryPlan(
            directBudget: directBudget,
            relationalBudget: relationalBudget,
            scopeBudget: scopeBudget,
            traversalPlan: traversalPlan,
            tierFloor: request.tierFloor,
            tierCeiling: request.tierCeiling,
            confidenceFloor: request.confidenceFloor,
            scope: request.scope
        )
    }

    /// Returns budget allocation weights (direct, relational, scope) per intent.
    private func budgetWeights(for intent: RetrievalIntent) -> (Int, Int, Int) {
        switch intent {
        case .explain:
            return (50, 30, 20)
        case .impact:
            return (20, 60, 20)
        case .dependencies:
            return (20, 60, 20)
        case .overview:
            return (30, 40, 30)
        }
    }

    /// Builds the traversal plan for relational evidence based on intent.
    private func buildTraversalPlan(for intent: RetrievalIntent) -> TraversalPlan {
        let configs: [PredicateTraversalConfig]
        let perEntityBudget: Int

        switch intent {
        case .explain:
            configs = [
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "calls", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 1
                ),
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "conformsTo", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 1
                ),
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "inherits", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 1
                ),
            ]
            perEntityBudget = 50

        case .impact:
            configs = [
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "calls", domain: "relationship"),
                    direction: .inverse,
                    maxDepth: 2
                ),
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "conformsTo", domain: "relationship"),
                    direction: .inverse,
                    maxDepth: 2
                ),
            ]
            perEntityBudget = 30

        case .dependencies:
            configs = [
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "calls", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 2
                ),
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "inherits", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 2
                ),
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "conformsTo", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 2
                ),
            ]
            perEntityBudget = 30

        case .overview:
            configs = [
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "calls", domain: "relationship"),
                    direction: .forward,
                    maxDepth: 1
                ),
                PredicateTraversalConfig(
                    predicate: PredicateIdentifier(name: "calls", domain: "relationship"),
                    direction: .inverse,
                    maxDepth: 1
                ),
            ]
            perEntityBudget = 20
        }

        return TraversalPlan(predicateConfigs: configs, perEntityBudget: perEntityBudget)
    }

    // MARK: — Tier / Confidence Filtering

    private func passesTierFilter(_ tier: Tier, plan: QueryPlan) -> Bool {
        tier >= plan.tierFloor && tier <= plan.tierCeiling
    }

    private func passesConfidenceFilter(_ confidence: Confidence, plan: QueryPlan) -> Bool {
        guard let floor = plan.confidenceFloor else { return true }
        return confidence >= floor
    }

    // MARK: — Helpers

    private func emptyEvidenceSet(request: RetrievalRequest, epoch: Epoch, subjectNotFound: Bool) -> EvidenceSet {
        EvidenceSet(
            anchors: [],
            request: request,
            evidence: [],
            metadata: EvidenceSetMetadata(
                completedStages: [],
                truncatedStages: [],
                budgetAllocated: request.budget,
                budgetConsumed: 0,
                fallbackFamilies: [],
                availableTiers: [],
                absentTiers: [],
                observedEpoch: epoch,
                excludedUnitCount: 0,
                subjectNotFound: subjectNotFound
            )
        )
    }
}

// MARK: — Evidence Accumulator

/// Tracks budget consumption and deduplication during pipeline execution.
///
/// Per-request resource — deallocated when the request completes.
/// DDS-005: Deduplication ensures each unit appears at most once at shortest distance.
private struct EvidenceAccumulator {
    /// All gathered evidence (pre-sort).
    private(set) var evidence: [AnnotatedUnit] = []

    /// Unit IDs already gathered — for deduplication.
    private var seenUnitIds: Set<UnitIdentifier> = []

    /// Total budget.
    let totalBudget: Int

    /// Budget consumed so far.
    private(set) var consumed: Int = 0

    /// Per-stage minimum reservations.
    private let directReservation: Int
    private let relationalReservation: Int
    private let scopeReservation: Int

    /// Per-stage consumption tracking.
    private var directConsumed: Int = 0
    private var relationalConsumed: Int = 0
    private var scopeConsumed: Int = 0

    /// Stages that completed fully.
    private(set) var completedStages: Set<EvidenceStage> = []

    /// Stages truncated by budget.
    private(set) var truncatedStages: Set<EvidenceStage> = []

    /// Count of units excluded due to resolution failure.
    var excludedUnitCount: Int = 0

    init(totalBudget: Int, plan: QueryPlan) {
        self.totalBudget = totalBudget
        self.directReservation = plan.directBudget
        self.relationalReservation = plan.relationalBudget
        self.scopeReservation = plan.scopeBudget
    }

    /// Returns the available budget for a stage: its reservation plus shared pool,
    /// but never dipping below other stages' reservations.
    func budgetForStage(_ stage: EvidenceStage) -> Int {
        switch stage {
        case .direct:
            // Direct can use its reservation plus any shared pool,
            // but must leave relational and scope reservations intact
            let protectedForOthers = relationalReservation + scopeReservation
            return min(directReservation + max(0, totalBudget - consumed - protectedForOthers - directReservation + directConsumed),
                       totalBudget - consumed)
        case .relational:
            let protectedForOthers = scopeReservation
            return min(relationalReservation + max(0, totalBudget - consumed - protectedForOthers - relationalReservation + relationalConsumed),
                       totalBudget - consumed)
        case .scope:
            // Scope is last — can use everything remaining
            return totalBudget - consumed
        }
    }

    /// Whether the stage can gather one more unit.
    func canGather(stage: EvidenceStage, stageBudget: Int) -> Bool {
        guard consumed < totalBudget else { return false }
        let stageConsumed: Int
        switch stage {
        case .direct: stageConsumed = directConsumed
        case .relational: stageConsumed = relationalConsumed
        case .scope: stageConsumed = scopeConsumed
        }
        return stageConsumed < stageBudget
    }

    /// Adds an annotated unit if not already present (deduplication).
    mutating func add(_ annotated: AnnotatedUnit, stage: EvidenceStage) {
        // DDS-005 Deduplication: each unit appears at most once, at shortest distance
        guard !seenUnitIds.contains(annotated.unit.id) else { return }
        seenUnitIds.insert(annotated.unit.id)
        evidence.append(annotated)
        consumed += 1
        switch stage {
        case .direct: directConsumed += 1
        case .relational: relationalConsumed += 1
        case .scope: scopeConsumed += 1
        }
    }

    mutating func markCompleted(_ stage: EvidenceStage) {
        if !truncatedStages.contains(stage) {
            completedStages.insert(stage)
        }
    }

    mutating func markTruncated(_ stage: EvidenceStage) {
        truncatedStages.insert(stage)
        completedStages.remove(stage)
    }
}
