// DemandSignalSink.swift — DIRCore
// DDS-007: PC-2 (counterparty to DDS-009:PC-4)
// IAG-001 §4: Defined in DIRCore, implemented by UpdateEngine,
//             consumed by ConsumerRuntime
// IAG-003 §3.1: async — crosses UpdateActor boundary

import Foundation

/// Receives demand signals from consumers requesting T2 recomputation.
///
/// DDS-009 PC-4: The ConsumerRuntime emits demand signals when it determines
/// that a T2 (semantic) unit is needed but does not exist or is stale.
/// DDS-007 PC-2: The UpdateEngine receives these signals and schedules
/// deferred T2 producer execution.
///
/// Defined in DIRCore because ConsumerRuntime and UpdateEngine must not import
/// each other — both import DIRCore (IAG-001 §3).
public protocol DemandSignalSink: Sendable {

    /// Submits a demand signal for T2 recomputation.
    ///
    /// Advisory — the UpdateEngine may choose not to act if a valid T2 unit
    /// already exists for the given subject and predicate.
    ///
    /// - Parameter signal: The demand signal describing what T2 unit is needed.
    func submit(_ signal: DemandSignal) async
}
