// CodableRoundTripTests.swift — DIRCoreTests
// IAG-004 §3.4: Codable round-trip verification for all DIRCore types
// IAG-002 TI-5: Codable conformance declared in DIRCore

import Testing
import Foundation
@testable import DIRCore

@Suite("Codable Round-Trip")
struct CodableRoundTripTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(decoded == value)
    }

    @Test("UnitIdentifier round-trips")
    func unitIdentifier() throws {
        try roundTrip(UnitIdentifier(rawValue: 42))
        try roundTrip(UnitIdentifier(rawValue: 0))
        try roundTrip(UnitIdentifier(rawValue: UInt64.max))
    }

    @Test("Epoch round-trips")
    func epoch() throws {
        try roundTrip(Epoch.zero)
        try roundTrip(Epoch(value: 999))
    }

    @Test("ContentHash round-trips")
    func contentHash() throws {
        try roundTrip(ContentHash(bytes: Array(repeating: 0xAB, count: 32)))
    }

    @Test("EntityReference round-trips")
    func entityReference() throws {
        try roundTrip(EntityReference(qualifiedName: "MyModule.MyClass.myMethod"))
    }

    @Test("UnitSubject round-trips")
    func unitSubject() throws {
        try roundTrip(UnitSubject.entity(EntityReference(qualifiedName: "Foo")))
        try roundTrip(UnitSubject.pair(EntityPair(
            source: EntityReference(qualifiedName: "A"),
            target: EntityReference(qualifiedName: "B")
        )))
    }

    @Test("PredicateIdentifier round-trips")
    func predicateIdentifier() throws {
        try roundTrip(PredicateIdentifier(name: "lineCount", domain: "structure"))
    }

    @Test("Tier round-trips")
    func tier() throws {
        for t in Tier.allCases {
            try roundTrip(t)
        }
    }

    @Test("Confidence round-trips")
    func confidence() throws {
        for c in Confidence.allCases {
            try roundTrip(c)
        }
    }

    @Test("TypedValue round-trips all variants")
    func typedValue() throws {
        try roundTrip(TypedValue.string("hello"))
        try roundTrip(TypedValue.integer(42))
        try roundTrip(TypedValue.boolean(true))
        try roundTrip(TypedValue.float(3.14))
        try roundTrip(TypedValue.enumerated("caseA"))
        try roundTrip(TypedValue.text("long text"))
        try roundTrip(TypedValue.reference(EntityReference(qualifiedName: "Ref")))
        try roundTrip(TypedValue.structured(["key": .integer(1), "nested": .string("val")]))
    }

    @Test("ProvenanceRecord round-trips")
    func provenance() throws {
        try roundTrip(ProvenanceRecord(
            producer: "swift-frontend",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 1000),
            inputUnitIds: [UnitIdentifier(rawValue: 1), UnitIdentifier(rawValue: 2)]
        ))
    }

    @Test("GroundingChain round-trips all variants")
    func grounding() throws {
        let hash = ContentHash(bytes: Array(repeating: 0, count: 32))
        try roundTrip(GroundingChain.direct(SourcePosition(
            filePath: "test.swift", startLine: 1, endLine: 10, fileVersion: hash
        )))
        try roundTrip(GroundingChain.derived([
            UnitIdentifier(rawValue: 1), UnitIdentifier(rawValue: 2)
        ]))
        try roundTrip(GroundingChain.inferred(
            inputUnits: [UnitIdentifier(rawValue: 3)], method: "semantic-analysis"
        ))
    }

    @Test("VersionStamp round-trips")
    func versionStamp() throws {
        let hash1 = ContentHash(bytes: Array(repeating: 1, count: 32))
        let hash2 = ContentHash(bytes: Array(repeating: 2, count: 32))
        try roundTrip(VersionStamp(singleSource: hash1))
        try roundTrip(VersionStamp(sourceHashes: [hash1, hash2]))
    }

    @Test("UnitStatus round-trips")
    func unitStatus() throws {
        try roundTrip(UnitStatus.active)
        try roundTrip(UnitStatus.invalidated)
        try roundTrip(UnitStatus.superseded)
        try roundTrip(UnitStatus.garbageCollected)
    }

    @Test("InvalidationReason round-trips all variants")
    func invalidationReason() throws {
        try roundTrip(InvalidationReason.sourceChanged)
        try roundTrip(InvalidationReason.groundingCollapse(UnitIdentifier(rawValue: 5)))
        try roundTrip(InvalidationReason.producerUpgrade(producer: "v2-frontend"))
    }

    @Test("SupersessionKey round-trips")
    func supersessionKey() throws {
        try roundTrip(SupersessionKey(
            subject: .entity(EntityReference(qualifiedName: "Foo")),
            predicate: PredicateIdentifier(name: "role", domain: "identity"),
            tier: .t1
        ))
    }

    @Test("UnitAdmission round-trips")
    func unitAdmission() throws {
        let hash = ContentHash(bytes: Array(repeating: 0, count: 32))
        try roundTrip(UnitAdmission(
            subject: .entity(EntityReference(qualifiedName: "Test")),
            predicate: PredicateIdentifier(name: "p", domain: "d"),
            value: .string("v"),
            tier: .t0,
            provenance: ProvenanceRecord(
                producer: "test", method: .extraction,
                timestamp: Date(timeIntervalSince1970: 0)
            ),
            confidence: .deterministic,
            grounding: .direct(SourcePosition(
                filePath: "t.swift", startLine: 1, endLine: 1, fileVersion: hash
            )),
            version: VersionStamp(singleSource: hash)
        ))
    }

    @Test("WriteTransaction round-trips")
    func writeTransaction() throws {
        try roundTrip(WriteTransaction(admissions: [], transitions: []))
    }

    @Test("StatusTransition round-trips")
    func statusTransition() throws {
        try roundTrip(StatusTransition.invalidate(
            UnitIdentifier(rawValue: 1),
            metadata: InvalidationMetadata(epoch: Epoch(value: 1), reason: .sourceChanged)
        ))
        try roundTrip(StatusTransition.supersede(
            UnitIdentifier(rawValue: 2),
            by: UnitIdentifier(rawValue: 3)
        ))
        try roundTrip(StatusTransition.garbageCollect(UnitIdentifier(rawValue: 4)))
    }

    @Test("DemandSignal round-trips")
    func demandSignal() throws {
        try roundTrip(DemandSignal(
            subject: .entity(EntityReference(qualifiedName: "X")),
            predicate: PredicateIdentifier(name: "purpose", domain: "semantic")
        ))
    }
}
