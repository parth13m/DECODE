// AtomicUnit.swift — DIRCore
// DAS-002: All 10 fields — identity, subject, predicate, value, tier, provenance,
//          confidence, grounding, version, status
// DDS-002: R1 (unit store custody), R2 (intake validation), R4 (supersession)
// DDS-002: IM-4 — identifiers assigned at admission, not before

import Foundation

/// The 10-field atomic unit record — the fundamental element of the DIR.
///
/// All fields except `status` and lifecycle metadata are immutable after creation
/// (DAS-002 I-LC-5). To change a value, the old unit is superseded by a new unit.
///
/// Units are created exclusively by the DIR Runtime at admission time (DDS-002 PC-1).
/// The `id` is assigned at admission — units submitted for admission do not carry
/// pre-assigned identifiers (DDS-002 IM-4).
public struct AtomicUnit: Hashable, Codable, Sendable {

    // MARK: — 10 DAS-002 Fields (all immutable)

    /// Globally unique, opaque identifier assigned at admission (DAS-002 I-ID-1/2/3).
    public let id: UnitIdentifier

    /// What entity or entity pair this unit describes (DAS-002 I-SUB-1/2/3).
    public let subject: UnitSubject

    /// What property of the subject this unit asserts (DAS-002 I-PRED-1/3).
    public let predicate: PredicateIdentifier

    /// The asserted value (DAS-002 I-VAL-1/2).
    public let value: TypedValue

    /// Which tier produced this unit (DAS-003 I1/I6).
    public let tier: Tier

    /// Immutable record of what produced this unit (DAS-002 I-PROV-1/2).
    public let provenance: ProvenanceRecord

    /// Confidence level, constrained by tier (DAS-002 I-CONF-1 through I-CONF-4).
    public let confidence: Confidence

    /// Evidence chain to source material (DAS-002 I-GND-1/2/4).
    public let grounding: GroundingChain

    /// Content-addressed version of the source material (DAS-002 I-VER-1/2/3/4).
    public let version: VersionStamp

    /// Lifecycle status — the only mutable aspect of a unit (DAS-002 I-LC-1 through I-LC-5).
    public private(set) var status: UnitStatus

    // MARK: — Lifecycle Metadata

    /// Recorded when a unit transitions to Invalidated (DDS-002 PC-2, DAS-010 WR-7).
    public private(set) var invalidationMetadata: InvalidationMetadata?

    /// The identifier of the unit that superseded this one (DDS-002 PC-1 supersession).
    public private(set) var supersededBy: UnitIdentifier?

    // MARK: — Initialization

    /// Creates a new atomic unit with Active status.
    ///
    /// Used by the DIR Runtime at admission time (DDS-002 PC-1).
    /// All units are created Active (DAS-002 I-LC-1).
    public init(
        id: UnitIdentifier,
        subject: UnitSubject,
        predicate: PredicateIdentifier,
        value: TypedValue,
        tier: Tier,
        provenance: ProvenanceRecord,
        confidence: Confidence,
        grounding: GroundingChain,
        version: VersionStamp
    ) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.tier = tier
        self.provenance = provenance
        self.confidence = confidence
        self.grounding = grounding
        self.version = version
        self.status = .active
        self.invalidationMetadata = nil
        self.supersededBy = nil
    }

    // MARK: — Derived Properties

    /// The supersession key for this unit: (subject, predicate, tier).
    /// Two Active units with the same supersession key cannot coexist (DDS-002 R4).
    public var supersessionKey: SupersessionKey {
        SupersessionKey(subject: subject, predicate: predicate, tier: tier)
    }

    // MARK: — Status Transitions (DDS-002 PC-2)

    /// Transitions this unit to Invalidated status.
    ///
    /// - Precondition: Current status must be `.active` (DAS-002 I-LC-4).
    /// - Parameter metadata: The invalidation epoch and reason (DAS-010 WR-7).
    public mutating func invalidate(metadata: InvalidationMetadata) {
        precondition(status.canTransition(to: .invalidated),
                     "Invalid transition: \(status) → invalidated")
        status = .invalidated
        invalidationMetadata = metadata
    }

    /// Transitions this unit to Superseded status.
    ///
    /// - Precondition: Current status must be `.active` or `.invalidated` (DAS-002 I-LC-4).
    /// - Parameter successor: The identifier of the unit that replaces this one.
    public mutating func supersede(by successor: UnitIdentifier) {
        precondition(status.canTransition(to: .superseded),
                     "Invalid transition: \(status) → superseded")
        status = .superseded
        supersededBy = successor
    }

    /// Transitions this unit to GarbageCollected status.
    ///
    /// - Precondition: Current status must be `.superseded` or `.invalidated` (DAS-002 I-LC-4).
    public mutating func garbageCollect() {
        precondition(status.canTransition(to: .garbageCollected),
                     "Invalid transition: \(status) → garbageCollected")
        status = .garbageCollected
    }
}
