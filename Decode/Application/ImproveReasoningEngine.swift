// ImproveReasoningEngine.swift — Decode Application
// DDS-009: ReasoningEngine implementation for the "improve" purpose.
// Product development work that uses the pipeline (IAG-004 §18).

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

/// Production reasoning engine for code improvement.
///
/// DDS-009 RB-1..RB-4: Purpose-specific reasoning over a ContextFrame.
/// DDS-009 RI-3: Stateless between invocations — struct with no mutable state.
/// DDS-009 RB-5/RB-6: No DIR, index, or file system access.
///
/// ## How it works
/// 1. Extracts structured knowledge from context frame units (shared with ExplainReasoningEngine)
/// 2. Builds an improvement prompt using ImprovementService instructions
/// 3. Calls the AI provider to generate the improvement
/// 4. Parses the XML-tagged response (`<improvement_summary>`, `<improved_code>`)
/// 5. Produces claims grounded to the context frame units that contributed
///
/// ## No-Improvement Path
/// When the AI determines no meaningful improvement exists, it returns only
/// `<improvement_summary>` with no `<improved_code>` tag. This is a successful
/// outcome — completeness is `.complete` because the engine made a sound judgment.
///
/// ## AI Provider
/// The engine receives the AI provider via a Sendable closure. When the provider
/// is unavailable, the engine falls back to a deterministic listing of the
/// context frame's content — no AI, but still a valid understanding.
struct ImproveReasoningEngine: ReasoningEngine, Sendable {

    /// Engine identifier for registration and conversation state compatibility.
    static let identifier = "com.decode.improve"

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
                content: "Insufficient evidence in the context frame to produce an improvement.",
                claims: [],
                completeness: .insufficient,
                conversationState: nil
            )
        }

        let knowledge = ReasoningEngineSupport.extractKnowledge(from: allUnits)

        let systemPrompt = buildSystemPrompt(outputSpecification: outputSpecification)
        let userPrompt = buildUserPrompt(knowledge: knowledge)

        guard let provider = await aiProvider() else {
            return produceDeterministicOutput(
                knowledge: knowledge,
                allUnits: allUnits
            )
        }

        let response = try await provider.generateCompletion(
            userContent: userPrompt,
            systemPrompt: systemPrompt,
            mode: "improve"
        )

        // Parse the XML-tagged response using ImprovementService.
        let parsed = ImprovementService.parseResponse(response)

        // Build structured content preserving XML tags so downstream consumers
        // can parse with ImprovementService.parseResponse() directly.
        let content: String
        if parsed.improvedCode.isEmpty {
            content = "<improvement_summary>\(parsed.summary)</improvement_summary>"
        } else {
            content = "<improvement_summary>\(parsed.summary)</improvement_summary>\n\n<improved_code>\n\(parsed.improvedCode)\n</improved_code>"
        }

        let claims = ReasoningEngineSupport.buildClaims(
            from: knowledge,
            allUnits: allUnits
        )

        return ReasoningEngineOutput(
            content: content,
            claims: claims,
            completeness: claims.isEmpty ? .insufficient : .complete,
            conversationState: nil
        )
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(
        outputSpecification: OutputSpecification
    ) -> String {
        // Use ImprovementService's production-validated prompt as the base.
        var prompt = ImprovementService.systemPrompt

        // Adapt detail level — more or less aggressive improvement search.
        switch outputSpecification.detailLevel {
        case .minimal:
            prompt += "\n\nFocus only on the single most impactful improvement, if any."
        case .standard:
            break // Default behavior — already covered by base prompt.
        case .detailed:
            prompt += "\n\nBe thorough: consider all improvement dimensions and explain each change in detail."
        }

        return prompt
    }

    private func buildUserPrompt(
        knowledge: ExtractedKnowledge
    ) -> String {
        var sections: [String] = []

        // Present entities as the code to analyze for improvement.
        if !knowledge.entityFacts.isEmpty {
            var entitySection = "CODE ENTITIES TO ANALYZE:\n"
            for entityName in knowledge.entityNames {
                guard let facts = knowledge.entityFacts[entityName] else { continue }
                entitySection += "\n\(entityName):\n"
                for fact in facts {
                    entitySection += "  \(fact.predicate): \(fact.value)\n"
                }
            }
            sections.append(entitySection)
        }

        if !knowledge.relationships.isEmpty {
            var relSection = "RELATIONSHIPS:\n"
            for rel in knowledge.relationships {
                relSection += "  \(rel.source) —[\(rel.predicate)]→ \(rel.target)\n"
            }
            sections.append(relSection)
        }

        if sections.isEmpty {
            return "Analyze the code for improvements based on the available evidence."
        }

        return "Analyze the following code structure for improvements:\n\n" + sections.joined(separator: "\n")
    }

    // MARK: - Deterministic Fallback

    /// Produces a deterministic understanding when no AI provider is available.
    ///
    /// DDS-009 UC-4: Reports completeness honestly — partial without AI reasoning.
    /// For improve, deterministic output lists the entities and relationships
    /// but cannot suggest improvements without AI reasoning.
    private func produceDeterministicOutput(
        knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit]
    ) -> ReasoningEngineOutput {
        var lines: [String] = []

        lines.append("Code improvement requires AI analysis. Entities available for review:")

        if !knowledge.entityNames.isEmpty {
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

        let content = lines.joined(separator: "\n")

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
