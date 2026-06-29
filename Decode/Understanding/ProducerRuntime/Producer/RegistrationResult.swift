// RegistrationResult.swift — ProducerRuntime
// DDS-001: PC-1 — registration acceptance or rejection

import Foundation
import DIRCore

/// The result of attempting to register a producer.
///
/// DDS-001 PC-1: Registration is accepted if the contract is valid and does not
/// introduce a DAG cycle. Otherwise rejected with a diagnostic.
public enum RegistrationResult: Sendable {
    /// The producer was accepted into the registry and is schedulable.
    case accepted
    /// Registration was deferred because the runtime is in the Executing state.
    /// The registration will be applied when the current execution cycle completes.
    case deferred
    /// Registration was rejected.
    case rejected(reason: String)
}
