// MockDIRWriteAccess.swift — UnderstandingTestSupport
// IAG-001 §9: Initial mock set for Phase 2 testing
// IAG-004 §3.1: MockDIRWriteAccess needed by ProducerRuntimeTests, StorageEngineTests

import Foundation
@testable import DIRCore

/// Mock implementation of `DIRWriteAccess` for unit testing.
///
/// Records all submitted transactions for assertion. Returns a configurable result.
public final class MockDIRWriteAccess: DIRWriteAccess, @unchecked Sendable {

    /// All transactions submitted to this mock.
    public private(set) var submittedTransactions: [WriteTransaction] = []

    /// The result to return for the next `submit()` call.
    /// Defaults to a committed result with no admissions or transitions.
    public var nextResult: WriteTransactionResult = .committed(CommittedTransaction(
        epoch: .zero,
        admittedUnitIds: [],
        supersededUnitIds: [],
        appliedTransitions: []
    ))

    public init() {}

    // MARK: — DIRWriteAccess

    public func submit(_ transaction: WriteTransaction) async -> WriteTransactionResult {
        submittedTransactions.append(transaction)
        return nextResult
    }
}
