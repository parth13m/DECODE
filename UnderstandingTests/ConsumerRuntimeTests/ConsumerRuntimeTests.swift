// ConsumerRuntimeTests.swift — ConsumerRuntimeTests
// DDS-009: Consumer Runtime tests
// IAG-001 §9: Unit tests for ConsumerRuntime (M6)
// IAG-004 §3.2: Verification gate tests

import Testing
import Foundation
@testable import ConsumerRuntime
@testable import ContextAssembly
@testable import RetrievalRuntime
@testable import DIRCore
@testable import UnderstandingTestSupport

// MARK: — Test Helpers

/// Creates a mock reasoning engine that produces configurable output.
final class MockReasoningEngine: ReasoningEngine, @unchecked Sendable {
    var output: ReasoningEngineOutput
    var shouldThrow: Bool = false
    var throwError: Error = MockEngineError.failed
    var invokeCount: Int = 0

    init(output: ReasoningEngineOutput? = nil) {
        self.output = output ?? ReasoningEngineOutput(
            content: "Test understanding",
            claims: [],
            completeness: .complete
        )
    }

    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        invokeCount += 1
        if shouldThrow { throw throwError }
        return output
    }
}

enum MockEngineError: Error {
    case failed
    case timeout
}

/// Creates a mock demand signal sink.
final class MockDemandSignalSink: DemandSignalSink, @unchecked Sendable {
    var submittedSignals: [DemandSignal] = []

    func submit(_ signal: DemandSignal) async {
        submittedSignals.append(signal)
    }
}

/// Creates a simple AnnotatedUnit for testing.
private func makeAnnotatedUnit(
    id: UInt64,
    entity: String,
    tier: Tier = .t0,
    confidence: Confidence = .deterministic,
    distance: Int = 0
) -> AnnotatedUnit {
    let unit = makeUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entity)),
        tier: tier,
        confidence: confidence
    )
    return AnnotatedUnit(
        unit: unit,
        provenance: EvidenceProvenance(stage: .direct, path: []),
        distance: distance
    )
}

/// Creates a ContextUnit from an AnnotatedUnit.
private func makeContextUnit(
    id: UInt64,
    entity: String,
    tier: Tier = .t0,
    confidence: Confidence = .deterministic,
    stratumName: String = "primary"
) -> ContextUnit {
    let annotated = makeAnnotatedUnit(id: id, entity: entity, tier: tier, confidence: confidence)
    return ContextUnit(
        annotatedUnit: annotated,
        role: ContextRole(stratumName: stratumName, reason: "test selection")
    )
}

/// Creates a minimal valid ContextFrame for testing.
private func makeContextFrame(
    purpose: ContextPurpose = ContextPurpose("explain"),
    units: [ContextUnit] = [],
    epoch: Epoch = Epoch(value: 1),
    degradationLevel: DegradationLevel = .full
) -> ContextFrame {
    let strata = units.isEmpty ? [] : [
        FilledStratum(
            name: "primary",
            priority: 1,
            units: units,
            budgetAllocated: units.count * 100,
            budgetUsed: units.count * 50
        )
    ]

    let tierCounts: [Tier: Int] = units.reduce(into: [:]) { counts, cu in
        counts[cu.annotatedUnit.unit.tier, default: 0] += 1
    }

    let metadata = ContextFrameMetadata(
        evidenceSetSize: units.count,
        selectedCount: units.count,
        tierCounts: tierCounts,
        stratumCounts: ["primary": units.count],
        coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
        degradationLevel: degradationLevel,
        freshnessState: .fresh,
        assemblyDuration: 0.001,
        strategyVersion: "test-v1",
        committedEpoch: epoch,
        budgetInsufficient: false
    )

    return ContextFrame(
        anchors: units.map { $0.annotatedUnit.unit.subject }.compactMap { subject in
            if case let .entity(ref) = subject { return ref }
            return nil
        },
        purpose: purpose,
        strategyVersion: "test-v1",
        strata: strata,
        budgetSummary: BudgetSummary(
            total: units.count * 100,
            denomination: .tokens,
            used: units.count * 50
        ),
        metadata: metadata
    )
}

/// Creates a ConsumerRequest with sensible defaults.
private func makeRequest(
    purpose: ContextPurpose = ContextPurpose("explain"),
    units: [ContextUnit]? = nil,
    conversationState: ConversationState? = nil,
    degradationLevel: DegradationLevel = .full
) -> ConsumerRequest {
    let contextUnits = units ?? [
        makeContextUnit(id: 1, entity: "TestEntity", tier: .t0),
        makeContextUnit(id: 2, entity: "TestEntity.method", tier: .t1, confidence: .high)
    ]
    let frame = makeContextFrame(
        purpose: purpose,
        units: contextUnits,
        degradationLevel: degradationLevel
    )
    return ConsumerRequest(
        contextFrame: frame,
        outputSpecification: OutputSpecification(purpose: purpose),
        conversationState: conversationState
    )
}

/// Creates an EngineRegistration with a mock engine.
private func makeRegistration(
    purpose: ContextPurpose = ContextPurpose("explain"),
    engineId: String = "test-engine",
    version: String = "1.0",
    engine: ReasoningEngine? = nil,
    isFallback: Bool = false
) -> EngineRegistration {
    EngineRegistration(
        purpose: purpose,
        engineIdentifier: engineId,
        engineVersion: version,
        engine: engine ?? MockReasoningEngine(),
        isFallback: isFallback
    )
}

/// Creates a mock engine that produces grounded claims.
private func makeEngineWithGroundedClaims(
    unitIds: [UInt64],
    claimType: ClaimType = .factual,
    confidence: Confidence = .deterministic
) -> MockReasoningEngine {
    let claims = unitIds.map { id in
        UnderstandingClaim(
            content: "Claim about unit \(id)",
            claimType: claimType,
            confidence: confidence,
            groundingReferences: [UnitIdentifier(rawValue: id)]
        )
    }
    return MockReasoningEngine(output: ReasoningEngineOutput(
        content: "Understanding with \(claims.count) claims",
        claims: claims,
        completeness: .complete
    ))
}

// MARK: — State Model Tests

@Suite("Consumer Runtime State Model")
struct StateModelTests {

    @Test("Valid state transitions")
    func validTransitions() async {
        let actor = ConsumerActor()
        let catalog = await actor.engineCatalog()
        #expect(catalog.isEmpty)

        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)
        if case let .failure(failure) = result {
            #expect(failure.mode == .engineNotFound)
        }

        await actor.shutdown()
    }

    @Test("Consumer requests rejected in unavailable state")
    func rejectInUnavailable() async {
        let actor = ConsumerActor()
        let request = makeRequest()
        let result = await actor.invoke(request)
        if case let .failure(failure) = result {
            #expect(failure.mode == .terminated)
        } else {
            Issue.record("Expected failure in unavailable state")
        }
    }

    @Test("Consumer requests rejected in terminated state")
    func rejectInTerminated() async {
        let actor = ConsumerActor()
        await actor.activate()
        await actor.shutdown()

        let request = makeRequest()
        let result = await actor.invoke(request)
        if case let .failure(failure) = result {
            #expect(failure.mode == .terminated)
        } else {
            Issue.record("Expected failure in terminated state")
        }
    }

    @Test("Engine registration accepted in unavailable state")
    func registerInUnavailable() async {
        let actor = ConsumerActor()
        let reg = makeRegistration()
        let success = await actor.register(reg)
        #expect(success)

        let catalog = await actor.engineCatalog()
        #expect(catalog.count == 1)
    }

    @Test("Engine registration rejected in terminated state")
    func registerInTerminated() async {
        let actor = ConsumerActor()
        await actor.activate()
        await actor.shutdown()

        let reg = makeRegistration()
        let success = await actor.register(reg)
        #expect(!success)
    }
}

// MARK: — Engine Registration Tests (PC-2, PC-3)

@Suite("Reasoning Engine Registration")
struct EngineRegistrationTests {

    @Test("Register engine for a purpose")
    func registerEngine() async {
        let actor = ConsumerActor()
        let reg = makeRegistration(purpose: ContextPurpose("explain"))
        let success = await actor.register(reg)
        #expect(success)

        let catalog = await actor.engineCatalog()
        #expect(catalog.count == 1)
        #expect(catalog[ContextPurpose("explain")]?.engineIdentifier == "test-engine")
    }

    @Test("Register multiple engines for different purposes")
    func registerMultiplePurposes() async {
        let actor = ConsumerActor()
        let reg1 = makeRegistration(purpose: ContextPurpose("explain"), engineId: "explain-engine")
        let reg2 = makeRegistration(purpose: ContextPurpose("impact"), engineId: "impact-engine")
        _ = await actor.register(reg1)
        _ = await actor.register(reg2)

        let catalog = await actor.engineCatalog()
        #expect(catalog.count == 2)
        #expect(catalog[ContextPurpose("explain")]?.engineIdentifier == "explain-engine")
        #expect(catalog[ContextPurpose("impact")]?.engineIdentifier == "impact-engine")
    }

    @Test("Replacing engine for the same purpose")
    func replaceEngine() async {
        let actor = ConsumerActor()
        let reg1 = makeRegistration(purpose: ContextPurpose("explain"), engineId: "engine-v1", version: "1.0")
        let reg2 = makeRegistration(purpose: ContextPurpose("explain"), engineId: "engine-v2", version: "2.0")
        _ = await actor.register(reg1)
        _ = await actor.register(reg2)

        let catalog = await actor.engineCatalog()
        #expect(catalog.count == 1)
        #expect(catalog[ContextPurpose("explain")]?.engineIdentifier == "engine-v2")
        #expect(catalog[ContextPurpose("explain")]?.engineVersion == "2.0")
    }

    @Test("Register fallback engine")
    func registerFallback() async {
        let actor = ConsumerActor()
        let primary = makeRegistration(purpose: ContextPurpose("explain"), engineId: "primary")
        let fallback = makeRegistration(
            purpose: ContextPurpose("explain"),
            engineId: "fallback",
            isFallback: true
        )
        _ = await actor.register(primary)
        _ = await actor.register(fallback)

        let catalog = await actor.engineCatalog()
        #expect(catalog[ContextPurpose("explain")]?.hasFallback == true)
        #expect(catalog[ContextPurpose("explain")]?.fallbackIdentifier == "fallback")
    }

    @Test("Reject registration with empty engine identifier")
    func rejectEmptyId() async {
        let actor = ConsumerActor()
        let reg = makeRegistration(engineId: "")
        let success = await actor.register(reg)
        #expect(!success)
    }

    @Test("Empty catalog query returns empty dictionary")
    func emptyCatalog() async {
        let actor = ConsumerActor()
        let catalog = await actor.engineCatalog()
        #expect(catalog.isEmpty)
    }
}

// MARK: — Consumer Invocation Tests (PC-1)

@Suite("Consumer Invocation")
struct ConsumerInvocationTests {

    @Test("Successful invocation with grounded claims")
    func successfulInvocation() async {
        let actor = ConsumerActor()
        let engine = makeEngineWithGroundedClaims(unitIds: [1, 2])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.claims.count == 2)
        #expect(understanding.metadata.purpose == ContextPurpose("explain"))
        #expect(understanding.metadata.engineIdentifier == "test-engine")
        #expect(understanding.metadata.completeness == .complete)
        #expect(understanding.metadata.ungroundedClaimsRemoved == 0)
    }

    @Test("Invocation produces understanding with correct metadata")
    func metadataCompleteness() async {
        let actor = ConsumerActor()
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        let meta = understanding.metadata
        #expect(meta.purpose == ContextPurpose("explain"))
        #expect(meta.outputClass == .human)
        #expect(meta.engineIdentifier == "test-engine")
        #expect(meta.engineVersion == "1.0")
        #expect(meta.reasoningDuration >= 0)
        #expect(meta.groundingCoverage >= 0)
        #expect(meta.groundingCoverage <= 1.0)
        #expect(!meta.usedFallback)
        #expect(!meta.conversationStateDiscarded)
    }

    @Test("Invocation with no claims produces empty understanding")
    func noClaimsSuccess() async {
        let actor = ConsumerActor()
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "No specific claims to make",
            claims: [],
            completeness: .insufficient
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.claims.isEmpty)
        #expect(understanding.content == "No specific claims to make")
        #expect(understanding.metadata.completeness == .insufficient)
    }
}

// MARK: — Validation Tests (FM-2)

@Suite("Request Validation")
struct ValidationTests {

    @Test("Reject request with purpose mismatch")
    func purposeMismatch() async {
        let actor = ConsumerActor()
        let engine = MockReasoningEngine()
        let reg = makeRegistration(purpose: ContextPurpose("explain"), engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let frame = makeContextFrame(purpose: ContextPurpose("explain"))
        let request = ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(purpose: ContextPurpose("impact"))
        )

        let result = await actor.invoke(request)
        guard case let .failure(failure) = result else {
            Issue.record("Expected validation failure")
            return
        }
        #expect(failure.mode == .validationFailure)
    }

    @Test("Reject request with empty conversation state data")
    func emptyConversationState() async {
        let actor = ConsumerActor()
        let engine = MockReasoningEngine()
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let emptyState = ConversationState(data: Data(), engineIdentifier: "test", engineVersion: "1.0")
        let request = makeRequest(conversationState: emptyState)

        let result = await actor.invoke(request)
        guard case let .failure(failure) = result else {
            Issue.record("Expected validation failure")
            return
        }
        #expect(failure.mode == .validationFailure)
    }
}

// MARK: — Engine Resolution Tests (FM-6)

@Suite("Engine Resolution")
struct EngineResolutionTests {

    @Test("Fail with engine not found for unregistered purpose")
    func engineNotFound() async {
        let actor = ConsumerActor()
        let reg = makeRegistration(purpose: ContextPurpose("explain"))
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest(purpose: ContextPurpose("impact"))
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected engine not found failure")
            return
        }
        #expect(failure.mode == .engineNotFound)
        #expect(failure.availablePurposes.contains(ContextPurpose("explain")))
    }
}

// MARK: — Grounding Verification Tests (RI-1, FM-3)

@Suite("Grounding Verification")
struct GroundingTests {

    @Test("Ungrounded claims are removed")
    func removeUngroundedClaims() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(content: "Grounded", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)]),
            UnderstandingClaim(content: "Ungrounded", claimType: .derived, confidence: .high, groundingReferences: [UnitIdentifier(rawValue: 999)])
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Mixed claims",
            claims: claims,
            completeness: .complete
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.claims.count == 1)
        #expect(understanding.claims[0].content == "Grounded")
        #expect(understanding.metadata.ungroundedClaimsRemoved == 1)
    }

    @Test("All claims ungrounded produces grounding failure (FM-3)")
    func allUngrounded() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(content: "Bad claim", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 999)])
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Bad understanding",
            claims: claims,
            completeness: .complete
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected grounding failure")
            return
        }
        #expect(failure.mode == .groundingFailure)
    }

    @Test("All claims grounded — RI-1 satisfied")
    func allGrounded() async {
        let actor = ConsumerActor()
        let engine = makeEngineWithGroundedClaims(unitIds: [1, 2])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        for claim in understanding.claims {
            #expect(!claim.groundingReferences.isEmpty)
        }
        #expect(understanding.metadata.ungroundedClaimsRemoved == 0)
    }

    @Test("Grounding coverage reported correctly")
    func groundingCoverage() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(content: "About unit 1", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)])
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Partial coverage",
            claims: claims,
            completeness: .partial
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.metadata.groundingCoverage == 0.5)
    }
}

// MARK: — Confidence Verification Tests (RI-2)

@Suite("Confidence Verification")
struct ConfidenceTests {

    @Test("Confidence capped when exceeding tier — RI-2")
    func confidenceCapping() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(
                content: "Over-confident claim",
                claimType: .factual,
                confidence: .deterministic,
                groundingReferences: [UnitIdentifier(rawValue: 3)]
            )
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Test",
            claims: claims,
            completeness: .complete
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [
            makeContextUnit(id: 3, entity: "SemanticEntity", tier: .t2, confidence: .high)
        ]
        let request = makeRequest(units: units)
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.claims[0].confidence == .high)
        #expect(understanding.metadata.confidenceAdjustments == 1)
    }

    @Test("Confidence not capped when appropriate for tier")
    func confidenceNotCapped() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(
                content: "Correct confidence",
                claimType: .factual,
                confidence: .deterministic,
                groundingReferences: [UnitIdentifier(rawValue: 1)]
            )
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Test",
            claims: claims,
            completeness: .complete
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "Entity", tier: .t0)]
        let request = makeRequest(units: units)
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.claims[0].confidence == .deterministic)
        #expect(understanding.metadata.confidenceAdjustments == 0)
    }

    @Test("High confidence with T1 evidence is valid")
    func highConfidenceT1() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(
                content: "Derived claim",
                claimType: .derived,
                confidence: .high,
                groundingReferences: [UnitIdentifier(rawValue: 1)]
            )
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Test",
            claims: claims,
            completeness: .complete
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "Entity", tier: .t1, confidence: .high)]
        let request = makeRequest(units: units)
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.claims[0].confidence == .high)
        #expect(understanding.metadata.confidenceAdjustments == 0)
    }
}

// MARK: — Engine Failure Tests (FM-1)

@Suite("Reasoning Engine Failure")
struct EngineFailureTests {

    @Test("Primary engine failure invokes fallback")
    func fallbackOnFailure() async {
        let actor = ConsumerActor()

        let primaryEngine = MockReasoningEngine()
        primaryEngine.shouldThrow = true

        let fallbackEngine = makeEngineWithGroundedClaims(unitIds: [1])

        let primaryReg = makeRegistration(engineId: "primary", engine: primaryEngine)
        let fallbackReg = makeRegistration(engineId: "fallback", engine: fallbackEngine, isFallback: true)

        _ = await actor.register(primaryReg)
        _ = await actor.register(fallbackReg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected fallback success")
            return
        }

        #expect(understanding.metadata.usedFallback)
        #expect(understanding.metadata.engineIdentifier == "fallback")
    }

    @Test("Primary and fallback both fail")
    func bothFail() async {
        let actor = ConsumerActor()

        let primaryEngine = MockReasoningEngine()
        primaryEngine.shouldThrow = true

        let fallbackEngine = MockReasoningEngine()
        fallbackEngine.shouldThrow = true

        let primaryReg = makeRegistration(engineId: "primary", engine: primaryEngine)
        let fallbackReg = makeRegistration(engineId: "fallback", engine: fallbackEngine, isFallback: true)

        _ = await actor.register(primaryReg)
        _ = await actor.register(fallbackReg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.mode == .engineFailure)
    }

    @Test("Primary fails with no fallback designated")
    func noFallback() async {
        let actor = ConsumerActor()

        let engine = MockReasoningEngine()
        engine.shouldThrow = true

        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.mode == .engineFailure)
    }

    @Test("Next invocation retries primary engine after failure")
    func retryPrimary() async {
        let actor = ConsumerActor()

        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Success",
            claims: [UnderstandingClaim(content: "Claim", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)])],
            completeness: .complete
        ))
        engine.shouldThrow = true

        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result1 = await actor.invoke(request)
        guard case .failure = result1 else {
            Issue.record("Expected first invocation to fail")
            return
        }

        engine.shouldThrow = false

        let result2 = await actor.invoke(request)
        guard case .success = result2 else {
            Issue.record("Expected second invocation to succeed")
            return
        }
        #expect(engine.invokeCount == 2)
    }
}

// MARK: — Conversation State Tests (FM-5, RI-7, RI-9)

@Suite("Conversation State")
struct ConversationStateTests {

    @Test("Conversation state passed to engine and returned in understanding")
    func conversationFlow() async {
        let actor = ConsumerActor()

        let outputState = ConversationState(
            data: "conversation context".data(using: .utf8)!,
            engineIdentifier: "test-engine",
            engineVersion: "1.0"
        )
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Follow-up answer",
            claims: [UnderstandingClaim(content: "Claim", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)])],
            completeness: .complete,
            conversationState: outputState
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.conversationState != nil)
        #expect(understanding.conversationState?.engineIdentifier == "test-engine")
    }

    @Test("Conversation state discarded on engine mismatch (FM-5)")
    func engineMismatch() async {
        let actor = ConsumerActor()
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let staleState = ConversationState(
            data: "old context".data(using: .utf8)!,
            engineIdentifier: "other-engine",
            engineVersion: "1.0"
        )
        let request = makeRequest(conversationState: staleState)
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success (FM-5 — succeeds as new conversation)")
            return
        }

        #expect(understanding.metadata.conversationStateDiscarded)
    }

    @Test("Oversized conversation state discarded — RI-7")
    func oversizedState() async {
        let actor = ConsumerActor()
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let bigData = Data(repeating: 0xFF, count: ConversationState.maxSizeBytes + 1)
        let bigState = ConversationState(
            data: bigData,
            engineIdentifier: "test-engine",
            engineVersion: "1.0"
        )
        let request = makeRequest(conversationState: bigState)
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success (oversized input discarded)")
            return
        }

        #expect(understanding.metadata.conversationStateDiscarded)
    }

    @Test("Output conversation state discarded if oversized — RI-7")
    func oversizedOutputState() async {
        let actor = ConsumerActor()
        let bigData = Data(repeating: 0xAA, count: ConversationState.maxSizeBytes + 1)
        let bigOutputState = ConversationState(
            data: bigData,
            engineIdentifier: "test-engine",
            engineVersion: "1.0"
        )
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Answer",
            claims: [UnderstandingClaim(content: "Claim", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)])],
            completeness: .complete,
            conversationState: bigOutputState
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.conversationState == nil)
    }

    @Test("Conversation state boundedness constant is defined")
    func boundednessConstant() {
        #expect(ConversationState.maxSizeBytes == 256 * 1024)
    }
}

// MARK: — Consumer Demand Signaling Tests (PC-4)

@Suite("Consumer Demand Signaling")
struct DemandSignalingTests {

    @Test("Demand signal emitted for degraded T2 content")
    func demandSignalEmitted() async {
        let sink = MockDemandSignalSink()
        let actor = ConsumerActor(demandSignalSink: sink)
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "TestEntity", tier: .t0)]
        let request = makeRequest(units: units, degradationLevel: .t0t1Only)
        let result = await actor.invoke(request)

        guard case .success = result else {
            Issue.record("Expected success")
            return
        }

        #expect(sink.submittedSignals.count == 1)
        #expect(sink.submittedSignals[0].tier == .t2)
    }

    @Test("No demand signal when context frame is full")
    func noDemandForFull() async {
        let sink = MockDemandSignalSink()
        let actor = ConsumerActor(demandSignalSink: sink)
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "TestEntity", tier: .t0)]
        let request = makeRequest(units: units, degradationLevel: .full)
        _ = await actor.invoke(request)

        #expect(sink.submittedSignals.isEmpty)
    }

    @Test("Demand signals deduplicated within window")
    func deduplication() async {
        let sink = MockDemandSignalSink()
        let actor = ConsumerActor(demandSignalSink: sink)
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "TestEntity", tier: .t0)]
        let request = makeRequest(units: units, degradationLevel: .t0Only)

        _ = await actor.invoke(request)
        _ = await actor.invoke(request)

        #expect(sink.submittedSignals.count == 1)
    }

    @Test("No demand signal when no sink available")
    func noSinkGraceful() async {
        let actor = ConsumerActor(demandSignalSink: nil)
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "TestEntity", tier: .t0)]
        let request = makeRequest(units: units, degradationLevel: .t0Only)
        let result = await actor.invoke(request)

        guard case .success = result else {
            Issue.record("Expected success even without demand sink")
            return
        }
    }
}

// MARK: — Completeness Honesty Tests (RI-5)

@Suite("Completeness Honesty")
struct CompletenessTests {

    @Test("Partial completeness reported by engine is preserved")
    func partialCompleteness() async {
        let actor = ConsumerActor()
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Partial answer",
            claims: [UnderstandingClaim(content: "Claim", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)])],
            completeness: .partial
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.metadata.completeness == .partial)
    }

    @Test("Insufficient completeness reported by engine is preserved")
    func insufficientCompleteness() async {
        let actor = ConsumerActor()
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Limited answer",
            claims: [UnderstandingClaim(content: "Claim", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 1)])],
            completeness: .insufficient
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .success(understanding) = result else {
            Issue.record("Expected success")
            return
        }

        #expect(understanding.metadata.completeness == .insufficient)
    }
}

// MARK: — Failure Diagnostic Tests (RI-8)

@Suite("Failure Diagnostics")
struct FailureDiagnosticTests {

    @Test("FM-2 validation failure includes diagnostic")
    func validationDiagnostic() async {
        let actor = ConsumerActor()
        let reg = makeRegistration(purpose: ContextPurpose("explain"))
        _ = await actor.register(reg)
        await actor.activate()

        let frame = makeContextFrame(purpose: ContextPurpose("explain"))
        let request = ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(purpose: ContextPurpose("impact"))
        )
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.mode == .validationFailure)
        #expect(!failure.diagnostic.isEmpty)
        #expect(failure.requestedPurpose == ContextPurpose("impact"))
    }

    @Test("FM-6 engine not found includes available purposes")
    func engineNotFoundDiagnostic() async {
        let actor = ConsumerActor()
        let reg = makeRegistration(purpose: ContextPurpose("explain"))
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest(purpose: ContextPurpose("unknown"))
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.mode == .engineNotFound)
        #expect(failure.availablePurposes.contains(ContextPurpose("explain")))
        #expect(!failure.diagnostic.isEmpty)
    }

    @Test("FM-1 engine failure includes diagnostic")
    func engineFailureDiagnostic() async {
        let actor = ConsumerActor()
        let engine = MockReasoningEngine()
        engine.shouldThrow = true
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.mode == .engineFailure)
        #expect(!failure.diagnostic.isEmpty)
    }

    @Test("FM-3 grounding failure includes diagnostic")
    func groundingFailureDiagnostic() async {
        let actor = ConsumerActor()
        let claims = [
            UnderstandingClaim(content: "Bad", claimType: .factual, confidence: .deterministic, groundingReferences: [UnitIdentifier(rawValue: 999)])
        ]
        let engine = MockReasoningEngine(output: ReasoningEngineOutput(
            content: "Bad", claims: claims, completeness: .complete
        ))
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result = await actor.invoke(request)

        guard case let .failure(failure) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(failure.mode == .groundingFailure)
        #expect(!failure.diagnostic.isEmpty)
    }
}

// MARK: — Consumer Statelessness Tests (RI-3)

@Suite("Consumer Statelessness")
struct StatelessnessTests {

    @Test("Identical requests produce structurally equivalent results")
    func identicalRequests() async {
        let actor = ConsumerActor()
        let engine = makeEngineWithGroundedClaims(unitIds: [1, 2])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let request = makeRequest()
        let result1 = await actor.invoke(request)
        let result2 = await actor.invoke(request)

        guard case let .success(u1) = result1, case let .success(u2) = result2 else {
            Issue.record("Expected both invocations to succeed")
            return
        }

        #expect(u1.claims.count == u2.claims.count)
        #expect(u1.metadata.purpose == u2.metadata.purpose)
        #expect(u1.metadata.completeness == u2.metadata.completeness)
    }
}

// MARK: — No DIR Side Effects Tests (RI-6)

@Suite("No DIR Side Effects")
struct SideEffectTests {

    @Test("Consumer invocation does not modify DIR")
    func noDIRSideEffects() async {
        // ConsumerRuntime has no DIRWriteAccess — it cannot modify the DIR.
        // The only outbound effect is advisory demand signals via DemandSignalSink.
        let sink = MockDemandSignalSink()
        let actor = ConsumerActor(demandSignalSink: sink)
        let engine = makeEngineWithGroundedClaims(unitIds: [1])
        let reg = makeRegistration(engine: engine)
        _ = await actor.register(reg)
        await actor.activate()

        let units = [makeContextUnit(id: 1, entity: "TestEntity", tier: .t0)]
        let request = makeRequest(units: units, degradationLevel: .t0Only)
        _ = await actor.invoke(request)

        // Demand signals are advisory — not state modifications (RI-6)
        for signal in sink.submittedSignals {
            #expect(signal.tier == .t2)
        }
    }
}

// MARK: — Consumer Runtime Type Tests

@Suite("Consumer Runtime Types")
struct TypeTests {

    @Test("ConsumerRuntimeState transitions")
    func stateTransitions() {
        #expect(ConsumerRuntimeState.unavailable.canTransition(to: .available))
        #expect(ConsumerRuntimeState.available.canTransition(to: .terminated))
        #expect(!ConsumerRuntimeState.unavailable.canTransition(to: .terminated))
        #expect(!ConsumerRuntimeState.terminated.canTransition(to: .available))
        #expect(!ConsumerRuntimeState.terminated.canTransition(to: .unavailable))
        #expect(!ConsumerRuntimeState.available.canTransition(to: .unavailable))
    }

    @Test("OutputSpecification defaults")
    func outputSpecDefaults() {
        let spec = OutputSpecification(purpose: ContextPurpose("explain"))
        #expect(spec.outputClass == .human)
        #expect(spec.maxLength == nil)
        #expect(spec.detailLevel == .standard)
        #expect(!spec.isFollowUp)
    }

    @Test("ConversationState size tracking")
    func conversationStateSize() {
        let data = "test data".data(using: .utf8)!
        let state = ConversationState(data: data, engineIdentifier: "e1", engineVersion: "1.0")
        #expect(state.sizeBytes == data.count)
    }

    @Test("ClaimType enumeration")
    func claimTypes() {
        let types: [ClaimType] = [.factual, .derived, .interpretive, .inferred]
        #expect(types.count == 4)
    }

    @Test("ConsumerFailureMode enumeration")
    func failureModes() {
        let modes: [ConsumerFailureMode] = [
            .engineFailure, .validationFailure, .groundingFailure,
            .budgetExhaustion, .conversationStateCorruption,
            .engineNotFound, .contextStaleness, .terminated
        ]
        #expect(modes.count == 8)
    }

    @Test("Understanding construction")
    func understandingConstruction() {
        let claim = UnderstandingClaim(
            content: "Test",
            claimType: .factual,
            confidence: .deterministic,
            groundingReferences: [UnitIdentifier(rawValue: 1)]
        )
        let meta = UnderstandingMetadata(
            purpose: ContextPurpose("test"),
            outputClass: .human,
            engineIdentifier: "e1",
            engineVersion: "1.0",
            contextFrameEpoch: Epoch(value: 1),
            degradationLevel: .full,
            reasoningDuration: 0.5,
            groundingCoverage: 1.0,
            tierDistribution: [.t0: 1],
            completeness: .complete
        )
        let understanding = Understanding(
            content: "Test content",
            claims: [claim],
            metadata: meta
        )
        #expect(understanding.claims.count == 1)
        #expect(understanding.content == "Test content")
        #expect(understanding.conversationState == nil)
    }
}

// MARK: — Multi-Purpose Tests

@Suite("Multi-Purpose Engine Support")
struct MultiPurposeTests {

    @Test("Different purposes route to different engines")
    func purposeRouting() async {
        let actor = ConsumerActor()

        let explainEngine = makeEngineWithGroundedClaims(unitIds: [1])
        let impactEngine = makeEngineWithGroundedClaims(unitIds: [1], claimType: .derived, confidence: .high)

        _ = await actor.register(makeRegistration(
            purpose: ContextPurpose("explain"),
            engineId: "explain-engine",
            engine: explainEngine
        ))
        _ = await actor.register(makeRegistration(
            purpose: ContextPurpose("impact"),
            engineId: "impact-engine",
            engine: impactEngine
        ))
        await actor.activate()

        let explainRequest = makeRequest(purpose: ContextPurpose("explain"))
        let impactRequest = makeRequest(purpose: ContextPurpose("impact"))

        let explainResult = await actor.invoke(explainRequest)
        let impactResult = await actor.invoke(impactRequest)

        guard case let .success(explainU) = explainResult,
              case let .success(impactU) = impactResult else {
            Issue.record("Expected both to succeed")
            return
        }

        #expect(explainU.metadata.engineIdentifier == "explain-engine")
        #expect(impactU.metadata.engineIdentifier == "impact-engine")
    }
}
