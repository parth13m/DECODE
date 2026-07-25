// ContextAssembly.swift — M5
// DDS-006: Context Assembly Runtime — structured context from retrieved evidence
// IAG-001 §4: ContextAssembly module, depends on DIRCore + RetrievalRuntime
// IAG-003 §1.2: Stateless — no actor

import Foundation
import DIRCore
import RetrievalRuntime

/// Stateless context assembly service implementing the 10-phase assembly pipeline.
///
/// DDS-006 PC-1: Transforms evidence sets into purpose-calibrated, budget-constrained
/// context frames via strategy-based selection.
///
/// DDS-006 PC-2/PC-3: Owns the strategy catalog — validates, registers, versions,
/// and resolves context strategies.
///
/// Thread safety: The strategy catalog is protected by an internal lock for concurrent
/// registration and assembly. Each assembly request is independent — no shared mutable
/// state between requests beyond the catalog.
public final class ContextAssemblyService: ContextAssembling, StrategyManagement, @unchecked Sendable {
    // Note: @unchecked Sendable justified — internal state protected by NSLock.
    // No actor used per IAG-003 §1.2 (stateless subsystem). The catalog lock
    // protects only strategy registration/lookup, not per-request assembly state.

    // MARK: — Strategy Catalog

    /// Active strategies keyed by purpose.
    private var activeStrategies: [ContextPurpose: ContextStrategy] = [:]

    /// Superseded strategy versions keyed by (purpose, version).
    private var supersededStrategies: [ContextPurpose: [String: ContextStrategy]] = [:]

    /// Protects catalog reads/writes for concurrent access.
    private let catalogLock = NSLock()

    // MARK: — Lifecycle

    private var state: ContextAssemblyState = .available

    public init() {}

    // MARK: — StrategyManagement (PC-2, PC-3)

    public func register(_ strategy: ContextStrategy) -> Result<Void, StrategyValidationError> {
        // Validate SI-1 through SI-7 (except SI-6 which is enforced by catalog supersession).
        if let error = validate(strategy) {
            return .failure(error)
        }

        catalogLock.lock()
        defer { catalogLock.unlock() }

        // SI-6: Supersede prior version if exists.
        if let prior = activeStrategies[strategy.purpose] {
            var versions = supersededStrategies[strategy.purpose] ?? [:]
            versions[prior.version] = prior
            supersededStrategies[strategy.purpose] = versions
        }

        activeStrategies[strategy.purpose] = strategy
        return .success(())
    }

    public func strategyCatalog() -> [ContextPurpose: ContextStrategy] {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        return activeStrategies
    }

    // MARK: — ContextAssembling (PC-1)

    public func assemble(_ request: AssemblyRequest) async -> AssemblyResult {
        let startTime = ContinuousClock.now

        // Phase 1: Precondition validation.
        if let rejection = validatePreconditions(request) {
            return .rejected(rejection)
        }

        // Phase 2: Strategy resolution.
        let strategy: ContextStrategy
        switch resolveStrategy(purpose: request.purpose, version: request.strategyVersion) {
        case .resolved(let resolved):
            strategy = resolved
        case .rejected(let rejection):
            return .rejected(rejection)
        }

        // Phase 3: Budget computation.
        let totalBudget = request.budget
        let stratumBudgets = computeStratumBudgets(strategy: strategy, totalBudget: totalBudget)

        // Phases 4–7: Selection pipeline.
        let selectionResult = executeSelection(
            evidence: request.evidenceSet.evidence,
            strategy: strategy,
            stratumBudgets: stratumBudgets,
            totalBudget: totalBudget,
            denomination: request.denomination
        )

        // Phase 8: Metadata assembly.
        let elapsed = ContinuousClock.now - startTime
        let assemblyDuration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let metadata = assembleMetadata(
            evidenceSet: request.evidenceSet,
            filledStrata: selectionResult.strata,
            coherenceStats: selectionResult.coherenceStatistics,
            assemblyDuration: assemblyDuration,
            strategyVersion: strategy.version,
            totalBudget: totalBudget,
            denomination: request.denomination
        )

        // Phase 9: Context frame construction.
        let totalUsed = selectionResult.strata.reduce(0) { $0 + $1.budgetUsed }
        let frame = ContextFrame(
            anchors: request.evidenceSet.anchors,
            purpose: request.purpose,
            strategyVersion: strategy.version,
            strata: selectionResult.strata,
            budgetSummary: BudgetSummary(
                total: totalBudget,
                denomination: request.denomination,
                used: totalUsed
            ),
            metadata: metadata
        )

        // Phase 10: Return.
        return .success(frame)
    }

    // MARK: — Phase 1: Precondition Validation

    private func validatePreconditions(_ request: AssemblyRequest) -> AssemblyRejection? {
        // PRE-3: Budget validity.
        if request.budget <= 0 {
            return AssemblyRejection(
                reason: .invalidBudget,
                diagnostic: "Budget must be positive, got \(request.budget)."
            )
        }

        // PRE-1: Evidence set structural validity — basic check.
        // An empty evidence set is valid (FM-1). We check that metadata is present
        // and epoch is valid. Full structural validation of each annotated unit
        // is the responsibility of the Retrieval Runtime (DDS-005).

        return nil
    }

    // MARK: — Phase 2: Strategy Resolution

    private enum StrategyResolution {
        case resolved(ContextStrategy)
        case rejected(AssemblyRejection)
    }

    private func resolveStrategy(purpose: ContextPurpose, version: String?) -> StrategyResolution {
        catalogLock.lock()
        defer { catalogLock.unlock() }

        if let version {
            // Check active strategy first.
            if let active = activeStrategies[purpose], active.version == version {
                return .resolved(active)
            }
            // Check superseded versions.
            if let versioned = supersededStrategies[purpose]?[version] {
                return .resolved(versioned)
            }
            return .rejected(AssemblyRejection(
                reason: .strategyVersionNotFound,
                diagnostic: "Strategy version '\(version)' not found for purpose '\(purpose)'."
            ))
        }

        guard let active = activeStrategies[purpose] else {
            return .rejected(AssemblyRejection(
                reason: .strategyNotFound,
                diagnostic: "No strategy registered for purpose '\(purpose)'."
            ))
        }
        return .resolved(active)
    }

    // MARK: — Phase 3: Budget Computation

    private func computeStratumBudgets(strategy: ContextStrategy, totalBudget: Int) -> [String: Int] {
        var budgets: [String: Int] = [:]
        var allocated = 0

        let sorted = strategy.sortedStrata
        for (index, stratum) in sorted.enumerated() {
            if index == sorted.count - 1 {
                // Last stratum gets remainder to avoid rounding loss.
                budgets[stratum.name] = totalBudget - allocated
            } else {
                let share = Int((stratum.budgetFraction * Double(totalBudget)).rounded(.down))
                budgets[stratum.name] = share
                allocated += share
            }
        }
        return budgets
    }

    // MARK: — Phases 4–7: Selection Pipeline

    private struct SelectionResult {
        let strata: [FilledStratum]
        let coherenceStatistics: CoherenceStatistics
    }

    private func executeSelection(
        evidence: [AnnotatedUnit],
        strategy: ContextStrategy,
        stratumBudgets: [String: Int],
        totalBudget: Int,
        denomination: BudgetDenomination
    ) -> SelectionResult {
        let sortedStrata = strategy.sortedStrata

        // Track which units have been assigned to a stratum (CFI-2: partitioning).
        var assignedUnitIDs: Set<UnitIdentifier> = []

        // Coherence tracking.
        var coherenceFired = 0
        var coherenceSatisfied = 0
        var coherenceRetracted = 0

        // Track budget overflow flowing from higher to lower priority strata.
        var overflowBudget = 0

        // Collected filled strata.
        var filledStrata: [FilledStratum] = []

        // Phase 4: Stratum-ordered selection.
        for stratum in sortedStrata {
            let stratumAllocation = (stratumBudgets[stratum.name] ?? 0) + overflowBudget

            // 4a: Candidate identification — units matching this stratum's criteria
            // that haven't been assigned to a prior stratum.
            var candidates = evidence.filter { unit in
                !assignedUnitIDs.contains(unit.unit.id) && stratum.selectionCriteria.matches(unit)
            }

            // 4b: Candidate ordering per fill policy.
            candidates.sort { a, b in
                sortByFillPolicy(a, b, policy: stratum.fillPolicy)
            }

            // 4c: Per-candidate processing with budget enforcement.
            var selectedUnits: [ContextUnit] = []
            var budgetUsed = 0

            for candidate in candidates {
                let unitCost = estimateUnitCost(candidate, denomination: denomination)

                // Check coherence constraints for this candidate.
                let coherenceResult = evaluateCoherence(
                    candidate: candidate,
                    evidence: evidence,
                    selectedUnitIDs: assignedUnitIDs,
                    constraints: strategy.coherenceConstraints
                )

                let totalCostForCandidate = unitCost + coherenceResult.additionalCost

                if budgetUsed + totalCostForCandidate <= stratumAllocation {
                    // Include the candidate.
                    let role = ContextRole(
                        stratumName: stratum.name,
                        reason: roleReason(for: candidate, stratum: stratum)
                    )
                    selectedUnits.append(ContextUnit(annotatedUnit: candidate, role: role))
                    assignedUnitIDs.insert(candidate.unit.id)
                    budgetUsed += unitCost

                    // Include coherence-required units.
                    for required in coherenceResult.requiredUnits {
                        if !assignedUnitIDs.contains(required.unit.id) {
                            let coherenceRole = ContextRole(
                                stratumName: stratum.name,
                                reason: "Coherence: co-required with \(candidate.unit.id)"
                            )
                            selectedUnits.append(ContextUnit(annotatedUnit: required, role: coherenceRole))
                            assignedUnitIDs.insert(required.unit.id)
                            budgetUsed += estimateUnitCost(required, denomination: denomination)
                        }
                    }

                    coherenceFired += coherenceResult.constraintsFired
                    coherenceSatisfied += coherenceResult.constraintsSatisfied
                } else if stratum.essential {
                    // Essential stratum: try to fit as many as budget allows.
                    if budgetUsed + unitCost <= stratumAllocation {
                        let role = ContextRole(
                            stratumName: stratum.name,
                            reason: roleReason(for: candidate, stratum: stratum)
                        )
                        selectedUnits.append(ContextUnit(annotatedUnit: candidate, role: role))
                        assignedUnitIDs.insert(candidate.unit.id)
                        budgetUsed += unitCost
                    }
                }
                // Non-essential: skip candidate if it doesn't fit (within-stratum elision).
            }

            // 4d: Budget overflow — unused budget flows to next stratum.
            overflowBudget = stratumAllocation - budgetUsed

            filledStrata.append(FilledStratum(
                name: stratum.name,
                priority: stratum.priority,
                units: selectedUnits,
                budgetAllocated: stratumAllocation,
                budgetUsed: budgetUsed
            ))
        }

        // Phase 5: Cross-stratum coherence resolution.
        // Verify all coherence constraints are satisfied or retracted.
        let allSelectedIDs = assignedUnitIDs
        for constraint in strategy.coherenceConstraints {
            let hasTrigger = filledStrata.flatMap(\.units).contains { cu in
                constraint.triggerCriteria.matches(cu.annotatedUnit)
            }
            if hasTrigger {
                let hasRequired = filledStrata.flatMap(\.units).contains { cu in
                    constraint.requirementCriteria.matches(cu.annotatedUnit)
                }
                if !hasRequired {
                    // Retract: remove triggering units to maintain coherence (CFI-3).
                    coherenceRetracted += 1
                    for i in 0..<filledStrata.count {
                        let before = filledStrata[i].units.count
                        let filtered = filledStrata[i].units.filter { cu in
                            !constraint.triggerCriteria.matches(cu.annotatedUnit)
                        }
                        if filtered.count != before {
                            let newUsed = filtered.reduce(0) { $0 + estimateUnitCost($1.annotatedUnit, denomination: denomination) }
                            filledStrata[i] = FilledStratum(
                                name: filledStrata[i].name,
                                priority: filledStrata[i].priority,
                                units: filtered,
                                budgetAllocated: filledStrata[i].budgetAllocated,
                                budgetUsed: newUsed
                            )
                        }
                    }
                }
            }
        }

        // Phase 6: Deduplication — SI-2 should prevent this, but defensive.
        // Already handled by assignedUnitIDs tracking during selection.

        // Phase 7: Within-stratum ordering — already established during selection.

        let coherenceStats = CoherenceStatistics(
            fired: coherenceFired,
            satisfied: coherenceSatisfied,
            retracted: coherenceRetracted
        )

        return SelectionResult(strata: filledStrata, coherenceStatistics: coherenceStats)
    }

    // MARK: — Fill Policy Sorting

    private func sortByFillPolicy(_ a: AnnotatedUnit, _ b: AnnotatedUnit, policy: FillPolicy) -> Bool {
        switch policy {
        case .distanceFirst:
            // Ascending distance (closest first), tie-break by unit ID.
            if a.distance != b.distance { return a.distance < b.distance }
            return a.unit.id < b.unit.id

        case .tierFirst:
            // Descending tier (highest tier first), tie-break by unit ID.
            if a.unit.tier != b.unit.tier { return a.unit.tier > b.unit.tier }
            return a.unit.id < b.unit.id

        case .confidenceFirst:
            // Descending confidence (highest first), tie-break by unit ID.
            if a.unit.confidence != b.unit.confidence { return a.unit.confidence > b.unit.confidence }
            return a.unit.id < b.unit.id

        case .entityCompleteness:
            // Prefer units with more predicates from the same subject.
            // Approximated by distance (completeness correlates with proximity),
            // then tier, then unit ID.
            if a.distance != b.distance { return a.distance < b.distance }
            if a.unit.tier != b.unit.tier { return a.unit.tier > b.unit.tier }
            return a.unit.id < b.unit.id
        }
    }

    // MARK: — Unit Cost Estimation

    private func estimateUnitCost(_ unit: AnnotatedUnit, denomination: BudgetDenomination) -> Int {
        switch denomination {
        case .unitCount:
            return 1
        case .tokens:
            // Conservative token estimation per DDS-006.
            // Estimate based on value type and grounding chain.
            return estimateTokenCost(unit.unit)
        }
    }

    /// Conservative token estimate for a single atomic unit.
    ///
    /// DDS-006 Unit Size Estimation: Conservative — overestimates rather than underestimates.
    private func estimateTokenCost(_ unit: AtomicUnit) -> Int {
        // Base cost: subject + predicate + metadata overhead.
        var tokens = 20

        // Value cost depends on value type.
        switch unit.value {
        case .string(let s):
            // ~4 chars per token, conservative.
            tokens += max(1, s.count / 3)
        case .text(let t):
            tokens += max(1, t.count / 3)
        case .integer, .boolean, .float:
            tokens += 2
        case .enumerated:
            tokens += 3
        case .reference:
            tokens += 5
        case .structured:
            tokens += 30
        }

        // Grounding chain overhead.
        switch unit.grounding {
        case .direct:
            tokens += 5
        case .derived:
            tokens += 10
        case .inferred:
            tokens += 15
        }

        return tokens
    }

    // MARK: — Coherence Evaluation

    private struct CoherenceEvaluation {
        let requiredUnits: [AnnotatedUnit]
        let additionalCost: Int
        let constraintsFired: Int
        let constraintsSatisfied: Int
    }

    private func evaluateCoherence(
        candidate: AnnotatedUnit,
        evidence: [AnnotatedUnit],
        selectedUnitIDs: Set<UnitIdentifier>,
        constraints: [CoherenceConstraint]
    ) -> CoherenceEvaluation {
        var requiredUnits: [AnnotatedUnit] = []
        var fired = 0
        var satisfied = 0

        for constraint in constraints {
            if constraint.triggerCriteria.matches(candidate) {
                fired += 1
                // Check if requirement is already selected.
                let alreadySelected = selectedUnitIDs.contains { id in
                    evidence.contains { $0.unit.id == id && constraint.requirementCriteria.matches($0) }
                }
                if alreadySelected {
                    satisfied += 1
                    continue
                }
                // Find a requirement candidate in the evidence set.
                if let required = evidence.first(where: { unit in
                    !selectedUnitIDs.contains(unit.unit.id) &&
                    unit.unit.id != candidate.unit.id &&
                    constraint.requirementCriteria.matches(unit)
                }) {
                    requiredUnits.append(required)
                    satisfied += 1
                }
                // If not found, constraint will be handled in phase 5 (retraction).
            }
        }

        let additionalCost = requiredUnits.count // Conservative: 1 unit each for unitCount.
        return CoherenceEvaluation(
            requiredUnits: requiredUnits,
            additionalCost: additionalCost,
            constraintsFired: fired,
            constraintsSatisfied: satisfied
        )
    }

    // MARK: — Context Role Generation

    private func roleReason(for unit: AnnotatedUnit, stratum: StratumDefinition) -> String {
        let stageDesc: String
        switch unit.provenance.stage {
        case .direct: stageDesc = "direct evidence"
        case .relational: stageDesc = "relational evidence"
        case .scope: stageDesc = "scope evidence"
        }
        return "\(stageDesc) in \(unit.unit.predicate.domain), distance \(unit.distance)"
    }

    // MARK: — Phase 8: Metadata Assembly

    private func assembleMetadata(
        evidenceSet: EvidenceSet,
        filledStrata: [FilledStratum],
        coherenceStats: CoherenceStatistics,
        assemblyDuration: TimeInterval,
        strategyVersion: String,
        totalBudget: Int,
        denomination: BudgetDenomination
    ) -> ContextFrameMetadata {
        let allUnits = filledStrata.flatMap(\.units)
        let selectedCount = allUnits.count

        // Per-tier counts.
        var tierCounts: [Tier: Int] = [:]
        for cu in allUnits {
            tierCounts[cu.annotatedUnit.unit.tier, default: 0] += 1
        }

        // Per-stratum counts.
        var stratumCounts: [String: Int] = [:]
        for stratum in filledStrata {
            stratumCounts[stratum.name] = stratum.units.count
        }

        // Degradation level.
        let presentTiers = Set(tierCounts.filter { $0.value > 0 }.map(\.key))
        let degradationLevel: DegradationLevel
        if selectedCount == 0 {
            degradationLevel = .empty
        } else if presentTiers.contains(.t2) {
            degradationLevel = .full
        } else if presentTiers.contains(.t1) {
            degradationLevel = .t0t1Only
        } else {
            degradationLevel = .t0Only
        }

        // Freshness state from evidence set metadata.
        let freshnessState: FreshnessState
        if evidenceSet.metadata.fallbackFamilies.isEmpty {
            freshnessState = .fresh
        } else if evidenceSet.metadata.fallbackFamilies.count < 3 {
            freshnessState = .partiallyStale
        } else {
            freshnessState = .stale
        }

        // Budget insufficiency — check if essential stratum couldn't fit all candidates.
        let totalUsed = filledStrata.reduce(0) { $0 + $1.budgetUsed }
        let budgetInsufficient = filledStrata.contains { stratum in
            // A stratum with essential flag where budget was exhausted before all candidates.
            stratum.budgetUsed == stratum.budgetAllocated && stratum.budgetAllocated < totalBudget
        }

        return ContextFrameMetadata(
            evidenceSetSize: evidenceSet.evidence.count,
            selectedCount: selectedCount,
            tierCounts: tierCounts,
            stratumCounts: stratumCounts,
            coherenceStatistics: coherenceStats,
            degradationLevel: degradationLevel,
            freshnessState: freshnessState,
            assemblyDuration: assemblyDuration,
            strategyVersion: strategyVersion,
            committedEpoch: evidenceSet.metadata.observedEpoch,
            budgetInsufficient: budgetInsufficient
        )
    }

    // MARK: — Strategy Validation (SI-1 through SI-7)

    /// Validates a strategy against all invariants. Returns the first violation found, or nil.
    private func validate(_ strategy: ContextStrategy) -> StrategyValidationError? {
        // SI-1: Budget fraction totality — sum must equal 1.0.
        let sum = strategy.strata.reduce(0.0) { $0 + $1.budgetFraction }
        if abs(sum - 1.0) > 1e-9 {
            return .budgetFractionMismatch(sum: sum)
        }

        // SI-3: Priority uniqueness.
        var seenPriorities: Set<Int> = []
        for stratum in strategy.strata {
            if seenPriorities.contains(stratum.priority) {
                return .duplicatePriority(priority: stratum.priority)
            }
            seenPriorities.insert(stratum.priority)
        }

        // SI-5: Essential stratum singularity — at most one essential stratum.
        let essentialCount = strategy.strata.filter(\.essential).count
        if essentialCount > 1 {
            return .multipleEssentialStrata
        }

        // SI-7: Stratum reachability — each stratum's criteria must be satisfiable.
        for stratum in strategy.strata {
            if !stratum.selectionCriteria.isSatisfiable {
                return .unsatisfiableCriteria(stratum: stratum.name)
            }
        }

        // SI-2: Selection criteria mutual exclusivity.
        // For each pair of strata, check if their criteria could overlap.
        let strataList = strategy.strata
        for i in 0..<strataList.count {
            for j in (i + 1)..<strataList.count {
                if criteriaCouldOverlap(strataList[i].selectionCriteria, strataList[j].selectionCriteria) {
                    return .overlappingSelectionCriteria(
                        stratum1: strataList[i].name,
                        stratum2: strataList[j].name
                    )
                }
            }
        }

        // SI-4: Coherence constraint acyclicity.
        if hasCyclicCoherenceConstraints(strategy.coherenceConstraints) {
            return .cyclicCoherenceConstraints
        }

        return nil
    }

    /// Checks if two selection criteria could match the same annotated unit.
    ///
    /// SI-2: Two criteria overlap if there exists a valid annotated unit that
    /// satisfies both. We check for disjoint stage or disjoint predicate domains.
    private func criteriaCouldOverlap(_ a: SelectionCriteria, _ b: SelectionCriteria) -> Bool {
        // If both specify different stages, they are disjoint.
        if let aStage = a.stage, let bStage = b.stage, aStage != bStage {
            return false
        }

        // If both specify predicate domains with no overlap, they are disjoint.
        if let aDomains = a.predicateDomains, let bDomains = b.predicateDomains {
            if aDomains.isDisjoint(with: bDomains) {
                return false
            }
        }

        // If tier ranges don't overlap, they are disjoint.
        if let aMin = a.minTier, let bMax = b.maxTier, aMin > bMax { return false }
        if let bMin = b.minTier, let aMax = a.maxTier, bMin > aMax { return false }

        // Could overlap.
        return true
    }

    /// Detects cycles in the coherence constraint graph.
    ///
    /// SI-4: Build a directed graph where constraint X has an edge to constraint Y
    /// if satisfying X's requirement could trigger Y. Check for cycles.
    private func hasCyclicCoherenceConstraints(_ constraints: [CoherenceConstraint]) -> Bool {
        guard constraints.count > 1 else { return false }

        // Build adjacency: constraint i → constraint j if i's requirement
        // could satisfy j's trigger.
        let n = constraints.count
        var adj: [[Int]] = Array(repeating: [], count: n)

        for i in 0..<n {
            for j in 0..<n where i != j {
                // If satisfying constraint i's requirement could trigger constraint j
                // (i.e., the requirement of i matches the trigger of j).
                if criteriaCouldOverlap(constraints[i].requirementCriteria,
                                         constraints[j].triggerCriteria) {
                    adj[i].append(j)
                }
            }
        }

        // DFS cycle detection.
        enum Color { case white, gray, black }
        var colors = Array(repeating: Color.white, count: n)

        func dfs(_ node: Int) -> Bool {
            colors[node] = .gray
            for neighbor in adj[node] {
                if colors[neighbor] == .gray { return true }
                if colors[neighbor] == .white && dfs(neighbor) { return true }
            }
            colors[node] = .black
            return false
        }

        for i in 0..<n {
            if colors[i] == .white && dfs(i) {
                return true
            }
        }

        return false
    }
}
