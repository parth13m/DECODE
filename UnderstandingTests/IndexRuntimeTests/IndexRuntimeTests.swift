// IndexRuntimeTests.swift — IndexRuntimeTests
// DDS-004: Index Runtime tests
// IAG-001 §9: Unit tests for IndexRuntime (M3)
// IAG-004 §3.2: Verification gate tests

import Testing
import Foundation
@testable import IndexRuntime
@testable import DIRCore
@testable import UnderstandingTestSupport

// MARK: — Test Helpers

/// Creates an IndexActor with a populated mock DIR for testing.
private func makeActor(units: [AtomicUnit] = []) -> (IndexActor, MockDIRReadAccess) {
    let mock = MockDIRReadAccess()
    for unit in units {
        mock.units[unit.id] = unit
    }
    mock.epoch = makeEpoch(1)
    let actor = IndexActor(dirRead: mock)
    return (actor, mock)
}

/// Creates a unit with a single entity subject.
private func makeEntityUnit(
    id: UInt64,
    entity: String,
    predicate: String = "testPred",
    domain: String = "test",
    value: TypedValue = .string("value"),
    tier: Tier = .t0,
    producer: String = "test-producer"
) -> AtomicUnit {
    makeUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entity)),
        predicate: PredicateIdentifier(name: predicate, domain: domain),
        value: value,
        tier: tier,
        provenance: makeProvenance(producer: producer)
    )
}

/// Creates a unit with a pair subject (relationship).
private func makePairUnit(
    id: UInt64,
    source: String,
    target: String,
    predicate: String = "calls",
    domain: String = "relationships",
    tier: Tier = .t0,
    producer: String = "test-producer"
) -> AtomicUnit {
    makeUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .pair(EntityPair(
            source: EntityReference(qualifiedName: source),
            target: EntityReference(qualifiedName: target)
        )),
        predicate: PredicateIdentifier(name: predicate, domain: domain),
        value: .boolean(true),
        tier: tier,
        provenance: makeProvenance(producer: producer)
    )
}

/// Creates a "contains" relationship unit for scope testing.
private func makeContainsUnit(
    id: UInt64,
    parent: String,
    child: String
) -> AtomicUnit {
    makePairUnit(id: id, source: parent, target: child, predicate: "contains", domain: "structure")
}

/// Creates a text-valued unit for content index testing.
private func makeTextUnit(
    id: UInt64,
    entity: String,
    text: String,
    predicate: String = "description",
    domain: String = "semantic"
) -> AtomicUnit {
    makeUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entity)),
        predicate: PredicateIdentifier(name: predicate, domain: domain),
        value: .text(text),
        tier: .t2,
        provenance: makeProvenance(producer: "semantic-enricher"),
        confidence: .high
    )
}

// MARK: — State Model Tests

@Suite("Index Runtime State Model")
struct IndexRuntimeStateTests {

    @Test("Valid state transitions")
    func validTransitions() {
        #expect(IndexRuntimeState.uninitialized.canTransition(to: .building))
        #expect(IndexRuntimeState.building.canTransition(to: .operational))
        #expect(IndexRuntimeState.operational.canTransition(to: .building))
        #expect(IndexRuntimeState.operational.canTransition(to: .quiescing))
        #expect(IndexRuntimeState.building.canTransition(to: .quiescing))
        #expect(IndexRuntimeState.quiescing.canTransition(to: .terminated))
    }

    @Test("Invalid state transitions")
    func invalidTransitions() {
        #expect(!IndexRuntimeState.uninitialized.canTransition(to: .operational))
        #expect(!IndexRuntimeState.terminated.canTransition(to: .building))
        #expect(!IndexRuntimeState.terminated.canTransition(to: .operational))
        #expect(!IndexRuntimeState.quiescing.canTransition(to: .operational))
        #expect(!IndexRuntimeState.quiescing.canTransition(to: .building))
    }
}

// MARK: — Family Availability Tests

@Suite("Index Family Availability")
struct IndexFamilyAvailabilityTests {

    @Test("Valid availability transitions")
    func validTransitions() {
        #expect(IndexFamilyAvailability.absent.canTransition(to: .building))
        #expect(IndexFamilyAvailability.building.canTransition(to: .available))
        #expect(IndexFamilyAvailability.available.canTransition(to: .rebuilding))
        #expect(IndexFamilyAvailability.available.canTransition(to: .absent))
        #expect(IndexFamilyAvailability.rebuilding.canTransition(to: .available))
        #expect(IndexFamilyAvailability.rebuilding.canTransition(to: .absent))
    }

    @Test("Invalid availability transitions")
    func invalidTransitions() {
        #expect(!IndexFamilyAvailability.absent.canTransition(to: .available))
        #expect(!IndexFamilyAvailability.absent.canTransition(to: .rebuilding))
        #expect(!IndexFamilyAvailability.building.canTransition(to: .rebuilding))
    }

    @Test("Construction priority order")
    func constructionOrder() {
        let order = IndexFamily.constructionOrder
        #expect(order == [.entity, .graph, .scope, .predicate, .content])
    }

    @Test("Structural vs deferred families")
    func structuralVsDeferred() {
        #expect(IndexFamily.entity.isStructural)
        #expect(IndexFamily.graph.isStructural)
        #expect(IndexFamily.scope.isStructural)
        #expect(IndexFamily.predicate.isStructural)
        #expect(!IndexFamily.content.isStructural)
    }
}

// MARK: — Construction Tests (DDS-004 R2)

@Suite("Index Construction")
struct IndexConstructionTests {

    @Test("Constructs all families from empty DIR")
    func constructFromEmptyDIR() async {
        let (actor, _) = makeActor()
        await actor.constructAll()

        let report = await actor.freshnessReport()
        for family in IndexFamily.allCases {
            let familyReport = report.families[family]
            #expect(familyReport?.availability == .available)
            #expect(familyReport?.entryCount == 0)
        }
    }

    @Test("Constructs entity index from populated DIR")
    func constructEntityIndex() async {
        let units = [
            makeEntityUnit(id: 1, entity: "ModuleA.ClassB"),
            makeEntityUnit(id: 2, entity: "ModuleA.ClassB", predicate: "hasType", domain: "structure"),
            makeEntityUnit(id: 3, entity: "ModuleA.ClassC"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let result = await actor.queryEntity(
            EntityReference(qualifiedName: "ModuleA.ClassB"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(!result.usedFallback)
        #expect(result.entries.count == 2)
    }

    @Test("Constructs graph index with bidirectional entries")
    func constructGraphIndex() async {
        let units = [
            makePairUnit(id: 1, source: "A", target: "B", predicate: "calls"),
            makePairUnit(id: 2, source: "B", target: "C", predicate: "calls"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        // Forward query: A calls → B
        let forward = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "A"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .forward
        )
        #expect(forward.entries.count == 1)
        #expect(forward.entries[0].neighbor == EntityReference(qualifiedName: "B"))

        // Inverse query: B is called by → A
        let inverse = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "B"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .inverse
        )
        #expect(inverse.entries.count == 1)
        #expect(inverse.entries[0].neighbor == EntityReference(qualifiedName: "A"))
    }

    @Test("Constructs scope index with transitive closure")
    func constructScopeIndex() async {
        let units = [
            makeContainsUnit(id: 1, parent: "Module", child: "File"),
            makeContainsUnit(id: 2, parent: "File", child: "Class"),
            makeContainsUnit(id: 3, parent: "Class", child: "Method"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        // Module transitively contains File, Class, Method
        let result = await actor.queryScope(EntityReference(qualifiedName: "Module"))
        #expect(!result.usedFallback)
        #expect(result.entries.count == 3)

        // Check depths
        let entryNames = Dictionary(
            result.entries.map { ($0.containedEntity.qualifiedName, $0.depth) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(entryNames["File"] == 1)
        #expect(entryNames["Class"] == 2)
        #expect(entryNames["Method"] == 3)
    }

    @Test("Constructs predicate index")
    func constructPredicateIndex() async {
        let pred = PredicateIdentifier(name: "hasReturnType", domain: "structure")
        let units = [
            makeUnit(
                id: UnitIdentifier(rawValue: 1),
                subject: .entity(EntityReference(qualifiedName: "A.foo")),
                predicate: pred, value: .string("Int"), tier: .t0,
                provenance: makeProvenance(producer: "swift-frontend")
            ),
            makeUnit(
                id: UnitIdentifier(rawValue: 2),
                subject: .entity(EntityReference(qualifiedName: "B.bar")),
                predicate: pred, value: .string("String"), tier: .t0,
                provenance: makeProvenance(producer: "swift-frontend")
            ),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let result = await actor.queryPredicate(pred, tier: nil, status: nil, producerId: nil)
        #expect(!result.usedFallback)
        #expect(result.entries.count == 2)
    }

    @Test("Constructs content index from text-valued units")
    func constructContentIndex() async {
        let units = [
            makeTextUnit(id: 1, entity: "A", text: "This function handles user authentication"),
            makeTextUnit(id: 2, entity: "B", text: "Database connection manager for authentication"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let result = await actor.queryContent(term: "authentication")
        #expect(!result.usedFallback)
        #expect(result.entries.count == 2)

        let unique = await actor.queryContent(term: "database")
        #expect(unique.entries.count == 1)
    }

    @Test("Non-text units are excluded from content index")
    func nonTextExcludedFromContent() async {
        let units = [
            makeEntityUnit(id: 1, entity: "A"), // string, not text
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let report = await actor.familyFreshness(.content)
        #expect(report.entryCount == 0)
    }
}

// MARK: — Query Filter Tests

@Suite("Index Query Filters")
struct IndexQueryFilterTests {

    @Test("Entity query with predicate filter")
    func entityPredicateFilter() async {
        let units = [
            makeEntityUnit(id: 1, entity: "A", predicate: "hasType"),
            makeEntityUnit(id: 2, entity: "A", predicate: "hasReturnType"),
            makeEntityUnit(id: 3, entity: "A", predicate: "hasType"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let result = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: PredicateIdentifier(name: "hasType", domain: "test"),
            tier: nil, status: nil
        )
        #expect(result.entries.count == 2)
    }

    @Test("Entity query with tier filter")
    func entityTierFilter() async {
        let units = [
            makeEntityUnit(id: 1, entity: "A", tier: .t0),
            makeEntityUnit(id: 2, entity: "A", predicate: "semantic", tier: .t2),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let t0Only = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: .t0, status: nil
        )
        #expect(t0Only.entries.count == 1)
    }

    @Test("Predicate query with producer filter")
    func predicateProducerFilter() async {
        let pred = PredicateIdentifier(name: "isPublic", domain: "visibility")
        let units = [
            makeUnit(
                id: UnitIdentifier(rawValue: 1),
                subject: .entity(EntityReference(qualifiedName: "A")),
                predicate: pred, value: .boolean(true), tier: .t0,
                provenance: makeProvenance(producer: "swift-frontend")
            ),
            makeUnit(
                id: UnitIdentifier(rawValue: 2),
                subject: .entity(EntityReference(qualifiedName: "B")),
                predicate: pred, value: .boolean(true), tier: .t0,
                provenance: makeProvenance(producer: "ts-frontend")
            ),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let swiftOnly = await actor.queryPredicate(
            pred, tier: nil, status: nil, producerId: "swift-frontend"
        )
        #expect(swiftOnly.entries.count == 1)
    }
}

// MARK: — DIR Scan Fallback Tests (DDS-004 RI-6)

@Suite("DIR Scan Fallback")
struct DIRScanFallbackTests {

    @Test("Entity query uses fallback before construction")
    func entityFallbackBeforeConstruction() async {
        let units = [makeEntityUnit(id: 1, entity: "A")]
        let (actor, _) = makeActor(units: units)
        // Do NOT call constructAll — indexes are absent

        let result = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(result.usedFallback)
        #expect(result.entries.count == 1)
    }

    @Test("Graph query uses fallback when family absent")
    func graphFallback() async {
        let units = [makePairUnit(id: 1, source: "A", target: "B")]
        let (actor, _) = makeActor(units: units)

        let result = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "A"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .forward
        )
        #expect(result.usedFallback)
        #expect(result.entries.count == 1)
    }

    @Test("Scope query uses fallback when family absent")
    func scopeFallback() async {
        let units = [makeContainsUnit(id: 1, parent: "Mod", child: "File")]
        let (actor, _) = makeActor(units: units)

        let result = await actor.queryScope(EntityReference(qualifiedName: "Mod"))
        #expect(result.usedFallback)
        #expect(result.entries.count == 1)
    }

    @Test("Content query uses fallback when family absent")
    func contentFallback() async {
        let units = [makeTextUnit(id: 1, entity: "A", text: "hello world")]
        let (actor, _) = makeActor(units: units)

        let result = await actor.queryContent(term: "hello")
        #expect(result.usedFallback)
        #expect(result.entries.count == 1)
    }

    @Test("Predicate query uses fallback when family absent")
    func predicateFallback() async {
        let pred = PredicateIdentifier(name: "testPred", domain: "test")
        let units = [makeEntityUnit(id: 1, entity: "A")]
        let (actor, _) = makeActor(units: units)

        let result = await actor.queryPredicate(pred, tier: nil, status: nil, producerId: nil)
        #expect(result.usedFallback)
        #expect(result.entries.count == 1)
    }
}

// MARK: — Freshness Report Tests (DDS-004 PC-3)

@Suite("Freshness Report")
struct FreshnessReportTests {

    @Test("Reports all families after construction")
    func reportsAllFamilies() async {
        let (actor, _) = makeActor()
        await actor.constructAll()

        let report = await actor.freshnessReport()
        #expect(report.families.count == 5)

        for family in IndexFamily.allCases {
            let familyReport = report.families[family]!
            #expect(familyReport.availability == .available)
            #expect(familyReport.lastUpdateEpoch == makeEpoch(1))
            #expect(familyReport.staleEntryCount == 0)
        }
    }

    @Test("Reports absent families before construction")
    func reportsAbsentFamilies() async {
        let (actor, _) = makeActor()

        for family in IndexFamily.allCases {
            let availability = await actor.familyAvailability(family)
            #expect(availability == .absent)
        }
    }

    @Test("Individual family report")
    func individualFamilyReport() async {
        let units = [makeEntityUnit(id: 1, entity: "A")]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let report = await actor.familyFreshness(.entity)
        #expect(report.family == .entity)
        #expect(report.availability == .available)
        #expect(report.entryCount == 1)
        #expect(report.memoryFootprintBytes > 0)
    }
}

// MARK: — Batch Update Tests (DDS-004 PC-4)

@Suite("Batch Index Update")
struct BatchUpdateTests {

    @Test("Batch update with unit admission indexes in all families")
    func batchAdmission() async {
        let (actor, mock) = makeActor()
        await actor.constructAll()

        // Add a new unit to the mock
        let newUnit = makeEntityUnit(id: 10, entity: "NewEntity")
        mock.units[UnitIdentifier(rawValue: 10)] = newUnit
        mock.epoch = makeEpoch(2)

        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [.admitted(UnitIdentifier(rawValue: 10))]
        )
        let result = await actor.applyBatchWithResolution(batch)
        #expect(result.updatedFamilies.contains(.entity))
        #expect(result.updatedFamilies.contains(.predicate))

        // Verify entity was indexed
        let entityResult = await actor.queryEntity(
            EntityReference(qualifiedName: "NewEntity"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(entityResult.entries.count == 1)
    }

    @Test("Batch update with garbage collection removes from all families")
    func batchGarbageCollection() async {
        let units = [makeEntityUnit(id: 1, entity: "OldEntity")]
        let (actor, mock) = makeActor(units: units)
        await actor.constructAll()

        // Verify entity exists
        let before = await actor.queryEntity(
            EntityReference(qualifiedName: "OldEntity"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(before.entries.count == 1)

        // GC the unit
        mock.epoch = makeEpoch(2)
        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [.garbageCollected(UnitIdentifier(rawValue: 1))]
        )
        let result = await actor.applyBatchWithResolution(batch)
        #expect(result.updatedFamilies.contains(.entity))

        // Verify entity removed
        let after = await actor.queryEntity(
            EntityReference(qualifiedName: "OldEntity"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(after.entries.count == 0)
    }

    @Test("Batch update rejects in terminated state")
    func batchRejectsInTerminated() async {
        let (actor, _) = makeActor()
        await actor.constructAll()
        await actor.shutdown()
        await actor.terminate()

        let batch = ChangeBatch(epoch: makeEpoch(2), changes: [])
        let result = await actor.applyBatch(batch)
        #expect(result.updatedFamilies.isEmpty)
    }

    @Test("Batch update queued during building state")
    func batchQueuedDuringBuilding() async {
        let (actor, _) = makeActor()
        // Actor is in uninitialized state — cannot even accept batches
        let batch = ChangeBatch(epoch: makeEpoch(1), changes: [])
        let result = await actor.applyBatch(batch)
        #expect(result.updatedFamilies.isEmpty)
    }

    @Test("Graph index handles pair unit admission")
    func graphAdmission() async {
        let (actor, mock) = makeActor()
        await actor.constructAll()

        let newUnit = makePairUnit(id: 10, source: "X", target: "Y")
        mock.units[UnitIdentifier(rawValue: 10)] = newUnit
        mock.epoch = makeEpoch(2)

        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [.admitted(UnitIdentifier(rawValue: 10))]
        )
        _ = await actor.applyBatchWithResolution(batch)

        let forward = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "X"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .forward
        )
        #expect(forward.entries.count == 1)

        let inverse = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "Y"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .inverse
        )
        #expect(inverse.entries.count == 1)
    }

    @Test("Scope index handles contains admission")
    func scopeAdmission() async {
        let (actor, mock) = makeActor()
        await actor.constructAll()

        let newUnit = makeContainsUnit(id: 10, parent: "Module", child: "File")
        mock.units[UnitIdentifier(rawValue: 10)] = newUnit
        mock.epoch = makeEpoch(2)

        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [.admitted(UnitIdentifier(rawValue: 10))]
        )
        _ = await actor.applyBatchWithResolution(batch)

        let result = await actor.queryScope(EntityReference(qualifiedName: "Module"))
        #expect(result.entries.count == 1)
    }
}

// MARK: — Deferred Content Update Tests (DDS-004 RI-8)

@Suite("Deferred Content Updates")
struct DeferredContentUpdateTests {

    @Test("Content updates are deferred during batch update")
    func contentDeferred() async {
        let (actor, mock) = makeActor()
        await actor.constructAll()

        let textUnit = makeTextUnit(id: 10, entity: "A", text: "deferred text content")
        mock.units[UnitIdentifier(rawValue: 10)] = textUnit
        mock.epoch = makeEpoch(2)

        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [.admitted(UnitIdentifier(rawValue: 10))]
        )
        _ = await actor.applyBatchWithResolution(batch)

        // Before processing deferred updates, content index may not have the text
        // (it was enqueued, not applied synchronously)
        // Process deferred updates
        await actor.processDeferredUpdates()

        let report = await actor.familyFreshness(.content)
        #expect(report.lastUpdateEpoch == makeEpoch(2))
    }

    @Test("Deferred removal on garbage collection")
    func deferredRemoval() async {
        let textUnit = makeTextUnit(id: 1, entity: "A", text: "search term here")
        let (actor, mock) = makeActor(units: [textUnit])
        await actor.constructAll()

        // Verify content is searchable
        let before = await actor.queryContent(term: "search")
        #expect(before.entries.count == 1)

        // GC the unit
        mock.epoch = makeEpoch(2)
        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [.garbageCollected(UnitIdentifier(rawValue: 1))]
        )
        _ = await actor.applyBatchWithResolution(batch)
        await actor.processDeferredUpdates()

        let after = await actor.queryContent(term: "search")
        #expect(after.entries.count == 0)
    }
}

// MARK: — Rebuild Tests (DDS-004 PC-2)

@Suite("Index Family Rebuild")
struct RebuildTests {

    @Test("Rebuild produces identical index to initial construction")
    func rebuildProducesIdenticalIndex() async {
        let units = [
            makeEntityUnit(id: 1, entity: "A"),
            makeEntityUnit(id: 2, entity: "B"),
            makePairUnit(id: 3, source: "A", target: "B"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        // Query before rebuild
        let beforeEntity = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: nil, status: nil
        )

        // Rebuild entity index
        await actor.rebuildFamily(.entity)

        let afterEntity = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(beforeEntity.entries.count == afterEntity.entries.count)
    }

    @Test("Rebuild of one family does not affect others")
    func rebuildIsolation() async {
        let units = [
            makeEntityUnit(id: 1, entity: "A"),
            makePairUnit(id: 2, source: "A", target: "B"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        // Rebuild entity only
        await actor.rebuildFamily(.entity)

        // Graph should be unaffected
        let graphResult = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "A"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .forward
        )
        #expect(graphResult.entries.count == 1)
        #expect(!graphResult.usedFallback)
    }

    @Test("Family availability after rebuild")
    func availabilityAfterRebuild() async {
        let (actor, _) = makeActor()
        await actor.constructAll()

        await actor.rebuildFamily(.entity)

        let availability = await actor.familyAvailability(.entity)
        #expect(availability == .available)
    }
}

// MARK: — Shutdown Tests

@Suite("Index Runtime Shutdown")
struct ShutdownTests {

    @Test("Shutdown discards deferred updates")
    func shutdownDiscardsDeferredUpdates() async {
        let (actor, _) = makeActor()
        await actor.constructAll()
        await actor.shutdown()

        // After shutdown, processing deferred updates should be a no-op
        await actor.processDeferredUpdates()

        // Verify state
        await actor.terminate()
    }

    @Test("Queries still work during quiescing")
    func queriesDuringQuiescing() async {
        let units = [makeEntityUnit(id: 1, entity: "A")]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()
        await actor.shutdown()

        // DDS-004: Read queries remain available during quiescing
        let result = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(result.entries.count == 1)
    }
}

// MARK: — Pair Entity Indexing Tests

@Suite("Pair Entity Indexing")
struct PairEntityIndexingTests {

    @Test("Pair units indexed under both source and target in entity index")
    func pairUnitsInEntityIndex() async {
        let units = [makePairUnit(id: 1, source: "A", target: "B")]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        // Should appear under both A and B
        let resultA = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(resultA.entries.count == 1)

        let resultB = await actor.queryEntity(
            EntityReference(qualifiedName: "B"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(resultB.entries.count == 1)
    }

    @Test("Non-pair units excluded from graph index")
    func nonPairExcludedFromGraph() async {
        let units = [makeEntityUnit(id: 1, entity: "A")]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let report = await actor.familyFreshness(.graph)
        #expect(report.entryCount == 0)
    }

    @Test("Only contains predicate units in scope index")
    func onlyContainsInScope() async {
        let units = [
            makePairUnit(id: 1, source: "A", target: "B", predicate: "calls"),
            makeContainsUnit(id: 2, parent: "Module", child: "File"),
        ]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        // Only the contains relationship should be in scope
        let report = await actor.familyFreshness(.scope)
        #expect(report.entryCount >= 1)

        // The "calls" relationship should not create scope entries
        let scopeA = await actor.queryScope(EntityReference(qualifiedName: "A"))
        #expect(scopeA.entries.count == 0)
    }
}

// MARK: — Content Index Tokenization Tests

@Suite("Content Index Search")
struct ContentIndexSearchTests {

    @Test("Case-insensitive search")
    func caseInsensitiveSearch() async {
        let units = [makeTextUnit(id: 1, entity: "A", text: "Authentication Handler")]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let result = await actor.queryContent(term: "authentication")
        #expect(result.entries.count == 1)

        let upper = await actor.queryContent(term: "AUTHENTICATION")
        #expect(upper.entries.count == 1)
    }

    @Test("No results for missing term")
    func noResultsForMissingTerm() async {
        let units = [makeTextUnit(id: 1, entity: "A", text: "hello world")]
        let (actor, _) = makeActor(units: units)
        await actor.constructAll()

        let result = await actor.queryContent(term: "nonexistent")
        #expect(result.entries.count == 0)
    }

    @Test("Query entity not found returns empty")
    func entityNotFoundReturnsEmpty() async {
        let (actor, _) = makeActor()
        await actor.constructAll()

        let result = await actor.queryEntity(
            EntityReference(qualifiedName: "NonExistent"),
            predicate: nil, tier: nil, status: nil
        )
        #expect(result.entries.isEmpty)
        #expect(!result.usedFallback)
    }
}

// MARK: — Supersession Tests

@Suite("Unit Supersession")
struct SupersessionTests {

    @Test("Supersession replaces entity index entries")
    func supersessionReplacesEntity() async {
        let original = makeEntityUnit(id: 1, entity: "A")
        let successor = makeEntityUnit(id: 2, entity: "A", predicate: "testPred")
        let (actor, mock) = makeActor(units: [original])
        await actor.constructAll()

        // Add successor to mock
        mock.units[UnitIdentifier(rawValue: 2)] = successor
        mock.epoch = makeEpoch(2)

        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [
                .superseded(UnitIdentifier(rawValue: 1), by: UnitIdentifier(rawValue: 2)),
                .admitted(UnitIdentifier(rawValue: 2)),
            ]
        )
        _ = await actor.applyBatchWithResolution(batch)

        let result = await actor.queryEntity(
            EntityReference(qualifiedName: "A"),
            predicate: nil, tier: nil, status: nil
        )
        // Should have successor only
        #expect(result.entries.count == 1)
        #expect(result.entries[0].unitId == UnitIdentifier(rawValue: 2))
    }

    @Test("Supersession removes old graph entries and adds new")
    func supersessionReplacesGraph() async {
        let original = makePairUnit(id: 1, source: "A", target: "B")
        let successor = makePairUnit(id: 2, source: "A", target: "C")
        let (actor, mock) = makeActor(units: [original])
        await actor.constructAll()

        mock.units[UnitIdentifier(rawValue: 2)] = successor
        mock.epoch = makeEpoch(2)

        let batch = ChangeBatch(
            epoch: makeEpoch(2),
            changes: [
                .superseded(UnitIdentifier(rawValue: 1), by: UnitIdentifier(rawValue: 2)),
                .admitted(UnitIdentifier(rawValue: 2)),
            ]
        )
        _ = await actor.applyBatchWithResolution(batch)

        // Old target B should be gone, new target C should exist
        let result = await actor.queryGraph(
            entity: EntityReference(qualifiedName: "A"),
            predicate: PredicateIdentifier(name: "calls", domain: "relationships"),
            direction: .forward
        )
        #expect(result.entries.count == 1)
        #expect(result.entries[0].neighbor == EntityReference(qualifiedName: "C"))
    }
}
