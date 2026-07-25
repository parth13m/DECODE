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
    /// DAS-009 ES-1: Three strata corresponding to the three retrieval stages
    /// (direct, relational, scope). Budget allocation follows the Explain
    /// retrieval intent's weight distribution (50/30/20).
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
    /// Follow-up questions need the same evidence scope as the original explanation
    /// so the reasoning engine can reference what was already discussed.
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

    /// All strategies to register at startup.
    static let all: [ContextStrategy] = [explain, improve, followup]
}
