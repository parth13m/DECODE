// StorageError.swift — StorageEngine
// DDS-008: FM-1 through FM-6 — failure categories

import Foundation
import DIRCore

/// Errors that can occur during Storage Engine operations.
///
/// DDS-008 Failure Handling: FM-1 (snapshot write failure), FM-2 (snapshot load corruption),
/// FM-3 (schema evolution), FM-4 (GC safety violation), FM-5 (grounding map inconsistency),
/// FM-6 (disk space exhaustion).
public enum StorageError: Error, Sendable {
    /// FM-1: Snapshot write to disk failed.
    case snapshotWriteFailed(detail: String)

    /// FM-2: Snapshot file failed checksum validation.
    case snapshotCorrupted(path: String)

    /// FM-3: Snapshot contains units that fail current intake validation.
    case schemaEvolution(rejectedCount: Int, totalCount: Int)

    /// FM-4: GC candidate is referenced by active/invalidated units.
    case gcSafetyViolation(unitId: UnitIdentifier)

    /// FM-5: Grounding dependency map is inconsistent with DIR provenance.
    case groundingMapInconsistency(detail: String)

    /// FM-6: Disk space exhaustion.
    case diskSpaceExhausted

    /// Invalid state transition.
    case invalidState(current: StorageEngineState, attempted: String)

    /// The Storage Engine is not accepting operations.
    case notOperational
}
