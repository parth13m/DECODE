// ImproveReasoningEngineTests.swift — DecodeTests
// Tests for the production Improve ReasoningEngine.

import Testing
import Foundation
@testable import Decode
import ConsumerRuntime
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Mock AI Provider for Tests

private final class MockImproveAIProvider: AIProviderProtocol, @unchecked Sendable {
    var completionResponse: String = """
        <improvement_summary>
        Simplified the loop by using map instead of manual iteration.
        </improvement_summary>
        <improved_code>
        let results = items.map { transform($0) }
        </improved_code>
        """
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

private func makeContextFrame(
    units: [AtomicUnit],
    purpose: ContextPurpose = ContextPurpose("improve")
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

@Suite("ImproveReasoningEngine")
struct ImproveReasoningEngineTests {

    @Test("Engine produces valid improvement output with AI provider")
    func testReasonWithAIProvider() async throws {
        let mockProvider = MockImproveAIProvider()
        mockProvider.completionResponse = """
            <improvement_summary>
            Replaced manual loop with map for clarity.
            </improvement_summary>
            <improved_code>
            let results = items.map { transform($0) }
            </improved_code>
            """

        let engine = ImproveReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "DataProcessor", predicateName: "kind", value: .string("class")),
            makeTestUnit(id: 2, entityName: "DataProcessor", predicateName: "hasMethod", value: .string("processItems")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        // Content should contain both parsed summary and improved code.
        #expect(output.content.contains("Replaced manual loop"))
        #expect(output.content.contains("items.map"))
        #expect(!output.claims.isEmpty)
        #expect(output.completeness == .complete)

        for claim in output.claims {
            #expect(!claim.groundingReferences.isEmpty, "Claim must have at least one grounding reference")
        }
    }

    @Test("Engine handles no-improvement response correctly")
    func testNoImprovementPath() async throws {
        let mockProvider = MockImproveAIProvider()
        mockProvider.completionResponse = """
            <improvement_summary>
            No meaningful improvement found.

            The current implementation is already clear and appropriate for its purpose.
            </improvement_summary>
            """

        let engine = ImproveReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "CleanCode", predicateName: "kind", value: .string("struct")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        // No-improvement is a successful outcome.
        #expect(output.content.contains("No meaningful improvement"))
        #expect(!output.content.contains("<improved_code>"))
        #expect(output.completeness == .complete)
        #expect(!output.claims.isEmpty)
    }

    @Test("Engine produces deterministic fallback without AI provider")
    func testReasonWithoutAIProvider() async throws {
        let engine = ImproveReasoningEngine(
            aiProvider: { nil }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("struct")),
            makeTestUnit(id: 2, entityName: "UserService", predicateName: "hasMethod", value: .string("fetchUser")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

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
        let engine = ImproveReasoningEngine(
            aiProvider: { nil }
        )

        let frame = makeContextFrame(units: [])
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

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
        let mockProvider = MockImproveAIProvider()
        mockProvider.shouldThrow = true

        let engine = ImproveReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

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
        let engine = ImproveReasoningEngine(
            aiProvider: { nil }
        )

        let unit1 = makeTestUnit(id: 10, entityName: "Controller", predicateName: "kind", value: .string("class"))
        let unit2 = makeTestUnit(id: 20, entityName: "Controller", predicateName: "hasMethod", value: .string("handleRequest"))
        let unit3 = makeTestUnit(id: 30, entityName: "Router", predicateName: "kind", value: .string("struct"))

        let frame = makeContextFrame(units: [unit1, unit2, unit3])
        let spec = OutputSpecification(purpose: ContextPurpose("improve"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        let controllerClaims = output.claims.filter { $0.content.contains("Controller") }
        let routerClaims = output.claims.filter { $0.content.contains("Router") }

        #expect(!controllerClaims.isEmpty)
        #expect(!routerClaims.isEmpty)

        for claim in controllerClaims {
            let refIds = Set(claim.groundingReferences.map(\.rawValue))
            #expect(refIds.contains(10) || refIds.contains(20))
        }

        for claim in routerClaims {
            let refIds = Set(claim.groundingReferences.map(\.rawValue))
            #expect(refIds.contains(30))
        }
    }

    @Test("Engine integrates with ConsumerActor end-to-end")
    func testConsumerActorIntegration() async throws {
        let mockProvider = MockImproveAIProvider()
        mockProvider.completionResponse = """
            <improvement_summary>
            Extracted repeated logic into a helper method.
            </improvement_summary>
            <improved_code>
            func process() { helper() }
            </improved_code>
            """

        let engine = ImproveReasoningEngine(
            aiProvider: { mockProvider }
        )

        let consumer = ConsumerActor()
        await consumer.activate()

        let registered = await consumer.register(EngineRegistration(
            purpose: ContextPurpose("improve"),
            engineIdentifier: ImproveReasoningEngine.identifier,
            engineVersion: ImproveReasoningEngine.version,
            engine: engine,
            isFallback: false
        ))
        #expect(registered)

        let units = [
            makeTestUnit(id: 1, entityName: "Processor", predicateName: "kind", value: .string("class")),
            makeTestUnit(id: 2, entityName: "Processor", predicateName: "hasMethod", value: .string("run")),
        ]
        let frame = makeContextFrame(units: units)
        let request = ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: ContextPurpose("improve"),
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: nil
        )

        let result = await consumer.invoke(request)

        switch result {
        case .success(let understanding):
            #expect(understanding.content.contains("Extracted repeated logic"))
            #expect(!understanding.claims.isEmpty)
            #expect(understanding.metadata.engineIdentifier == ImproveReasoningEngine.identifier)
            #expect(understanding.metadata.purpose == ContextPurpose("improve"))

            for claim in understanding.claims {
                #expect(!claim.groundingReferences.isEmpty)
            }

        case .failure(let failure):
            Issue.record("Consumer invocation should succeed but failed: \(failure.diagnostic)")
        }

        await consumer.shutdown()
    }
}
