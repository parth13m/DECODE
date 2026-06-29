// ProducerRuntimeTests.swift — ProducerRuntime
// DDS-001: Contract tests (PC-1 through PC-9), state model tests, failure mode tests
// DDS-003: DAG construction, changed output detection
// IAG-004 §4: Phase 2 verification — registration, DAG, execution, failure isolation

import Testing
import Foundation
@testable import ProducerRuntime
@testable import DIRCore
import UnderstandingTestSupport

// MARK: — Test Helpers

/// A mock pass that returns configurable output.
final class MockPass: PassDefinition, @unchecked Sendable {
    var outputToReturn: [RawOutputRecord] = []
    var shouldThrow: Error?
    var executeCount = 0

    func execute(context: ExecutionContext) async throws -> [RawOutputRecord] {
        executeCount += 1
        if let error = shouldThrow { throw error }
        return outputToReturn
    }
}

/// A mock frontend that returns configurable output.
final class MockFrontend: FrontendDefinition, @unchecked Sendable {
    var outputToReturn: [RawOutputRecord] = []
    var shouldThrow: Error?
    var parseCount = 0

    func parse(
        filePath: String,
        identity: ProducerIdentity,
        outputContract: OutputContract
    ) async throws -> [RawOutputRecord] {
        parseCount += 1
        if let error = shouldThrow { throw error }
        return outputToReturn
    }
}

/// Simple error for testing failure paths.
struct TestError: Error, Sendable {
    let message: String
    init(_ message: String = "test error") { self.message = message }
}

// MARK: — Factory Helpers

func testPredicateId(_ name: String = "testPred") -> PredicateIdentifier {
    PredicateIdentifier(name: name, domain: "test")
}

func testProducerId(_ name: String) -> ProducerIdentifier {
    ProducerIdentifier(name: name)
}

func testIdentity(_ name: String, major: Int = 1, minor: Int = 0) -> ProducerIdentity {
    ProducerIdentity(
        identifier: testProducerId(name),
        version: ProducerVersion(major: major, minor: minor)
    )
}

func testOutputContract(
    predicates: Set<PredicateIdentifier> = [PredicateIdentifier(name: "testPred", domain: "test")],
    tierRange: ClosedRange<Tier> = .t0 ... .t0
) -> OutputContract {
    OutputContract(predicates: predicates, tierRange: tierRange)
}

func testInputContract(
    predicates: Set<PredicateIdentifier> = [PredicateIdentifier(name: "testPred", domain: "test")],
    tiers: Set<Tier> = [.t0]
) -> InputContract {
    InputContract(predicates: predicates, tiers: tiers)
}

func testFrontendContract(
    name: String = "test-frontend",
    sourceFormats: Set<String> = ["swift"],
    tierRange: ClosedRange<Tier> = .t0 ... .t0
) -> FrontendContract {
    FrontendContract(
        identity: testIdentity(name),
        sourceFormats: sourceFormats,
        outputContract: testOutputContract(tierRange: tierRange)
    )
}

func testPassContract(
    name: String = "test-pass",
    inputPreds: Set<PredicateIdentifier>? = nil,
    inputTiers: Set<Tier> = [.t0],
    outputPreds: Set<PredicateIdentifier>? = nil,
    outputTierRange: ClosedRange<Tier> = .t0 ... .t0,
    scope: ScopeGranularity = .perFile,
    strategy: ExecutionStrategy = .deterministic,
    isComposition: Bool = false,
    isIdempotent: Bool = true,
    dependencies: Set<ProducerIdentifier> = []
) -> PassContract {
    PassContract(
        identity: testIdentity(name),
        inputContract: testInputContract(
            predicates: inputPreds ?? [testPredicateId()],
            tiers: inputTiers
        ),
        outputContract: OutputContract(
            predicates: outputPreds ?? [PredicateIdentifier(name: "derivedPred", domain: "test")],
            tierRange: outputTierRange
        ),
        scope: scope,
        executionStrategy: strategy,
        isComposition: isComposition,
        isIdempotent: isIdempotent,
        dependencies: dependencies
    )
}

func makeActor() -> ProducerActor {
    ProducerActor(
        dirRead: MockDIRReadAccess(),
        dirWrite: MockDIRWriteAccess()
    )
}

// MARK: — Registration Tests

@Suite("Producer Registration")
struct RegistrationTests {

    @Test("Valid frontend registration succeeds")
    func validFrontendRegistration() async throws {
        let actor = makeActor()
        let contract = testFrontendContract()
        let result = try await actor.register(.frontend(contract))
        #expect(result == .accepted)
    }

    @Test("Valid pass registration succeeds")
    func validPassRegistration() async throws {
        let actor = makeActor()
        let contract = testPassContract()
        let result = try await actor.register(.pass(contract))
        #expect(result == .accepted)
    }

    @Test("Frontend with no source formats is rejected")
    func frontendNoFormatsRejected() async throws {
        let actor = makeActor()
        let contract = FrontendContract(
            identity: testIdentity("bad-frontend"),
            sourceFormats: [],
            outputContract: testOutputContract()
        )
        let result = try await actor.register(.frontend(contract))
        #expect(result == .rejected(reason: "Frontend must declare at least one source format"))
    }

    @Test("Frontend with no output predicates is rejected")
    func frontendNoPredicatesRejected() async throws {
        let actor = makeActor()
        let contract = FrontendContract(
            identity: testIdentity("bad-frontend"),
            sourceFormats: ["swift"],
            outputContract: OutputContract(predicates: [], tierRange: .t0 ... .t0)
        )
        let result = try await actor.register(.frontend(contract))
        #expect(result == .rejected(reason: "Frontend must declare at least one output predicate"))
    }

    @Test("Deterministic pass with T2 output is rejected")
    func deterministicT2Rejected() async throws {
        let actor = makeActor()
        let contract = testPassContract(
            name: "bad-det",
            outputTierRange: .t2 ... .t2,
            strategy: .deterministic
        )
        let result = try await actor.register(.pass(contract))
        #expect(result == .rejected(reason: "Deterministic pass cannot produce T2 output"))
    }

    @Test("Semantic pass with only T0 output is rejected")
    func semanticT0Rejected() async throws {
        let actor = makeActor()
        let contract = testPassContract(
            name: "bad-sem",
            outputTierRange: .t0 ... .t1,
            strategy: .semantic,
            isIdempotent: false
        )
        let result = try await actor.register(.pass(contract))
        #expect(result == .rejected(reason: "Semantic pass must produce T2 output"))
    }

    @Test("Non-idempotent deterministic pass is rejected")
    func deterministicNonIdempotentRejected() async throws {
        let actor = makeActor()
        let contract = testPassContract(
            name: "bad-idem",
            strategy: .deterministic,
            isIdempotent: false
        )
        let result = try await actor.register(.pass(contract))
        #expect(result == .rejected(reason: "Deterministic pass must be idempotent"))
    }

    @Test("Removing a registered producer succeeds")
    func removeRegistered() async throws {
        let actor = makeActor()
        let contract = testFrontendContract()
        _ = try await actor.register(.frontend(contract))
        try await actor.remove(contract.identity.identifier)
        let prods = await actor.registeredProducers()
        #expect(prods.isEmpty)
    }

    @Test("Removing an unregistered producer throws")
    func removeUnregistered() async throws {
        let actor = makeActor()
        do {
            try await actor.remove(testProducerId("nonexistent"))
            #expect(Bool(false), "Should have thrown")
        } catch is ProducerError {
            // Expected
        }
    }

    @Test("Producer discovery by predicate and tier")
    func discoveryByPredicate() async throws {
        let actor = makeActor()
        let pred = testPredicateId("specialPred")
        let contract = FrontendContract(
            identity: testIdentity("disc-frontend"),
            sourceFormats: ["swift"],
            outputContract: OutputContract(predicates: [pred], tierRange: .t0 ... .t0)
        )
        _ = try await actor.register(.frontend(contract))

        let found = await actor.producers(for: pred, at: .t0)
        #expect(found.count == 1)
        #expect(found.first == contract.identity.identifier)

        let notFound = await actor.producers(for: testPredicateId("other"), at: .t0)
        #expect(notFound.isEmpty)
    }
}

// MARK: — RegistrationResult Equatable

extension RegistrationResult: @retroactive Equatable {
    public static func == (lhs: RegistrationResult, rhs: RegistrationResult) -> Bool {
        switch (lhs, rhs) {
        case (.accepted, .accepted): return true
        case (.deferred, .deferred): return true
        case (.rejected(let a), .rejected(let b)): return a == b
        default: return false
        }
    }
}

// MARK: — DAG Tests

@Suite("Pass DAG")
struct DAGTests {

    @Test("DAG with no dependencies has flat topological order")
    func flatDAG() async throws {
        let actor = makeActor()
        _ = try await actor.register(.frontend(testFrontendContract(name: "fe1")))
        _ = try await actor.register(.frontend(testFrontendContract(name: "fe2", sourceFormats: ["py"])))

        let snapshot = await actor.dagSnapshot()
        #expect(snapshot.topologicalOrder.count == 2)
        #expect(snapshot.frontendCount == 2)
    }

    @Test("Pass depends on frontend — frontend first in order")
    func frontendBeforePass() async throws {
        let actor = makeActor()
        let fePred = testPredicateId("fePred")
        let feContract = FrontendContract(
            identity: testIdentity("fe"),
            sourceFormats: ["swift"],
            outputContract: OutputContract(predicates: [fePred], tierRange: .t0 ... .t0)
        )
        _ = try await actor.register(.frontend(feContract))

        let passContract = testPassContract(
            name: "pass1",
            inputPreds: [fePred],
            dependencies: [testProducerId("fe")]
        )
        _ = try await actor.register(.pass(passContract))

        let snapshot = await actor.dagSnapshot()
        let order = snapshot.topologicalOrder
        let feIdx = order.firstIndex(of: testProducerId("fe"))!
        let passIdx = order.firstIndex(of: testProducerId("pass1"))!
        #expect(feIdx < passIdx)
    }

    @Test("DAG cycle is rejected at DAG level")
    func dagCycleRejected() {
        // Test via PassDAG.build directly — cycle between A and B
        let contracts: [ProducerIdentifier: ProducerContract] = [
            testProducerId("passA"): .pass(testPassContract(
                name: "passA",
                dependencies: [testProducerId("passB")]
            )),
            testProducerId("passB"): .pass(testPassContract(
                name: "passB",
                dependencies: [testProducerId("passA")]
            ))
        ]

        let result = PassDAG.build(from: contracts)
        switch result {
        case .success:
            #expect(Bool(false), "Expected cycle error")
        case .failure(let error):
            if case .cycle(let path) = error {
                #expect(path.count >= 2)
            } else {
                #expect(Bool(false), "Expected cycle, got \(error)")
            }
        }
    }

    @Test("Registering pass with missing dependency is rejected")
    func missingDepViaRegister() async throws {
        let actor = makeActor()
        let contract = testPassContract(
            name: "passA",
            dependencies: [testProducerId("nonexistent")]
        )
        do {
            _ = try await actor.register(.pass(contract))
            #expect(Bool(false), "Should have thrown")
        } catch is ProducerError {
            // Expected — missing dependency
        }
    }

    @Test("Execution levels group independent passes")
    func executionLevels() async throws {
        let actor = makeActor()

        // Level 0: two independent frontends
        _ = try await actor.register(.frontend(testFrontendContract(name: "fe1")))
        _ = try await actor.register(.frontend(testFrontendContract(name: "fe2", sourceFormats: ["py"])))

        // Level 1: pass depending on both frontends
        let pass1 = testPassContract(
            name: "pass1",
            dependencies: [testProducerId("fe1"), testProducerId("fe2")]
        )
        _ = try await actor.register(.pass(pass1))

        let snapshot = await actor.dagSnapshot()
        #expect(snapshot.executionLevels.count == 2)
        #expect(snapshot.executionLevels[0].count == 2) // Both frontends
        #expect(snapshot.executionLevels[1].count == 1) // The pass
    }
}

// MARK: — State Model Tests

@Suite("State Model")
struct StateModelTests {

    @Test("Empty → Ready on first registration")
    func emptyToReady() async throws {
        let actor = makeActor()
        #expect(await actor.currentState == .empty)
        _ = try await actor.register(.frontend(testFrontendContract()))
        #expect(await actor.currentState == .ready)
    }

    @Test("Ready → Empty on last removal")
    func readyToEmpty() async throws {
        let actor = makeActor()
        let contract = testFrontendContract()
        _ = try await actor.register(.frontend(contract))
        #expect(await actor.currentState == .ready)
        try await actor.remove(contract.identity.identifier)
        #expect(await actor.currentState == .empty)
    }

    @Test("Execution ticket rejected in empty state")
    func executeInEmptyState() async throws {
        let actor = makeActor()
        let ticket = ExecutionTicket(
            producerId: testProducerId("fe"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)
        if case .failed(let record) = result {
            #expect(record.category == .executionError)
        } else {
            #expect(Bool(false), "Expected failure in empty state")
        }
    }

    @Test("Shutdown transitions to terminated")
    func shutdown() async throws {
        let actor = makeActor()
        _ = try await actor.register(.frontend(testFrontendContract()))
        await actor.shutdown()
        #expect(await actor.currentState == .terminated)
    }
}

// MARK: — Execution Tests

@Suite("Execution")
struct ExecutionTests {

    @Test("Frontend execution produces output")
    func frontendExecution() async throws {
        let actor = makeActor()
        let frontend = MockFrontend()
        let pred = testPredicateId("entityName")
        frontend.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "Foo")),
                predicate: pred,
                value: .string("Foo"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        let contract = FrontendContract(
            identity: testIdentity("swift-fe"),
            sourceFormats: ["swift"],
            outputContract: OutputContract(predicates: [pred], tierRange: .t0 ... .t0)
        )
        _ = try await actor.registerFrontend(contract, implementation: frontend)

        let ticket = ExecutionTicket(
            producerId: testProducerId("swift-fe"),
            scope: .file(path: "Foo.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)

        if case .completed(let report) = result {
            #expect(report.outputUnitCount == 1)
        } else {
            #expect(Bool(false), "Expected completed, got \(result)")
        }
        #expect(frontend.parseCount == 1)
    }

    @Test("Pass execution with input assembly")
    func passExecution() async throws {
        let mockRead = MockDIRReadAccess()
        let inputPred = testPredicateId("inputPred")
        let outputPred = testPredicateId("outputPred")

        // Seed the mock DIR with an active unit
        let existingUnit = makeUnit(
            predicate: inputPred,
            tier: .t0
        )
        mockRead.units[existingUnit.id] = existingUnit

        let actor = ProducerActor(dirRead: mockRead, dirWrite: MockDIRWriteAccess())

        let pass = MockPass()
        pass.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "TestEntity")),
                predicate: outputPred,
                value: .string("derived"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [existingUnit.id],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        let contract = testPassContract(
            name: "test-pass",
            inputPreds: [inputPred],
            outputPreds: [outputPred]
        )
        _ = try await actor.registerPass(contract, implementation: pass)

        let ticket = ExecutionTicket(
            producerId: testProducerId("test-pass"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)

        if case .completed(let report) = result {
            #expect(report.outputUnitCount == 1)
        } else {
            #expect(Bool(false), "Expected completed, got \(result)")
        }
        #expect(pass.executeCount == 1)
    }

    @Test("Unregistered producer execution fails")
    func unregisteredExecution() async throws {
        let actor = makeActor()
        _ = try await actor.register(.frontend(testFrontendContract()))

        let ticket = ExecutionTicket(
            producerId: testProducerId("nonexistent"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)
        if case .failed(let record) = result {
            #expect(record.category == .executionError)
        } else {
            #expect(Bool(false), "Expected failure")
        }
    }
}

// MARK: — Failure Isolation Tests

@Suite("Failure Isolation")
struct FailureIsolationTests {

    @Test("Pass that throws produces a failure record")
    func passThrowsRecordedAsFailure() async throws {
        let actor = makeActor()
        let pass = MockPass()
        pass.shouldThrow = TestError("boom")

        let contract = testPassContract(name: "failing-pass")
        _ = try await actor.registerPass(contract, implementation: pass)

        let ticket = ExecutionTicket(
            producerId: testProducerId("failing-pass"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)

        if case .failed(let record) = result {
            #expect(record.category == .executionError)
            #expect(record.isRetryEligible == true) // Deterministic → always retry
        } else {
            #expect(Bool(false), "Expected failure")
        }

        let failures = await actor.allFailures()
        #expect(failures.count == 1)
    }

    @Test("Output with undeclared predicate is rejected")
    func undeclaredPredicateRejected() async throws {
        let actor = makeActor()
        let pass = MockPass()
        let undeclaredPred = PredicateIdentifier(name: "notDeclared", domain: "rogue")
        pass.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "Foo")),
                predicate: undeclaredPred,
                value: .string("bad"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        let contract = testPassContract(name: "bad-output-pass")
        _ = try await actor.registerPass(contract, implementation: pass)

        let ticket = ExecutionTicket(
            producerId: testProducerId("bad-output-pass"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)

        if case .failed(let record) = result {
            #expect(record.category == .invalidOutput)
            #expect(record.isRetryEligible == false)
        } else {
            #expect(Bool(false), "Expected failure for undeclared predicate")
        }
    }

    @Test("Failure records are queryable by producer")
    func failureRecordsByProducer() async throws {
        let actor = makeActor()

        let pass1 = MockPass()
        pass1.shouldThrow = TestError("fail1")
        let pass2 = MockPass()
        pass2.shouldThrow = TestError("fail2")

        _ = try await actor.registerPass(
            testPassContract(name: "p1"),
            implementation: pass1
        )
        _ = try await actor.registerPass(
            testPassContract(name: "p2", dependencies: []),
            implementation: pass2
        )

        _ = await actor.execute(ExecutionTicket(
            producerId: testProducerId("p1"),
            scope: .file(path: "a.swift"),
            mode: .incremental
        ))
        _ = await actor.execute(ExecutionTicket(
            producerId: testProducerId("p2"),
            scope: .file(path: "b.swift"),
            mode: .incremental
        ))

        let p1Failures = await actor.failures(for: testProducerId("p1"))
        #expect(p1Failures.count == 1)

        let allFailures = await actor.allFailures()
        #expect(allFailures.count == 2)

        await actor.clearFailures()
        let afterClear = await actor.allFailures()
        #expect(afterClear.isEmpty)
    }
}

// MARK: — Changed Output Detection Tests

@Suite("Changed Output Detection")
struct ChangeDetectionTests {

    @Test("First invocation reports changed")
    func firstInvocationChanged() async throws {
        let actor = makeActor()
        let pass = MockPass()
        let outputPred = PredicateIdentifier(name: "outPred", domain: "test")
        pass.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "E")),
                predicate: outputPred,
                value: .string("v1"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        let contract = testPassContract(name: "change-pass", outputPreds: [outputPred])
        _ = try await actor.registerPass(contract, implementation: pass)

        let ticket = ExecutionTicket(
            producerId: testProducerId("change-pass"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )
        let result = await actor.execute(ticket)

        if case .completed(let report) = result {
            if case .firstInvocation = report.changeReport {
                // Expected
            } else {
                #expect(Bool(false), "Expected firstInvocation, got \(report.changeReport)")
            }
        } else {
            #expect(Bool(false), "Expected completed")
        }
    }

    @Test("Identical re-invocation reports no change")
    func identicalReinvocation() async throws {
        let actor = makeActor()
        let pass = MockPass()
        let outputPred = PredicateIdentifier(name: "stablePred", domain: "test")
        pass.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "E")),
                predicate: outputPred,
                value: .string("stable"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        let contract = testPassContract(name: "stable-pass", outputPreds: [outputPred])
        _ = try await actor.registerPass(contract, implementation: pass)

        let ticket = ExecutionTicket(
            producerId: testProducerId("stable-pass"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )

        // First invocation
        _ = await actor.execute(ticket)

        // Second invocation — same output
        let result = await actor.execute(ticket)
        if case .completed(let report) = result {
            if case .noChange = report.changeReport {
                // Expected
            } else {
                #expect(Bool(false), "Expected noChange, got \(report.changeReport)")
            }
        } else {
            #expect(Bool(false), "Expected completed")
        }
    }

    @Test("Different output on re-invocation reports changed")
    func differentOutputChanged() async throws {
        let actor = makeActor()
        let pass = MockPass()
        let outputPred = PredicateIdentifier(name: "changingPred", domain: "test")
        pass.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "E")),
                predicate: outputPred,
                value: .string("v1"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        let contract = testPassContract(name: "changing-pass", outputPreds: [outputPred])
        _ = try await actor.registerPass(contract, implementation: pass)

        let ticket = ExecutionTicket(
            producerId: testProducerId("changing-pass"),
            scope: .file(path: "test.swift"),
            mode: .incremental
        )

        // First invocation
        _ = await actor.execute(ticket)

        // Change output
        pass.outputToReturn = [
            RawOutputRecord(
                subject: .entity(EntityReference(qualifiedName: "E")),
                predicate: outputPred,
                value: .string("v2"),
                tier: .t0,
                confidence: .deterministic,
                groundingRefs: [],
                version: VersionStamp(singleSource: makeContentHash(1))
            )
        ]

        // Second invocation — different output
        let result = await actor.execute(ticket)
        if case .completed(let report) = result {
            if case .changed = report.changeReport {
                // Expected
            } else {
                #expect(Bool(false), "Expected changed, got \(report.changeReport)")
            }
        } else {
            #expect(Bool(false), "Expected completed")
        }
    }
}

// MARK: — DAG Struct Tests

@Suite("PassDAG Construction")
struct PassDAGStructTests {

    @Test("Empty DAG")
    func emptyDAG() {
        let dag = PassDAG()
        #expect(dag.isEmpty)
        #expect(dag.count == 0)
        #expect(dag.topologicalOrder.isEmpty)
        #expect(dag.executionLevels.isEmpty)
    }

    @Test("Single frontend DAG")
    func singleFrontend() {
        let contracts: [ProducerIdentifier: ProducerContract] = [
            testProducerId("fe"): .frontend(testFrontendContract(name: "fe"))
        ]
        let result = PassDAG.build(from: contracts)
        switch result {
        case .success(let dag):
            #expect(dag.count == 1)
            #expect(dag.topologicalOrder == [testProducerId("fe")])
        case .failure(let error):
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("Linear chain: A → B → C")
    func linearChain() {
        let predA = testPredicateId("predA")
        let predB = testPredicateId("predB")
        let predC = testPredicateId("predC")

        let contracts: [ProducerIdentifier: ProducerContract] = [
            testProducerId("A"): .frontend(FrontendContract(
                identity: testIdentity("A"),
                sourceFormats: ["swift"],
                outputContract: OutputContract(predicates: [predA], tierRange: .t0 ... .t0)
            )),
            testProducerId("B"): .pass(PassContract(
                identity: testIdentity("B"),
                inputContract: InputContract(predicates: [predA], tiers: [.t0]),
                outputContract: OutputContract(predicates: [predB], tierRange: .t0 ... .t0),
                scope: .perFile,
                executionStrategy: .deterministic,
                isComposition: false,
                isIdempotent: true,
                dependencies: [testProducerId("A")]
            )),
            testProducerId("C"): .pass(PassContract(
                identity: testIdentity("C"),
                inputContract: InputContract(predicates: [predB], tiers: [.t0]),
                outputContract: OutputContract(predicates: [predC], tierRange: .t0 ... .t0),
                scope: .perFile,
                executionStrategy: .deterministic,
                isComposition: false,
                isIdempotent: true,
                dependencies: [testProducerId("B")]
            ))
        ]

        let result = PassDAG.build(from: contracts)
        switch result {
        case .success(let dag):
            #expect(dag.count == 3)
            let order = dag.topologicalOrder
            #expect(order.firstIndex(of: testProducerId("A"))!
                    < order.firstIndex(of: testProducerId("B"))!)
            #expect(order.firstIndex(of: testProducerId("B"))!
                    < order.firstIndex(of: testProducerId("C"))!)
            #expect(dag.executionLevels.count == 3)
        case .failure(let error):
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("Cycle detection: A ↔ B")
    func cycleDetection() {
        let contracts: [ProducerIdentifier: ProducerContract] = [
            testProducerId("A"): .pass(PassContract(
                identity: testIdentity("A"),
                inputContract: testInputContract(),
                outputContract: testOutputContract(),
                scope: .perFile,
                executionStrategy: .deterministic,
                isComposition: false,
                isIdempotent: true,
                dependencies: [testProducerId("B")]
            )),
            testProducerId("B"): .pass(PassContract(
                identity: testIdentity("B"),
                inputContract: testInputContract(),
                outputContract: testOutputContract(),
                scope: .perFile,
                executionStrategy: .deterministic,
                isComposition: false,
                isIdempotent: true,
                dependencies: [testProducerId("A")]
            ))
        ]

        let result = PassDAG.build(from: contracts)
        switch result {
        case .success:
            #expect(Bool(false), "Expected cycle error")
        case .failure(let error):
            if case .cycle(let path) = error {
                #expect(path.count >= 2)
            } else {
                #expect(Bool(false), "Expected cycle, got \(error)")
            }
        }
    }

    @Test("ProducerVersion ordering")
    func versionOrdering() {
        let v1_0 = ProducerVersion(major: 1, minor: 0)
        let v1_1 = ProducerVersion(major: 1, minor: 1)
        let v2_0 = ProducerVersion(major: 2, minor: 0)

        #expect(v1_0 < v1_1)
        #expect(v1_1 < v2_0)
        #expect(!(v2_0 < v1_0))
    }

    @Test("ProducerRuntimeState valid transitions")
    func stateTransitions() {
        #expect(ProducerRuntimeState.empty.canTransition(to: .ready))
        #expect(ProducerRuntimeState.ready.canTransition(to: .executing))
        #expect(ProducerRuntimeState.executing.canTransition(to: .ready))
        #expect(ProducerRuntimeState.ready.canTransition(to: .quiescing))
        #expect(ProducerRuntimeState.quiescing.canTransition(to: .terminated))

        // Invalid transitions
        #expect(!ProducerRuntimeState.empty.canTransition(to: .executing))
        #expect(!ProducerRuntimeState.terminated.canTransition(to: .ready))
        #expect(!ProducerRuntimeState.quiescing.canTransition(to: .ready))
    }
}
