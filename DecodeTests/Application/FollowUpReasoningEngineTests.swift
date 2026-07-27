// FollowUpReasoningEngineTests.swift — DecodeTests
// Tests for the production FollowUp ReasoningEngine.

import Testing
import Foundation
@testable import Decode
import ConsumerRuntime
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Mock AI Provider for Tests

private final class MockFollowUpAIProvider: AIProviderProtocol, @unchecked Sendable {
    var completionResponse: String = "This code manages user sessions."
    var streamResponse: String = "The method handles state transitions."
    var shouldThrow: Bool = false
    var lastMessages: [AIMessage]?

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
        if shouldThrow {
            throw NSError(domain: "MockAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock AI failure"])
        }
        lastMessages = messages
        let response = streamResponse
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
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
    purpose: ContextPurpose = ContextPurpose("followup")
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
        budgetSummary: BudgetSummary(total: 1000, denomination: .unitCount, used: units.count),
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

@Suite("FollowUpReasoningEngine")
struct FollowUpReasoningEngineTests {

    @Test("Initial invocation produces explanation with conversation state")
    func testInitialInvocation() async throws {
        let mockProvider = MockFollowUpAIProvider()
        mockProvider.completionResponse = "SessionManager handles user session lifecycle."

        let engine = FollowUpReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "SessionManager", predicateName: "kind", value: .string("class")),
            makeTestUnit(id: 2, entityName: "SessionManager", predicateName: "purpose", value: .text("Manages user sessions"), tier: .t1),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        #expect(output.content == "SessionManager handles user session lifecycle.")
        #expect(!output.claims.isEmpty)
        #expect(output.completeness == .complete)

        // Must produce conversation state for future follow-ups.
        #expect(output.conversationState != nil)
        #expect(output.conversationState?.engineIdentifier == FollowUpReasoningEngine.identifier)
        #expect(output.conversationState?.engineVersion == FollowUpReasoningEngine.version)

        for claim in output.claims {
            #expect(!claim.groundingReferences.isEmpty)
        }
    }

    @Test("Follow-up invocation uses prior state and streamChat")
    func testFollowUpInvocation() async throws {
        let mockProvider = MockFollowUpAIProvider()
        mockProvider.completionResponse = "Initial explanation."
        mockProvider.streamResponse = "The method uses a state machine pattern."

        let engine = FollowUpReasoningEngine(
            aiProvider: { mockProvider }
        )

        // Step 1: Initial invocation to get conversation state.
        let units = [
            makeTestUnit(id: 1, entityName: "StateMachine", predicateName: "kind", value: .string("class")),
            makeTestUnit(id: 2, entityName: "StateMachine", predicateName: "hasMethod", value: .string("transition")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let initialOutput = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        guard let conversationState = initialOutput.conversationState else {
            Issue.record("Initial invocation must produce conversation state")
            return
        }

        // Step 2: Follow-up invocation with the conversation state.
        // Add a question unit to the frame.
        let followUpUnits = [
            makeTestUnit(id: 1, entityName: "StateMachine", predicateName: "kind", value: .string("class")),
            makeTestUnit(id: 3, entityName: "Query", predicateName: "question", value: .text("How does the transition method work?")),
        ]
        let followUpFrame = makeContextFrame(units: followUpUnits)

        let followUpOutput = try await engine.reason(
            contextFrame: followUpFrame,
            outputSpecification: spec,
            conversationState: conversationState
        )

        #expect(followUpOutput.content == "The method uses a state machine pattern.")
        #expect(!followUpOutput.claims.isEmpty)
        #expect(followUpOutput.completeness == .complete)

        // Must produce updated conversation state.
        #expect(followUpOutput.conversationState != nil)

        // Verify streamChat was called with 3 messages.
        #expect(mockProvider.lastMessages?.count == 3)
        #expect(mockProvider.lastMessages?[0].role == .user)       // context summary
        #expect(mockProvider.lastMessages?[1].role == .assistant)  // prior response
        #expect(mockProvider.lastMessages?[2].role == .user)       // follow-up question
        #expect(mockProvider.lastMessages?[2].content.contains("How does the transition method work?") == true)
    }

    @Test("Conversation state round-trips correctly")
    func testConversationStateRoundTrip() async throws {
        let mockProvider = MockFollowUpAIProvider()
        mockProvider.completionResponse = "Explanation of code."
        mockProvider.streamResponse = "Follow-up answer."

        let engine = FollowUpReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        // Initial → get state
        let output1 = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: nil)
        guard let state1 = output1.conversationState else {
            Issue.record("Must produce conversation state")
            return
        }

        // Follow-up → get updated state
        let output2 = try await engine.reason(contextFrame: frame, outputSpecification: spec, conversationState: state1)
        guard let state2 = output2.conversationState else {
            Issue.record("Follow-up must produce updated state")
            return
        }

        // State must carry the engine identifier.
        #expect(state1.engineIdentifier == FollowUpReasoningEngine.identifier)
        #expect(state2.engineIdentifier == FollowUpReasoningEngine.identifier)

        // State size must be within bounds.
        #expect(state1.sizeBytes <= ConversationState.maxSizeBytes)
        #expect(state2.sizeBytes <= ConversationState.maxSizeBytes)
    }

    @Test("Engine produces deterministic fallback without AI provider")
    func testDeterministicFallback() async throws {
        let engine = FollowUpReasoningEngine(
            aiProvider: { nil }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("struct")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        #expect(output.content.contains("UserService"))
        #expect(output.completeness == .partial)
        #expect(!output.claims.isEmpty)

        // Deterministic fallback still produces conversation state.
        #expect(output.conversationState != nil)
    }

    @Test("Engine handles empty context frame")
    func testEmptyContextFrame() async throws {
        let engine = FollowUpReasoningEngine(
            aiProvider: { nil }
        )

        let frame = makeContextFrame(units: [])
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: nil
        )

        #expect(output.completeness == .insufficient)
        #expect(output.claims.isEmpty)
        #expect(output.conversationState == nil)
    }

    @Test("Engine propagates AI provider errors")
    func testAIProviderError() async throws {
        let mockProvider = MockFollowUpAIProvider()
        mockProvider.shouldThrow = true

        let engine = FollowUpReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        await #expect(throws: (any Error).self) {
            try await engine.reason(
                contextFrame: frame,
                outputSpecification: spec,
                conversationState: nil
            )
        }
    }

    @Test("Engine handles corrupted conversation state gracefully")
    func testCorruptedConversationState() async throws {
        let mockProvider = MockFollowUpAIProvider()
        mockProvider.completionResponse = "Fresh explanation."

        let engine = FollowUpReasoningEngine(
            aiProvider: { mockProvider }
        )

        let units = [
            makeTestUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeContextFrame(units: units)
        let spec = OutputSpecification(purpose: ContextPurpose("followup"), outputClass: .human, detailLevel: .standard)

        // Create corrupted state.
        let corruptedState = ConversationState(
            data: Data("not valid json".utf8),
            engineIdentifier: FollowUpReasoningEngine.identifier,
            engineVersion: FollowUpReasoningEngine.version
        )

        // Should fall back to initial invocation, not crash.
        let output = try await engine.reason(
            contextFrame: frame,
            outputSpecification: spec,
            conversationState: corruptedState
        )

        #expect(output.content == "Fresh explanation.")
        #expect(output.completeness == .complete)
        #expect(output.conversationState != nil)
    }

    @Test("Engine integrates with ConsumerActor end-to-end")
    func testConsumerActorIntegration() async throws {
        let mockProvider = MockFollowUpAIProvider()
        mockProvider.completionResponse = "The DataStore manages persistence."

        let engine = FollowUpReasoningEngine(
            aiProvider: { mockProvider }
        )

        let consumer = ConsumerActor()
        await consumer.activate()

        let registered = await consumer.register(EngineRegistration(
            purpose: ContextPurpose("followup"),
            engineIdentifier: FollowUpReasoningEngine.identifier,
            engineVersion: FollowUpReasoningEngine.version,
            engine: engine,
            isFallback: false
        ))
        #expect(registered)

        let units = [
            makeTestUnit(id: 1, entityName: "DataStore", predicateName: "kind", value: .string("actor")),
        ]
        let frame = makeContextFrame(units: units)
        let request = ConsumerRequest(
            contextFrame: frame,
            outputSpecification: OutputSpecification(
                purpose: ContextPurpose("followup"),
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
            #expect(understanding.metadata.engineIdentifier == FollowUpReasoningEngine.identifier)
            #expect(understanding.metadata.purpose == ContextPurpose("followup"))

            // Conversation state should flow through the pipeline.
            #expect(understanding.conversationState != nil)

        case .failure(let failure):
            Issue.record("Consumer invocation should succeed but failed: \(failure.diagnostic)")
        }

        await consumer.shutdown()
    }
}
