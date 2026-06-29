// GraphIndex.swift — IndexRuntime
// DDS-004: Graph Index — bidirectional relationship traversal
// DAS-005 R-DIR-2: Forward and inverse traversal from unidirectional data
// DAS-007 DA-7: Bidirectional adjacency structure

import Foundation
import DIRCore

/// Key for graph index entries: (entity, relationship predicate, direction).
struct GraphIndexKey: Hashable, Sendable {
    let entity: String
    let predicate: PredicateIdentifier
    let direction: TraversalDirection
}

/// The Graph Index data structure.
///
/// DDS-004: Bidirectional relationship traversal. For each paired-entity unit,
/// stores both a forward entry (source → target) and an inverse entry (target → source).
///
/// Construction: O(R) scan of all paired-entity units.
/// Memory: ~50 bytes per entry pair. ~5 MB at alpha scale (~50,000 relationships).
struct GraphIndex: Sendable {

    /// Maps (entity, predicate, direction) → set of neighbor entries.
    private var entries: [GraphIndexKey: Set<GraphIndexEntry>]

    /// Total entry count (counts both forward and inverse entries).
    private(set) var count: Int

    init() {
        self.entries = [:]
        self.count = 0
    }

    // MARK: — Query

    /// Returns all entries for the given entity, predicate, and direction.
    func query(
        entity: EntityReference,
        predicate: PredicateIdentifier,
        direction: TraversalDirection
    ) -> [GraphIndexEntry] {
        let key = GraphIndexKey(entity: entity.qualifiedName, predicate: predicate, direction: direction)
        return Array(entries[key, default: []])
    }

    /// Returns all entries for the given entity and direction, across all predicates.
    func query(entity: EntityReference, direction: TraversalDirection) -> [GraphIndexEntry] {
        var result: [GraphIndexEntry] = []
        for (key, set) in entries where key.entity == entity.qualifiedName && key.direction == direction {
            result.append(contentsOf: set)
        }
        return result
    }

    // MARK: — Mutation

    /// Adds both forward and inverse entries for a paired-entity unit.
    mutating func addPair(
        source: EntityReference,
        target: EntityReference,
        predicate: PredicateIdentifier,
        unitId: UnitIdentifier,
        tier: Tier,
        status: UnitStatus
    ) {
        let forwardEntry = GraphIndexEntry(neighbor: target, unitId: unitId, tier: tier, status: status)
        let forwardKey = GraphIndexKey(entity: source.qualifiedName, predicate: predicate, direction: .forward)
        let fInserted = entries[forwardKey, default: []].insert(forwardEntry).inserted

        let inverseEntry = GraphIndexEntry(neighbor: source, unitId: unitId, tier: tier, status: status)
        let inverseKey = GraphIndexKey(entity: target.qualifiedName, predicate: predicate, direction: .inverse)
        let iInserted = entries[inverseKey, default: []].insert(inverseEntry).inserted

        if fInserted { count += 1 }
        if iInserted { count += 1 }
    }

    /// Removes all entries referencing the given unit ID.
    mutating func removeUnit(_ unitId: UnitIdentifier) {
        for (key, var set) in entries {
            let before = set.count
            set = set.filter { $0.unitId != unitId }
            count -= (before - set.count)
            if set.isEmpty {
                entries.removeValue(forKey: key)
            } else {
                entries[key] = set
            }
        }
    }

    /// Updates the status of all entries referencing the given unit ID.
    mutating func updateStatus(unitId: UnitIdentifier, newStatus: UnitStatus) {
        for (key, var set) in entries {
            let matching = set.filter { $0.unitId == unitId }
            for old in matching {
                set.remove(old)
                set.insert(GraphIndexEntry(
                    neighbor: old.neighbor, unitId: old.unitId,
                    tier: old.tier, status: newStatus
                ))
            }
            entries[key] = set
        }
    }

    /// Estimated memory footprint in bytes (~50 bytes per entry).
    var estimatedMemoryBytes: Int { count * 50 }

    /// Removes all entries.
    mutating func clear() {
        entries.removeAll()
        count = 0
    }
}
