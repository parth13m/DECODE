// StorageActor.swift — StorageEngine
// DDS-008: Storage Engine — snapshot persistence, GC, grounding map, content hashes
// IAG-003 §2.5: StorageActor owns grounding dependency map, content hash map,
//               in-progress GC state, snapshot write state
// IAG-003 §8: os.Logger category "storage"

import Foundation
import DIRCore
import os
import CryptoKit

/// The core actor of the Storage Engine.
///
/// IAG-003 §2.5: Owns the grounding dependency map, content hash map,
/// in-progress GC state, and snapshot write state. All cross-module protocol
/// methods serialize through this actor.
///
/// Concurrency model:
/// - Snapshot capture reads a committed epoch — does not interfere with pipeline.
/// - GC runs between synchronous pipeline executions.
/// - Map maintenance is driven by change batch notifications, applied sequentially.
public actor StorageActor: SnapshotPersistence, GarbageCollector, GroundingMapAccess,
                            ContentHashMapAccess, DeferredQueuePersistence,
                            ChangeBatchObserver {

    // MARK: — Dependencies

    /// DIR read access (injected as protocol from UpdateEngine via DIRCore).
    private let dirRead: DIRReadAccess

    /// DIR write access (injected as protocol from UpdateEngine via DIRCore).
    private let dirWrite: DIRWriteAccess

    // MARK: — Configuration

    /// The directory for snapshot files.
    private let snapshotDirectory: URL

    /// GC retention policy.
    private let retentionPolicy: GCRetentionPolicy

    // MARK: — Owned State

    /// Grounding dependency map (DDS-008 R3).
    private var groundingMap: GroundingDependencyMap = GroundingDependencyMap()

    /// Whether the grounding map has been constructed.
    private var mapAvailable: Bool = false

    /// Per-file content hash map (DDS-008 R8).
    private var contentHashes: [String: ContentHash] = [:]

    /// Deferred T2 recomputation queue (DDS-008 R6).
    private var deferredRecomputationQueue: [UnitIdentifier] = []

    /// The current runtime state.
    private var state: StorageEngineState = .created

    /// Epoch of the last captured snapshot.
    private var lastCapturedEpoch: Epoch?

    /// Epoch count since last GC (for scheduling).
    private var epochsSinceLastGC: UInt64 = 0

    // MARK: — Logging

    private let logger = Logger(subsystem: "com.decode.understanding", category: "storage")

    // MARK: — Initialization

    /// Creates a StorageActor with DIR access and configuration.
    ///
    /// IAG-001 §6: StorageEngine receives DIRReadAccess and DIRWriteAccess.
    /// DDS-008: No persistent state beyond snapshot files.
    public init(
        dirRead: DIRReadAccess,
        dirWrite: DIRWriteAccess,
        snapshotDirectory: URL,
        retentionPolicy: GCRetentionPolicy = .default
    ) {
        self.dirRead = dirRead
        self.dirWrite = dirWrite
        self.snapshotDirectory = snapshotDirectory
        self.retentionPolicy = retentionPolicy
        logger.debug("StorageActor created — state: created")
    }

    // MARK: — Lifecycle

    /// Begins the loading phase — loads snapshot and populates DIR.
    ///
    /// DDS-008 Lifecycle: Created → Loading → MapBuilding.
    public func beginLoading() {
        transitionState(to: .loading)
    }

    /// Completes snapshot loading, begins grounding map construction.
    ///
    /// DDS-008 Lifecycle: Loading → MapBuilding.
    /// Called after the DIR has been populated from the snapshot.
    public func completeLoading(
        contentHashes: [String: ContentHash],
        deferredQueue: [UnitIdentifier]
    ) {
        self.contentHashes = contentHashes
        self.deferredRecomputationQueue = deferredQueue
        transitionState(to: .mapBuilding)
        logger.info("Snapshot loading complete — content hashes: \(contentHashes.count), deferred queue: \(deferredQueue.count)")
    }

    /// Constructs the grounding dependency map from the DIR.
    ///
    /// DDS-008 R3: Scans all units, extracts provenance.inputs, builds reverse lookup.
    /// O(N) where N is total unit count.
    public func constructGroundingMap() async {
        guard state == .mapBuilding else {
            logger.warning("constructGroundingMap called in state: \(self.state.rawValue)")
            return
        }

        logger.info("Constructing grounding dependency map")
        groundingMap.clear()

        let allUnits = await dirRead.allUnits()
        for unit in allUnits {
            let inputs = provenanceInputs(from: unit.grounding, provenance: unit.provenance)
            groundingMap.addUnit(unit.id, provenanceInputs: inputs)
        }

        let epoch = await dirRead.committedEpoch
        groundingMap.lastMaintainedEpoch = epoch
        mapAvailable = true

        transitionState(to: .operational)
        logger.info("Grounding map constructed — \(self.groundingMap.edgeCount) edges, state: operational")
    }

    /// Initiates quiescence of the Storage Engine.
    ///
    /// DDS-008 Lifecycle: Operational → Quiescing.
    public func shutdown() {
        guard state == .operational else { return }
        transitionState(to: .quiescing)
        logger.info("StorageActor quiescing")
    }

    /// Completes termination.
    ///
    /// DDS-008 Lifecycle: Quiescing → Terminated.
    public func terminate() {
        guard state == .quiescing else { return }
        transitionState(to: .terminated)
        groundingMap.clear()
        contentHashes.removeAll()
        deferredRecomputationQueue.removeAll()
        mapAvailable = false
        logger.info("StorageActor terminated — all resources deallocated")
    }

    // MARK: — SnapshotPersistence (PC-1, PC-2)

    public func captureSnapshot(_ snapshot: SnapshotData) async throws {
        guard state == .operational || state == .mapBuilding || state == .quiescing else {
            throw StorageError.invalidState(current: state, attempted: "captureSnapshot")
        }

        logger.info("Capturing snapshot at epoch \(snapshot.epoch.value)")

        // Serialize (sortedKeys for deterministic checksum)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys

        // Create snapshot without checksum first
        var snapshotWithChecksum = snapshot

        let dataWithoutChecksum = try encoder.encode(snapshot)
        let checksum = Data(SHA256.hash(data: dataWithoutChecksum))
        snapshotWithChecksum = SnapshotData(
            units: snapshot.units,
            epoch: snapshot.epoch,
            nextUnitId: snapshot.nextUnitId,
            contentHashes: snapshot.contentHashes,
            deferredQueue: snapshot.deferredQueue,
            checksum: checksum
        )

        let finalData = try encoder.encode(snapshotWithChecksum)

        // Atomic write: write to temp file, then rename
        let tempPath = snapshotDirectory.appendingPathComponent("snapshot.tmp")
        let canonicalPath = snapshotDirectory.appendingPathComponent("snapshot.json")
        let priorPath = snapshotDirectory.appendingPathComponent("snapshot.prior.json")

        // Ensure directory exists
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        // Write to temp
        try finalData.write(to: tempPath, options: .atomic)

        // Rotate: current → prior, temp → current (DAS-012 I5: at most 2 files)
        let fm = FileManager.default
        if fm.fileExists(atPath: canonicalPath.path) {
            // Remove old prior if it exists
            if fm.fileExists(atPath: priorPath.path) {
                try fm.removeItem(at: priorPath)
            }
            try fm.moveItem(at: canonicalPath, to: priorPath)
        }
        try fm.moveItem(at: tempPath, to: canonicalPath)

        lastCapturedEpoch = snapshot.epoch
        logger.info("Snapshot captured — epoch: \(snapshot.epoch.value), size: \(finalData.count) bytes")
    }

    public func loadSnapshot() async -> SnapshotLoadResult {
        let canonicalPath = snapshotDirectory.appendingPathComponent("snapshot.json")
        let priorPath = snapshotDirectory.appendingPathComponent("snapshot.prior.json")

        // Try canonical first
        if let snapshot = loadAndValidateSnapshot(at: canonicalPath) {
            logger.info("Snapshot loaded — epoch: \(snapshot.epoch.value), units: \(snapshot.units.count)")
            return .loaded(snapshot)
        }

        // Try prior (DDS-008 FM-2: fallback to prior snapshot)
        if let snapshot = loadAndValidateSnapshot(at: priorPath) {
            logger.warning("Primary snapshot corrupted — loaded prior snapshot at epoch: \(snapshot.epoch.value)")
            return .loadedPrior(snapshot)
        }

        // No valid snapshot (DDS-008 PC-2: first launch or full rebuild)
        logger.info("No valid snapshot found — full rebuild required")
        return .requiresFullRebuild
    }

    public func lastSnapshotEpoch() async -> Epoch? {
        lastCapturedEpoch
    }

    // MARK: — GarbageCollector (PC-3)

    public func collectGarbage(currentEpoch: Epoch) async -> GCCycleResult {
        guard state == .operational, mapAvailable else {
            return GCCycleResult(
                candidatesEvaluated: 0, candidatesCollected: 0,
                candidatesSkippedSafety: 0, candidatesSkippedRetention: 0,
                duration: 0
            )
        }

        let startTime = ContinuousClock.now

        logger.debug("GC cycle starting at epoch \(currentEpoch.value)")

        // Step 1: Enumerate candidates (DDS-008 PC-3)
        let allUnits = await dirRead.allUnits()
        var candidatesEvaluated = 0
        var collected = 0
        var skippedSafety = 0
        var skippedRetention = 0

        var gcDirectives: [StatusTransition] = []

        for unit in allUnits {
            guard unit.status == .superseded || unit.status == .invalidated else { continue }
            candidatesEvaluated += 1

            // Check retention policy
            guard isEligibleForCollection(unit, currentEpoch: currentEpoch) else {
                skippedRetention += 1
                continue
            }

            // Check GC safety (DAS-012 I7)
            if groundingMap.hasDependents(unit.id) {
                // Verify dependents are still active/invalidated
                let deps = groundingMap.dependents(of: unit.id)
                var hasActiveDep = false
                for depId in deps {
                    if let dep = await dirRead.unit(for: depId),
                       dep.status == .active || dep.status == .invalidated {
                        hasActiveDep = true
                        break
                    }
                }
                if hasActiveDep {
                    skippedSafety += 1
                    continue
                }
            }

            gcDirectives.append(.garbageCollect(unit.id))
        }

        // Step 3: Issue GC directives in batches (DDS-008 PC-3)
        if !gcDirectives.isEmpty {
            let transaction = WriteTransaction(admissions: [], transitions: gcDirectives)
            let result = await dirWrite.submit(transaction)
            if case .committed = result {
                collected = gcDirectives.count
                // Step 4: Update dependency map
                for directive in gcDirectives {
                    groundingMap.removeDependent(directive.unitId)
                    groundingMap.removeKey(directive.unitId)
                }
            }
        }

        let duration = ContinuousClock.now - startTime
        let durationSeconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18

        logger.info("GC cycle complete — evaluated: \(candidatesEvaluated), collected: \(collected), skipped(safety): \(skippedSafety), skipped(retention): \(skippedRetention)")

        epochsSinceLastGC = 0

        return GCCycleResult(
            candidatesEvaluated: candidatesEvaluated,
            candidatesCollected: collected,
            candidatesSkippedSafety: skippedSafety,
            candidatesSkippedRetention: skippedRetention,
            duration: durationSeconds
        )
    }

    // MARK: — GroundingMapAccess (PC-4)

    public func dependents(of unitId: UnitIdentifier) async -> GroundingLookupResult {
        guard mapAvailable else { return .notAvailable }
        return .available(groundingMap.dependents(of: unitId))
    }

    public func isMapAvailable() async -> Bool {
        mapAvailable
    }

    // MARK: — ContentHashMapAccess (PC-5)

    public func contentHash(for filePath: String) async -> ContentHash? {
        contentHashes[filePath]
    }

    public func allContentHashes() async -> [String: ContentHash] {
        contentHashes
    }

    public func updateContentHash(for filePath: String, hash: ContentHash) async {
        contentHashes[filePath] = hash
    }

    public func removeContentHash(for filePath: String) async {
        contentHashes.removeValue(forKey: filePath)
    }

    public func trackedFileCount() async -> Int {
        contentHashes.count
    }

    // MARK: — DeferredQueuePersistence (PC-6)

    public func deferredQueue() async -> [UnitIdentifier] {
        deferredRecomputationQueue
    }

    public func updateDeferredQueue(_ queue: [UnitIdentifier]) async {
        deferredRecomputationQueue = queue
    }

    public func enqueueDeferredUnit(_ unitId: UnitIdentifier) async {
        if !deferredRecomputationQueue.contains(unitId) {
            deferredRecomputationQueue.append(unitId)
        }
    }

    public func dequeueDeferredUnit(_ unitId: UnitIdentifier) async {
        deferredRecomputationQueue.removeAll { $0 == unitId }
    }

    // MARK: — ChangeBatchObserver (PC-11)

    public func didCommit(_ batch: ChangeBatch) async {
        guard state == .operational || state == .mapBuilding else { return }

        // Incrementally maintain grounding dependency map (DDS-008 R3)
        if mapAvailable {
            for change in batch.changes {
                switch change {
                case let .admitted(unitId):
                    // Look up the unit to get its provenance inputs
                    if let unit = await dirRead.unit(for: unitId) {
                        let inputs = provenanceInputs(from: unit.grounding, provenance: unit.provenance)
                        groundingMap.addUnit(unitId, provenanceInputs: inputs)
                    }
                case let .garbageCollected(unitId):
                    groundingMap.removeDependent(unitId)
                    groundingMap.removeKey(unitId)
                default:
                    break
                }
            }
            groundingMap.lastMaintainedEpoch = batch.epoch
        }

        epochsSinceLastGC += 1

        logger.debug("Change batch processed — epoch: \(batch.epoch.value), changes: \(batch.changes.count), map edges: \(self.groundingMap.edgeCount)")
    }

    // MARK: — Observability

    /// Returns the current state of the Storage Engine.
    public func currentState() -> StorageEngineState {
        state
    }

    /// Returns grounding map metrics.
    public func groundingMapMetrics() -> (edgeCount: Int, memoryBytes: Int, lastEpoch: Epoch?) {
        (groundingMap.edgeCount, groundingMap.estimatedMemoryBytes, groundingMap.lastMaintainedEpoch)
    }

    /// Returns whether a GC cycle is due.
    public func isGCDue() -> Bool {
        epochsSinceLastGC >= retentionPolicy.gcIntervalEpochs
    }

    // MARK: — Private: Snapshot Validation

    private func loadAndValidateSnapshot(at path: URL) -> SnapshotData? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let snapshot = try decoder.decode(SnapshotData.self, from: data)

            // Validate checksum (DAS-012 snapshot integrity)
            if let storedChecksum = snapshot.checksum {
                // Re-encode without checksum to verify
                let withoutChecksum = SnapshotData(
                    units: snapshot.units,
                    epoch: snapshot.epoch,
                    nextUnitId: snapshot.nextUnitId,
                    contentHashes: snapshot.contentHashes,
                    deferredQueue: snapshot.deferredQueue,
                    checksum: nil
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .sortedKeys
                let reencoded = try encoder.encode(withoutChecksum)
                let computedChecksum = Data(SHA256.hash(data: reencoded))

                if computedChecksum != storedChecksum {
                    logger.error("Snapshot checksum mismatch at \(path.lastPathComponent)")
                    return nil
                }
            }

            return snapshot
        } catch {
            logger.error("Failed to load snapshot at \(path.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: — Private: GC Eligibility

    /// Checks whether a unit is eligible for GC based on retention policy.
    ///
    /// DDS-008 PC-3, DAS-012 GC-R1 through GC-R4.
    private func isEligibleForCollection(_ unit: AtomicUnit, currentEpoch: Epoch) -> Bool {
        switch unit.status {
        case .superseded:
            let retention: UInt64
            switch unit.tier {
            case .t0, .t1:
                retention = retentionPolicy.t0t1RetentionEpochs
            case .t2:
                retention = retentionPolicy.t2RetentionEpochs
            }
            // Check if enough epochs have passed since supersession
            // The unit doesn't track its supersession epoch directly,
            // so we use the invalidation metadata epoch if available,
            // or consider it eligible based on current epoch vs unit's implied age.
            // For safety, we use a conservative check: the unit must have been
            // superseded for at least `retention` epochs.
            if let metadata = unit.invalidationMetadata {
                return currentEpoch.value >= metadata.epoch.value + retention
            }
            // If no metadata, use a conservative heuristic: check if current epoch
            // exceeds the minimum retention period
            return currentEpoch.value >= retention

        case .invalidated:
            // DAS-012 GC-R3: Invalidated T2 units are never collected while invalidated
            if unit.tier == .t2 { return false }
            // T0/T1 invalidated: eligible after retention period
            if let metadata = unit.invalidationMetadata {
                return currentEpoch.value >= metadata.epoch.value + retentionPolicy.t0t1RetentionEpochs
            }
            return true

        case .active, .garbageCollected:
            return false
        }
    }

    // MARK: — Private: Provenance Input Extraction

    /// Extracts provenance input unit IDs from grounding chain and provenance record.
    private func provenanceInputs(from grounding: GroundingChain, provenance: ProvenanceRecord) -> [UnitIdentifier] {
        var inputs = provenance.inputUnitIds
        switch grounding {
        case .direct:
            break
        case let .derived(unitIds):
            inputs.append(contentsOf: unitIds)
        case let .inferred(inputUnits, _):
            inputs.append(contentsOf: inputUnits)
        }
        return inputs
    }

    // MARK: — Private: State Management

    private func transitionState(to target: StorageEngineState) {
        let current = state
        guard current.canTransition(to: target) else {
            logger.warning("Invalid state transition: \(current.rawValue) → \(target.rawValue)")
            return
        }
        state = target
        logger.info("State transition: \(current.rawValue) → \(target.rawValue)")
    }
}
