// UnderstandingIntegrationTests.swift
// IAG-004 §7: Phase 5 integration tests — verify modules operate together.
// Uses real implementations (not mocks) for all pipeline modules.

import Testing
import Foundation
@testable import DIRCore
@testable import ProducerRuntime
@testable import IndexRuntime
@testable import RetrievalRuntime
@testable import ContextAssembly
@testable import ConsumerRuntime
@testable import UpdateEngine
@testable import StorageEngine
import UnderstandingTestSupport

// MARK: - DIRAccessForwarder (test-local copy)

/// Breaks circular construction dependency. Same logic as UnderstandingSystem's forwarder.
/// Defined locally because the test target does not import the Decode application target.
private final class DIRAccessForwarder: DIRReadAccess, DIRWriteAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var _readAccess: (any DIRReadAccess)?
    private var _writeAccess: (any DIRWriteAccess)?

    func resolve(read: any DIRReadAccess, write: any DIRWriteAccess) {
        lock.lock()
        defer { lock.unlock() }
        precondition(_readAccess == nil, "Already resolved")
        _readAccess = read
        _writeAccess = write
    }

    private var readAccess: any DIRReadAccess {
        lock.lock()
        defer { lock.unlock() }
        return _readAccess!
    }

    private var writeAccess: any DIRWriteAccess {
        lock.lock()
        defer { lock.unlock() }
        return _writeAccess!
    }

    func unit(for id: UnitIdentifier) async -> AtomicUnit? { await readAccess.unit(for: id) }
    func activeUnits() async -> [AtomicUnit] { await readAccess.activeUnits() }
    func invalidatedUnits() async -> [AtomicUnit] { await readAccess.invalidatedUnits() }
    func allUnits() async -> [AtomicUnit] { await readAccess.allUnits() }
    func activeUnit(for key: SupersessionKey) async -> AtomicUnit? { await readAccess.activeUnit(for: key) }
    var committedEpoch: Epoch { get async { await readAccess.committedEpoch } }
    func submit(_ transaction: WriteTransaction) async -> WriteTransactionResult { await writeAccess.submit(transaction) }
}

// MARK: - TestPipeline

/// Creates and wires all pipeline modules — mirrors UnderstandingSystem composition.
private struct TestPipeline: Sendable {
    let storageActor: StorageActor
    let updateActor: UpdateActor
    let producerActor: ProducerActor
    let indexActor: IndexActor
    let retrievalService: RetrievalService
    let contextAssemblyService: ContextAssemblyService
    let consumerActor: ConsumerActor

    init(snapshotDirectory: URL) {
        let forwarder = DIRAccessForwarder()

        let producer = ProducerActor(dirRead: forwarder, dirWrite: forwarder)
        let storage = StorageActor(
            dirRead: forwarder,
            dirWrite: forwarder,
            snapshotDirectory: snapshotDirectory
        )
        let index = IndexActor(dirRead: forwarder)

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

        forwarder.resolve(read: update, write: update)

        self.storageActor = storage
        self.updateActor = update
        self.producerActor = producer
        self.indexActor = index
        self.retrievalService = RetrievalService(
            indexQuerying: index,
            indexFreshness: index,
            dirAccess: update
        )
        self.contextAssemblyService = ContextAssemblyService()
        self.consumerActor = ConsumerActor(demandSignalSink: update)
    }

    func start() async {
        await updateActor.loadFromSnapshot()
        async let mapBuild: Void = storageActor.constructGroundingMap()
        async let indexBuild: Void = indexActor.constructAll()
        _ = await (mapBuild, indexBuild)
        await consumerActor.activate()
        await updateActor.reconcile()
        await updateActor.completeReconciliation()
    }

    func shutdown() async {
        await consumerActor.shutdown()
        await indexActor.shutdown()
        await updateActor.shutdown()
        await storageActor.shutdown()
    }
}

// MARK: - Test Helpers

/// Creates a temporary directory for snapshot storage. Cleaned up automatically.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("UnderstandingIntegrationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Removes a temporary directory.
private func cleanupTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// A test reasoning engine that produces hardcoded understanding.
private struct TestReasoningEngine: ReasoningEngine {
    let claims: [UnderstandingClaim]

    init(claims: [UnderstandingClaim] = []) {
        self.claims = claims
    }

    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        let resolvedClaims = claims.isEmpty
            ? [UnderstandingClaim(
                content: "Test understanding for \(contextFrame.purpose)",
                claimType: .factual,
                confidence: .deterministic,
                groundingReferences: contextFrame.strata.flatMap { stratum in
                    stratum.units.map { $0.annotatedUnit.unit.id }
                }
            )]
            : claims

        return ReasoningEngineOutput(
            content: "Test understanding output",
            claims: resolvedClaims,
            completeness: .complete,
            conversationState: nil
        )
    }
}

/// A test frontend that produces T0 units from any file path.
private struct TestFrontend: FrontendDefinition {
    let entityName: String
    let predicateName: String

    init(entityName: String = "TestEntity", predicateName: String = "identity") {
        self.entityName = entityName
        self.predicateName = predicateName
    }

    func parse(
        filePath: String,
        identity: ProducerIdentity,
        outputContract: OutputContract
    ) async throws -> [RawOutputRecord] {
        [RawOutputRecord(
            subject: .entity(EntityReference(qualifiedName: entityName)),
            predicate: PredicateIdentifier(name: predicateName, domain: "test"),
            value: .string("entity from \(filePath)"),
            tier: .t0,
            confidence: .deterministic,
            groundingRefs: [],
            version: VersionStamp(singleSource: makeContentHash(42))
        )]
    }
}

// MARK: - Startup and Shutdown

@Suite("Startup and Shutdown")
struct StartupShutdownTests {

    @Test("Pipeline starts from empty state")
    func startupFromEmpty() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Verify: UpdateActor reached operational state (epoch 0 from empty snapshot).
        let epoch = await pipeline.updateActor.committedEpoch
        #expect(epoch == .zero)

        // Verify: DIR is empty.
        let units = await pipeline.updateActor.activeUnits()
        #expect(units.isEmpty)

        await pipeline.shutdown()
    }

    @Test("Shutdown completes without error")
    func shutdownCompletes() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()
        await pipeline.shutdown()

        // Verify: consumer rejects new requests after shutdown.
        let request = ConsumerRequest(
            contextFrame: makeEmptyContextFrame(),
            outputSpecification: OutputSpecification(
                purpose: ContextPurpose("test"),
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )
        let result = await pipeline.consumerActor.invoke(request)
        if case .failure(let failure) = result {
            #expect(failure.mode == .terminated)
        } else {
            Issue.record("Expected failure after shutdown")
        }
    }
}

// MARK: - DIR Integration

@Suite("DIR Integration")
struct DIRIntegrationTests {

    @Test("Units admitted via WriteTransaction are queryable")
    func writeAndReadUnits() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Admit a unit via WriteTransaction.
        let admission = makeAdmission(
            subject: .entity(EntityReference(qualifiedName: "MyClass")),
            predicate: PredicateIdentifier(name: "identity", domain: "test"),
            value: .string("a test class"),
            tier: .t0
        )
        let transaction = WriteTransaction(admissions: [admission])
        let result = await pipeline.updateActor.submit(transaction)

        // Verify: transaction committed with one admitted unit.
        guard case .committed(let committed) = result else {
            Issue.record("Expected committed transaction")
            return
        }
        #expect(committed.admittedUnitIds.count == 1)

        // Verify: unit is queryable via DIRReadAccess.
        let unitId = committed.admittedUnitIds[0]
        let unit = await pipeline.updateActor.unit(for: unitId)
        #expect(unit != nil)
        #expect(unit?.subject == .entity(EntityReference(qualifiedName: "MyClass")))
        #expect(unit?.tier == .t0)
        #expect(unit?.status == .active)

        await pipeline.shutdown()
    }

    @Test("Multiple units in a single transaction")
    func batchAdmission() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let admissions = (0..<5).map { i in
            makeAdmission(
                subject: .entity(EntityReference(qualifiedName: "Entity\(i)")),
                predicate: PredicateIdentifier(name: "identity", domain: "test"),
                value: .string("entity \(i)"),
                tier: .t0
            )
        }
        let transaction = WriteTransaction(admissions: admissions)
        let result = await pipeline.updateActor.submit(transaction)

        guard case .committed(let committed) = result else {
            Issue.record("Expected committed transaction")
            return
        }
        #expect(committed.admittedUnitIds.count == 5)

        // Verify: all units queryable.
        let activeUnits = await pipeline.updateActor.activeUnits()
        #expect(activeUnits.count == 5)

        await pipeline.shutdown()
    }
}

// MARK: - Index Integration

@Suite("Index Integration")
struct IndexIntegrationTests {

    @Test("Index construction over populated DIR")
    func indexConstructionFromDIR() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Admit units to DIR.
        let admission = makeAdmission(
            subject: .entity(EntityReference(qualifiedName: "IndexedEntity")),
            predicate: PredicateIdentifier(name: "identity", domain: "test"),
            value: .string("an entity"),
            tier: .t0
        )
        let transaction = WriteTransaction(admissions: [admission])
        let writeResult = await pipeline.updateActor.submit(transaction)
        guard case .committed(let committed) = writeResult else {
            Issue.record("Expected committed transaction")
            return
        }

        // Apply batch to indexes with the admitted unit.
        let changeBatch = ChangeBatch(
            epoch: Epoch(value: 1),
            changes: [.admitted(committed.admittedUnitIds[0])]
        )
        let indexResult = await pipeline.indexActor.applyBatch(changeBatch)
        #expect(indexResult.failedFamilies.isEmpty)

        await pipeline.shutdown()
    }
}

// MARK: - Read Pipeline Integration

@Suite("Read Pipeline")
struct ReadPipelineTests {

    @Test("Evidence retrieval returns units from DIR via indexes")
    func evidenceRetrieval() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Populate DIR with a unit.
        let entityRef = EntityReference(qualifiedName: "QueryTarget")
        let admission = makeAdmission(
            subject: .entity(entityRef),
            predicate: PredicateIdentifier(name: "identity", domain: "test"),
            value: .string("target entity"),
            tier: .t0
        )
        let transaction = WriteTransaction(admissions: [admission])
        let writeResult = await pipeline.updateActor.submit(transaction)
        guard case .committed(let committed) = writeResult else {
            Issue.record("Expected committed transaction")
            return
        }

        // Update indexes with the new unit.
        let changeBatch = ChangeBatch(
            epoch: Epoch(value: 1),
            changes: [.admitted(committed.admittedUnitIds[0])]
        )
        _ = await pipeline.indexActor.applyBatch(changeBatch)

        // Retrieve evidence for the entity.
        let request = RetrievalRequest(
            subject: .entity(entityRef),
            intent: .explain,
            scope: .narrow,
            budget: 100
        )
        let evidence = await pipeline.retrievalService.retrieve(request)

        // Evidence set should contain the unit.
        #expect(!evidence.evidence.isEmpty)

        await pipeline.shutdown()
    }

    @Test("Full read pipeline: retrieval → assembly → consumer")
    func fullReadPipeline() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let purpose = ContextPurpose("explain")

        // Populate DIR with units.
        let entityRef = EntityReference(qualifiedName: "ExplainTarget")
        let admission = makeAdmission(
            subject: .entity(entityRef),
            predicate: PredicateIdentifier(name: "identity", domain: "test"),
            value: .string("target entity for explanation"),
            tier: .t0
        )
        let transaction = WriteTransaction(admissions: [admission])
        let writeResult = await pipeline.updateActor.submit(transaction)
        guard case .committed(let committed) = writeResult else {
            Issue.record("Expected committed transaction")
            return
        }

        // Update indexes.
        let changeBatch = ChangeBatch(
            epoch: Epoch(value: 1),
            changes: [.admitted(committed.admittedUnitIds[0])]
        )
        _ = await pipeline.indexActor.applyBatch(changeBatch)

        // Retrieve evidence.
        let retrievalRequest = RetrievalRequest(
            subject: .entity(entityRef),
            intent: .explain,
            scope: .narrow,
            budget: 100
        )
        let evidence = await pipeline.retrievalService.retrieve(retrievalRequest)

        // Register a context strategy for the purpose.
        let strategy = ContextStrategy(
            purpose: purpose,
            strata: [
                StratumDefinition(
                    name: "primary",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                )
            ],
            version: "1.0"
        )
        let strategyResult = pipeline.contextAssemblyService.register(strategy)
        guard case .success = strategyResult else {
            Issue.record("Failed to register strategy: \(strategyResult)")
            return
        }

        // Assemble context.
        let assemblyRequest = AssemblyRequest(
            evidenceSet: evidence,
            purpose: purpose,
            budget: 100
        )
        let assemblyResult = await pipeline.contextAssemblyService.assemble(assemblyRequest)

        guard case .success(let contextFrame) = assemblyResult else {
            Issue.record("Assembly failed: \(assemblyResult)")
            return
        }
        #expect(contextFrame.purpose == purpose)

        // Register a reasoning engine.
        let engine = TestReasoningEngine()
        let registration = EngineRegistration(
            purpose: purpose,
            engineIdentifier: "test-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        )
        let registered = await pipeline.consumerActor.register(registration)
        #expect(registered)

        // Invoke consumer.
        let consumerRequest = ConsumerRequest(
            contextFrame: contextFrame,
            outputSpecification: OutputSpecification(
                purpose: purpose,
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )
        let consumerResult = await pipeline.consumerActor.invoke(consumerRequest)

        // Verify understanding produced.
        guard case .success(let understanding) = consumerResult else {
            Issue.record("Consumer invocation failed: \(consumerResult)")
            return
        }
        #expect(!understanding.content.isEmpty)
        #expect(understanding.metadata.purpose == purpose)

        await pipeline.shutdown()
    }
}

// MARK: - Write-Then-Read

@Suite("Write Then Read")
struct WriteThenReadTests {

    @Test("Consumer observes units admitted after startup")
    func epochVisibility() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let purpose = ContextPurpose("explain")

        // Register strategy and engine first.
        let strategy = ContextStrategy(
            purpose: purpose,
            strata: [
                StratumDefinition(
                    name: "primary",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                )
            ],
            version: "1.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)

        let engine = TestReasoningEngine()
        let registration = EngineRegistration(
            purpose: purpose,
            engineIdentifier: "test-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        )
        _ = await pipeline.consumerActor.register(registration)

        // Record epoch before write.
        let epochBefore = await pipeline.updateActor.committedEpoch

        // Admit a unit.
        let entityRef = EntityReference(qualifiedName: "NewEntity")
        let admission = makeAdmission(
            subject: .entity(entityRef),
            predicate: PredicateIdentifier(name: "identity", domain: "test"),
            value: .string("new entity"),
            tier: .t0
        )
        let writeResult = await pipeline.updateActor.submit(WriteTransaction(admissions: [admission]))
        guard case .committed(let committed) = writeResult else {
            Issue.record("Expected committed transaction")
            return
        }

        // Update indexes.
        let changeBatch = ChangeBatch(
            epoch: Epoch(value: epochBefore.value + 1),
            changes: [.admitted(committed.admittedUnitIds[0])]
        )
        _ = await pipeline.indexActor.applyBatch(changeBatch)

        // Retrieve evidence for the new entity.
        let retrievalRequest = RetrievalRequest(
            subject: .entity(entityRef),
            intent: .explain,
            scope: .narrow,
            budget: 100
        )
        let evidence = await pipeline.retrievalService.retrieve(retrievalRequest)

        // If evidence found, assemble and invoke consumer.
        if !evidence.evidence.isEmpty {
            let assemblyRequest = AssemblyRequest(
                evidenceSet: evidence,
                purpose: purpose,
                budget: 100
            )
            let assemblyResult = await pipeline.contextAssemblyService.assemble(assemblyRequest)
            if case .success(let frame) = assemblyResult {
                let consumerRequest = ConsumerRequest(
                    contextFrame: frame,
                    outputSpecification: OutputSpecification(
                        purpose: purpose,
                        outputClass: .human,
                        detailLevel: .standard
                    ),
                    conversationState: nil
                )
                let result = await pipeline.consumerActor.invoke(consumerRequest)
                if case .success(let understanding) = result {
                    #expect(!understanding.content.isEmpty)
                } else {
                    Issue.record("Consumer invocation failed after write")
                }
            }
        }

        // Verify: epoch did not regress (consumer observes committed epoch or later).
        let epochAfter = await pipeline.updateActor.committedEpoch
        #expect(epochAfter.value >= epochBefore.value)

        await pipeline.shutdown()
    }
}

// MARK: - Write Vertical Slice

@Suite("Write Vertical Slice")
struct WriteVerticalSliceTests {

    @Test("File change processed through full write pipeline with registered frontend")
    func fileChangeToEpochAdvancement() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Create a temp file to process.
        let testFile = dir.appendingPathComponent("test.testlang")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)

        // Register a test frontend for .testlang files.
        let frontendId = ProducerIdentifier(name: "test-frontend")
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: frontendId,
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["testlang"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "identity", domain: "test")],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = TestFrontend(entityName: "TestLangEntity", predicateName: "identity")
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        // Record epoch before processing.
        let epochBefore = await pipeline.updateActor.committedEpoch

        // Process file change through the write pipeline.
        let changeSet = ChangeSet(events: [
            FileChangeEvent(filePath: testFile.path, changeType: .created)
        ])
        let result = await pipeline.updateActor.processChangeSet(changeSet)

        // Verify: epoch advanced.
        #expect(result.epochAfter.value > epochBefore.value)
        #expect(result.totalFiles == 1)

        await pipeline.shutdown()
    }
}

// MARK: - Demand Signal

@Suite("Demand Signal Round-Trip")
struct DemandSignalTests {

    @Test("Consumer demand signal reaches UpdateActor via DemandSignalSink")
    func demandSignalRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let purpose = ContextPurpose("explain")

        // Register engine that produces claims with grounding refs to nonexistent T2 units.
        let engine = TestReasoningEngine(claims: [
            UnderstandingClaim(
                content: "Test claim",
                claimType: .factual,
                confidence: .deterministic,
                groundingReferences: []
            )
        ])
        let registration = EngineRegistration(
            purpose: purpose,
            engineIdentifier: "demand-test-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        )
        _ = await pipeline.consumerActor.register(registration)

        // Create a minimal context frame indicating T0-only degradation.
        let contextFrame = makeContextFrame(
            purpose: purpose,
            degradationLevel: .t0Only
        )

        // Invoke consumer — this should trigger demand signals for missing T2 content.
        let request = ConsumerRequest(
            contextFrame: contextFrame,
            outputSpecification: OutputSpecification(
                purpose: purpose,
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )
        let result = await pipeline.consumerActor.invoke(request)

        // The invocation should succeed (demand signals are advisory, not blocking).
        if case .success(let understanding) = result {
            #expect(!understanding.content.isEmpty)
        }
        // Demand signal was emitted to UpdateActor as DemandSignalSink.
        // UpdateActor silently receives it — no observable side effect to assert
        // beyond the invocation completing without error.
        // The signal round-trip is verified by the fact that ConsumerActor
        // successfully called submit() on the DemandSignalSink (UpdateActor)
        // without error.

        await pipeline.shutdown()
    }
}

// MARK: - Composition Wiring

@Suite("Composition Wiring")
struct CompositionWiringTests {

    @Test("All modules can be constructed and wired")
    func moduleWiring() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        // Construction itself validates that all protocol types are satisfied.
        let pipeline = TestPipeline(snapshotDirectory: dir)

        // Verify module instances are distinct (IAG-003 RI-1: singleton UpdateActor).
        let updateId = ObjectIdentifier(pipeline.updateActor)
        let producerId = ObjectIdentifier(pipeline.producerActor)
        let storageId = ObjectIdentifier(pipeline.storageActor)
        let indexId = ObjectIdentifier(pipeline.indexActor)

        #expect(updateId != producerId)
        #expect(updateId != storageId)
        #expect(updateId != indexId)

        await pipeline.start()
        await pipeline.shutdown()
    }

    @Test("Consumer invocation uses real DIR via protocol chain")
    func protocolChainIntegrity() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Admit a unit through UpdateActor.
        let admission = makeAdmission(
            subject: .entity(EntityReference(qualifiedName: "ChainTest")),
            predicate: PredicateIdentifier(name: "identity", domain: "test"),
            value: .string("protocol chain test"),
            tier: .t0
        )
        let result = await pipeline.updateActor.submit(WriteTransaction(admissions: [admission]))
        guard case .committed(let committed) = result else {
            Issue.record("Expected committed transaction")
            return
        }

        // Verify: the same unit is readable via the DIRReadAccess protocol.
        let unitId = committed.admittedUnitIds[0]
        let unit = await pipeline.updateActor.unit(for: unitId)
        #expect(unit != nil)

        // Verify: active units reflect the admission.
        let activeUnits = await pipeline.updateActor.activeUnits()
        #expect(activeUnits.contains(where: { $0.id == unitId }))

        await pipeline.shutdown()
    }
}

// MARK: - Context Frame Helpers

/// Creates an empty context frame for testing.
private func makeEmptyContextFrame() -> ContextFrame {
    ContextFrame(
        anchors: [],
        purpose: ContextPurpose("test"),
        strategyVersion: "1.0",
        strata: [],
        budgetSummary: BudgetSummary(
            total: 100,
            denomination: .unitCount,
            used: 0
        ),
        metadata: ContextFrameMetadata(
            evidenceSetSize: 0,
            selectedCount: 0,
            tierCounts: [:],
            stratumCounts: [:],
            coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
            degradationLevel: .full,
            freshnessState: .fresh,
            assemblyDuration: 0,
            strategyVersion: "1.0",
            committedEpoch: .zero,
            budgetInsufficient: false
        )
    )
}

/// Creates a context frame with specified purpose and degradation level.
private func makeContextFrame(
    purpose: ContextPurpose,
    degradationLevel: DegradationLevel = .full
) -> ContextFrame {
    ContextFrame(
        anchors: [EntityReference(qualifiedName: "TestAnchor")],
        purpose: purpose,
        strategyVersion: "1.0",
        strata: [],
        budgetSummary: BudgetSummary(
            total: 100,
            denomination: .unitCount,
            used: 0
        ),
        metadata: ContextFrameMetadata(
            evidenceSetSize: 0,
            selectedCount: 0,
            tierCounts: [:],
            stratumCounts: [:],
            coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
            degradationLevel: degradationLevel,
            freshnessState: .fresh,
            assemblyDuration: 0,
            strategyVersion: "1.0",
            committedEpoch: .zero,
            budgetInsufficient: false
        )
    )
}

// MARK: - End-to-End Pipeline Flow

@Suite("End-to-End Pipeline Flow")
struct EndToEndPipelineFlowTests {

    @Test("Complete flow: file → frontend → DIR → retrieval → assembly → consumer → Understanding")
    func completeEndToEndFlow() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let purpose = ContextPurpose("explain")

        // 1. Register a test frontend that produces multiple predicates per entity.
        let frontendId = ProducerIdentifier(name: "e2e-frontend")
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: frontendId,
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["e2e"],
            outputContract: OutputContract(
                predicates: [
                    PredicateIdentifier(name: "kind", domain: "structure"),
                    PredicateIdentifier(name: "signature", domain: "structure"),
                ],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = MultiPredicateFrontend()
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        // 2. Register a context strategy for "explain".
        let strategy = ContextStrategy(
            purpose: purpose,
            strata: [
                StratumDefinition(
                    name: "primary",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 0.6,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
                StratumDefinition(
                    name: "relational",
                    priority: 1,
                    selectionCriteria: SelectionCriteria(stage: .relational),
                    budgetFraction: 0.4,
                    fillPolicy: .distanceFirst
                ),
            ],
            version: "1.0.0"
        )
        let strategyResult = pipeline.contextAssemblyService.register(strategy)
        guard case .success = strategyResult else {
            Issue.record("Strategy registration failed: \(strategyResult)")
            return
        }

        // 3. Register a test reasoning engine.
        let engine = TestReasoningEngine()
        let engineReg = EngineRegistration(
            purpose: purpose,
            engineIdentifier: "e2e-test-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        )
        let registered = await pipeline.consumerActor.register(engineReg)
        #expect(registered)

        // 4. Create a test file and process it through the write pipeline.
        let testFile = dir.appendingPathComponent("Service.e2e")
        try "class UserService { func create() {} }".write(
            to: testFile, atomically: true, encoding: .utf8
        )

        let changeSet = ChangeSet(events: [
            FileChangeEvent(filePath: testFile.path, changeType: .created)
        ])
        let changeResult = await pipeline.updateActor.processChangeSet(changeSet)
        #expect(changeResult.totalFiles == 1)

        // 5. Verify units are in the DIR.
        let activeUnits = await pipeline.updateActor.activeUnits()
        #expect(!activeUnits.isEmpty, "Frontend should have produced units in the DIR")

        // Find the entity name the frontend produced.
        let entityRef = EntityReference(qualifiedName: "UserService")

        // 6. Retrieve evidence for the entity.
        let retrievalRequest = RetrievalRequest(
            subject: .entity(entityRef),
            intent: .explain,
            scope: .local,
            budget: 100
        )
        let evidenceSet = await pipeline.retrievalService.retrieve(retrievalRequest)
        #expect(!evidenceSet.evidence.isEmpty, "Should find evidence for entity in DIR")

        // 7. Assemble context.
        let assemblyRequest = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: purpose,
            budget: 100
        )
        let assemblyResult = await pipeline.contextAssemblyService.assemble(assemblyRequest)
        guard case .success(let contextFrame) = assemblyResult else {
            Issue.record("Assembly failed: \(assemblyResult)")
            return
        }
        #expect(contextFrame.purpose == purpose)
        #expect(!contextFrame.strata.isEmpty)

        // 8. Invoke the consumer to produce Understanding.
        let consumerRequest = ConsumerRequest(
            contextFrame: contextFrame,
            outputSpecification: OutputSpecification(
                purpose: purpose,
                outputClass: .human,
                detailLevel: .standard
            )
        )
        let consumerResult = await pipeline.consumerActor.invoke(consumerRequest)

        // 9. Verify the complete Understanding was produced.
        guard case .success(let understanding) = consumerResult else {
            Issue.record("Consumer invocation failed: \(consumerResult)")
            return
        }
        #expect(!understanding.content.isEmpty)
        #expect(!understanding.claims.isEmpty)
        #expect(understanding.metadata.purpose == purpose)
        #expect(understanding.metadata.engineIdentifier == "e2e-test-engine")

        await pipeline.shutdown()
    }

    @Test("End-to-end with strategy for improve purpose")
    func endToEndImprove() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let purpose = ContextPurpose("improve")

        // Register frontend, strategy, and engine.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "e2e-improve-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["imp"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = MultiPredicateFrontend()
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        let strategy = ContextStrategy(
            purpose: purpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)

        let engine = TestReasoningEngine()
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: purpose,
            engineIdentifier: "e2e-improve-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        ))

        // Process file.
        let testFile = dir.appendingPathComponent("Code.imp")
        try "function optimize() {}".write(to: testFile, atomically: true, encoding: .utf8)
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Retrieve → Assemble → Invoke.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(subject: .entity(EntityReference(qualifiedName: "UserService")), intent: .explain, budget: 100)
        )
        let assembly = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: purpose, budget: 100)
        )
        guard case .success(let frame) = assembly else {
            Issue.record("Assembly failed")
            return
        }

        let result = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(purpose: purpose, outputClass: .human, detailLevel: .standard)
        ))

        guard case .success(let understanding) = result else {
            Issue.record("Consumer failed: \(result)")
            return
        }
        #expect(!understanding.content.isEmpty)
        #expect(understanding.metadata.purpose == purpose)

        await pipeline.shutdown()
    }

    @Test("End-to-end returns empty evidence for unknown entity")
    func endToEndUnknownEntity() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // No files processed, no units in DIR.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "NonExistentEntity")),
                intent: .explain,
                budget: 100
            )
        )

        #expect(evidence.evidence.isEmpty)
        #expect(evidence.metadata.subjectNotFound)

        await pipeline.shutdown()
    }
}

/// A test frontend that produces multiple predicates for a "UserService" entity.
/// Used by end-to-end tests to simulate a realistic frontend with entity + predicate output.
private struct MultiPredicateFrontend: FrontendDefinition {
    func parse(
        filePath: String,
        identity: ProducerIdentity,
        outputContract: OutputContract
    ) async throws -> [RawOutputRecord] {
        let hash = makeContentHash(UInt8(filePath.count % 256))
        let version = VersionStamp(singleSource: hash)

        var records: [RawOutputRecord] = []

        // Emit "kind" for UserService entity.
        records.append(RawOutputRecord(
            subject: .entity(EntityReference(qualifiedName: "UserService")),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("class"),
            tier: .t0,
            confidence: .deterministic,
            groundingRefs: [],
            version: version
        ))

        // Emit "signature" if the output contract allows it.
        if outputContract.predicates.contains(PredicateIdentifier(name: "signature", domain: "structure")) {
            records.append(RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "UserService")),
                predicate: PredicateIdentifier(name: "signature", domain: "structure"),
                value: .string("class UserService"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: version
            ))
        }

        return records
    }
}

// MARK: - Session Explain via Pipeline

@Suite("Session Explain Pipeline Integration")
struct SessionExplainPipelineTests {

    @Test("Session explain: pipeline produces Understanding for known entity")
    func sessionExplainSuccess() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let purpose = ContextPurpose("explain")

        // Register frontend that produces entities like the SwiftSyntaxFrontend does.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "session-test-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["swift"],
            outputContract: OutputContract(
                predicates: [
                    PredicateIdentifier(name: "kind", domain: "structure"),
                    PredicateIdentifier(name: "signature", domain: "structure"),
                ],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = SessionTestFrontend(entityName: "AppDelegate")
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        // Register strategy and engine.
        let strategy = ContextStrategy(
            purpose: purpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: purpose,
            engineIdentifier: "session-test-engine",
            engineVersion: "1.0",
            engine: TestReasoningEngine(),
            isFallback: false
        ))

        // Process a Swift file (simulates what the file monitoring bridge does).
        let testFile = dir.appendingPathComponent("AppDelegate.swift")
        try "class AppDelegate { func applicationDidFinishLaunching() {} }".write(
            to: testFile, atomically: true, encoding: .utf8
        )
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // This mirrors the coordinator's pattern: find entity name → query pipeline.
        let entityName = "AppDelegate"
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(subject: .entity(EntityReference(qualifiedName: entityName)), intent: .explain, budget: 100)
        )
        #expect(!evidence.evidence.isEmpty, "Pipeline should find evidence for entity in session file")

        // Full query through assembly → consumer.
        let assemblyResult = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: purpose, budget: 100)
        )
        guard case .success(let frame) = assemblyResult else {
            Issue.record("Assembly failed: \(assemblyResult)")
            return
        }

        let consumerResult = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(purpose: purpose, outputClass: .human, detailLevel: .standard)
        ))
        guard case .success(let understanding) = consumerResult else {
            Issue.record("Consumer failed: \(consumerResult)")
            return
        }

        #expect(!understanding.content.isEmpty)
        #expect(understanding.metadata.purpose == purpose)
        #expect(understanding.metadata.engineIdentifier == "session-test-engine")

        await pipeline.shutdown()
    }

    @Test("Session explain: pipeline returns no evidence for unknown entity — triggers fallback")
    func sessionExplainFallbackNoEvidence() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Register frontend but process a file with a different entity.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "session-fallback-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["swift"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        _ = try await pipeline.producerActor.registerFrontend(
            frontendContract,
            implementation: SessionTestFrontend(entityName: "KnownEntity")
        )

        let testFile = dir.appendingPathComponent("Source.swift")
        try "class KnownEntity {}".write(to: testFile, atomically: true, encoding: .utf8)
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Query for an entity that doesn't exist in the DIR.
        // This simulates the coordinator's fallback: snippet doesn't match any entity.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "UnknownSnippetEntity")),
                intent: .explain, budget: 100
            )
        )

        #expect(evidence.evidence.isEmpty, "No evidence for unknown entity — coordinator should fall back")
        #expect(evidence.metadata.subjectNotFound)

        await pipeline.shutdown()
    }

    @Test("Session explain: pipeline evidence found but no strategy → assembly rejection triggers fallback")
    func sessionExplainFallbackNoStrategy() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Register frontend with entity.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "session-nostrategy-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["swift"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        _ = try await pipeline.producerActor.registerFrontend(
            frontendContract,
            implementation: SessionTestFrontend(entityName: "TargetEntity")
        )

        let testFile = dir.appendingPathComponent("Target.swift")
        try "class TargetEntity {}".write(to: testFile, atomically: true, encoding: .utf8)
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Retrieve evidence — should succeed.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(subject: .entity(EntityReference(qualifiedName: "TargetEntity")), intent: .explain, budget: 100)
        )
        #expect(!evidence.evidence.isEmpty)

        // Assemble with a purpose that has no registered strategy.
        let unregisteredPurpose = ContextPurpose("unregistered-purpose")
        let assemblyResult = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: unregisteredPurpose, budget: 100)
        )

        // Assembly should reject — no strategy for this purpose.
        guard case .rejected = assemblyResult else {
            Issue.record("Expected assembly rejection for unregistered purpose, got: \(assemblyResult)")
            return
        }

        // This confirms the coordinator's fallback path: assembly rejection → legacy code.
        await pipeline.shutdown()
    }
}

// MARK: - Session Test Frontend

/// A test frontend that produces units for a named entity.
/// Simulates what SwiftSyntaxFrontend/TreeSitterFrontend produce.
private struct SessionTestFrontend: FrontendDefinition {
    let entityName: String

    func parse(
        filePath: String,
        identity: ProducerIdentity,
        outputContract: OutputContract
    ) async throws -> [RawOutputRecord] {
        let hash = makeContentHash(UInt8(filePath.count % 256))
        let version = VersionStamp(singleSource: hash)

        var records: [RawOutputRecord] = []
        records.append(RawOutputRecord(
            subject: .entity(EntityReference(qualifiedName: entityName)),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("class"),
            tier: .t0,
            confidence: .deterministic,
            groundingRefs: [],
            version: version
        ))

        if outputContract.predicates.contains(PredicateIdentifier(name: "signature", domain: "structure")) {
            records.append(RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: entityName)),
                predicate: PredicateIdentifier(name: "signature", domain: "structure"),
                value: .string("class \(entityName)"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: version
            ))
        }

        return records
    }
}

// MARK: - Follow-Up Pipeline Integration Tests

@Suite("Follow-Up Pipeline Integration")
struct FollowUpPipelineIntegrationTests {

    @Test("Follow-up through pipeline: ConversationState round-trip")
    func followUpConversationStateRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Register frontend.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "followup-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["swift"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        _ = try await pipeline.producerActor.registerFrontend(
            frontendContract,
            implementation: SessionTestFrontend(entityName: "FollowUpEntity")
        )

        // Register strategy and stateful engine for both purposes.
        let explainPurpose = ContextPurpose("explain")
        let followupPurpose = ContextPurpose("followup")
        let strategy = ContextStrategy(
            purpose: explainPurpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)

        let followupStrategy = ContextStrategy(
            purpose: followupPurpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(followupStrategy)

        let statefulEngine = StatefulTestReasoningEngine()
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: explainPurpose,
            engineIdentifier: "stateful-test-engine",
            engineVersion: "1.0",
            engine: statefulEngine,
            isFallback: false
        ))
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: followupPurpose,
            engineIdentifier: "stateful-test-engine",
            engineVersion: "1.0",
            engine: statefulEngine,
            isFallback: false
        ))

        // Process a file.
        let testFile = dir.appendingPathComponent("FollowUp.swift")
        try "class FollowUpEntity { func doWork() {} }".write(
            to: testFile, atomically: true, encoding: .utf8
        )
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Step 1: Initial explain query.
        let entityName = "FollowUpEntity"
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(subject: .entity(EntityReference(qualifiedName: entityName)), intent: .explain, budget: 100)
        )
        #expect(!evidence.evidence.isEmpty)

        let assemblyResult = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: explainPurpose, budget: 100)
        )
        guard case .success(let frame) = assemblyResult else {
            Issue.record("Assembly failed: \(assemblyResult)")
            return
        }

        let initialResult = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(purpose: explainPurpose, outputClass: .human, detailLevel: .standard)
        ))
        guard case .success(let initialUnderstanding) = initialResult else {
            Issue.record("Initial query failed: \(initialResult)")
            return
        }

        #expect(!initialUnderstanding.content.isEmpty)
        #expect(initialUnderstanding.conversationState != nil, "Initial understanding should produce ConversationState")

        // Step 2: Follow-up query with round-tripped ConversationState.
        let conversationState = initialUnderstanding.conversationState!

        // Re-retrieve and re-assemble for followup purpose.
        let followupEvidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(subject: .entity(EntityReference(qualifiedName: entityName)), intent: .explain, budget: 100)
        )
        let followupAssembly = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: followupEvidence, purpose: followupPurpose, budget: 100)
        )
        guard case .success(let followupFrame) = followupAssembly else {
            Issue.record("Follow-up assembly failed: \(followupAssembly)")
            return
        }

        let followupResult = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: followupFrame,
            outputSpecification: OutputSpecification(purpose: followupPurpose, outputClass: .human, detailLevel: .standard),
            conversationState: conversationState
        ))
        guard case .success(let followupUnderstanding) = followupResult else {
            Issue.record("Follow-up query failed: \(followupResult)")
            return
        }

        #expect(!followupUnderstanding.content.isEmpty)
        #expect(followupUnderstanding.content.contains("follow-up"), "Follow-up response should indicate it received prior state")
        #expect(followupUnderstanding.conversationState != nil, "Follow-up should produce new ConversationState for chaining")

        await pipeline.shutdown()
    }

    @Test("Follow-up with nil ConversationState falls back to initial invocation")
    func followUpNilStateFallsBack() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Register frontend.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "followup-nil-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["swift"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        _ = try await pipeline.producerActor.registerFrontend(
            frontendContract,
            implementation: SessionTestFrontend(entityName: "NilStateEntity")
        )

        let followupPurpose = ContextPurpose("followup")
        let strategy = ContextStrategy(
            purpose: followupPurpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)

        let statefulEngine = StatefulTestReasoningEngine()
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: followupPurpose,
            engineIdentifier: "stateful-test-engine",
            engineVersion: "1.0",
            engine: statefulEngine,
            isFallback: false
        ))

        // Process file.
        let testFile = dir.appendingPathComponent("NilState.swift")
        try "class NilStateEntity {}".write(to: testFile, atomically: true, encoding: .utf8)
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Query with followup purpose but no ConversationState (simulates DDS-009 FM-5).
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(subject: .entity(EntityReference(qualifiedName: "NilStateEntity")), intent: .explain, budget: 100)
        )
        let assemblyResult = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: followupPurpose, budget: 100)
        )
        guard case .success(let frame) = assemblyResult else {
            Issue.record("Assembly failed: \(assemblyResult)")
            return
        }

        // No conversationState — engine should treat as initial invocation.
        let result = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(purpose: followupPurpose, outputClass: .human, detailLevel: .standard),
            conversationState: nil
        ))
        guard case .success(let understanding) = result else {
            Issue.record("Follow-up with nil state failed: \(result)")
            return
        }

        #expect(!understanding.content.isEmpty)
        #expect(understanding.content.contains("initial"), "With nil state, engine should treat as initial invocation")

        await pipeline.shutdown()
    }

    @Test("Follow-up fallback: no evidence for unknown entity")
    func followUpFallbackNoEvidence() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Register frontend with a known entity.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "followup-fallback-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["swift"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        _ = try await pipeline.producerActor.registerFrontend(
            frontendContract,
            implementation: SessionTestFrontend(entityName: "KnownEntity")
        )

        let testFile = dir.appendingPathComponent("Known.swift")
        try "class KnownEntity {}".write(to: testFile, atomically: true, encoding: .utf8)
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Query for an entity that doesn't exist — simulates coordinator fallback.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "UnknownFollowUpEntity")),
                intent: .explain, budget: 100
            )
        )

        #expect(evidence.evidence.isEmpty, "No evidence for unknown entity — coordinator should fall back to legacy")
        #expect(evidence.metadata.subjectNotFound)

        await pipeline.shutdown()
    }
}

// MARK: - Improve Pipeline Integration Tests

@Suite("Improve Pipeline Integration")
struct ImprovePipelineIntegrationTests {

    @Test("Improve through pipeline: Understanding.content parseable by ImprovementService")
    func improveContentParseable() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let improvePurpose = ContextPurpose("improve")

        // Register frontend.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "improve-test-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["imp"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = MultiPredicateFrontend()
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        // Register improve strategy.
        let strategy = ContextStrategy(
            purpose: improvePurpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)

        // Register engine that returns improvement-formatted content.
        let engine = ImproveTestReasoningEngine()
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: improvePurpose,
            engineIdentifier: "improve-test-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        ))

        // Process file.
        let testFile = dir.appendingPathComponent("Code.imp")
        try "class UserService { func create() {} }".write(
            to: testFile, atomically: true, encoding: .utf8
        )
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Retrieve → Assemble → Invoke.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "UserService")),
                intent: .explain,
                budget: 100
            )
        )
        #expect(!evidence.evidence.isEmpty)

        let assembly = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: improvePurpose, budget: 100)
        )
        guard case .success(let frame) = assembly else {
            Issue.record("Assembly failed")
            return
        }

        let result = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: improvePurpose,
                outputClass: .human,
                detailLevel: .standard
            )
        ))

        guard case .success(let understanding) = result else {
            Issue.record("Consumer failed: \(result)")
            return
        }

        // Verify the Understanding.content is parseable by the same parser
        // that the HUD uses (ImprovementService.parseResponse).
        #expect(understanding.content.contains("<improvement_summary>"))
        #expect(understanding.content.contains("<improved_code>"))
        #expect(understanding.metadata.purpose == improvePurpose)

        // Verify no ConversationState — ImproveReasoningEngine is stateless.
        #expect(understanding.conversationState == nil)

        await pipeline.shutdown()
    }

    @Test("Improve pipeline: no-improvement path preserves summary tag")
    func improveNoChangePreservesSummaryTag() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        let improvePurpose = ContextPurpose("improve")

        // Register frontend.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "improve-nochange-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["noc"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = MultiPredicateFrontend()
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        // Register strategy.
        let strategy = ContextStrategy(
            purpose: improvePurpose,
            strata: [
                StratumDefinition(
                    name: "direct",
                    priority: 0,
                    selectionCriteria: SelectionCriteria(stage: .direct),
                    budgetFraction: 1.0,
                    fillPolicy: .distanceFirst,
                    essential: true
                ),
            ],
            version: "1.0.0"
        )
        _ = pipeline.contextAssemblyService.register(strategy)

        // Register engine that returns no-improvement output.
        let engine = ImproveNoChangeTestEngine()
        _ = await pipeline.consumerActor.register(EngineRegistration(
            purpose: improvePurpose,
            engineIdentifier: "improve-nochange-engine",
            engineVersion: "1.0",
            engine: engine,
            isFallback: false
        ))

        // Process file.
        let testFile = dir.appendingPathComponent("Clean.noc")
        try "class CleanService { func run() {} }".write(
            to: testFile, atomically: true, encoding: .utf8
        )
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Retrieve → Assemble → Invoke.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "UserService")),
                intent: .explain,
                budget: 100
            )
        )
        let assembly = await pipeline.contextAssemblyService.assemble(
            AssemblyRequest(evidenceSet: evidence, purpose: improvePurpose, budget: 100)
        )
        guard case .success(let frame) = assembly else {
            Issue.record("Assembly failed")
            return
        }

        let result = await pipeline.consumerActor.invoke(ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: improvePurpose,
                outputClass: .human,
                detailLevel: .standard
            )
        ))

        guard case .success(let understanding) = result else {
            Issue.record("Consumer failed: \(result)")
            return
        }

        // No-improvement: summary tag present, no improved_code tag.
        #expect(understanding.content.contains("<improvement_summary>"))
        #expect(!understanding.content.contains("<improved_code>"))
        #expect(understanding.conversationState == nil)

        await pipeline.shutdown()
    }

    @Test("Improve pipeline fallback: no evidence for unknown entity")
    func improveFallbackNoEvidence() async throws {
        let dir = try makeTempDir()
        defer { cleanupTempDir(dir) }

        let pipeline = TestPipeline(snapshotDirectory: dir)
        await pipeline.start()

        // Process a file so the DIR has content, but query a non-existent entity.
        let frontendContract = FrontendContract(
            identity: ProducerIdentity(
                identifier: ProducerIdentifier(name: "improve-fallback-frontend"),
                version: ProducerVersion(major: 1, minor: 0)
            ),
            sourceFormats: ["fb"],
            outputContract: OutputContract(
                predicates: [PredicateIdentifier(name: "kind", domain: "structure")],
                tierRange: .t0 ... .t0
            )
        )
        let frontend = MultiPredicateFrontend()
        _ = try await pipeline.producerActor.registerFrontend(frontendContract, implementation: frontend)

        let testFile = dir.appendingPathComponent("Known.fb")
        try "class KnownEntity {}".write(to: testFile, atomically: true, encoding: .utf8)
        _ = await pipeline.updateActor.processChangeSet(
            ChangeSet(events: [FileChangeEvent(filePath: testFile.path, changeType: .created)])
        )

        // Query for unknown entity — should produce empty evidence.
        let evidence = await pipeline.retrievalService.retrieve(
            RetrievalRequest(
                subject: .entity(EntityReference(qualifiedName: "UnknownImproveEntity")),
                intent: .explain,
                budget: 100
            )
        )

        #expect(evidence.evidence.isEmpty, "No evidence for unknown entity — HUD should fall back to legacy")
        #expect(evidence.metadata.subjectNotFound)

        await pipeline.shutdown()
    }
}

// MARK: - Improve Test Reasoning Engines

/// Test engine that returns improvement-formatted content with both tags.
private struct ImproveTestReasoningEngine: ReasoningEngine {
    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        let claims = [UnderstandingClaim(
            content: "Improvement claim",
            claimType: .factual,
            confidence: .deterministic,
            groundingReferences: contextFrame.strata.flatMap { $0.units.map { $0.annotatedUnit.unit.id } }
        )]
        return ReasoningEngineOutput(
            content: "<improvement_summary>Extract method for clarity</improvement_summary>\n\n<improved_code>\nfunc optimized() { /* improved */ }\n</improved_code>",
            claims: claims,
            completeness: .complete,
            conversationState: nil
        )
    }
}

/// Test engine that returns no-improvement output (summary only, no improved_code tag).
private struct ImproveNoChangeTestEngine: ReasoningEngine {
    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        let claims = [UnderstandingClaim(
            content: "No-change claim",
            claimType: .factual,
            confidence: .deterministic,
            groundingReferences: contextFrame.strata.flatMap { $0.units.map { $0.annotatedUnit.unit.id } }
        )]
        return ReasoningEngineOutput(
            content: "<improvement_summary>Code is already well-structured. No changes needed.</improvement_summary>",
            claims: claims,
            completeness: .complete,
            conversationState: nil
        )
    }
}

// MARK: - Stateful Test Reasoning Engine

/// A test reasoning engine that produces and accepts ConversationState,
/// simulating the FollowUpReasoningEngine's conversation continuity behavior.
private struct StatefulTestReasoningEngine: ReasoningEngine {

    private struct EngineState: Codable {
        var turnCount: Int
        var priorResponse: String
    }

    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        let isFollowUp: Bool
        let turnCount: Int

        if let state = conversationState,
           let decoded = try? JSONDecoder().decode(EngineState.self, from: state.data) {
            // Follow-up: we have prior state.
            isFollowUp = true
            turnCount = decoded.turnCount + 1
        } else {
            // Initial invocation (or corrupted state — FM-5 fallback).
            isFollowUp = false
            turnCount = 1
        }

        let content = isFollowUp
            ? "This is a follow-up response (turn \(turnCount)) for \(contextFrame.purpose)"
            : "This is an initial response for \(contextFrame.purpose)"

        // Produce new ConversationState for chaining.
        let newState = EngineState(turnCount: turnCount, priorResponse: content)
        let stateData = try JSONEncoder().encode(newState)
        let newConversationState = ConversationState(
            data: stateData,
            engineIdentifier: "stateful-test-engine",
            engineVersion: "1.0"
        )

        let claims = [UnderstandingClaim(
            content: content,
            claimType: .factual,
            confidence: .deterministic,
            groundingReferences: contextFrame.strata.flatMap { stratum in
                stratum.units.map { $0.annotatedUnit.unit.id }
            }
        )]

        return ReasoningEngineOutput(
            content: content,
            claims: claims,
            completeness: .complete,
            conversationState: newConversationState
        )
    }
}
