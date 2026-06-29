// ProducerRuntimeState.swift — ProducerRuntime
// DDS-001: State Model — Empty → Ready → Executing → Quiescing → Terminated

import Foundation

/// The lifecycle state of the Producer Runtime.
///
/// DDS-001 State Model:
/// - Empty: no producers registered; execution tickets rejected.
/// - Ready: at least one producer registered; tickets accepted.
/// - Executing: execution cycle in progress; registration deferred.
/// - Quiescing: shutting down; no new tickets accepted.
/// - Terminated: destroyed; no operations valid.
public enum ProducerRuntimeState: String, Hashable, Sendable {
    case empty
    case ready
    case executing
    case quiescing
    case terminated

    /// Returns whether transitioning to the given state is valid.
    ///
    /// DDS-001 State Model transition table:
    /// - Empty → Ready (first producer registered)
    /// - Ready → Empty (last producer removed)
    /// - Ready → Executing (execution ticket received)
    /// - Executing → Ready (all tickets processed)
    /// - Ready → Quiescing (shutdown signal)
    /// - Executing → Quiescing (shutdown signal during execution)
    /// - Quiescing → Terminated (all in-progress work resolved)
    ///
    /// Invalid: Empty → Executing, Terminated → any, Quiescing → Ready/Executing
    public func canTransition(to target: ProducerRuntimeState) -> Bool {
        switch (self, target) {
        case (.empty, .ready): return true
        case (.ready, .empty): return true
        case (.ready, .executing): return true
        case (.executing, .ready): return true
        case (.ready, .quiescing): return true
        case (.executing, .quiescing): return true
        case (.quiescing, .terminated): return true
        default: return false
        }
    }
}
