// ModuleContextStrategyTests.swift — DecodeTests
// M5/M10: Tests for project-scope context strategy integration.
// Verifies strategy definitions, purpose→scope mapping, budget allocation,
// stratum partitioning, and backward compatibility.

import Testing
import Foundation
@testable import Decode
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Strategy Definition Tests

@Suite("M10 Strategy Definitions")
struct M10StrategyDefinitionTests {

    @Test("Explain strategy is version 3.0.0 with four strata")
    func explainStrategyV3() {
        let strategy = ContextStrategies.explain
        #expect(strategy.version == "3.0.0")
        #expect(strategy.strata.count == 4)
    }

    @Test("Followup strategy is version 3.0.0 with four strata")
    func followupStrategyV3() {
        let strategy = ContextStrategies.followup
        #expect(strategy.version == "3.0.0")
        #expect(strategy.strata.count == 4)
    }

    @Test("Improve strategy is unchanged at version 1.0.0 with two strata")
    func improveStrategyUnchanged() {
        let strategy = ContextStrategies.improve
        #expect(strategy.version == "1.0.0")
        #expect(strategy.strata.count == 2)
    }

    @Test("Explain strata names are direct, relational, project, scope")
    func explainStrataNames() {
        let names = ContextStrategies.explain.strata.map(\.name)
        #expect(names.contains("direct"))
        #expect(names.contains("relational"))
        #expect(names.contains("project"))
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

    @Test("Explain project stratum is not essential")
    func explainProjectNotEssential() {
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(project.essential == false)
    }

    @Test("Improve has no project stratum")
    func improveNoProjectStratum() {
        let names = ContextStrategies.improve.strata.map(\.name)
        #expect(!names.contains("project"))
    }
}

// MARK: - Budget Allocation Tests

@Suite("M10 Budget Allocation")
struct M10BudgetAllocationTests {

    @Test("Explain direct gets 45%")
    func explainDirectBudget() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        #expect(direct.budgetFraction == 0.45)
    }

    @Test("Explain relational gets 25%")
    func explainRelationalBudget() {
        let relational = ContextStrategies.explain.strata.first { $0.name == "relational" }!
        #expect(relational.budgetFraction == 0.25)
    }

    @Test("Explain project gets 15%")
    func explainProjectBudget() {
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(project.budgetFraction == 0.15)
    }

    @Test("Explain scope gets 15%")
    func explainScopeBudget() {
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!
        #expect(scope.budgetFraction == 0.15)
    }
}

// MARK: - Stratum Priority Tests

@Suite("M10 Stratum Priorities")
struct M10StratumPriorityTests {

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

    @Test("Project is priority 2")
    func projectPriority() {
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(project.priority == 2)
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

@Suite("M10 Tier Partitioning")
struct M10TierPartitioningTests {

    @Test("Project stratum selects T1 scope evidence only")
    func projectStratumSelectsT1() {
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(project.selectionCriteria.stage == .scope)
        #expect(project.selectionCriteria.minTier == .t1)
        #expect(project.selectionCriteria.maxTier == .t1)
    }

    @Test("Scope stratum selects T0 scope evidence only")
    func scopeStratumSelectsT0() {
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!
        #expect(scope.selectionCriteria.stage == .scope)
        #expect(scope.selectionCriteria.maxTier == .t0)
    }

    @Test("Project and scope strata do not overlap (SI-2)")
    func projectScopeNoOverlap() {
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        let scope = ContextStrategies.explain.strata.first { $0.name == "scope" }!

        // Project: minTier=.t1, maxTier=.t1
        // Scope: maxTier=.t0
        // T1 > T0 → disjoint
        let projectMin = project.selectionCriteria.minTier!
        let scopeMax = scope.selectionCriteria.maxTier!
        #expect(projectMin > scopeMax)
    }

    @Test("Direct stratum is disjoint from project (different stage)")
    func directDisjointFromProject() {
        let direct = ContextStrategies.explain.strata.first { $0.name == "direct" }!
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(direct.selectionCriteria.stage == .direct)
        #expect(project.selectionCriteria.stage == .scope)
    }

    @Test("Relational stratum is disjoint from project (different stage)")
    func relationalDisjointFromProject() {
        let relational = ContextStrategies.explain.strata.first { $0.name == "relational" }!
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(relational.selectionCriteria.stage == .relational)
        #expect(project.selectionCriteria.stage == .scope)
    }
}

// MARK: - Strategy Registration Tests

@Suite("M10 Strategy Registration")
struct M10StrategyRegistrationTests {

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

@Suite("M10 Fill Policies")
struct M10FillPolicyTests {

    @Test("Project stratum uses confidenceFirst fill policy")
    func projectUsesConfidenceFirst() {
        let project = ContextStrategies.explain.strata.first { $0.name == "project" }!
        #expect(project.fillPolicy == .confidenceFirst)
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

@Suite("M10 Purpose Scope Mapping")
struct M10PurposeScopeMappingTests {

    @Test("Explain purpose defaults to system scope")
    func explainDefaultsToSystem() {
        let classification = QuestionClassifier.classify(purpose: "explain")
        #expect(classification.scope == .system)
    }

    @Test("Followup purpose defaults to system scope")
    func followupDefaultsToSystem() {
        let classification = QuestionClassifier.classify(purpose: "followup")
        #expect(classification.scope == .system)
    }

    @Test("Improve purpose maps to local scope")
    func improveMapsToLocal() {
        let classification = QuestionClassifier.classify(purpose: "improve")
        #expect(classification.scope == .local)
    }
}

// MARK: - Followup Mirrors Explain Tests

@Suite("M10 Followup Mirrors Explain")
struct M10FollowupMirrorsExplainTests {

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

@Suite("M10 Backward Compatibility")
struct M10BackwardCompatibilityTests {

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

    @Test("Explain v3 supersedes v2 when both registered")
    func explainV3SupersedesV2() {
        let assemblyService = ContextAssemblyService()

        // Register v2 first
        let v2 = ContextStrategy(
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
                    budgetFraction: 0.25,
                    fillPolicy: .distanceFirst
                ),
                StratumDefinition(
                    name: "module",
                    priority: 2,
                    selectionCriteria: SelectionCriteria(
                        stage: .scope,
                        minTier: .t1,
                        maxTier: .t1
                    ),
                    budgetFraction: 0.10,
                    fillPolicy: .confidenceFirst
                ),
                StratumDefinition(
                    name: "scope",
                    priority: 3,
                    selectionCriteria: SelectionCriteria(
                        stage: .scope,
                        maxTier: .t0
                    ),
                    budgetFraction: 0.15,
                    fillPolicy: .distanceFirst
                ),
            ],
            tierPreference: .ordering([.t0, .t1, .t2]),
            elisionPolicy: .stratumFirst,
            version: "2.0.0"
        )
        _ = assemblyService.register(v2)

        // Register v3
        _ = assemblyService.register(ContextStrategies.explain)

        let catalog = assemblyService.strategyCatalog()
        let activeExplain = catalog[ContextPurpose("explain")]!
        #expect(activeExplain.version == "3.0.0")
        #expect(activeExplain.strata.count == 4)
    }

    @Test("Elision policy is stratumFirst for all strategies")
    func elisionPolicyConsistent() {
        #expect(ContextStrategies.explain.elisionPolicy == .stratumFirst)
        #expect(ContextStrategies.followup.elisionPolicy == .stratumFirst)
        #expect(ContextStrategies.improve.elisionPolicy == .stratumFirst)
    }
}

// MARK: - Question Classifier M10 Tests

@Suite("M10 Question Classifier")
struct M10QuestionClassifierTests {

    @Test("Overview keywords route to system scope")
    func overviewKeywordsRouteToSystem() {
        let classification = QuestionClassifier.classify(
            purpose: "explain",
            questionHint: "how does this fit into the architecture?"
        )
        #expect(classification.scope == .system)
        #expect(classification.matchedRule == .overviewKeywords)
    }

    @Test("Impact keywords preserve at least system scope from baseline")
    func impactKeywordsPreserveSystemScope() {
        let classification = QuestionClassifier.classify(
            purpose: "explain",
            questionHint: "what calls this function?"
        )
        #expect(classification.scope >= .system)
    }

    @Test("Narrow keywords override to local scope")
    func narrowKeywordsOverrideToLocal() {
        let classification = QuestionClassifier.classify(
            purpose: "explain",
            questionHint: "what does this line do?"
        )
        #expect(classification.scope == .local)
        #expect(classification.matchedRule == .narrowKeywords)
    }

    @Test("Improve purpose stays local regardless of question")
    func improvePurposeStaysLocal() {
        let classification = QuestionClassifier.classify(
            purpose: "improve",
            questionHint: "improve this code"
        )
        #expect(classification.scope == .local)
    }
}
