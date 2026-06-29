// Transactions.swift — DIRCore
// DDS-002: PC-1 (admission), PC-2 (status transition), PC-6 (write transaction)
// DDS-002: Write transaction atomicity — all operations succeed or none applied

import Foundation

// MARK: — Unit Admission (PC-1)

/// A unit submitted for admission to the DIR.
///
/// Does NOT carry a pre-assigned identifier — the DIR Runtime assigns identifiers
/// at admission time (DDS-002 IM-4). All 10 DAS-002 fields except `id` and `status`
/// are provided by the producer. Status is always `.active` on admission (DAS-002 I-LC-1).
public struct UnitAdmission: Hashable, Codable, Sendable {
    public let subject: UnitSubject
    public let predicate: PredicateIdentifier
    public let value: TypedValue
    public let tier: Tier
    public let provenance: ProvenanceRecord
    public let confidence: Confidence
    public let grounding: GroundingChain
    public let version: VersionStamp

    public init(
        subject: UnitSubject,
        predicate: PredicateIdentifier,
        value: TypedValue,
        tier: Tier,
        provenance: ProvenanceRecord,
        confidence: Confidence,
        grounding: GroundingChain,
        version: VersionStamp
    ) {
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.tier = tier
        self.provenance = provenance
        self.confidence = confidence
        self.grounding = grounding
        self.version = version
    }
}

// MARK: — Status Transition (PC-2)

/// A request to transition an existing unit's lifecycle status.
///
/// DDS-002 PC-2: The unit must exist and the transition must be valid per the
/// lifecycle state machine. Invalidation requires metadata (epoch + reason).
public struct StatusTransition: Hashable, Codable, Sendable {
    /// The identifier of the unit to transition.
    public let unitId: UnitIdentifier

    /// The target status.
    public let targetStatus: UnitStatus

    /// Required when transitioning to `.invalidated`. Records why.
    public let invalidationMetadata: InvalidationMetadata?

    /// Required when transitioning to `.superseded`. Records the successor.
    public let supersededBy: UnitIdentifier?

    /// Create an invalidation transition.
    public static func invalidate(
        _ unitId: UnitIdentifier,
        metadata: InvalidationMetadata
    ) -> StatusTransition {
        StatusTransition(
            unitId: unitId,
            targetStatus: .invalidated,
            invalidationMetadata: metadata,
            supersededBy: nil
        )
    }

    /// Create a supersession transition.
    public static func supersede(
        _ unitId: UnitIdentifier,
        by successor: UnitIdentifier
    ) -> StatusTransition {
        StatusTransition(
            unitId: unitId,
            targetStatus: .superseded,
            invalidationMetadata: nil,
            supersededBy: successor
        )
    }

    /// Create a garbage collection transition.
    public static func garbageCollect(_ unitId: UnitIdentifier) -> StatusTransition {
        StatusTransition(
            unitId: unitId,
            targetStatus: .garbageCollected,
            invalidationMetadata: nil,
            supersededBy: nil
        )
    }
}

// MARK: — Write Transaction (PC-6)

/// A set of unit operations applied atomically to the DIR.
///
/// DDS-002 PC-6: Either all operations succeed or none are applied. Within a
/// transaction, admissions are processed before status transitions, and
/// supersession is resolved as part of admission. Units admitted earlier in the
/// transaction are visible to validation of units admitted later.
public struct WriteTransaction: Hashable, Codable, Sendable {
    /// Units to be admitted (processed in submission order).
    public let admissions: [UnitAdmission]

    /// Status transitions to apply (after all admissions).
    public let transitions: [StatusTransition]

    public init(
        admissions: [UnitAdmission] = [],
        transitions: [StatusTransition] = []
    ) {
        self.admissions = admissions
        self.transitions = transitions
    }
}

// MARK: — Write Transaction Result (PC-6)

/// The outcome of a write transaction.
///
/// DDS-002 PC-6: Either committed (all operations applied) or rejected (none applied).
public enum WriteTransactionResult: Sendable {
    /// All operations applied successfully.
    case committed(CommittedTransaction)

    /// The entire transaction was rejected. No changes applied.
    case rejected(TransactionRejection)
}

/// Details of a successfully committed write transaction.
public struct CommittedTransaction: Sendable {
    /// The epoch at which this transaction was committed.
    public let epoch: Epoch

    /// Identifiers assigned to admitted units, in admission order.
    public let admittedUnitIds: [UnitIdentifier]

    /// Units that were superseded as a side effect of admissions (DDS-002 PC-1).
    public let supersededUnitIds: [UnitIdentifier]

    /// Status transitions that were applied.
    public let appliedTransitions: [StatusTransition]

    public init(
        epoch: Epoch,
        admittedUnitIds: [UnitIdentifier],
        supersededUnitIds: [UnitIdentifier],
        appliedTransitions: [StatusTransition]
    ) {
        self.epoch = epoch
        self.admittedUnitIds = admittedUnitIds
        self.supersededUnitIds = supersededUnitIds
        self.appliedTransitions = appliedTransitions
    }
}

/// Details of a rejected write transaction.
///
/// DDS-002 PC-6: Rejection includes a diagnostic identifying all failures.
public struct TransactionRejection: Sendable {
    /// All validation failures that caused the rejection.
    public let failures: [ValidationFailure]

    public init(failures: [ValidationFailure]) {
        self.failures = failures
    }
}

/// A specific validation failure within a write transaction.
public struct ValidationFailure: Sendable {
    /// Which admission (by index) or transition caused the failure.
    public let source: FailureSource

    /// What went wrong.
    public let kind: FailureKind

    public init(source: FailureSource, kind: FailureKind) {
        self.source = source
        self.kind = kind
    }
}

/// Identifies the operation within a write transaction that failed.
public enum FailureSource: Sendable {
    /// An admission at the given index failed intake validation.
    case admission(index: Int)

    /// A status transition at the given index failed.
    case transition(index: Int)
}

/// The kind of validation failure.
public enum FailureKind: Sendable {
    /// An intake validation violation (DDS-002 PC-1, R2).
    case intakeViolation(IntakeViolation)

    /// An invalid status transition (DDS-002 PC-2).
    case invalidTransition(from: UnitStatus, to: UnitStatus)

    /// The target unit does not exist in the store.
    case unitNotFound(UnitIdentifier)
}

/// Specific intake validation violations (DDS-002 R2).
///
/// These correspond to the intake validation checks enumerated in DDS-002 PC-1.
public enum IntakeViolation: Sendable {
    /// Tier is not within {T0, T1, T2}.
    case invalidTier

    /// Tier exceeds predicate's maximum deterministic tier and predicate
    /// does not permit semantic tiers.
    case tierExceedsMDT

    /// Confidence does not conform to tier bounds (DAS-003 I2).
    case confidenceTierMismatch

    /// Provenance is incomplete (missing producer or method).
    case incompleteProvenance

    /// Grounding chain is empty.
    case emptyGrounding

    /// Grounding chain contains a cycle within the submitted batch.
    case cyclicGrounding

    /// Version stamp is missing source hashes.
    case emptyVersionStamp

    /// Value kind does not match predicate's expected value kind.
    case valueKindMismatch(expected: ValueKind, actual: ValueKind)
}
