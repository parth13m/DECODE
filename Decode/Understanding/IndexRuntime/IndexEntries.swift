// IndexEntries.swift — IndexRuntime
// DDS-004: Index entry types for each family
// DDS-004 PC-1: Query return types per family

import Foundation
import DIRCore

// MARK: — Entity Index Entry

/// An entry in the Entity Index.
///
/// DDS-004 PC-1: Maps entity identifier → set of (unit ID, predicate, tier, status).
public struct EntityIndexEntry: Hashable, Sendable {
    public let unitId: UnitIdentifier
    public let predicate: PredicateIdentifier
    public let tier: Tier
    public let status: UnitStatus

    public init(unitId: UnitIdentifier, predicate: PredicateIdentifier, tier: Tier, status: UnitStatus) {
        self.unitId = unitId
        self.predicate = predicate
        self.tier = tier
        self.status = status
    }
}

// MARK: — Graph Index Entry

/// Traversal direction for graph queries.
///
/// DAS-005 R-DIR-2: Supports both forward and inverse traversal
/// from unidirectional data via bidirectional index entries.
public enum TraversalDirection: String, Hashable, Sendable {
    /// From source to target.
    case forward
    /// From target to source.
    case inverse
}

/// An entry in the Graph Index.
///
/// DDS-004 PC-1: Maps (entity, relationship predicate, direction) →
/// set of (neighbor entity, unit ID, tier, status).
public struct GraphIndexEntry: Hashable, Sendable {
    public let neighbor: EntityReference
    public let unitId: UnitIdentifier
    public let tier: Tier
    public let status: UnitStatus

    public init(neighbor: EntityReference, unitId: UnitIdentifier, tier: Tier, status: UnitStatus) {
        self.neighbor = neighbor
        self.unitId = unitId
        self.tier = tier
        self.status = status
    }
}

// MARK: — Scope Index Entry

/// An entry in the Scope Index.
///
/// DDS-004 PC-1: Maps scope entity → set of (contained entity, depth).
/// Supports transitive containment queries.
public struct ScopeIndexEntry: Hashable, Sendable {
    public let containedEntity: EntityReference
    public let depth: Int

    public init(containedEntity: EntityReference, depth: Int) {
        self.containedEntity = containedEntity
        self.depth = depth
    }
}

// MARK: — Predicate Index Entry

/// An entry in the Predicate Index.
///
/// DDS-004 PC-1: Maps predicate → set of (unit ID, subject, tier, status, producer).
public struct PredicateIndexEntry: Hashable, Sendable {
    public let unitId: UnitIdentifier
    public let subject: UnitSubject
    public let tier: Tier
    public let status: UnitStatus
    public let producerId: String?

    public init(
        unitId: UnitIdentifier,
        subject: UnitSubject,
        tier: Tier,
        status: UnitStatus,
        producerId: String?
    ) {
        self.unitId = unitId
        self.subject = subject
        self.tier = tier
        self.status = status
        self.producerId = producerId
    }
}

// MARK: — Content Index Entry

/// An entry in the Content Index.
///
/// DDS-004 PC-1: Maps search term → set of (unit ID, subject, predicate).
public struct ContentIndexEntry: Hashable, Sendable {
    public let unitId: UnitIdentifier
    public let subject: UnitSubject
    public let predicate: PredicateIdentifier

    public init(unitId: UnitIdentifier, subject: UnitSubject, predicate: PredicateIdentifier) {
        self.unitId = unitId
        self.subject = subject
        self.predicate = predicate
    }
}
