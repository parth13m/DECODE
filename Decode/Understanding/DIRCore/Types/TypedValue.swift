// TypedValue.swift — DIRCore
// DAS-002: I-VAL-1 (immutable once created), I-VAL-2 (independently queryable sub-fields must be separate units)
// Value types: Scalar (string, integer, boolean, float), Enumerated, Text, Reference, Structured

import Foundation

/// The value field of an atomic unit.
///
/// Immutable once the unit is created. To change a value, the old unit is invalidated
/// and a new unit is created (DAS-002 I-VAL-1).
///
/// Structured values with independently queryable sub-fields must be decomposed into
/// separate units with separate predicates (DAS-002 I-VAL-2).
public indirect enum TypedValue: Hashable, Codable, Sendable {
    // Scalar types
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case float(Double)

    // Non-scalar types
    case enumerated(String)
    case text(String)
    case reference(EntityReference)
    case structured([String: TypedValue])

    /// The kind of this value, for structural validation against predicate descriptors.
    public var kind: ValueKind {
        switch self {
        case .string: .string
        case .integer: .integer
        case .boolean: .boolean
        case .float: .float
        case .enumerated: .enumerated
        case .text: .text
        case .reference: .reference
        case .structured: .structured
        }
    }
}
