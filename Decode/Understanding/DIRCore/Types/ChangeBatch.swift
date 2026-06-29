// ChangeBatch.swift — DIRCore
// DDS-008: PC-11 — change notification from UpdateEngine to observers
// DDS-002: Write notifications (units admitted, status changed) for incremental index maintenance

import Foundation

/// A batch of changes committed to the DIR in a single epoch.
///
/// Emitted by the UpdateEngine after a write transaction is committed.
/// Consumed by `ChangeBatchObserver` implementations (StorageEngine, IndexRuntime)
/// for incremental maintenance.
public struct ChangeBatch: Sendable {
    /// The epoch at which these changes were committed.
    public let epoch: Epoch

    /// The individual changes, in the order they occurred.
    public let changes: [UnitChange]

    public init(epoch: Epoch, changes: [UnitChange]) {
        self.epoch = epoch
        self.changes = changes
    }
}

/// A single change to a unit in the DIR.
public enum UnitChange: Sendable {
    /// A new unit was admitted with Active status (DDS-002 PC-1).
    case admitted(UnitIdentifier)

    /// A unit was transitioned to Invalidated status (DDS-002 PC-2).
    case invalidated(UnitIdentifier)

    /// A unit was transitioned to Superseded status, with its successor.
    case superseded(UnitIdentifier, by: UnitIdentifier)

    /// A unit was transitioned to GarbageCollected status (DDS-002 PC-7).
    case garbageCollected(UnitIdentifier)
}
