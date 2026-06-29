// EpochControl.swift — DIRCore
// DDS-002: PC-4 (epoch advancement), PC-3(b) (within-cycle visibility)
// IAG-001 §4: Defined in DIRCore, implemented by UpdateEngine,
//             consumed internally by UpdateEngine only

import Foundation

/// Controls epoch advancement and within-cycle visibility.
///
/// DDS-002 PC-4: The epoch counter advances atomically from N to N+1.
/// After advancement, all writes committed during the synchronous pipeline
/// become visible to consumer queries.
///
/// DDS-002 PC-3(b): During synchronous pipeline execution, producer reads
/// observe the committed epoch plus all writes committed by prior producers
/// in the current execution cycle.
///
/// This protocol is internal to `UpdateEngine` — it is not a cross-module
/// injection point (IAG-001 §4 traceability table). It is defined in DIRCore
/// because `UpdateEngine` imports `DIRCore`, not the other way around.
public protocol EpochControl: Sendable {

    /// Advances the epoch from N to N+1.
    ///
    /// DDS-002 PC-4: After advancement, all writes committed during the
    /// synchronous pipeline become visible to consumer queries (PC-3).
    ///
    /// - Precondition: The synchronous pipeline has completed — all T0 and T1
    ///   producer executions have finished, all output batches admitted, all
    ///   invalidations recorded.
    func advanceEpoch() -> Epoch
}
