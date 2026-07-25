// ExplainReasoningEngineTests.swift — DecodeTests
// Tests for the production Explain ReasoningEngine.

import Testing
import Foundation
@testable import Decode
import ConsumerRuntime
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Mock AI Provider for Tests

private final class MockExplainAIProvider: AIProviderProtocol, @unchecked Sendable {
    var completionResponse: String = "This code defines a service that manages user sessions."
    var shouldThrow: Bool = false

    func generateCompletion(
        userContent: String,
        systemPrompt: String,
        mode: String?
    ) async throws -> String {
        if shouldThrow {
            throw NSError(domain: "MockAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock AI failure"])
        }
        return completionResponse
    }

    func streamChat(
        messages: [AIMessage],
        systemPrompt: String,
        mode: String?,
        contextTier: String?,
        explanationProfile: String?,
        language: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(completionResponse)
            continuation.finish()
        }
    }

    func validateConnection() async throws {}
}

// MARK: - Test Helpers

private let testHash = ContentHash(bytes: Array(repeating: 0, count: 32))

/// Creates a test AtomicUnit with the given parameters.
private func makeTestUnit(
    id: UInt64,
    entityName: String,
    predicateName: String,
    predicateDomain: String = "structure",
    value: TypedValue,
    tier: Tier = .t0
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entityName)),
        predicate: PredicateIdentifier(name: predicateName, domain: predicateDomain),
        value: value,
        tier: tier,
        provenance: ProvenanceRecord(
            producer: "test-producer",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: tier == .t0 ? .deterministic : .high,
        grounding: .direct(SourcePosition(
            filePath: "test.swift",
            startLine: 1,
            endLine: 10,
            fileVersion: testHash
        )),
        version: VersionStamp(singleSource: testHash)
    )
}

/// Creates a ContextFrame from a list of AtomicUnits.
private func makeContextFrame(
    units: [AtomicUnit],
    purpose: ContextPurpose = ContextPurpose("explain")
) -> ContextFrame {
    let contextUnits = units.map { unit in
        ContextUnit(
            annotatedUnit: AnnotatedUnit(
                unit: unit,
                provenance: EvidenceProvenance(stage: .direct, path: ["direct"]),
                distance: 0
            ),
            role: ContextRole(stratumName: "primary", reason: "test anchor")
        )
    }

    let stratum = FilledStratum(
        name: "primary",
        priority: 0,
        units: contextUnits,
        budgetAllocated: 1000,
        budgetUsed: units.count
    )

    let tierCounts: [Tier: Int] = Dictionary(
        units.map { ($0.tier, 1) },
        uniquingKeysWith: +
    )

    return ContextFrame(
        anchors: units.compactMap { unit in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        },
        purpose: purpose,
        strategyVersion: "test-1.0",
        strata: [stratum],
        budgetSummary: BudgetSummary(total: 1000, denomination: .units, used: units.count),
        metadata: ContextFrameMetadata(
            evidenceSetSize: units.count,
            selectedCount: units.count,
            tierCounts: tierCounts,
            stratumCounts: ["primary": units.count],
            coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
            degradationLevel: .full,
            freshnessState: .fresh,
            assemblyDuration: 0.001,
            strategyVersion: "test-1.0",
            committedEpoch: Epoch(value: 1),
            budgetInsufficient: false
        )
    )
}

// MARK: - Tests

@Suite("ExplainReasoningEngine")
struct ExplainReasoningEngineTests {

    @Test("Engine produces valid output with AI provider")
    func testReasonWithAIProvider() async throws {
        let mockProvider = MockExplainAIProvider()
        mockProvider.completionResponse = "SessionManager handles user session lifecycle."

        let engine = ExplainReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "SessionManager", predicateName: "kind", value: .string("class")),
            makeTestUnit(id: 2, entityName: "SessionManager", predicateName: "purpose", value: .text("Manages user sessions"), tier: .t1),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        #expect(output.content == "SessionManager handles user session lifecycle.")
        #expect(!output.claims.isEmpty)
        #expect(output.completeness == .complete)

        // Verify all claims are grounded
        for claim in output.claims {
            #expect(!claim.groundingReferences.isEmpty, "Claim must have at least one grounding reference")
        }
    }

    @Test("Engine produces deterministic fallback without AI provider")
    func testReasonWithoutAIProvider() async throws {
        let engine = ExplainReasoningEngine(
            aiProvider: { nil }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("struct")),
            makeTestUnit(id: 2, entityName: "UserService", predicateName: "hasMethod", value: .string("fetchUser")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        #expect(output.content.contains("UserService"))
        #expect(output.completeness == .partial)
        #expect(!output.claims.isEmpty)

        for claim in output.claims {
            #expect(!claim.groundingReferences.isEmpty)
        }
    }

    @Test("Engine handles empty context frame")
    func testEmptyContextFrame() async throws {
        let engine = ExplainReasoningEngine(
            aiProvider: { nil }
        )

        let frame = makeContextFrame(units: [])
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        #expect(output.completeness == .insufficient)
        #expect(output.claims.isEmpty)
    }

    @Test("Engine propagates AI provider errors")
    func testAIProviderError() async throws {
        let mockProvider = MockExplainAIProvider()
        mockProvider.shouldThrow = true

        let engine = ExplainReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        await #expect(throws: (any Error).self) {
            try await engine.reason(
                contextFrame: frame,
                outputSpecification: spec,
                conversationState: nil
            )
        }
    }

    @Test("Claims are grounded to correct unit IDs")
    func testClaimGrounding() async throws {
        let engine = ExplainReasoningEngine(
            aiProvider: { nil }
        )

        let unit1 = makeTestUnit(id: 10, entityName: "AppDelegate", predicateName: "kind", value: .string("class"))
        let unit2 = makeTestUnit(id: 20, entityName: "AppDelegate", predicateName: "conformsTo", value: .string("NSApplicationDelegate"))
        let unit3 = makeTestUnit(id: 30, entityName: "ViewModel", predicateName: "kind", value: .string("struct"))

        let frame = makeContextFrame(units: [unit1, unit2, unit3])
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        let appDelegateClaims = output.claims.filter { $0.content.contains("AppDelegate") }
        let viewModelClaims = output.claims.filter { $0.content.contains("ViewModel") }

        #expect(!appDelegateClaims.isEmpty)
        #expect(!viewModelClaims.isEmpty)

        // AppDelegate claims should reference unit IDs 10 and/or 20
        for claim in appDelegateClaims {
            let refIds = Set(claim.groundingReferences.map(\.rawValue))
            #expect(refIds.contains(10) || refIds.contains(20))
        }

        // ViewModel claims should reference unit ID 30
        for claim in viewModelClaims {
            let refIds = Set(claim.groundingReferences.map(\.rawValue))
            #expect(refIds.contains(30))
        }
    }

    @Test("Engine handles relationship units")
    func testRelationshipUnits() async throws {
        let engine = ExplainReasoningEngine(
            aiProvider: { nil }
        )

        let entityUnit = makeTestUnit(id: 1, entityName: "Controller", predicateName: "kind", value: .string("class"))

        let relUnit = AtomicUnit(
            id: UnitIdentifier(rawValue: 2),
            subject: .pair(EntityPair(
                source: EntityReference(qualifiedName: "Controller"),
                target: EntityReference(qualifiedName: "Service")
            )),
            predicate: PredicateIdentifier(name: "calls", domain: "dependency"),
            value: .boolean(true),
            tier: .t0,
            provenance: ProvenanceRecord(producer: "test", method: .extraction, timestamp: Date(timeIntervalSince1970: 0)),
            confidence: .deterministic,
            grounding: .direct(SourcePosition(filePath: "test.swift", startLine: 1, endLine: 5, fileVersion: testHash)),
            version: VersionStamp(singleSource: testHash)
        )

        let frame = makeContextFrame(units: [entityUnit, relUnit])
        let spec = OutputSpecification(purpose: ContextPurpose("explain"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        let relClaims = output.claims.filter { $0.content.contains("calls") }
        #expect(!relClaims.isEmpty)

        for claim in relClaims {
            #expect(claim.groundingReferences.contains(UnitIdentifier(rawValue: 2)))
        }
    }

    @Test("Engine integrates with ConsumerActor end-to-end")
    func testConsumerActorIntegration() async throws {
        let mockProvider = MockExplainAIProvider()
        mockProvider.completionResponse = "The DataStore manages persistence."

        let engine = ExplainReasoningEngine(
            aiProvider: { mockProvider }
        )

        let consumer = ConsumerActor()
        await consumer.activate()

        let registered = await consumer.register(EngineRegistration(
            purpose: ContextPurpose("explain"),
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version,
            engine: engine,
            isFallback: false
        ))
        #expect(registered)

        let units = [
            makeTestUnit(id: 1, entityName: "DataStore", predicateName: "kind", value: .string("actor")),
            makeTestUnit(id: 2, entityName: "DataStore", predicateName: "purpose", value: .text("Manages persistence"), tier: .t1),
        ]
        let frame = makeContextFrame(units: units)
        let request = ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: ContextPurpose("explain"),
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )

        let result = await consumer.invoke(request)

        switch result {
        case .success(let understanding):
            #expect(understanding.content == "The DataStore manages persistence.")
            #expect(!understanding.claims.isEmpty)
            #expect(understanding.metadata.engineIdentifier == ExplainReasoningEngine.identifier)
            #expect(understanding.metadata.purpose == ContextPurpose("explain"))

            for claim in understanding.claims {
                #expect(!claim.groundingReferences.isEmpty)
            }

        case .failure(let failure):
            Issue.record("Consumer invocation should succeed but failed: \(failure.diagnostic)")
        }

        await consumer.shutdown()
    }
}
