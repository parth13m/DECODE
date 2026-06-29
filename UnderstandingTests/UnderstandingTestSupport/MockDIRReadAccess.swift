// MockDIRReadAccess.swift — UnderstandingTestSupport
// IAG-001 §9: Initial mock set for Phase 2 testing
// IAG-004 §3.1: MockDIRReadAccess needed by ProducerRuntimeTests,
//               IndexRuntimeTests, RetrievalRuntimeTests, StorageEngineTests

import Foundation
@testable import DIRCore

/// Mock implementation of `DIRReadAccess` for unit testing.
///
/// Tests configure the mock by populating `units` and setting `epoch`.
/// All protocol methods read from these stored values.
public final class MockDIRReadAccess: DIRReadAccess, @unchecked Sendable {

    /// The units in the mock store, keyed by identifier.
    public var units: [UnitIdentifier: AtomicUnit] = [:]

    /// The mock committed epoch.
    public var epoch: Epoch = .zero

    public init() {}

    // MARK: — DIRReadAccess

    public func unit(for id: UnitIdentifier) async -> AtomicUnit? {
        units[id]
    }

    public func activeUnits() async -> [AtomicUnit] {
        units.values.filter { $0.status == .active }
    }

    public func invalidatedUnits() async -> [AtomicUnit] {
        units.values.filter { $0.status == .invalidated }
    }

    public func allUnits() async -> [AtomicUnit] {
        Array(units.values)
    }

    public func activeUnit(for key: SupersessionKey) async -> AtomicUnit? {
        units.values.first { $0.status == .active && $0.supersessionKey == key }
    }

    public var committedEpoch: Epoch {
        get async { epoch }
    }
}
