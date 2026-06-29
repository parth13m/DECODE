// SnapshotData.swift — StorageEngine
// DDS-008: PC-1, PC-2 — Snapshot capture and loading
// DAS-012: Snapshot persistence, atomicity, consistency, integrity

import Foundation
import DIRCore

/// The serializable representation of a complete DIR snapshot.
///
/// DDS-008 PC-1: Contains all active and invalidated units, epoch counter,
/// unit identity counter, content hash map, and deferred T2 recomputation queue.
/// Every snapshot represents exactly one committed DIR epoch (RI-1).
public struct SnapshotData: Codable, Sendable {

    /// All active and invalidated units at the snapshot epoch.
    public let units: [AtomicUnit]

    /// The epoch at which this snapshot was captured.
    public let epoch: Epoch

    /// The next unit identity counter value (for resuming ID assignment).
    public let nextUnitId: UInt64

    /// Per-file content hashes at the snapshot epoch (DDS-008 R8).
    public let contentHashes: [String: ContentHash]

    /// Deferred T2 recomputation queue entries (DDS-008 R6).
    /// Each entry is a unit ID that needs T2 recomputation.
    public let deferredQueue: [UnitIdentifier]

    /// Checksum of the serialized contents (DAS-012 snapshot integrity).
    /// Computed over all fields except this one.
    public var checksum: Data?

    public init(
        units: [AtomicUnit],
        epoch: Epoch,
        nextUnitId: UInt64,
        contentHashes: [String: ContentHash],
        deferredQueue: [UnitIdentifier],
        checksum: Data? = nil
    ) {
        self.units = units
        self.epoch = epoch
        self.nextUnitId = nextUnitId
        self.contentHashes = contentHashes
        self.deferredQueue = deferredQueue
        self.checksum = checksum
    }
}

/// The result of a snapshot load attempt.
///
/// DDS-008 PC-2: Either the snapshot was loaded successfully, the prior
/// snapshot was used, or a full rebuild is required.
public enum SnapshotLoadResult: Sendable {
    /// Snapshot loaded successfully.
    case loaded(SnapshotData)

    /// No valid snapshot found — first launch or full rebuild required.
    case requiresFullRebuild

    /// Snapshot was corrupted; prior snapshot loaded instead.
    case loadedPrior(SnapshotData)
}

/// GC retention policy configuration.
///
/// DDS-008 PC-3, DAS-012 GC-R1 through GC-R4.
public struct GCRetentionPolicy: Sendable {
    /// T0/T1 superseded units: eligible after this many epochs (DAS-012 GC-R1).
    /// Default: 1 (eligible at the next epoch).
    public let t0t1RetentionEpochs: UInt64

    /// T2 superseded units: eligible after this many epochs (DAS-012 GC-R2).
    /// Default: 100.
    public let t2RetentionEpochs: UInt64

    /// Minimum T2 retention under memory pressure (DAS-012 GC-S3).
    /// Default: 10.
    public let t2MinRetentionEpochs: UInt64

    /// GC triggers every N epochs (DAS-012 GC-S2).
    /// Default: 10.
    public let gcIntervalEpochs: UInt64

    public init(
        t0t1RetentionEpochs: UInt64 = 1,
        t2RetentionEpochs: UInt64 = 100,
        t2MinRetentionEpochs: UInt64 = 10,
        gcIntervalEpochs: UInt64 = 10
    ) {
        self.t0t1RetentionEpochs = t0t1RetentionEpochs
        self.t2RetentionEpochs = t2RetentionEpochs
        self.t2MinRetentionEpochs = t2MinRetentionEpochs
        self.gcIntervalEpochs = gcIntervalEpochs
    }

    /// Default policy per DAS-012.
    public static let `default` = GCRetentionPolicy()
}
