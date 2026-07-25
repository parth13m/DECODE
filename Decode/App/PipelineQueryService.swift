// PipelineQueryService.swift — Decode App
// IAG-004 §18: Orchestrates a complete query through the understanding pipeline.
//
// Bridges the gap between coordinator-level requests (file path + entity name)
// and the pipeline's protocol chain (retrieval → assembly → consumer → Understanding).

import Foundation
import DIRCore
import RetrievalRuntime
import ContextAssembly
import ConsumerRuntime
import UpdateEngine

/// Orchestrates a complete understanding query through the Software Intelligence Platform.
///
/// Given a file path and an entity reference, this service:
/// 1. Ensures the file has been processed through the write pipeline (DIR population)
/// 2. Retrieves evidence for the entity via `EvidenceRetrieval`
/// 3. Assembles a context frame via `ContextAssembling`
/// 4. Invokes the appropriate reasoning engine via `ConsumerInvocation`
/// 5. Returns the produced `Understanding`
///
/// This is the primary production entry point for exercising the full platform.
/// Coordinators will call this instead of direct AI provider invocation.
final class PipelineQueryService: Sendable {

    private let understandingSystem: UnderstandingSystem

    init(understandingSystem: UnderstandingSystem) {
        self.understandingSystem = understandingSystem
    }

    /// Executes a complete understanding query for an entity in a file.
    ///
    /// - Parameters:
    ///   - filePath: The source file to analyze.
    ///   - entityName: The qualified name of the entity to explain.
    ///   - purpose: The consumer purpose (e.g., "explain", "improve", "followup").
    ///   - conversationState: Prior conversation state for follow-up queries.
    /// - Returns: The pipeline result — either a produced `Understanding` or a failure description.
    func query(
        filePath: String,
        entityName: String,
        purpose: String = "explain",
        conversationState: ConversationState? = nil
    ) async -> PipelineQueryResult {
        let contextPurpose = ContextPurpose(purpose)

        // Step 1: Ensure file is processed through the write pipeline.
        let changeEvent = UpdateEngine.FileChangeEvent(
            filePath: filePath,
            changeType: .modified
        )
        let changeResult = await understandingSystem.processChanges([changeEvent])

        // Step 2: Retrieve evidence for the entity.
        let entityRef = EntityReference(qualifiedName: entityName)
        let retrievalRequest = RetrievalRequest(
            subject: .entity(entityRef),
            intent: .explain,
            scope: .local,
            budget: 500
        )
        let evidenceSet = await understandingSystem.evidenceRetrieval.retrieve(retrievalRequest)

        // If no evidence found, return early with diagnostic.
        if evidenceSet.evidence.isEmpty {
            return .noEvidence(
                entityName: entityName,
                filePath: filePath,
                filesProcessed: changeResult.totalFiles
            )
        }

        // Step 3: Assemble context frame.
        let assemblyRequest = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: contextPurpose,
            budget: 500
        )
        let assemblyResult = await understandingSystem.contextAssembly.assemble(assemblyRequest)

        guard case .success(let contextFrame) = assemblyResult else {
            if case .rejected(let rejection) = assemblyResult {
                return .assemblyRejected(reason: "\(rejection)")
            }
            return .assemblyRejected(reason: "unknown")
        }

        // Step 4: Invoke the reasoning engine.
        let consumerRequest = ConsumerRequest(
            contextFrame: contextFrame,
            outputSpecification: OutputSpecification(
                purpose: contextPurpose,
                outputClass: .human,
                detailLevel: .standard
            ),
            conversationState: conversationState
        )
        let consumerResult = await understandingSystem.consumerInvocation.invoke(consumerRequest)

        // Step 5: Return the result.
        switch consumerResult {
        case .success(let understanding):
            return .success(understanding)
        case .failure(let failure):
            return .consumerFailure(
                mode: failure.mode.rawValue,
                diagnostic: failure.diagnostic
            )
        }
    }

    /// Executes a follow-up query, injecting the user's question into the
    /// conversation state before invoking the FollowUpReasoningEngine.
    ///
    /// The question is added as `pendingQuestion` in the engine's internal
    /// `FollowUpState`. This avoids modifying pipeline types — the injection
    /// happens at the application layer before the opaque state enters the runtime.
    ///
    /// - Parameters:
    ///   - filePath: The source file to analyze (same as initial query).
    ///   - entityName: The qualified entity name (same as initial query).
    ///   - question: The user's follow-up question text.
    ///   - conversationState: The conversation state from the prior Understanding.
    /// - Returns: The pipeline result with the follow-up Understanding.
    func queryFollowUp(
        filePath: String,
        entityName: String,
        question: String,
        conversationState: ConversationState
    ) async -> PipelineQueryResult {
        // Inject the question into the conversation state.
        let injectedState = injectQuestion(question, into: conversationState)

        return await query(
            filePath: filePath,
            entityName: entityName,
            purpose: "followup",
            conversationState: injectedState
        )
    }

    /// Injects a follow-up question into an existing conversation state.
    ///
    /// Decodes the engine's `FollowUpState`, adds the `pendingQuestion` field,
    /// re-encodes, and wraps in a new `ConversationState`. If decoding fails
    /// (corrupted state), returns the original state unchanged — the engine
    /// handles corrupted state gracefully (FM-5: falls back to initial invocation).
    private func injectQuestion(
        _ question: String,
        into state: ConversationState
    ) -> ConversationState {
        guard var followUpState = try? JSONDecoder().decode(
            FollowUpReasoningEngine.FollowUpState.self, from: state.data
        ) else {
            return state
        }

        followUpState.pendingQuestion = question

        guard let data = try? JSONEncoder().encode(followUpState),
              data.count <= ConversationState.maxSizeBytes else {
            return state
        }

        return ConversationState(
            data: data,
            engineIdentifier: state.engineIdentifier,
            engineVersion: state.engineVersion
        )
    }
}

/// The result of a pipeline query.
enum PipelineQueryResult: Sendable {
    /// Successfully produced an Understanding.
    case success(Understanding)
    /// No evidence found for the entity in the DIR.
    case noEvidence(entityName: String, filePath: String, filesProcessed: Int)
    /// Context assembly rejected the request.
    case assemblyRejected(reason: String)
    /// Consumer invocation failed.
    case consumerFailure(mode: String, diagnostic: String)

    /// Whether the query succeeded.
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
