// DemandSignal.swift — DIRCore
// DDS-007: PC-2 — advisory signal from ConsumerRuntime to UpdateEngine
// DDS-009: PC-4 — ConsumerRuntime emits demand signals for T2 recomputation

import Foundation

/// An advisory signal indicating that a consumer needs a T2 (semantic) unit
/// for a specific subject and predicate.
///
/// Demand signals flow from `ConsumerRuntime` through `DemandSignalSink` to
/// the `UpdateEngine`, which schedules T2 producer execution. Demand signals
/// are advisory — the UpdateEngine may choose not to act on them (e.g., if a
/// T2 unit already exists and is still valid).
public struct DemandSignal: Hashable, Codable, Sendable {
    /// The subject entity or pair the consumer needs understanding about.
    public let subject: UnitSubject

    /// The predicate the consumer needs a T2 unit for.
    public let predicate: PredicateIdentifier

    /// The tier being requested (typically .t2).
    public let tier: Tier

    public init(subject: UnitSubject, predicate: PredicateIdentifier, tier: Tier = .t2) {
        self.subject = subject
        self.predicate = predicate
        self.tier = tier
    }
}
