// GroundingDependencyMap.swift — StorageEngine
// DDS-008: R3, PC-4 — Grounding dependency map
// DAS-012: Reverse lookup for cascade traversal
// DAS-010: IP-4 — O(degree) cascade traversal

import Foundation
import DIRCore

/// Reverse lookup structure mapping a unit ID to the set of units that depend on it.
///
/// DDS-008 R3: Exclusively owned by StorageEngine. Built from DIR provenance records.
/// Maps unit U → set of units V where V.provenance.inputs contains U.
///
/// DDS-008 PC-4: Supports O(degree) cascade traversal for the Update Engine.
///
/// Memory: ~16 bytes per edge. ~10 MB at alpha scale (~600K edges).
struct GroundingDependencyMap: Sendable {

    /// Maps unit ID → set of dependent unit IDs.
    /// For unit U, dependents[U] = { V | V.provenance.inputs contains U }.
    private var dependents: [UnitIdentifier: Set<UnitIdentifier>]

    /// Total edge count.
    private(set) var edgeCount: Int

    /// The epoch at which this map was last updated.
    var lastMaintainedEpoch: Epoch?

    init() {
        self.dependents = [:]
        self.edgeCount = 0
        self.lastMaintainedEpoch = nil
    }

    // MARK: — Query (PC-4)

    /// Returns the set of units whose provenance.inputs references the given unit.
    ///
    /// DDS-008 PC-4: O(degree) lookup.
    func dependents(of unitId: UnitIdentifier) -> Set<UnitIdentifier> {
        dependents[unitId, default: []]
    }

    /// Returns whether any active or invalidated unit depends on the given unit.
    /// Used for GC safety verification (DAS-012 I7).
    func hasDependents(_ unitId: UnitIdentifier) -> Bool {
        !(dependents[unitId, default: []].isEmpty)
    }

    // MARK: — Construction

    /// Adds a dependency edge: dependent depends on input.
    mutating func addEdge(input: UnitIdentifier, dependent: UnitIdentifier) {
        let inserted = dependents[input, default: []].insert(dependent).inserted
        if inserted { edgeCount += 1 }
    }

    /// Adds all dependency edges for a unit with the given provenance inputs.
    mutating func addUnit(_ unitId: UnitIdentifier, provenanceInputs: [UnitIdentifier]) {
        for input in provenanceInputs {
            addEdge(input: input, dependent: unitId)
        }
    }

    /// Removes all edges where the given unit appears as a dependent.
    mutating func removeDependent(_ unitId: UnitIdentifier) {
        for (key, var set) in dependents {
            if set.remove(unitId) != nil {
                edgeCount -= 1
                if set.isEmpty {
                    dependents.removeValue(forKey: key)
                } else {
                    dependents[key] = set
                }
            }
        }
    }

    /// Removes the key entry for a given unit (when the unit is garbage collected).
    mutating func removeKey(_ unitId: UnitIdentifier) {
        if let removed = dependents.removeValue(forKey: unitId) {
            edgeCount -= removed.count
        }
    }

    /// Removes all entries.
    mutating func clear() {
        dependents.removeAll()
        edgeCount = 0
        lastMaintainedEpoch = nil
    }

    /// Estimated memory footprint in bytes (~16 bytes per edge).
    var estimatedMemoryBytes: Int { edgeCount * 16 }
}
