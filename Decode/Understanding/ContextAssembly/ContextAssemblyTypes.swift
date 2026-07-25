// ContextAssemblyTypes.swift — ContextAssembly
// DDS-006: Context Assembly Runtime types
// DAS-009: ContextStrategy, ContextFrame, ContextUnit contracts

import Foundation
import DIRCore
import RetrievalRuntime

// MARK: — Context Purpose

/// Identifies the consumer purpose for which a context frame is assembled.
///
/// DDS-006 CS-R1: One purpose maps to exactly one active strategy.
public struct ContextPurpose: Hashable, Sendable {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }
}

extension ContextPurpose: CustomStringConvertible {
    public var description: String { identifier }
}

// MARK: — Budget Denomination

/// How the context budget is measured.
///
/// DDS-006: Tokens (for AI consumers) or unit count (for automated consumers).
public enum BudgetDenomination: Hashable, Sendable {
    /// Budget denominated in estimated tokens.
    case tokens
    /// Budget denominated in unit count (each unit costs 1).
    case unitCount
}

// MARK: — Fill Policy

/// How candidates within a stratum are ordered for selection.
///
/// DDS-006 CS-R2: Exactly one fill policy per stratum.
public enum FillPolicy: Hashable, Sendable {
    /// Closest evidence first (ascending distance from anchor).
    case distanceFirst
    /// Highest-tier evidence first (descending tier).
    case tierFirst
    /// Highest-confidence evidence first (descending confidence).
    case confidenceFirst
    /// Prefer entities with complete coverage across predicates.
    case entityCompleteness
}

// MARK: — Elision Policy

/// How evidence is sacrificed when the evidence set exceeds the budget.
///
/// DDS-006 CS-R5: Exactly one elision policy per strategy.
public enum ElisionPolicy: Hashable, Sendable {
    /// Lowest-priority strata emptied first before higher strata are reduced.
    case stratumFirst
    /// Within each stratum, furthest evidence is elided first.
    case distanceFirst
    /// Within each stratum, lowest-confidence evidence is elided first.
    case confidenceFirst
    /// All strata reduced proportionally.
    case proportional
}

// MARK: — Tier Preference

/// How tier evidence is prioritized within strata.
///
/// DDS-006 CS-R4: Secondary to stratum priority.
public enum TierPreference: Hashable, Sendable {
    /// Prefer evidence in the given tier ordering (first = highest priority).
    case ordering([Tier])
    /// Target a minimum ratio of each tier (fractions must sum to ≤ 1.0).
    case ratioTargets([Tier: Double])
}

// MARK: — Selection Criteria

/// Predicates over evidence annotations that determine which units belong to a stratum.
///
/// DDS-006 CS-R2: Compose conjunctively — all specified criteria must match.
public struct SelectionCriteria: Hashable, Sendable {
    /// If set, only units from this evidence stage match.
    public let stage: EvidenceStage?

    /// If set, only units with predicates in this set match.
    public let predicateDomains: Set<String>?

    /// If set, only units within this distance range match.
    public let maxDistance: Int?

    /// If set, only units at or above this tier match.
    public let minTier: Tier?

    /// If set, only units at or below this tier match.
    public let maxTier: Tier?

    /// If set, only units at or above this confidence match.
    public let minConfidence: Confidence?

    public init(
        stage: EvidenceStage? = nil,
        predicateDomains: Set<String>? = nil,
        maxDistance: Int? = nil,
        minTier: Tier? = nil,
        maxTier: Tier? = nil,
        minConfidence: Confidence? = nil
    ) {
        self.stage = stage
        self.predicateDomains = predicateDomains
        self.maxDistance = maxDistance
        self.minTier = minTier
        self.maxTier = maxTier
        self.minConfidence = minConfidence
    }

    /// Whether the given annotated unit matches all criteria.
    public func matches(_ unit: AnnotatedUnit) -> Bool {
        if let stage, unit.provenance.stage != stage { return false }
        if let domains = predicateDomains, !domains.contains(unit.unit.predicate.domain) { return false }
        if let maxDist = maxDistance, unit.distance > maxDist { return false }
        if let minT = minTier, unit.unit.tier < minT { return false }
        if let maxT = maxTier, unit.unit.tier > maxT { return false }
        if let minC = minConfidence, unit.unit.confidence < minC { return false }
        return true
    }

    /// Whether this criteria can possibly be satisfied by any valid annotated unit.
    ///
    /// DDS-006 SI-7: Detects logically unsatisfiable criteria.
    public var isSatisfiable: Bool {
        if let minT = minTier, let maxT = maxTier, minT > maxT { return false }
        return true
    }
}

// MARK: — Stratum Definition

/// A priority-ordered group of evidence within a context frame.
///
/// DDS-006 CS-R2: Each stratum specifies name, priority, selection criteria,
/// budget fraction, fill policy, and essential flag.
public struct StratumDefinition: Hashable, Sendable {
    /// Unique name within the strategy.
    public let name: String

    /// Priority: 1 = highest. Unique within the strategy.
    public let priority: Int

    /// What evidence belongs to this stratum.
    public let selectionCriteria: SelectionCriteria

    /// Fraction of total budget allocated to this stratum (0.0–1.0).
    public let budgetFraction: Double

    /// How candidates are ordered for selection.
    public let fillPolicy: FillPolicy

    /// If true, evidence in this stratum is protected from elision.
    public let essential: Bool

    public init(
        name: String,
        priority: Int,
        selectionCriteria: SelectionCriteria,
        budgetFraction: Double,
        fillPolicy: FillPolicy,
        essential: Bool = false
    ) {
        self.name = name
        self.priority = priority
        self.selectionCriteria = selectionCriteria
        self.budgetFraction = budgetFraction
        self.fillPolicy = fillPolicy
        self.essential = essential
    }
}

// MARK: — Coherence Constraint

/// A rule requiring co-occurrence of units in the context frame.
///
/// DDS-006 CS-R3: If a unit matching the trigger is included,
/// a unit matching the requirement must also be included.
public struct CoherenceConstraint: Hashable, Sendable {
    /// Identifies this constraint for diagnostics.
    public let name: String

    /// Predicate matching triggering units.
    public let triggerCriteria: SelectionCriteria

    /// Predicate matching required co-occurring units.
    public let requirementCriteria: SelectionCriteria

    public init(name: String, triggerCriteria: SelectionCriteria, requirementCriteria: SelectionCriteria) {
        self.name = name
        self.triggerCriteria = triggerCriteria
        self.requirementCriteria = requirementCriteria
    }
}

// MARK: — Context Strategy

/// A validated, versioned contract governing context assembly for a specific purpose.
///
/// DDS-006: Strategies are first-class engineering contracts — validated at registration,
/// versioned for reproducibility, immutable once registered.
public struct ContextStrategy: Sendable {
    /// The consumer purpose this strategy serves (CS-R1).
    public let purpose: ContextPurpose

    /// Ordered stratum definitions (CS-R2).
    public let strata: [StratumDefinition]

    /// Coherence constraints (CS-R3).
    public let coherenceConstraints: [CoherenceConstraint]

    /// Tier preference (CS-R4).
    public let tierPreference: TierPreference

    /// Elision policy (CS-R5).
    public let elisionPolicy: ElisionPolicy

    /// Version identifier (CS-R6).
    public let version: String

    public init(
        purpose: ContextPurpose,
        strata: [StratumDefinition],
        coherenceConstraints: [CoherenceConstraint] = [],
        tierPreference: TierPreference = .ordering([.t0, .t1, .t2]),
        elisionPolicy: ElisionPolicy = .stratumFirst,
        version: String
    ) {
        self.purpose = purpose
        self.strata = strata
        self.coherenceConstraints = coherenceConstraints
        self.tierPreference = tierPreference
        self.elisionPolicy = elisionPolicy
        self.version = version
    }

    /// Strata sorted by priority (ascending = highest priority first).
    public var sortedStrata: [StratumDefinition] {
        strata.sorted { $0.priority < $1.priority }
    }
}

// MARK: — Assembly Request

/// The input to a context assembly invocation.
///
/// DDS-006: Evidence set, context purpose, budget, optional strategy version override.
public struct AssemblyRequest: Sendable {
    /// The evidence set from DDS-005:PC-1.
    public let evidenceSet: EvidenceSet

    /// The consumer purpose.
    public let purpose: ContextPurpose

    /// The hard budget ceiling.
    public let budget: Int

    /// Budget denomination.
    public let denomination: BudgetDenomination

    /// Optional strategy version override for replay/debugging.
    public let strategyVersion: String?

    public init(
        evidenceSet: EvidenceSet,
        purpose: ContextPurpose,
        budget: Int,
        denomination: BudgetDenomination = .unitCount,
        strategyVersion: String? = nil
    ) {
        self.evidenceSet = evidenceSet
        self.purpose = purpose
        self.budget = budget
        self.denomination = denomination
        self.strategyVersion = strategyVersion
    }
}

// MARK: — Context Role

/// Why a unit was selected for the context frame.
///
/// DDS-006 CF-R5: Every context unit carries a context role.
public struct ContextRole: Hashable, Sendable {
    /// The stratum that selected this unit.
    public let stratumName: String

    /// Human-readable reason for selection.
    public let reason: String

    public init(stratumName: String, reason: String) {
        self.stratumName = stratumName
        self.reason = reason
    }
}

// MARK: — Context Unit

/// An atomic unit within a context frame, augmented with a context role.
///
/// DDS-006 CF-R5: Inherits all fields from the annotated unit without modification.
public struct ContextUnit: Hashable, Sendable {
    /// The source annotated unit (unmodified).
    public let annotatedUnit: AnnotatedUnit

    /// Why this unit was selected.
    public let role: ContextRole

    public init(annotatedUnit: AnnotatedUnit, role: ContextRole) {
        self.annotatedUnit = annotatedUnit
        self.role = role
    }
}

// MARK: — Filled Stratum

/// A stratum within a context frame, containing its selected context units.
///
/// DDS-006 CF-R4: Contains stratum name, priority, ordered units, budget info.
public struct FilledStratum: Sendable {
    /// Stratum name (matching the strategy definition).
    public let name: String

    /// Priority (matching the strategy).
    public let priority: Int

    /// Ordered context units per the fill policy.
    public let units: [ContextUnit]

    /// Budget allocated to this stratum (including overflow received).
    public let budgetAllocated: Int

    /// Budget consumed by this stratum.
    public let budgetUsed: Int

    public init(name: String, priority: Int, units: [ContextUnit], budgetAllocated: Int, budgetUsed: Int) {
        self.name = name
        self.priority = priority
        self.units = units
        self.budgetAllocated = budgetAllocated
        self.budgetUsed = budgetUsed
    }
}

// MARK: — Degradation Level

/// The tier degradation level of a context frame.
///
/// DDS-006 CF-R7: Reports which tiers are represented.
public enum DegradationLevel: String, Hashable, Sendable {
    /// All three tiers represented.
    case full
    /// T0 and T1 only (T2 absent).
    case t0t1Only
    /// T0 only (T1 and T2 absent).
    case t0Only
    /// No evidence at all.
    case empty
}

// MARK: — Freshness State

/// Context freshness inherited from evidence set metadata.
///
/// DDS-006 CFR-1: Context freshness inherits from evidence freshness.
public enum FreshnessState: String, Hashable, Sendable {
    /// All indexes were current — no fallback used.
    case fresh
    /// Some index families used DIR scan fallback.
    case partiallyStale
    /// Evidence set was gathered with significant staleness.
    case stale
}

// MARK: — Coherence Statistics

/// Statistics about coherence constraint enforcement.
///
/// DDS-006 CF-R7: Constraints fired, satisfied, and retracted.
public struct CoherenceStatistics: Sendable {
    /// Number of constraints whose trigger matched a selected unit.
    public let fired: Int
    /// Number of fired constraints that were satisfied (both units present).
    public let satisfied: Int
    /// Number of fired constraints that were retracted (triggering unit removed).
    public let retracted: Int

    public init(fired: Int, satisfied: Int, retracted: Int) {
        self.fired = fired
        self.satisfied = satisfied
        self.retracted = retracted
    }
}

// MARK: — Budget Summary

/// Budget usage summary for a context frame.
///
/// DDS-006 CF-R6: Total, used, denomination, utilization ratio.
public struct BudgetSummary: Sendable {
    /// Total budget.
    public let total: Int
    /// Budget denomination.
    public let denomination: BudgetDenomination
    /// Budget consumed.
    public let used: Int
    /// Utilization ratio (used / total).
    public var utilization: Double {
        total > 0 ? Double(used) / Double(total) : 0.0
    }

    public init(total: Int, denomination: BudgetDenomination, used: Int) {
        self.total = total
        self.denomination = denomination
        self.used = used
    }
}

// MARK: — Context Frame Metadata

/// Metadata describing a context frame's composition.
///
/// DDS-006 CF-R7: Complete assembly metrics.
public struct ContextFrameMetadata: Sendable {
    /// Total annotated units received.
    public let evidenceSetSize: Int
    /// Units selected into the frame.
    public let selectedCount: Int
    /// Units elided (evidenceSetSize - selectedCount).
    public var elisionCount: Int { evidenceSetSize - selectedCount }
    /// Elision ratio.
    public var elisionRatio: Double { evidenceSetSize > 0 ? Double(elisionCount) / Double(evidenceSetSize) : 0.0 }
    /// Per-tier unit counts in the frame.
    public let tierCounts: [Tier: Int]
    /// Per-stratum unit counts.
    public let stratumCounts: [String: Int]
    /// Coherence constraint statistics.
    public let coherenceStatistics: CoherenceStatistics
    /// Tier degradation level.
    public let degradationLevel: DegradationLevel
    /// Freshness state inherited from evidence set.
    public let freshnessState: FreshnessState
    /// Assembly duration.
    public let assemblyDuration: TimeInterval
    /// Strategy version used.
    public let strategyVersion: String
    /// Committed epoch from evidence set.
    public let committedEpoch: Epoch
    /// Whether budget was insufficient for essential evidence.
    public let budgetInsufficient: Bool

    public init(
        evidenceSetSize: Int,
        selectedCount: Int,
        tierCounts: [Tier: Int],
        stratumCounts: [String: Int],
        coherenceStatistics: CoherenceStatistics,
        degradationLevel: DegradationLevel,
        freshnessState: FreshnessState,
        assemblyDuration: TimeInterval,
        strategyVersion: String,
        committedEpoch: Epoch,
        budgetInsufficient: Bool
    ) {
        self.evidenceSetSize = evidenceSetSize
        self.selectedCount = selectedCount
        self.tierCounts = tierCounts
        self.stratumCounts = stratumCounts
        self.coherenceStatistics = coherenceStatistics
        self.degradationLevel = degradationLevel
        self.freshnessState = freshnessState
        self.assemblyDuration = assemblyDuration
        self.strategyVersion = strategyVersion
        self.committedEpoch = committedEpoch
        self.budgetInsufficient = budgetInsufficient
    }
}

// MARK: — Context Frame

/// The output of context assembly: a bounded, structured, purpose-calibrated
/// representation of evidence ready for consumption.
///
/// DDS-006 PC-1: Satisfies CFI-1 through CFI-9.
public struct ContextFrame: Sendable {
    /// Resolved entity anchors from the evidence set (CF-R1).
    public let anchors: [EntityReference]

    /// The context purpose (CF-R2).
    public let purpose: ContextPurpose

    /// Strategy identifier and version (CF-R3).
    public let strategyVersion: String

    /// Filled strata in priority order (CF-R4).
    public let strata: [FilledStratum]

    /// Budget summary (CF-R6).
    public let budgetSummary: BudgetSummary

    /// Assembly metadata (CF-R7).
    public let metadata: ContextFrameMetadata

    public init(
        anchors: [EntityReference],
        purpose: ContextPurpose,
        strategyVersion: String,
        strata: [FilledStratum],
        budgetSummary: BudgetSummary,
        metadata: ContextFrameMetadata
    ) {
        self.anchors = anchors
        self.purpose = purpose
        self.strategyVersion = strategyVersion
        self.strata = strata
        self.budgetSummary = budgetSummary
        self.metadata = metadata
    }
}

// MARK: — Assembly Result

/// The result of a context assembly invocation.
///
/// DDS-006 PC-1: Either a valid context frame or a rejection with diagnostic.
public enum AssemblyResult: Sendable {
    /// A valid context frame (possibly empty or partial).
    case success(ContextFrame)
    /// Assembly rejected — no frame produced.
    case rejected(AssemblyRejection)
}

/// Why an assembly request was rejected.
public struct AssemblyRejection: Sendable {
    /// The specific reason for rejection.
    public let reason: RejectionReason
    /// Human-readable diagnostic.
    public let diagnostic: String

    public init(reason: RejectionReason, diagnostic: String) {
        self.reason = reason
        self.diagnostic = diagnostic
    }
}

/// Rejection reasons per DDS-006 failure modes.
public enum RejectionReason: Hashable, Sendable {
    /// PRE-3: Zero or negative budget.
    case invalidBudget
    /// FM-4: No strategy for the requested purpose.
    case strategyNotFound
    /// FM-4: Specified strategy version not found.
    case strategyVersionNotFound
    /// FM-7: Evidence set malformed.
    case malformedEvidenceSet
}

// MARK: — Strategy Validation

/// Why a strategy registration was rejected.
public enum StrategyValidationError: Hashable, Sendable, Error {
    /// SI-1: Budget fractions do not sum to 1.0.
    case budgetFractionMismatch(sum: Double)
    /// SI-2: Overlapping selection criteria between strata.
    case overlappingSelectionCriteria(stratum1: String, stratum2: String)
    /// SI-3: Two strata share a priority.
    case duplicatePriority(priority: Int)
    /// SI-4: Cyclic coherence constraint graph.
    case cyclicCoherenceConstraints
    /// SI-5: More than one essential stratum.
    case multipleEssentialStrata
    /// SI-7: Stratum has unsatisfiable selection criteria.
    case unsatisfiableCriteria(stratum: String)
}

// MARK: — Context Assembly State

/// Lifecycle state of the Context Assembly Runtime.
///
/// DDS-006 State Model: Unavailable → Available → Terminated.
public enum ContextAssemblyState: String, Hashable, Sendable {
    case unavailable
    case available
    case terminated

    public func canTransition(to target: ContextAssemblyState) -> Bool {
        switch (self, target) {
        case (.unavailable, .available): return true
        case (.available, .terminated): return true
        default: return false
        }
    }
}
