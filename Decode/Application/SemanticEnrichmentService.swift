import Foundation

/// Produces LLM-derived semantic understanding of source files.
///
/// The Semantic Enrichment Pipeline converts objective deterministic facts
/// (entities, relationships, imports) into interpreted understanding
/// (purpose, behavior, safety, design) via a single LLM call per file version.
///
/// ## Ownership Model (Post-KGR Migration)
/// This service is a **pure producer** — it executes the LLM call and parses the
/// response. It does NOT own caching, persistence, or lifecycle. Those
/// responsibilities belong to the Knowledge Generation Runtime:
/// - **KnowledgeArtifactStore**: persistent cache (disk-backed)
/// - **KnowledgePlanner**: decides when to run
/// - **KnowledgeGenerationRuntime**: schedules and executes
///
/// The `enrich()` method remains as a **fallback path** for cases where the
/// KGR has not yet populated the artifact store (e.g., first launch, race
/// between indexing and user question).
///
/// ## Shared Logic
/// Prompt construction and response parsing are exposed as `static` methods
/// so that `FileUnderstandingJob` can reuse them without duplication.
@MainActor
final class SemanticEnrichmentService {

    /// Closure that returns the current AI provider, or nil if unavailable.
    private let aiProvider: @MainActor () -> (any AIProviderProtocol)?

    init(aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?) {
        self.aiProvider = aiProvider
    }

    // MARK: - Public API

    /// Compute semantic enrichment for a file via LLM.
    ///
    /// Always calls the LLM — no caching. The caller (coordinator) is
    /// responsible for checking the KnowledgeArtifactStore first.
    ///
    /// Returns `nil` on failure (network, auth, timeout, empty response).
    func enrich(intelligence: FileIntelligence) async -> SemanticEnrichment? {
        // No AI provider — cannot enrich.
        guard let provider = aiProvider() else {
            return nil
        }

        // Build the enrichment prompt from deterministic facts.
        let systemPrompt = Self.buildEnrichmentPrompt()
        let userMessage = Self.buildFactsSummary(intelligence: intelligence)

        do {
            let response = try await provider.generateCompletion(
                userContent: userMessage,
                systemPrompt: systemPrompt,
                mode: "enrichment"
            )

            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let enrichment = Self.parseEnrichmentResponse(trimmed, fileHash: intelligence.fileHash)

            #if DEBUG
            print("[SemanticEnrichment] Computed for \(intelligence.fileName): purpose=\(enrichment.purpose.count) chars, behavior=\(enrichment.behavior?.count ?? 0) chars, safety=\(enrichment.safety?.count ?? 0) chars, design=\(enrichment.design?.count ?? 0) chars")
            #endif

            return enrichment
        } catch {
            #if DEBUG
            print("[SemanticEnrichment] Failed for \(intelligence.fileName): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Prompt Construction (Shared with FileUnderstandingJob)

    /// System prompt for semantic enrichment.
    ///
    /// Instructs the LLM to produce purpose, behavioral, safety, and
    /// design summaries from structured facts. The prompt is deliberately
    /// minimal — the deterministic facts do the heavy lifting.
    nonisolated static func buildEnrichmentPrompt() -> String {
        """
        You are a senior software engineer analyzing a source file's structure.

        You will receive structured facts about a file: its entities, relationships, \
        imports, and a preliminary purpose statement derived from naming conventions.

        Produce four analyses:

        1. PURPOSE: A precise 1-2 sentence statement explaining WHY this file exists \
        and WHAT responsibility it owns within the larger system.

        2. BEHAVIOR: A concise 2-3 sentence summary of HOW this file operates at runtime. \
        Cover: what triggers its execution, how its entities collaborate, what external \
        systems it interacts with, and any important sequencing or state transitions.

        3. SAFETY: A concise 2-3 sentence assessment of what a developer should know \
        before modifying this file. Cover: error handling strategy, concurrency model, \
        resource lifecycle concerns, important assumptions the code depends on, and \
        notable side effects. Only state what the structural facts support — do not \
        speculate or invent guarantees.

        4. DESIGN: A concise 2-3 sentence explanation of the file's architectural \
        responsibility and key design decisions. Cover: why the file's abstractions \
        exist, notable design patterns employed, and important engineering trade-offs. \
        Focus on decisions that would inform a developer encountering this file for \
        the first time. Only explain what the structural evidence supports — do not \
        invent architectural intent or speculate about alternatives.

        Rules:
        - Focus on intent and responsibility, not implementation details.
        - Use the relationships, external calls, and imports to understand context.
        - Improve upon the preliminary purpose — it was derived from naming heuristics \
        and may be generic or incomplete.
        - Do not list individual methods or repeat the structured facts.
        - Do not use markdown formatting.

        Respond using exactly this format:

        <purpose>
        Your purpose statement here.
        </purpose>

        <behavior>
        Your behavioral summary here.
        </behavior>

        <safety>
        Your safety assessment here.
        </safety>

        <design>
        Your design explanation here.
        </design>
        """
    }

    /// Assemble a structured summary of deterministic facts for the LLM.
    ///
    /// This is the key design decision of the semantic enrichment pipeline:
    /// send structured facts, not raw source code. This achieves:
    /// - Low token usage (~200-500 tokens vs ~2000-10000 for full source)
    /// - Consistent input format across all languages
    /// - Focus on structural understanding, not syntax
    nonisolated static func buildFactsSummary(intelligence: FileIntelligence) -> String {
        var parts: [String] = []

        // File identity.
        parts.append("File: \(intelligence.fileName)")
        parts.append("Language: \(intelligence.language)")
        parts.append("Lines: \(intelligence.lineCount)")

        // Identity layer.
        parts.append("Role: \(intelligence.identity.summary)")

        // Preliminary purpose.
        if !intelligence.purpose.isEmpty {
            parts.append("Preliminary purpose: \(intelligence.purpose)")
        }

        // Entities: types with their members grouped underneath,
        // then top-level functions separately. Grouping eliminates the
        // structural ambiguity of a flat method list when a file has
        // multiple types, at zero additional token cost.
        let entities = intelligence.entities
        let types = entities.filter {
            $0.entity.entityType == .class
            || $0.entity.entityType == .struct
            || $0.entity.entityType == .enum
            || $0.entity.entityType == .protocol
        }

        // Build a lookup from parent stableId → child methods/functions.
        var membersByParent: [String: [ParsedEntity]] = [:]
        for entity in entities {
            guard let parentId = entity.parentStableId,
                  entity.entity.entityType == .function
                    || entity.entity.entityType == .method
            else { continue }
            membersByParent[parentId, default: []].append(entity)
        }

        if !types.isEmpty {
            var typeLines: [String] = []
            for typeEntity in types.prefix(15) {
                let nested = typeEntity.parentStableId != nil ? " (nested)" : ""
                typeLines.append("  \(typeEntity.entity.entityType.rawValue) \(typeEntity.entity.name)\(nested)")

                // Append member methods indented under their owning type.
                if let members = membersByParent[typeEntity.entity.stableId] {
                    for member in members.prefix(20) {
                        typeLines.append("    \(member.signature)")
                    }
                }
            }
            parts.append("Types:\n\(typeLines.joined(separator: "\n"))")
        }

        // Top-level functions (no parent type).
        let topLevelFunctions = entities.filter {
            ($0.entity.entityType == .function || $0.entity.entityType == .method)
            && $0.parentStableId == nil
        }
        if !topLevelFunctions.isEmpty {
            let funcLines = topLevelFunctions.prefix(20).map { entity in
                return "  \(entity.signature)"
            }
            parts.append("Functions:\n\(funcLines.joined(separator: "\n"))")
        }

        // Imports (module names only).
        let moduleImports = intelligence.imports
            .filter { $0.kind == .module || $0.kind == .symbol }
            .map(\.moduleName)
        let uniqueImports = Array(Set(moduleImports)).sorted()
        if !uniqueImports.isEmpty {
            parts.append("Dependencies: \(uniqueImports.joined(separator: ", "))")
        }

        // Relationships (summarized, not exhaustive).
        let relationships = intelligence.relationships
        let conformances = relationships.filter { $0.kind == .conformsTo }
        let inheritances = relationships.filter { $0.kind == .inherits }
        let ownerships = relationships.filter { $0.kind == .owns }

        var relLines: [String] = []
        for rel in inheritances {
            if let source = entityName(forStableId: rel.sourceEntity, in: entities) {
                relLines.append("  \(source) inherits \(rel.targetName)")
            }
        }
        for rel in conformances {
            if let source = entityName(forStableId: rel.sourceEntity, in: entities) {
                relLines.append("  \(source) conforms to \(rel.targetName)")
            }
        }
        // Limit ownership to 10 to control token usage.
        for rel in ownerships.prefix(10) {
            if let source = entityName(forStableId: rel.sourceEntity, in: entities) {
                relLines.append("  \(source) owns \(rel.targetName)")
            }
        }

        if !relLines.isEmpty {
            parts.append("Relationships:\n\(relLines.joined(separator: "\n"))")
        }

        // Call graph summary: entry points, external calls, internal call count.
        let callRelationships = relationships.filter { $0.kind == .calls }
        if !callRelationships.isEmpty {
            let callerIds = Set(callRelationships.map(\.sourceEntity))
            let calleeNames = Set(callRelationships.map(\.targetName))

            // Entry points: entities that are never called by other entities in this file.
            let entityNames = Set(entities.map(\.entity.name))
            let entryPoints = entities.filter {
                ($0.entity.entityType == .function || $0.entity.entityType == .method)
                && callerIds.contains($0.entity.stableId)
                && !calleeNames.contains($0.entity.name)
            }

            if !entryPoints.isEmpty {
                let names = entryPoints.prefix(5).map(\.entity.name)
                parts.append("Entry points: \(names.joined(separator: ", "))")
            }

            // External calls: targets not defined in this file.
            // These reveal side effects and external dependencies — the
            // highest-value behavioral signal per token.
            let externalTargets = callRelationships
                .filter { !entityNames.contains($0.targetName) }
                .map(\.targetName)
            let uniqueExternal = Array(Set(externalTargets)).sorted()
            if !uniqueExternal.isEmpty {
                let capped = uniqueExternal.prefix(10)
                parts.append("External calls: \(capped.joined(separator: ", "))")
            }

            // Internal call count.
            let internalCalls = callRelationships.filter { entityNames.contains($0.targetName) }
            if !internalCalls.isEmpty {
                parts.append("Internal calls: \(internalCalls.count)")
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Response Parsing (Shared with FileUnderstandingJob)

    /// Parse an LLM enrichment response into a SemanticEnrichment.
    ///
    /// Extracts purpose, behavior, safety, and design from XML-like tags.
    /// If tags are absent, the entire response is treated as purpose
    /// (backward-compatible fallback). Each tag is parsed independently —
    /// partial responses degrade gracefully.
    nonisolated static func parseEnrichmentResponse(_ response: String, fileHash: String) -> SemanticEnrichment {
        let purpose: String
        let behavior: String?
        let safety: String?
        let design: String?

        if let taggedPurpose = extractTagContent(from: response, tag: "purpose") {
            let cleaned = taggedPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
            purpose = cleaned.isEmpty ? response : cleaned
        } else {
            // No tags — entire response is purpose (backward-compatible fallback).
            purpose = response
        }

        if let taggedBehavior = extractTagContent(from: response, tag: "behavior") {
            let cleaned = taggedBehavior.trimmingCharacters(in: .whitespacesAndNewlines)
            behavior = cleaned.isEmpty ? nil : cleaned
        } else {
            behavior = nil
        }

        if let taggedSafety = extractTagContent(from: response, tag: "safety") {
            let cleaned = taggedSafety.trimmingCharacters(in: .whitespacesAndNewlines)
            safety = cleaned.isEmpty ? nil : cleaned
        } else {
            safety = nil
        }

        if let taggedDesign = extractTagContent(from: response, tag: "design") {
            let cleaned = taggedDesign.trimmingCharacters(in: .whitespacesAndNewlines)
            design = cleaned.isEmpty ? nil : cleaned
        } else {
            design = nil
        }

        return SemanticEnrichment(
            purpose: purpose,
            behavior: behavior,
            safety: safety,
            design: design,
            fileHash: fileHash,
            computedAt: Date()
        )
    }

    /// Resolve an entity name from a stableId.
    private nonisolated static func entityName(
        forStableId stableId: String,
        in entities: [ParsedEntity]
    ) -> String? {
        entities.first { $0.entity.stableId == stableId }?.entity.name
    }

    /// Extract text content between opening and closing XML-like tags.
    ///
    /// Returns `nil` if the tag is not found. Handles whitespace around
    /// and within tags.
    nonisolated static func extractTagContent(from text: String, tag: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
        else {
            return nil
        }

        return String(text[openRange.upperBound..<closeRange.lowerBound])
    }
}
