// ProducerActor.swift — ProducerRuntime
// DDS-001: Producer Runtime — registry, DAG, execution orchestration
// DDS-003: Pass Runtime — invocation lifecycle, input assembly, output pipeline
// IAG-003 §2.2: ProducerActor owns registry, DAG, execution state, prior output
// IAG-003 §8: os.Logger category "producer"

import Foundation
import DIRCore
import os

/// The core actor of the Producer Runtime.
///
/// IAG-003 §2.2: Owns the producer registry, Pass DAG, per-invocation
/// lifecycle state, and prior output records. All cross-module protocol
/// methods serialize through this actor.
///
/// Concurrency model:
/// - Independent passes at the same topological level execute concurrently
///   via TaskGroup (DAS-006 PE-2).
/// - Per-invocation lifecycle state transitions are serialized within the actor.
/// - Pass execution itself runs in child tasks.
public actor ProducerActor: ProducerRegistry, ExecutionDirective, FailureReportSource {

    // MARK: — Dependencies

    /// DIR read access (injected as protocol from UpdateEngine).
    private let dirRead: DIRReadAccess

    /// DIR write access (injected as protocol from UpdateEngine).
    private let dirWrite: DIRWriteAccess

    // MARK: — Owned State

    /// Registered producer contracts, keyed by identifier.
    private var contracts: [ProducerIdentifier: ProducerContract] = [:]

    /// Registered pass implementations, keyed by identifier.
    private var passImplementations: [ProducerIdentifier: PassDefinition] = [:]

    /// Registered frontend implementations, keyed by identifier.
    private var frontendImplementations: [ProducerIdentifier: FrontendDefinition] = [:]

    /// The current Pass DAG, rebuilt on registry changes.
    private var dag: PassDAG = PassDAG()

    /// The current runtime state.
    private var state: ProducerRuntimeState = .empty

    /// Producer failure records for the current session (DDS-001 PC-6).
    private var failureRecords: [FailureRecord] = []

    /// Prior output records for changed output detection (DDS-003 R6).
    /// Keyed by (producerId, scopeWindowId).
    private var priorOutputs: [PriorOutputKey: PriorOutputSummary] = [:]

    /// Registrations deferred during execution (DDS-001 state model).
    private var deferredRegistrations: [ProducerContract] = []

    // MARK: — Logging

    private let logger = Logger(subsystem: "com.decode.understanding", category: "producer")

    // MARK: — Initialization

    /// Creates a ProducerActor with DIR access.
    ///
    /// IAG-001 §6: ProducerRuntime receives DIRReadAccess and DIRWriteAccess
    /// from the composition root.
    public init(dirRead: DIRReadAccess, dirWrite: DIRWriteAccess) {
        self.dirRead = dirRead
        self.dirWrite = dirWrite
        logger.debug("ProducerActor created — state: empty")
    }

    // MARK: — ProducerRegistry

    public func register(_ contract: ProducerContract) async throws -> RegistrationResult {
        let id = contract.identity.identifier

        // Validate contract
        if let error = validateContract(contract) {
            logger.warning("Registration rejected for \(id): \(error)")
            return .rejected(reason: error)
        }

        // Defer registration during execution (DDS-001 state model)
        if state == .executing {
            logger.info("Registration deferred for \(id) — runtime is executing")
            deferredRegistrations.append(contract)
            return .deferred
        }

        guard state == .empty || state == .ready else {
            throw ProducerError.invalidState(
                current: state,
                attempted: "register(\(id))"
            )
        }

        // Check for DAG cycle before adding
        if case .pass(let pc) = contract, !pc.dependencies.isEmpty {
            if let cyclePath = dag.wouldCreateCycle(
                adding: contract,
                existingContracts: contracts
            ) {
                logger.error("Registration rejected for \(id) — DAG cycle: \(cyclePath)")
                throw ProducerError.dagCycle(id, cyclePath: cyclePath)
            }
        }

        // Add to registry and rebuild DAG
        contracts[id] = contract
        try rebuildDAG()

        // Transition state
        if state == .empty {
            transitionState(to: .ready)
        }

        logger.info("Registered producer: \(id) (\(contract.kind.rawValue))")
        return .accepted
    }

    /// Registers a pass implementation alongside its contract.
    ///
    /// Internal API — the composition root calls this to wire up pass implementations.
    func registerPass(
        _ contract: PassContract,
        implementation: PassDefinition
    ) async throws -> RegistrationResult {
        let result = try await register(.pass(contract))
        if case .accepted = result {
            passImplementations[contract.identity.identifier] = implementation
        } else if case .deferred = result {
            passImplementations[contract.identity.identifier] = implementation
        }
        return result
    }

    /// Registers a frontend implementation alongside its contract.
    func registerFrontend(
        _ contract: FrontendContract,
        implementation: FrontendDefinition
    ) async throws -> RegistrationResult {
        let result = try await register(.frontend(contract))
        if case .accepted = result {
            frontendImplementations[contract.identity.identifier] = implementation
        } else if case .deferred = result {
            frontendImplementations[contract.identity.identifier] = implementation
        }
        return result
    }

    public func remove(_ id: ProducerIdentifier) async throws {
        guard contracts[id] != nil else {
            throw ProducerError.producerNotFound(id)
        }

        contracts.removeValue(forKey: id)
        passImplementations.removeValue(forKey: id)
        frontendImplementations.removeValue(forKey: id)

        if contracts.isEmpty {
            dag = PassDAG()
            transitionState(to: .empty)
        } else {
            try rebuildDAG()
        }

        logger.info("Removed producer: \(id)")
    }

    public func dagSnapshot() async -> DAGSnapshot {
        var frontendCount = 0
        var deterministicPassCount = 0
        var semanticPassCount = 0

        for contract in contracts.values {
            switch contract {
            case .frontend: frontendCount += 1
            case .pass(let pc):
                switch pc.executionStrategy {
                case .deterministic: deterministicPassCount += 1
                case .semantic: semanticPassCount += 1
                }
            }
        }

        return DAGSnapshot(
            topologicalOrder: dag.topologicalOrder,
            executionLevels: dag.executionLevels,
            frontendCount: frontendCount,
            deterministicPassCount: deterministicPassCount,
            semanticPassCount: semanticPassCount
        )
    }

    public func producers(
        for predicate: PredicateIdentifier,
        at tier: Tier
    ) async -> [ProducerIdentifier] {
        dag.producers(for: predicate, at: tier, contracts: contracts)
    }

    public func contract(for id: ProducerIdentifier) async -> ProducerContract? {
        contracts[id]
    }

    public func registeredProducers() async -> Set<ProducerIdentifier> {
        Set(contracts.keys)
    }

    // MARK: — ExecutionDirective

    public func execute(_ ticket: ExecutionTicket) async -> TicketResult {
        guard state == .ready || state == .executing else {
            let record = FailureRecord(
                producerIdentity: ProducerIdentity(
                    identifier: ticket.producerId,
                    version: ProducerVersion(major: 0, minor: 0)
                ),
                scope: ticket.scope,
                category: .executionError,
                diagnostic: "Runtime not in executable state: \(state.rawValue)",
                isRetryEligible: false
            )
            failureRecords.append(record)
            return .failed(record)
        }

        let wasReady = state == .ready
        if wasReady { transitionState(to: .executing) }

        let result = await executeTicketInternal(ticket)

        if wasReady {
            // Process deferred registrations
            await processDeferredRegistrations()
            transitionState(to: contracts.isEmpty ? .empty : .ready)
        }

        return result
    }

    public func executeBatch(_ tickets: [ExecutionTicket]) async -> [TicketResult] {
        guard state == .ready else {
            return tickets.map { ticket in
                let record = FailureRecord(
                    producerIdentity: ProducerIdentity(
                        identifier: ticket.producerId,
                        version: ProducerVersion(major: 0, minor: 0)
                    ),
                    scope: ticket.scope,
                    category: .executionError,
                    diagnostic: "Runtime not ready: \(state.rawValue)",
                    isRetryEligible: false
                )
                failureRecords.append(record)
                return .failed(record)
            }
        }

        transitionState(to: .executing)

        // Execute tickets in DAG topological order, grouped by execution level
        var results: [TicketResult] = []
        for level in dag.executionLevels {
            let levelTickets = tickets.filter { level.contains($0.producerId) }
            if levelTickets.isEmpty { continue }

            if levelTickets.count == 1 {
                // Single ticket — execute directly
                let result = await executeTicketInternal(levelTickets[0])
                results.append(result)
            } else {
                // Multiple independent tickets — execute concurrently via TaskGroup
                let levelResults = await withTaskGroup(
                    of: (Int, TicketResult).self,
                    returning: [TicketResult].self
                ) { group in
                    for (index, ticket) in levelTickets.enumerated() {
                        group.addTask { [self] in
                            let result = await self.executeTicketInternal(ticket)
                            return (index, result)
                        }
                    }

                    var indexed: [(Int, TicketResult)] = []
                    for await pair in group {
                        indexed.append(pair)
                    }
                    return indexed.sorted { $0.0 < $1.0 }.map(\.1)
                }
                results.append(contentsOf: levelResults)
            }
        }

        // Handle tickets for producers not in the DAG (unregistered)
        let dagProducers = dag.allProducerIds
        for ticket in tickets where !dagProducers.contains(ticket.producerId) {
            let record = FailureRecord(
                producerIdentity: ProducerIdentity(
                    identifier: ticket.producerId,
                    version: ProducerVersion(major: 0, minor: 0)
                ),
                scope: ticket.scope,
                category: .executionError,
                diagnostic: "Producer not registered: \(ticket.producerId)",
                isRetryEligible: false
            )
            failureRecords.append(record)
            results.append(.failed(record))
        }

        await processDeferredRegistrations()
        transitionState(to: contracts.isEmpty ? .empty : .ready)

        return results
    }

    public func executeBatchAll(filePaths: Set<String>) async -> [TicketResult] {
        // Create tickets for all registered producers
        var tickets: [ExecutionTicket] = []

        for (id, contract) in contracts {
            switch contract {
            case .frontend:
                tickets.append(ExecutionTicket(
                    producerId: id,
                    scope: .files(paths: filePaths),
                    mode: .batch
                ))
            case .pass(let pc):
                let scope: ExecutionScope
                switch pc.scope {
                case .perSystem: scope = .system
                default: scope = .files(paths: filePaths)
                }
                tickets.append(ExecutionTicket(
                    producerId: id,
                    scope: scope,
                    mode: .batch
                ))
            }
        }

        return await executeBatch(tickets)
    }

    // MARK: — FailureReportSource

    public func allFailures() async -> [FailureRecord] {
        failureRecords
    }

    public func failures(for producerId: ProducerIdentifier) async -> [FailureRecord] {
        failureRecords.filter { $0.producerIdentity.identifier == producerId }
    }

    public func clearFailures() async {
        failureRecords.removeAll()
        logger.debug("Failure records cleared")
    }

    // MARK: — Shutdown

    /// Initiates graceful shutdown.
    ///
    /// DDS-001: Quiescing → Terminated. No new tickets accepted.
    public func shutdown() {
        guard state.canTransition(to: .quiescing) else { return }
        transitionState(to: .quiescing)
        transitionState(to: .terminated)
        logger.info("ProducerActor terminated")
    }

    // MARK: — Internal Execution

    private func executeTicketInternal(_ ticket: ExecutionTicket) async -> TicketResult {
        let id = ticket.producerId

        guard let contract = contracts[id] else {
            let record = FailureRecord(
                producerIdentity: ProducerIdentity(
                    identifier: id,
                    version: ProducerVersion(major: 0, minor: 0)
                ),
                scope: ticket.scope,
                category: .executionError,
                diagnostic: "Producer not registered",
                isRetryEligible: false
            )
            failureRecords.append(record)
            return .failed(record)
        }

        let identity = contract.identity
        let startTime = ContinuousClock.now

        logger.debug("Executing \(id) over scope \(String(describing: ticket.scope))")

        do {
            let rawOutput: [RawOutputRecord]

            switch contract {
            case .frontend(let fc):
                rawOutput = try await executeFrontend(id: id, contract: fc, scope: ticket.scope)
            case .pass(let pc):
                rawOutput = try await executePass(id: id, contract: pc, scope: ticket.scope)
            }

            // Build output batch with provenance stamping
            let admissions = buildAdmissions(
                rawOutput: rawOutput,
                identity: identity,
                contract: contract
            )

            // Validate output against contract
            if let violation = validateOutput(admissions: admissions, contract: contract) {
                let record = FailureRecord(
                    producerIdentity: identity,
                    scope: ticket.scope,
                    category: .invalidOutput,
                    diagnostic: violation,
                    isRetryEligible: false
                )
                failureRecords.append(record)
                logger.error("Output validation failed for \(id): \(violation)")
                return .failed(record)
            }

            // Changed output detection (DDS-003 R6)
            let scopeWindowId = ScopeWindowIdentifier.from(ticket.scope)
            let priorKey = PriorOutputKey(producerId: id, scopeWindow: scopeWindowId)
            let changeReport = detectChanges(
                newAdmissions: admissions,
                priorKey: priorKey
            )

            // Update prior output record
            priorOutputs[priorKey] = PriorOutputSummary(from: admissions)

            // Commit to DIR if there are admissions
            if !admissions.isEmpty {
                let transaction = WriteTransaction(admissions: admissions)
                let writeResult = await dirWrite.submit(transaction)

                switch writeResult {
                case .committed:
                    break
                case .rejected(let rejection):
                    let record = FailureRecord(
                        producerIdentity: identity,
                        scope: ticket.scope,
                        category: .dirWriteFailure,
                        diagnostic: "DIR rejected write: \(rejection.failures.count) failures",
                        isRetryEligible: true
                    )
                    failureRecords.append(record)
                    logger.error("DIR write rejected for \(id)")
                    return .failed(record)
                }
            }

            let duration = ContinuousClock.now - startTime
            let report = ExecutionReport(
                producerIdentity: identity,
                scope: ticket.scope,
                changeReport: changeReport,
                outputUnitCount: admissions.count,
                inputUnitCount: 0, // Updated by pass execution path
                duration: duration
            )

            logger.info("Completed \(id): \(admissions.count) units, \(changeReport)")
            return .completed(report)

        } catch {
            let duration = ContinuousClock.now - startTime
            let category: FailureCategory
            let isRetryEligible: Bool

            if Task.isCancelled {
                // Cancellation — not a failure per DDS-003
                logger.info("Cancelled \(id) after \(duration)")
                let record = FailureRecord(
                    producerIdentity: identity,
                    scope: ticket.scope,
                    category: .executionError,
                    diagnostic: "Cancelled",
                    isRetryEligible: true
                )
                return .failed(record)
            }

            if case .pass(let pc) = contract, pc.executionStrategy == .semantic {
                category = .aiServiceUnavailable
                isRetryEligible = true
            } else {
                category = .executionError
                isRetryEligible = contract.kind == .pass
                    ? (contract.outputContract.tierRange.upperBound <= .t1)
                    : true
            }

            let record = FailureRecord(
                producerIdentity: identity,
                scope: ticket.scope,
                category: category,
                diagnostic: String(describing: error),
                isRetryEligible: isRetryEligible
            )
            failureRecords.append(record)
            logger.error("Failed \(id): \(error)")
            return .failed(record)
        }
    }

    // MARK: — Frontend Execution

    private func executeFrontend(
        id: ProducerIdentifier,
        contract: FrontendContract,
        scope: ExecutionScope
    ) async throws -> [RawOutputRecord] {
        guard let frontend = frontendImplementations[id] else {
            throw ProducerError.producerNotFound(id)
        }

        let filePaths: [String]
        switch scope {
        case .file(let path): filePaths = [path]
        case .files(let paths): filePaths = Array(paths)
        default: filePaths = []
        }

        var allOutput: [RawOutputRecord] = []
        for path in filePaths {
            // Filter by supported formats
            let ext = (path as NSString).pathExtension
            guard contract.sourceFormats.contains(ext) else { continue }

            do {
                let output = try await frontend.parse(
                    filePath: path,
                    identity: contract.identity,
                    outputContract: contract.outputContract
                )
                allOutput.append(contentsOf: output)
            } catch {
                // FM-7: source inaccessible — record failure but continue
                let record = FailureRecord(
                    producerIdentity: contract.identity,
                    scope: .file(path: path),
                    category: .sourceInaccessible,
                    diagnostic: "Failed to parse \(path): \(error)",
                    isRetryEligible: true
                )
                failureRecords.append(record)
                logger.warning("Frontend \(id) failed for \(path): \(error)")
            }
        }

        return allOutput
    }

    // MARK: — Pass Execution

    private func executePass(
        id: ProducerIdentifier,
        contract: PassContract,
        scope: ExecutionScope
    ) async throws -> [RawOutputRecord] {
        guard let pass = passImplementations[id] else {
            throw ProducerError.producerNotFound(id)
        }

        // Input assembly (DDS-003 R1, R2)
        let inputSet = await assembleInput(contract: contract)

        // Build execution context (DDS-003 R3)
        let scopeWindow = ScopeWindow(
            entities: Set(),
            identifier: ScopeWindowIdentifier.from(scope)
        )

        let budget: SemanticBudget?
        if contract.executionStrategy == .semantic {
            budget = SemanticBudget(
                remainingInvocations: 100,
                inferenceMethod: "default"
            )
        } else {
            budget = nil
        }

        let context = ExecutionContext(
            inputSet: inputSet,
            scopeWindow: scopeWindow,
            passIdentity: contract.identity,
            outputContract: contract.outputContract,
            budget: budget
        )

        // Execute (DDS-003 R4)
        return try await pass.execute(context: context)
    }

    // MARK: — Input Assembly

    /// Assembles the input set for a pass from the DIR.
    ///
    /// DDS-003 R1: Queries DIR for units matching the pass's input contract.
    private func assembleInput(contract: PassContract) async -> [AtomicUnit] {
        let allUnits = await dirRead.activeUnits()
        return allUnits.filter { unit in
            contract.inputContract.predicates.contains(unit.predicate)
            && contract.inputContract.tiers.contains(unit.tier)
        }
    }

    // MARK: — Output Pipeline

    /// Stamps provenance and builds UnitAdmissions from raw output.
    ///
    /// DDS-003 R5: Provenance stamping, grounding chain construction.
    private func buildAdmissions(
        rawOutput: [RawOutputRecord],
        identity: ProducerIdentity,
        contract: ProducerContract
    ) -> [UnitAdmission] {
        let method: ProductionMethod
        switch contract {
        case .frontend: method = .extraction
        case .pass(let pc):
            method = pc.executionStrategy == .deterministic ? .derivation : .inference
        }

        return rawOutput.map { record in
            let provenance = ProvenanceRecord(
                producer: identity.identifier.name,
                method: method,
                timestamp: Date(),
                inputUnitIds: []
            )

            let grounding: GroundingChain
            if let inferenceMethod = record.inferenceMethod {
                grounding = .inferred(
                    inputUnits: record.groundingRefs,
                    method: inferenceMethod
                )
            } else if record.groundingRefs.isEmpty {
                grounding = .direct(SourcePosition(
                    filePath: "",
                    startLine: 0,
                    endLine: 0,
                    fileVersion: ContentHash(bytes: Array(repeating: 0, count: 32))
                ))
            } else {
                grounding = .derived(record.groundingRefs)
            }

            return UnitAdmission(
                subject: record.subject,
                predicate: record.predicate,
                value: record.value,
                tier: record.tier,
                provenance: provenance,
                confidence: record.confidence,
                grounding: grounding,
                version: record.version
            )
        }
    }

    /// Validates output admissions against the producer's contract.
    ///
    /// DDS-001 R4: Returns nil if valid, or a diagnostic string if invalid.
    private func validateOutput(
        admissions: [UnitAdmission],
        contract: ProducerContract
    ) -> String? {
        let outputContract = contract.outputContract
        for admission in admissions {
            if !outputContract.predicates.contains(admission.predicate) {
                return "Undeclared predicate: \(admission.predicate)"
            }
            if !outputContract.tierRange.contains(admission.tier) {
                return "Tier \(admission.tier) outside declared range \(outputContract.tierRange)"
            }
        }
        return nil
    }

    // MARK: — Changed Output Detection

    /// Compares new output against prior output for the same scope.
    ///
    /// DDS-003 PC-3 / R6: Canonical DIR equality comparison.
    private func detectChanges(
        newAdmissions: [UnitAdmission],
        priorKey: PriorOutputKey
    ) -> ChangeReport {
        guard let prior = priorOutputs[priorKey] else {
            return .firstInvocation
        }

        let newKeys = Set(newAdmissions.map { OutputComparisonKey(from: $0) })

        if newKeys == prior.entries {
            return .noChange
        }

        let added = newKeys.subtracting(prior.entries).count
        let removed = prior.entries.subtracting(newKeys).count
        let modified = 0 // Simplified — full comparison would match by supersession key

        return .changed(ChangeDetail(
            addedCount: added,
            removedCount: removed,
            modifiedCount: modified
        ))
    }

    // MARK: — DAG Management

    private func rebuildDAG() throws {
        let result = PassDAG.build(from: contracts)
        switch result {
        case .success(let newDAG):
            dag = newDAG
        case .failure(let error):
            switch error {
            case .cycle(let path):
                throw ProducerError.dagCycle(path.first ?? ProducerIdentifier(name: "unknown"), cyclePath: path)
            case .missingDependency(let producer, let dep):
                throw ProducerError.invalidContract(producer, reason: "Missing dependency: \(dep)")
            }
        }
    }

    // MARK: — State Management

    private func transitionState(to target: ProducerRuntimeState) {
        let current = state
        guard current.canTransition(to: target) else {
            logger.warning("Invalid state transition: \(current.rawValue) → \(target.rawValue)")
            return
        }
        state = target
        logger.debug("State transition: \(current.rawValue) → \(target.rawValue)")
    }

    // MARK: — Deferred Registrations

    private func processDeferredRegistrations() async {
        guard !deferredRegistrations.isEmpty else { return }
        let deferred = deferredRegistrations
        deferredRegistrations.removeAll()

        for contract in deferred {
            do {
                _ = try await register(contract)
            } catch {
                logger.error("Deferred registration failed for \(contract.identity.identifier): \(error)")
            }
        }
    }

    // MARK: — Contract Validation

    /// Validates a producer contract for structural correctness.
    ///
    /// DDS-001 PC-1: Returns nil if valid, or a diagnostic string if invalid.
    private func validateContract(_ contract: ProducerContract) -> String? {
        switch contract {
        case .frontend(let fc):
            if fc.sourceFormats.isEmpty {
                return "Frontend must declare at least one source format"
            }
            if fc.outputContract.predicates.isEmpty {
                return "Frontend must declare at least one output predicate"
            }
            // Frontends must produce T0
            if fc.outputContract.tierRange.lowerBound != .t0 {
                return "Frontend must produce T0 output"
            }

        case .pass(let pc):
            if pc.inputContract.predicates.isEmpty {
                return "Pass must declare at least one input predicate"
            }
            if pc.outputContract.predicates.isEmpty {
                return "Pass must declare at least one output predicate"
            }
            // Deterministic passes must produce T0 or T1
            if pc.executionStrategy == .deterministic
                && pc.outputContract.tierRange.lowerBound > .t1 {
                return "Deterministic pass cannot produce T2 output"
            }
            // Semantic passes must produce T2
            if pc.executionStrategy == .semantic
                && pc.outputContract.tierRange.upperBound < .t2 {
                return "Semantic pass must produce T2 output"
            }
            // Deterministic passes must be idempotent (DAS-006 PC-IDEM-1)
            if pc.executionStrategy == .deterministic && !pc.isIdempotent {
                return "Deterministic pass must be idempotent"
            }
        }
        return nil
    }

    // MARK: — Query (for internal use)

    /// Returns the current runtime state.
    var currentState: ProducerRuntimeState { state }
}

// MARK: — Prior Output Key

/// Key for looking up prior output records.
struct PriorOutputKey: Hashable, Sendable {
    let producerId: ProducerIdentifier
    let scopeWindow: ScopeWindowIdentifier
}

// MARK: — ChangeReport description

extension ChangeReport: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noChange: return "no change"
        case .changed(let d): return "changed (+\(d.addedCount) -\(d.removedCount) ~\(d.modifiedCount))"
        case .firstInvocation: return "first invocation"
        }
    }
}
