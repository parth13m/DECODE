// StorageEngineTests.swift — StorageEngine
// IAG-004 §4: Phase 2 — StorageEngine unit tests
// Tests: state model, grounding map, content hash map, GC, snapshots,
//        deferred queue, change batch observer

import Testing
import Foundation
@testable import StorageEngine
@testable import DIRCore
@testable import UnderstandingTestSupport

// MARK: — Test Helpers

/// Creates a StorageActor with test defaults.
private func makeActor(
    dirRead: MockDIRReadAccess = MockDIRReadAccess(),
    dirWrite: MockDIRWriteAccess = MockDIRWriteAccess(),
    retentionPolicy: GCRetentionPolicy = .default
) -> StorageActor {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("StorageEngineTests-\(UUID().uuidString)")
    return StorageActor(
        dirRead: dirRead,
        dirWrite: dirWrite,
        snapshotDirectory: tmpDir,
        retentionPolicy: retentionPolicy
    )
}

/// Creates a superseded unit for GC testing.
private func makeSupersededUnit(
    id: UInt64,
    tier: Tier = .t0,
    supersedingId: UInt64 = 999,
    invalidationEpoch: UInt64 = 0,
    provenance: ProvenanceRecord? = nil,
    grounding: GroundingChain? = nil
) -> AtomicUnit {
    var unit = makeUnit(
        id: UnitIdentifier(rawValue: id),
        tier: tier,
        provenance: provenance,
        grounding: grounding
    )
    unit.invalidate(metadata: InvalidationMetadata(
        epoch: Epoch(value: invalidationEpoch),
        reason: .sourceChanged
    ))
    unit.supersede(by: UnitIdentifier(rawValue: supersedingId))
    return unit
}

/// Creates an invalidated unit for GC testing.
private func makeInvalidatedUnit(
    id: UInt64,
    tier: Tier = .t0,
    invalidationEpoch: UInt64 = 0,
    provenance: ProvenanceRecord? = nil,
    grounding: GroundingChain? = nil
) -> AtomicUnit {
    var unit = makeUnit(
        id: UnitIdentifier(rawValue: id),
        tier: tier,
        provenance: provenance,
        grounding: grounding
    )
    unit.invalidate(metadata: InvalidationMetadata(
        epoch: Epoch(value: invalidationEpoch),
        reason: .sourceChanged
    ))
    return unit
}

// MARK: — State Model Tests

@Suite("StorageEngineState")
struct StorageEngineStateTests {

    @Test("Initial state is created")
    func initialState() async {
        let actor = makeActor()
        let state = await actor.currentState()
        #expect(state == .created)
    }

    @Test("Valid lifecycle: created → loading → mapBuilding → operational → quiescing → terminated")
    func fullLifecycle() async {
        let actor = makeActor()

        await actor.beginLoading()
        #expect(await actor.currentState() == .loading)

        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        #expect(await actor.currentState() == .mapBuilding)

        await actor.constructGroundingMap()
        #expect(await actor.currentState() == .operational)

        await actor.shutdown()
        #expect(await actor.currentState() == .quiescing)

        await actor.terminate()
        #expect(await actor.currentState() == .terminated)
    }

    @Test("Terminate clears all state")
    func terminateClearsState() async {
        let actor = makeActor()
        await actor.beginLoading()
        await actor.completeLoading(
            contentHashes: ["a.swift": makeContentHash(1)],
            deferredQueue: [UnitIdentifier(rawValue: 1)]
        )
        await actor.constructGroundingMap()

        // Verify state is populated
        #expect(await actor.trackedFileCount() == 1)
        #expect(await actor.deferredQueue().count == 1)
        #expect(await actor.isMapAvailable() == true)

        await actor.shutdown()
        await actor.terminate()

        // All cleared
        #expect(await actor.trackedFileCount() == 0)
        #expect(await actor.deferredQueue().isEmpty)
        #expect(await actor.isMapAvailable() == false)
    }
}

// MARK: — StorageEngineState Transition Tests

@Suite("StorageEngineState transitions")
struct StorageEngineStateTransitionTests {

    @Test("Valid transitions accepted")
    func validTransitions() {
        #expect(StorageEngineState.created.canTransition(to: .loading))
        #expect(StorageEngineState.loading.canTransition(to: .mapBuilding))
        #expect(StorageEngineState.mapBuilding.canTransition(to: .operational))
        #expect(StorageEngineState.operational.canTransition(to: .quiescing))
        #expect(StorageEngineState.quiescing.canTransition(to: .terminated))
    }

    @Test("Invalid transitions rejected")
    func invalidTransitions() {
        #expect(!StorageEngineState.created.canTransition(to: .operational))
        #expect(!StorageEngineState.loading.canTransition(to: .operational))
        #expect(!StorageEngineState.operational.canTransition(to: .loading))
        #expect(!StorageEngineState.terminated.canTransition(to: .created))
        #expect(!StorageEngineState.created.canTransition(to: .terminated))
    }
}

// MARK: — Grounding Dependency Map Tests

@Suite("Grounding Dependency Map")
struct GroundingDependencyMapTests {

    @Test("Construction from DIR — direct grounding has no edges")
    func constructionDirectGrounding() async {
        let dirRead = MockDIRReadAccess()
        let unitA = makeUnit(id: UnitIdentifier(rawValue: 1))
        dirRead.units[unitA.id] = unitA

        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Direct grounding: no provenance inputs, no edges
        let result = await actor.dependents(of: UnitIdentifier(rawValue: 1))
        if case .available(let deps) = result {
            #expect(deps.isEmpty)
        } else {
            Issue.record("Expected .available")
        }
    }

    @Test("Construction from DIR — derived grounding creates edges")
    func constructionDerivedGrounding() async {
        let dirRead = MockDIRReadAccess()
        let unitA = makeUnit(id: UnitIdentifier(rawValue: 1))
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            grounding: .derived([UnitIdentifier(rawValue: 1)])
        )
        dirRead.units[unitA.id] = unitA
        dirRead.units[unitB.id] = unitB

        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Unit B depends on Unit A → A should have B as dependent
        let result = await actor.dependents(of: UnitIdentifier(rawValue: 1))
        if case .available(let deps) = result {
            #expect(deps.contains(UnitIdentifier(rawValue: 2)))
        } else {
            Issue.record("Expected .available")
        }
    }

    @Test("Construction from DIR — inferred grounding creates edges")
    func constructionInferredGrounding() async {
        let dirRead = MockDIRReadAccess()
        let unitA = makeUnit(id: UnitIdentifier(rawValue: 1))
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            grounding: .inferred(
                inputUnits: [UnitIdentifier(rawValue: 1)],
                method: "semantic"
            )
        )
        dirRead.units[unitA.id] = unitA
        dirRead.units[unitB.id] = unitB

        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let result = await actor.dependents(of: UnitIdentifier(rawValue: 1))
        if case .available(let deps) = result {
            #expect(deps.contains(UnitIdentifier(rawValue: 2)))
        } else {
            Issue.record("Expected .available")
        }
    }

    @Test("Construction from DIR — provenance inputs create edges")
    func constructionProvenanceInputs() async {
        let dirRead = MockDIRReadAccess()
        let unitA = makeUnit(id: UnitIdentifier(rawValue: 1))
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            provenance: makeProvenance(inputUnitIds: [UnitIdentifier(rawValue: 1)])
        )
        dirRead.units[unitA.id] = unitA
        dirRead.units[unitB.id] = unitB

        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let result = await actor.dependents(of: UnitIdentifier(rawValue: 1))
        if case .available(let deps) = result {
            #expect(deps.contains(UnitIdentifier(rawValue: 2)))
        } else {
            Issue.record("Expected .available")
        }
    }

    @Test("Map not available before construction")
    func mapNotAvailableBeforeConstruction() async {
        let actor = makeActor()
        #expect(await actor.isMapAvailable() == false)

        let result = await actor.dependents(of: UnitIdentifier(rawValue: 1))
        if case .notAvailable = result {
            // correct
        } else {
            Issue.record("Expected .notAvailable before construction")
        }
    }

    @Test("Grounding map metrics reflect state")
    func groundingMapMetrics() async {
        let dirRead = MockDIRReadAccess()
        let unitA = makeUnit(id: UnitIdentifier(rawValue: 1))
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            grounding: .derived([UnitIdentifier(rawValue: 1)])
        )
        dirRead.units[unitA.id] = unitA
        dirRead.units[unitB.id] = unitB
        dirRead.epoch = Epoch(value: 5)

        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let metrics = await actor.groundingMapMetrics()
        #expect(metrics.edgeCount > 0)
        #expect(metrics.lastEpoch == Epoch(value: 5))
    }
}

// MARK: — Content Hash Map Tests

@Suite("Content Hash Map")
struct ContentHashMapTests {

    @Test("CRUD operations")
    func crudOperations() async {
        let actor = makeActor()
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Create
        let hash = makeContentHash(42)
        await actor.updateContentHash(for: "main.swift", hash: hash)
        #expect(await actor.trackedFileCount() == 1)

        // Read
        let retrieved = await actor.contentHash(for: "main.swift")
        #expect(retrieved == hash)

        // Read missing
        let missing = await actor.contentHash(for: "nonexistent.swift")
        #expect(missing == nil)

        // Update
        let newHash = makeContentHash(99)
        await actor.updateContentHash(for: "main.swift", hash: newHash)
        #expect(await actor.contentHash(for: "main.swift") == newHash)

        // Delete
        await actor.removeContentHash(for: "main.swift")
        #expect(await actor.contentHash(for: "main.swift") == nil)
        #expect(await actor.trackedFileCount() == 0)
    }

    @Test("Bulk load from completeLoading")
    func bulkLoad() async {
        let actor = makeActor()
        let hashes: [String: ContentHash] = [
            "a.swift": makeContentHash(1),
            "b.swift": makeContentHash(2),
            "c.swift": makeContentHash(3),
        ]

        await actor.beginLoading()
        await actor.completeLoading(contentHashes: hashes, deferredQueue: [])

        #expect(await actor.trackedFileCount() == 3)
        #expect(await actor.contentHash(for: "a.swift") == makeContentHash(1))
        #expect(await actor.contentHash(for: "b.swift") == makeContentHash(2))
        #expect(await actor.contentHash(for: "c.swift") == makeContentHash(3))

        let allHashes = await actor.allContentHashes()
        #expect(allHashes.count == 3)
    }
}

// MARK: — Deferred Queue Tests

@Suite("Deferred Queue")
struct DeferredQueueTests {

    @Test("Queue operations")
    func queueOperations() async {
        let actor = makeActor()
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Initially empty
        #expect(await actor.deferredQueue().isEmpty)

        // Enqueue
        await actor.enqueueDeferredUnit(UnitIdentifier(rawValue: 1))
        await actor.enqueueDeferredUnit(UnitIdentifier(rawValue: 2))
        #expect(await actor.deferredQueue().count == 2)

        // No duplicates
        await actor.enqueueDeferredUnit(UnitIdentifier(rawValue: 1))
        #expect(await actor.deferredQueue().count == 2)

        // Dequeue
        await actor.dequeueDeferredUnit(UnitIdentifier(rawValue: 1))
        #expect(await actor.deferredQueue().count == 1)
        #expect(await actor.deferredQueue().first == UnitIdentifier(rawValue: 2))

        // Dequeue nonexistent — no-op
        await actor.dequeueDeferredUnit(UnitIdentifier(rawValue: 99))
        #expect(await actor.deferredQueue().count == 1)
    }

    @Test("Bulk update replaces entire queue")
    func bulkUpdate() async {
        let actor = makeActor()
        await actor.beginLoading()
        await actor.completeLoading(
            contentHashes: [:],
            deferredQueue: [UnitIdentifier(rawValue: 1)]
        )
        await actor.constructGroundingMap()

        #expect(await actor.deferredQueue().count == 1)

        let newQueue = [UnitIdentifier(rawValue: 10), UnitIdentifier(rawValue: 20)]
        await actor.updateDeferredQueue(newQueue)
        #expect(await actor.deferredQueue() == newQueue)
    }

    @Test("Loaded from completeLoading")
    func loadedFromCompleteLoading() async {
        let actor = makeActor()
        let queue = [UnitIdentifier(rawValue: 5), UnitIdentifier(rawValue: 10)]
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: queue)

        #expect(await actor.deferredQueue() == queue)
    }
}

// MARK: — GC Retention Policy Tests

@Suite("GC Retention Policy")
struct GCRetentionPolicyTests {

    @Test("T0/T1 superseded eligible after retention period (GC-R1)")
    func t0t1SupersededEligible() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        // Superseded at epoch 0, with retention = 1
        let unit = makeSupersededUnit(id: 1, tier: .t0, invalidationEpoch: 0)
        dirRead.units[unit.id] = unit

        let actor = makeActor(
            dirRead: dirRead,
            dirWrite: dirWrite,
            retentionPolicy: GCRetentionPolicy(t0t1RetentionEpochs: 1)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Current epoch 1 = invalidation(0) + retention(1) → eligible
        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 1))
        #expect(result.candidatesEvaluated == 1)
        #expect(result.candidatesCollected == 1)
        #expect(dirWrite.submittedTransactions.count == 1)
    }

    @Test("T0/T1 superseded NOT eligible before retention period")
    func t0t1SupersededNotYetEligible() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        // Superseded at epoch 5, retention = 3
        let unit = makeSupersededUnit(id: 1, tier: .t0, invalidationEpoch: 5)
        dirRead.units[unit.id] = unit

        let actor = makeActor(
            dirRead: dirRead,
            dirWrite: dirWrite,
            retentionPolicy: GCRetentionPolicy(t0t1RetentionEpochs: 3)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Epoch 7 < invalidation(5) + retention(3) = 8
        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 7))
        #expect(result.candidatesEvaluated == 1)
        #expect(result.candidatesCollected == 0)
        #expect(result.candidatesSkippedRetention == 1)
    }

    @Test("T2 superseded has longer retention period (GC-R2)")
    func t2SupersededLongerRetention() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        // T2 superseded at epoch 0, retention = 100
        let unit = makeSupersededUnit(id: 1, tier: .t2, invalidationEpoch: 0)
        dirRead.units[unit.id] = unit

        let actor = makeActor(
            dirRead: dirRead,
            dirWrite: dirWrite,
            retentionPolicy: GCRetentionPolicy(t2RetentionEpochs: 100)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Epoch 50 < 100 → not eligible
        let result50 = await actor.collectGarbage(currentEpoch: Epoch(value: 50))
        #expect(result50.candidatesSkippedRetention == 1)

        // Epoch 100 → eligible
        let result100 = await actor.collectGarbage(currentEpoch: Epoch(value: 100))
        #expect(result100.candidatesCollected == 1)
    }

    @Test("Invalidated T2 never collected (GC-R3)")
    func invalidatedT2NeverCollected() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        // T2 invalidated but NOT superseded
        let unit = makeInvalidatedUnit(id: 1, tier: .t2, invalidationEpoch: 0)
        dirRead.units[unit.id] = unit

        let actor = makeActor(dirRead: dirRead, dirWrite: dirWrite)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Even at a very high epoch, T2 invalidated should not be collected
        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 10000))
        #expect(result.candidatesEvaluated == 1)
        #expect(result.candidatesCollected == 0)
        #expect(result.candidatesSkippedRetention == 1)
    }

    @Test("Active units are never GC candidates")
    func activeUnitsSkipped() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        let unit = makeUnit(id: UnitIdentifier(rawValue: 1))
        dirRead.units[unit.id] = unit

        let actor = makeActor(dirRead: dirRead, dirWrite: dirWrite)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 1000))
        #expect(result.candidatesEvaluated == 0)
        #expect(result.candidatesCollected == 0)
    }
}

// MARK: — GC Safety Tests

@Suite("GC Safety")
struct GCSafetyTests {

    @Test("Unit with active dependent is skipped (DAS-012 I7)")
    func unitWithActiveDependentSkipped() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        // Unit A is superseded (GC candidate), Unit B is active and depends on A
        let unitA = makeSupersededUnit(id: 1, tier: .t0, invalidationEpoch: 0)
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            grounding: .derived([UnitIdentifier(rawValue: 1)])
        )
        dirRead.units[unitA.id] = unitA
        dirRead.units[unitB.id] = unitB

        let actor = makeActor(
            dirRead: dirRead,
            dirWrite: dirWrite,
            retentionPolicy: GCRetentionPolicy(t0t1RetentionEpochs: 1)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 10))
        #expect(result.candidatesEvaluated == 1)
        #expect(result.candidatesCollected == 0)
        #expect(result.candidatesSkippedSafety == 1)
    }

    @Test("Unit with no active dependents is collected")
    func unitWithNoActiveDependentsCollected() async {
        let dirRead = MockDIRReadAccess()
        let dirWrite = MockDIRWriteAccess()

        // Superseded unit with no dependents
        let unit = makeSupersededUnit(id: 1, tier: .t0, invalidationEpoch: 0)
        dirRead.units[unit.id] = unit

        let actor = makeActor(
            dirRead: dirRead,
            dirWrite: dirWrite,
            retentionPolicy: GCRetentionPolicy(t0t1RetentionEpochs: 1)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 10))
        #expect(result.candidatesCollected == 1)

        // Verify GC directive was submitted
        #expect(dirWrite.submittedTransactions.count == 1)
        let tx = dirWrite.submittedTransactions[0]
        #expect(tx.transitions.count == 1)
        #expect(tx.transitions[0].targetStatus == .garbageCollected)
        #expect(tx.transitions[0].unitId == UnitIdentifier(rawValue: 1))
    }

    @Test("GC does nothing when not operational")
    func gcNotOperational() async {
        let actor = makeActor()
        // State is .created, not operational
        let result = await actor.collectGarbage(currentEpoch: Epoch(value: 100))
        #expect(result.candidatesEvaluated == 0)
        #expect(result.duration == 0)
    }

    @Test("GC resets epochsSinceLastGC")
    func gcResetsEpochCounter() async {
        let dirRead = MockDIRReadAccess()
        let actor = makeActor(
            dirRead: dirRead,
            retentionPolicy: GCRetentionPolicy(gcIntervalEpochs: 5)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Simulate 5 epochs via change batches
        for i: UInt64 in 1...5 {
            await actor.didCommit(ChangeBatch(epoch: Epoch(value: i), changes: []))
        }
        #expect(await actor.isGCDue() == true)

        // Run GC
        _ = await actor.collectGarbage(currentEpoch: Epoch(value: 5))
        #expect(await actor.isGCDue() == false)
    }
}

// MARK: — Snapshot Persistence Tests

@Suite("Snapshot Persistence")
struct SnapshotPersistenceTests {

    @Test("Capture and load round-trip")
    func captureAndLoadRoundTrip() async throws {
        let dirRead = MockDIRReadAccess()
        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let unit = makeUnit(id: UnitIdentifier(rawValue: 1))
        let snapshot = SnapshotData(
            units: [unit],
            epoch: Epoch(value: 42),
            nextUnitId: 2,
            contentHashes: ["test.swift": makeContentHash(1)],
            deferredQueue: [UnitIdentifier(rawValue: 10)]
        )

        try await actor.captureSnapshot(snapshot)
        #expect(await actor.lastSnapshotEpoch() == Epoch(value: 42))

        // Load it back
        let loadResult = await actor.loadSnapshot()
        switch loadResult {
        case .loaded(let loaded):
            #expect(loaded.epoch == Epoch(value: 42))
            #expect(loaded.units.count == 1)
            #expect(loaded.units[0].id == UnitIdentifier(rawValue: 1))
            #expect(loaded.nextUnitId == 2)
            #expect(loaded.contentHashes["test.swift"] == makeContentHash(1))
            #expect(loaded.deferredQueue == [UnitIdentifier(rawValue: 10)])
        default:
            Issue.record("Expected .loaded, got \(loadResult)")
        }
    }

    @Test("Snapshot rotation — prior exists after second capture")
    func snapshotRotation() async throws {
        let dirRead = MockDIRReadAccess()
        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        let snapshot1 = SnapshotData(
            units: [],
            epoch: Epoch(value: 1),
            nextUnitId: 1,
            contentHashes: [:],
            deferredQueue: []
        )
        let snapshot2 = SnapshotData(
            units: [],
            epoch: Epoch(value: 2),
            nextUnitId: 1,
            contentHashes: [:],
            deferredQueue: []
        )

        try await actor.captureSnapshot(snapshot1)
        try await actor.captureSnapshot(snapshot2)

        // Load should get the latest
        let loadResult = await actor.loadSnapshot()
        if case .loaded(let loaded) = loadResult {
            #expect(loaded.epoch == Epoch(value: 2))
        } else {
            Issue.record("Expected .loaded")
        }
    }

    @Test("No snapshot returns requiresFullRebuild")
    func noSnapshotReturnsFullRebuild() async {
        let actor = makeActor()
        let loadResult = await actor.loadSnapshot()
        if case .requiresFullRebuild = loadResult {
            // correct
        } else {
            Issue.record("Expected .requiresFullRebuild")
        }
    }

    @Test("Snapshot capture fails in invalid state")
    func snapshotCaptureInvalidState() async {
        let actor = makeActor()
        // State is .created — snapshot should throw
        let snapshot = SnapshotData(
            units: [],
            epoch: Epoch(value: 1),
            nextUnitId: 1,
            contentHashes: [:],
            deferredQueue: []
        )

        do {
            try await actor.captureSnapshot(snapshot)
            Issue.record("Expected StorageError.invalidState")
        } catch let error as StorageError {
            if case .invalidState(let current, _) = error {
                #expect(current == .created)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Corrupted snapshot falls back to prior (FM-2)")
    func corruptedSnapshotFallback() async throws {
        let dirRead = MockDIRReadAccess()
        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Capture two snapshots
        let snapshot1 = SnapshotData(
            units: [],
            epoch: Epoch(value: 1),
            nextUnitId: 1,
            contentHashes: [:],
            deferredQueue: []
        )
        let snapshot2 = SnapshotData(
            units: [],
            epoch: Epoch(value: 2),
            nextUnitId: 1,
            contentHashes: [:],
            deferredQueue: []
        )
        try await actor.captureSnapshot(snapshot1)
        try await actor.captureSnapshot(snapshot2)

        // Corrupt the canonical snapshot by overwriting with garbage
        // We need to get the snapshot directory — we'll use a separate actor for this test
        // with a known directory
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageEngineTests-corrupt-\(UUID().uuidString)")
        let actor2 = StorageActor(
            dirRead: dirRead,
            dirWrite: MockDIRWriteAccess(),
            snapshotDirectory: tmpDir
        )
        await actor2.beginLoading()
        await actor2.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor2.constructGroundingMap()

        try await actor2.captureSnapshot(snapshot1)
        try await actor2.captureSnapshot(snapshot2)

        // Corrupt canonical
        let canonicalPath = tmpDir.appendingPathComponent("snapshot.json")
        try Data("corrupted".utf8).write(to: canonicalPath)

        let loadResult = await actor2.loadSnapshot()
        switch loadResult {
        case .loadedPrior(let loaded):
            #expect(loaded.epoch == Epoch(value: 1))
        default:
            Issue.record("Expected .loadedPrior, got \(loadResult)")
        }

        // Clean up
        try? FileManager.default.removeItem(at: tmpDir)
    }
}

// MARK: — Change Batch Observer Tests

@Suite("ChangeBatchObserver")
struct ChangeBatchObserverTests {

    @Test("Admitted unit adds edges to grounding map")
    func admittedUnitAddsEdges() async {
        let dirRead = MockDIRReadAccess()
        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Now add a unit that depends on ID 1
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            grounding: .derived([UnitIdentifier(rawValue: 1)])
        )
        dirRead.units[unitB.id] = unitB

        let batch = ChangeBatch(
            epoch: Epoch(value: 1),
            changes: [.admitted(UnitIdentifier(rawValue: 2))]
        )
        await actor.didCommit(batch)

        // Now unit 1 should have unit 2 as dependent
        let result = await actor.dependents(of: UnitIdentifier(rawValue: 1))
        if case .available(let deps) = result {
            #expect(deps.contains(UnitIdentifier(rawValue: 2)))
        } else {
            Issue.record("Expected .available")
        }
    }

    @Test("Garbage collected unit removes edges")
    func garbageCollectedRemovesEdges() async {
        let dirRead = MockDIRReadAccess()
        // Set up: unit 2 depends on unit 1
        let unitA = makeUnit(id: UnitIdentifier(rawValue: 1))
        let unitB = makeUnit(
            id: UnitIdentifier(rawValue: 2),
            grounding: .derived([UnitIdentifier(rawValue: 1)])
        )
        dirRead.units[unitA.id] = unitA
        dirRead.units[unitB.id] = unitB

        let actor = makeActor(dirRead: dirRead)
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        // Verify edge exists
        if case .available(let deps) = await actor.dependents(of: UnitIdentifier(rawValue: 1)) {
            #expect(deps.contains(UnitIdentifier(rawValue: 2)))
        }

        // GC unit 2
        let batch = ChangeBatch(
            epoch: Epoch(value: 1),
            changes: [.garbageCollected(UnitIdentifier(rawValue: 2))]
        )
        await actor.didCommit(batch)

        // Edge should be removed
        if case .available(let deps) = await actor.dependents(of: UnitIdentifier(rawValue: 1)) {
            #expect(!deps.contains(UnitIdentifier(rawValue: 2)))
        }
    }

    @Test("Epoch counter increments on each batch")
    func epochCounterIncrements() async {
        let actor = makeActor(
            retentionPolicy: GCRetentionPolicy(gcIntervalEpochs: 3)
        )
        await actor.beginLoading()
        await actor.completeLoading(contentHashes: [:], deferredQueue: [])
        await actor.constructGroundingMap()

        #expect(await actor.isGCDue() == false)

        for i: UInt64 in 1...3 {
            await actor.didCommit(ChangeBatch(epoch: Epoch(value: i), changes: []))
        }

        #expect(await actor.isGCDue() == true)
    }

    @Test("Batch ignored in non-operational/non-mapBuilding state")
    func batchIgnoredInWrongState() async {
        let actor = makeActor()
        // State is .created — batch should be ignored silently
        await actor.didCommit(ChangeBatch(
            epoch: Epoch(value: 1),
            changes: [.admitted(UnitIdentifier(rawValue: 1))]
        ))

        // No crash, no state change
        #expect(await actor.currentState() == .created)
    }
}

// MARK: — GroundingDependencyMap Internal Tests

@Suite("GroundingDependencyMap")
struct GroundingDependencyMapInternalTests {

    @Test("Add and query edges")
    func addAndQueryEdges() {
        var map = GroundingDependencyMap()
        map.addEdge(input: UnitIdentifier(rawValue: 1), dependent: UnitIdentifier(rawValue: 2))
        map.addEdge(input: UnitIdentifier(rawValue: 1), dependent: UnitIdentifier(rawValue: 3))

        #expect(map.edgeCount == 2)
        let deps = map.dependents(of: UnitIdentifier(rawValue: 1))
        #expect(deps.count == 2)
        #expect(deps.contains(UnitIdentifier(rawValue: 2)))
        #expect(deps.contains(UnitIdentifier(rawValue: 3)))
    }

    @Test("Empty lookup returns empty set")
    func emptyLookup() {
        let map = GroundingDependencyMap()
        let deps = map.dependents(of: UnitIdentifier(rawValue: 99))
        #expect(deps.isEmpty)
    }

    @Test("addUnit adds edges from provenance inputs")
    func addUnitFromProvenance() {
        var map = GroundingDependencyMap()
        map.addUnit(
            UnitIdentifier(rawValue: 5),
            provenanceInputs: [UnitIdentifier(rawValue: 1), UnitIdentifier(rawValue: 2)]
        )

        #expect(map.edgeCount == 2)
        #expect(map.dependents(of: UnitIdentifier(rawValue: 1)).contains(UnitIdentifier(rawValue: 5)))
        #expect(map.dependents(of: UnitIdentifier(rawValue: 2)).contains(UnitIdentifier(rawValue: 5)))
    }

    @Test("removeDependent removes unit from all dependents sets")
    func removeDependent() {
        var map = GroundingDependencyMap()
        map.addEdge(input: UnitIdentifier(rawValue: 1), dependent: UnitIdentifier(rawValue: 5))
        map.addEdge(input: UnitIdentifier(rawValue: 2), dependent: UnitIdentifier(rawValue: 5))

        #expect(map.edgeCount == 2)

        map.removeDependent(UnitIdentifier(rawValue: 5))

        #expect(!map.dependents(of: UnitIdentifier(rawValue: 1)).contains(UnitIdentifier(rawValue: 5)))
        #expect(!map.dependents(of: UnitIdentifier(rawValue: 2)).contains(UnitIdentifier(rawValue: 5)))
    }

    @Test("removeKey removes entry entirely")
    func removeKey() {
        var map = GroundingDependencyMap()
        map.addEdge(input: UnitIdentifier(rawValue: 1), dependent: UnitIdentifier(rawValue: 2))

        #expect(map.hasDependents(UnitIdentifier(rawValue: 1)))

        map.removeKey(UnitIdentifier(rawValue: 1))

        #expect(!map.hasDependents(UnitIdentifier(rawValue: 1)))
    }

    @Test("clear resets all state")
    func clearResetsAll() {
        var map = GroundingDependencyMap()
        map.addEdge(input: UnitIdentifier(rawValue: 1), dependent: UnitIdentifier(rawValue: 2))
        map.addEdge(input: UnitIdentifier(rawValue: 3), dependent: UnitIdentifier(rawValue: 4))

        map.clear()

        #expect(map.edgeCount == 0)
        #expect(map.dependents(of: UnitIdentifier(rawValue: 1)).isEmpty)
    }

    @Test("estimatedMemoryBytes is positive with data")
    func estimatedMemoryBytes() {
        var map = GroundingDependencyMap()
        map.addEdge(input: UnitIdentifier(rawValue: 1), dependent: UnitIdentifier(rawValue: 2))

        #expect(map.estimatedMemoryBytes > 0)
    }
}

// MARK: — StorageError Tests

@Suite("StorageError")
struct StorageErrorTests {

    @Test("All error cases are constructible")
    func errorCasesConstructible() {
        let errors: [StorageError] = [
            .snapshotWriteFailed(detail: "disk full"),
            .snapshotCorrupted(path: "/tmp/snapshot.json"),
            .schemaEvolution(rejectedCount: 1, totalCount: 10),
            .gcSafetyViolation(unitId: UnitIdentifier(rawValue: 1)),
            .groundingMapInconsistency(detail: "orphan edge"),
            .diskSpaceExhausted,
            .invalidState(current: .created, attempted: "captureSnapshot"),
            .notOperational,
        ]
        #expect(errors.count == 8)
    }
}
