// FailureRecord.swift — ProducerRuntime
// DDS-001: PC-6 — failure reports
// DDS-001: FM-1 through FM-7 — failure categories

import Foundation
import DIRCore

/// The category of a producer failure.
///
/// DDS-001 FM-1 through FM-7: each failure mode maps to a specific category
/// for diagnostic and recovery purposes.
public enum FailureCategory: String, Hashable, Sendable {
    /// FM-1: Producer threw an error during execution.
    case executionError
    /// FM-2: Producer exceeded its timeout bound.
    case timeout
    /// FM-3: Output batch failed validation (wrong predicates, tier, provenance, grounding).
    case invalidOutput
    /// FM-4: DAG cycle detected during registration.
    case dagCycle
    /// FM-5: Semantic pass could not reach AI service.
    case aiServiceUnavailable
    /// FM-6: DIR write transaction was rejected.
    case dirWriteFailure
    /// FM-7: Frontend could not read source file.
    case sourceInaccessible
}

/// A record of a producer execution failure.
///
/// DDS-001 PC-6: Every failure is recorded with producer identity, version,
/// scope, failure category, and diagnostic detail. Retained for the current session.
public struct FailureRecord: Sendable {
    /// The producer that failed.
    public let producerIdentity: ProducerIdentity

    /// The scope of the failed execution.
    public let scope: ExecutionScope

    /// The failure category.
    public let category: FailureCategory

    /// Human-readable diagnostic detail for debugging.
    public let diagnostic: String

    /// Whether the failed invocation is eligible for retry.
    ///
    /// DDS-003 RE-1: Deterministic passes are always retry-eligible.
    /// DDS-003 RE-2: Semantic passes are retry-eligible for transient failures.
    /// DDS-003 RE-3: Composition passes follow their underlying strategy.
    public let isRetryEligible: Bool

    /// When the failure occurred.
    public let timestamp: Date

    public init(
        producerIdentity: ProducerIdentity,
        scope: ExecutionScope,
        category: FailureCategory,
        diagnostic: String,
        isRetryEligible: Bool,
        timestamp: Date = Date()
    ) {
        self.producerIdentity = producerIdentity
        self.scope = scope
        self.category = category
        self.diagnostic = diagnostic
        self.isRetryEligible = isRetryEligible
        self.timestamp = timestamp
    }
}
