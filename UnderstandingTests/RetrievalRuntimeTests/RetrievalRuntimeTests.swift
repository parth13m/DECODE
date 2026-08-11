// RetrievalRuntimeTests.swift — RetrievalRuntime
// DDS-005: Five-stage evidence retrieval pipeline tests
// IAG-004 §6.4: Anchor resolution, direct evidence, relational evidence,
//               scope evidence, budget enforcement, fallback, ordering

import Testing
import Foundation
@testable import DIRCore
@testable import IndexRuntime
@testable import RetrievalRuntime
@testable import UnderstandingTestSupport

// MARK: — Mocks

/// Mock IndexQuerying for isolated retrieval tests.
final class MockIndexQuerying: IndexQuerying, @unchecked Sendable {
    var entityResults: [EntityReference: IndexQueryResult<EntityIndexEntry>] = [:]
    var graphResults: [String: IndexQueryResult<GraphIndexEntry>] = [:]
    var scopeResults: [EntityReference: IndexQueryResult<ScopeIndexEntry>] = [:]
    var predicateResults: [PredicateIdentifier: IndexQueryResult<PredicateIndexEntry>] = [:]
    var contentResults: [String: IndexQueryResult<ContentIndexEntry>] = [:]

    func queryEntity(
        _ entity: EntityReference,
        predicate: PredicateIdentifier?,
        tier: Tier?,
        status: UnitStatus?
    ) async -> IndexQueryResult<EntityIndexEntry> {
        entityResults[entity] ?? IndexQueryResult(entries: [], usedFallback: false)
    }

    func queryGraph(
        entity: EntityReference,
        predicate: PredicateIdentifier,
        direction: TraversalDirection
    ) async -> IndexQueryResult<GraphIndexEntry> {
        let key = "\(entity.qualifiedName)|\(predicate.name)|\(direction.rawValue)"
        return graphResults[key] ?? IndexQueryResult(entries: [], usedFallback: false)
    }

    func queryScope(_ scope: EntityReference) async -> IndexQueryResult<ScopeIndexEntry> {
        scopeResults[scope] ?? IndexQueryResult(entries: [], usedFallback: false)
    }

    func queryPredicate(
        _ predicate: PredicateIdentifier,
        tier: Tier?,
        status: UnitStatus?,
        producerId: String?
    ) async -> IndexQueryResult<PredicateIndexEntry> {
        predicateResults[predicate] ?? IndexQueryResult(entries: [], usedFallback: false)
    }

    func queryContent(term: String) async -> IndexQueryResult<ContentIndexEntry> {
        contentResults[term] ?? IndexQueryResult(entries: [], usedFallback: false)
    }
}

/// Mock IndexFreshness for isolated retrieval tests.
final class MockIndexFreshness: IndexFreshness, @unchecked Sendable {
    var report: FreshnessReport = FreshnessReport(families: [:])

    func freshnessReport() async -> FreshnessReport { report }

    func familyFreshness(_ family: IndexFamily) async -> FamilyFreshnessReport {
        report.families[family] ?? FamilyFreshnessReport(
            family: family,
            lastUpdateEpoch: nil,
            staleEntryCount: 0,
            availability: .absent,
            memoryFootprintBytes: 0,
            entryCount: 0
        )
    }

    func familyAvailability(_ family: IndexFamily) async -> IndexFamilyAvailability {
        report.families[family]?.availability ?? .absent
    }
}

// MARK: — Test Helpers

private let callsPredicate = PredicateIdentifier(name: "calls", domain: "relationship")
private let conformsToPredicate = PredicateIdentifier(name: "conformsTo", domain: "relationship")
private let inheritsPredicate = PredicateIdentifier(name: "inherits", domain: "relationship")
private let testPredicate = PredicateIdentifier(name: "testPredicate", domain: "test")

private func makeService(
    indexQuerying: MockIndexQuerying = MockIndexQuerying(),
    indexFreshness: MockIndexFreshness = MockIndexFreshness(),
    dirAccess: MockDIRReadAccess = MockDIRReadAccess()
) -> RetrievalService {
    RetrievalService(
        indexQuerying: indexQuerying,
        indexFreshness: indexFreshness,
        dirAccess: dirAccess
    )
}

private func makeEntityRef(_ name: String) -> EntityReference {
    EntityReference(qualifiedName: name)
}

private func makeUnitWithEntity(
    id: UInt64,
    entity: String,
    predicate: PredicateIdentifier = testPredicate,
    tier: Tier = .t0,
    confidence: Confidence = .deterministic,
    filePath: String = "test.swift",
    startLine: Int = 1,
    endLine: Int = 10
) -> AtomicUnit {
    makeUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entity)),
        predicate: predicate,
        tier: tier,
        confidence: confidence,
        grounding: .direct(SourcePosition(
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            fileVersion: makeContentHash(0)
        ))
    )
}

/// Sets up entity index entries and DIR units for a given entity.
private func setupEntity(
    _ entityName: String,
    units: [AtomicUnit],
    indexQuerying: MockIndexQuerying,
    dirAccess: MockDIRReadAccess
) {
    let entityRef = makeEntityRef(entityName)
    let entries = units.map { unit in
        EntityIndexEntry(
            unitId: unit.id,
            predicate: unit.predicate,
            tier: unit.tier,
            status: unit.status
        )
    }
    indexQuerying.entityResults[entityRef] = IndexQueryResult(entries: entries, usedFallback: false)
    for unit in units {
        dirAccess.units[unit.id] = unit
    }
}

// MARK: — Anchor Resolution Tests

@Suite("Anchor Resolution")
struct AnchorResolutionTests {

    @Test("EntityReference for existing entity resolves to that entity")
    func entityRefExisting() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()
        let unit = makeUnitWithEntity(id: 1, entity: "MyClass")
        setupEntity("MyClass", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let anchors = await service.resolveAnchors(for: .entity(makeEntityRef("MyClass")))

        #expect(anchors == [makeEntityRef("MyClass")])
    }

    @Test("EntityReference for non-existent entity returns empty")
    func entityRefNonExistent() async {
        let service = makeService()
        let anchors = await service.resolveAnchors(for: .entity(makeEntityRef("Missing")))
        #expect(anchors.isEmpty)
    }

    @Test("SnippetReference within entity source range resolves to that entity")
    func snippetInEntity() async {
        let dirAccess = MockDIRReadAccess()
        let indexQuerying = MockIndexQuerying()
        let unit = makeUnitWithEntity(id: 1, entity: "MyFunc", filePath: "app.swift", startLine: 5, endLine: 20)
        dirAccess.units[unit.id] = unit

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let snippet = SnippetReference(filePath: "app.swift", startLine: 10, endLine: 15)
        let anchors = await service.resolveAnchors(for: .snippet(snippet))

        #expect(anchors == [makeEntityRef("MyFunc")])
    }

    @Test("SnippetReference spanning multiple entities resolves to all containing entities")
    func snippetMultipleEntities() async {
        let dirAccess = MockDIRReadAccess()
        let indexQuerying = MockIndexQuerying()

        let unit1 = makeUnitWithEntity(id: 1, entity: "ClassA", filePath: "app.swift", startLine: 1, endLine: 30)
        let unit2 = makeUnitWithEntity(id: 2, entity: "MethodB", filePath: "app.swift", startLine: 5, endLine: 25)
        dirAccess.units[unit1.id] = unit1
        dirAccess.units[unit2.id] = unit2

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let snippet = SnippetReference(filePath: "app.swift", startLine: 10, endLine: 20)
        let anchors = await service.resolveAnchors(for: .snippet(snippet))

        #expect(anchors.count == 2)
        #expect(anchors.contains(makeEntityRef("ClassA")))
        #expect(anchors.contains(makeEntityRef("MethodB")))
    }

    @Test("SnippetReference outside all entity ranges with file scope falls back to file scope")
    func snippetFallbackToFileScope() async {
        let dirAccess = MockDIRReadAccess()
        let indexQuerying = MockIndexQuerying()

        // No entity covers lines 100-110, but file scope entity exists.
        // File entities use canonical "file:<filename>" qualified names
        // (see FrontendOutputConversion.convert).
        let fileScopeUnit = makeUnitWithEntity(id: 1, entity: "file:app.swift", filePath: "other.swift", startLine: 1, endLine: 1)
        dirAccess.units[fileScopeUnit.id] = fileScopeUnit
        indexQuerying.entityResults[makeEntityRef("file:app.swift")] = IndexQueryResult(
            entries: [EntityIndexEntry(unitId: fileScopeUnit.id, predicate: testPredicate, tier: .t0, status: .active)],
            usedFallback: false
        )

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let snippet = SnippetReference(filePath: "app.swift", startLine: 100, endLine: 110)
        let anchors = await service.resolveAnchors(for: .snippet(snippet))

        #expect(anchors == [makeEntityRef("file:app.swift")])
    }

    @Test("SnippetReference outside all ranges with no file scope returns empty")
    func snippetNoFallback() async {
        let dirAccess = MockDIRReadAccess()
        let service = makeService(dirAccess: dirAccess)
        let snippet = SnippetReference(filePath: "missing.swift", startLine: 1, endLine: 5)
        let anchors = await service.resolveAnchors(for: .snippet(snippet))
        #expect(anchors.isEmpty)
    }

    @Test("ScopeReference for existing scope resolves to that scope")
    func scopeRefExisting() async {
        let indexQuerying = MockIndexQuerying()
        let scopeRef = makeEntityRef("MyModule")
        indexQuerying.scopeResults[scopeRef] = IndexQueryResult(
            entries: [ScopeIndexEntry(containedEntity: makeEntityRef("ClassA"), depth: 1)],
            usedFallback: false
        )

        let service = makeService(indexQuerying: indexQuerying)
        let anchors = await service.resolveAnchors(for: .scope(scopeRef))
        #expect(anchors == [scopeRef])
    }

    @Test("Anchor resolution is deterministic")
    func anchorDeterminism() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()
        let unit = makeUnitWithEntity(id: 1, entity: "Stable")
        setupEntity("Stable", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let first = await service.resolveAnchors(for: .entity(makeEntityRef("Stable")))
        let second = await service.resolveAnchors(for: .entity(makeEntityRef("Stable")))
        #expect(first == second)
    }
}

// MARK: — Direct Evidence Tests

@Suite("Direct Evidence")
struct DirectEvidenceTests {

    @Test("Direct evidence returns all units for anchor entity")
    func allUnitsReturned() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()
        dirAccess.epoch = makeEpoch(5)

        var units: [AtomicUnit] = []
        for i in 1...10 {
            let unit = makeUnitWithEntity(id: UInt64(i), entity: "Target")
            units.append(unit)
        }
        setupEntity("Target", units: units, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Target")), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 10)
        #expect(result.anchors == [makeEntityRef("Target")])
        #expect(result.metadata.observedEpoch == makeEpoch(5))
    }

    @Test("Tier floor filters out units below the floor")
    func tierFloorFilter() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let t0Unit = makeUnitWithEntity(id: 1, entity: "E", tier: .t0)
        let t1Unit = makeUnitWithEntity(id: 2, entity: "E", tier: .t1, confidence: .high)
        setupEntity("E", units: [t0Unit, t1Unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            tierFloor: .t1,
            tierCeiling: .t2
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].unit.tier == .t1)
    }

    @Test("Tier ceiling filters out units above the ceiling")
    func tierCeilingFilter() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let t0Unit = makeUnitWithEntity(id: 1, entity: "E", tier: .t0)
        let t2Unit = makeUnitWithEntity(id: 2, entity: "E", tier: .t2, confidence: .high)
        setupEntity("E", units: [t0Unit, t2Unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            tierCeiling: .t0
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].unit.tier == .t0)
    }

    @Test("Confidence floor filters out units below threshold")
    func confidenceFloorFilter() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let highUnit = makeUnitWithEntity(id: 1, entity: "E", tier: .t1, confidence: .high)
        let lowUnit = makeUnitWithEntity(id: 2, entity: "E", tier: .t1, confidence: .low)
        setupEntity("E", units: [highUnit, lowUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            tierFloor: .t1,
            confidenceFloor: .moderate
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].unit.confidence == .high)
    }

    @Test("Direct evidence has distance 0 and 'direct' provenance")
    func directProvenance() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()
        let unit = makeUnitWithEntity(id: 1, entity: "E")
        setupEntity("E", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].distance == 0)
        #expect(result.evidence[0].provenance.stage == .direct)
        #expect(result.evidence[0].provenance.path == ["direct"])
    }
}

// MARK: — Relational Evidence Tests

@Suite("Relational Evidence")
struct RelationalEvidenceTests {

    @Test("1-hop traversal returns entities the anchor calls")
    func oneHopForward() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Anchor entity "A" with one direct unit
        let anchorUnit = makeUnitWithEntity(id: 1, entity: "A")
        setupEntity("A", units: [anchorUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // "A" calls "B" — graph edge
        let edgeUnit = makeUnit(
            id: UnitIdentifier(rawValue: 10),
            subject: .pair(EntityPair(source: makeEntityRef("A"), target: makeEntityRef("B"))),
            predicate: callsPredicate
        )
        dirAccess.units[edgeUnit.id] = edgeUnit

        indexQuerying.graphResults["A|calls|forward"] = IndexQueryResult(
            entries: [GraphIndexEntry(neighbor: makeEntityRef("B"), unitId: edgeUnit.id, tier: .t0, status: .active)],
            usedFallback: false
        )

        // "B" has its own units
        let bUnit = makeUnitWithEntity(id: 20, entity: "B")
        setupEntity("B", units: [bUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("A")), intent: .explain)
        let result = await service.retrieve(request)

        // Should have: anchor's direct unit, edge unit, B's unit
        let relationalUnits = result.evidence.filter { $0.provenance.stage == .relational }
        #expect(!relationalUnits.isEmpty)

        // Edge and neighbor units should have distance >= 1
        for unit in relationalUnits {
            #expect(unit.distance >= 1)
        }
    }

    @Test("Traversal depth limit is respected")
    func depthLimitRespected() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let anchorUnit = makeUnitWithEntity(id: 1, entity: "Root")
        setupEntity("Root", units: [anchorUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Root calls A, A calls B (2 hops)
        let edgeRA = makeUnit(id: UnitIdentifier(rawValue: 10), subject: .pair(EntityPair(source: makeEntityRef("Root"), target: makeEntityRef("A"))), predicate: callsPredicate)
        dirAccess.units[edgeRA.id] = edgeRA
        indexQuerying.graphResults["Root|calls|forward"] = IndexQueryResult(
            entries: [GraphIndexEntry(neighbor: makeEntityRef("A"), unitId: edgeRA.id, tier: .t0, status: .active)],
            usedFallback: false
        )

        let aUnit = makeUnitWithEntity(id: 20, entity: "A")
        setupEntity("A", units: [aUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let edgeAB = makeUnit(id: UnitIdentifier(rawValue: 30), subject: .pair(EntityPair(source: makeEntityRef("A"), target: makeEntityRef("B"))), predicate: callsPredicate)
        dirAccess.units[edgeAB.id] = edgeAB
        indexQuerying.graphResults["A|calls|forward"] = IndexQueryResult(
            entries: [GraphIndexEntry(neighbor: makeEntityRef("B"), unitId: edgeAB.id, tier: .t0, status: .active)],
            usedFallback: false
        )

        let bUnit = makeUnitWithEntity(id: 40, entity: "B")
        setupEntity("B", units: [bUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Explain intent has maxDepth=1 for calls, so B (distance 2) should not appear
        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Root")), intent: .explain)
        let result = await service.retrieve(request)

        let relationalIds = Set(result.evidence.filter { $0.provenance.stage == .relational }.map(\.unit.id))
        // Edge RA and A's unit should be included (depth 1), but B should not
        #expect(relationalIds.contains(edgeRA.id))
        #expect(relationalIds.contains(aUnit.id))
        #expect(!relationalIds.contains(bUnit.id))
    }

    @Test("Relational evidence records correct distance from anchor")
    func correctDistance() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let anchorUnit = makeUnitWithEntity(id: 1, entity: "Origin")
        setupEntity("Origin", units: [anchorUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let edgeUnit = makeUnit(id: UnitIdentifier(rawValue: 10), subject: .pair(EntityPair(source: makeEntityRef("Origin"), target: makeEntityRef("Dest"))), predicate: callsPredicate)
        dirAccess.units[edgeUnit.id] = edgeUnit
        indexQuerying.graphResults["Origin|calls|forward"] = IndexQueryResult(
            entries: [GraphIndexEntry(neighbor: makeEntityRef("Dest"), unitId: edgeUnit.id, tier: .t0, status: .active)],
            usedFallback: false
        )

        let destUnit = makeUnitWithEntity(id: 20, entity: "Dest")
        setupEntity("Dest", units: [destUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Origin")), intent: .explain)
        let result = await service.retrieve(request)

        let relational = result.evidence.filter { $0.provenance.stage == .relational }
        for unit in relational {
            #expect(unit.distance == 1)
        }
    }
}

// MARK: — Scope Evidence Tests

@Suite("Scope Evidence")
struct ScopeEvidenceTests {

    @Test("Narrow scope gathers no scope evidence")
    func narrowScope() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let unit = makeUnitWithEntity(id: 1, entity: "E", filePath: "test.swift")
        setupEntity("E", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain, scope: .narrow)
        let result = await service.retrieve(request)

        let scopeUnits = result.evidence.filter { $0.provenance.stage == .scope }
        #expect(scopeUnits.isEmpty)
    }

    @Test("Local scope gathers file-level scope evidence")
    func localScope() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Entity with grounding to test.swift
        let entityUnit = makeUnitWithEntity(id: 1, entity: "MyFunc", filePath: "test.swift", startLine: 5, endLine: 20)
        setupEntity("MyFunc", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // File scope entity — canonical "file:<filename>" naming per FrontendOutputConversion
        let fileScopeUnit = makeUnitWithEntity(id: 100, entity: "file:test.swift", filePath: "test.swift", startLine: 1, endLine: 50)
        setupEntity("file:test.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("MyFunc")), intent: .explain, scope: .local)
        let result = await service.retrieve(request)

        let scopeUnits = result.evidence.filter { $0.provenance.stage == .scope }
        #expect(!scopeUnits.isEmpty)
        #expect(scopeUnits.allSatisfy { $0.provenance.path.first == "scope" })
    }
}

// MARK: — Module Scope Evidence Tests (M5)

@Suite("Module Scope Evidence")
struct ModuleScopeEvidenceTests {

    @Test("Module scope gathers module entity evidence at distance 2")
    func moduleScopeGathersModuleEvidence() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Entity in /src/ModA/File.swift
        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "MyClass",
            filePath: "/src/ModA/File.swift", startLine: 5, endLine: 20
        )
        setupEntity("MyClass", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // File scope entity — canonical "file:<filename>" naming per FrontendOutputConversion
        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:File.swift",
            filePath: "/src/ModA/File.swift", startLine: 1, endLine: 50
        )
        setupEntity("file:File.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Module entity — T1 emergence predicate
        let moduleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 100),
            subject: .entity(EntityReference(qualifiedName: "module:ModA")),
            predicate: PredicateIdentifier(name: "cohesion", domain: "emergence"),
            value: .structured(["ratio": .float(0.8)]),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        setupEntity("module:ModA", units: [moduleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("MyClass")),
            intent: .explain,
            scope: .module
        )
        let result = await service.retrieve(request)

        let moduleScopeUnits = result.evidence.filter {
            $0.provenance.stage == .scope && $0.provenance.path.contains("module:ModA")
        }
        #expect(!moduleScopeUnits.isEmpty)
        #expect(moduleScopeUnits.allSatisfy { $0.distance == 2 })
    }

    @Test("Local scope does not gather module evidence")
    func localScopeNoModuleEvidence() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "MyClass",
            filePath: "/src/ModA/File.swift"
        )
        setupEntity("MyClass", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:File.swift",
            filePath: "/src/ModA/File.swift"
        )
        setupEntity("file:File.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let moduleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 100),
            subject: .entity(EntityReference(qualifiedName: "module:ModA")),
            predicate: PredicateIdentifier(name: "cohesion", domain: "emergence"),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        setupEntity("module:ModA", units: [moduleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("MyClass")),
            intent: .explain,
            scope: .local
        )
        let result = await service.retrieve(request)

        let moduleScopeUnits = result.evidence.filter {
            $0.provenance.path.contains("module:ModA")
        }
        #expect(moduleScopeUnits.isEmpty)
    }

    @Test("Module scope includes both file and module evidence")
    func moduleScopeIncludesBothLevels() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "Svc",
            filePath: "/src/Infra/Svc.swift", startLine: 1, endLine: 30
        )
        setupEntity("Svc", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:Svc.swift",
            filePath: "/src/Infra/Svc.swift"
        )
        setupEntity("file:Svc.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let moduleRoleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 100),
            subject: .entity(EntityReference(qualifiedName: "module:Infra")),
            predicate: PredicateIdentifier(name: "moduleRole", domain: "emergence"),
            value: .string("provider"),
            tier: .t1,
            confidence: .moderate,
            grounding: .derived([])
        )
        setupEntity("module:Infra", units: [moduleRoleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Svc")),
            intent: .explain,
            scope: .module
        )
        let result = await service.retrieve(request)

        let fileScopeEvidence = result.evidence.filter {
            $0.provenance.stage == .scope && $0.distance == 1
        }
        let moduleScopeEvidence = result.evidence.filter {
            $0.provenance.stage == .scope && $0.distance == 2
        }

        #expect(!fileScopeEvidence.isEmpty)
        #expect(!moduleScopeEvidence.isEmpty)
    }

    @Test("Module scope with no module entity produces file-scope only")
    func moduleScopeNoModuleEntity() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "Solo",
            filePath: "/src/Alone/Solo.swift", startLine: 1, endLine: 10
        )
        setupEntity("Solo", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:Solo.swift",
            filePath: "/src/Alone/Solo.swift"
        )
        setupEntity("file:Solo.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // No module entity registered in index — module:Alone does not exist
        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Solo")),
            intent: .explain,
            scope: .module
        )
        let result = await service.retrieve(request)

        let fileScopeEvidence = result.evidence.filter { $0.provenance.stage == .scope }
        #expect(!fileScopeEvidence.isEmpty)
        #expect(fileScopeEvidence.allSatisfy { $0.distance == 1 })
    }

    @Test("Module scope respects tier filter")
    func moduleScopeRespectsTierFilter() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "E",
            filePath: "/src/Mod/E.swift"
        )
        setupEntity("E", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:E.swift",
            filePath: "/src/Mod/E.swift"
        )
        setupEntity("file:E.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Module entity at T1
        let moduleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 100),
            subject: .entity(EntityReference(qualifiedName: "module:Mod")),
            predicate: PredicateIdentifier(name: "cohesion", domain: "emergence"),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        setupEntity("module:Mod", units: [moduleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        // Request with tierCeiling = .t0 should exclude T1 module evidence
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            scope: .module,
            tierCeiling: .t0
        )
        let result = await service.retrieve(request)

        let moduleEvidence = result.evidence.filter {
            $0.provenance.path.contains("module:Mod")
        }
        #expect(moduleEvidence.isEmpty)
    }
}

// MARK: — System Scope Evidence Tests (M10)

@Suite("System Scope Evidence")
struct SystemScopeEvidenceTests {

    @Test("System scope gathers system entity evidence at distance 3")
    func systemScopeGathersSystemEvidence() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Entity in /src/ModA/File.swift
        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "MyClass",
            filePath: "/src/ModA/File.swift", startLine: 5, endLine: 20
        )
        setupEntity("MyClass", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // File scope entity
        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:File.swift",
            filePath: "/src/ModA/File.swift", startLine: 1, endLine: 50
        )
        setupEntity("file:File.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Module entity
        let moduleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 100),
            subject: .entity(EntityReference(qualifiedName: "module:ModA")),
            predicate: PredicateIdentifier(name: "cohesion", domain: "emergence"),
            value: .structured(["ratio": .float(0.8)]),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        setupEntity("module:ModA", units: [moduleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // System entity — T1 kind:structure = "system"
        let systemKindUnit = makeUnit(
            id: UnitIdentifier(rawValue: 200),
            subject: .entity(EntityReference(qualifiedName: "system:MyProject")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("system"),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        dirAccess.units[systemKindUnit.id] = systemKindUnit

        // System entity properties
        let systemPropUnit = makeUnit(
            id: UnitIdentifier(rawValue: 201),
            subject: .entity(EntityReference(qualifiedName: "system:MyProject")),
            predicate: PredicateIdentifier(name: "architectureStyle", domain: "emergence"),
            value: .string("layered"),
            tier: .t1,
            confidence: .moderate,
            grounding: .derived([])
        )
        setupEntity("system:MyProject", units: [systemKindUnit, systemPropUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("MyClass")),
            intent: .explain,
            scope: .system
        )
        let result = await service.retrieve(request)

        let systemScopeUnits = result.evidence.filter {
            $0.provenance.stage == .scope && $0.provenance.path.contains("system:MyProject")
        }
        #expect(!systemScopeUnits.isEmpty)
        #expect(systemScopeUnits.allSatisfy { $0.distance == 3 })
    }

    @Test("Module scope does not gather system evidence")
    func moduleScopeNoSystemEvidence() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "MyClass",
            filePath: "/src/ModA/File.swift"
        )
        setupEntity("MyClass", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:File.swift",
            filePath: "/src/ModA/File.swift"
        )
        setupEntity("file:File.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // System entity
        let systemKindUnit = makeUnit(
            id: UnitIdentifier(rawValue: 200),
            subject: .entity(EntityReference(qualifiedName: "system:MyProject")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("system"),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        dirAccess.units[systemKindUnit.id] = systemKindUnit
        setupEntity("system:MyProject", units: [systemKindUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("MyClass")),
            intent: .explain,
            scope: .module
        )
        let result = await service.retrieve(request)

        let systemUnits = result.evidence.filter {
            $0.provenance.path.contains("system:MyProject")
        }
        #expect(systemUnits.isEmpty)
    }

    @Test("System scope includes file, module, and system evidence")
    func systemScopeIncludesAllLevels() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "Svc",
            filePath: "/src/Infra/Svc.swift", startLine: 1, endLine: 30
        )
        setupEntity("Svc", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:Svc.swift",
            filePath: "/src/Infra/Svc.swift"
        )
        setupEntity("file:Svc.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let moduleRoleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 100),
            subject: .entity(EntityReference(qualifiedName: "module:Infra")),
            predicate: PredicateIdentifier(name: "moduleRole", domain: "emergence"),
            value: .string("provider"),
            tier: .t1,
            confidence: .moderate,
            grounding: .derived([])
        )
        setupEntity("module:Infra", units: [moduleRoleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let systemKindUnit = makeUnit(
            id: UnitIdentifier(rawValue: 200),
            subject: .entity(EntityReference(qualifiedName: "system:App")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("system"),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        dirAccess.units[systemKindUnit.id] = systemKindUnit

        let systemStyleUnit = makeUnit(
            id: UnitIdentifier(rawValue: 201),
            subject: .entity(EntityReference(qualifiedName: "system:App")),
            predicate: PredicateIdentifier(name: "architectureStyle", domain: "emergence"),
            value: .string("layered"),
            tier: .t1,
            confidence: .moderate,
            grounding: .derived([])
        )
        setupEntity("system:App", units: [systemKindUnit, systemStyleUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Svc")),
            intent: .explain,
            scope: .system
        )
        let result = await service.retrieve(request)

        let fileScopeEvidence = result.evidence.filter {
            $0.provenance.stage == .scope && $0.distance == 1
        }
        let moduleScopeEvidence = result.evidence.filter {
            $0.provenance.stage == .scope && $0.distance == 2
        }
        let systemScopeEvidence = result.evidence.filter {
            $0.provenance.stage == .scope && $0.distance == 3
        }

        #expect(!fileScopeEvidence.isEmpty)
        #expect(!moduleScopeEvidence.isEmpty)
        #expect(!systemScopeEvidence.isEmpty)
    }

    @Test("System scope respects tier filter")
    func systemScopeRespectsTierFilter() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let entityUnit = makeUnitWithEntity(
            id: 1, entity: "E",
            filePath: "/src/Mod/E.swift"
        )
        setupEntity("E", units: [entityUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let fileScopeUnit = makeUnitWithEntity(
            id: 10, entity: "file:E.swift",
            filePath: "/src/Mod/E.swift"
        )
        setupEntity("file:E.swift", units: [fileScopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // System entity at T1
        let systemKindUnit = makeUnit(
            id: UnitIdentifier(rawValue: 200),
            subject: .entity(EntityReference(qualifiedName: "system:Proj")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("system"),
            tier: .t1,
            confidence: .high,
            grounding: .derived([])
        )
        dirAccess.units[systemKindUnit.id] = systemKindUnit

        let systemPropUnit = makeUnit(
            id: UnitIdentifier(rawValue: 201),
            subject: .entity(EntityReference(qualifiedName: "system:Proj")),
            predicate: PredicateIdentifier(name: "architectureStyle", domain: "emergence"),
            value: .string("layered"),
            tier: .t1,
            confidence: .moderate,
            grounding: .derived([])
        )
        setupEntity("system:Proj", units: [systemKindUnit, systemPropUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        // Request with tierCeiling = .t0 should exclude T1 system evidence
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            scope: .system,
            tierCeiling: .t0
        )
        let result = await service.retrieve(request)

        let systemEvidence = result.evidence.filter {
            $0.provenance.path.contains("system:Proj")
        }
        #expect(systemEvidence.isEmpty)
    }
}

// MARK: — Budget Enforcement Tests

@Suite("Budget Enforcement")
struct BudgetEnforcementTests {

    @Test("Budget limits total evidence count")
    func budgetLimit() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        var units: [AtomicUnit] = []
        for i in 1...20 {
            units.append(makeUnitWithEntity(id: UInt64(i), entity: "Big"))
        }
        setupEntity("Big", units: units, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Big")),
            intent: .explain,
            budget: 10
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count <= 10)
        #expect(result.metadata.budgetConsumed <= 10)
        #expect(result.metadata.budgetAllocated == 10)
    }

    @Test("Budget exhaustion produces valid evidence set with truncation metadata")
    func budgetExhaustionMetadata() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        var units: [AtomicUnit] = []
        for i in 1...50 {
            units.append(makeUnitWithEntity(id: UInt64(i), entity: "Large"))
        }
        setupEntity("Large", units: units, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Large")),
            intent: .explain,
            budget: 5
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count <= 5)
        #expect(result.metadata.truncated)
        #expect(!result.metadata.truncatedStages.isEmpty)
    }

    @Test("Total evidence across all stages does not exceed total budget")
    func totalBudgetRespected() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Setup anchor with many direct units
        var anchorUnits: [AtomicUnit] = []
        for i in 1...30 {
            anchorUnits.append(makeUnitWithEntity(id: UInt64(i), entity: "Center"))
        }
        setupEntity("Center", units: anchorUnits, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Center")),
            intent: .explain,
            budget: 15
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count <= 15)
    }
}

// MARK: — Annotation and Ordering Tests

@Suite("Annotation and Ordering")
struct AnnotationOrderingTests {

    @Test("Evidence is ordered: direct before relational before scope")
    func stageOrdering() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Direct evidence
        let directUnit = makeUnitWithEntity(id: 1, entity: "E", filePath: "test.swift")
        setupEntity("E", units: [directUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Relational evidence
        let edgeUnit = makeUnit(id: UnitIdentifier(rawValue: 10), subject: .pair(EntityPair(source: makeEntityRef("E"), target: makeEntityRef("F"))), predicate: callsPredicate)
        dirAccess.units[edgeUnit.id] = edgeUnit
        indexQuerying.graphResults["E|calls|forward"] = IndexQueryResult(
            entries: [GraphIndexEntry(neighbor: makeEntityRef("F"), unitId: edgeUnit.id, tier: .t0, status: .active)],
            usedFallback: false
        )
        let fUnit = makeUnitWithEntity(id: 20, entity: "F")
        setupEntity("F", units: [fUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Scope evidence
        let scopeUnit = makeUnitWithEntity(id: 100, entity: "test.swift", filePath: "test.swift", startLine: 1, endLine: 50)
        setupEntity("test.swift", units: [scopeUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain, scope: .local)
        let result = await service.retrieve(request)

        // Verify ordering: direct stages come first
        var lastStage: EvidenceStage? = nil
        for unit in result.evidence {
            if let prev = lastStage {
                #expect(unit.provenance.stage >= prev)
            }
            lastStage = unit.provenance.stage
        }
    }

    @Test("Within same stage, evidence ordered by ascending distance")
    func distanceOrdering() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let anchorUnit = makeUnitWithEntity(id: 1, entity: "Root")
        setupEntity("Root", units: [anchorUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Root")), intent: .explain)
        let result = await service.retrieve(request)

        for i in 1..<result.evidence.count {
            let prev = result.evidence[i - 1]
            let curr = result.evidence[i]
            if prev.provenance.stage == curr.provenance.stage {
                #expect(curr.distance >= prev.distance)
            }
        }
    }

    @Test("Within same stage and distance, ordered by ascending unit ID")
    func unitIdOrdering() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        var units: [AtomicUnit] = []
        // Create units with non-sequential IDs to verify sorting
        for id in [5, 3, 7, 1, 9] as [UInt64] {
            units.append(makeUnitWithEntity(id: id, entity: "Sorted"))
        }
        setupEntity("Sorted", units: units, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Sorted")), intent: .explain)
        let result = await service.retrieve(request)

        let directUnits = result.evidence.filter { $0.provenance.stage == .direct }
        for i in 1..<directUnits.count {
            #expect(directUnits[i].unit.id > directUnits[i - 1].unit.id)
        }
    }

    @Test("Every annotated unit has non-empty evidence provenance")
    func provenanceCompleteness() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let unit = makeUnitWithEntity(id: 1, entity: "E")
        setupEntity("E", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain)
        let result = await service.retrieve(request)

        for annotated in result.evidence {
            #expect(!annotated.provenance.path.isEmpty)
            #expect(annotated.distance >= 0)
        }
    }

    @Test("Tier and confidence match underlying DIR unit")
    func tierConfidenceMatch() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let unit = makeUnitWithEntity(id: 1, entity: "E", tier: .t1, confidence: .high)
        setupEntity("E", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            tierFloor: .t1
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].unit.tier == .t1)
        #expect(result.evidence[0].unit.confidence == .high)
    }

    @Test("Deduplicated units appear once at shortest distance")
    func deduplication() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Unit that is both direct evidence and reachable via graph
        let sharedUnit = makeUnitWithEntity(id: 1, entity: "Shared")
        setupEntity("Shared", units: [sharedUnit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        // Shared also appears as neighbor in graph (would be distance 1)
        let edgeUnit = makeUnit(id: UnitIdentifier(rawValue: 10), subject: .pair(EntityPair(source: makeEntityRef("Shared"), target: makeEntityRef("Shared"))), predicate: callsPredicate)
        dirAccess.units[edgeUnit.id] = edgeUnit
        indexQuerying.graphResults["Shared|calls|forward"] = IndexQueryResult(
            entries: [GraphIndexEntry(neighbor: makeEntityRef("Shared"), unitId: edgeUnit.id, tier: .t0, status: .active)],
            usedFallback: false
        )

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Shared")), intent: .explain)
        let result = await service.retrieve(request)

        // sharedUnit should appear exactly once (direct at distance 0)
        let occurrences = result.evidence.filter { $0.unit.id == sharedUnit.id }
        #expect(occurrences.count == 1)
        #expect(occurrences[0].distance == 0)
    }

    @Test("Two identical requests produce identically ordered evidence")
    func deterministicOrdering() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        var units: [AtomicUnit] = []
        for i in 1...5 {
            units.append(makeUnitWithEntity(id: UInt64(i), entity: "Deterministic"))
        }
        setupEntity("Deterministic", units: units, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Deterministic")), intent: .explain)

        let result1 = await service.retrieve(request)
        let result2 = await service.retrieve(request)

        #expect(result1.evidence.count == result2.evidence.count)
        for (a, b) in zip(result1.evidence, result2.evidence) {
            #expect(a.unit.id == b.unit.id)
            #expect(a.distance == b.distance)
            #expect(a.provenance.stage == b.provenance.stage)
        }
    }
}

// MARK: — Consistency Tests

@Suite("Consistency")
struct ConsistencyTests {

    @Test("All evidence observes the same committed epoch")
    func singleEpochEvidence() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()
        dirAccess.epoch = makeEpoch(42)

        let unit = makeUnitWithEntity(id: 1, entity: "E")
        setupEntity("E", units: [unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.metadata.observedEpoch == makeEpoch(42))
    }
}

// MARK: — Tier Degradation Tests

@Suite("Tier Degradation")
struct TierDegradationTests {

    @Test("With T2 absent, returns T0 and T1 evidence with absent tier metadata")
    func t2Absent() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let t0Unit = makeUnitWithEntity(id: 1, entity: "E", tier: .t0)
        let t1Unit = makeUnitWithEntity(id: 2, entity: "E", tier: .t1, confidence: .high)
        setupEntity("E", units: [t0Unit, t1Unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 2)
        #expect(result.metadata.availableTiers.contains(.t0))
        #expect(result.metadata.availableTiers.contains(.t1))
        #expect(result.metadata.absentTiers.contains(.t2))
    }

    @Test("With T1 and T2 absent, returns T0 evidence only")
    func t1t2Absent() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let t0Unit = makeUnitWithEntity(id: 1, entity: "E", tier: .t0)
        setupEntity("E", units: [t0Unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(makeEntityRef("E")), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.metadata.absentTiers.contains(.t1))
        #expect(result.metadata.absentTiers.contains(.t2))
    }

    @Test("Tier absence does not cause retrieval failure")
    func tierAbsenceNoFailure() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let t0Unit = makeUnitWithEntity(id: 1, entity: "E", tier: .t0)
        setupEntity("E", units: [t0Unit], indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            tierFloor: .t0,
            tierCeiling: .t2
        )
        let result = await service.retrieve(request)

        // Valid evidence set even with absent tiers
        #expect(!result.metadata.subjectNotFound)
        #expect(!result.evidence.isEmpty)
    }
}

// MARK: — Graceful Degradation Tests

@Suite("Graceful Degradation")
struct GracefulDegradationTests {

    @Test("Index family fallback is recorded in metadata")
    func fallbackRecorded() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        let unit = makeUnitWithEntity(id: 1, entity: "E")
        let entityRef = makeEntityRef("E")
        indexQuerying.entityResults[entityRef] = IndexQueryResult(
            entries: [EntityIndexEntry(unitId: unit.id, predicate: testPredicate, tier: .t0, status: .active)],
            usedFallback: true  // DIR scan fallback
        )
        dirAccess.units[unit.id] = unit

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(entityRef), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.metadata.fallbackFamilies.contains(.entity))
        #expect(!result.evidence.isEmpty)
    }
}

// MARK: — Failure Mode Tests

@Suite("Failure Modes")
struct FailureModeTests {

    @Test("FM-1: Subject not found returns empty evidence set with metadata")
    func subjectNotFound() async {
        let service = makeService()
        let request = RetrievalRequest(subject: .entity(makeEntityRef("Missing")), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.anchors.isEmpty)
        #expect(result.evidence.isEmpty)
        #expect(result.metadata.subjectNotFound)
    }

    @Test("FM-2: Budget exhaustion produces truncated but valid evidence set")
    func budgetExhaustion() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        var units: [AtomicUnit] = []
        for i in 1...100 {
            units.append(makeUnitWithEntity(id: UInt64(i), entity: "Huge"))
        }
        setupEntity("Huge", units: units, indexQuerying: indexQuerying, dirAccess: dirAccess)

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("Huge")),
            intent: .explain,
            budget: 3
        )
        let result = await service.retrieve(request)

        #expect(result.evidence.count <= 3)
        #expect(result.metadata.truncated)
        #expect(!result.metadata.subjectNotFound)
    }

    @Test("FM-5: Unit resolution failure excludes unit, other evidence unaffected")
    func unitResolutionFailure() async {
        let indexQuerying = MockIndexQuerying()
        let dirAccess = MockDIRReadAccess()

        // Entity index says unit 1 and 2 exist, but only unit 1 is in DIR
        let unit1 = makeUnitWithEntity(id: 1, entity: "E")
        dirAccess.units[unit1.id] = unit1

        let entityRef = makeEntityRef("E")
        indexQuerying.entityResults[entityRef] = IndexQueryResult(
            entries: [
                EntityIndexEntry(unitId: UnitIdentifier(rawValue: 1), predicate: testPredicate, tier: .t0, status: .active),
                EntityIndexEntry(unitId: UnitIdentifier(rawValue: 2), predicate: testPredicate, tier: .t0, status: .active),
            ],
            usedFallback: false
        )

        let service = makeService(indexQuerying: indexQuerying, dirAccess: dirAccess)
        let request = RetrievalRequest(subject: .entity(entityRef), intent: .explain)
        let result = await service.retrieve(request)

        #expect(result.evidence.count == 1)
        #expect(result.metadata.excludedUnitCount == 1)
    }

    @Test("Invalid request (zero budget) returns empty evidence set")
    func zeroBudget() async {
        let service = makeService()
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            budget: 0
        )
        let result = await service.retrieve(request)
        #expect(result.evidence.isEmpty)
    }

    @Test("Invalid request (tier floor > ceiling) returns empty evidence set")
    func invalidTierRange() async {
        let service = makeService()
        let request = RetrievalRequest(
            subject: .entity(makeEntityRef("E")),
            intent: .explain,
            tierFloor: .t2,
            tierCeiling: .t0
        )
        let result = await service.retrieve(request)
        #expect(result.evidence.isEmpty)
    }
}
