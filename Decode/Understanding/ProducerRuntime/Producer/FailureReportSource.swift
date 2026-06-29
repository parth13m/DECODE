// FailureReportSource.swift — ProducerRuntime
// DDS-001: PC-6 — failure reports
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses ProducerActor boundary

import Foundation
import DIRCore

/// Provides access to producer failure records.
///
/// DDS-001 PC-6: Every producer failure is recorded with identity, version,
/// scope, failure category, and diagnostic detail. Records retained for
/// the current session.
///
/// IAG-003: All methods are async — they cross the ProducerActor boundary.
/// Implemented by ProducerActor, consumed by UpdateEngine.
public protocol FailureReportSource: Sendable {

    /// Returns all failure records for the current session.
    func allFailures() async -> [FailureRecord]

    /// Returns failure records for a specific producer.
    func failures(for producerId: ProducerIdentifier) async -> [FailureRecord]

    /// Clears all failure records (e.g., on session reset).
    func clearFailures() async
}
