// GroundingMapAccess.swift — StorageEngine
// DDS-008: PC-4 — Grounding Dependency Map Access
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses StorageActor boundary

import Foundation
import DIRCore

/// The result of a grounding map lookup.
public enum GroundingLookupResult: Sendable {
    /// The map is available and the lookup returned dependents.
    case available(Set<UnitIdentifier>)
    /// The map is not yet available (during startup before construction).
    case notAvailable
}

/// Provides reverse grounding lookup for cascade traversal.
///
/// DDS-008 PC-4: Given a unit identifier, returns the set of units whose
/// provenance.inputs references it. O(degree) lookup.
///
/// IAG-003: All methods are async — they cross the StorageActor boundary.
/// Implemented by StorageActor, consumed by UpdateEngine.
public protocol GroundingMapAccess: Sendable {

    /// Returns the set of units that depend on the given unit.
    ///
    /// DDS-008 PC-4: O(degree) reverse grounding lookup.
    /// Returns `.notAvailable` during startup before map construction.
    ///
    /// - Parameter unitId: The unit to look up dependents for.
    /// - Returns: The dependent set, or not available.
    func dependents(of unitId: UnitIdentifier) async -> GroundingLookupResult

    /// Returns whether the grounding map is available.
    func isMapAvailable() async -> Bool
}
