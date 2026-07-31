// ExplainReasoningEngine.swift — Decode Application
// DDS-009: ReasoningEngine implementation for the "explain" purpose.
// Product development work that uses the pipeline (IAG-004 §18).

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

/// Production reasoning engine for code explanation.
///
/// DDS-009 RB-1..RB-4: Purpose-specific reasoning over a ContextFrame.
/// DDS-009 RI-3: Stateless between invocations — struct with no mutable state.
/// DDS-009 RB-5/RB-6: No DIR, index, or file system access.
///
/// ## How it works
/// 1. Extracts structured knowledge from context frame units (subject/predicate/value)
/// 2. Builds an explanation prompt using ExplanationFramework V7 logic
/// 3. Calls the AI provider to generate the explanation
/// 4. Produces claims grounded to the context frame units that contributed
///
/// ## AI Provider
/// The engine receives the AI provider via a Sendable closure. When the provider
/// is unavailable, the engine falls back to a deterministic summary of the
/// context frame's content — no AI, but still a valid understanding.
struct ExplainReasoningEngine: ReasoningEngine, Sendable {

    /// Engine identifier for registration and conversation state compatibility.
    static let identifier = "com.decode.explain"

    /// Engine version. Increment when prompt or output format changes.
    static let version = "1.0.0"

    /// Provides the current AI provider. Returns nil when not authenticated.
    private let aiProvider: @Sendable () async -> (any AIProviderProtocol)?

    init(aiProvider: @escaping @Sendable () async -> (any AIProviderProtocol)?) {
        self.aiProvider = aiProvider
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
                content: "Insufficient evidence in the context frame to produce an explanation.",
                claims: [],
                completeness: .insufficient,
                conversationState: nil
            )
        }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)

        // M6: Extract module observations for module-aware framing.
        // M11: Use filterProjectEntities which removes both module: and system: entities.
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)
        let moduleObservations = ReasoningEngineSupport.extractModuleObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames
        )

        // M11: Extract system observations for architecture-aware framing.
        // Question-aware prioritization infrastructure is available via
        // ReasoningEngineSupport.questionAwareOrder() but question text does not
        // currently flow to reasoning engines (pipeline is frozen). Default
        // observation ordering is used. Suppression and ordering can be activated
        // when question context becomes available at this layer.
        let systemObservations = ReasoningEngineSupport.extractSystemObservations(
            from: knowledge,
            codeEntityNames: filtered.entityNames,
            moduleName: moduleObservations?.moduleName
        )

        let systemPrompt = buildSystemPrompt(
            knowledge: knowledge,
            outputSpecification: outputSpecification,
            hasModuleObservations: moduleObservations != nil,
            hasSystemObservations: systemObservations != nil
        )
        let userPrompt = buildUserPrompt(
            knowledge: knowledge,
            outputSpecification: outputSpecification,
            systemObservations: systemObservations,
            moduleObservations: moduleObservations
        )

        guard let provider = await aiProvider() else {
            return produceDeterministicOutput(
                knowledge: knowledge,
                allUnits: allUnits
            )
        }

        let response = try await provider.generateCompletion(
            userContent: userPrompt,
            systemPrompt: systemPrompt,
            mode: "explain"
        )

        let claims = ReasoningEngineSupport.buildClaims(
            from: knowledge,
            allUnits: allUnits
        )

        return ReasoningEngineOutput(
            content: response,
            claims: claims,
            completeness: claims.isEmpty ? .insufficient : .complete,
            conversationState: nil
        )
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(
        knowledge: ExtractedKnowledge,
        outputSpecification: OutputSpecification,
        hasModuleObservations: Bool = false,
        hasSystemObservations: Bool = false
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

        // M11: Add system observation instruction when system context is present.
        if hasSystemObservations {
            prompt += "\n\n" + SystemObservations.systemPromptInstruction
        }

        // M6: Add module observation instruction when module context is present.
        if hasModuleObservations {
            prompt += "\n\n" + ModuleObservations.systemPromptInstruction
        }

        return prompt
    }

    private func buildUserPrompt(
        knowledge: ExtractedKnowledge,
        outputSpecification: OutputSpecification,
        systemObservations: SystemObservations? = nil,
        moduleObservations: ModuleObservations? = nil
    ) -> String {
        var sections: [String] = []

        // M11: Inject system observations first (broadest framing).
        if let systemObservations {
            sections.append(systemObservations.formatForPrompt())
        }

        // M6: Inject module observations after system observations.
        if let moduleObservations {
            sections.append(moduleObservations.formatForPrompt())
        }

        // M11: Use filterProjectEntities which removes both module: and system: entities.
        let filtered = ReasoningEngineSupport.filterProjectEntities(from: knowledge)

        if !filtered.entityFacts.isEmpty {
            var entitySection = "## Entities\n"
            for entityName in filtered.entityNames {
                guard let facts = filtered.entityFacts[entityName] else { continue }
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

    // MARK: - Deterministic Fallback

    /// Produces a deterministic understanding when no AI provider is available.
    ///
    /// DDS-009 UC-4: Reports completeness honestly — partial without AI reasoning.
    private func produceDeterministicOutput(
        knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit]
    ) -> ReasoningEngineOutput {
        var lines: [String] = []

        if !knowledge.entityNames.isEmpty {
            lines.append("Entities discovered: \(knowledge.entityNames.joined(separator: ", "))")

            for entityName in knowledge.entityNames {
                guard let facts = knowledge.entityFacts[entityName] else { continue }
                let summary = facts.map { "\($0.predicate): \($0.value)" }
                    .joined(separator: "; ")
                lines.append("  \(entityName) — \(summary)")
            }
        }

        if !knowledge.relationships.isEmpty {
            lines.append("Relationships:")
            for rel in knowledge.relationships {
                lines.append("  \(rel.source) —[\(rel.predicate)]→ \(rel.target)")
            }
        }

        let content = lines.isEmpty
            ? "No structured knowledge available for explanation."
            : lines.joined(separator: "\n")

        let claims = ReasoningEngineSupport.buildClaims(
            from: knowledge,
            allUnits: allUnits
        )

        return ReasoningEngineOutput(
            content: content,
            claims: claims,
            completeness: .partial,
            conversationState: nil
        )
    }
}
