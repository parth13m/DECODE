// Predicate.swift — DIRCore
// DAS-002: I-PRED-1 (append-only registry), I-PRED-2 (declares domain, value type, arity, MDT)
// DAS-002: I-PRED-3 (same subject+predicate = competing claims → supersession)

import Foundation

/// Identifies a predicate in the DIR's append-only predicate registry.
///
/// Predicates are versioned and never removed, ensuring existing units remain interpretable.
public struct PredicateIdentifier: Hashable, Codable, Sendable {
    /// The unique predicate name within its domain (e.g., "hasReturnType").
    public let name: String

    /// The domain grouping this predicate belongs to (e.g., "structure", "behavior").
    public let domain: String

    public init(name: String, domain: String) {
        self.name = name
        self.domain = domain
    }
}

extension PredicateIdentifier: CustomStringConvertible {
    public var description: String {
        "\(domain).\(name)"
    }
}

/// Whether a predicate applies to a single entity or an entity pair.
public enum SubjectArity: String, Hashable, Codable, Sendable {
    case single
    case paired
}

/// Metadata describing a predicate's constraints and capabilities.
///
/// DAS-002 I-PRED-2: each predicate declares domain, expected value type,
/// subject arity, and maximum deterministic tier.
public struct PredicateDescriptor: Hashable, Codable, Sendable {
    public let identifier: PredicateIdentifier
    public let expectedValueKind: ValueKind
    public let subjectArity: SubjectArity
    public let maximumDeterministicTier: Tier
    public let permitsSemanticTier: Bool

    public init(
        identifier: PredicateIdentifier,
        expectedValueKind: ValueKind,
        subjectArity: SubjectArity,
        maximumDeterministicTier: Tier,
        permitsSemanticTier: Bool
    ) {
        self.identifier = identifier
        self.expectedValueKind = expectedValueKind
        self.subjectArity = subjectArity
        self.maximumDeterministicTier = maximumDeterministicTier
        self.permitsSemanticTier = permitsSemanticTier
    }
}

/// The kind of value a predicate expects, used for structural validation.
public enum ValueKind: String, Hashable, Codable, Sendable {
    case string
    case integer
    case boolean
    case float
    case enumerated
    case text
    case reference
    case structured
}
