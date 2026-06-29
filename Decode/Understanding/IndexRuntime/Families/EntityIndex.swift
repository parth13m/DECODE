// EntityIndex.swift — IndexRuntime
// DDS-004: Entity Index — maps entity → set of (unitID, predicate, tier, status)
// DDS-004 R1, R2, R3: Construction and incremental maintenance

import Foundation
import DIRCore

/// The Entity Index data structure.
///
/// DDS-004: Groups units by subject entity. Supports lookup by entity identifier
/// with optional predicate, tier, and status filters.
///
/// Construction: O(N) scan of all Active and Invalidated units.
/// Memory: ~40 bytes per entry. ~12 MB at alpha scale (~300,000 units).
struct EntityIndex: Sendable {

    /// Maps entity qualified name → set of entries for that entity.
    private var entries: [String: Set<EntityIndexEntry>]

    /// Total entry count across all entities.
    private(set) var count: Int

    init() {
        self.entries = [:]
        self.count = 0
    }

    // MARK: — Query

    /// Returns all entries for the given entity.
    func query(entity: EntityReference) -> [EntityIndexEntry] {
        Array(entries[entity.qualifiedName, default: []])
    }

    /// Returns entries for the given entity, filtered by optional criteria.
    func query(
        entity: EntityReference,
        predicate: PredicateIdentifier? = nil,
        tier: Tier? = nil,
        status: UnitStatus? = nil
    ) -> [EntityIndexEntry] {
        let base = entries[entity.qualifiedName, default: []]
        return base.filter { entry in
            if let predicate, entry.predicate != predicate { return false }
            if let tier, entry.tier != tier { return false }
            if let status, entry.status != status { return false }
            return true
        }
    }

    // MARK: — Mutation

    /// Adds an entry for the given entity.
    mutating func add(entity: EntityReference, entry: EntityIndexEntry) {
        let inserted = entries[entity.qualifiedName, default: []].insert(entry).inserted
        if inserted { count += 1 }
    }

    /// Removes an entry by unit ID from the given entity.
    mutating func remove(entity: EntityReference, unitId: UnitIdentifier) {
        guard var set = entries[entity.qualifiedName] else { return }
        let before = set.count
        set = set.filter { $0.unitId != unitId }
        let removed = before - set.count
        count -= removed
        if set.isEmpty {
            entries.removeValue(forKey: entity.qualifiedName)
        } else {
            entries[entity.qualifiedName] = set
        }
    }

    /// Updates the status of entries matching the given unit ID.
    mutating func updateStatus(entity: EntityReference, unitId: UnitIdentifier, newStatus: UnitStatus) {
        guard var set = entries[entity.qualifiedName] else { return }
        let matching = set.filter { $0.unitId == unitId }
        for old in matching {
            set.remove(old)
            set.insert(EntityIndexEntry(
                unitId: old.unitId, predicate: old.predicate,
                tier: old.tier, status: newStatus
            ))
        }
        entries[entity.qualifiedName] = set
    }

    /// Removes all entries referencing the given unit ID across all entities.
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

    /// Estimated memory footprint in bytes (~40 bytes per entry).
    var estimatedMemoryBytes: Int { count * 40 }

    /// Removes all entries.
    mutating func clear() {
        entries.removeAll()
        count = 0
    }
}
