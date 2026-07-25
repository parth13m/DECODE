// ContextAssemblyTests.swift — ContextAssemblyTests
// DDS-006: Context Assembly Runtime tests
// Tests strategy validation (SI-1–SI-7), assembly pipeline, budget enforcement,
// coherence, elision, determinism, failure modes, and CFI invariants.

import Testing
import Foundation
@testable import ContextAssembly
@testable import DIRCore
@testable import RetrievalRuntime
@testable import UnderstandingTestSupport

// MARK: — Test Helpers

/// Creates an AnnotatedUnit with sensible defaults for testing.
private func makeAnnotatedUnit(
    id: UInt64 = 1,
    domain: String = "structure",
    tier: Tier = .t0,
    confidence: Confidence = .deterministic,
    stage: EvidenceStage = .direct,
    distance: Int = 0,
    value: TypedValue = .string("testValue")
) -> AnnotatedUnit {
    let unit = makeUnit(
        id: UnitIdentifier(rawValue: id),
        predicate: PredicateIdentifier(name: "testPred", domain: domain),
        value: value,
        tier: tier,
        confidence: confidence
    )
    return AnnotatedUnit(
        unit: unit,
        provenance: EvidenceProvenance(stage: stage, path: ["direct"]),
        distance: distance
    )
}

/// Creates a minimal valid EvidenceSet for testing.
private func makeEvidenceSet(
    evidence: [AnnotatedUnit] = [],
    anchors: [EntityReference] = [EntityReference(qualifiedName: "TestAnchor")],
    epoch: UInt64 = 5
) -> EvidenceSet {
    EvidenceSet(
        anchors: anchors,
        request: RetrievalRequest(
            subject: .entity(EntityReference(qualifiedName: "TestAnchor")),
            intent: .explain
        ),
        evidence: evidence,
        metadata: EvidenceSetMetadata(
            completedStages: [.direct, .relational, .scope],
            truncatedStages: [],
            budgetAllocated: 500,
            budgetConsumed: evidence.count,
            fallbackFamilies: [],
            availableTiers: [.t0, .t1, .t2],
            absentTiers: [],
            observedEpoch: makeEpoch(epoch),
            excludedUnitCount: 0,
            subjectNotFound: false
        )
    )
}

/// Creates a simple two-stratum strategy for testing.
private func makeSimpleStrategy(
    purpose: String = "explain",
    version: String = "1.0"
) -> ContextStrategy {
    ContextStrategy(
        purpose: ContextPurpose(purpose),
        strata: [
            StratumDefinition(
                name: "core",
                priority: 1,
                selectionCriteria: SelectionCriteria(stage: .direct),
                budgetFraction: 0.6,
                fillPolicy: .distanceFirst
            ),
            StratumDefinition(
                name: "context",
                priority: 2,
                selectionCriteria: SelectionCriteria(stage: .relational),
                budgetFraction: 0.4,
                fillPolicy: .distanceFirst
            ),
        ],
        version: version
    )
}

// MARK: — Strategy Validation Tests

@Suite("Strategy Validation")
struct StrategyValidationTests {

    @Test("SI-1: Budget fractions must sum to 1.0")
    func budgetFractionTotality() {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "a", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "b", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.3, fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success:
            Issue.record("Should have failed with budget fraction mismatch")
        case .failure(let error):
            #expect(error == .budgetFractionMismatch(sum: 0.8))
        }
    }

    @Test("SI-1: Budget fractions summing to 1.0 pass")
    func budgetFractionValid() {
        let service = ContextAssemblyService()
        let result = service.register(makeSimpleStrategy())
        switch result {
        case .success: break // Expected
        case .failure(let error):
            Issue.record("Should have succeeded, got \(error)")
        }
    }

    @Test("SI-3: Duplicate priorities rejected")
    func duplicatePriority() {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "a", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "b", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success:
            Issue.record("Should have failed with duplicate priority")
        case .failure(let error):
            #expect(error == .duplicatePriority(priority: 1))
        }
    }

    @Test("SI-5: Multiple essential strata rejected")
    func multipleEssentialStrata() {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "a", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst,
                    essential: true
                ),
                StratumDefinition(
                    name: "b", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success:
            Issue.record("Should have failed with multiple essential strata")
        case .failure(let error):
            #expect(error == .multipleEssentialStrata)
        }
    }

    @Test("SI-7: Unsatisfiable criteria rejected")
    func unsatisfiableCriteria() {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "impossible", priority: 1,
                    selectionCriteria: SelectionCriteria(minTier: .t2, maxTier: .t0),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "ok", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success:
            Issue.record("Should have failed with unsatisfiable criteria")
        case .failure(let error):
            #expect(error == .unsatisfiableCriteria(stratum: "impossible"))
        }
    }

    @Test("SI-2: Overlapping selection criteria rejected")
    func overlappingCriteria() {
        let service = ContextAssemblyService()
        // Both strata select direct stage with overlapping domains.
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "a", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "b", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .tierFirst
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success:
            Issue.record("Should have failed with overlapping criteria")
        case .failure(let error):
            #expect(error == .overlappingSelectionCriteria(stratum1: "a", stratum2: "b"))
        }
    }

    @Test("SI-2: Disjoint stages pass mutual exclusivity")
    func disjointStagesPass() {
        let service = ContextAssemblyService()
        let result = service.register(makeSimpleStrategy())
        switch result {
        case .success: break
        case .failure(let error):
            Issue.record("Should have succeeded, got \(error)")
        }
    }

    @Test("SI-2: Disjoint predicate domains pass mutual exclusivity")
    func disjointDomainsPass() {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "structure", priority: 1,
                    selectionCriteria: SelectionCriteria(predicateDomains: Set(["structure"])),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "behavior", priority: 2,
                    selectionCriteria: SelectionCriteria(predicateDomains: Set(["behavior"])),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success: break
        case .failure(let error):
            Issue.record("Should have succeeded, got \(error)")
        }
    }

    @Test("SI-4: Cyclic coherence constraints rejected")
    func cyclicCoherence() {
        let service = ContextAssemblyService()
        // Constraint A: trigger on direct → require relational.
        // Constraint B: trigger on relational → require direct.
        // This creates a cycle: A triggers B triggers A.
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "a", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "b", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
            ],
            coherenceConstraints: [
                CoherenceConstraint(
                    name: "A",
                    triggerCriteria: SelectionCriteria(stage: .direct),
                    requirementCriteria: SelectionCriteria(stage: .relational)
                ),
                CoherenceConstraint(
                    name: "B",
                    triggerCriteria: SelectionCriteria(stage: .relational),
                    requirementCriteria: SelectionCriteria(stage: .direct)
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success:
            Issue.record("Should have failed with cyclic coherence")
        case .failure(let error):
            #expect(error == .cyclicCoherenceConstraints)
        }
    }

    @Test("One essential stratum allowed")
    func singleEssentialAllowed() {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(
                    name: "essential", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.6, fillPolicy: .distanceFirst,
                    essential: true
                ),
                StratumDefinition(
                    name: "optional", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.4, fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        let result = service.register(strategy)
        switch result {
        case .success: break
        case .failure(let error):
            Issue.record("Should have succeeded, got \(error)")
        }
    }
}

// MARK: — Strategy Catalog Tests

@Suite("Strategy Catalog")
struct StrategyCatalogTests {

    @Test("Empty catalog returns empty dictionary")
    func emptyCatalog() {
        let service = ContextAssemblyService()
        let catalog = service.strategyCatalog()
        #expect(catalog.isEmpty)
    }

    @Test("Registered strategy appears in catalog")
    func registeredStrategyInCatalog() {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy(purpose: "explain"))
        let catalog = service.strategyCatalog()
        #expect(catalog.count == 1)
        #expect(catalog[ContextPurpose("explain")]?.version == "1.0")
    }

    @Test("Multiple purposes coexist in catalog")
    func multiplePurposes() {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy(purpose: "explain", version: "1.0"))
        _ = service.register(makeSimpleStrategy(purpose: "impact", version: "1.0"))
        let catalog = service.strategyCatalog()
        #expect(catalog.count == 2)
    }

    @Test("Superseded strategy replaced in catalog")
    func supersession() {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy(purpose: "explain", version: "1.0"))
        _ = service.register(makeSimpleStrategy(purpose: "explain", version: "2.0"))
        let catalog = service.strategyCatalog()
        #expect(catalog.count == 1)
        #expect(catalog[ContextPurpose("explain")]?.version == "2.0")
    }

    @Test("Superseded version accessible via version override")
    func supersededVersionAccessible() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy(purpose: "explain", version: "1.0"))
        _ = service.register(makeSimpleStrategy(purpose: "explain", version: "2.0"))

        let evidence = [makeAnnotatedUnit(id: 1, stage: .direct)]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100,
            strategyVersion: "1.0"
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.strategyVersion == "1.0")
        case .rejected:
            Issue.record("Should have assembled with superseded version")
        }
    }
}

// MARK: — Assembly Rejection Tests

@Suite("Assembly Rejections")
struct AssemblyRejectionTests {

    @Test("FM-4: Strategy not found rejection")
    func strategyNotFound() async {
        let service = ContextAssemblyService()
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(),
            purpose: ContextPurpose("unknown"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success:
            Issue.record("Should have been rejected")
        case .rejected(let rejection):
            #expect(rejection.reason == .strategyNotFound)
        }
    }

    @Test("FM-4: Strategy version not found rejection")
    func strategyVersionNotFound() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy(purpose: "explain", version: "1.0"))

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(),
            purpose: ContextPurpose("explain"),
            budget: 100,
            strategyVersion: "9.9"
        )
        let result = await service.assemble(request)
        switch result {
        case .success:
            Issue.record("Should have been rejected")
        case .rejected(let rejection):
            #expect(rejection.reason == .strategyVersionNotFound)
        }
    }

    @Test("PRE-3: Zero budget rejection")
    func zeroBudget() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(),
            purpose: ContextPurpose("explain"),
            budget: 0
        )
        let result = await service.assemble(request)
        switch result {
        case .success:
            Issue.record("Should have been rejected")
        case .rejected(let rejection):
            #expect(rejection.reason == .invalidBudget)
        }
    }

    @Test("PRE-3: Negative budget rejection")
    func negativeBudget() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(),
            purpose: ContextPurpose("explain"),
            budget: -5
        )
        let result = await service.assemble(request)
        switch result {
        case .success:
            Issue.record("Should have been rejected")
        case .rejected(let rejection):
            #expect(rejection.reason == .invalidBudget)
        }
    }
}

// MARK: — Empty Evidence Tests

@Suite("Empty Evidence")
struct EmptyEvidenceTests {

    @Test("FM-1: Empty evidence produces valid empty frame")
    func emptyEvidenceProducesEmptyFrame() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: []),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.strata.allSatisfy { $0.units.isEmpty })
            #expect(frame.metadata.selectedCount == 0)
            #expect(frame.metadata.degradationLevel == .empty)
            #expect(frame.budgetSummary.used == 0)
        case .rejected:
            Issue.record("Empty evidence should produce a valid frame, not rejection")
        }
    }
}

// MARK: — Stratum Selection Tests

@Suite("Stratum Selection")
struct StratumSelectionTests {

    @Test("Units assigned to correct strata by stage criteria")
    func stratumAssignment() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct, distance: 0),
            makeAnnotatedUnit(id: 2, stage: .direct, distance: 1),
            makeAnnotatedUnit(id: 3, stage: .relational, distance: 1),
            makeAnnotatedUnit(id: 4, stage: .relational, distance: 2),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let coreIDs = frame.strata.first(where: { $0.name == "core" })!.units.map(\.annotatedUnit.unit.id.rawValue)
            let contextIDs = frame.strata.first(where: { $0.name == "context" })!.units.map(\.annotatedUnit.unit.id.rawValue)
            #expect(coreIDs.contains(1))
            #expect(coreIDs.contains(2))
            #expect(contextIDs.contains(3))
            #expect(contextIDs.contains(4))
            #expect(frame.metadata.selectedCount == 4)
        case .rejected(let r):
            Issue.record("Should not reject: \(r.diagnostic)")
        }
    }

    @Test("CFI-2: Each unit in exactly one stratum (no duplicates)")
    func stratumPartitioning() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .relational),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            var allIDs: [UInt64] = []
            for stratum in frame.strata {
                for cu in stratum.units {
                    allIDs.append(cu.annotatedUnit.unit.id.rawValue)
                }
            }
            #expect(Set(allIDs).count == allIDs.count, "No duplicates across strata")
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CFI-6: Higher-priority strata filled first")
    func priorityOrdering() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .relational),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.strata[0].priority < frame.strata[1].priority)
            #expect(frame.strata[0].name == "core")
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Unmatched units are elided")
    func unmatchedUnitsElided() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // Scope units don't match either stratum (direct or relational).
        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .scope),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.selectedCount == 1)
            #expect(frame.metadata.elisionCount == 1)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Budget Enforcement Tests

@Suite("Budget Enforcement")
struct BudgetEnforcementTests {

    @Test("CFI-1: Frame never exceeds budget")
    func budgetCompliance() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // Create many units — more than the budget.
        var evidence: [AnnotatedUnit] = []
        for i in 1...20 {
            evidence.append(makeAnnotatedUnit(id: UInt64(i), stage: .direct, distance: i))
        }

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 5
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.budgetSummary.used <= frame.budgetSummary.total)
            #expect(frame.metadata.selectedCount <= 5)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Budget overflow flows from higher to lower strata")
    func budgetOverflow() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // Only relational units — core stratum gets nothing, all budget overflows to context.
        var evidence: [AnnotatedUnit] = []
        for i in 1...10 {
            evidence.append(makeAnnotatedUnit(id: UInt64(i), stage: .relational, distance: i))
        }

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 8
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let coreStratum = frame.strata.first(where: { $0.name == "core" })!
            let contextStratum = frame.strata.first(where: { $0.name == "context" })!
            #expect(coreStratum.units.isEmpty)
            // Context should receive overflow from core's unused budget.
            #expect(contextStratum.units.count <= 8)
            #expect(contextStratum.units.count > 0)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Budget utilization reported in summary")
    func budgetUtilization() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .relational),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.budgetSummary.total == 100)
            #expect(frame.budgetSummary.used == 2)
            #expect(frame.budgetSummary.utilization > 0.0)
            #expect(frame.budgetSummary.utilization < 1.0)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Fill Policy Tests

@Suite("Fill Policy")
struct FillPolicyTests {

    @Test("CFI-9: Distance-first ordering within stratum")
    func distanceFirstOrdering() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct, distance: 3),
            makeAnnotatedUnit(id: 2, stage: .direct, distance: 1),
            makeAnnotatedUnit(id: 3, stage: .direct, distance: 2),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let coreUnits = frame.strata.first(where: { $0.name == "core" })!.units
            let distances = coreUnits.map(\.annotatedUnit.distance)
            #expect(distances == [1, 2, 3])
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CFI-9: Tier-first ordering within stratum")
    func tierFirstOrdering() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("tier-test"),
            strata: [
                StratumDefinition(
                    name: "all",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .tierFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        let evidence = [
            makeAnnotatedUnit(id: 1, tier: .t0, confidence: .deterministic, stage: .direct),
            makeAnnotatedUnit(id: 2, tier: .t2, confidence: .high, stage: .direct),
            makeAnnotatedUnit(id: 3, tier: .t1, confidence: .high, stage: .direct),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("tier-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let tiers = frame.strata[0].units.map(\.annotatedUnit.unit.tier)
            #expect(tiers == [.t2, .t1, .t0])
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CFI-9: Confidence-first ordering within stratum")
    func confidenceFirstOrdering() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("conf-test"),
            strata: [
                StratumDefinition(
                    name: "all",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .confidenceFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        let evidence = [
            makeAnnotatedUnit(id: 1, tier: .t1, confidence: .low, stage: .direct),
            makeAnnotatedUnit(id: 2, tier: .t1, confidence: .high, stage: .direct),
            makeAnnotatedUnit(id: 3, tier: .t1, confidence: .moderate, stage: .direct),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("conf-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let confs = frame.strata[0].units.map(\.annotatedUnit.unit.confidence)
            #expect(confs == [.high, .moderate, .low])
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Tie-breaking by ascending unit ID")
    func tieBreakByUnitID() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // Same distance — tie broken by unit ID ascending.
        let evidence = [
            makeAnnotatedUnit(id: 5, stage: .direct, distance: 0),
            makeAnnotatedUnit(id: 2, stage: .direct, distance: 0),
            makeAnnotatedUnit(id: 8, stage: .direct, distance: 0),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let ids = frame.strata.first(where: { $0.name == "core" })!.units.map(\.annotatedUnit.unit.id.rawValue)
            #expect(ids == [2, 5, 8])
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Selection Criteria Tests

@Suite("Selection Criteria")
struct SelectionCriteriaTests {

    @Test("Stage filter matches correctly")
    func stageFilter() {
        let criteria = SelectionCriteria(stage: .direct)
        let directUnit = makeAnnotatedUnit(id: 1, stage: .direct)
        let relationalUnit = makeAnnotatedUnit(id: 2, stage: .relational)
        #expect(criteria.matches(directUnit))
        #expect(!criteria.matches(relationalUnit))
    }

    @Test("Predicate domain filter matches correctly")
    func predicateDomainFilter() {
        let criteria = SelectionCriteria(predicateDomains: Set(["structure"]))
        let structureUnit = makeAnnotatedUnit(id: 1, domain: "structure")
        let behaviorUnit = makeAnnotatedUnit(id: 2, domain: "behavior")
        #expect(criteria.matches(structureUnit))
        #expect(!criteria.matches(behaviorUnit))
    }

    @Test("Distance filter matches correctly")
    func distanceFilter() {
        let criteria = SelectionCriteria(maxDistance: 2)
        let closeUnit = makeAnnotatedUnit(id: 1, distance: 1)
        let farUnit = makeAnnotatedUnit(id: 2, distance: 5)
        #expect(criteria.matches(closeUnit))
        #expect(!criteria.matches(farUnit))
    }

    @Test("Tier range filter matches correctly")
    func tierRangeFilter() {
        let criteria = SelectionCriteria(minTier: .t0, maxTier: .t1)
        let t0Unit = makeAnnotatedUnit(id: 1, tier: .t0, confidence: .deterministic)
        let t1Unit = makeAnnotatedUnit(id: 2, tier: .t1, confidence: .high)
        let t2Unit = makeAnnotatedUnit(id: 3, tier: .t2, confidence: .high)
        #expect(criteria.matches(t0Unit))
        #expect(criteria.matches(t1Unit))
        #expect(!criteria.matches(t2Unit))
    }

    @Test("Confidence filter matches correctly")
    func confidenceFilter() {
        let criteria = SelectionCriteria(minConfidence: .moderate)
        let highUnit = makeAnnotatedUnit(id: 1, tier: .t1, confidence: .high)
        let lowUnit = makeAnnotatedUnit(id: 2, tier: .t1, confidence: .low)
        #expect(criteria.matches(highUnit))
        #expect(!criteria.matches(lowUnit))
    }

    @Test("Conjunctive criteria — all must match")
    func conjunctiveCriteria() {
        let criteria = SelectionCriteria(
            stage: .direct,
            predicateDomains: Set(["structure"]),
            maxDistance: 2
        )
        // Matches all.
        let matching = makeAnnotatedUnit(id: 1, domain: "structure", stage: .direct, distance: 1)
        // Wrong stage.
        let wrongStage = makeAnnotatedUnit(id: 2, domain: "structure", stage: .relational, distance: 1)
        // Wrong domain.
        let wrongDomain = makeAnnotatedUnit(id: 3, domain: "behavior", stage: .direct, distance: 1)

        #expect(criteria.matches(matching))
        #expect(!criteria.matches(wrongStage))
        #expect(!criteria.matches(wrongDomain))
    }
}

// MARK: — Coherence Tests

@Suite("Coherence Enforcement")
struct CoherenceTests {

    @Test("CFI-3: Coherence constraint satisfied when both units present")
    func coherenceSatisfied() async {
        let service = ContextAssemblyService()
        // Two strata: direct and relational, with coherence requiring relational
        // when direct is selected.
        let strategy = ContextStrategy(
            purpose: ContextPurpose("coherence-test"),
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5,
                    fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "relational",
                    priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.5,
                    fillPolicy: .distanceFirst
                ),
            ],
            coherenceConstraints: [
                CoherenceConstraint(
                    name: "direct-needs-relational",
                    triggerCriteria: SelectionCriteria(stage: .direct),
                    requirementCriteria: SelectionCriteria(stage: .relational)
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct, distance: 0),
            makeAnnotatedUnit(id: 2, stage: .relational, distance: 1),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("coherence-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.selectedCount == 2)
            #expect(frame.metadata.coherenceStatistics.retracted == 0)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CFI-3: Coherence retraction when required unit absent")
    func coherenceRetraction() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("retraction-test"),
            strata: [
                StratumDefinition(
                    name: "all",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst
                ),
            ],
            coherenceConstraints: [
                CoherenceConstraint(
                    name: "direct-needs-scope",
                    triggerCriteria: SelectionCriteria(stage: .direct),
                    requirementCriteria: SelectionCriteria(stage: .scope)
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        // Only direct units — no scope units exist.
        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct, distance: 0),
            makeAnnotatedUnit(id: 2, stage: .relational, distance: 1),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("retraction-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            // Direct unit should be retracted because no scope unit exists.
            let allIDs = frame.strata.flatMap(\.units).map(\.annotatedUnit.unit.id.rawValue)
            #expect(!allIDs.contains(1), "Triggering unit should be retracted")
            #expect(frame.metadata.coherenceStatistics.retracted > 0)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Determinism Tests

@Suite("Determinism")
struct DeterminismTests {

    @Test("CFI-4: Same inputs produce same frame")
    func deterministicAssembly() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        var evidence: [AnnotatedUnit] = []
        for i: UInt64 in 1...10 {
            evidence.append(makeAnnotatedUnit(id: i, stage: i <= 5 ? .direct : .relational, distance: Int(i)))
        }
        let evidenceSet = makeEvidenceSet(evidence: evidence)

        let request = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: ContextPurpose("explain"),
            budget: 7
        )

        let result1 = await service.assemble(request)
        let result2 = await service.assemble(request)

        switch (result1, result2) {
        case (.success(let frame1), .success(let frame2)):
            // Same units in same order.
            let ids1 = frame1.strata.flatMap(\.units).map(\.annotatedUnit.unit.id.rawValue)
            let ids2 = frame2.strata.flatMap(\.units).map(\.annotatedUnit.unit.id.rawValue)
            #expect(ids1 == ids2)
            // Same metadata (except duration).
            #expect(frame1.metadata.selectedCount == frame2.metadata.selectedCount)
            #expect(frame1.metadata.elisionCount == frame2.metadata.elisionCount)
            #expect(frame1.metadata.tierCounts == frame2.metadata.tierCounts)
            #expect(frame1.metadata.stratumCounts == frame2.metadata.stratumCounts)
        default:
            Issue.record("Both assemblies should succeed")
        }
    }
}

// MARK: — Grounding Integrity Tests

@Suite("Grounding Integrity")
struct GroundingIntegrityTests {

    @Test("CFI-5: Grounding chains pass through unmodified")
    func groundingPreserved() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .relational),
        ]
        let evidenceSet = makeEvidenceSet(evidence: evidence)

        let request = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            for cu in frame.strata.flatMap(\.units) {
                // Find the original in the evidence set.
                let original = evidenceSet.evidence.first { $0.unit.id == cu.annotatedUnit.unit.id }!
                #expect(cu.annotatedUnit.unit.grounding == original.unit.grounding)
            }
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CFI-7: All units originate from evidence set")
    func evidenceSoundness() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .relational),
        ]
        let evidenceSet = makeEvidenceSet(evidence: evidence)
        let evidenceIDs = Set(evidenceSet.evidence.map(\.unit.id))

        let request = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            for cu in frame.strata.flatMap(\.units) {
                #expect(evidenceIDs.contains(cu.annotatedUnit.unit.id))
            }
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Metadata Tests

@Suite("Metadata Assembly")
struct MetadataTests {

    @Test("Metadata reports correct tier counts")
    func tierCounts() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("meta-test"),
            strata: [
                StratumDefinition(
                    name: "all",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        let evidence = [
            makeAnnotatedUnit(id: 1, tier: .t0, confidence: .deterministic, stage: .direct),
            makeAnnotatedUnit(id: 2, tier: .t0, confidence: .deterministic, stage: .direct, distance: 1),
            makeAnnotatedUnit(id: 3, tier: .t1, confidence: .high, stage: .direct, distance: 2),
            makeAnnotatedUnit(id: 4, tier: .t2, confidence: .moderate, stage: .direct, distance: 3),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("meta-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.tierCounts[.t0] == 2)
            #expect(frame.metadata.tierCounts[.t1] == 1)
            #expect(frame.metadata.tierCounts[.t2] == 1)
            #expect(frame.metadata.degradationLevel == .full)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("FM-5: Degradation level reflects absent tiers")
    func degradationLevel() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("degrade-test"),
            strata: [
                StratumDefinition(
                    name: "all",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        // Only T0 evidence.
        let evidence = [
            makeAnnotatedUnit(id: 1, tier: .t0, confidence: .deterministic, stage: .direct),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("degrade-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.degradationLevel == .t0Only)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Freshness state reflects fallback families")
    func freshnessState() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [makeAnnotatedUnit(id: 1, stage: .direct)]
        let evidenceSet = EvidenceSet(
            anchors: [EntityReference(qualifiedName: "Test")],
            request: RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "Test")),
                intent: .explain
            ),
            evidence: evidence,
            metadata: EvidenceSetMetadata(
                completedStages: [.direct],
                truncatedStages: [],
                budgetAllocated: 500,
                budgetConsumed: 1,
                fallbackFamilies: [.entity, .graph],
                availableTiers: [.t0],
                absentTiers: [.t1, .t2],
                observedEpoch: makeEpoch(5),
                excludedUnitCount: 0,
                subjectNotFound: false
            )
        )
        let request = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.freshnessState == .partiallyStale)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CFI-8: Epoch consistency — committed epoch from evidence set")
    func epochConsistency() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [makeAnnotatedUnit(id: 1, stage: .direct)]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence, epoch: 42),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.committedEpoch == makeEpoch(42))
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Assembly duration is positive")
    func assemblyDuration() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [makeAnnotatedUnit(id: 1, stage: .direct)]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.assemblyDuration >= 0)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Elision ratio computed correctly")
    func elisionRatio() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // 10 direct units, budget of 3.
        var evidence: [AnnotatedUnit] = []
        for i: UInt64 in 1...10 {
            evidence.append(makeAnnotatedUnit(id: i, stage: .direct, distance: Int(i)))
        }
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 3
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.evidenceSetSize == 10)
            #expect(frame.metadata.selectedCount <= 3)
            #expect(frame.metadata.elisionCount >= 7)
            #expect(frame.metadata.elisionRatio > 0.5)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Context Frame Contract Tests

@Suite("Context Frame Contract")
struct ContextFrameContractTests {

    @Test("CF-R1: Anchors preserved from evidence set")
    func anchorsPreserved() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let anchors = [
            EntityReference(qualifiedName: "Anchor1"),
            EntityReference(qualifiedName: "Anchor2"),
        ]
        let evidence = [makeAnnotatedUnit(id: 1, stage: .direct)]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence, anchors: anchors),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.anchors == anchors)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CF-R2: Purpose matches request")
    func purposeMatches() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: [makeAnnotatedUnit(id: 1, stage: .direct)]),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.purpose == ContextPurpose("explain"))
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CF-R3: Strategy version recorded")
    func strategyVersionRecorded() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy(version: "3.5"))

        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: [makeAnnotatedUnit(id: 1, stage: .direct)]),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.strategyVersion == "3.5")
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CF-R4: Empty strata included with zero units")
    func emptyStrataIncluded() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // Only direct units — context stratum (relational) will be empty.
        let evidence = [makeAnnotatedUnit(id: 1, stage: .direct)]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.strata.count == 2)
            let contextStratum = frame.strata.first(where: { $0.name == "context" })!
            #expect(contextStratum.units.isEmpty)
            #expect(contextStratum.budgetUsed == 0)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("CF-R5: Every context unit has a context role")
    func contextRolePresent() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct),
            makeAnnotatedUnit(id: 2, stage: .relational),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            for cu in frame.strata.flatMap(\.units) {
                #expect(!cu.role.stratumName.isEmpty)
                #expect(!cu.role.reason.isEmpty)
            }
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Token Budget Tests

@Suite("Token Budget")
struct TokenBudgetTests {

    @Test("Token budget uses conservative estimation")
    func tokenBudgetEstimation() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("token-test"),
            strata: [
                StratumDefinition(
                    name: "all",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        // Create units with string values of known size.
        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct, value: .string("short")),
            makeAnnotatedUnit(id: 2, stage: .direct, distance: 1, value: .string(String(repeating: "a", count: 300))),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("token-test"),
            budget: 50,
            denomination: .tokens
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            // Both units should fit in token budget of 50.
            #expect(frame.budgetSummary.denomination == .tokens)
            #expect(frame.budgetSummary.used <= 50)
        case .rejected:
            Issue.record("Should not reject")
        }
    }

    @Test("Unit count budget: each unit costs exactly 1")
    func unitCountBudget() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        var evidence: [AnnotatedUnit] = []
        for i: UInt64 in 1...5 {
            evidence.append(makeAnnotatedUnit(id: i, stage: .direct, distance: Int(i)))
        }
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 3,
            denomination: .unitCount
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.budgetSummary.used <= 3)
            #expect(frame.metadata.selectedCount <= 3)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Predicate Domain Strategy Tests

@Suite("Predicate Domain Strategy")
struct PredicateDomainTests {

    @Test("Domain-based strata correctly partition evidence")
    func domainBasedPartition() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("domain-test"),
            strata: [
                StratumDefinition(
                    name: "structure",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(predicateDomains: Set(["structure"])),
                    budgetFraction: 0.6,
                    fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "behavior",
                    priority: 2,
                    selectionCriteria: SelectionCriteria(predicateDomains: Set(["behavior"])),
                    budgetFraction: 0.4,
                    fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        let evidence = [
            makeAnnotatedUnit(id: 1, domain: "structure"),
            makeAnnotatedUnit(id: 2, domain: "behavior"),
            makeAnnotatedUnit(id: 3, domain: "structure", distance: 1),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("domain-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            let structureUnits = frame.strata.first(where: { $0.name == "structure" })!.units
            let behaviorUnits = frame.strata.first(where: { $0.name == "behavior" })!.units
            #expect(structureUnits.count == 2)
            #expect(behaviorUnits.count == 1)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Three-Stratum Strategy Tests

@Suite("Three-Stratum Strategy")
struct ThreeStratumTests {

    @Test("Three-stratum strategy with scope evidence")
    func threeStrataAssembly() async {
        let service = ContextAssemblyService()
        let strategy = ContextStrategy(
            purpose: ContextPurpose("three-test"),
            strata: [
                StratumDefinition(
                    name: "core", priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "relations", priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.3, fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "scope", priority: 3,
                    selectionCriteria: SelectionCriteria(stage: .scope),
                    budgetFraction: 0.2, fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0"
        )
        _ = service.register(strategy)

        let evidence = [
            makeAnnotatedUnit(id: 1, stage: .direct, distance: 0),
            makeAnnotatedUnit(id: 2, stage: .relational, distance: 1),
            makeAnnotatedUnit(id: 3, stage: .scope, distance: 2),
        ]
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("three-test"),
            budget: 100
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.strata.count == 3)
            #expect(frame.metadata.selectedCount == 3)
            #expect(frame.strata[0].name == "core")
            #expect(frame.strata[1].name == "relations")
            #expect(frame.strata[2].name == "scope")
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Large Evidence Set Tests

@Suite("Large Evidence Set")
struct LargeEvidenceSetTests {

    @Test("FM-6: High elision ratio handled correctly")
    func highElisionRatio() async {
        let service = ContextAssemblyService()
        _ = service.register(makeSimpleStrategy())

        // 100 units, budget of 5.
        var evidence: [AnnotatedUnit] = []
        for i: UInt64 in 1...50 {
            evidence.append(makeAnnotatedUnit(
                id: i,
                stage: .direct,
                distance: Int(i)
            ))
        }
        for i: UInt64 in 51...100 {
            evidence.append(makeAnnotatedUnit(
                id: i,
                stage: .relational,
                distance: Int(i - 50)
            ))
        }
        let request = AssemblyRequest(
            evidenceSet: makeEvidenceSet(evidence: evidence),
            purpose: ContextPurpose("explain"),
            budget: 5
        )
        let result = await service.assemble(request)
        switch result {
        case .success(let frame):
            #expect(frame.metadata.elisionRatio > 0.9)
            #expect(frame.budgetSummary.used <= 5)
            #expect(frame.metadata.selectedCount <= 5)
        case .rejected:
            Issue.record("Should not reject")
        }
    }
}

// MARK: — Context Assembly State Tests

@Suite("Context Assembly State")
struct ContextAssemblyStateTests {

    @Test("State transitions validated")
    func stateTransitions() {
        let s = ContextAssemblyState.unavailable
        #expect(s.canTransition(to: .available))
        #expect(!s.canTransition(to: .terminated))

        let a = ContextAssemblyState.available
        #expect(a.canTransition(to: .terminated))
        #expect(!a.canTransition(to: .unavailable))

        let t = ContextAssemblyState.terminated
        #expect(!t.canTransition(to: .available))
        #expect(!t.canTransition(to: .unavailable))
    }
}

// MARK: — Stratum Definition Sort Tests

@Suite("Strategy Sorted Strata")
struct StratumSortTests {

    @Test("sortedStrata returns by ascending priority")
    func sortedStrata() {
        let strategy = ContextStrategy(
            purpose: ContextPurpose("test"),
            strata: [
                StratumDefinition(name: "low", priority: 3, selectionCriteria: SelectionCriteria(stage: .scope), budgetFraction: 0.2, fillPolicy: .distanceFirst),
                StratumDefinition(name: "high", priority: 1, selectionCriteria: SelectionCriteria(stage: .direct), budgetFraction: 0.5, fillPolicy: .distanceFirst),
                StratumDefinition(name: "mid", priority: 2, selectionCriteria: SelectionCriteria(stage: .relational), budgetFraction: 0.3, fillPolicy: .distanceFirst),
            ],
            version: "1.0"
        )
        let sorted = strategy.sortedStrata
        #expect(sorted.map(\.name) == ["high", "mid", "low"])
    }
}
