// IndexBatchUpdate.swift — IndexRuntime
// DDS-004: PC-4 — Batch Index Update
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses IndexActor boundary

import Foundation
import DIRCore

/// Accepts change batches and updates index families.
///
/// DDS-004 PC-4: Given a change batch, updates all structural indexes
/// (Entity, Graph, Scope, Predicate) synchronously. Content Index update
/// is enqueued for deferred processing (DAS-010 IM-4).
///
/// Update ordering within a change batch follows DAS-010 IM-3:
/// Entity and Graph first → Scope and Predicate second → Content deferred.
///
/// IAG-003: All methods are async — they cross the IndexActor boundary.
/// Implemented by IndexActor, consumed by UpdateEngine.
public protocol IndexBatchUpdate: Sendable {

    /// Applies a change batch to all index families.
    ///
    /// DDS-004 PC-4: Structural indexes updated synchronously before return.
    /// Content Index update is enqueued for deferred processing.
    ///
    /// Per-family behavior (DDS-004 PC-4 precondition):
    /// - Available families: updated immediately.
    /// - Rebuilding families: changes applied to in-progress rebuild copy.
    /// - Building families: changes queued for application on construction completion.
    ///
    /// - Parameter batch: The change batch from a committed write transaction.
    /// - Returns: Result indicating which families were updated successfully.
    func applyBatch(_ batch: ChangeBatch) async -> BatchUpdateResult

    /// Processes pending deferred Content Index updates.
    ///
    /// DDS-004 RI-8: The Content Index is never more than one execution cycle
    /// behind the DIR. This method processes the deferred update queue.
    func processDeferredUpdates() async

    /// Triggers a rebuild of a specific index family from the DIR.
    ///
    /// DDS-004 PC-2: Scans the relevant DIR subset, constructs a fresh index,
    /// and atomically replaces the existing index. During rebuild, queries
    /// against the rebuilding family use DIR scan fallback.
    ///
    /// - Parameter family: The index family to rebuild.
    func rebuildFamily(_ family: IndexFamily) async
}
