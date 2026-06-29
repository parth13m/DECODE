// PredicateIndex.swift — IndexRuntime
// DDS-004: Predicate Index — maps predicate → set of (unitID, subject, tier, status, producer)

import Foundation
import DIRCore

/// The Predicate Index data structure.
///
/// DDS-004: Groups units by predicate. Supports lookup by predicate identifier
/// with optional tier, status, and provenance filters.
///
/// Construction: O(N) scan of all Active and Invalidated units.
/// Memory: ~50 bytes per entry. ~15 MB at alpha scale (~300,000 units).
struct PredicateIndex: Sendable {

    /// Maps predicate key (domain.name) → set of entries.
    private var entries: [String: Set<PredicateIndexEntry>]

    /// Total entry count.
    private(set) var count: Int

    init() {
        self.entries = [:]
        self.count = 0
    }

    // MARK: — Query

    /// Returns all entries for the given predicate.
    func query(predicate: PredicateIdentifier) -> [PredicateIndexEntry] {
        Array(entries[predicate.description, default: []])
    }

    /// Returns entries for the given predicate, filtered by optional criteria.
    func query(
        predicate: PredicateIdentifier,
        tier: Tier? = nil,
        status: UnitStatus? = nil,
        producerId: String? = nil
    ) -> [PredicateIndexEntry] {
        let base = entries[predicate.description, default: []]
        return base.filter { entry in
            if let tier, entry.tier != tier { return false }
            if let status, entry.status != status { return false }
            if let producerId, entry.producerId != producerId { return false }
            return true
        }
    }

    // MARK: — Mutation

    /// Adds an entry for the given predicate.
    mutating func add(predicate: PredicateIdentifier, entry: PredicateIndexEntry) {
        let inserted = entries[predicate.description, default: []].insert(entry).inserted
        if inserted { count += 1 }
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
                set.insert(PredicateIndexEntry(
                    unitId: old.unitId, subject: old.subject,
                    tier: old.tier, status: newStatus, producerId: old.producerId
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
