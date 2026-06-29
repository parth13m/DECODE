// StorageEngineState.swift — StorageEngine
// DDS-008: State Model — Created → Loading → MapBuilding → Operational → Quiescing → Terminated

import Foundation

/// The lifecycle state of the Storage Engine.
///
/// DDS-008 State Model:
/// - Created: constructed, snapshot located/validated. DIR not yet populated.
/// - Loading: snapshot being deserialized, DIR being populated via write transactions.
/// - MapBuilding: snapshot loaded. Grounding dependency map being constructed.
/// - Operational: all contracts active. Snapshots, GC, grounding map available.
/// - Quiescing: shutting down. Final snapshot being captured. GC suspended.
/// - Terminated: destroyed. No operations valid.
public enum StorageEngineState: String, Hashable, Sendable {
    case created
    case loading
    case mapBuilding
    case operational
    case quiescing
    case terminated

    /// Returns whether transitioning to the given state is valid.
    ///
    /// DDS-008 State Model transition table:
    /// - Created → Loading (DIR Runtime enters Loading state)
    /// - Loading → MapBuilding (DIR population complete)
    /// - MapBuilding → Operational (map construction complete)
    /// - Operational → Quiescing (shutdown signal)
    /// - Quiescing → Terminated (final snapshot confirmed)
    ///
    /// Invalid: Created → Operational, Terminated → any, Quiescing → Operational
    public func canTransition(to target: StorageEngineState) -> Bool {
        switch (self, target) {
        case (.created, .loading): return true
        case (.loading, .mapBuilding): return true
        case (.mapBuilding, .operational): return true
        case (.operational, .quiescing): return true
        case (.quiescing, .terminated): return true
        default: return false
        }
    }
}
