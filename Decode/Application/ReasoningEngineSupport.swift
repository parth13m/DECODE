// ReasoningEngineSupport.swift — Decode Application
// Shared knowledge extraction and claim generation for ReasoningEngine implementations.
// Used by ExplainReasoningEngine, FollowUpReasoningEngine, and ImproveReasoningEngine.

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

/// Structured knowledge extracted from context frame units.
///
/// Shared across reasoning engines — the extraction logic is purpose-independent.
/// Each engine uses the same knowledge but constructs different prompts and
/// interprets responses differently.
struct ExtractedKnowledge: Sendable {
    /// Entity names discovered in units (ordered, deduplicated).
    let entityNames: [String]

    /// Per-entity knowledge: entity qualified name → [(predicate, value text, unit ID)].
    let entityFacts: [String: [(predicate: String, value: String, unitId: UnitIdentifier)]]

    /// Relationship facts: [(source, predicate, target, unit ID)].
    let relationships: [(source: String, predicate: String, target: String, unitId: UnitIdentifier)]

    /// All unit IDs present in the context frame.
    let allUnitIds: [UnitIdentifier]

    /// Detected language (from unit predicates if available).
    let detectedLanguage: String?
}

// MARK: - Module Observations (M6 ConsumerRuntime support)

/// Semantic observation layer for module-level context.
///
/// Transforms raw module emergent properties (M4) from the context frame
/// into interpreted, actionable observations that reasoning engines inject into
/// prompts. The LLM receives structured observations with guidance directives,
/// not raw data or pre-written sentences.
///
/// The observation pipeline:
/// 1. Extract module entities and their properties from ExtractedKnowledge
/// 2. Apply suppression rules (single-file module, moderate values, etc.)
/// 3. Interpret surviving properties (ratio → "high", role → interpretation)
/// 4. Generate guidance directives from the observation combination
/// 5. Format as a prompt-injectable observation block
struct ModuleObservations: Sendable, Equatable {

    /// The module name (e.g., "Application").
    let moduleName: String

    /// The entity being explained (for the observation header).
    let entityName: String

    /// Module role observation. Nil when suppressed.
    let role: RoleObservation?

    /// Entity visibility observation. Nil when suppressed.
    let visibility: VisibilityObservation?

    /// Cohesion observation. Nil when suppressed (moderate range).
    let cohesion: CohesionObservation?

    /// Interaction style observation. Nil when suppressed (no dominant type).
    let style: StyleObservation?

    /// Boundary direction observation. Nil when suppressed.
    let boundary: BoundaryObservation?

    /// Actionable guidance directives for the LLM.
    let guidance: String

    // MARK: - Observation Types

    struct RoleObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct VisibilityObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct CohesionObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct StyleObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct BoundaryObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    // MARK: - Prompt Formatting

    /// Formats the observations as a prompt-injectable block for the user prompt.
    func formatForPrompt() -> String {
        var lines: [String] = []
        lines.append("MODULE OBSERVATIONS — \(entityName)")
        lines.append("")
        lines.append("module:     \(moduleName)")

        if let role {
            lines.append("role:       \(role.value) — \(role.interpretation)")
        }
        if let visibility {
            lines.append("visibility: \(visibility.value) — \(visibility.interpretation)")
        }
        if let cohesion {
            lines.append("cohesion:   \(cohesion.value) — \(cohesion.interpretation)")
        }
        if let style {
            lines.append("style:      \(style.value) — \(style.interpretation)")
        }
        if let boundary {
            lines.append("boundary:   \(boundary.value) — \(boundary.interpretation)")
        }

        lines.append("")
        lines.append("guidance:   \(guidance)")

        return lines.joined(separator: "\n")
    }

    /// Formats the observations as a compact one-line summary for ConversationState.
    func formatForContextSummary() -> String {
        var parts: [String] = ["Module: \(moduleName)"]
        if let role {
            parts.append(role.value)
        }
        if let visibility {
            parts.append(visibility.value)
        }
        return parts.joined(separator: ", ") + "."
    }

    /// System prompt instruction for module-aware explanations.
    static let systemPromptInstruction = """
    When MODULE OBSERVATIONS are present, use them to frame your explanation — \
    mention the entity's position in the broader system where it improves understanding. \
    Do not create a separate module section. Weave module framing naturally, \
    typically as one sentence in the opening or closing of your explanation. \
    Follow the guidance directive. Do not restate observations as bullet points.
    """

    /// Follow-up system prompt instruction for module-aware context.
    static let followUpContextInstruction = """
    The context summary includes module-level information. Reference it only when \
    the user's question touches cross-file concerns, impact, or architectural position.
    """
}

/// Shared utilities for reasoning engine implementations.
///
/// Provides knowledge extraction from ContextFrame units and grounded claim
/// generation. Both operations are purpose-independent — every reasoning engine
/// needs to extract structured knowledge and produce grounded claims.
enum ReasoningEngineSupport {

    // MARK: - Knowledge Extraction

    /// Extracts structured knowledge from context frame units.
    ///
    /// Iterates over all units, categorizing them as entity facts or relationship facts.
    /// Entity names are deduplicated and ordered by first appearance.
    static func extractKnowledge(from units: [ContextUnit]) -> ExtractedKnowledge {
        var entityNames: [String] = []
        var entityFacts: [String: [(predicate: String, value: String, unitId: UnitIdentifier)]] = [:]
        var relationships: [(source: String, predicate: String, target: String, unitId: UnitIdentifier)] = []
        var allUnitIds: [UnitIdentifier] = []
        var detectedLanguage: String?
        var seenEntities = Set<String>()

        for contextUnit in units {
            let unit = contextUnit.annotatedUnit.unit
            allUnitIds.append(unit.id)

            switch unit.subject {
            case .entity(let ref):
                let name = ref.qualifiedName
                if !seenEntities.contains(name) {
                    seenEntities.insert(name)
                    entityNames.append(name)
                }
                let valueText = textRepresentation(of: unit.value)
                entityFacts[name, default: []].append((
                    predicate: unit.predicate.name,
                    value: valueText,
                    unitId: unit.id
                ))

                if unit.predicate.name == "language" || unit.predicate.name == "sourceLanguage" {
                    detectedLanguage = valueText
                }

            case .pair(let pair):
                relationships.append((
                    source: pair.source.qualifiedName,
                    predicate: unit.predicate.name,
                    target: pair.target.qualifiedName,
                    unitId: unit.id
                ))
            }
        }

        return ExtractedKnowledge(
            entityNames: entityNames,
            entityFacts: entityFacts,
            relationships: relationships,
            allUnitIds: allUnitIds,
            detectedLanguage: detectedLanguage
        )
    }

    /// Converts a TypedValue to a human-readable text representation.
    static func textRepresentation(of value: TypedValue) -> String {
        switch value {
        case .string(let s): return s
        case .text(let t): return t
        case .integer(let i): return String(i)
        case .boolean(let b): return b ? "true" : "false"
        case .float(let f): return String(f)
        case .enumerated(let e): return e
        case .reference(let ref): return ref.qualifiedName
        case .structured(let dict):
            return dict.map { "\($0.key): \(textRepresentation(of: $0.value))" }
                .joined(separator: ", ")
        }
    }

    // MARK: - Module Observation Extraction

    /// Extracts module observations from extracted knowledge.
    ///
    /// Identifies module entities (`module:*` prefix), extracts their emergent
    /// properties, applies suppression rules, interprets surviving properties,
    /// and generates guidance directives.
    ///
    /// Returns nil when:
    /// - No module entity exists in the knowledge
    /// - The module has only 1 file (module = file, no framing value)
    /// - All properties are suppressed
    ///
    /// - Parameters:
    ///   - knowledge: Extracted knowledge from the context frame.
    ///   - codeEntityNames: Non-module entity names to determine the primary entity.
    /// - Returns: Module observations if applicable, nil otherwise.
    static func extractModuleObservations(
        from knowledge: ExtractedKnowledge,
        codeEntityNames: [String]
    ) -> ModuleObservations? {
        // Find the first module entity.
        guard let moduleEntityName = knowledge.entityNames.first(where: { $0.hasPrefix("module:") }),
              let moduleFacts = knowledge.entityFacts[moduleEntityName]
        else { return nil }

        let moduleName = String(moduleEntityName.dropFirst("module:".count))

        // Parse module properties from facts.
        let properties = parseModuleProperties(from: moduleFacts)

        // Suppression: single-file module.
        if let fileCount = properties.fileCount, fileCount <= 1 {
            return nil
        }

        // Determine the primary entity being explained.
        let primaryEntity = codeEntityNames.first ?? "unknown"

        // Build observations with suppression rules.
        let role = buildRoleObservation(properties: properties, primaryEntity: primaryEntity)
        let visibility = buildVisibilityObservation(
            properties: properties,
            primaryEntity: primaryEntity
        )
        let cohesion = buildCohesionObservation(properties: properties)
        let style = buildStyleObservation(properties: properties)
        let boundary = buildBoundaryObservation(properties: properties, primaryEntity: primaryEntity)

        // If all observations are suppressed, return nil.
        if role == nil && visibility == nil && cohesion == nil && style == nil && boundary == nil {
            return nil
        }

        // Generate guidance from the combination of surviving observations.
        let guidance = generateGuidance(
            role: role,
            visibility: visibility,
            cohesion: cohesion,
            style: style,
            boundary: boundary
        )

        return ModuleObservations(
            moduleName: moduleName,
            entityName: primaryEntity,
            role: role,
            visibility: visibility,
            cohesion: cohesion,
            style: style,
            boundary: boundary,
            guidance: guidance
        )
    }

    /// Removes module entities from extracted knowledge, returning filtered
    /// entity names and facts for prompt construction.
    ///
    /// Module entity evidence is consumed by the observation layer — it should
    /// not appear as raw facts in the entity section of the prompt.
    static func filterModuleEntities(
        from knowledge: ExtractedKnowledge
    ) -> (entityNames: [String], entityFacts: [String: [(predicate: String, value: String, unitId: UnitIdentifier)]]) {
        let filteredNames = knowledge.entityNames.filter { !$0.hasPrefix("module:") }
        let filteredFacts = knowledge.entityFacts.filter { !$0.key.hasPrefix("module:") }
        return (filteredNames, filteredFacts)
    }

    // MARK: - Module Property Parsing

    /// Parsed module emergent properties from raw entity facts.
    private struct ModuleProperties {
        var moduleRole: String?
        var cohesionRatio: Double?
        var cohesionInternal: Int?
        var cohesionExternal: Int?
        var publicInterfaceCount: Int?
        var publicInterfaceEntities: String?
        var interactionCalls: Int?
        var interactionConformsTo: Int?
        var interactionInherits: Int?
        var boundaryInboundCalls: Int?
        var boundaryOutboundCalls: Int?
        var boundaryInboundConformsTo: Int?
        var boundaryOutboundConformsTo: Int?
        var boundaryInboundInherits: Int?
        var boundaryOutboundInherits: Int?
        var fileCount: Int?
    }

    /// Parses module facts into structured properties.
    private static func parseModuleProperties(
        from facts: [(predicate: String, value: String, unitId: UnitIdentifier)]
    ) -> ModuleProperties {
        var props = ModuleProperties()

        for fact in facts {
            switch fact.predicate {
            case "moduleRole":
                props.moduleRole = fact.value

            case "cohesion":
                // Structured value: "internal: N, external: N, ratio: D"
                let parts = parseStructuredValue(fact.value)
                if let internal_ = parts["internal"] { props.cohesionInternal = Int(internal_) }
                if let external_ = parts["external"] { props.cohesionExternal = Int(external_) }
                if let ratio = parts["ratio"] { props.cohesionRatio = Double(ratio) }

            case "publicInterface":
                let parts = parseStructuredValue(fact.value)
                if let count = parts["count"] { props.publicInterfaceCount = Int(count) }
                props.publicInterfaceEntities = parts["entities"]

            case "interactionProfile":
                let parts = parseStructuredValue(fact.value)
                if let calls = parts["calls"] { props.interactionCalls = Int(calls) }
                if let conformsTo = parts["conformsTo"] { props.interactionConformsTo = Int(conformsTo) }
                if let inherits = parts["inherits"] { props.interactionInherits = Int(inherits) }

            case "boundaryProfile":
                let parts = parseStructuredValue(fact.value)
                if let v = parts["inboundCalls"] { props.boundaryInboundCalls = Int(v) }
                if let v = parts["outboundCalls"] { props.boundaryOutboundCalls = Int(v) }
                if let v = parts["inboundConformsTo"] { props.boundaryInboundConformsTo = Int(v) }
                if let v = parts["outboundConformsTo"] { props.boundaryOutboundConformsTo = Int(v) }
                if let v = parts["inboundInherits"] { props.boundaryInboundInherits = Int(v) }
                if let v = parts["outboundInherits"] { props.boundaryOutboundInherits = Int(v) }

            case "fileCount":
                props.fileCount = Int(fact.value)

            default:
                break
            }
        }

        return props
    }

    /// Parses a structured value string like "key1: val1, key2: val2" into a dictionary.
    private static func parseStructuredValue(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for pair in pairs {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Observation Builders

    private static func buildRoleObservation(
        properties: ModuleProperties,
        primaryEntity: String
    ) -> ModuleObservations.RoleObservation? {
        guard let role = properties.moduleRole else { return nil }

        // Suppress "mixed" for internal entities (not in public interface).
        if role == "mixed" {
            let isPublic = isEntityInPublicInterface(primaryEntity, properties: properties)
            if !isPublic { return nil }
        }

        let interpretation: String
        switch role {
        case "provider": interpretation = "other modules depend on this module"
        case "consumer": interpretation = "this module depends on other modules"
        case "isolated": interpretation = "self-contained, no cross-module dependencies"
        case "mixed": interpretation = "both serves and consumes other modules"
        default: return nil
        }

        return ModuleObservations.RoleObservation(value: role, interpretation: interpretation)
    }

    private static func buildVisibilityObservation(
        properties: ModuleProperties,
        primaryEntity: String
    ) -> ModuleObservations.VisibilityObservation? {
        guard let count = properties.publicInterfaceCount, count > 0 else { return nil }

        if isEntityInPublicInterface(primaryEntity, properties: properties) {
            return ModuleObservations.VisibilityObservation(
                value: "public-interface",
                interpretation: "referenced by external modules"
            )
        }

        return nil
    }

    private static func buildCohesionObservation(
        properties: ModuleProperties
    ) -> ModuleObservations.CohesionObservation? {
        guard let ratio = properties.cohesionRatio else { return nil }

        if ratio > 0.8 {
            return ModuleObservations.CohesionObservation(
                value: "high",
                interpretation: "components tightly integrated"
            )
        } else if ratio < 0.3 {
            return ModuleObservations.CohesionObservation(
                value: "low",
                interpretation: "components relatively independent"
            )
        }

        // Moderate cohesion (0.3–0.8) is suppressed.
        return nil
    }

    private static func buildStyleObservation(
        properties: ModuleProperties
    ) -> ModuleObservations.StyleObservation? {
        let calls = properties.interactionCalls ?? 0
        let conformsTo = properties.interactionConformsTo ?? 0
        let inherits = properties.interactionInherits ?? 0
        let total = calls + conformsTo + inherits

        // Suppress if too few relationships (< 5).
        guard total >= 5 else { return nil }

        let dominanceThreshold = Double(total) * 0.6

        if Double(calls) > dominanceThreshold {
            return ModuleObservations.StyleObservation(
                value: "call-dominant",
                interpretation: "components communicate through function calls"
            )
        } else if Double(conformsTo) > dominanceThreshold {
            return ModuleObservations.StyleObservation(
                value: "protocol-dominant",
                interpretation: "organized around protocol contracts"
            )
        } else if Double(inherits) > dominanceThreshold {
            return ModuleObservations.StyleObservation(
                value: "inheritance-dominant",
                interpretation: "organized around class hierarchies"
            )
        }

        // No dominant type — suppressed.
        return nil
    }

    private static func buildBoundaryObservation(
        properties: ModuleProperties,
        primaryEntity: String
    ) -> ModuleObservations.BoundaryObservation? {
        let inbound = (properties.boundaryInboundCalls ?? 0)
            + (properties.boundaryInboundConformsTo ?? 0)
            + (properties.boundaryInboundInherits ?? 0)
        let outbound = (properties.boundaryOutboundCalls ?? 0)
            + (properties.boundaryOutboundConformsTo ?? 0)
            + (properties.boundaryOutboundInherits ?? 0)

        let total = inbound + outbound
        guard total > 0 else { return nil }

        // Only show boundary for entities at the module boundary.
        let isPublic = isEntityInPublicInterface(primaryEntity, properties: properties)
        guard isPublic else { return nil }

        if inbound > 2 * outbound || outbound == 0 {
            return ModuleObservations.BoundaryObservation(
                value: "inbound-heavy",
                interpretation: "primarily consumed by other modules"
            )
        } else if outbound > 2 * inbound || inbound == 0 {
            return ModuleObservations.BoundaryObservation(
                value: "outbound-heavy",
                interpretation: "primarily consumes other modules"
            )
        }

        // Balanced boundary — suppressed.
        return nil
    }

    // MARK: - Guidance Generation

    private static func generateGuidance(
        role: ModuleObservations.RoleObservation?,
        visibility: ModuleObservations.VisibilityObservation?,
        cohesion: ModuleObservations.CohesionObservation?,
        style: ModuleObservations.StyleObservation?,
        boundary: ModuleObservations.BoundaryObservation?
    ) -> String {
        var directives: [String] = []

        // Primary guidance from role + visibility combination.
        if let visibility, let role {
            switch (visibility.value, role.value) {
            case ("public-interface", "provider"):
                directives.append("Frame as outward-facing contract. Note cross-module impact of changes.")
            case ("public-interface", "consumer"):
                directives.append("Frame as external dependency surface. Note what this entity requires from other modules.")
            case ("public-interface", _):
                directives.append("Note that this entity is part of the module's public interface.")
            default:
                break
            }
        } else if let role {
            switch role.value {
            case "provider":
                directives.append("Note that this module serves others, but this entity is internal to it.")
            case "consumer":
                directives.append("Note that this module depends on other modules.")
            case "isolated":
                directives.append("Note self-containment — no external dependencies or dependents.")
            default:
                break
            }
        }

        // Cohesion guidance.
        if let cohesion {
            if cohesion.value == "high" {
                directives.append("Emphasize connections to sibling entities.")
            } else if cohesion.value == "low" {
                directives.append("Note relative independence from sibling entities.")
            }
        }

        // Style guidance.
        if let style {
            directives.append("This module's dominant interaction pattern is \(style.value).")
        }

        if directives.isEmpty {
            directives.append("Mention module context briefly where it aids understanding.")
        }

        return directives.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func isEntityInPublicInterface(
        _ entityName: String,
        properties: ModuleProperties
    ) -> Bool {
        guard let entities = properties.publicInterfaceEntities else { return false }
        let entitySet = Set(entities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return entitySet.contains(entityName)
    }

    // MARK: - Claim Generation

    /// Builds grounded claims from extracted knowledge.
    ///
    /// DDS-009 UC-1, GP-1: Every claim must reference at least one context frame unit.
    /// Strategy: one claim per entity with all its supporting unit IDs as grounding references,
    /// plus one claim per relationship.
    static func buildClaims(
        from knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit]
    ) -> [UnderstandingClaim] {
        var claims: [UnderstandingClaim] = []

        for entityName in knowledge.entityNames {
            guard let facts = knowledge.entityFacts[entityName] else { continue }
            let unitIds = facts.map { $0.unitId }
            guard !unitIds.isEmpty else { continue }

            let maxTier = unitIds.compactMap { id -> Tier? in
                allUnits.first { $0.annotatedUnit.unit.id == id }?
                    .annotatedUnit.unit.tier
            }.max() ?? .t0

            let claimType: ClaimType
            let confidence: Confidence
            switch maxTier {
            case .t0:
                claimType = .factual
                confidence = .deterministic
            case .t1:
                claimType = .derived
                confidence = .high
            case .t2:
                claimType = .interpretive
                confidence = .high
            }

            let factSummary = facts.map { "\($0.predicate): \($0.value)" }
                .joined(separator: "; ")

            claims.append(UnderstandingClaim(
                content: "Entity \(entityName): \(factSummary)",
                claimType: claimType,
                confidence: confidence,
                groundingReferences: unitIds
            ))
        }

        for rel in knowledge.relationships {
            claims.append(UnderstandingClaim(
                content: "\(rel.source) \(rel.predicate) \(rel.target)",
                claimType: .factual,
                confidence: .deterministic,
                groundingReferences: [rel.unitId]
            ))
        }

        if claims.isEmpty && !knowledge.allUnitIds.isEmpty {
            claims.append(UnderstandingClaim(
                content: "Analysis derived from \(knowledge.allUnitIds.count) context frame units.",
                claimType: .interpretive,
                confidence: .moderate,
                groundingReferences: knowledge.allUnitIds
            ))
        }

        return claims
    }
}
