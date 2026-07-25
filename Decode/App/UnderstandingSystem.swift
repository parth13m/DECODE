// UnderstandingSystem.swift — Decode App
// IAG-001 §6: Composition root for the understanding pipeline.
// IAG-003 §4.1: Startup sequence. §4.2: Shutdown sequence.
// IAG-004 §7: Phase 5 deliverable.

import Foundation
import DIRCore
import ProducerRuntime
import IndexRuntime
import RetrievalRuntime
import ContextAssembly
import ConsumerRuntime
import UpdateEngine
import StorageEngine

// MARK: - DIRAccessForwarder

/// Breaks the circular construction dependency between UpdateActor and its consumers.
///
/// ProducerActor, StorageActor, and IndexActor require DIRReadAccess/DIRWriteAccess
/// (implemented by UpdateActor) at construction time. UpdateActor requires protocols
/// from ProducerActor and StorageActor at construction time. This forwarder is created
/// first, injected into the consumer modules, then resolved to the real UpdateActor
/// after all modules are constructed.
///
/// Justification for @unchecked Sendable: Internal mutable state (_readAccess,
/// _writeAccess) is protected by NSLock. After resolve() is called during synchronous
/// construction (before any async work begins), the references are effectively immutable.
/// Same pattern as ContextAssemblyService (Decision #13/#17).
final class DIRAccessForwarder: DIRReadAccess, DIRWriteAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var _readAccess: (any DIRReadAccess)?
    private var _writeAccess: (any DIRWriteAccess)?

    func resolve(read: any DIRReadAccess, write: any DIRWriteAccess) {
        lock.lock()
        defer { lock.unlock() }
        precondition(_readAccess == nil, "DIRAccessForwarder already resolved")
        _readAccess = read
        _writeAccess = write
    }

    private var readAccess: any DIRReadAccess {
        lock.lock()
        defer { lock.unlock() }
        guard let access = _readAccess else {
            preconditionFailure("DIRAccessForwarder used before resolve()")
        }
        return access
    }

    private var writeAccess: any DIRWriteAccess {
        lock.lock()
        defer { lock.unlock() }
        guard let access = _writeAccess else {
            preconditionFailure("DIRAccessForwarder used before resolve()")
        }
        return access
    }

    // MARK: - DIRReadAccess

    func unit(for id: UnitIdentifier) async -> AtomicUnit? {
        await readAccess.unit(for: id)
    }

    func activeUnits() async -> [AtomicUnit] {
        await readAccess.activeUnits()
    }

    func invalidatedUnits() async -> [AtomicUnit] {
        await readAccess.invalidatedUnits()
    }

    func allUnits() async -> [AtomicUnit] {
        await readAccess.allUnits()
    }

    func activeUnit(for key: SupersessionKey) async -> AtomicUnit? {
        await readAccess.activeUnit(for: key)
    }

    var committedEpoch: Epoch {
        get async { await readAccess.committedEpoch }
    }

    // MARK: - DIRWriteAccess

    func submit(_ transaction: WriteTransaction) async -> WriteTransactionResult {
        await writeAccess.submit(transaction)
    }
}

// MARK: - UnderstandingSystem

/// Composition root for the understanding pipeline.
///
/// IAG-001 §6: Two responsibilities — construction and wiring.
/// All 8 pipeline modules are created in dependency order and wired via
/// protocol-typed constructor injection (IAG-001 §7, IR-1 through IR-5).
///
/// Exposes lifecycle entry points (start, shutdown) that delegate to
/// subsystem state transitions. Does not contain business logic,
/// scheduling decisions, or runtime policy (IAG-001 §6 prohibitions).
///
/// IAG-003 RI-1: Exactly one UpdateActor instance exists — owned here.
/// IAG-003 RI-5: Startup ordering is total — start() enforces sequence.
/// IAG-003 RI-6: Shutdown ordering is total — shutdown() enforces sequence.
public final class UnderstandingSystem: Sendable {

    // MARK: - Module Instances (IAG-001 §6 Ownership Chain)

    let storageActor: StorageActor
    let updateActor: UpdateActor
    let producerActor: ProducerActor
    let indexActor: IndexActor
    let retrievalService: RetrievalService
    let contextAssemblyService: ContextAssemblyService
    let consumerActor: ConsumerActor

    // MARK: - Public Protocol Accessors

    /// Consumer invocation — the primary query entry point (DDS-009:PC-1).
    public var consumerInvocation: any ConsumerInvocation { consumerActor }

    /// Reasoning engine management — register engines for purposes (DDS-009:PC-2/PC-3).
    public var engineManagement: any ReasoningEngineManagement { consumerActor }

    /// Producer registration — register frontends and passes (DDS-001:PC-1).
    public var producerRegistry: any ProducerRegistry { producerActor }

    /// Evidence retrieval — stateless query pipeline (DDS-005:PC-1).
    public var evidenceRetrieval: any EvidenceRetrieval { retrievalService }

    /// Context assembly — strategy-based context frame construction (DDS-006:PC-1).
    public var contextAssembly: any ContextAssembling { contextAssemblyService }

    /// Strategy management — register context strategies (DDS-006:PC-2/PC-3).
    public var strategyManagement: any StrategyManagement { contextAssemblyService }

    // MARK: - Initialization

    /// Creates the understanding pipeline with all modules wired.
    ///
    /// IAG-001 §6: Construction in dependency order. IAG-001 §7: Protocol-typed injection.
    /// The circular dependency between UpdateActor and ProducerActor/StorageActor/IndexActor
    /// is broken by DIRAccessForwarder, which is resolved before any async work begins.
    ///
    /// - Parameter snapshotDirectory: Directory for snapshot persistence (DDS-008).
    public init(snapshotDirectory: URL) {
        // Break circular dependency: UpdateActor ↔ ProducerActor/StorageActor/IndexActor.
        // All three need DIRReadAccess/DIRWriteAccess (from UpdateActor) at construction,
        // but UpdateActor needs protocols from ProducerActor and StorageActor.
        let dirForwarder = DIRAccessForwarder()

        // Create modules that need DIR access (they receive the forwarder).
        let producer = ProducerActor(dirRead: dirForwarder, dirWrite: dirForwarder)
        let storage = StorageActor(
            dirRead: dirForwarder,
            dirWrite: dirForwarder,
            snapshotDirectory: snapshotDirectory
        )
        let index = IndexActor(dirRead: dirForwarder)

        // Create UpdateActor with real protocol references from ProducerActor and StorageActor.
        let update = UpdateActor(
            executionDirective: producer,
            producerRegistry: producer,
            failureReportSource: producer,
            indexBatchUpdate: index,
            snapshotPersistence: storage,
            garbageCollector: storage,
            groundingMapAccess: storage,
            contentHashMapAccess: storage,
            deferredQueuePersistence: storage,
            changeBatchObserver: storage
        )

        // Resolve forwarder — all DIR access now routes through real UpdateActor.
        dirForwarder.resolve(read: update, write: update)

        // Store write pipeline actors.
        self.storageActor = storage
        self.updateActor = update
        self.producerActor = producer
        self.indexActor = index

        // Create read pipeline (no circular dependencies).
        self.retrievalService = RetrievalService(
            indexQuerying: index,
            indexFreshness: index,
            dirAccess: update
        )
        self.contextAssemblyService = ContextAssemblyService()
        self.consumerActor = ConsumerActor(demandSignalSink: update)
    }

    // MARK: - Lifecycle

    /// Starts the understanding pipeline.
    ///
    /// IAG-003 §4.1: 10-step startup sequence.
    /// All actors reach operational state before this method returns.
    /// Steps 1 (StorageActor) and 2-7 (module creation) occur in init().
    /// This method executes the async lifecycle: snapshot load, concurrent
    /// index/map construction, consumer activation, and reconciliation.
    public func start() async {
        // Step 2 (async portion): Load snapshot → populate unit store.
        await updateActor.loadFromSnapshot()

        // Steps 2c-4 + Step 8: MapBuilding and IndexConstruction run concurrently.
        // Both read the unit store via DIRReadAccess without writing.
        async let mapBuild: Void = storageActor.constructGroundingMap()
        async let indexBuild: Void = indexActor.constructAll()
        _ = await (mapBuild, indexBuild)

        // Step 7: Activate ConsumerRuntime.
        await consumerActor.activate()

        // Step 9: Reconciliation — validates deferred queue, processes pending changes.
        await updateActor.reconcile()
        await updateActor.completeReconciliation()

        // Step 10: Pipeline is operational.
    }

    /// Shuts down the understanding pipeline.
    ///
    /// IAG-003 §4.2: 8-step shutdown sequence following DDS destruction ordering.
    /// Consumer → Context → Retrieval → Index → Update → Storage.
    /// No step may be skipped (DDS-008:RI-1).
    public func shutdown() async {
        // Step 2: ConsumerActor quiesces — completes in-progress invocations.
        await consumerActor.shutdown()

        // Steps 3-4: Context and Retrieval are stateless — no shutdown needed.

        // Step 5: IndexActor quiesces — completes in-progress queries.
        await indexActor.shutdown()

        // Step 6: UpdateActor quiesces — stops accepting change sets,
        // completes current pipeline, requests final snapshot.
        await updateActor.shutdown()

        // Step 7: StorageActor quiesces — completes final snapshot write.
        await storageActor.shutdown()
    }

    // MARK: - Write Pipeline Entry Point

    /// Processes file changes through the write pipeline.
    ///
    /// Entry point for file system monitoring (Phase 6: Application Integration).
    /// Delegates to UpdateActor.processChangeSet for the 8-stage synchronous pipeline.
    ///
    /// Qualified types avoid collision with Decode app's own FileChangeEvent.
    public func processChanges(_ events: [UpdateEngine.FileChangeEvent]) async -> UpdateEngine.ChangeSetResult {
        await updateActor.processChangeSet(UpdateEngine.ChangeSet(events: events))
    }

    // MARK: - Frontend Registration Bridge

    /// Registers a frontend producer using a closure-based handler.
    ///
    /// IAG-004 §18: Public bridge for product code to register frontends
    /// without depending on ProducerRuntime's internal `FrontendDefinition` protocol.
    /// Delegates to `ProducerActor.registerFrontendHandler`.
    ///
    /// - Parameters:
    ///   - contract: The frontend's declared contract (identity, source formats, output contract).
    ///   - handler: A Sendable closure that parses a file and returns `FrontendOutput` records.
    /// - Returns: The registration result.
    public func registerFrontendHandler(
        _ contract: FrontendContract,
        handler: @escaping @Sendable (
            _ filePath: String,
            _ identity: ProducerIdentity,
            _ outputContract: OutputContract
        ) async throws -> [FrontendOutput]
    ) async throws -> RegistrationResult {
        try await producerActor.registerFrontendHandler(contract, handler: handler)
    }

    // MARK: - Pass Registration Bridge

    /// Registers a pass producer using a closure-based handler.
    ///
    /// IAG-004 §18: Public bridge for product code to register passes
    /// without depending on ProducerRuntime's internal `PassDefinition` protocol.
    /// Delegates to `ProducerActor.registerPassHandler`.
    ///
    /// - Parameters:
    ///   - contract: The pass's declared contract (identity, input/output contracts, scope, etc.).
    ///   - handler: A Sendable closure that executes the pass and returns `PassOutput` records.
    /// - Returns: The registration result.
    public func registerPassHandler(
        _ contract: PassContract,
        handler: @escaping @Sendable (
            _ inputSet: [AtomicUnit],
            _ scopeWindow: ScopeWindow,
            _ passIdentity: ProducerIdentity,
            _ outputContract: OutputContract,
            _ existingScopeEntity: EntityReference?
        ) async throws -> [PassOutput]
    ) async throws -> RegistrationResult {
        try await producerActor.registerPassHandler(contract, handler: handler)
    }
}
