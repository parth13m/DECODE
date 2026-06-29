// GarbageCollector.swift — StorageEngine
// DDS-008: PC-3 — Garbage Collection Execution
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses StorageActor boundary

import Foundation
import DIRCore

/// Result of a garbage collection cycle.
public struct GCCycleResult: Sendable {
    /// Number of candidates evaluated.
    public let candidatesEvaluated: Int
    /// Number of units collected.
    public let candidatesCollected: Int
    /// Number of candidates skipped due to GC safety.
    public let candidatesSkippedSafety: Int
    /// Number of candidates skipped due to retention policy.
    public let candidatesSkippedRetention: Int
    /// Duration of the GC cycle.
    public let duration: TimeInterval

    public init(
        candidatesEvaluated: Int,
        candidatesCollected: Int,
        candidatesSkippedSafety: Int,
        candidatesSkippedRetention: Int,
        duration: TimeInterval
    ) {
        self.candidatesEvaluated = candidatesEvaluated
        self.candidatesCollected = candidatesCollected
        self.candidatesSkippedSafety = candidatesSkippedSafety
        self.candidatesSkippedRetention = candidatesSkippedRetention
        self.duration = duration
    }
}

/// Executes garbage collection based on tier-informed retention policy.
///
/// DDS-008 PC-3: Evaluates unit eligibility, verifies GC safety via grounding
/// dependency map, issues GC directives to the DIR Runtime.
///
/// IAG-003: All methods are async — they cross the StorageActor boundary.
/// Implemented by StorageActor, consumed by UpdateEngine.
public protocol GarbageCollector: Sendable {

    /// Executes a garbage collection cycle.
    ///
    /// DDS-008 PC-3: Scans for eligible units, verifies safety, issues GC directives.
    /// GC runs as a background operation — does not block the synchronous pipeline.
    ///
    /// - Parameter currentEpoch: The current committed epoch for retention calculation.
    /// - Returns: The result of the GC cycle.
    func collectGarbage(currentEpoch: Epoch) async -> GCCycleResult
}
