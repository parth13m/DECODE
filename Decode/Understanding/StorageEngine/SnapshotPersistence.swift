// SnapshotPersistence.swift — StorageEngine
// DDS-008: PC-1 (Snapshot Capture), PC-2 (Snapshot Loading)
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses StorageActor boundary

import Foundation
import DIRCore

/// Manages snapshot capture and loading for DIR persistence.
///
/// DDS-008 PC-1: Captures epoch-aligned snapshots atomically.
/// DDS-008 PC-2: Loads snapshots on startup to populate the DIR.
///
/// IAG-003: All methods are async — they cross the StorageActor boundary.
/// Implemented by StorageActor, consumed by UpdateEngine.
public protocol SnapshotPersistence: Sendable {

    /// Captures a snapshot of the current DIR state.
    ///
    /// DDS-008 PC-1: Reads DIR contents at committed epoch, serializes
    /// atomically to disk. Prior snapshot retained until rename completes.
    ///
    /// - Parameter snapshot: The snapshot data to persist.
    func captureSnapshot(_ snapshot: SnapshotData) async throws

    /// Loads the most recent valid snapshot from disk.
    ///
    /// DDS-008 PC-2: Locates snapshot file, validates checksum.
    /// Falls back to prior snapshot if primary is corrupted.
    /// Returns `.requiresFullRebuild` if no valid snapshot exists.
    func loadSnapshot() async -> SnapshotLoadResult

    /// Returns the epoch of the most recently captured snapshot, if any.
    func lastSnapshotEpoch() async -> Epoch?
}
