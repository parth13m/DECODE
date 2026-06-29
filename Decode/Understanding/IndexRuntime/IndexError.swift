// IndexError.swift — IndexRuntime
// DDS-004: FM-1 through FM-5 — failure categories

import Foundation
import DIRCore

/// Errors that can occur during index operations.
///
/// DDS-004 Failure Handling: FM-1 (inconsistency), FM-2 (family lost),
/// FM-3 (staleness), FM-4 (DIR unavailable during rebuild), FM-5 (change batch error).
public enum IndexError: Error, Sendable {
    /// FM-1: A structural index entry is inconsistent with the DIR.
    case inconsistency(family: IndexFamily, detail: String)

    /// FM-2: An index family's data is entirely lost.
    case familyLost(family: IndexFamily)

    /// FM-3: A structural index is stale (last-update epoch behind DIR committed epoch).
    case staleness(family: IndexFamily, indexEpoch: Epoch, dirEpoch: Epoch)

    /// FM-4: DIR Runtime became unavailable during index rebuild.
    case dirUnavailable

    /// FM-5: Error processing a change batch for a specific family.
    case changeBatchError(family: IndexFamily, detail: String)

    /// Invalid state transition.
    case invalidState(current: IndexRuntimeState, attempted: String)

    /// The Index Runtime is not accepting operations (quiescing or terminated).
    case notAccepting
}
