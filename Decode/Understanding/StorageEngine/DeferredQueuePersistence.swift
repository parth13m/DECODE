// DeferredQueuePersistence.swift — StorageEngine
// DDS-008: PC-6 — Deferred Queue Persistence
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses StorageActor boundary

import Foundation
import DIRCore

/// Provides persistence for the deferred T2 recomputation queue.
///
/// DDS-008 PC-6: The deferred queue is included in every snapshot.
/// On startup, the queue is restored and validated.
///
/// IAG-003: All methods are async — they cross the StorageActor boundary.
/// Implemented by StorageActor, consumed by UpdateEngine.
public protocol DeferredQueuePersistence: Sendable {

    /// Returns the current deferred T2 recomputation queue.
    ///
    /// DDS-008 PC-6: Restored from snapshot on startup.
    func deferredQueue() async -> [UnitIdentifier]

    /// Updates the deferred queue.
    ///
    /// DDS-008 PC-6: Called by UpdateEngine during operation.
    func updateDeferredQueue(_ queue: [UnitIdentifier]) async

    /// Adds a unit to the deferred queue.
    func enqueueDeferredUnit(_ unitId: UnitIdentifier) async

    /// Removes a unit from the deferred queue.
    func dequeueDeferredUnit(_ unitId: UnitIdentifier) async
}
