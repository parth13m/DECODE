// DIRReadAccess.swift — DIRCore
// DDS-002: PC-3 (epoch-consistent read), PC-5 (unit identity resolution), PC-8 (snapshot capture)
// IAG-001 §4: Defined in DIRCore, implemented by UpdateEngine,
//             consumed by ProducerRuntime, RetrievalRuntime, StorageEngine, IndexRuntime
// IAG-003 §3.1: async — crosses UpdateActor boundary

import Foundation

/// Read-only access to the DIR unit store.
///
/// Provides epoch-consistent reads (DDS-002 PC-3), identity resolution (PC-5),
/// and bulk access for snapshot capture (PC-8) and index construction.
///
/// All reads observe the committed epoch. During synchronous pipeline execution,
/// consumer/external reads see the prior committed epoch. Pipeline-internal reads
/// (producer reads) see committed epoch plus prior producers' output — that
/// distinction is handled by `EpochControl`, not by this protocol.
///
/// Implemented by `UpdateEngine`. Consumed by modules that need to query the DIR
/// without importing `UpdateEngine` directly.
public protocol DIRReadAccess: Sendable {

    // MARK: — Identity Resolution (PC-5)

    /// Returns the complete unit record for the given identifier, if it exists.
    ///
    /// DDS-002 PC-5: O(1) lookup. Returns the unit regardless of lifecycle status.
    /// Returns `nil` if the unit has been garbage collected or the identifier was never issued.
    func unit(for id: UnitIdentifier) async -> AtomicUnit?

    // MARK: — Status-Partitioned Reads (PC-3)

    /// Returns all Active units.
    ///
    /// DDS-002 PC-3: Default read partition. All returned units have `.active` status
    /// at the committed epoch.
    func activeUnits() async -> [AtomicUnit]

    /// Returns all Invalidated units.
    ///
    /// DDS-002 PC-3: Invalidated units remain queryable with their invalidation metadata.
    func invalidatedUnits() async -> [AtomicUnit]

    /// Returns all units regardless of status.
    ///
    /// Used by StorageEngine for snapshot capture (PC-8) and IndexRuntime for
    /// index construction.
    func allUnits() async -> [AtomicUnit]

    // MARK: — Supersession Key Lookup

    /// Returns the Active unit for the given supersession key, if one exists.
    ///
    /// DDS-002: At most one Active unit exists per supersession key.
    func activeUnit(for key: SupersessionKey) async -> AtomicUnit?

    // MARK: — Epoch

    /// The current committed epoch.
    ///
    /// DDS-002 PC-3: All consumer reads observe this epoch.
    var committedEpoch: Epoch { get async }
}
