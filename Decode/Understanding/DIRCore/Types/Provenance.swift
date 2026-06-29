// Provenance.swift — DIRCore
// DAS-002: I-PROV-1 (immutable), I-PROV-2 (machine-interpretable)
// DDS-002: PV-1 (completeness), PV-2 (machine-interpretable), PV-3 (input reference validity)

import Foundation

/// How a unit was produced — extraction, derivation, inference, or annotation.
///
/// DAS-002: producer identity and method are machine-interpretable (I-PROV-2).
public enum ProductionMethod: String, Hashable, Codable, Sendable {
    /// Extracted directly from source material (frontends). Inputs may be empty.
    case extraction
    /// Derived from other units by deterministic algorithm.
    case derivation
    /// Produced by non-deterministic semantic inference from input units.
    case inference
    /// Annotated by a human or external system.
    case annotation
}

/// Immutable record of what produced an atomic unit.
///
/// DAS-002: provenance includes producer identity, method, timestamp, and input references.
/// DDS-002 PV-1: producer, method, and timestamp are required. Inputs may be empty only
/// for extraction-method units.
public struct ProvenanceRecord: Hashable, Codable, Sendable {
    /// Identifier of the subsystem/pass that created the unit.
    public let producer: String

    /// How the unit was produced.
    public let method: ProductionMethod

    /// When the unit was created.
    public let timestamp: Date

    /// References to units or source material consumed to produce this unit.
    /// Empty for units extracted directly from source (frontends).
    /// DDS-002 PV-3: for derived/inferred units, must reference existing units.
    public let inputUnitIds: [UnitIdentifier]

    public init(
        producer: String,
        method: ProductionMethod,
        timestamp: Date,
        inputUnitIds: [UnitIdentifier] = []
    ) {
        self.producer = producer
        self.method = method
        self.timestamp = timestamp
        self.inputUnitIds = inputUnitIds
    }
}
