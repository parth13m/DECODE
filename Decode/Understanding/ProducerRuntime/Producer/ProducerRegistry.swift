// ProducerRegistry.swift — ProducerRuntime
// DDS-001: PC-1 (registration), PC-3 (DAG query), PC-4 (discovery)
// IAG-001 §4: Public protocol, implemented by ProducerRuntime, consumed by UpdateEngine
// IAG-003 §3.1: All cross-module protocols are async (crosses ProducerActor boundary)

import Foundation
import DIRCore

/// The Producer Registry — registration, DAG query, and discovery.
///
/// DDS-001 PC-1: Accept, validate, and catalog producer contracts.
/// DDS-001 PC-3: Query the Pass DAG state.
/// DDS-001 PC-4: Discover producers by predicate and tier.
///
/// IAG-003: All methods are async — they cross the ProducerActor boundary.
/// Implemented by ProducerActor, consumed by UpdateEngine.
public protocol ProducerRegistry: Sendable {

    /// Registers a producer contract.
    ///
    /// DDS-001 PC-1: Validates the contract and adds it to the registry.
    /// Registration is deferred during active execution cycles.
    ///
    /// - Parameter contract: The producer's full contract (frontend or pass).
    /// - Returns: Whether the registration was accepted, deferred, or rejected.
    /// - Throws: `ProducerError.dagCycle` if the contract introduces a DAG cycle.
    func register(_ contract: ProducerContract) async throws -> RegistrationResult

    /// Removes a producer from the registry.
    ///
    /// - Parameter id: The producer to remove.
    /// - Throws: `ProducerError.producerNotFound` if the producer is not registered.
    func remove(_ id: ProducerIdentifier) async throws

    /// Returns the current DAG structure.
    ///
    /// DDS-001 PC-3: The DAG reflects all accepted registrations.
    /// Non-mutating — does not block other actor work.
    func dagSnapshot() async -> DAGSnapshot

    /// Discovers producers whose output contract matches the given predicate and tier.
    ///
    /// DDS-001 PC-4: Returns empty if no registered producer produces the requested content.
    func producers(
        for predicate: PredicateIdentifier,
        at tier: Tier
    ) async -> [ProducerIdentifier]

    /// Returns the contract for the given producer, if registered.
    func contract(for id: ProducerIdentifier) async -> ProducerContract?

    /// Returns all registered producer identifiers.
    func registeredProducers() async -> Set<ProducerIdentifier>
}

/// A snapshot of the DAG state for query purposes.
///
/// DDS-001 PC-3: DAG query returns registered producers, edges,
/// topological order, and per-producer state.
public struct DAGSnapshot: Sendable {
    /// All registered producer identifiers, in topological order.
    public let topologicalOrder: [ProducerIdentifier]

    /// Groups of producers at the same execution level (may run concurrently).
    public let executionLevels: [[ProducerIdentifier]]

    /// The number of registered frontends.
    public let frontendCount: Int

    /// The number of registered deterministic passes.
    public let deterministicPassCount: Int

    /// The number of registered semantic passes.
    public let semanticPassCount: Int

    public init(
        topologicalOrder: [ProducerIdentifier],
        executionLevels: [[ProducerIdentifier]],
        frontendCount: Int,
        deterministicPassCount: Int,
        semanticPassCount: Int
    ) {
        self.topologicalOrder = topologicalOrder
        self.executionLevels = executionLevels
        self.frontendCount = frontendCount
        self.deterministicPassCount = deterministicPassCount
        self.semanticPassCount = semanticPassCount
    }
}
