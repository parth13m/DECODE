// ScopeIndex.swift — IndexRuntime
// DDS-004: Scope Index — containment tree with transitive closure
// DDS-004: Scope queries by scope entity → set of (contained entity, depth)

import Foundation
import DIRCore

/// The Scope Index data structure.
///
/// DDS-004: Containment tree built from `contains` relationship units.
/// Supports transitive containment queries: given a scope entity,
/// returns all transitively contained entities with depth.
///
/// Construction: O(R_c) for containment relationships + O(E) for transitive closure.
/// Memory: ~2 MB at alpha scale (~10,000 entities, avg depth 3).
struct ScopeIndex: Sendable {

    /// Direct children: parent entity → set of child entities.
    private var children: [String: Set<String>]

    /// Unit IDs backing each direct containment edge: (parent, child) → unitId.
    private var edgeUnits: [ScopeEdgeKey: UnitIdentifier]

    /// Transitive closure cache: scope entity → set of (contained entity, depth).
    private var transitiveCache: [String: Set<ScopeIndexEntry>]

    /// Whether the transitive cache is valid.
    private var cacheValid: Bool

    /// Total direct edge count.
    private(set) var directEdgeCount: Int

    init() {
        self.children = [:]
        self.edgeUnits = [:]
        self.transitiveCache = [:]
        self.cacheValid = false
        self.directEdgeCount = 0
    }

    // MARK: — Query

    /// Returns all transitively contained entities for the given scope entity.
    func query(scope: EntityReference) -> [ScopeIndexEntry] {
        if cacheValid, let cached = transitiveCache[scope.qualifiedName] {
            return Array(cached)
        }
        // Compute on demand if cache invalid
        var result: Set<ScopeIndexEntry> = []
        collectDescendants(of: scope.qualifiedName, depth: 1, into: &result)
        return Array(result)
    }

    /// Returns direct children of the given scope entity.
    func directChildren(of scope: EntityReference) -> [EntityReference] {
        children[scope.qualifiedName, default: []].map { EntityReference(qualifiedName: $0) }
    }

    // MARK: — Mutation

    /// Adds a direct containment edge: parent contains child.
    mutating func addEdge(parent: EntityReference, child: EntityReference, unitId: UnitIdentifier) {
        let key = ScopeEdgeKey(parent: parent.qualifiedName, child: child.qualifiedName)
        guard edgeUnits[key] == nil else { return }
        edgeUnits[key] = unitId
        children[parent.qualifiedName, default: []].insert(child.qualifiedName)
        directEdgeCount += 1
        cacheValid = false
    }

    /// Removes a containment edge by unit ID.
    mutating func removeEdge(unitId: UnitIdentifier) {
        guard let key = edgeUnits.first(where: { $0.value == unitId })?.key else { return }
        edgeUnits.removeValue(forKey: key)
        children[key.parent]?.remove(key.child)
        if children[key.parent]?.isEmpty == true {
            children.removeValue(forKey: key.parent)
        }
        directEdgeCount -= 1
        cacheValid = false
    }

    /// Recomputes the transitive closure cache.
    mutating func recomputeTransitiveClosure() {
        transitiveCache.removeAll()
        // For every entity that has children, compute all descendants
        for parent in children.keys {
            var result: Set<ScopeIndexEntry> = []
            collectDescendants(of: parent, depth: 1, into: &result)
            transitiveCache[parent] = result
        }
        cacheValid = true
    }

    /// Total entry count (transitive closure size, or direct edge count if cache invalid).
    var count: Int {
        if cacheValid {
            return transitiveCache.values.reduce(0) { $0 + $1.count }
        }
        return directEdgeCount
    }

    /// Estimated memory footprint in bytes.
    var estimatedMemoryBytes: Int { max(count, directEdgeCount) * 32 }

    /// Removes all entries.
    mutating func clear() {
        children.removeAll()
        edgeUnits.removeAll()
        transitiveCache.removeAll()
        cacheValid = false
        directEdgeCount = 0
    }

    // MARK: — Private

    private func collectDescendants(of entity: String, depth: Int, into result: inout Set<ScopeIndexEntry>) {
        guard let kids = children[entity] else { return }
        for child in kids {
            let entry = ScopeIndexEntry(containedEntity: EntityReference(qualifiedName: child), depth: depth)
            if result.insert(entry).inserted {
                collectDescendants(of: child, depth: depth + 1, into: &result)
            }
        }
    }
}

/// Key for a direct containment edge.
struct ScopeEdgeKey: Hashable, Sendable {
    let parent: String
    let child: String
}
