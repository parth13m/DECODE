// Tier.swift — DIRCore
// DAS-003: T0 (Deterministic), T1 (Derived), T2 (Semantic)
// DAS-003: I1 (tier totality), I2 (T0 = deterministic confidence only), I6 (tier immutability)
// DDS-002: R8 — enforce tier-confidence bounds at intake

import Foundation

/// The objectivity tier of an atomic unit.
///
/// Tiers are totally ordered. Lower tiers are more objective, more stable, and cheaper to produce.
/// A unit's tier is declared at creation and never changes (DAS-003 I6).
public enum Tier: Int, Hashable, Codable, Sendable, Comparable, CaseIterable {
    /// Provably correct given well-formed source. Deterministic confidence only.
    case t0 = 0
    /// Computed from T0 facts by deterministic algorithm. High/moderate/low confidence.
    case t1 = 1
    /// Produced by interpretive inference requiring judgment. High/moderate/low confidence.
    case t2 = 2

    public static func < (lhs: Tier, rhs: Tier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The confidence level of an atomic unit's value.
///
/// Ordered scale: deterministic > high > moderate > low.
/// Bounded by tier: T0 requires `deterministic`; T1/T2 forbid it (DAS-003 I2).
public enum Confidence: Int, Hashable, Codable, Sendable, Comparable, CaseIterable {
    case deterministic = 3
    case high = 2
    case moderate = 1
    case low = 0

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Validates that this confidence is permitted for the given tier.
    ///
    /// - DAS-003 I2: T0 units must have `deterministic`. T1/T2 must not.
    /// - Returns `true` if the combination is valid.
    public func isValid(for tier: Tier) -> Bool {
        switch tier {
        case .t0:
            return self == .deterministic
        case .t1, .t2:
            return self != .deterministic
        }
    }
}
