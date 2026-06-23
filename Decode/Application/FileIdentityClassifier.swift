import Foundation

/// Deterministic classifier that derives a file's identity from its name,
/// entity structure, and language.
///
/// This is the first understanding layer in Decode's progressive comprehension
/// model. It answers "What am I looking at?" using only structural signals —
/// no LLM call required.
///
/// The classifier uses a priority-ordered heuristic:
/// 1. File name patterns (strongest signal — engineers name files intentionally)
/// 2. Entity composition (what types of declarations dominate the file)
/// 3. Path-based layer detection (where the file lives in the project)
///
/// Classification doesn't need to be perfect. It's injected into the
/// explanation prompt as framing — the explanation LLM can refine or
/// override it based on the actual code.
enum FileIdentityClassifier {

    /// Classify a file's identity from structural signals.
    ///
    /// - Parameters:
    ///   - fileName: The file name (e.g., "SessionManager.swift").
    ///   - entities: Parsed entities from the file.
    ///   - language: Detected language (e.g., "swift", "python").
    ///   - filePath: Optional full file path for layer detection.
    /// - Returns: A `FileIdentity` describing the file's role and layer.
    static func classify(
        fileName: String,
        entities: [ParsedEntity],
        language: String,
        filePath: String? = nil
    ) -> FileIdentity {
        let baseName = (fileName as NSString).deletingPathExtension
        let role = detectRole(baseName: baseName, fileName: fileName, entities: entities)
        let layer = detectLayer(role: role, filePath: filePath, entities: entities)
        let patterns = detectPatterns(entities: entities, role: role)
        let summary = buildSummary(role: role, layer: layer, patterns: patterns, entityCount: entities.count)

        return FileIdentity(
            role: role,
            layer: layer,
            patterns: patterns,
            summary: summary
        )
    }

    // MARK: - Role Detection

    private static func detectRole(
        baseName: String,
        fileName: String,
        entities: [ParsedEntity]
    ) -> FileRole {
        let lowerName = baseName.lowercased()

        // Test files — strongest signal, check first.
        if lowerName.hasSuffix("tests") || lowerName.hasSuffix("test")
            || lowerName.hasPrefix("test") || lowerName.hasSuffix("spec") {
            return .test
        }

        // App entry points.
        if lowerName.hasSuffix("app") && !lowerName.contains("service") {
            return .appEntry
        }
        if lowerName == "appdependencies" || lowerName == "main" {
            return .appEntry
        }

        // Name-based role patterns (ordered by specificity).
        if lowerName.hasSuffix("coordinator") { return .coordinator }
        if lowerName.hasSuffix("viewmodel") || lowerName.contains("viewmodel") { return .viewModel }
        if lowerName.hasSuffix("view") || lowerName.hasSuffix("hud")
            || lowerName.hasSuffix("overlay") || lowerName.hasSuffix("panel")
            || lowerName.hasSuffix("sheet") || lowerName.hasSuffix("dock") {
            return .view
        }
        if lowerName.hasSuffix("manager") { return .manager }
        if lowerName.hasSuffix("service") { return .service }
        if lowerName.hasSuffix("parser") || lowerName.hasSuffix("transformer")
            || lowerName.hasSuffix("converter") || lowerName.hasSuffix("formatter") {
            return .parser
        }
        if lowerName.hasSuffix("protocol") || lowerName.hasSuffix("interface") {
            return .protocolDefinition
        }
        if lowerName.hasSuffix("config") || lowerName.hasSuffix("configuration")
            || lowerName.hasSuffix("constants") {
            return .configuration
        }

        // Entity-composition-based detection (when name isn't conclusive).
        return detectRoleFromEntities(entities)
    }

    private static func detectRoleFromEntities(_ entities: [ParsedEntity]) -> FileRole {
        let topLevel = entities.filter(\.isTopLevel)
        guard !topLevel.isEmpty else { return .unknown }

        let typeCounts = Dictionary(grouping: topLevel, by: \.entity.entityType)
            .mapValues(\.count)

        let protocolCount = typeCounts[.protocol] ?? 0
        let classCount = typeCounts[.class] ?? 0
        let structCount = typeCounts[.struct] ?? 0
        let enumCount = typeCounts[.enum] ?? 0
        let functionCount = typeCounts[.function] ?? 0

        // File is primarily protocol definitions.
        if protocolCount > 0 && protocolCount >= classCount + structCount {
            return .protocolDefinition
        }

        // File is primarily enums/structs with no methods — likely a model file.
        let totalTypes = classCount + structCount + enumCount
        let methodCount = entities.filter { $0.entity.entityType == .method }.count
        if totalTypes > 0 && totalTypes >= functionCount && methodCount <= totalTypes * 2 {
            return .model
        }

        // File is primarily free functions — could be utilities or configuration.
        if functionCount > 0 && functionCount > totalTypes {
            return .configuration
        }

        return .unknown
    }

    // MARK: - Layer Detection

    private static func detectLayer(
        role: FileRole,
        filePath: String?,
        entities: [ParsedEntity]
    ) -> ArchitecturalLayer {
        // Role-based layer inference.
        switch role {
        case .test: return .testing
        case .view, .viewModel: return .presentation
        case .coordinator, .manager: return .application
        case .protocolDefinition, .model: return .domain
        case .parser, .service: return .infrastructure
        default: break
        }

        // Path-based layer detection.
        if let path = filePath?.lowercased() {
            if path.contains("/presentation/") || path.contains("/views/") || path.contains("/ui/") {
                return .presentation
            }
            if path.contains("/application/") || path.contains("/coordinators/") {
                return .application
            }
            if path.contains("/domain/") || path.contains("/models/") {
                return .domain
            }
            if path.contains("/infrastructure/") || path.contains("/services/") {
                return .infrastructure
            }
            if path.contains("/tests/") || path.contains("/test/") {
                return .testing
            }
        }

        return .unknown
    }

    // MARK: - Pattern Detection

    private static func detectPatterns(
        entities: [ParsedEntity],
        role: FileRole
    ) -> [String] {
        var patterns: [String] = []

        let topLevel = entities.filter(\.isTopLevel)
        let signatures = entities.map(\.signature)
        let allSource = entities.map(\.sourceText).joined(separator: "\n")

        // Observable state container.
        if allSource.contains("@Observable") || allSource.contains("ObservableObject") {
            patterns.append("Observable state container")
        }

        // Dependency injection.
        let initEntities = entities.filter { $0.entity.name.contains("init") || $0.signature.contains("init(") }
        let hasInjectedDeps = initEntities.contains { sig in
            // init that takes protocol-typed or service-typed parameters
            sig.signature.contains(":") && (sig.signature.contains("Protocol") || sig.signature.contains("Service"))
        }
        if hasInjectedDeps {
            patterns.append("Dependency injection")
        }

        // Delegate / protocol conformance.
        let hasConformance = topLevel.contains { entity in
            entity.signature.contains(":")
                && entity.entity.entityType != .function
                && entity.entity.entityType != .method
        }
        if hasConformance && allSource.contains("delegate") {
            patterns.append("Delegate pattern")
        }

        // Singleton.
        if allSource.contains("static let shared") || allSource.contains("static var shared") {
            patterns.append("Singleton")
        }

        // Async/await.
        let asyncSignatures = signatures.filter { $0.contains("async") }
        if asyncSignatures.count >= 2 {
            patterns.append("Async/await concurrency")
        }

        // Visitor pattern.
        let visitMethods = entities.filter { $0.entity.name.contains("visit") && $0.entity.entityType == .method }
        if visitMethods.count >= 3 {
            patterns.append("Visitor pattern")
        }

        // State machine / enum with associated values.
        if role == .model {
            let enumEntities = topLevel.filter { $0.entity.entityType == .enum }
            let hasAssociatedValues = enumEntities.contains { $0.sourceText.contains("case") && $0.sourceText.contains("(") }
            if hasAssociatedValues {
                patterns.append("Algebraic data type")
            }
        }

        return patterns
    }

    // MARK: - Summary

    private static func buildSummary(
        role: FileRole,
        layer: ArchitecturalLayer,
        patterns: [String],
        entityCount: Int
    ) -> String {
        var parts: [String] = []

        // Role.
        parts.append(role.label)

        // Layer (only if meaningful).
        if !layer.label.isEmpty {
            parts.append(layer.label)
        }

        // Entity count as size signal.
        if entityCount > 0 {
            parts.append("\(entityCount) entities")
        }

        var summary = parts.joined(separator: " · ")

        // Append top patterns.
        if !patterns.isEmpty {
            let topPatterns = patterns.prefix(3).joined(separator: ", ")
            summary += ". Patterns: \(topPatterns)"
        }

        return summary
    }
}
