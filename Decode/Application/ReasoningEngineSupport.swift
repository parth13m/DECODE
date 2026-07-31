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

// MARK: - System Observations (M11 ConsumerRuntime support)

/// Semantic observation layer for system-level context.
///
/// Transforms raw system emergent properties (M8 composition + M9 emergence)
/// from the context frame into interpreted, actionable observations that
/// reasoning engines inject into prompts. Follows the ModuleObservations pattern.
///
/// The observation pipeline:
/// 1. Extract system entities and their properties from ExtractedKnowledge
/// 2. Apply suppression rules (trivial system, unknown style, etc.)
/// 3. Interpret surviving properties into observations
/// 4. Apply question-aware prioritization (ordering/emphasis)
/// 5. Generate guidance directives from the observation combination
/// 6. Format as a prompt-injectable observation block
struct SystemObservations: Sendable, Equatable {

    /// The system name (e.g., "Decode").
    let systemName: String

    /// The entity being explained (for the observation header).
    let entityName: String

    /// Architecture style observation. Nil when suppressed.
    let architecture: ArchitectureObservation?

    /// Dependency direction observation. Nil when suppressed.
    let dependencies: DependencyObservation?

    /// Scale observation. Nil when suppressed.
    let scale: ScaleObservation?

    /// Cross-cutting patterns observation. Nil when suppressed.
    let crossCutting: CrossCuttingObservation?

    /// Module interaction summary. Nil when suppressed.
    let interactions: InteractionObservation?

    /// Technology distribution observation. Nil when suppressed.
    let technologies: TechnologyObservation?

    /// Actionable guidance directives for the LLM.
    let guidance: String

    // MARK: - Observation Types

    struct ArchitectureObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct DependencyObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct ScaleObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct CrossCuttingObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct InteractionObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    struct TechnologyObservation: Sendable, Equatable {
        let value: String
        let interpretation: String
    }

    // MARK: - Prompt Formatting

    /// Formats the observations as a prompt-injectable block for the user prompt.
    ///
    /// Observations are emitted in a fixed priority order:
    /// architecture → dependencies → scale → cross-cutting → interactions → technologies.
    /// Question-aware prioritization may reorder via `formatForPrompt(prioritizedOrder:)`.
    func formatForPrompt() -> String {
        formatForPrompt(prioritizedOrder: nil)
    }

    /// Formats with optional question-aware ordering.
    ///
    /// - Parameter prioritizedOrder: Optional ordered list of observation keys to emit first.
    ///   Any observations not in this list are appended in default order.
    func formatForPrompt(prioritizedOrder: [ObservationKey]?) -> String {
        var lines: [String] = []
        lines.append("SYSTEM OBSERVATIONS — \(entityName)")
        lines.append("")
        lines.append("system:       \(systemName)")

        let orderedKeys = prioritizedOrder ?? ObservationKey.defaultOrder

        for key in orderedKeys {
            if let line = observationLine(for: key) {
                lines.append(line)
            }
        }

        lines.append("")
        lines.append("guidance:     \(guidance)")

        return lines.joined(separator: "\n")
    }

    /// Formats the observations as a compact one-line summary for ConversationState.
    func formatForContextSummary() -> String {
        var parts: [String] = ["System: \(systemName)"]
        if let architecture {
            parts.append(architecture.value)
        }
        if let scale {
            parts.append(scale.value)
        }
        return parts.joined(separator: ", ") + "."
    }

    /// System prompt instruction for system-aware explanations.
    static let systemPromptInstruction = """
    When SYSTEM OBSERVATIONS are present, use them to frame the entity's \
    architectural context — mention the system's structure, the entity's position \
    in it, and any cross-cutting or dependency patterns that improve understanding. \
    Do not create a separate architecture section. Weave system framing naturally, \
    typically as one or two sentences in the opening or closing of your explanation. \
    Follow the guidance directive. Do not restate observations as bullet points.
    """

    /// Follow-up system prompt instruction for system-aware context.
    static let followUpContextInstruction = """
    The context summary includes system-level architectural information. Reference it \
    only when the user's question touches architecture, impact, dependencies, or system design.
    """

    // MARK: - Observation Keys (for question-aware ordering)

    /// Identifies an observation category for prioritization.
    enum ObservationKey: String, Sendable, Equatable, CaseIterable {
        case architecture
        case dependencies
        case scale
        case crossCutting
        case interactions
        case technologies

        static let defaultOrder: [ObservationKey] = [
            .architecture, .dependencies, .scale, .crossCutting, .interactions, .technologies
        ]
    }

    /// Returns the formatted line for a given observation key, or nil if suppressed.
    private func observationLine(for key: ObservationKey) -> String? {
        switch key {
        case .architecture:
            guard let architecture else { return nil }
            return "architecture: \(architecture.value) — \(architecture.interpretation)"
        case .dependencies:
            guard let dependencies else { return nil }
            return "dependencies: \(dependencies.value) — \(dependencies.interpretation)"
        case .scale:
            guard let scale else { return nil }
            return "scale:        \(scale.value) — \(scale.interpretation)"
        case .crossCutting:
            guard let crossCutting else { return nil }
            return "cross-cutting: \(crossCutting.value) — \(crossCutting.interpretation)"
        case .interactions:
            guard let interactions else { return nil }
            return "interactions: \(interactions.value) — \(interactions.interpretation)"
        case .technologies:
            guard let technologies else { return nil }
            return "technologies: \(technologies.value) — \(technologies.interpretation)"
        }
    }
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

    // MARK: - System Observation Extraction (M11)

    /// Extracts system observations from extracted knowledge.
    ///
    /// Identifies system entities (`system:*` prefix), extracts their composition
    /// and emergent properties, applies suppression rules, interprets surviving
    /// properties, and generates guidance directives.
    ///
    /// Returns nil when:
    /// - No system entity exists in the knowledge
    /// - The system has fewer than 2 modules (trivial)
    /// - All observations are suppressed
    ///
    /// - Parameters:
    ///   - knowledge: Extracted knowledge from the context frame.
    ///   - codeEntityNames: Non-system, non-module entity names to determine the primary entity.
    ///   - moduleName: Optional module name of the entity being explained (for interaction filtering).
    ///   - questionHint: Optional question text for question-aware prioritization.
    /// - Returns: System observations if applicable, nil otherwise.
    static func extractSystemObservations(
        from knowledge: ExtractedKnowledge,
        codeEntityNames: [String],
        moduleName: String? = nil,
        questionHint: String? = nil
    ) -> SystemObservations? {
        // Find the first system entity.
        guard let systemEntityName = knowledge.entityNames.first(where: { $0.hasPrefix("system:") }),
              let systemFacts = knowledge.entityFacts[systemEntityName]
        else { return nil }

        let systemName = String(systemEntityName.dropFirst("system:".count))

        // Parse system properties from facts.
        let properties = parseSystemProperties(from: systemFacts)

        // Suppression: trivial system (fewer than 2 modules).
        if let moduleCount = properties.moduleCount, moduleCount < 2 {
            return nil
        }

        // Determine the primary entity being explained.
        let primaryEntity = codeEntityNames.first ?? "unknown"

        // Build observations with suppression rules.
        let architecture = buildArchitectureObservation(properties: properties)
        let dependencies = buildDependencyObservation(properties: properties)
        let scale = buildScaleObservation(properties: properties)
        let crossCutting = buildCrossCuttingObservation(properties: properties, primaryEntity: primaryEntity)
        let interactions = buildInteractionObservation(properties: properties, moduleName: moduleName)
        let technologies = buildTechnologyObservation(properties: properties)

        // If all observations are suppressed, return nil.
        if architecture == nil && dependencies == nil && scale == nil
            && crossCutting == nil && interactions == nil && technologies == nil {
            return nil
        }

        // Generate guidance from the combination of surviving observations.
        let guidance = generateSystemGuidance(
            architecture: architecture,
            dependencies: dependencies,
            crossCutting: crossCutting,
            moduleName: moduleName
        )

        // Question-aware observation ordering.
        let prioritizedOrder = questionAwareOrder(questionHint: questionHint)

        // Build the observations struct; embed the prioritized order in formatting.
        // The struct stores observations individually; ordering is applied at format time.
        return SystemObservations(
            systemName: systemName,
            entityName: primaryEntity,
            architecture: architecture,
            dependencies: dependencies,
            scale: scale,
            crossCutting: crossCutting,
            interactions: interactions,
            technologies: technologies,
            guidance: guidance
        )
    }

    /// Removes system entities from extracted knowledge, returning filtered
    /// entity names and facts for prompt construction.
    ///
    /// System entity evidence is consumed by the observation layer — it should
    /// not appear as raw facts in the entity section of the prompt.
    /// Also removes module entities (extends filterModuleEntities).
    static func filterProjectEntities(
        from knowledge: ExtractedKnowledge
    ) -> (entityNames: [String], entityFacts: [String: [(predicate: String, value: String, unitId: UnitIdentifier)]]) {
        let filteredNames = knowledge.entityNames.filter {
            !$0.hasPrefix("module:") && !$0.hasPrefix("system:")
        }
        let filteredFacts = knowledge.entityFacts.filter {
            !$0.key.hasPrefix("module:") && !$0.key.hasPrefix("system:")
        }
        return (filteredNames, filteredFacts)
    }

    // MARK: - System Property Parsing

    /// Parsed system properties from raw entity facts.
    struct SystemProperties {
        var architectureStyle: String?
        var architectureEvidence: String?
        var layerCount: Int?
        var hasCycles: Bool?
        var violationCount: Int?
        var totalEdges: Int?
        var moduleCount: Int?
        var totalFileCount: Int?
        var totalEntityCount: Int?
        var crossCuttingPatterns: [(name: String, referenceCount: Int)]?
        var crossCuttingThreshold: Int?
        var languages: [(name: String, percentage: Double)]?
        var primaryLanguage: String?
        var moduleInteractions: [(source: String, target: String, calls: Int, conformsTo: Int, inherits: Int)]?
    }

    /// Parses system facts into structured properties.
    static func parseSystemProperties(
        from facts: [(predicate: String, value: String, unitId: UnitIdentifier)]
    ) -> SystemProperties {
        var props = SystemProperties()

        for fact in facts {
            switch fact.predicate {
            case "architectureStyle":
                let parts = parseStructuredValue(fact.value)
                props.architectureStyle = parts["style"]
                props.architectureEvidence = parts["evidence"]

            case "dependencyDirection":
                let parts = parseStructuredValue(fact.value)
                if let v = parts["layerCount"] { props.layerCount = Int(v) }
                if let v = parts["hasCycles"] { props.hasCycles = v == "true" }
                if let v = parts["violationCount"] { props.violationCount = Int(v) }
                if let v = parts["totalEdges"] { props.totalEdges = Int(v) }

            case "moduleCount":
                props.moduleCount = Int(fact.value)

            case "totalFileCount":
                props.totalFileCount = Int(fact.value)

            case "totalEntityCount":
                props.totalEntityCount = Int(fact.value)

            case "crossCuttingPatterns":
                let parts = parseStructuredValue(fact.value)
                if let patternsStr = parts["patterns"] {
                    props.crossCuttingPatterns = parseCrossCuttingPatterns(patternsStr)
                }
                if let t = parts["threshold"] { props.crossCuttingThreshold = Int(t) }

            case "technologyDistribution":
                let parts = parseStructuredValue(fact.value)
                if let langsStr = parts["languages"] {
                    props.languages = parseLanguageDistribution(langsStr)
                }
                props.primaryLanguage = parts["primary"]

            case "moduleInteractionMap":
                let parts = parseStructuredValue(fact.value)
                if let edgesStr = parts["edges"] {
                    props.moduleInteractions = parseModuleInteractions(edgesStr)
                }

            default:
                break
            }
        }

        return props
    }

    /// Parses cross-cutting patterns from the structured value string.
    /// Format: "[EntityA(4), EntityB(3)]"
    private static func parseCrossCuttingPatterns(_ text: String) -> [(name: String, referenceCount: Int)] {
        var patterns: [(name: String, referenceCount: Int)] = []
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !cleaned.isEmpty else { return patterns }
        let items = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for item in items {
            // Format: "EntityName(N)"
            if let parenStart = item.firstIndex(of: "("),
               let parenEnd = item.firstIndex(of: ")") {
                let name = String(item[item.startIndex..<parenStart])
                let countStr = String(item[item.index(after: parenStart)..<parenEnd])
                if let count = Int(countStr) {
                    patterns.append((name: name, referenceCount: count))
                }
            }
        }
        return patterns
    }

    /// Parses language distribution from the structured value string.
    /// Format: "[Swift(92.5), Python(7.5)]"
    private static func parseLanguageDistribution(_ text: String) -> [(name: String, percentage: Double)] {
        var languages: [(name: String, percentage: Double)] = []
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !cleaned.isEmpty else { return languages }
        let items = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for item in items {
            if let parenStart = item.firstIndex(of: "("),
               let parenEnd = item.firstIndex(of: ")") {
                let name = String(item[item.startIndex..<parenStart])
                let pctStr = String(item[item.index(after: parenStart)..<parenEnd])
                if let pct = Double(pctStr) {
                    languages.append((name: name, percentage: pct))
                }
            }
        }
        return languages
    }

    /// Parses module interactions from the structured value string.
    /// Format: "[ModA->ModB(calls:10, conformsTo:2, inherits:0)]"
    private static func parseModuleInteractions(_ text: String) -> [(source: String, target: String, calls: Int, conformsTo: Int, inherits: Int)] {
        var interactions: [(source: String, target: String, calls: Int, conformsTo: Int, inherits: Int)] = []
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !cleaned.isEmpty else { return interactions }
        let items = cleaned.split(separator: "],").map { $0.trimmingCharacters(in: .whitespaces) }
        for item in items {
            let cleanedItem = item.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            // Format: "ModA->ModB(calls:10, conformsTo:2, inherits:0)"
            if let arrowRange = cleanedItem.range(of: "->"),
               let parenStart = cleanedItem.firstIndex(of: "(") {
                let source = String(cleanedItem[cleanedItem.startIndex..<arrowRange.lowerBound])
                let target = String(cleanedItem[arrowRange.upperBound..<parenStart])
                let paramsStr = String(cleanedItem[cleanedItem.index(after: parenStart)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                let params = parseStructuredValue(paramsStr)
                interactions.append((
                    source: source,
                    target: target,
                    calls: Int(params["calls"] ?? "0") ?? 0,
                    conformsTo: Int(params["conformsTo"] ?? "0") ?? 0,
                    inherits: Int(params["inherits"] ?? "0") ?? 0
                ))
            }
        }
        return interactions
    }

    // MARK: - System Observation Builders

    private static func buildArchitectureObservation(
        properties: SystemProperties
    ) -> SystemObservations.ArchitectureObservation? {
        guard let style = properties.architectureStyle, style != "unknown" else { return nil }

        var interpretation = style
        if let evidence = properties.architectureEvidence {
            interpretation = evidence
        } else if let layerCount = properties.layerCount {
            interpretation = "\(layerCount) layers"
        }

        return SystemObservations.ArchitectureObservation(
            value: style,
            interpretation: interpretation
        )
    }

    private static func buildDependencyObservation(
        properties: SystemProperties
    ) -> SystemObservations.DependencyObservation? {
        guard let layerCount = properties.layerCount, layerCount >= 2 else { return nil }

        let hasCycles = properties.hasCycles ?? false
        let violations = properties.violationCount ?? 0
        let edges = properties.totalEdges ?? 0

        let cycleText = hasCycles ? "cycles detected" : "no cycles"
        let value = "\(layerCount) layers, \(cycleText), \(violations) violations"
        let interpretation: String
        if !hasCycles && violations == 0 {
            interpretation = "clean dependency flow across \(edges) edges"
        } else if hasCycles {
            interpretation = "dependency cycles present — architectural concern"
        } else {
            interpretation = "\(violations) layer violation\(violations == 1 ? "" : "s") across \(edges) edges"
        }

        return SystemObservations.DependencyObservation(
            value: value,
            interpretation: interpretation
        )
    }

    private static func buildScaleObservation(
        properties: SystemProperties
    ) -> SystemObservations.ScaleObservation? {
        guard let moduleCount = properties.moduleCount, moduleCount >= 2 else { return nil }

        let files = properties.totalFileCount ?? 0
        let entities = properties.totalEntityCount ?? 0

        let value = "\(moduleCount) modules, \(files) files, \(entities) entities"
        let interpretation: String
        if moduleCount <= 5 {
            interpretation = "small system"
        } else if moduleCount <= 15 {
            interpretation = "medium-scale system"
        } else {
            interpretation = "large-scale system"
        }

        return SystemObservations.ScaleObservation(
            value: value,
            interpretation: interpretation
        )
    }

    private static func buildCrossCuttingObservation(
        properties: SystemProperties,
        primaryEntity: String
    ) -> SystemObservations.CrossCuttingObservation? {
        guard let patterns = properties.crossCuttingPatterns, !patterns.isEmpty else { return nil }

        let value = patterns.map { "\($0.name) (\($0.referenceCount) modules)" }
            .joined(separator: ", ")

        // Check if the primary entity is itself a cross-cutting concern.
        let entityIsCrossCutting = patterns.contains { $0.name == primaryEntity }
        let interpretation: String
        if entityIsCrossCutting {
            let count = patterns.first { $0.name == primaryEntity }?.referenceCount ?? 0
            interpretation = "this entity is a cross-cutting concern referenced by \(count) modules"
        } else {
            interpretation = "\(patterns.count) cross-cutting concern\(patterns.count == 1 ? "" : "s") in the system"
        }

        return SystemObservations.CrossCuttingObservation(
            value: value,
            interpretation: interpretation
        )
    }

    private static func buildInteractionObservation(
        properties: SystemProperties,
        moduleName: String?
    ) -> SystemObservations.InteractionObservation? {
        guard let interactions = properties.moduleInteractions, !interactions.isEmpty else { return nil }
        guard let moduleName else { return nil }

        // Filter to interactions involving the entity's module.
        let relevant = interactions.filter { $0.source == moduleName || $0.target == moduleName }
        guard !relevant.isEmpty else { return nil }

        let value: String = relevant.prefix(3).map { edge -> String in
            let total = edge.calls + edge.conformsTo + edge.inherits
            return "\(edge.source)↔\(edge.target) (\(total) relationships)"
        }.joined(separator: ", ")

        let totalRelationships = relevant.reduce(0) { $0 + $1.calls + $1.conformsTo + $1.inherits }
        let interpretation = "\(relevant.count) module connection\(relevant.count == 1 ? "" : "s"), \(totalRelationships) total relationships"

        return SystemObservations.InteractionObservation(
            value: value,
            interpretation: interpretation
        )
    }

    private static func buildTechnologyObservation(
        properties: SystemProperties
    ) -> SystemObservations.TechnologyObservation? {
        guard let languages = properties.languages, languages.count >= 2 else { return nil }

        let value: String = languages.prefix(3).map { lang -> String in
            let pctStr = String(format: "%.0f%%", lang.percentage)
            return "\(lang.name) \(pctStr)"
        }.joined(separator: ", ")

        let primary = properties.primaryLanguage ?? languages.first?.name ?? "unknown"
        let interpretation = "\(primary)-dominant system"

        return SystemObservations.TechnologyObservation(
            value: value,
            interpretation: interpretation
        )
    }

    // MARK: - System Guidance Generation

    private static func generateSystemGuidance(
        architecture: SystemObservations.ArchitectureObservation?,
        dependencies: SystemObservations.DependencyObservation?,
        crossCutting: SystemObservations.CrossCuttingObservation?,
        moduleName: String?
    ) -> String {
        var directives: [String] = []

        if let architecture {
            if let _ = moduleName {
                directives.append("Frame this entity within a \(architecture.value) system architecture.")
            } else {
                directives.append("This is a \(architecture.value) system.")
            }
        }

        if let dependencies {
            let hasCycles = dependencies.value.contains("cycles detected")
            if hasCycles {
                directives.append("Note dependency cycles — this may affect change impact.")
            } else if dependencies.value.contains("0 violations") {
                directives.append("Dependencies flow cleanly — mention architectural position when relevant.")
            }
        }

        if let crossCutting {
            if crossCutting.interpretation.contains("this entity is a cross-cutting") {
                directives.append("Emphasize cross-module impact — changes here affect multiple modules.")
            }
        }

        if directives.isEmpty {
            directives.append("Mention system context briefly where it aids understanding.")
        }

        return directives.joined(separator: " ")
    }

    // MARK: - Question-Aware Observation Ordering (M11)

    /// Determines observation ordering based on question intent.
    ///
    /// This is lightweight prioritization within the reasoning layer only.
    /// It does not introduce new classification — it reads the question text
    /// and adjusts observation ordering/emphasis deterministically.
    ///
    /// - Parameter questionHint: Optional question text.
    /// - Returns: Prioritized observation order, or nil for default ordering.
    static func questionAwareOrder(
        questionHint: String?
    ) -> [SystemObservations.ObservationKey]? {
        guard let question = questionHint, !question.isEmpty else { return nil }

        let q = question.lowercased()

        // "Why" questions → architecture + dependencies first
        if q.contains("why") || q.contains("purpose of") || q.contains("reason") {
            return [.architecture, .dependencies, .scale, .crossCutting, .interactions, .technologies]
        }

        // Impact/change questions → dependencies + cross-cutting first
        if q.contains("impact") || q.contains("break") || q.contains("change")
            || q.contains("affect") || q.contains("who calls") || q.contains("who uses") {
            return [.dependencies, .crossCutting, .interactions, .architecture, .scale, .technologies]
        }

        // High-level overview → architecture + scale + technologies first
        if q.contains("overview") || q.contains("architecture") || q.contains("big picture")
            || q.contains("high-level") || q.contains("high level") || q.contains("how is this organized") {
            return [.architecture, .scale, .technologies, .dependencies, .crossCutting, .interactions]
        }

        // Narrow/syntax → suppress most (nil prioritization = default order, but
        // the reasoning engine should check this and skip system observations)
        if q.contains("what does this line") || q.contains("syntax")
            || q.contains("just this") || q.contains("only this") || q.contains("this specific") {
            // Return nil to signal that system observations should be minimized.
            // The engine uses shouldSuppressForNarrowQuestion() to check this.
            return nil
        }

        // Default ordering
        return nil
    }

    /// Returns true if the question is narrow/syntax-focused and system observations
    /// should be suppressed or minimized.
    static func shouldSuppressSystemForNarrowQuestion(questionHint: String?) -> Bool {
        guard let question = questionHint, !question.isEmpty else { return false }
        let q = question.lowercased()
        return q.contains("what does this line") || q.contains("syntax")
            || q.contains("just this") || q.contains("only this") || q.contains("this specific")
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
    ///
    /// Handles bracket-enclosed values that contain commas, e.g.:
    /// "patterns: [EntityA(4), EntityB(3)], threshold: 3"
    private static func parseStructuredValue(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var pairs: [String] = []
        var current = ""
        var bracketDepth = 0

        for char in text {
            if char == "[" {
                bracketDepth += 1
                current.append(char)
            } else if char == "]" {
                bracketDepth -= 1
                current.append(char)
            } else if char == "," && bracketDepth == 0 {
                pairs.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pairs.append(current.trimmingCharacters(in: .whitespaces))
        }

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
