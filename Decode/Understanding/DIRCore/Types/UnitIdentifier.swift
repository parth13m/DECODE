// UnitIdentifier.swift — DIRCore
// DAS-002: I-ID-1 (unique), I-ID-2 (never reassigned), I-ID-3 (no semantic content)
// DDS-002: R5 — globally unique, immutable, opaque

import Foundation

/// Globally unique, opaque identifier for an atomic unit in the DIR.
///
/// Assigned by the DIR runtime at admission. Monotonically increasing.
/// Carries no semantic content — not derived from the unit's fields.
public struct UnitIdentifier: Hashable, Codable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: UnitIdentifier, rhs: UnitIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension UnitIdentifier: CustomStringConvertible {
    public var description: String {
        "unit-\(rawValue)"
    }
}
