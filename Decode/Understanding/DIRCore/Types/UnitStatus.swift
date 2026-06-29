// UnitStatus.swift — DIRCore
// DAS-002: I-LC-1 (created as Active), I-LC-2 (invalidation triggers), I-LC-3 (supersession)
// DAS-002: I-LC-4 (transitions irreversible), I-LC-5 (only status changes)
// DDS-002: PC-2 — status transition contract

import Foundation

/// The lifecycle status of an atomic unit in the DIR.
///
/// Valid transitions (all irreversible per DAS-002 I-LC-4):
/// ```
/// Active → Invalidated       (source change, grounding collapse, producer upgrade)
/// Active → Superseded        (new unit with same supersession key admitted)
/// Invalidated → Superseded   (replacement unit admitted for invalidated unit)
/// Superseded → GarbageCollected
/// Invalidated → GarbageCollected
/// ```
public enum UnitStatus: String, Hashable, Codable, Sendable {
    /// Current and available for query, composition, and delivery.
    case active

    /// Source material has changed; the unit may no longer be correct.
    /// Remains queryable with an invalidation flag until replaced.
    case invalidated

    /// A new unit with the same supersession key has been created.
    /// Retains a reference to its successor for version history.
    case superseded

    /// Permanently removed from the unit store.
    case garbageCollected

    /// Returns whether transitioning from this status to the target is valid.
    ///
    /// DDS-002 PC-2: only permitted transitions are accepted.
    public func canTransition(to target: UnitStatus) -> Bool {
        switch (self, target) {
        case (.active, .invalidated): true
        case (.active, .superseded): true
        case (.invalidated, .superseded): true
        case (.superseded, .garbageCollected): true
        case (.invalidated, .garbageCollected): true
        default: false
        }
    }
}

/// The reason a unit was invalidated.
///
/// DDS-002 PC-2: invalidation records the reason as metadata.
/// DAS-002 I-LC-2: only these triggers are valid.
public enum InvalidationReason: Hashable, Codable, Sendable {
    /// The source material changed (content hash differs).
    case sourceChanged

    /// An upstream unit in the grounding chain was invalidated.
    case groundingCollapse(UnitIdentifier)

    /// The producer that created this unit was upgraded.
    case producerUpgrade(producer: String)
}

/// Metadata recorded when a unit is invalidated.
///
/// DDS-002 PC-2: "Invalidation records the epoch at which invalidation occurred
/// and the reason as invalidation metadata."
public struct InvalidationMetadata: Hashable, Codable, Sendable {
    /// The epoch at which invalidation occurred.
    public let epoch: Epoch

    /// Why the unit was invalidated.
    public let reason: InvalidationReason

    public init(epoch: Epoch, reason: InvalidationReason) {
        self.epoch = epoch
        self.reason = reason
    }
}
