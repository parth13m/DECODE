// IndexQuerying.swift — IndexRuntime
// DDS-004: PC-1 — Index Query
// IAG-001 §4: Public protocol, consumed by RetrievalRuntime
// IAG-003 §3.1: async — crosses IndexActor boundary

import Foundation
import DIRCore

/// Provides query access to all five index families.
///
/// DDS-004 PC-1: Given an index family, query parameters, and the current
/// epoch context, the Index Runtime returns matching index entries.
/// For structural indexes, results are consistent with the DIR at the
/// committed epoch. For the Content Index, results may reflect a prior epoch.
///
/// When an index family is unavailable, the Index Runtime falls back to
/// DIR scan (DDS-004 RI-6). The caller is notified that fallback is in effect.
///
/// IAG-003: All methods are async — they cross the IndexActor boundary.
/// Implemented by IndexActor, consumed by RetrievalRuntime.
public protocol IndexQuerying: Sendable {

    // MARK: — Entity Index (PC-1)

    /// Queries the Entity Index for a specific entity.
    ///
    /// DDS-004 PC-1: Returns all (unitID, predicate, tier, status) entries
    /// for the given entity, with optional filters.
    ///
    /// - Parameters:
    ///   - entity: The entity to look up.
    ///   - predicate: Optional predicate filter.
    ///   - tier: Optional tier filter.
    ///   - status: Optional status filter.
    /// - Returns: Matching entries, with fallback indicator.
    func queryEntity(
        _ entity: EntityReference,
        predicate: PredicateIdentifier?,
        tier: Tier?,
        status: UnitStatus?
    ) async -> IndexQueryResult<EntityIndexEntry>

    // MARK: — Graph Index (PC-1)

    /// Queries the Graph Index for relationship traversal.
    ///
    /// DDS-004 PC-1: Returns all (neighbor entity, unitID, tier, status)
    /// entries for the given entity, relationship predicate, and direction.
    /// Supports both forward and inverse traversal (DAS-005 R-DIR-2).
    ///
    /// - Parameters:
    ///   - entity: The starting entity.
    ///   - predicate: The relationship predicate to traverse.
    ///   - direction: Forward (source→target) or inverse (target→source).
    /// - Returns: Matching entries, with fallback indicator.
    func queryGraph(
        entity: EntityReference,
        predicate: PredicateIdentifier,
        direction: TraversalDirection
    ) async -> IndexQueryResult<GraphIndexEntry>

    // MARK: — Scope Index (PC-1)

    /// Queries the Scope Index for transitive containment.
    ///
    /// DDS-004 PC-1: Returns all (contained entity, depth) entries
    /// for the given scope entity.
    ///
    /// - Parameter scope: The scope entity (file, module, or system).
    /// - Returns: Matching entries, with fallback indicator.
    func queryScope(
        _ scope: EntityReference
    ) async -> IndexQueryResult<ScopeIndexEntry>

    // MARK: — Predicate Index (PC-1)

    /// Queries the Predicate Index for a specific predicate.
    ///
    /// DDS-004 PC-1: Returns all (unitID, subject, tier, status, producer)
    /// entries for the given predicate, with optional filters.
    ///
    /// - Parameters:
    ///   - predicate: The predicate to look up.
    ///   - tier: Optional tier filter.
    ///   - status: Optional status filter.
    ///   - producerId: Optional producer filter.
    /// - Returns: Matching entries, with fallback indicator.
    func queryPredicate(
        _ predicate: PredicateIdentifier,
        tier: Tier?,
        status: UnitStatus?,
        producerId: String?
    ) async -> IndexQueryResult<PredicateIndexEntry>

    // MARK: — Content Index (PC-1)

    /// Queries the Content Index for term-based text search.
    ///
    /// DDS-004 PC-1: Returns all (unitID, subject, predicate) entries
    /// matching the given search term. Results may be one epoch behind
    /// the DIR (DDS-004 RI-8).
    ///
    /// - Parameter term: The search term.
    /// - Returns: Matching entries, with fallback indicator.
    func queryContent(
        term: String
    ) async -> IndexQueryResult<ContentIndexEntry>
}
