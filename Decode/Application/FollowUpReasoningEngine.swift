// FollowUpReasoningEngine.swift — Decode Application
// DDS-009: ReasoningEngine implementation for the "followup" purpose.
// Product development work that uses the pipeline (IAG-004 §18).

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

/// Production reasoning engine for follow-up questions.
///
/// DDS-009 RB-1..RB-4: Purpose-specific reasoning over a ContextFrame.
/// DDS-009 RI-3: Stateless between invocations — struct with no mutable state.
/// DDS-009 RB-5/RB-6: No DIR, index, or file system access.
/// DDS-009 CL-5, RI-7: ConversationState bounded (256 KB), opaque, transient.
///
/// ## How it works
/// This is the only engine that uses `ConversationState`. Two invocation modes:
///
/// **Initial invocation** (no conversation state):
/// 1. Extracts knowledge from the context frame
/// 2. Generates an explanation (same as ExplainReasoningEngine)
/// 3. Encodes the explanation + context frame summary into ConversationState
/// 4. Returns the explanation with conversation state for future follow-ups
///
/// **Follow-up invocation** (with conversation state):
/// 1. Decodes the prior explanation and context summary from conversation state
/// 2. Extracts the follow-up question from the context frame's first anchor
/// 3. Builds a 3-message conversation: [original summary, explanation, question]
/// 4. Calls `streamChat` with the follow-up system prompt
/// 5. Returns the answer with updated conversation state
///
/// ## AI Provider
/// The engine receives the AI provider via a Sendable closure. When the provider
/// is unavailable, the engine falls back to a deterministic response.
struct FollowUpReasoningEngine: ReasoningEngine, Sendable {

    /// Engine identifier for registration and conversation state compatibility.
    static let identifier = "com.decode.followup"

    /// Engine version. Increment when prompt, output format, or state schema changes.
    static let version = "1.0.0"

    /// Provides the current AI provider. Returns nil when not authenticated.
    private let aiProvider: @Sendable () async -> (any AIProviderProtocol)?

    init(aiProvider: @escaping @Sendable () async -> (any AIProviderProtocol)?) {
        self.aiProvider = aiProvider
    }

    // MARK: - Follow-Up System Prompt

    /// System prompt for follow-up questions.
    ///
    /// Mirrors the production `followUpSystemPrompt` from ExplanationHUDViewModel.
    /// Defined here so the reasoning engine doesn't depend on presentation types.
    static let followUpSystemPrompt = """
        You are Decode, a code explanation assistant. The user already received a \
        full explanation of their code. Now they are asking a follow-up question.

        LENGTH:
        - Default: 3–6 sentences. No more.
        - Go longer ONLY if the user explicitly asks to "explain in detail", \
        "walk through", "compare", "give examples", or asks "why" or "how".

        RULES:
        - Answer ONLY the question that was asked. Nothing else.
        - Do NOT provide optimizations, alternative implementations, refactors, \
        best practices, or suggestions unless the user explicitly asks for them.
        - If a short example helps answer the question, include one. Keep it minimal.
        - Reference the original code or explanation when it helps clarify.
        - Do NOT output Purpose, Flow, Example, Important Lines, or Summary sections.
        - Do NOT use **bold section labels** to structure your response.

        FORMATTING:
        - Use <hl>text</hl> sparingly for the most important term, variable, or \
        function name when it improves readability.
        - Use <critical>text</critical> only for bugs or dangerous patterns.
        - Use inline code backticks for short code references.
        - Do NOT use <flow>, <tldr>, <tip>, <note>, or <analogy> tags.
        - Do NOT use markdown headings (## or ###).
        """

    // MARK: - Conversation State Schema

    /// Internal representation of conversation state.
    /// Encoded as JSON into the opaque `ConversationState.data`.
    struct FollowUpState: Codable, Sendable {
        /// Summary of the context frame content (entity facts, relationships).
        let contextSummary: String
        /// The explanation or prior answer produced by the engine.
        let priorResponse: String
        /// The user's follow-up question, injected by PipelineQueryService
        /// before invoking the engine. `nil` on initial invocation and when
        /// the question is extracted from the context frame instead.
        var pendingQuestion: String?
    }

    // MARK: - ReasoningEngine

    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        let allUnits = contextFrame.strata.flatMap { $0.units }

        guard !allUnits.isEmpty else {
            return ReasoningEngineOutput(
                content: "Insufficient evidence in the context frame to produce an answer.",
                claims: [],
                completeness: .insufficient,
                conversationState: nil
            )
        }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)

        // Determine invocation mode based on conversation state.
        if let conversationState {
            return try await handleFollowUp(
                conversationState: conversationState,
                knowledge: knowledge,
                allUnits: allUnits,
                outputSpecification: outputSpecification
            )
        } else {
            return try await handleInitialInvocation(
                knowledge: knowledge,
                allUnits: allUnits,
                outputSpecification: outputSpecification
            )
        }
    }

    // MARK: - Initial Invocation (No Prior State)

    /// First invocation — produces an explanation and encodes conversation state.
    private func handleInitialInvocation(
        knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit],
        outputSpecification: OutputSpecification
    ) async throws -> ReasoningEngineOutput {
        let contextSummary = buildContextSummary(knowledge: knowledge)

        guard let provider = await aiProvider() else {
            return produceDeterministicOutput(
                knowledge: knowledge,
                allUnits: allUnits,
                contextSummary: contextSummary
            )
        }

        let systemPrompt = buildInitialSystemPrompt(
            knowledge: knowledge,
            outputSpecification: outputSpecification
        )
        let userPrompt = buildInitialUserPrompt(knowledge: knowledge)

        let response = try await provider.generateCompletion(
            userContent: userPrompt,
            systemPrompt: systemPrompt,
            mode: "followup"
        )

        let claims = ReasoningEngineSupport.buildClaims(
            from: knowledge,
            allUnits: allUnits
        )

        let state = encodeConversationState(
            contextSummary: contextSummary,
            priorResponse: response
        )

        return ReasoningEngineOutput(
            content: response,
            claims: claims,
            completeness: claims.isEmpty ? .insufficient : .complete,
            conversationState: state
        )
    }

    // MARK: - Follow-Up Invocation (With Prior State)

    /// Follow-up invocation — uses prior state to build conversation context.
    private func handleFollowUp(
        conversationState: ConversationState,
        knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit],
        outputSpecification: OutputSpecification
    ) async throws -> ReasoningEngineOutput {
        // Decode prior conversation state.
        let priorState: FollowUpState
        do {
            priorState = try JSONDecoder().decode(FollowUpState.self, from: conversationState.data)
        } catch {
            // Corrupted state — fall back to initial invocation.
            return try await handleInitialInvocation(
                knowledge: knowledge,
                allUnits: allUnits,
                outputSpecification: outputSpecification
            )
        }

        // Extract the follow-up question: prefer pendingQuestion from state
        // (injected by PipelineQueryService), then context frame, then fallback.
        let question = priorState.pendingQuestion
            ?? extractFollowUpQuestion(from: allUnits, knowledge: knowledge)

        guard let provider = await aiProvider() else {
            return produceDeterministicOutput(
                knowledge: knowledge,
                allUnits: allUnits,
                contextSummary: priorState.contextSummary
            )
        }

        // Build 3-message conversation: [original context, prior response, question].
        let messages = [
            AIMessage(role: .user, content: priorState.contextSummary),
            AIMessage(role: .assistant, content: priorState.priorResponse),
            AIMessage(role: .user, content: question),
        ]

        let stream = try await provider.streamChat(
            messages: messages,
            systemPrompt: Self.followUpSystemPrompt,
            mode: "followup"
        )

        // Collect streamed chunks into a single response.
        var response = ""
        for try await chunk in stream {
            response += chunk
        }

        let claims = ReasoningEngineSupport.buildClaims(
            from: knowledge,
            allUnits: allUnits
        )

        // Update conversation state with the new response.
        let updatedState = encodeConversationState(
            contextSummary: priorState.contextSummary,
            priorResponse: response
        )

        return ReasoningEngineOutput(
            content: response,
            claims: claims,
            completeness: claims.isEmpty ? .insufficient : .complete,
            conversationState: updatedState
        )
    }

    // MARK: - Prompt Construction

    private func buildInitialSystemPrompt(
        knowledge: ExtractedKnowledge,
        outputSpecification: OutputSpecification
    ) -> String {
        let framework: ExplanationFramework
        if let lang = knowledge.detectedLanguage {
            framework = ExplanationFramework.select(fileName: "file.\(lang)", codeSnippet: "")
        } else {
            framework = .imperativeFlow
        }

        var prompt = """
        You are an expert code explainer. You receive structured knowledge about code entities \
        extracted from a software intelligence platform, and you produce clear, insightful explanations.

        The knowledge below was extracted from the codebase by deterministic analysis. \
        Use it to explain what the code does, why it exists, and how it works.

        \(framework.languageHint)
        """

        switch outputSpecification.detailLevel {
        case .minimal:
            prompt += "\n\nProvide a concise explanation — key points only."
        case .standard:
            prompt += "\n\nProvide a thorough explanation with appropriate depth."
        case .detailed:
            prompt += "\n\nProvide a comprehensive, detailed explanation covering all aspects."
        }

        return prompt
    }

    private func buildInitialUserPrompt(
        knowledge: ExtractedKnowledge
    ) -> String {
        var sections: [String] = []

        if !knowledge.entityFacts.isEmpty {
            var entitySection = "## Entities\n"
            for entityName in knowledge.entityNames {
                guard let facts = knowledge.entityFacts[entityName] else { continue }
                entitySection += "\n### \(entityName)\n"
                for fact in facts {
                    entitySection += "- \(fact.predicate): \(fact.value)\n"
                }
            }
            sections.append(entitySection)
        }

        if !knowledge.relationships.isEmpty {
            var relSection = "## Relationships\n"
            for rel in knowledge.relationships {
                relSection += "- \(rel.source) —[\(rel.predicate)]→ \(rel.target)\n"
            }
            sections.append(relSection)
        }

        if sections.isEmpty {
            return "Explain the code based on the available evidence."
        }

        return "Explain the following code structure:\n\n" + sections.joined(separator: "\n")
    }

    // MARK: - Context Summary

    /// Builds a text summary of the context frame for conversation state.
    private func buildContextSummary(knowledge: ExtractedKnowledge) -> String {
        var lines: [String] = []

        for entityName in knowledge.entityNames {
            guard let facts = knowledge.entityFacts[entityName] else { continue }
            let summary = facts.map { "\($0.predicate): \($0.value)" }
                .joined(separator: "; ")
            lines.append("\(entityName) — \(summary)")
        }

        for rel in knowledge.relationships {
            lines.append("\(rel.source) —[\(rel.predicate)]→ \(rel.target)")
        }

        return lines.isEmpty
            ? "Code context from structured analysis."
            : lines.joined(separator: "\n")
    }

    // MARK: - Question Extraction

    /// Extracts the follow-up question from the context frame.
    ///
    /// Looks for a unit with predicate name "question" or "followUpQuestion".
    /// Falls back to a generic prompt if not found.
    private func extractFollowUpQuestion(
        from allUnits: [ContextUnit],
        knowledge: ExtractedKnowledge
    ) -> String {
        // Search for a question predicate.
        for (_, facts) in knowledge.entityFacts {
            for fact in facts {
                if fact.predicate == "question" || fact.predicate == "followUpQuestion" {
                    return fact.value
                }
            }
        }

        // Fall back to constructing a question from entity names.
        if !knowledge.entityNames.isEmpty {
            return "Tell me more about \(knowledge.entityNames.joined(separator: ", "))."
        }

        return "Can you explain further?"
    }

    // MARK: - Conversation State Encoding

    private func encodeConversationState(
        contextSummary: String,
        priorResponse: String
    ) -> ConversationState? {
        let state = FollowUpState(
            contextSummary: contextSummary,
            priorResponse: priorResponse
        )

        guard let data = try? JSONEncoder().encode(state),
              data.count <= ConversationState.maxSizeBytes else {
            return nil
        }

        return ConversationState(
            data: data,
            engineIdentifier: Self.identifier,
            engineVersion: Self.version
        )
    }

    // MARK: - Deterministic Fallback

    /// Produces a deterministic understanding when no AI provider is available.
    private func produceDeterministicOutput(
        knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit],
        contextSummary: String
    ) -> ReasoningEngineOutput {
        var lines: [String] = []
        lines.append("Follow-up answers require AI analysis. Context available:")

        for entityName in knowledge.entityNames {
            guard let facts = knowledge.entityFacts[entityName] else { continue }
            let summary = facts.map { "\($0.predicate): \($0.value)" }
                .joined(separator: "; ")
            lines.append("  \(entityName) — \(summary)")
        }

        if !knowledge.relationships.isEmpty {
            lines.append("Relationships:")
            for rel in knowledge.relationships {
                lines.append("  \(rel.source) —[\(rel.predicate)]→ \(rel.target)")
            }
        }

        let content = lines.joined(separator: "\n")

        let claims = ReasoningEngineSupport.buildClaims(
            from: knowledge,
            allUnits: allUnits
        )

        // Encode state even for deterministic output so follow-ups can resume.
        let state = encodeConversationState(
            contextSummary: contextSummary,
            priorResponse: content
        )

        return ReasoningEngineOutput(
            content: content,
            claims: claims,
            completeness: .partial,
            conversationState: state
        )
    }
}
