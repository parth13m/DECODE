// ProducerError.swift — ProducerRuntime
// DDS-001: FM-1 through FM-7, PC-1 registration rejection
// IAG-003 §11.1: Error boundary — internal errors caught, public error propagated

import Foundation
import DIRCore

/// Errors produced by the Producer Runtime.
///
/// IAG-003 §11.1: ProducerActor catches internal errors (SwiftSyntax parse errors,
/// tree-sitter errors, URLSession errors, timeout errors) and maps them to
/// producer-specific error types with DDS-001 failure categories.
public enum ProducerError: Error, Sendable {

    /// Registration was rejected because the contract is structurally invalid.
    /// DDS-001 PC-1: missing fields, inconsistent tier/determinism.
    case invalidContract(ProducerIdentifier, reason: String)

    /// Registration was rejected because it would introduce a DAG cycle.
    /// DDS-001 FM-4: includes the cycle path.
    case dagCycle(ProducerIdentifier, cyclePath: [ProducerIdentifier])

    /// The producer is not registered.
    case producerNotFound(ProducerIdentifier)

    /// The runtime is not in a state that permits the requested operation.
    case invalidState(current: ProducerRuntimeState, attempted: String)

    /// A producer execution failed.
    /// DDS-001 FM-1 through FM-7: includes identity, category, and diagnostic.
    case executionFailed(FailureRecord)
}
