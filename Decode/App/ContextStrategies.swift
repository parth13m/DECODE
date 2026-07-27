// ContextStrategies.swift — Decode App
// IAG-004 §18: Production context assembly strategies for each consumer purpose.
//
// Each strategy defines how evidence is selected, prioritized, and budgeted
// for the corresponding reasoning engine (DDS-006 CS-R1).

import Foundation
import DIRCore
import ContextAssembly
import RetrievalRuntime

/// Production context assembly strategies for the three consumer purposes.
///
/// Registered at startup in `AppDependencies.performDeferredStartup()` after
/// `UnderstandingSystem.start()`. Each strategy maps to a registered
/// `ReasoningEngine` via shared `ContextPurpose`.
enum ContextStrategies {

    /// Strategy for "explain" purpose — balanced across all evidence stages.
    ///
    /// Version 2.0.0 (M5): Adds a module stratum for module-level emergent
    /// properties. Supersedes 1.0.0 (which is retained for diagnostic replay).
    /// Budget rebalanced: direct 50%, relational 25%, module 10%, scope 15%.
    ///
    /// The module stratum selects scope-stage evidence at T1 (module-level
    /// properties from ModuleBoundaryPass and ModuleEmergentPropertiesPass).
    /// The file-scope stratum selects scope-stage evidence at T0 (file-level
    /// properties from frontends). This tier-based partition satisfies SI-2.
    static let explain = ContextStrategy(
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

    /// Strategy for "improve" purpose — prioritizes direct evidence.
    ///
    /// Improvement needs the entity's own code and immediate relationships.
    /// Wider scope evidence adds noise without helping code suggestions.
    static let improve = ContextStrategy(
        purpose: ContextPurpose("improve"),
        strata: [
            StratumDefinition(
                name: "direct",
                priority: 0,
                selectionCriteria: SelectionCriteria(stage: .direct),
                budgetFraction: 0.7,
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
        ],
        tierPreference: .ordering([.t0, .t1]),
        elisionPolicy: .stratumFirst,
        version: "1.0.0"
    )

    /// Strategy for "followup" purpose — mirrors explain for consistent context.
    ///
    /// Version 2.0.0 (M5): Adds module stratum, matching explain strategy.
    /// Follow-up questions need the same evidence scope as the original
    /// explanation so the reasoning engine can reference what was discussed.
    static let followup = ContextStrategy(
        purpose: ContextPurpose("followup"),
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

    /// All strategies to register at startup.
    static let all: [ContextStrategy] = [explain, improve, followup]
}
