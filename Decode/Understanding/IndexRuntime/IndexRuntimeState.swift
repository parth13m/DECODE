// IndexRuntimeState.swift — IndexRuntime
// DDS-004: State Model — Uninitialized → Building → Operational → Quiescing → Terminated
// IAG-003 §2.3: IndexActor lifecycle state

import Foundation

/// The lifecycle state of the Index Runtime.
///
/// DDS-004 State Model:
/// - Uninitialized: created but index construction has not begun.
/// - Building: families being constructed from DIR. Completed families serve queries;
///   in-progress families use DIR scan fallback.
/// - Operational: all five families constructed. Steady state.
/// - Quiescing: shutting down. No new change batches accepted.
/// - Terminated: destroyed. No operations valid.
public enum IndexRuntimeState: String, Hashable, Sendable {
    case uninitialized
    case building
    case operational
    case quiescing
    case terminated

    /// Returns whether transitioning to the given state is valid.
    ///
    /// DDS-004 State Model transition table:
    /// - Uninitialized → Building (DIR Runtime operational; construction begins)
    /// - Building → Operational (all five families constructed)
    /// - Operational → Building (index family requires rebuild)
    /// - Operational → Quiescing (shutdown signal)
    /// - Building → Quiescing (shutdown signal during construction)
    /// - Quiescing → Terminated (all in-progress updates resolved)
    ///
    /// Invalid: Uninitialized → Operational, Terminated → any, Quiescing → Operational/Building
    public func canTransition(to target: IndexRuntimeState) -> Bool {
        switch (self, target) {
        case (.uninitialized, .building): return true
        case (.building, .operational): return true
        case (.operational, .building): return true
        case (.operational, .quiescing): return true
        case (.building, .quiescing): return true
        case (.quiescing, .terminated): return true
        default: return false
        }
    }
}
