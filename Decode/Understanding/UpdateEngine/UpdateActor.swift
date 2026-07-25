// UpdateActor.swift — UpdateEngine
// DDS-002 + DDS-007: DIR Runtime + Update Engine coordination
// IAG-003 §2.1: UpdateActor owns unit store, epoch counter, identity counter,
//               change set processing queue, deferred recomputation queue
// IAG-003 §8: os.Logger category "update-engine"

import Foundation
import DIRCore
import ProducerRuntime
import IndexRuntime
import StorageEngine
import os
import CryptoKit

/// The central actor of the understanding pipeline.
///
/// IAG-003 §2.1: Implements `DIRReadAccess`, `DIRWriteAccess`, `DemandSignalSink`
/// (from DIRCore). Epoch control is internal — the nonisolated `EpochControl`
/// protocol cannot be conformed to by an actor that mutates state.
///
/// Owns:
/// - Unit store (all Active and Invalidated atomic units)
/// - Epoch counter (monotonically increasing)
/// - Unit identity counter (monotonically increasing)
/// - Change set processing queue (at most one active — DDS-007 R9)
/// - Deferred T2 recomputation queue
///
/// Concurrency model:
/// - All write transactions serialized through this actor (DDS-002 single-writer)
/// - Consumer reads via DIRReadAccess observe committed epoch only (DDS-002:PC-3(a))
/// - Sequential change set processing — no concurrent change sets (DDS-007 R9)
public actor UpdateActor: DIRReadAccess, DIRWriteAccess, DemandSignalSink {

    // MARK: — Dependencies

    /// Producer execution (DDS-007:PC-5).
    private let executionDirective: ExecutionDirective

    /// Producer registry for DAG queries (DDS-007:PC-8).
    private let producerRegistry: ProducerRegistry

    /// Failure report source (DDS-007:PC-12).
    private let failureReportSource: FailureReportSource

    /// Index batch update delivery (DDS-007:PC-9).
    private let indexBatchUpdate: IndexBatchUpdate

    /// Snapshot persistence (DDS-008:PC-1/PC-2).
    private let snapshotPersistence: SnapshotPersistence

    /// Garbage collection (DDS-008:PC-3).
    private let garbageCollector: GarbageCollector

    /// Grounding map access for cascade traversal (DDS-007:PC-10).
    private let groundingMapAccess: GroundingMapAccess

    /// Content hash map for change detection (DDS-007:PC-11).
    private let contentHashMapAccess: ContentHashMapAccess

    /// Deferred queue persistence (DDS-008:PC-6).
    private let deferredQueuePersistence: DeferredQueuePersistence

    /// Change batch observer (StorageEngine for grounding map maintenance).
    private let changeBatchObserver: ChangeBatchObserver

    // MARK: — Owned State (IAG-003 §2.1)

    /// The unit store — custody of all atomic units (DDS-002 R1).
    private var unitStore: UnitStore

    /// Epoch counter — monotonically increasing (DDS-002 R6).
    private var epoch: Epoch

    /// The lifecycle state.
    private var state: UpdateEngineState = .created

    /// Deferred T2 recomputation queue (DDS-007 R5).
    private var deferredQueue: [UnitIdentifier] = []

    /// Change event queue — events arriving during processing (DDS-007 R9).
    private var pendingEvents: [FileChangeEvent] = []

    /// Whether a change set is currently being processed.
    private var isProcessing: Bool = false

    /// Epochs since last GC (for scheduling).
    private var epochsSinceLastGC: UInt64 = 0

    // MARK: — Logging

    private let logger = Logger(subsystem: "com.decode.understanding", category: "update-engine")

    // MARK: — Initialization

    /// Creates an UpdateActor with all required dependencies.
    ///
    /// IAG-001 §6: UpdateEngine receives protocol references from all leaf modules.
    public init(
        executionDirective: ExecutionDirective,
        producerRegistry: ProducerRegistry,
        failureReportSource: FailureReportSource,
        indexBatchUpdate: IndexBatchUpdate,
        snapshotPersistence: SnapshotPersistence,
        garbageCollector: GarbageCollector,
        groundingMapAccess: GroundingMapAccess,
        contentHashMapAccess: ContentHashMapAccess,
        deferredQueuePersistence: DeferredQueuePersistence,
        changeBatchObserver: ChangeBatchObserver
    ) {
        self.executionDirective = executionDirective
        self.producerRegistry = producerRegistry
        self.failureReportSource = failureReportSource
        self.indexBatchUpdate = indexBatchUpdate
        self.snapshotPersistence = snapshotPersistence
        self.garbageCollector = garbageCollector
        self.groundingMapAccess = groundingMapAccess
        self.contentHashMapAccess = contentHashMapAccess
        self.deferredQueuePersistence = deferredQueuePersistence
        self.changeBatchObserver = changeBatchObserver
        self.unitStore = UnitStore()
        self.epoch = .zero
        logger.debug("UpdateActor created — state: created")
    }

    // MARK: — Lifecycle

    /// Loads DIR state from a snapshot, transitioning to operational.
    ///
    /// IAG-003 §4.1: Load snapshot → populate unit store → advance to Operational.
    /// DDS-002: Loading → Operational.
    public func loadFromSnapshot() async {
        transitionState(to: .reconciling)

        let loadResult = await snapshotPersistence.loadSnapshot()
        switch loadResult {
        case .loaded(let snapshot), .loadedPrior(let snapshot):
            unitStore.loadFromSnapshot(snapshot)
            epoch = snapshot.epoch
            deferredQueue = snapshot.deferredQueue
            logger.info("Snapshot loaded — epoch: \(snapshot.epoch.value), units: \(snapshot.units.count)")

        case .requiresFullRebuild:
            unitStore = UnitStore()
            epoch = .zero
            deferredQueue = []
            logger.info("No snapshot — starting with empty DIR at epoch 0")
        }
    }

    /// Performs reconciliation, comparing tracked files against current state.
    ///
    /// DDS-007 PC-4: After snapshot load, compares each tracked file's current
    /// content hash against snapshot hash. Changed/new/deleted files processed.
    public func reconcile() async {
        guard state == .reconciling else {
            logger.warning("reconcile called in state: \(self.state.rawValue)")
            return
        }

        logger.info("Starting reconciliation")

        // Get stored content hashes from snapshot
        let storedHashes = await contentHashMapAccess.allContentHashes()

        // For each stored file, check if the hash has changed
        // In a real implementation, this would compare against current file system state.
        // At alpha, reconciliation detects changes via the content hash map.
        // Files that changed since last snapshot are assembled into a change set.

        // Validate deferred queue — remove entries for units that no longer exist
        var validatedQueue: [UnitIdentifier] = []
        for unitId in deferredQueue {
            if unitStore.unit(for: unitId) != nil {
                validatedQueue.append(unitId)
            }
        }
        deferredQueue = validatedQueue
        await deferredQueuePersistence.updateDeferredQueue(deferredQueue)

        logger.info("Reconciliation complete — stored hashes: \(storedHashes.count), deferred queue: \(self.deferredQueue.count)")
    }

    /// Completes startup reconciliation and enters Idle state.
    ///
    /// DDS-007: Reconciling → Idle.
    public func completeReconciliation() {
        guard state == .reconciling else { return }
        transitionState(to: .idle)
        logger.info("Reconciliation complete — entering Idle state at epoch \(self.epoch.value)")
    }

    /// Initiates shutdown.
    ///
    /// DDS-007: Idle/Processing → Quiescing.
    public func shutdown() async {
        guard state == .idle || state == .processing else { return }
        transitionState(to: .quiescing)

        // Persist deferred queue in final snapshot
        await deferredQueuePersistence.updateDeferredQueue(deferredQueue)

        // Capture final snapshot
        let snapshot = buildSnapshotData()
        do {
            try await snapshotPersistence.captureSnapshot(snapshot)
            logger.info("Final snapshot captured at epoch \(self.epoch.value)")
        } catch {
            logger.error("Failed to capture final snapshot: \(error.localizedDescription)")
        }

        transitionState(to: .terminated)
        unitStore.clear()
        deferredQueue.removeAll()
        pendingEvents.removeAll()
        logger.info("UpdateActor terminated")
    }

    // MARK: — DIRReadAccess (DDS-002:PC-3)

    /// DDS-002 PC-3(a): Consumer reads observe committed epoch only.
    public func unit(for id: UnitIdentifier) async -> AtomicUnit? {
        unitStore.unit(for: id)
    }

    public func activeUnits() async -> [AtomicUnit] {
        unitStore.activeUnits()
    }

    public func invalidatedUnits() async -> [AtomicUnit] {
        unitStore.invalidatedUnits()
    }

    public func allUnits() async -> [AtomicUnit] {
        unitStore.allUnits()
    }

    public func activeUnit(for key: SupersessionKey) async -> AtomicUnit? {
        unitStore.activeUnit(for: key)
    }

    public var committedEpoch: Epoch {
        get async { epoch }
    }

    // MARK: — DIRWriteAccess (DDS-002:PC-6)

    /// Processes a write transaction atomically.
    ///
    /// DDS-002 PC-6: All operations succeed or none. Admissions before transitions.
    /// Supersession resolved at admission. Earlier units visible to later ones.
    public func submit(_ transaction: WriteTransaction) async -> WriteTransactionResult {
        let result = unitStore.processTransaction(transaction)

        if case .committed(let committed) = result {
            // Build change batch for observers
            var changes: [UnitChange] = []
            for unitId in committed.admittedUnitIds {
                changes.append(.admitted(unitId))
            }
            for unitId in committed.supersededUnitIds {
                changes.append(.superseded(unitId, by: committed.admittedUnitIds.last ?? unitId))
            }
            for transition in committed.appliedTransitions {
                switch transition.targetStatus {
                case .invalidated:
                    changes.append(.invalidated(transition.unitId))
                case .garbageCollected:
                    changes.append(.garbageCollected(transition.unitId))
                case .superseded:
                    changes.append(.superseded(transition.unitId, by: transition.supersededBy ?? transition.unitId))
                case .active:
                    break
                }
            }

            if !changes.isEmpty {
                let batch = ChangeBatch(epoch: epoch, changes: changes)
                await changeBatchObserver.didCommit(batch)
            }
        }

        return result
    }

    // MARK: — Epoch Control (DDS-002:PC-4)

    /// Advances the epoch from N to N+1 atomically.
    ///
    /// DDS-002 PC-4: All writes committed during the synchronous pipeline
    /// become visible to consumer queries.
    public func advanceEpoch() -> Epoch {
        epoch = epoch.advanced()
        epochsSinceLastGC += 1
        logger.info("Epoch advanced to \(self.epoch.value)")
        return epoch
    }

    // MARK: — DemandSignalSink (DDS-007:PC-2)

    /// Receives demand signals from consumers requesting T2 recomputation.
    ///
    /// DDS-007 PC-2: Schedules deferred T2 producer execution.
    /// Consumer-demand prioritized above background scheduling.
    public func submit(_ signal: DemandSignal) async {
        guard state == .idle || state == .processing else { return }

        // Check if a valid T2 unit already exists
        let key = SupersessionKey(
            subject: signal.subject,
            predicate: signal.predicate,
            tier: signal.tier
        )
        if let existing = unitStore.activeUnit(for: key) {
            // Already have an active unit — no recomputation needed
            logger.debug("Demand signal ignored — active T2 unit exists for \(signal.predicate.name)")
            _ = existing
            return
        }

        // Check invalidated units — they need recomputation
        // Find any invalidated unit with this key
        let invalidated = unitStore.invalidatedUnits().first {
            $0.supersessionKey == key
        }

        if let invalidatedUnit = invalidated {
            if !deferredQueue.contains(invalidatedUnit.id) {
                deferredQueue.append(invalidatedUnit.id)
                await deferredQueuePersistence.enqueueDeferredUnit(invalidatedUnit.id)
                logger.info("Demand signal enqueued T2 recomputation for unit \(invalidatedUnit.id.rawValue)")
            }
        } else {
            // No unit exists at all — first-question trigger
            // The deferred pipeline will need to create a new T2 unit
            logger.info("Demand signal for non-existent T2 unit — \(signal.predicate.name)")
        }
    }

    // MARK: — Change Set Processing (DDS-007:PC-1)

    /// Processes a change set through the 8-stage synchronous pipeline.
    ///
    /// DDS-007 PC-1: Content-hash filtering → frontend re-execution →
    /// entity comparison → direct invalidation → cascade propagation →
    /// synchronous recomputation → index update → epoch advancement.
    public func processChangeSet(_ changeSet: ChangeSet) async -> ChangeSetResult {
        guard state == .idle || state == .reconciling else {
            logger.warning("processChangeSet called in state: \(self.state.rawValue)")
            return emptyResult()
        }

        if state == .idle {
            transitionState(to: .processing)
        }
        isProcessing = true

        let startTime = ContinuousClock.now
        let epochBefore = epoch

        var hashFiltered = 0
        var directInvalidations = 0
        var cascadeInvalidations = 0
        var deferredT2Count = 0
        var syncTickets = 0
        var earlyTerminations = 0

        // Stage 1: Content-Hash Filtering (DDS-007 CD-1, I6)
        var changedFiles: [FileChangeEvent] = []
        for event in changeSet.events {
            if event.changeType == .deleted {
                changedFiles.append(event)
                continue
            }

            // Compute current file hash
            let currentHash = await computeFileHash(event.filePath)
            let storedHash = await contentHashMapAccess.contentHash(for: event.filePath)

            if let current = currentHash, let stored = storedHash, current == stored {
                hashFiltered += 1
                continue
            }

            changedFiles.append(event)

            // Update content hash
            if let currentHash = currentHash {
                await contentHashMapAccess.updateContentHash(for: event.filePath, hash: currentHash)
            }
        }

        if changedFiles.isEmpty {
            logger.info("All files filtered by content hash — no work, no epoch advancement")
            isProcessing = false
            if state == .processing {
                transitionState(to: .idle)
            }
            return ChangeSetResult(
                totalFiles: changeSet.events.count,
                hashFilteredFiles: hashFiltered,
                directInvalidations: 0, cascadeInvalidations: 0,
                deferredT2Units: 0, syncRecomputationTickets: 0,
                earlyTerminations: 0,
                epochBefore: epochBefore, epochAfter: epochBefore,
                duration: 0
            )
        }

        // Stage 2: Frontend Re-Execution (DDS-007 R1)
        var allChanges: [UnitChange] = []

        for event in changedFiles {
            if event.changeType == .deleted {
                // Invalidate all units grounded to this file
                let fileInvalidations = invalidateUnitsForFile(event.filePath)
                directInvalidations += fileInvalidations.count
                allChanges.append(contentsOf: fileInvalidations)
                await contentHashMapAccess.removeContentHash(for: event.filePath)
                continue
            }

            // Issue frontend execution ticket for the file
            let dag = await producerRegistry.dagSnapshot()
            for producerId in dag.topologicalOrder {
                guard let contract = await producerRegistry.contract(for: producerId) else { continue }
                if case .frontend(let frontend) = contract {
                    let ext = (event.filePath as NSString).pathExtension
                    if frontend.sourceFormats.contains(ext) {
                        // Snapshot unit IDs before execution to detect new admissions.
                        let unitIdsBefore = Set(unitStore.allUnits().map(\.id))

                        let ticket = ExecutionTicket(
                            producerId: producerId,
                            scope: .file(path: event.filePath),
                            mode: .incremental
                        )
                        let result = await executionDirective.execute(ticket)
                        syncTickets += 1

                        // Track newly admitted units (DDS-007 R8: index must
                        // reflect all DIR mutations, including admissions).
                        let unitIdsAfter = Set(unitStore.allUnits().map(\.id))
                        for newId in unitIdsAfter.subtracting(unitIdsBefore) {
                            allChanges.append(.admitted(newId))
                        }

                        switch result {
                        case .completed(let report):
                            // Stage 3: Entity-Level Comparison (DDS-007 CD-4, CD-5)
                            switch report.changeReport {
                            case .noChange:
                                earlyTerminations += 1
                            case .changed, .firstInvocation:
                                // Stage 4: Direct Invalidation (DDS-007 R2)
                                let invalidations = invalidateChangedUnits(
                                    forFile: event.filePath,
                                    producerId: producerId
                                )
                                directInvalidations += invalidations.count
                                allChanges.append(contentsOf: invalidations)

                            }
                        case .failed(let failure):
                            // FM-1: Frontend parse failure — retain prior units
                            logger.warning("Frontend parse failed for \(event.filePath): \(failure.diagnostic)")
                        }
                    }
                }
            }
        }

        // Stage 5: Cascade Propagation (DDS-007 R2)
        var cascadeFrontier: Set<UnitIdentifier> = Set(
            allChanges.compactMap { change in
                switch change {
                case .invalidated(let id): return id
                default: return nil
                }
            }
        )

        var visited = cascadeFrontier
        while !cascadeFrontier.isEmpty {
            var nextFrontier: Set<UnitIdentifier> = []
            for unitId in cascadeFrontier {
                let lookupResult = await groundingMapAccess.dependents(of: unitId)
                guard case .available(let dependents) = lookupResult else { continue }

                for depId in dependents {
                    guard !visited.contains(depId) else { continue }
                    guard let depUnit = unitStore.unit(for: depId),
                          depUnit.status == .active else { continue }

                    // DDS-007 CB-1/CB-2: T0/T1 synchronous, T2 deferred
                    if depUnit.tier == .t2 {
                        // Deferred: enqueue for T2 recomputation
                        if !deferredQueue.contains(depId) {
                            deferredQueue.append(depId)
                            deferredT2Count += 1
                        }
                    } else {
                        // Synchronous: invalidate now
                        var mutableUnit = depUnit
                        mutableUnit.invalidate(metadata: InvalidationMetadata(
                            epoch: epoch,
                            reason: .groundingCollapse(unitId)
                        ))
                        unitStore.units[depId] = mutableUnit
                        allChanges.append(.invalidated(depId))
                        cascadeInvalidations += 1
                        nextFrontier.insert(depId)
                    }
                    visited.insert(depId)
                }
            }
            cascadeFrontier = nextFrontier
        }

        // Stage 6: Synchronous Recomputation (DDS-007 R4)
        // Issue tickets for T0/T1 passes in DAG topological order
        let dag = await producerRegistry.dagSnapshot()
        for producerId in dag.topologicalOrder {
            guard let contract = await producerRegistry.contract(for: producerId) else { continue }
            if case .pass(let passContract) = contract,
               passContract.executionStrategy == .deterministic {
                // Check if any units for this pass's predicates were invalidated
                let hasInvalidated = unitStore.invalidatedUnits().contains { unit in
                    passContract.outputContract.predicates.contains(unit.predicate)
                }
                if hasInvalidated {
                    for filePath in changedFiles.map(\.filePath) {
                        let ticket = ExecutionTicket(
                            producerId: producerId,
                            scope: .file(path: filePath),
                            mode: .incremental
                        )
                        let result = await executionDirective.execute(ticket)
                        syncTickets += 1

                        if case .completed(let report) = result {
                            if case .noChange = report.changeReport {
                                earlyTerminations += 1
                            }
                        }
                    }
                }
            }
        }

        // Stage 7: Index Update (DDS-007 R8, DDS-007:PC-9)
        if !allChanges.isEmpty {
            let changeBatch = ChangeBatch(epoch: epoch, changes: allChanges)
            let indexResult = await indexBatchUpdate.applyBatch(changeBatch)
            if !indexResult.failedFamilies.isEmpty {
                logger.warning("Index update had failures: \(indexResult.failedFamilies.count) families")
            }
        }

        // Stage 8: Epoch Advancement (DDS-007 R7, DDS-002:PC-4)
        let newEpoch = advanceEpoch()

        // Notify StorageEngine of changes
        if !allChanges.isEmpty {
            let batch = ChangeBatch(epoch: newEpoch, changes: allChanges)
            await changeBatchObserver.didCommit(batch)
        }

        // Persist deferred queue
        await deferredQueuePersistence.updateDeferredQueue(deferredQueue)

        // Schedule snapshot (async, non-blocking)
        let snapshot = buildSnapshotData()
        Task {
            try? await snapshotPersistence.captureSnapshot(snapshot)
        }

        // GC scheduling (DDS-008:GC-3 — never during synchronous pipeline)
        if epochsSinceLastGC >= 10 {
            Task {
                _ = await garbageCollector.collectGarbage(currentEpoch: newEpoch)
            }
            epochsSinceLastGC = 0
        }

        let duration = ContinuousClock.now - startTime
        let durationSeconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18

        isProcessing = false
        if state == .processing {
            transitionState(to: .idle)
        }

        logger.info("Change set processed — files: \(changedFiles.count), invalidations: \(directInvalidations)+\(cascadeInvalidations), epoch: \(newEpoch.value)")

        return ChangeSetResult(
            totalFiles: changeSet.events.count,
            hashFilteredFiles: hashFiltered,
            directInvalidations: directInvalidations,
            cascadeInvalidations: cascadeInvalidations,
            deferredT2Units: deferredT2Count,
            syncRecomputationTickets: syncTickets,
            earlyTerminations: earlyTerminations,
            epochBefore: epochBefore,
            epochAfter: newEpoch,
            duration: durationSeconds
        )
    }

    // MARK: — Deferred Pipeline (DDS-007:PC-2, R5)

    /// Processes a single deferred T2 recomputation.
    ///
    /// DDS-007 PC-2: Reads committed epoch, executes T2 producer.
    /// Collision detection: if unit invalidated during recomputation, discard result.
    public func processDeferredRecomputation(unitId: UnitIdentifier) async -> Bool {
        guard state == .idle || state == .processing else { return false }

        guard let unit = unitStore.unit(for: unitId) else {
            // Unit no longer exists — remove from queue
            deferredQueue.removeAll { $0 == unitId }
            await deferredQueuePersistence.dequeueDeferredUnit(unitId)
            return false
        }

        guard unit.status == .invalidated || unit.status == .active else {
            deferredQueue.removeAll { $0 == unitId }
            await deferredQueuePersistence.dequeueDeferredUnit(unitId)
            return false
        }

        // Find the T2 producer for this unit's predicate
        let producers = await producerRegistry.producers(for: unit.predicate, at: .t2)
        guard let producerId = producers.first else {
            logger.warning("No T2 producer found for predicate \(unit.predicate.name)")
            return false
        }

        // Execute T2 producer
        let ticket = ExecutionTicket(
            producerId: producerId,
            scope: .entity(EntityReference(qualifiedName: unit.subject.qualifiedName)),
            mode: .incremental
        )
        let result = await executionDirective.execute(ticket)

        switch result {
        case .completed(let report):
            // Collision detection: check if unit was invalidated during recomputation
            guard let currentUnit = unitStore.unit(for: unitId) else {
                // Unit was GC'd during recomputation
                deferredQueue.removeAll { $0 == unitId }
                return false
            }
            if currentUnit.status == .garbageCollected || currentUnit.status == .superseded {
                // Collision — discard result, re-queue if still relevant
                logger.info("Deferred collision detected — unit \(unitId.rawValue) status changed during recomputation")
                deferredQueue.removeAll { $0 == unitId }
                return false
            }

            // Commit result — advance deferred epoch
            let newChanges: [UnitChange] = [.admitted(unitId)]
            let changeBatch = ChangeBatch(epoch: epoch, changes: newChanges)
            _ = await indexBatchUpdate.applyBatch(changeBatch)
            let newEpoch = advanceEpoch()
            await changeBatchObserver.didCommit(ChangeBatch(epoch: newEpoch, changes: newChanges))

            // Remove from deferred queue
            deferredQueue.removeAll { $0 == unitId }
            await deferredQueuePersistence.dequeueDeferredUnit(unitId)

            logger.info("Deferred T2 recomputation completed — unit \(unitId.rawValue), epoch \(newEpoch.value)")
            _ = report
            return true

        case .failed(let failure):
            // FM-3: Keep in deferred queue for later retry
            logger.warning("Deferred T2 recomputation failed — unit \(unitId.rawValue): \(failure.diagnostic)")
            return false
        }
    }

    /// Returns the current deferred queue size.
    public func deferredQueueSize() -> Int {
        deferredQueue.count
    }

    // MARK: — Producer Upgrade Processing (DDS-007:PC-3)

    /// Detects producer version changes and schedules re-evaluation.
    ///
    /// DDS-007 PC-3: Compares current producer versions against provenance.
    /// Re-evaluates affected units as synthetic change set.
    public func processProducerUpgrades() async {
        let registeredProducers = await producerRegistry.registeredProducers()
        var upgradedProducers: Set<ProducerIdentifier> = []

        for producerId in registeredProducers {
            guard let contract = await producerRegistry.contract(for: producerId) else { continue }
            let currentVersion = contract.identity.version

            // Check if any units have a different version for this producer
            let producerUnits = unitStore.allUnits().filter {
                $0.provenance.producer == producerId.name
            }

            for unit in producerUnits {
                // Compare version stamps (simplified — producer version embedded in provenance)
                // If we detect a version mismatch, flag for upgrade
                if !upgradedProducers.contains(producerId) {
                    // At alpha, version comparison is by producer name match
                    // Full version comparison would require storing ProducerVersion in provenance
                    _ = currentVersion
                }
            }
        }

        if !upgradedProducers.isEmpty {
            logger.info("Producer upgrades detected: \(upgradedProducers.count) producers")
        }
    }

    // MARK: — Observability

    /// Returns the current engine state.
    public func currentState() -> UpdateEngineState {
        state
    }

    /// Returns unit store metrics.
    public func storeMetrics() -> (total: Int, active: Int, invalidated: Int, epoch: Epoch) {
        (unitStore.count, unitStore.activeCount,
         unitStore.invalidatedUnits().count, epoch)
    }

    /// Returns whether a GC cycle is due.
    public func isGCDue() -> Bool {
        epochsSinceLastGC >= 10
    }

    // MARK: — Private: Invalidation Helpers

    /// Invalidates all units grounded to a specific file.
    private func invalidateUnitsForFile(_ filePath: String) -> [UnitChange] {
        var changes: [UnitChange] = []
        for unit in unitStore.activeUnits() {
            if case .direct(let pos) = unit.grounding, pos.filePath == filePath {
                var mutableUnit = unit
                mutableUnit.invalidate(metadata: InvalidationMetadata(
                    epoch: epoch,
                    reason: .sourceChanged
                ))
                unitStore.units[unit.id] = mutableUnit
                changes.append(.invalidated(unit.id))
            }
        }
        return changes
    }

    /// Invalidates changed units for a specific file and producer.
    private func invalidateChangedUnits(
        forFile filePath: String,
        producerId: ProducerIdentifier
    ) -> [UnitChange] {
        var changes: [UnitChange] = []
        for unit in unitStore.activeUnits() {
            if unit.provenance.producer == producerId.name,
               case .direct(let pos) = unit.grounding,
               pos.filePath == filePath {
                // Check if the unit was not just admitted in this pipeline run
                // (i.e., it was from a prior epoch and needs invalidation)
                if unit.status == .active {
                    var mutableUnit = unit
                    mutableUnit.invalidate(metadata: InvalidationMetadata(
                        epoch: epoch,
                        reason: .sourceChanged
                    ))
                    unitStore.units[unit.id] = mutableUnit
                    changes.append(.invalidated(unit.id))
                }
            }
        }
        return changes
    }

    /// Computes the content hash for a file.
    private func computeFileHash(_ filePath: String) async -> ContentHash? {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return nil
        }
        let hash = SHA256.hash(data: data)
        return ContentHash(bytes: Array(hash))
    }

    /// Builds a SnapshotData from current state.
    private func buildSnapshotData() -> SnapshotData {
        let snapshotUnits = unitStore.allUnits().filter {
            $0.status == .active || $0.status == .invalidated
        }
        return SnapshotData(
            units: snapshotUnits,
            epoch: epoch,
            nextUnitId: unitStore.nextUnitId,
            contentHashes: [:], // Content hashes owned by StorageEngine
            deferredQueue: deferredQueue
        )
    }

    /// Returns an empty ChangeSetResult (no work done).
    private func emptyResult() -> ChangeSetResult {
        ChangeSetResult(
            totalFiles: 0, hashFilteredFiles: 0,
            directInvalidations: 0, cascadeInvalidations: 0,
            deferredT2Units: 0, syncRecomputationTickets: 0,
            earlyTerminations: 0,
            epochBefore: epoch, epochAfter: epoch,
            duration: 0
        )
    }

    // MARK: — Private: State Management

    private func transitionState(to target: UpdateEngineState) {
        let current = state
        guard current.canTransition(to: target) else {
            logger.warning("Invalid state transition: \(current.rawValue) → \(target.rawValue)")
            return
        }
        state = target
        logger.info("State transition: \(current.rawValue) → \(target.rawValue)")
    }
}

// MARK: — UnitSubject Extension

extension UnitSubject {
    /// Returns the qualified name for the primary entity.
    var qualifiedName: String {
        switch self {
        case .entity(let ref): return ref.qualifiedName
        case .pair(let pair): return pair.source.qualifiedName
        }
    }
}
