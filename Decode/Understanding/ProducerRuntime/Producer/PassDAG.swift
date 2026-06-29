// PassDAG.swift — ProducerRuntime
// DDS-001: R2 — DAG construction from registered pass contracts
// DAS-006: PD-1 through PD-6 — dependency declaration and DAG construction
// DAS-006: I1 — DAG acyclicity invariant
// DAS-006: PE-1 — tier-level ordering enforcement

import Foundation
import DIRCore

/// The directed acyclic graph of pass dependencies.
///
/// DDS-001 R2: Constructed from registered pass contracts. Maintains
/// acyclicity (DAS-006 I1), topological order, and tier-level ordering.
///
/// The DAG is reconstructed from the registry on each change.
/// External subsystems query it through PC-3.
struct PassDAG: Sendable {

    /// A node in the DAG representing a registered producer.
    struct Node: Sendable {
        let producerId: ProducerIdentifier
        let kind: ProducerKind
        /// The output tier range (used for tier-level ordering).
        let outputTierRange: ClosedRange<Tier>
        /// For passes: the declared dependencies.
        let dependencies: Set<ProducerIdentifier>
    }

    /// The nodes in the DAG, keyed by producer identifier.
    private let nodes: [ProducerIdentifier: Node]

    /// The topological ordering of producer identifiers.
    /// Frontends appear first, then passes in dependency/tier order.
    let topologicalOrder: [ProducerIdentifier]

    /// Groups of producers at the same topological level that can execute concurrently.
    /// DAS-006 PE-2: independent passes at the same level may execute concurrently.
    let executionLevels: [[ProducerIdentifier]]

    /// Creates an empty DAG.
    init() {
        self.nodes = [:]
        self.topologicalOrder = []
        self.executionLevels = []
    }

    /// Creates a DAG from the given nodes. Internal — use `build(from:)`.
    private init(
        nodes: [ProducerIdentifier: Node],
        topologicalOrder: [ProducerIdentifier],
        executionLevels: [[ProducerIdentifier]]
    ) {
        self.nodes = nodes
        self.topologicalOrder = topologicalOrder
        self.executionLevels = executionLevels
    }

    /// Whether the DAG is empty (no producers registered).
    var isEmpty: Bool { nodes.isEmpty }

    /// The number of registered producers.
    var count: Int { nodes.count }

    /// Returns the node for the given producer, if registered.
    func node(for id: ProducerIdentifier) -> Node? {
        nodes[id]
    }

    /// All registered producer identifiers.
    var allProducerIds: Set<ProducerIdentifier> {
        Set(nodes.keys)
    }

    /// Returns the producers that produce output matching the given predicate and tier.
    ///
    /// DDS-001 PC-4: Producer discovery by predicate and tier.
    func producers(
        for predicate: PredicateIdentifier,
        at tier: Tier,
        contracts: [ProducerIdentifier: ProducerContract]
    ) -> [ProducerIdentifier] {
        contracts.compactMap { id, contract in
            let output = contract.outputContract
            if output.predicates.contains(predicate) && output.tierRange.contains(tier) {
                return id
            }
            return nil
        }
    }

    // MARK: — DAG Construction

    /// Builds a new DAG from the given set of contracts.
    ///
    /// DAS-006 I1: Verifies acyclicity. Returns the cycle path on failure.
    /// DAS-006 PE-1: Enforces tier-level ordering (T0 passes before T1 before T2).
    /// DAS-006 PD-6: Frontends are implicit DAG roots.
    ///
    /// - Parameter contracts: All registered producer contracts.
    /// - Returns: A valid DAG, or a cycle error identifying the offending path.
    static func build(
        from contracts: [ProducerIdentifier: ProducerContract]
    ) -> Result<PassDAG, DAGError> {
        // Build nodes
        var dagNodes: [ProducerIdentifier: Node] = [:]
        for (id, contract) in contracts {
            let kind: ProducerKind
            let deps: Set<ProducerIdentifier>
            let tierRange: ClosedRange<Tier>

            switch contract {
            case .frontend(let fc):
                kind = .frontend
                deps = []
                tierRange = fc.outputContract.tierRange
            case .pass(let pc):
                kind = .pass
                deps = pc.dependencies
                tierRange = pc.outputContract.tierRange
            }

            dagNodes[id] = Node(
                producerId: id,
                kind: kind,
                outputTierRange: tierRange,
                dependencies: deps
            )
        }

        // Verify all dependencies reference registered producers
        for (id, node) in dagNodes {
            for dep in node.dependencies {
                if dagNodes[dep] == nil {
                    return .failure(.missingDependency(
                        producer: id,
                        missingDependency: dep
                    ))
                }
            }
        }

        // Topological sort with cycle detection (Kahn's algorithm)
        let sortResult = topologicalSort(nodes: dagNodes)
        switch sortResult {
        case .success(let order):
            // Group into execution levels
            let levels = computeExecutionLevels(order: order, nodes: dagNodes)
            return .success(PassDAG(
                nodes: dagNodes,
                topologicalOrder: order,
                executionLevels: levels
            ))
        case .failure(let dagError):
            return .failure(dagError)
        }
    }

    /// Checks whether adding a producer with the given contract would create a cycle,
    /// without actually modifying the DAG.
    ///
    /// DDS-001 FM-4: Pre-registration cycle check.
    func wouldCreateCycle(
        adding contract: ProducerContract,
        existingContracts: [ProducerIdentifier: ProducerContract]
    ) -> [ProducerIdentifier]? {
        var allContracts = existingContracts
        allContracts[contract.identity.identifier] = contract
        switch Self.build(from: allContracts) {
        case .success:
            return nil
        case .failure(.cycle(let path)):
            return path
        case .failure:
            return nil
        }
    }

    // MARK: — Topological Sort

    /// Kahn's algorithm for topological sort with cycle detection.
    ///
    /// Frontends (no dependencies) are natural roots.
    /// Tier-level ordering is enforced by sorting within each level.
    private static func topologicalSort(
        nodes: [ProducerIdentifier: Node]
    ) -> Result<[ProducerIdentifier], DAGError> {
        // Compute in-degrees
        // Edge direction: if B depends on A, then A → B. B has an incoming edge from A.
        var inDegree: [ProducerIdentifier: Int] = [:]
        for id in nodes.keys {
            inDegree[id] = 0
        }
        for (_, node) in nodes {
            // Each dependency is an incoming edge to this node
            inDegree[node.producerId, default: 0] += node.dependencies.count
        }

        // Start with nodes that have no incoming edges (frontends and independent passes)
        var queue: [ProducerIdentifier] = inDegree
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted { a, b in
                // Sort roots: frontends first, then by minimum output tier
                let nodeA = nodes[a]!
                let nodeB = nodes[b]!
                if nodeA.kind != nodeB.kind {
                    return nodeA.kind == .frontend
                }
                return nodeA.outputTierRange.lowerBound < nodeB.outputTierRange.lowerBound
            }

        var result: [ProducerIdentifier] = []
        var remaining = inDegree

        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)
            remaining.removeValue(forKey: current)

            // Find all nodes that depend on current
            var nextBatch: [ProducerIdentifier] = []
            for (id, node) in nodes {
                if node.dependencies.contains(current) {
                    inDegree[id, default: 0] -= 1
                    if inDegree[id] == 0 {
                        nextBatch.append(id)
                    }
                }
            }

            // Sort next batch by tier for tier-level ordering
            nextBatch.sort { a, b in
                let nodeA = nodes[a]!
                let nodeB = nodes[b]!
                return nodeA.outputTierRange.lowerBound < nodeB.outputTierRange.lowerBound
            }

            queue.append(contentsOf: nextBatch)
        }

        if result.count != nodes.count {
            // Cycle detected — find the cycle path
            let cyclePath = findCyclePath(in: remaining, nodes: nodes)
            return .failure(.cycle(cyclePath))
        }

        return .success(result)
    }

    /// Finds a cycle path among the remaining nodes after topological sort fails.
    private static func findCyclePath(
        in remaining: [ProducerIdentifier: Int],
        nodes: [ProducerIdentifier: Node]
    ) -> [ProducerIdentifier] {
        let remainingIds = Set(remaining.keys)
        guard let start = remainingIds.first else { return [] }

        // DFS to find cycle
        var visited: Set<ProducerIdentifier> = []
        var path: [ProducerIdentifier] = []

        func dfs(_ current: ProducerIdentifier) -> Bool {
            if path.contains(current) {
                // Found cycle — trim path to just the cycle
                if let idx = path.firstIndex(of: current) {
                    path = Array(path[idx...])
                    path.append(current)
                }
                return true
            }
            if visited.contains(current) { return false }
            visited.insert(current)
            path.append(current)

            if let node = nodes[current] {
                for dep in node.dependencies where remainingIds.contains(dep) {
                    if dfs(dep) { return true }
                }
            }

            path.removeLast()
            return false
        }

        _ = dfs(start)
        return path.isEmpty ? Array(remainingIds) : path
    }

    /// Groups topologically ordered producers into execution levels.
    ///
    /// DAS-006 PE-2: Passes at the same level with no mutual dependency
    /// may execute concurrently.
    private static func computeExecutionLevels(
        order: [ProducerIdentifier],
        nodes: [ProducerIdentifier: Node]
    ) -> [[ProducerIdentifier]] {
        guard !order.isEmpty else { return [] }

        // Assign each node to the earliest level it can execute at
        var levelMap: [ProducerIdentifier: Int] = [:]

        for id in order {
            guard let node = nodes[id] else { continue }
            if node.dependencies.isEmpty {
                levelMap[id] = 0
            } else {
                let maxDepLevel = node.dependencies.compactMap { levelMap[$0] }.max() ?? 0
                levelMap[id] = maxDepLevel + 1
            }
        }

        // Group by level
        let maxLevel = levelMap.values.max() ?? 0
        var levels: [[ProducerIdentifier]] = Array(repeating: [], count: maxLevel + 1)
        for id in order {
            if let level = levelMap[id] {
                levels[level].append(id)
            }
        }

        return levels.filter { !$0.isEmpty }
    }
}

// MARK: — DAG Errors

/// Errors from DAG construction.
///
/// DDS-001 FM-4: cycle detection reports the cycle path.
enum DAGError: Error, Sendable {
    /// Adding the producer would create a cycle. Includes the cycle path.
    case cycle([ProducerIdentifier])
    /// A declared dependency references an unregistered producer.
    case missingDependency(producer: ProducerIdentifier, missingDependency: ProducerIdentifier)
}
