// DIRWriteAccess.swift — DIRCore
// DDS-002: PC-1 (admission), PC-2 (status transition), PC-6 (write transaction)
// IAG-001 §4: Defined in DIRCore, implemented by UpdateEngine,
//             consumed by ProducerRuntime, StorageEngine
// IAG-003 §3.1: async — crosses UpdateActor boundary

import Foundation

/// Write access to the DIR unit store.
///
/// Provides atomic write transactions (DDS-002 PC-6) combining unit admissions (PC-1)
/// and status transitions (PC-2). All writes are serialized — no two write transactions
/// execute concurrently (DAS-012 DA-1).
///
/// Implemented by `UpdateEngine`. Consumed by `ProducerRuntime` (to admit producer
/// output batches) and `StorageEngine` (to restore from snapshots and apply GC).
public protocol DIRWriteAccess: Sendable {

    /// Submits a write transaction for atomic execution.
    ///
    /// DDS-002 PC-6: Either all operations succeed or none are applied.
    /// Admissions are processed before transitions. Supersession is resolved
    /// as part of admission. Units admitted earlier in the transaction are
    /// visible to validation of units admitted later.
    ///
    /// - Parameter transaction: The set of admissions and transitions to apply.
    /// - Returns: The result — either committed with details, or rejected with diagnostics.
    func submit(_ transaction: WriteTransaction) async -> WriteTransactionResult
}
