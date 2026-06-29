// ChangeBatchObserver.swift — DIRCore
// DDS-008: PC-11 — change notification for incremental maintenance
// IAG-001 §4: Defined in DIRCore, implemented by StorageEngine,
//             consumed by UpdateEngine
// IAG-003 §3.1: async — crosses StorageActor boundary

import Foundation

/// Observes batches of changes committed to the DIR.
///
/// DDS-008 PC-11: After a write transaction is committed, the UpdateEngine
/// notifies observers with a `ChangeBatch` describing what changed. Observers
/// use this for incremental maintenance (snapshot scheduling, index updates).
///
/// Defined in DIRCore because the observer direction is inverted — StorageEngine
/// implements this protocol, but UpdateEngine calls it. Both modules import
/// DIRCore (IAG-001 §4).
public protocol ChangeBatchObserver: Sendable {

    /// Called after a write transaction is committed.
    ///
    /// - Parameter batch: The epoch and set of changes that were committed.
    func didCommit(_ batch: ChangeBatch) async
}
