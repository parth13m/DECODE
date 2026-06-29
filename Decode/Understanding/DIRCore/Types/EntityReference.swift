// EntityReference.swift — DIRCore
// DAS-002: subject field — EntityReference | EntityPair
// DAS-002: I-SUB-1 (references existing entity), I-SUB-2 (explicit source/target), I-SUB-3 (no ternary)
// DAS-004: Qualified Name for entity identity

import Foundation

/// Identifies an entity in the DIR by its qualified name.
public struct EntityReference: Hashable, Codable, Sendable {
    /// Globally unique qualified name within scope (e.g., "Module.Type.method").
    public let qualifiedName: String

    public init(qualifiedName: String) {
        self.qualifiedName = qualifiedName
    }
}

/// An ordered pair of entities representing a relationship subject.
///
/// DAS-002 I-SUB-2: pair is ordered — (A, B) ≠ (B, A).
/// Directionality is carried by pair ordering.
public struct EntityPair: Hashable, Codable, Sendable {
    public let source: EntityReference
    public let target: EntityReference

    public init(source: EntityReference, target: EntityReference) {
        self.source = source
        self.target = target
    }
}

/// The subject of an atomic unit — either a single entity or an ordered pair.
///
/// DAS-002 I-SUB-3: no ternary or higher-arity subjects permitted.
public enum UnitSubject: Hashable, Codable, Sendable {
    case entity(EntityReference)
    case pair(EntityPair)
}
