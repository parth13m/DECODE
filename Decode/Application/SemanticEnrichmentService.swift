import Foundation

/// Orchestrates lazy, cached LLM-derived semantic understanding of source files.
///
/// The Semantic Enrichment Pipeline converts objective deterministic facts
/// (entities, relationships, imports) into interpreted understanding
/// (purpose and behavior, with future safety and design layers) via a single
/// LLM call per file version.
///
/// ## Lifecycle
/// 1. **Trigger**: The first time a user requests an explanation for a file.
/// 2. **Cache check**: If enrichment exists for the current `fileHash`, return it.
/// 3. **LLM call**: Send structured deterministic facts (NOT raw source) to the LLM.
/// 4. **Cache store**: Store the result keyed by `fileHash`.
/// 5. **Return**: The enrichment is used by the coordinator to augment the prompt.
///
/// ## Failure
/// If the LLM call fails (network, auth, timeout), returns `nil`.
/// The coordinator falls back to deterministic purpose — the user never
/// sees an error from enrichment failure.
///
/// ## Cache Invalidation
/// Automatic via `fileHash`. When the file changes, `reparseSession()` updates
/// the hash. The next enrichment request sees a cache miss and recomputes.
@MainActor
final class SemanticEnrichmentService {

    /// In-memory cache: fileHash → enrichment.
    private var cache: [String: SemanticEnrichment] = [:]

    /// Closure that returns the current AI provider, or nil if unavailable.
    private let aiProvider: @MainActor () -> (any AIProviderProtocol)?

    init(aiProvider: @escaping @MainActor () -> (any AIProviderProtocol)?) {
        self.aiProvider = aiProvider
    }

    // MARK: - Public API

    /// Check whether enrichment is cached for a given file hash.
    ///
    /// Pure cache lookup — no LLM call, no computation. Returns `nil` if
    /// the file has not been enriched yet or the hash doesn't match.
    func cachedEnrichment(forHash fileHash: String) -> SemanticEnrichment? {
        cache[fileHash]
    }

    /// Retrieve or compute semantic enrichment for a file.
    ///
    /// Returns cached enrichment if available for the given file hash.
    /// Otherwise, makes a single LLM call using structured deterministic
    /// facts from FileIntelligence. Returns `nil` on failure.
    ///
    /// This method is designed to be called in the coordinator's hot path.
    /// Cache hits are instantaneous. Cache misses add one LLM round-trip.
    func enrich(intelligence: FileIntelligence) async -> SemanticEnrichment? {
        let hash = intelligence.fileHash

        // Cache hit — return immediately.
        if let cached = cache[hash] {
            return cached
        }

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

            // Parse structured response. If XML tags are present, extract
            // each field independently. If tags are absent (e.g., model
            // returned plain text), treat the entire response as purpose
            // with no other layers — never fail due to formatting.
            let purpose: String
            let behavior: String?
            let safety: String?
            let design: String?

            if let taggedPurpose = Self.extractTagContent(from: trimmed, tag: "purpose") {
                let cleaned = taggedPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
                purpose = cleaned.isEmpty ? trimmed : cleaned
            } else {
                // No tags — entire response is purpose (backward-compatible fallback).
                purpose = trimmed
            }

            if let taggedBehavior = Self.extractTagContent(from: trimmed, tag: "behavior") {
                let cleaned = taggedBehavior.trimmingCharacters(in: .whitespacesAndNewlines)
                behavior = cleaned.isEmpty ? nil : cleaned
            } else {
                behavior = nil
            }

            if let taggedSafety = Self.extractTagContent(from: trimmed, tag: "safety") {
                let cleaned = taggedSafety.trimmingCharacters(in: .whitespacesAndNewlines)
                safety = cleaned.isEmpty ? nil : cleaned
            } else {
                safety = nil
            }

            if let taggedDesign = Self.extractTagContent(from: trimmed, tag: "design") {
                let cleaned = taggedDesign.trimmingCharacters(in: .whitespacesAndNewlines)
                design = cleaned.isEmpty ? nil : cleaned
            } else {
                design = nil
            }

            let enrichment = SemanticEnrichment(
                purpose: purpose,
                behavior: behavior,
                safety: safety,
                design: design,
                fileHash: hash,
                computedAt: Date()
            )

            cache[hash] = enrichment

            #if DEBUG
            print("[SemanticEnrichment] Computed for \(intelligence.fileName): purpose=\(purpose.count) chars, behavior=\(behavior?.count ?? 0) chars, safety=\(safety?.count ?? 0) chars, design=\(design?.count ?? 0) chars")
            #endif

            return enrichment
        } catch {
            #if DEBUG
            print("[SemanticEnrichment] Failed for \(intelligence.fileName): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Prompt Construction

    /// System prompt for semantic enrichment.
    ///
    /// Instructs the LLM to produce purpose, behavioral, safety, and
    /// design summaries from structured facts. The prompt is deliberately
    /// minimal — the deterministic facts do the heavy lifting.
    private static func buildEnrichmentPrompt() -> String {
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
    private static func buildFactsSummary(intelligence: FileIntelligence) -> String {
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

    /// Resolve an entity name from a stableId.
    private static func entityName(
        forStableId stableId: String,
        in entities: [ParsedEntity]
    ) -> String? {
        entities.first { $0.entity.stableId == stableId }?.entity.name
    }

    // MARK: - Response Parsing

    /// Extract text content between opening and closing XML-like tags.
    ///
    /// Returns `nil` if the tag is not found. Handles whitespace around
    /// and within tags. Follows the same pattern used by
    /// ``ImprovementService/extractTagContent(from:tag:)``.
    private static func extractTagContent(from text: String, tag: String) -> String? {
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
