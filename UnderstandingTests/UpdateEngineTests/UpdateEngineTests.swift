// UpdateEngineTests.swift — UpdateEngine
// IAG-004 §5: Phase 3 verification — UpdateEngine unit tests
// Tests: state model, write transactions, epoch management, intake validation,
//        content-hash filtering, cascade propagation, change batch observer,
//        snapshot integration, demand signals, UnitStore, IntakeValidator, errors

import Testing
import Foundation
@testable import DIRCore
@testable import UpdateEngine
@testable import ProducerRuntime
@testable import IndexRuntime
@testable import StorageEngine
@testable import UnderstandingTestSupport

// MARK: — Mock Dependencies

/// Mock ExecutionDirective that records tickets and returns configurable results.
final class MockExecutionDirective: ExecutionDirective, @unchecked Sendable {
    var executedTickets: [ExecutionTicket] = []
    var nextResult: TicketResult = .completed(ExecutionReport(
        producerIdentity: ProducerIdentity(
            identifier: ProducerIdentifier(name: "mock"),
            version: ProducerVersion(major: 1, minor: 0)
        ),
        scope: .system,
        changeReport: .noChange,
        outputUnitCount: 0,
        inputUnitCount: 0,
        duration: .zero
    ))
    var resultsByProducer: [String: TicketResult] = [:]

    func execute(_ ticket: ExecutionTicket) async -> TicketResult {
        executedTickets.append(ticket)
        return resultsByProducer[ticket.producerId.name] ?? nextResult
    }

    func executeBatch(_ tickets: [ExecutionTicket]) async -> [TicketResult] {
        executedTickets.append(contentsOf: tickets)
        return tickets.map { resultsByProducer[$0.producerId.name] ?? nextResult }
    }

    func executeBatchAll(filePaths: Set<String>) async -> [TicketResult] {
        return []
    }
}

/// Mock ProducerRegistry with configurable DAG and contracts.
final class MockProducerRegistry: ProducerRegistry, @unchecked Sendable {
    var contracts: [ProducerIdentifier: ProducerContract] = [:]
    var producers: [String: [ProducerIdentifier]] = [:]
    var dag = DAGSnapshot(
        topologicalOrder: [],
        executionLevels: [],
        frontendCount: 0,
        deterministicPassCount: 0,
        semanticPassCount: 0
    )

    func register(_ contract: ProducerContract) async throws -> RegistrationResult {
        contracts[contract.identity.identifier] = contract
        return .accepted
    }

    func remove(_ id: ProducerIdentifier) async throws {
        contracts.removeValue(forKey: id)
    }

    func dagSnapshot() async -> DAGSnapshot { dag }

    func producers(for predicate: PredicateIdentifier, at tier: Tier) async -> [ProducerIdentifier] {
        let key = "\(predicate.name):\(tier)"
        return producers[key] ?? []
    }

    func contract(for id: ProducerIdentifier) async -> ProducerContract? {
        contracts[id]
    }

    func registeredProducers() async -> Set<ProducerIdentifier> {
        Set(contracts.keys)
    }
}

/// Mock FailureReportSource.
final class MockFailureReportSource: FailureReportSource, @unchecked Sendable {
    var records: [FailureRecord] = []

    func allFailures() async -> [FailureRecord] { records }
    func failures(for producerId: ProducerIdentifier) async -> [FailureRecord] {
        records.filter { $0.producerIdentity.identifier == producerId }
    }
    func clearFailures() async { records.removeAll() }
}

/// Mock IndexBatchUpdate that records applied batches.
final class MockIndexBatchUpdate: IndexBatchUpdate, @unchecked Sendable {
    var appliedBatches: [ChangeBatch] = []
    var nextResult = BatchUpdateResult(
        updatedFamilies: [.entity],
        failedFamilies: [:],
        epoch: .zero
    )

    func applyBatch(_ batch: ChangeBatch) async -> BatchUpdateResult {
        appliedBatches.append(batch)
        return nextResult
    }

    func processDeferredUpdates() async {}
    func rebuildFamily(_ family: IndexFamily) async {}
}

/// Mock SnapshotPersistence.
final class MockSnapshotPersistence: SnapshotPersistence, @unchecked Sendable {
    var capturedSnapshots: [SnapshotData] = []
    var nextLoadResult: SnapshotLoadResult = .requiresFullRebuild

    func captureSnapshot(_ snapshot: SnapshotData) async throws {
        capturedSnapshots.append(snapshot)
    }

    func loadSnapshot() async -> SnapshotLoadResult {
        nextLoadResult
    }

    func lastSnapshotEpoch() async -> Epoch? {
        capturedSnapshots.last?.epoch
    }
}

/// Mock GarbageCollector.
final class MockGarbageCollector: GarbageCollector, @unchecked Sendable {
    var collectCalled = false

    func collectGarbage(currentEpoch: Epoch) async -> GCCycleResult {
        collectCalled = true
        return GCCycleResult(
            candidatesEvaluated: 0,
            candidatesCollected: 0,
            candidatesSkippedSafety: 0,
            candidatesSkippedRetention: 0,
            duration: 0
        )
    }
}

/// Mock GroundingMapAccess.
final class MockGroundingMapAccess: GroundingMapAccess, @unchecked Sendable {
    var dependentsMap: [UnitIdentifier: Set<UnitIdentifier>] = [:]

    func dependents(of unitId: UnitIdentifier) async -> GroundingLookupResult {
        if let deps = dependentsMap[unitId] {
            return .available(deps)
        }
        return .available([])
    }

    func isMapAvailable() async -> Bool { true }
}

/// Mock ContentHashMapAccess.
final class MockContentHashMapAccess: ContentHashMapAccess, @unchecked Sendable {
    var hashes: [String: ContentHash] = [:]

    func contentHash(for filePath: String) async -> ContentHash? {
        hashes[filePath]
    }

    func allContentHashes() async -> [String: ContentHash] { hashes }

    func updateContentHash(for filePath: String, hash: ContentHash) async {
        hashes[filePath] = hash
    }

    func removeContentHash(for filePath: String) async {
        hashes.removeValue(forKey: filePath)
    }

    func trackedFileCount() async -> Int { hashes.count }
}

/// Mock DeferredQueuePersistence.
final class MockDeferredQueuePersistence: DeferredQueuePersistence, @unchecked Sendable {
    var queue: [UnitIdentifier] = []

    func deferredQueue() async -> [UnitIdentifier] { queue }
    func updateDeferredQueue(_ queue: [UnitIdentifier]) async { self.queue = queue }
    func enqueueDeferredUnit(_ unitId: UnitIdentifier) async { queue.append(unitId) }
    func dequeueDeferredUnit(_ unitId: UnitIdentifier) async { queue.removeAll { $0 == unitId } }
}

/// Mock ChangeBatchObserver that records committed batches.
final class MockChangeBatchObserver: ChangeBatchObserver, @unchecked Sendable {
    var committedBatches: [ChangeBatch] = []

    func didCommit(_ batch: ChangeBatch) async {
        committedBatches.append(batch)
    }
}

// MARK: — Helper Functions

/// Creates an UpdateActor with all mock dependencies.
func makeActor(
    executionDirective: MockExecutionDirective = MockExecutionDirective(),
    producerRegistry: MockProducerRegistry = MockProducerRegistry(),
    failureReportSource: MockFailureReportSource = MockFailureReportSource(),
    indexBatchUpdate: MockIndexBatchUpdate = MockIndexBatchUpdate(),
    snapshotPersistence: MockSnapshotPersistence = MockSnapshotPersistence(),
    garbageCollector: MockGarbageCollector = MockGarbageCollector(),
    groundingMapAccess: MockGroundingMapAccess = MockGroundingMapAccess(),
    contentHashMapAccess: MockContentHashMapAccess = MockContentHashMapAccess(),
    deferredQueuePersistence: MockDeferredQueuePersistence = MockDeferredQueuePersistence(),
    changeBatchObserver: MockChangeBatchObserver = MockChangeBatchObserver()
) -> UpdateActor {
    UpdateActor(
        executionDirective: executionDirective,
        producerRegistry: producerRegistry,
        failureReportSource: failureReportSource,
        indexBatchUpdate: indexBatchUpdate,
        snapshotPersistence: snapshotPersistence,
        garbageCollector: garbageCollector,
        groundingMapAccess: groundingMapAccess,
        contentHashMapAccess: contentHashMapAccess,
        deferredQueuePersistence: deferredQueuePersistence,
        changeBatchObserver: changeBatchObserver
    )
}

/// Creates an UpdateActor and transitions it to Idle state.
func makeIdleActor(
    snapshotPersistence: MockSnapshotPersistence = MockSnapshotPersistence(),
    contentHashMapAccess: MockContentHashMapAccess = MockContentHashMapAccess(),
    deferredQueuePersistence: MockDeferredQueuePersistence = MockDeferredQueuePersistence(),
    changeBatchObserver: MockChangeBatchObserver = MockChangeBatchObserver(),
    executionDirective: MockExecutionDirective = MockExecutionDirective(),
    producerRegistry: MockProducerRegistry = MockProducerRegistry(),
    indexBatchUpdate: MockIndexBatchUpdate = MockIndexBatchUpdate(),
    groundingMapAccess: MockGroundingMapAccess = MockGroundingMapAccess(),
    garbageCollector: MockGarbageCollector = MockGarbageCollector()
) async -> UpdateActor {
    let actor = makeActor(
        executionDirective: executionDirective,
        producerRegistry: producerRegistry,
        indexBatchUpdate: indexBatchUpdate,
        snapshotPersistence: snapshotPersistence,
        garbageCollector: garbageCollector,
        groundingMapAccess: groundingMapAccess,
        contentHashMapAccess: contentHashMapAccess,
        deferredQueuePersistence: deferredQueuePersistence,
        changeBatchObserver: changeBatchObserver
    )
    await actor.loadFromSnapshot()
    await actor.reconcile()
    await actor.completeReconciliation()
    return actor
}

// MARK: — UpdateEngineState Tests

@Suite("UpdateEngineState")
struct UpdateEngineStateTests {

    @Test("Initial state is created")
    func initialState() {
        let state = UpdateEngineState.created
        #expect(state.rawValue == "created")
    }

    @Test("All valid transitions succeed")
    func validTransitions() {
        #expect(UpdateEngineState.created.canTransition(to: .reconciling))
        #expect(UpdateEngineState.reconciling.canTransition(to: .idle))
        #expect(UpdateEngineState.idle.canTransition(to: .processing))
        #expect(UpdateEngineState.processing.canTransition(to: .idle))
        #expect(UpdateEngineState.idle.canTransition(to: .quiescing))
        #expect(UpdateEngineState.processing.canTransition(to: .quiescing))
        #expect(UpdateEngineState.quiescing.canTransition(to: .terminated))
    }

    @Test("Invalid transitions are rejected")
    func invalidTransitions() {
        #expect(!UpdateEngineState.created.canTransition(to: .idle))
        #expect(!UpdateEngineState.created.canTransition(to: .processing))
        #expect(!UpdateEngineState.created.canTransition(to: .terminated))
        #expect(!UpdateEngineState.idle.canTransition(to: .created))
        #expect(!UpdateEngineState.terminated.canTransition(to: .created))
        #expect(!UpdateEngineState.terminated.canTransition(to: .idle))
        #expect(!UpdateEngineState.reconciling.canTransition(to: .processing))
        #expect(!UpdateEngineState.quiescing.canTransition(to: .idle))
    }

    @Test("Self-transitions are invalid")
    func selfTransitions() {
        let allStates: [UpdateEngineState] = [.created, .reconciling, .idle, .processing, .quiescing, .terminated]
        for state in allStates {
            #expect(!state.canTransition(to: state), "Self-transition should be invalid: \(state)")
        }
    }
}

// MARK: — Actor Lifecycle Tests

@Suite("UpdateActor Lifecycle")
struct UpdateActorLifecycleTests {

    @Test("Actor starts in created state")
    func startsCreated() async {
        let actor = makeActor()
        let state = await actor.currentState()
        #expect(state == .created)
    }

    @Test("loadFromSnapshot transitions to reconciling")
    func loadTransitionsToReconciling() async {
        let actor = makeActor()
        await actor.loadFromSnapshot()
        let state = await actor.currentState()
        #expect(state == .reconciling)
    }

    @Test("completeReconciliation transitions to idle")
    func reconciliationToIdle() async {
        let actor = makeActor()
        await actor.loadFromSnapshot()
        await actor.reconcile()
        await actor.completeReconciliation()
        let state = await actor.currentState()
        #expect(state == .idle)
    }

    @Test("shutdown from idle transitions to terminated")
    func shutdownFromIdle() async {
        let actor = await makeIdleActor()
        await actor.shutdown()
        let state = await actor.currentState()
        #expect(state == .terminated)
    }

    @Test("shutdown captures final snapshot")
    func shutdownCapturesSnapshot() async {
        let snap = MockSnapshotPersistence()
        let actor = await makeIdleActor(snapshotPersistence: snap)
        await actor.shutdown()
        #expect(!snap.capturedSnapshots.isEmpty)
    }

    @Test("loadFromSnapshot restores units from snapshot")
    func loadRestoresUnits() async {
        let snap = MockSnapshotPersistence()
        let unit = makeUnit(id: UnitIdentifier(rawValue: 42))
        snap.nextLoadResult = .loaded(SnapshotData(
            units: [unit],
            epoch: Epoch(value: 5),
            nextUnitId: 43,
            contentHashes: [:],
            deferredQueue: []
        ))

        let actor = await makeIdleActor(snapshotPersistence: snap)
        let loaded = await actor.unit(for: UnitIdentifier(rawValue: 42))
        #expect(loaded != nil)
        #expect(loaded?.id.rawValue == 42)
    }

    @Test("loadFromSnapshot with requiresFullRebuild starts empty")
    func loadWithNoSnapshot() async {
        let snap = MockSnapshotPersistence()
        snap.nextLoadResult = .requiresFullRebuild

        let actor = await makeIdleActor(snapshotPersistence: snap)
        let units = await actor.allUnits()
        #expect(units.isEmpty)
        let epoch = await actor.committedEpoch
        #expect(epoch == .zero)
    }
}

// MARK: — DIRReadAccess Tests

@Suite("DIRReadAccess")
struct DIRReadAccessTests {

    @Test("committedEpoch starts at zero")
    func epochStartsAtZero() async {
        let actor = await makeIdleActor()
        let epoch = await actor.committedEpoch
        #expect(epoch == .zero)
    }

    @Test("unit(for:) returns nil for nonexistent unit")
    func unitNotFound() async {
        let actor = await makeIdleActor()
        let unit = await actor.unit(for: UnitIdentifier(rawValue: 999))
        #expect(unit == nil)
    }

    @Test("activeUnits returns only active units")
    func activeUnitsFiltered() async {
        let snap = MockSnapshotPersistence()
        var activeUnit = makeUnit(id: UnitIdentifier(rawValue: 1))
        var invalidatedUnit = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            predicate: PredicateIdentifier(name: "other", domain: "test")
        )
        invalidatedUnit.invalidate(metadata: InvalidationMetadata(
            epoch: .zero, reason: .sourceChanged
        ))
        snap.nextLoadResult = .loaded(SnapshotData(
            units: [activeUnit, invalidatedUnit],
            epoch: .zero,
            nextUnitId: 3,
            contentHashes: [:],
            deferredQueue: []
        ))

        let actor = await makeIdleActor(snapshotPersistence: snap)
        let active = await actor.activeUnits()
        #expect(active.count == 1)
        #expect(active[0].id.rawValue == 1)
    }
}

// MARK: — DIRWriteAccess Tests

@Suite("DIRWriteAccess — Write Transactions")
struct WriteTransactionTests {

    @Test("Admit a single unit")
    func admitSingleUnit() async {
        let observer = MockChangeBatchObserver()
        let actor = await makeIdleActor(changeBatchObserver: observer)

        let admission = makeAdmission()
        let transaction = WriteTransaction(admissions: [admission])
        let result = await actor.submit(transaction)

        if case .committed(let committed) = result {
            #expect(committed.admittedUnitIds.count == 1)
        } else {
            Issue.record("Expected committed transaction")
        }

        // Verify observer was notified
        #expect(!observer.committedBatches.isEmpty)
    }

    @Test("Admit multiple units in batch")
    func admitBatch() async {
        let actor = await makeIdleActor()

        let admissions = [
            makeAdmission(subject: .entity(EntityReference(qualifiedName: "A"))),
            makeAdmission(
                subject: .entity(EntityReference(qualifiedName: "B")),
                predicate: PredicateIdentifier(name: "pred2", domain: "test")
            ),
        ]
        let transaction = WriteTransaction(admissions: admissions)
        let result = await actor.submit(transaction)

        if case .committed(let committed) = result {
            #expect(committed.admittedUnitIds.count == 2)
        } else {
            Issue.record("Expected committed transaction")
        }
    }

    @Test("Supersession replaces active unit with same key")
    func supersession() async {
        let actor = await makeIdleActor()

        // Admit first unit
        let admission1 = makeAdmission(value: .string("v1"))
        let result1 = await actor.submit(WriteTransaction(admissions: [admission1]))
        guard case .committed(let c1) = result1 else {
            Issue.record("Expected committed"); return
        }
        let firstId = c1.admittedUnitIds[0]

        // Admit second unit with same supersession key — should supersede first
        let admission2 = makeAdmission(value: .string("v2"))
        let result2 = await actor.submit(WriteTransaction(admissions: [admission2]))

        if case .committed(let c2) = result2 {
            #expect(c2.supersededUnitIds.contains(firstId))
        } else {
            Issue.record("Expected committed transaction")
        }

        // Verify first unit is superseded
        let firstUnit = await actor.unit(for: firstId)
        #expect(firstUnit?.status == .superseded)
    }

    @Test("Reject transaction with invalid provenance")
    func rejectInvalidProvenance() async {
        let actor = await makeIdleActor()

        let admission = makeAdmission(provenance: makeProvenance(producer: ""))
        let transaction = WriteTransaction(admissions: [admission])
        let result = await actor.submit(transaction)

        if case .rejected = result {
            // Expected
        } else {
            Issue.record("Expected rejected transaction")
        }
    }

    @Test("Status transition — invalidate active unit")
    func invalidateActiveUnit() async {
        let actor = await makeIdleActor()

        // Admit a unit
        let admission = makeAdmission()
        let result = await actor.submit(WriteTransaction(admissions: [admission]))
        guard case .committed(let committed) = result else {
            Issue.record("Expected committed"); return
        }
        let unitId = committed.admittedUnitIds[0]

        // Invalidate it
        let transition = StatusTransition.invalidate(
            unitId,
            metadata: InvalidationMetadata(epoch: .zero, reason: .sourceChanged)
        )
        let result2 = await actor.submit(WriteTransaction(transitions: [transition]))

        if case .committed = result2 {
            let unit = await actor.unit(for: unitId)
            #expect(unit?.status == .invalidated)
        } else {
            Issue.record("Expected committed transition")
        }
    }

    @Test("Reject transition for nonexistent unit")
    func rejectTransitionNonexistent() async {
        let actor = await makeIdleActor()

        let transition = StatusTransition.invalidate(
            UnitIdentifier(rawValue: 999),
            metadata: InvalidationMetadata(epoch: .zero, reason: .sourceChanged)
        )
        let result = await actor.submit(WriteTransaction(transitions: [transition]))

        if case .rejected = result {
            // Expected — unit not found
        } else {
            Issue.record("Expected rejected transaction")
        }
    }
}

// MARK: — EpochControl Tests

@Suite("EpochControl")
struct EpochControlTests {

    @Test("advanceEpoch increments monotonically")
    func epochAdvances() async {
        let actor = await makeIdleActor()

        let e1 = await actor.advanceEpoch()
        #expect(e1.value == 1)

        let e2 = await actor.advanceEpoch()
        #expect(e2.value == 2)

        let e3 = await actor.advanceEpoch()
        #expect(e3.value == 3)
    }

    @Test("committedEpoch reflects advanced epoch")
    func committedEpochReflects() async {
        let actor = await makeIdleActor()

        _ = await actor.advanceEpoch()
        let epoch = await actor.committedEpoch
        #expect(epoch.value == 1)
    }
}

// MARK: — Change Batch Observer Tests

@Suite("ChangeBatchObserver Notification")
struct ChangeBatchObserverTests {

    @Test("Observer notified on unit admission")
    func observerNotifiedOnAdmission() async {
        let observer = MockChangeBatchObserver()
        let actor = await makeIdleActor(changeBatchObserver: observer)

        let admission = makeAdmission()
        _ = await actor.submit(WriteTransaction(admissions: [admission]))

        #expect(observer.committedBatches.count == 1)
        #expect(observer.committedBatches[0].changes.count >= 1)
    }

    @Test("Observer not notified on rejected transaction")
    func observerNotNotifiedOnRejection() async {
        let observer = MockChangeBatchObserver()
        let actor = await makeIdleActor(changeBatchObserver: observer)

        let admission = makeAdmission(provenance: makeProvenance(producer: ""))
        _ = await actor.submit(WriteTransaction(admissions: [admission]))

        #expect(observer.committedBatches.isEmpty)
    }
}

// MARK: — Demand Signal Tests

@Suite("DemandSignalSink")
struct DemandSignalTests {

    @Test("Demand signal for non-existent T2 unit is handled")
    func demandSignalForMissing() async {
        let deferredPersistence = MockDeferredQueuePersistence()
        let actor = await makeIdleActor(deferredQueuePersistence: deferredPersistence)

        let signal = DemandSignal(
            subject: .entity(EntityReference(qualifiedName: "TestEntity")),
            predicate: PredicateIdentifier(name: "semantic", domain: "test"),
            tier: .t2
        )
        await actor.submit(signal)

        // Signal for non-existent unit should be logged but not enqueued
        // (no invalidated unit to recompute)
        let queueSize = await actor.deferredQueueSize()
        #expect(queueSize == 0)
    }
}

// MARK: — Snapshot Integration Tests

@Suite("Snapshot Integration")
struct SnapshotIntegrationTests {

    @Test("Restore from snapshot preserves epoch")
    func restorePreservesEpoch() async {
        let snap = MockSnapshotPersistence()
        snap.nextLoadResult = .loaded(SnapshotData(
            units: [],
            epoch: Epoch(value: 42),
            nextUnitId: 100,
            contentHashes: [:],
            deferredQueue: []
        ))

        let actor = await makeIdleActor(snapshotPersistence: snap)
        let epoch = await actor.committedEpoch
        #expect(epoch.value == 42)
    }

    @Test("Restore from snapshot preserves deferred queue")
    func restorePreservesDeferredQueue() async {
        let unit = makeUnit(id: UnitIdentifier(rawValue: 5))
        let snap = MockSnapshotPersistence()
        snap.nextLoadResult = .loaded(SnapshotData(
            units: [unit],
            epoch: Epoch(value: 1),
            nextUnitId: 6,
            contentHashes: [:],
            deferredQueue: [UnitIdentifier(rawValue: 5)]
        ))

        let actor = await makeIdleActor(snapshotPersistence: snap)
        let queueSize = await actor.deferredQueueSize()
        #expect(queueSize == 1)
    }

    @Test("Deferred queue cleaned of missing units during reconciliation")
    func deferredQueueCleaned() async {
        let snap = MockSnapshotPersistence()
        // Deferred queue references unit 99 which doesn't exist in snapshot
        snap.nextLoadResult = .loaded(SnapshotData(
            units: [],
            epoch: Epoch(value: 1),
            nextUnitId: 1,
            contentHashes: [:],
            deferredQueue: [UnitIdentifier(rawValue: 99)]
        ))

        let actor = await makeIdleActor(snapshotPersistence: snap)
        let queueSize = await actor.deferredQueueSize()
        #expect(queueSize == 0)
    }
}

// MARK: — Store Metrics Tests

@Suite("Store Metrics")
struct StoreMetricsTests {

    @Test("Empty store metrics")
    func emptyMetrics() async {
        let actor = await makeIdleActor()
        let metrics = await actor.storeMetrics()
        #expect(metrics.total == 0)
        #expect(metrics.active == 0)
        #expect(metrics.invalidated == 0)
        #expect(metrics.epoch == .zero)
    }

    @Test("Metrics after admissions")
    func metricsAfterAdmissions() async {
        let actor = await makeIdleActor()

        let admission = makeAdmission()
        _ = await actor.submit(WriteTransaction(admissions: [admission]))

        let metrics = await actor.storeMetrics()
        #expect(metrics.total == 1)
        #expect(metrics.active == 1)
    }

    @Test("GC is not due initially")
    func gcNotDueInitially() async {
        let actor = await makeIdleActor()
        let due = await actor.isGCDue()
        #expect(!due)
    }
}

// MARK: — UnitStore Tests

@Suite("UnitStore")
struct UnitStoreTests {

    @Test("assignId returns monotonically increasing IDs")
    func assignIdMonotonic() {
        var store = UnitStore()
        let id1 = store.assignId()
        let id2 = store.assignId()
        let id3 = store.assignId()
        #expect(id1.rawValue == 1)
        #expect(id2.rawValue == 2)
        #expect(id3.rawValue == 3)
    }

    @Test("assignId starts from custom initial value")
    func assignIdCustomStart() {
        var store = UnitStore(nextUnitId: 100)
        let id = store.assignId()
        #expect(id.rawValue == 100)
    }

    @Test("Empty store queries")
    func emptyQueries() {
        let store = UnitStore()
        #expect(store.count == 0)
        #expect(store.activeCount == 0)
        #expect(store.activeUnits().isEmpty)
        #expect(store.invalidatedUnits().isEmpty)
        #expect(store.allUnits().isEmpty)
    }

    @Test("processTransaction admits unit")
    func processTransactionAdmits() {
        var store = UnitStore()
        let admission = makeAdmission()
        let transaction = WriteTransaction(admissions: [admission])

        let result = store.processTransaction(transaction)
        if case .committed(let committed) = result {
            #expect(committed.admittedUnitIds.count == 1)
            #expect(store.count == 1)
            #expect(store.activeCount == 1)
        } else {
            Issue.record("Expected committed")
        }
    }

    @Test("processTransaction handles supersession")
    func processTransactionSupersession() {
        var store = UnitStore()

        // Admit first unit
        let admission1 = makeAdmission(value: .string("old"))
        _ = store.processTransaction(WriteTransaction(admissions: [admission1]))

        // Admit second unit with same key — supersedes first
        let admission2 = makeAdmission(value: .string("new"))
        let result = store.processTransaction(WriteTransaction(admissions: [admission2]))

        if case .committed(let committed) = result {
            #expect(committed.supersededUnitIds.count == 1)
            #expect(store.activeCount == 1)
            // Total units is 2 — old superseded + new active
            #expect(store.count == 2)
        } else {
            Issue.record("Expected committed")
        }
    }

    @Test("processTransaction rejects invalid admission")
    func processTransactionRejects() {
        var store = UnitStore()
        let admission = makeAdmission(provenance: makeProvenance(producer: ""))
        let transaction = WriteTransaction(admissions: [admission])

        let result = store.processTransaction(transaction)
        if case .rejected(let rejection) = result {
            #expect(!rejection.failures.isEmpty)
        } else {
            Issue.record("Expected rejected")
        }
    }

    @Test("processTransaction applies status transition")
    func processTransactionTransition() {
        var store = UnitStore()

        // Admit
        let admission = makeAdmission()
        let admitResult = store.processTransaction(WriteTransaction(admissions: [admission]))
        guard case .committed(let committed) = admitResult else {
            Issue.record("Expected committed"); return
        }
        let unitId = committed.admittedUnitIds[0]

        // Invalidate
        let transition = StatusTransition.invalidate(
            unitId,
            metadata: InvalidationMetadata(epoch: .zero, reason: .sourceChanged)
        )
        let transResult = store.processTransaction(WriteTransaction(transitions: [transition]))

        if case .committed = transResult {
            let unit = store.unit(for: unitId)
            #expect(unit?.status == .invalidated)
            #expect(store.activeCount == 0)
        } else {
            Issue.record("Expected committed transition")
        }
    }

    @Test("loadFromSnapshot restores state")
    func loadFromSnapshot() {
        var store = UnitStore()
        let unit = makeUnit(id: UnitIdentifier(rawValue: 10))
        let snapshot = SnapshotData(
            units: [unit],
            epoch: Epoch(value: 5),
            nextUnitId: 11,
            contentHashes: [:],
            deferredQueue: []
        )

        store.loadFromSnapshot(snapshot)
        #expect(store.count == 1)
        #expect(store.nextUnitId == 11)
        #expect(store.unit(for: UnitIdentifier(rawValue: 10)) != nil)
    }

    @Test("clear removes all state")
    func clearRemovesAll() {
        var store = UnitStore()
        _ = store.processTransaction(WriteTransaction(admissions: [makeAdmission()]))
        #expect(store.count == 1)

        store.clear()
        #expect(store.count == 0)
        #expect(store.activeCount == 0)
    }

    @Test("activeUnit(for:) returns unit by supersession key")
    func activeUnitByKey() {
        var store = UnitStore()
        let admission = makeAdmission(
            subject: .entity(EntityReference(qualifiedName: "Foo")),
            predicate: PredicateIdentifier(name: "kind", domain: "test")
        )
        _ = store.processTransaction(WriteTransaction(admissions: [admission]))

        let key = SupersessionKey(
            subject: .entity(EntityReference(qualifiedName: "Foo")),
            predicate: PredicateIdentifier(name: "kind", domain: "test"),
            tier: .t0
        )
        let found = store.activeUnit(for: key)
        #expect(found != nil)
        #expect(found?.predicate.name == "kind")
    }
}

// MARK: — IntakeValidator Tests

@Suite("IntakeValidator")
struct IntakeValidatorTests {

    @Test("Valid admission passes validation")
    func validAdmission() {
        let admission = makeAdmission()
        let result = IntakeValidator.validate(
            admission,
            existingUnitIds: [],
            batchPriorIds: []
        )
        #expect(result == nil)
    }

    @Test("Empty provenance producer fails PV-1")
    func emptyProvenanceFails() {
        let admission = makeAdmission(provenance: makeProvenance(producer: ""))
        let result = IntakeValidator.validate(
            admission,
            existingUnitIds: [],
            batchPriorIds: []
        )
        guard let violation = result else { Issue.record("Expected violation"); return }
        if case .incompleteProvenance = violation {} else {
            Issue.record("Expected incompleteProvenance, got \(violation)")
        }
    }

    @Test("Empty version stamp fails")
    func emptyVersionStampFails() {
        let admission = makeAdmission(
            version: VersionStamp(sourceHashes: [])
        )
        let result = IntakeValidator.validate(
            admission,
            existingUnitIds: [],
            batchPriorIds: []
        )
        guard let violation = result else { Issue.record("Expected violation"); return }
        if case .emptyVersionStamp = violation {} else {
            Issue.record("Expected emptyVersionStamp, got \(violation)")
        }
    }

    @Test("Confidence-tier mismatch fails TE-2")
    func confidenceTierMismatch() {
        // T0 requires .deterministic confidence
        let admission = makeAdmission(
            tier: .t0,
            confidence: .low
        )
        let result = IntakeValidator.validate(
            admission,
            existingUnitIds: [],
            batchPriorIds: []
        )
        guard let violation = result else { Issue.record("Expected violation"); return }
        if case .confidenceTierMismatch = violation {} else {
            Issue.record("Expected confidenceTierMismatch, got \(violation)")
        }
    }

    @Test("Input reference to nonexistent unit fails PV-3")
    func inputReferenceToMissing() {
        let admission = makeAdmission(
            provenance: makeProvenance(inputUnitIds: [UnitIdentifier(rawValue: 999)])
        )
        let result = IntakeValidator.validate(
            admission,
            existingUnitIds: [],
            batchPriorIds: []
        )
        guard let violation = result else { Issue.record("Expected violation"); return }
        if case .incompleteProvenance = violation {} else {
            Issue.record("Expected incompleteProvenance, got \(violation)")
        }
    }

    @Test("Input reference in batchPriorIds passes PV-3")
    func inputReferenceInBatch() {
        let refId = UnitIdentifier(rawValue: 5)
        let admission = makeAdmission(
            provenance: makeProvenance(inputUnitIds: [refId])
        )
        let result = IntakeValidator.validate(
            admission,
            existingUnitIds: [],
            batchPriorIds: [refId]
        )
        #expect(result == nil)
    }

    @Test("validateBatch returns all violations")
    func validateBatchMultipleViolations() {
        let admissions = [
            makeAdmission(provenance: makeProvenance(producer: "")),
            makeAdmission(version: VersionStamp(sourceHashes: [])),
        ]
        var batchIds = Set<UnitIdentifier>()
        let failures = IntakeValidator.validateBatch(
            admissions,
            existingUnitIds: [],
            batchAdmittedIds: &batchIds,
            nextId: 1
        )
        #expect(failures.count >= 2)
    }

    @Test("validateTransitions rejects transition for missing unit")
    func validateTransitionMissingUnit() {
        let transitions = [
            StatusTransition.invalidate(
                UnitIdentifier(rawValue: 999),
                metadata: InvalidationMetadata(epoch: .zero, reason: .sourceChanged)
            )
        ]
        let failures = IntakeValidator.validateTransitions(transitions) { _ in nil }
        #expect(failures.count == 1)
    }

    @Test("validateTransitions rejects invalid status transition")
    func validateInvalidStatusTransition() {
        var unit = makeUnit()
        unit.invalidate(metadata: InvalidationMetadata(epoch: .zero, reason: .sourceChanged))

        let transitions = [
            StatusTransition.invalidate(
                unit.id,
                metadata: InvalidationMetadata(epoch: .zero, reason: .sourceChanged)
            )
        ]
        let failures = IntakeValidator.validateTransitions(transitions) { _ in unit }
        // invalidated -> invalidated is not a valid transition
        #expect(failures.count == 1)
    }
}

// MARK: — UpdateEngineError Tests

@Suite("UpdateEngineError")
struct UpdateEngineErrorTests {

    @Test("Error cases are constructible")
    func errorCases() {
        let errors: [UpdateEngineError] = [
            .intakeValidationFailed(violations: [.incompleteProvenance]),
            .invalidStatusTransition(
                unitId: UnitIdentifier(rawValue: 1),
                from: .active, to: .active
            ),
            .unitNotFound(UnitIdentifier(rawValue: 1)),
            .supersessionConflict(key: SupersessionKey(
                subject: .entity(EntityReference(qualifiedName: "A")),
                predicate: PredicateIdentifier(name: "p", domain: "d"),
                tier: .t0
            )),
            .memoryExhausted,
            .frontendParseFailed(filePath: "test.swift", detail: "parse error"),
            .synchronousPassFailed(producerId: "pass1", detail: "failed"),
            .deferredRecomputationFailed(unitId: UnitIdentifier(rawValue: 1), detail: "timeout"),
            .invalidationRejected(unitId: UnitIdentifier(rawValue: 1), detail: "already invalidated"),
            .indexUpdateFailed(detail: "index corruption"),
            .groundingMapUnavailable,
            .invalidState(current: .created, attempted: "processChangeSet"),
            .notOperational,
        ]
        #expect(errors.count == 13)
    }
}

// MARK: — FileChangeEvent Tests

@Suite("FileChangeEvent")
struct FileChangeEventTests {

    @Test("FileChangeType raw values")
    func changeTypeRawValues() {
        #expect(FileChangeType.modified.rawValue == "modified")
        #expect(FileChangeType.created.rawValue == "created")
        #expect(FileChangeType.deleted.rawValue == "deleted")
    }

    @Test("ChangeSet groups events")
    func changeSetGroups() {
        let events = [
            FileChangeEvent(filePath: "a.swift", changeType: .modified),
            FileChangeEvent(filePath: "b.swift", changeType: .created),
        ]
        let set = ChangeSet(events: events)
        #expect(set.events.count == 2)
    }

    @Test("ChangeSetResult captures all metrics")
    func changeSetResultMetrics() {
        let result = ChangeSetResult(
            totalFiles: 10,
            hashFilteredFiles: 3,
            directInvalidations: 5,
            cascadeInvalidations: 2,
            deferredT2Units: 1,
            syncRecomputationTickets: 4,
            earlyTerminations: 1,
            epochBefore: Epoch(value: 1),
            epochAfter: Epoch(value: 2),
            duration: 0.5
        )
        #expect(result.totalFiles == 10)
        #expect(result.hashFilteredFiles == 3)
        #expect(result.directInvalidations == 5)
        #expect(result.cascadeInvalidations == 2)
        #expect(result.deferredT2Units == 1)
        #expect(result.syncRecomputationTickets == 4)
        #expect(result.earlyTerminations == 1)
        #expect(result.duration == 0.5)
    }
}
