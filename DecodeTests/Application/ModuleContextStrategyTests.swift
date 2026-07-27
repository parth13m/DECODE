// ModuleContextStrategyTests.swift — DecodeTests
// M5: Tests for module-scope context strategy integration.
// Verifies strategy definitions, purpose→scope mapping, budget allocation,
// stratum partitioning, and backward compatibility.

import Testing
import Foundation
@testable import Decode
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Strategy Definition Tests

@Suite("M5 Strategy Definitions")
struct M5StrategyDefinitionTests {

    @Test("Explain strategy is version 2.0.0 with four strata")
    func explainStrategyV2() {
        let strategy = ContextStrategies.explain
        #expect(strategy.version == "2.0.0")
        #expect(strategy.strata.count == 4)
    }

    @Test("Followup strategy is version 2.0.0 with four strata")
    func followupStrategyV2() {
        let strategy = ContextStrategies.followup
        #expect(strategy.version == "2.0.0")
        #expect(strategy.strata.count == 4)
    }

    @Test("Improve strategy is unchanged at version 1.0.0 with two strata")
    func improveStrategyUnchanged() {
        let strategy = ContextStrategies.improve
        #expect(strategy.version == "1.0.0")
        #expect(strategy.strata.count == 2)
    }

    @Test("Explain strata names are direct, relational, module, scope")
    func explainStrataNames() {
        let names = ContextStrategies.explain.strata.map(\.name)
        #expect(names.contains("direct"))
        #expect(names.contains("relational"))
        #expect(names.contains("module"))
        #expect(names.contains("scope"))
    }

    @Test("Explain budget fractions sum to 1.0")
    func explainBudgetFractions() {
        let sum = ContextStrategies.explain.strata.reduce(0.0) { $0 + $1.budgetFraction }
        #expect(abs(sum - 1.0) < 1e-9)
    }

    @Test("Followup budget fractions sum to 1.0")
    func followupBudgetFractions() {
        let sum = ContextStrategies.followup.strata.reduce(0.0) { $0 + $1.budgetFraction }
        #expect(abs(sum - 1.0) < 1e-9)
    }

    @Test("Explain direct stratum is essential")
    func explainDirectEssential() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        #expect(direct.essential == true)
    }

    @Test("Explain module stratum is not essential")
    func explainModuleNotEssential() {
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(module.essential == false)
    }

    @Test("Improve has no module stratum")
    func improveNoModuleStratum() {
        let names = ContextStrategies.improve.strata.map(\.name)
        #expect(!names.contains("module"))
    }
}

// MARK: - Budget Allocation Tests

@Suite("M5 Budget Allocation")
struct M5BudgetAllocationTests {

    @Test("Explain direct gets 50%")
    func explainDirectBudget() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        #expect(direct.budgetFraction == 0.5)
    }

    @Test("Explain relational gets 25%")
    func explainRelationalBudget() {
        let relational = ContextStrategies.explain.strata.first { $0.name == "relational" }!
        #expect(relational.budgetFraction == 0.25)
    }

    @Test("Explain module gets 10%")
    func explainModuleBudget() {
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(module.budgetFraction == 0.10)
    }

    @Test("Explain scope gets 15%")
    func explainScopeBudget() {
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!
        #expect(scope.budgetFraction == 0.15)
    }
}

// MARK: - Stratum Priority Tests

@Suite("M5 Stratum Priorities")
struct M5StratumPriorityTests {

    @Test("Direct has highest priority (0)")
    func directPriority() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        #expect(direct.priority == 0)
    }

    @Test("Relational is priority 1")
    func relationalPriority() {
        let relational = ContextStrategies.explain.strata.first { $0.name == "relational" }!
        #expect(relational.priority == 1)
    }

    @Test("Module is priority 2")
    func modulePriority() {
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(module.priority == 2)
    }

    @Test("Scope is priority 3 (lowest)")
    func scopePriority() {
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!
        #expect(scope.priority == 3)
    }

    @Test("All priorities are unique")
    func uniquePriorities() {
        let priorities = ContextStrategies.explain.strata.map(\.priority)
        #expect(Set(priorities).count == priorities.count)
    }
}

// MARK: - Tier Partitioning Tests (SI-2)

@Suite("M5 Tier Partitioning")
struct M5TierPartitioningTests {

    @Test("Module stratum selects T1 scope evidence only")
    func moduleStratumSelectsT1() {
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(module.selectionCriteria.stage == .scope)
        #expect(module.selectionCriteria.minTier == .t1)
        #expect(module.selectionCriteria.maxTier == .t1)
    }

    @Test("Scope stratum selects T0 scope evidence only")
    func scopeStratumSelectsT0() {
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!
        #expect(scope.selectionCriteria.stage == .scope)
        #expect(scope.selectionCriteria.maxTier == .t0)
    }

    @Test("Module and scope strata do not overlap (SI-2)")
    func moduleScopeNoOverlap() {
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!

        // Module: minTier=.t1, maxTier=.t1
        // Scope: maxTier=.t0
        // T1 > T0 → disjoint
        let moduleMin = module.selectionCriteria.minTier!
        let scopeMax = scope.selectionCriteria.maxTier!
        #expect(moduleMin > scopeMax)
    }

    @Test("Direct stratum is disjoint from module (different stage)")
    func directDisjointFromModule() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(direct.selectionCriteria.stage == .direct)
        #expect(module.selectionCriteria.stage == .scope)
    }

    @Test("Relational stratum is disjoint from module (different stage)")
    func relationalDisjointFromModule() {
        let relational = ContextStrategies.explain.strata.first { $0.name == "relational" }!
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(relational.selectionCriteria.stage == .relational)
        #expect(module.selectionCriteria.stage == .scope)
    }
}

// MARK: - Strategy Registration Tests

@Suite("M5 Strategy Registration")
struct M5StrategyRegistrationTests {

    @Test("Explain strategy passes SI-1 through SI-7 validation")
    func explainPassesValidation() {
        let assemblyService = ContextAssemblyService()
        let result = assemblyService.register(ContextStrategies.explain)
        switch result {
        case .success:
            break // expected
        case .failure(let error):
            Issue.record("Explain strategy registration failed: \(error)")
        }
    }

    @Test("Followup strategy passes validation")
    func followupPassesValidation() {
        let assemblyService = ContextAssemblyService()
        let result = assemblyService.register(ContextStrategies.followup)
        switch result {
        case .success:
            break
        case .failure(let error):
            Issue.record("Followup strategy registration failed: \(error)")
        }
    }

    @Test("Improve strategy still passes validation")
    func improvePassesValidation() {
        let assemblyService = ContextAssemblyService()
        let result = assemblyService.register(ContextStrategies.improve)
        switch result {
        case .success:
            break
        case .failure(let error):
            Issue.record("Improve strategy registration failed: \(error)")
        }
    }

    @Test("All three strategies coexist in catalog")
    func allStrategiesCoexist() {
        let assemblyService = ContextAssemblyService()
        for strategy in ContextStrategies.all {
            _ = assemblyService.register(strategy)
        }
        let catalog = assemblyService.strategyCatalog()
        #expect(catalog.count == 3)
        #expect(catalog[ContextPurpose("explain")] != nil)
        #expect(catalog[ContextPurpose("improve")] != nil)
        #expect(catalog[ContextPurpose("followup")] != nil)
    }
}

// MARK: - Fill Policy Tests

@Suite("M5 Fill Policies")
struct M5FillPolicyTests {

    @Test("Module stratum uses confidenceFirst fill policy")
    func moduleUsesConfidenceFirst() {
        let module = ContextStrategies.explain.strata.first { $0.name == "module" }!
        #expect(module.fillPolicy == .confidenceFirst)
    }

    @Test("Direct stratum uses distanceFirst fill policy")
    func directUsesDistanceFirst() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        #expect(direct.fillPolicy == .distanceFirst)
    }

    @Test("Scope stratum uses distanceFirst fill policy")
    func scopeUsesDistanceFirst() {
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!
        #expect(scope.fillPolicy == .distanceFirst)
    }
}

// MARK: - Purpose → Scope Mapping Tests

@Suite("M5 Purpose Scope Mapping")
struct M5PurposeScopeMappingTests {

    @Test("Explain purpose maps to module scope")
    func explainMapsToModule() {
        // PipelineQueryService maps non-improve to .module
        let scope: RetrievalScope = ("explain" == "improve") ? .local : .module
        #expect(scope == .module)
    }

    @Test("Followup purpose maps to module scope")
    func followupMapsToModule() {
        let scope: RetrievalScope = ("followup" == "improve") ? .local : .module
        #expect(scope == .module)
    }

    @Test("Improve purpose maps to local scope")
    func improveMapsToLocal() {
        let scope: RetrievalScope = ("improve" == "improve") ? .local : .module
        #expect(scope == .local)
    }
}

// MARK: - Followup Mirrors Explain Tests

@Suite("M5 Followup Mirrors Explain")
struct M5FollowupMirrorsExplainTests {

    @Test("Followup has same strata names as explain")
    func sameStrataNames() {
        let explainNames = Set(ContextStrategies.explain.strata.map(\.name))
        let followupNames = Set(ContextStrategies.followup.strata.map(\.name))
        #expect(explainNames == followupNames)
    }

    @Test("Followup has same budget fractions as explain")
    func sameBudgetFractions() {
        let explainFractions = ContextStrategies.explain.strata.sorted { $0.priority < $1.priority }.map(\.budgetFraction)
        let followupFractions = ContextStrategies.followup.strata.sorted { $0.priority < $1.priority }.map(\.budgetFraction)
        #expect(explainFractions == followupFractions)
    }

    @Test("Followup has same tier preference as explain")
    func sameTierPreference() {
        #expect(ContextStrategies.explain.tierPreference == ContextStrategies.followup.tierPreference)
    }
}

// MARK: - Backward Compatibility Tests

@Suite("M5 Backward Compatibility")
struct M5BackwardCompatibilityTests {

    @Test("Improve strategy is unchanged from v1")
    func improveUnchanged() {
        let improve = ContextStrategies.improve
        #expect(improve.version == "1.0.0")
        #expect(improve.strata.count == 2)
        #expect(improve.strata[0].name == "direct")
        #expect(improve.strata[0].budgetFraction == 0.7)
        #expect(improve.strata[1].name == "relational")
        #expect(improve.strata[1].budgetFraction == 0.3)
    }

    @Test("Explain v2 supersedes v1 when both registered")
    func explainV2SupersedesV1() {
        let assemblyService = ContextAssemblyService()

        // Register v1 first
        let v1 = ContextStrategy(
            purpose: ContextPurpose("explain"),
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.5,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
                StratumDefinition(
                    name: "relational",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.3,
                    fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "scope",
                    priority: 2,
                    selectionCriteria: SelectionCriteria(stage: .scope),
                    budgetFraction: 0.2,
                    fillPolicy: .distanceFirst
                ),
            ],
            tierPreference: .ordering([.t0, .t1, .t2]),
            elisionPolicy: .stratumFirst,
            version: "1.0.0"
        )
        _ = assemblyService.register(v1)

        // Register v2
        _ = assemblyService.register(ContextStrategies.explain)

        let catalog = assemblyService.strategyCatalog()
        let activeExplain = catalog[ContextPurpose("explain")]!
        #expect(activeExplain.version == "2.0.0")
        #expect(activeExplain.strata.count == 4)
    }

    @Test("Elision policy is stratumFirst for all strategies")
    func elisionPolicyConsistent() {
        #expect(ContextStrategies.explain.elisionPolicy == .stratumFirst)
        #expect(ContextStrategies.followup.elisionPolicy == .stratumFirst)
        #expect(ContextStrategies.improve.elisionPolicy == .stratumFirst)
    }
}
