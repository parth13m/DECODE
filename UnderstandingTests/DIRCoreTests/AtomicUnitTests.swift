// AtomicUnitTests.swift — DIRCoreTests
// IAG-004 §3.4: Value type construction, status transitions (valid + invalid)

import Testing
import Foundation
@testable import DIRCore

@Suite("AtomicUnit Construction")
struct AtomicUnitConstructionTests {

    @Test("Unit is created with Active status")
    func unitCreatedActive() {
        let unit = makeTestUnit()
        #expect(unit.status == .active)
        #expect(unit.invalidationMetadata == nil)
        #expect(unit.supersededBy == nil)
    }

    @Test("Unit preserves all 10 fields")
    func unitPreservesFields() {
        let id = UnitIdentifier(rawValue: 42)
        let subject = UnitSubject.entity(EntityReference(qualifiedName: "MyClass"))
        let predicate = PredicateIdentifier(name: "lineCount", domain: "structure")
        let value = TypedValue.integer(150)
        let tier = Tier.t0
        let confidence = Confidence.deterministic
        let provenance = ProvenanceRecord(
            producer: "swift-frontend",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 1000)
        )
        let hash = ContentHash(bytes: Array(repeating: 1, count: 32))
        let grounding = GroundingChain.direct(SourcePosition(
            filePath: "MyClass.swift", startLine: 1, endLine: 50, fileVersion: hash
        ))
        let version = VersionStamp(singleSource: hash)

        let unit = AtomicUnit(
            id: id, subject: subject, predicate: predicate, value: value,
            tier: tier, provenance: provenance, confidence: confidence,
            grounding: grounding, version: version
        )

        #expect(unit.id == id)
        #expect(unit.subject == subject)
        #expect(unit.predicate == predicate)
        #expect(unit.value == value)
        #expect(unit.tier == tier)
        #expect(unit.confidence == confidence)
        #expect(unit.provenance == provenance)
        #expect(unit.grounding == grounding)
        #expect(unit.version == version)
        #expect(unit.status == .active)
    }

    @Test("Supersession key is derived from subject, predicate, tier")
    func supersessionKeyDerived() {
        let unit = makeTestUnit()
        let expected = SupersessionKey(
            subject: unit.subject,
            predicate: unit.predicate,
            tier: unit.tier
        )
        #expect(unit.supersessionKey == expected)
    }
}

@Suite("AtomicUnit Status Transitions")
struct AtomicUnitStatusTransitionTests {

    // MARK: — Valid Transitions

    @Test("Active → Invalidated succeeds")
    func activeToInvalidated() {
        var unit = makeTestUnit()
        let metadata = InvalidationMetadata(
            epoch: Epoch(value: 1),
            reason: .sourceChanged
        )
        unit.invalidate(metadata: metadata)
        #expect(unit.status == .invalidated)
        #expect(unit.invalidationMetadata == metadata)
    }

    @Test("Active → Superseded succeeds")
    func activeToSuperseded() {
        var unit = makeTestUnit()
        let successor = UnitIdentifier(rawValue: 99)
        unit.supersede(by: successor)
        #expect(unit.status == .superseded)
        #expect(unit.supersededBy == successor)
    }

    @Test("Invalidated → Superseded succeeds")
    func invalidatedToSuperseded() {
        var unit = makeTestUnit()
        unit.invalidate(metadata: InvalidationMetadata(epoch: Epoch(value: 1), reason: .sourceChanged))
        let successor = UnitIdentifier(rawValue: 99)
        unit.supersede(by: successor)
        #expect(unit.status == .superseded)
        #expect(unit.supersededBy == successor)
    }

    @Test("Superseded → GarbageCollected succeeds")
    func supersededToGC() {
        var unit = makeTestUnit()
        unit.supersede(by: UnitIdentifier(rawValue: 99))
        unit.garbageCollect()
        #expect(unit.status == .garbageCollected)
    }

    @Test("Invalidated → GarbageCollected succeeds")
    func invalidatedToGC() {
        var unit = makeTestUnit()
        unit.invalidate(metadata: InvalidationMetadata(epoch: Epoch(value: 1), reason: .sourceChanged))
        unit.garbageCollect()
        #expect(unit.status == .garbageCollected)
    }
}

@Suite("UnitStatus Transition Validation")
struct UnitStatusTransitionValidationTests {

    @Test("Valid transitions return true")
    func validTransitions() {
        #expect(UnitStatus.active.canTransition(to: .invalidated))
        #expect(UnitStatus.active.canTransition(to: .superseded))
        #expect(UnitStatus.invalidated.canTransition(to: .superseded))
        #expect(UnitStatus.superseded.canTransition(to: .garbageCollected))
        #expect(UnitStatus.invalidated.canTransition(to: .garbageCollected))
    }

    @Test("Invalid transitions return false")
    func invalidTransitions() {
        // Cannot go backward
        #expect(!UnitStatus.superseded.canTransition(to: .active))
        #expect(!UnitStatus.invalidated.canTransition(to: .active))
        #expect(!UnitStatus.garbageCollected.canTransition(to: .active))

        // Cannot skip to GC from Active
        #expect(!UnitStatus.active.canTransition(to: .garbageCollected))

        // Cannot go from GC to anything
        #expect(!UnitStatus.garbageCollected.canTransition(to: .superseded))
        #expect(!UnitStatus.garbageCollected.canTransition(to: .invalidated))

        // Self-transitions not allowed
        #expect(!UnitStatus.active.canTransition(to: .active))
        #expect(!UnitStatus.invalidated.canTransition(to: .invalidated))
    }
}

// MARK: — Test Helpers

private func makeTestUnit(id: UInt64 = 1) -> AtomicUnit {
    let hash = ContentHash(bytes: Array(repeating: 0, count: 32))
    return AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: "TestEntity")),
        predicate: PredicateIdentifier(name: "test", domain: "test"),
        value: .string("value"),
        tier: .t0,
        provenance: ProvenanceRecord(
            producer: "test", method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: .deterministic,
        grounding: .direct(SourcePosition(
            filePath: "test.swift", startLine: 1, endLine: 1, fileVersion: hash
        )),
        version: VersionStamp(singleSource: hash)
    )
}
