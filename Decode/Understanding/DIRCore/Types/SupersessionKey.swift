// SupersessionKey.swift — DIRCore
// DDS-002: R4, DAS-012 — supersession key is (subject, predicate, tier)
// Two Active units with the same (subject, predicate) but different tiers coexist.
// Only units with identical (subject, predicate, tier) are competitors requiring supersession.

import Foundation

/// The triple that identifies competing claims in the DIR.
///
/// When a new unit is admitted with the same supersession key as an existing Active unit,
/// the existing unit is atomically transitioned to Superseded status (DDS-002 PC-1).
public struct SupersessionKey: Hashable, Codable, Sendable {
    public let subject: UnitSubject
    public let predicate: PredicateIdentifier
    public let tier: Tier

    public init(subject: UnitSubject, predicate: PredicateIdentifier, tier: Tier) {
        self.subject = subject
        self.predicate = predicate
        self.tier = tier
    }
}
