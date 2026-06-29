// Factories.swift — UnderstandingTestSupport
// IAG-001 §9, IAG-004 §3.1: Factory utilities for test construction
// Provides makeUnit(), makeEpoch(), makeProvenance() with sensible defaults

import Foundation
@testable import DIRCore

// MARK: — Unit Factory

/// Creates an `AtomicUnit` with sensible defaults for testing.
///
/// All parameters have defaults, so tests only specify the fields they care about.
public func makeUnit(
    id: UnitIdentifier = UnitIdentifier(rawValue: 1),
    subject: UnitSubject = .entity(EntityReference(qualifiedName: "TestEntity")),
    predicate: PredicateIdentifier = PredicateIdentifier(name: "testPredicate", domain: "test"),
    value: TypedValue = .string("testValue"),
    tier: Tier = .t0,
    provenance: ProvenanceRecord? = nil,
    confidence: Confidence = .deterministic,
    grounding: GroundingChain? = nil,
    version: VersionStamp? = nil
) -> AtomicUnit {
    let resolvedProvenance = provenance ?? makeProvenance()
    let resolvedGrounding = grounding ?? .direct(SourcePosition(
        filePath: "test.swift",
        startLine: 1,
        endLine: 10,
        fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
    ))
    let resolvedVersion = version ?? VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )

    return AtomicUnit(
        id: id,
        subject: subject,
        predicate: predicate,
        value: value,
        tier: tier,
        provenance: resolvedProvenance,
        confidence: confidence,
        grounding: resolvedGrounding,
        version: resolvedVersion
    )
}

// MARK: — Epoch Factory

/// Creates an `Epoch` with a default value for testing.
public func makeEpoch(_ value: UInt64 = 0) -> Epoch {
    Epoch(value: value)
}

// MARK: — Provenance Factory

/// Creates a `ProvenanceRecord` with sensible defaults for testing.
public func makeProvenance(
    producer: String = "test-producer",
    method: ProductionMethod = .extraction,
    timestamp: Date = Date(timeIntervalSince1970: 0),
    inputUnitIds: [UnitIdentifier] = []
) -> ProvenanceRecord {
    ProvenanceRecord(
        producer: producer,
        method: method,
        timestamp: timestamp,
        inputUnitIds: inputUnitIds
    )
}

// MARK: — Admission Factory

/// Creates a `UnitAdmission` with sensible defaults for testing.
public func makeAdmission(
    subject: UnitSubject = .entity(EntityReference(qualifiedName: "TestEntity")),
    predicate: PredicateIdentifier = PredicateIdentifier(name: "testPredicate", domain: "test"),
    value: TypedValue = .string("testValue"),
    tier: Tier = .t0,
    provenance: ProvenanceRecord? = nil,
    confidence: Confidence = .deterministic,
    grounding: GroundingChain? = nil,
    version: VersionStamp? = nil
) -> UnitAdmission {
    let resolvedProvenance = provenance ?? makeProvenance()
    let resolvedGrounding = grounding ?? .direct(SourcePosition(
        filePath: "test.swift",
        startLine: 1,
        endLine: 10,
        fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
    ))
    let resolvedVersion = version ?? VersionStamp(
        singleSource: ContentHash(bytes: Array(repeating: 0, count: 32))
    )

    return UnitAdmission(
        subject: subject,
        predicate: predicate,
        value: value,
        tier: tier,
        provenance: resolvedProvenance,
        confidence: confidence,
        grounding: resolvedGrounding,
        version: resolvedVersion
    )
}

// MARK: — Content Hash Factory

/// Creates a `ContentHash` from a simple byte pattern for testing.
public func makeContentHash(_ seed: UInt8 = 0) -> ContentHash {
    ContentHash(bytes: Array(repeating: seed, count: 32))
}
