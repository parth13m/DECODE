// EvidenceRetrieval.swift — RetrievalRuntime
// DDS-005: PC-1 (evidence retrieval), PC-2 (anchor resolution)
// IAG-001 §4: Defined in RetrievalRuntime, consumed by ContextAssembly
// IAG-003 §3.1: async — performs async I/O (index queries, DIR reads)

import Foundation
import DIRCore

/// Executes multi-stage evidence retrieval over the DIR and indexes.
///
/// DDS-005 PC-1: Given a retrieval request, executes the five-stage pipeline
/// and returns an evidence set with annotated units in canonical order.
///
/// DDS-005 PC-2: Resolves subject references to entity anchors without
/// executing the full pipeline.
///
/// Stateless — no persistent state between requests (IAG-003 §1.2).
/// Each request captures its own epoch and maintains its own budget counter.
public protocol EvidenceRetrieval: Sendable {

    /// Executes the five-stage evidence retrieval pipeline.
    ///
    /// DDS-005 PC-1: Returns an evidence set containing resolved anchors,
    /// annotated units in canonical order, and execution metadata.
    ///
    /// Correctness guarantees:
    /// - RC-1: Completeness within horizon (up to budget).
    /// - RC-2: Soundness — every unit exists in the DIR at the observed epoch.
    /// - RC-3: Consistent snapshot — all evidence observes the same epoch.
    /// - RC-4: Deterministic anchor resolution.
    ///
    /// - Parameter request: The retrieval request specifying subject, intent,
    ///   scope, tier range, budget, and freshness requirement.
    /// - Returns: An evidence set. Never throws — empty evidence is a valid result.
    func retrieve(_ request: RetrievalRequest) async -> EvidenceSet

    /// Resolves a subject reference to entity anchors without full pipeline execution.
    ///
    /// DDS-005 PC-2: Resolution is deterministic — same subject and DIR state
    /// produce the same anchors. Never synthesizes anchors.
    ///
    /// - Parameter subject: The subject reference to resolve.
    /// - Returns: Resolved entity anchors (empty if subject not found).
    func resolveAnchors(for subject: SubjectReference) async -> [EntityReference]
}
