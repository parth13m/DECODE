// RetrievalTypes.swift — RetrievalRuntime
// DDS-005: Retrieval Runtime types
// DAS-008: RetrievalRequest, EvidenceSet, AnnotatedUnit contracts

import Foundation
import DIRCore
import IndexRuntime

// MARK: — Subject Reference

/// How a retrieval request identifies its subject.
///
/// DDS-005 PC-2: Anchor resolution resolves these to concrete entity anchors.
public enum SubjectReference: Hashable, Sendable {
    /// A direct entity reference — resolved via Entity Index lookup.
    case entity(EntityReference)

    /// A snippet defined by file path and line range — resolved by identifying
    /// the entity whose source range contains the snippet position.
    case snippet(SnippetReference)

    /// A scope reference (file, module, system) — resolved via Scope Index.
    case scope(EntityReference)
}

/// A snippet identified by source file and line range.
///
/// DDS-005 PC-2: Used for anchor resolution. The retrieval runtime identifies
/// the entity whose source range contains this position.
public struct SnippetReference: Hashable, Sendable {
    /// Path to the source file.
    public let filePath: String

    /// Start line (1-based, inclusive).
    public let startLine: Int

    /// End line (1-based, inclusive).
    public let endLine: Int

    public init(filePath: String, startLine: Int, endLine: Int) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
    }
}

// MARK: — Retrieval Intent

/// Determines how the five-stage pipeline is parameterized.
///
/// DDS-005: Intent determines query plan parameterization — which predicates
/// to traverse, traversal depth, budget allocation weights, tier preference.
/// Intent does not change stage structure.
public enum RetrievalIntent: Hashable, Sendable {
    /// Understanding what an entity is and does. Allocates more budget to direct evidence.
    case explain

    /// Understanding what an entity affects. Allocates more budget to relational evidence.
    case impact

    /// Understanding what depends on an entity (inverse traversal emphasis).
    case dependencies

    /// Broad overview — shallow traversal, balanced budget.
    case overview
}

// MARK: — Retrieval Scope

/// Controls how much scope evidence (stage 4) is gathered.
///
/// DDS-005 Stage 4: Scope breadth determines which scope levels are included.
public enum RetrievalScope: Int, Hashable, Sendable, Comparable {
    /// No scope evidence gathered (anchor only).
    case narrow = 0
    /// File-level scope properties and cross-boundary edges.
    case local = 1
    /// File-level plus module-level scope properties.
    case module = 2
    /// File, module, and system scope properties.
    case system = 3

    public static func < (lhs: RetrievalScope, rhs: RetrievalScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: — Freshness Requirement

/// How the retrieval handles Content Index staleness.
///
/// DDS-005 CF-2: Current forces DIR scan fallback for stale content queries.
/// Tolerant uses the Content Index regardless of staleness.
public enum FreshnessRequirement: Hashable, Sendable {
    /// Content Index must be current; falls back to DIR scan if stale.
    case current
    /// Content Index queried regardless of staleness; staleness disclosed in metadata.
    case tolerant
}

// MARK: — Retrieval Request

/// A structured specification of what evidence to gather from the DIR.
///
/// DDS-005 PC-1: Contains subject, intent, scope, tier range, budget, freshness.
public struct RetrievalRequest: Hashable, Sendable {
    /// What entity, snippet, or scope to gather evidence about.
    public let subject: SubjectReference

    /// How to parameterize the pipeline (which predicates, depth, budget allocation).
    public let intent: RetrievalIntent

    /// How much scope evidence to gather.
    public let scope: RetrievalScope

    /// Minimum tier to include in evidence (inclusive).
    public let tierFloor: Tier

    /// Maximum tier to include in evidence (inclusive).
    public let tierCeiling: Tier

    /// Maximum number of annotated units in the evidence set.
    public let budget: Int

    /// How to handle Content Index staleness.
    public let freshness: FreshnessRequirement

    /// Optional confidence floor — units below this confidence are excluded.
    public let confidenceFloor: Confidence?

    public init(
        subject: SubjectReference,
        intent: RetrievalIntent,
        scope: RetrievalScope = .local,
        tierFloor: Tier = .t0,
        tierCeiling: Tier = .t2,
        budget: Int = 500,
        freshness: FreshnessRequirement = .tolerant,
        confidenceFloor: Confidence? = nil
    ) {
        self.subject = subject
        self.intent = intent
        self.scope = scope
        self.tierFloor = tierFloor
        self.tierCeiling = tierCeiling
        self.budget = budget
        self.freshness = freshness
        self.confidenceFloor = confidenceFloor
    }
}

// MARK: — Evidence Provenance

/// Which pipeline stage produced an evidence unit and the structural path from anchor.
///
/// DDS-005 RI-5: Every annotated unit carries complete provenance.
public enum EvidenceStage: Int, Hashable, Sendable, Comparable {
    /// Stage 2 — direct evidence about the anchor entity.
    case direct = 0
    /// Stage 3 — evidence gathered via relationship traversal.
    case relational = 1
    /// Stage 4 — evidence about the anchor's containing scope.
    case scope = 2

    public static func < (lhs: EvidenceStage, rhs: EvidenceStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Complete provenance for an evidence unit.
///
/// DDS-005 RI-5: Stage, structural path from anchor, predicate chain for relational.
public struct EvidenceProvenance: Hashable, Sendable {
    /// Which pipeline stage produced this evidence.
    public let stage: EvidenceStage

    /// The structural path from anchor to this unit.
    /// For direct: ["direct"]. For relational: ["anchor", "calls", "target"].
    /// For scope: ["scope", scopeLevel].
    public let path: [String]

    public init(stage: EvidenceStage, path: [String]) {
        self.stage = stage
        self.path = path
    }
}

// MARK: — Annotated Unit

/// An atomic unit augmented with retrieval-specific metadata.
///
/// DDS-005: Evidence provenance, distance from anchor, tier, confidence.
public struct AnnotatedUnit: Hashable, Sendable {
    /// The underlying atomic unit from the DIR.
    public let unit: AtomicUnit

    /// Which stage produced this unit and the structural path from anchor.
    public let provenance: EvidenceProvenance

    /// Hop count from anchor (0 for direct, 1+ for relational, scope-dependent for scope).
    public let distance: Int

    public init(unit: AtomicUnit, provenance: EvidenceProvenance, distance: Int) {
        self.unit = unit
        self.provenance = provenance
        self.distance = distance
    }
}

// MARK: — Evidence Set Metadata

/// Metadata describing retrieval execution.
///
/// DDS-005 PC-1: Stages completed, budget consumed, fallbacks used, freshness state.
public struct EvidenceSetMetadata: Sendable {
    /// Which stages completed fully (not truncated by budget).
    public let completedStages: Set<EvidenceStage>

    /// Which stages were truncated by budget exhaustion.
    public let truncatedStages: Set<EvidenceStage>

    /// Total budget allocated.
    public let budgetAllocated: Int

    /// Budget consumed by evidence.
    public let budgetConsumed: Int

    /// Budget remaining after retrieval.
    public var budgetRemaining: Int { budgetAllocated - budgetConsumed }

    /// Whether truncation occurred at any stage.
    public var truncated: Bool { !truncatedStages.isEmpty }

    /// Index families that used DIR scan fallback instead of indexed query.
    public let fallbackFamilies: Set<IndexFamily>

    /// Which tiers had evidence available.
    public let availableTiers: Set<Tier>

    /// Which tiers in the request range had no evidence.
    public let absentTiers: Set<Tier>

    /// The committed epoch at which evidence was gathered.
    public let observedEpoch: Epoch

    /// Count of units excluded due to resolution failure (FM-5).
    public let excludedUnitCount: Int

    /// Whether the subject was not found (FM-1).
    public let subjectNotFound: Bool

    public init(
        completedStages: Set<EvidenceStage>,
        truncatedStages: Set<EvidenceStage>,
        budgetAllocated: Int,
        budgetConsumed: Int,
        fallbackFamilies: Set<IndexFamily>,
        availableTiers: Set<Tier>,
        absentTiers: Set<Tier>,
        observedEpoch: Epoch,
        excludedUnitCount: Int,
        subjectNotFound: Bool
    ) {
        self.completedStages = completedStages
        self.truncatedStages = truncatedStages
        self.budgetAllocated = budgetAllocated
        self.budgetConsumed = budgetConsumed
        self.fallbackFamilies = fallbackFamilies
        self.availableTiers = availableTiers
        self.absentTiers = absentTiers
        self.observedEpoch = observedEpoch
        self.excludedUnitCount = excludedUnitCount
        self.subjectNotFound = subjectNotFound
    }
}

// MARK: — Evidence Set

/// The output of a retrieval execution.
///
/// DDS-005 PC-1: Contains resolved anchors, original request, annotated units,
/// and execution metadata. Annotated units are in canonical deterministic order.
public struct EvidenceSet: Sendable {
    /// The resolved entity anchors (empty if subject not found).
    public let anchors: [EntityReference]

    /// The original retrieval request.
    public let request: RetrievalRequest

    /// Annotated units in canonical order: stage → distance → unit ID.
    public let evidence: [AnnotatedUnit]

    /// Execution metadata.
    public let metadata: EvidenceSetMetadata

    public init(
        anchors: [EntityReference],
        request: RetrievalRequest,
        evidence: [AnnotatedUnit],
        metadata: EvidenceSetMetadata
    ) {
        self.anchors = anchors
        self.request = request
        self.evidence = evidence
        self.metadata = metadata
    }
}

// MARK: — Query Plan (Internal)

/// Translates a retrieval request into concrete stage parameters.
///
/// DDS-005: Deterministic — same request always produces the same plan.
struct QueryPlan: Sendable {
    /// Budget reservations per stage.
    let directBudget: Int
    let relationalBudget: Int
    let scopeBudget: Int

    /// Traversal plan for stage 3 (relational evidence).
    let traversalPlan: TraversalPlan

    /// Tier range filter.
    let tierFloor: Tier
    let tierCeiling: Tier

    /// Confidence floor filter.
    let confidenceFloor: Confidence?

    /// Retrieval scope for stage 4.
    let scope: RetrievalScope
}

/// Parameterizes the relational evidence stage (stage 3).
///
/// DDS-005: Which predicates to follow, direction, depth, per-entity budget.
struct TraversalPlan: Sendable {
    /// Predicates to traverse with their configuration.
    let predicateConfigs: [PredicateTraversalConfig]

    /// Maximum units gathered per traversed entity.
    let perEntityBudget: Int
}

/// Configuration for traversing a single relationship predicate.
struct PredicateTraversalConfig: Sendable {
    /// The relationship predicate to follow.
    let predicate: PredicateIdentifier

    /// Traversal direction.
    let direction: TraversalDirection

    /// Maximum hop count for this predicate.
    let maxDepth: Int
}

// MARK: — Retrieval State

/// The lifecycle state of the Retrieval Runtime.
///
/// DDS-005 State Model: Unavailable → Available → Terminated.
public enum RetrievalState: String, Hashable, Sendable {
    case unavailable
    case available
    case terminated

    public func canTransition(to target: RetrievalState) -> Bool {
        switch (self, target) {
        case (.unavailable, .available): return true
        case (.available, .terminated): return true
        default: return false
        }
    }
}
