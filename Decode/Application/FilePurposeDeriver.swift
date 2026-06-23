import Foundation

/// Derives a one-sentence purpose statement for a source file.
///
/// Purpose answers "Why does this file exist?" — not what kind of file it is
/// (Identity), not what it does internally (Behavior), but why a developer
/// created it and what responsibility it owns.
///
/// Derivation is fully deterministic. It composes the purpose from:
/// 1. File name decomposition (subject + role suffix)
/// 2. Role-specific action verbs
/// 3. Method/entity name analysis for specificity
///
/// The derived purpose is injected into the explanation prompt so the LLM
/// frames every explanation in terms of the file's reason for existing.
enum FilePurposeDeriver {

    /// Derive a one-sentence purpose statement.
    ///
    /// Returns a sentence like "Manages session lifecycle — creation, parsing,
    /// and file watching." Returns an empty string only if there is genuinely
    /// nothing meaningful to say.
    static func derivePurpose(
        fileName: String,
        identity: FileIdentity,
        entities: [ParsedEntity]
    ) -> String {
        let baseName = (fileName as NSString).deletingPathExtension

        switch identity.role {
        case .manager, .coordinator, .service:
            return deriveBehavioralPurpose(baseName: baseName, role: identity.role, entities: entities)
        case .viewModel:
            return deriveViewModelPurpose(baseName: baseName, entities: entities)
        case .view:
            return deriveViewPurpose(baseName: baseName)
        case .model:
            return deriveModelPurpose(baseName: baseName, entities: entities)
        case .protocolDefinition:
            return deriveProtocolPurpose(baseName: baseName, entities: entities)
        case .parser:
            return deriveParserPurpose(baseName: baseName, entities: entities)
        case .test:
            return deriveTestPurpose(baseName: baseName)
        case .appEntry:
            return deriveAppEntryPurpose(baseName: baseName)
        case .configuration:
            return deriveConfigPurpose(baseName: baseName, entities: entities)
        case .extensionFile:
            return deriveExtensionPurpose(baseName: baseName)
        case .unknown:
            return deriveFallbackPurpose(baseName: baseName, entities: entities)
        }
    }

    // MARK: - Role-Specific Derivation

    /// For managers, coordinators, services: extract key responsibilities from method names.
    private static func deriveBehavioralPurpose(
        baseName: String,
        role: FileRole,
        entities: [ParsedEntity]
    ) -> String {
        let subject = extractSubject(from: baseName, stripping: roleSuffixes)
        let verb = roleVerb(for: role)
        let responsibilities = extractResponsibilities(from: entities)

        if responsibilities.isEmpty {
            return "\(verb) \(subject)."
        }
        return "\(verb) \(subject) — \(formatList(responsibilities))."
    }

    private static func deriveViewModelPurpose(baseName: String, entities: [ParsedEntity]) -> String {
        let subject = extractSubject(from: baseName, stripping: ["ViewModel", "VM"])
        let actions = extractResponsibilities(from: entities)
        if actions.isEmpty {
            return "Drives the \(subject) UI — transforms state for presentation."
        }
        return "Drives the \(subject) UI — \(formatList(actions))."
    }

    private static func deriveViewPurpose(baseName: String) -> String {
        let subject = extractSubject(from: baseName, stripping: viewSuffixes)
        return "Presents the \(subject) interface."
    }

    private static func deriveModelPurpose(baseName: String, entities: [ParsedEntity]) -> String {
        let topLevel = entities.filter(\.isTopLevel)

        // If file has enums, describe what they represent.
        let enums = topLevel.filter { $0.entity.entityType == .enum }
        let structs = topLevel.filter { $0.entity.entityType == .struct || $0.entity.entityType == .class }

        if !structs.isEmpty && enums.isEmpty {
            let fieldSummary = extractFieldTheme(from: structs.first!, allEntities: entities)
            if let theme = fieldSummary {
                return "Represents \(readableSubject(baseName)) — \(theme)."
            }
            return "Represents \(readableSubject(baseName))."
        }

        if !enums.isEmpty && structs.isEmpty {
            return "Defines the \(readableSubject(baseName)) type vocabulary."
        }

        // Mixed: structs + enums.
        let typeNames = topLevel.map(\.entity.name)
        if typeNames.count <= 3 {
            return "Defines \(formatList(typeNames.map { readableEntityName($0) }))."
        }
        return "Defines the \(readableSubject(baseName)) domain types."
    }

    private static func deriveProtocolPurpose(baseName: String, entities: [ParsedEntity]) -> String {
        let protocols = entities.filter { $0.entity.entityType == .protocol && $0.isTopLevel }
        if protocols.count == 1 {
            let methods = entities.filter { $0.entity.entityType == .method && $0.parentStableId == protocols[0].entity.stableId }
            let subject = extractSubject(from: protocols[0].entity.name, stripping: ["Protocol"])
            if methods.isEmpty {
                return "Defines the contract for \(readableSubject(subject))."
            }
            let methodSummary = methods.prefix(3).map { extractVerb(from: $0.entity.name) }
                .compactMap { $0 }
            if methodSummary.isEmpty {
                return "Defines the contract for \(readableSubject(subject))."
            }
            return "Defines the contract for \(readableSubject(subject)) — \(formatList(methodSummary))."
        }
        return "Defines contracts for \(readableSubject(baseName))."
    }

    private static func deriveParserPurpose(baseName: String, entities: [ParsedEntity]) -> String {
        let subject = extractSubject(from: baseName, stripping: ["Parser", "Transformer", "Converter", "Formatter"])
        return "Extracts structured information from \(subject) input."
    }

    private static func deriveTestPurpose(baseName: String) -> String {
        let subject = extractSubject(from: baseName, stripping: ["Tests", "Test", "Spec"])
        return "Tests \(readableSubject(subject))."
    }

    private static func deriveAppEntryPurpose(baseName: String) -> String {
        let lower = baseName.lowercased()
        if lower.contains("dependencies") || lower.contains("container") {
            return "Root dependency container — constructs and wires all services."
        }
        if lower.hasSuffix("app") || lower == "main" {
            return "Application entry point and scene configuration."
        }
        return "Application bootstrap and setup."
    }

    private static func deriveConfigPurpose(baseName: String, entities: [ParsedEntity]) -> String {
        return "Defines \(readableSubject(baseName)) constants and configuration."
    }

    private static func deriveExtensionPurpose(baseName: String) -> String {
        // Extension files often have "+" in the name: "Type+Feature.swift"
        if baseName.contains("+") {
            let parts = baseName.split(separator: "+", maxSplits: 1)
            if parts.count == 2 {
                let type = readableSubject(String(parts[0]))
                let feature = readableSubject(String(parts[1]))
                return "Extends \(type) with \(feature) capabilities."
            }
        }
        return "Extends \(readableSubject(baseName)) with additional functionality."
    }

    private static func deriveFallbackPurpose(baseName: String, entities: [ParsedEntity]) -> String {
        let topLevel = entities.filter(\.isTopLevel)
        guard !topLevel.isEmpty else { return "" }

        // Try to derive from the dominant entity type.
        if topLevel.count == 1 {
            let entity = topLevel[0]
            let name = readableEntityName(entity.entity.name)
            switch entity.entity.entityType {
            case .class, .struct:
                return "Defines \(name)."
            case .enum:
                return "Defines the \(name) type."
            case .function:
                return "Provides the \(name) function."
            default:
                return "Defines \(name)."
            }
        }

        return ""
    }

    // MARK: - Responsibility Extraction

    /// Extract the key responsibilities from method names.
    ///
    /// Looks at public-facing method names (non-private, non-helper),
    /// groups them by verb theme, and returns the top themes as
    /// short responsibility phrases.
    private static func extractResponsibilities(from entities: [ParsedEntity]) -> [String] {
        // Focus on methods and functions (the behavioral surface).
        let behavioral = entities.filter {
            ($0.entity.entityType == .method || $0.entity.entityType == .function)
                && !$0.entity.name.hasPrefix("_")
        }

        guard !behavioral.isEmpty else { return [] }

        // Extract verb-object pairs from method names.
        var themes: [String: Int] = [:]
        for entity in behavioral {
            if let theme = extractTheme(from: entity.entity.name) {
                themes[theme, default: 0] += 1
            }
        }

        // Sort by frequency, take top 3.
        return themes.sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    /// Extract a responsibility theme from a method name.
    ///
    /// "createSession" → "session creation"
    /// "buildContext" → "context building"
    /// "parseFile" → "file parsing"
    private static func extractTheme(from methodName: String) -> String? {
        let parts = splitCamelCase(methodName)
        guard parts.count >= 2 else { return nil }

        let verb = parts[0].lowercased()

        // Skip getters, setters, helpers, and internal methods.
        let skipVerbs: Set<String> = [
            "get", "set", "is", "has", "did", "will", "should",
            "make", "init", "deinit", "description",
        ]
        if skipVerbs.contains(verb) { return nil }

        // The object is everything after the verb.
        let objectParts = parts.dropFirst()
        let object = objectParts.joined(separator: " ").lowercased()

        // Map verb to gerund/noun form for natural reading.
        let gerund = verbToNoun(verb)
        return "\(object) \(gerund)"
    }

    /// Extract just a verb phrase for protocol method summaries.
    private static func extractVerb(from methodName: String) -> String? {
        let parts = splitCamelCase(methodName)
        guard parts.count >= 2 else { return nil }
        let verb = parts[0].lowercased()
        let skipVerbs: Set<String> = ["get", "set", "is", "has", "did", "will", "should"]
        if skipVerbs.contains(verb) { return nil }
        let objectParts = parts.dropFirst()
        return "\(verb) \(objectParts.joined(separator: " ").lowercased())"
    }

    /// Extract a field-based theme for model types.
    ///
    /// Looks at the properties (methods on a struct = computed properties + stored)
    /// and tries to summarize what the model carries.
    private static func extractFieldTheme(from entity: ParsedEntity, allEntities: [ParsedEntity]) -> String? {
        let children = allEntities.filter { $0.parentStableId == entity.entity.stableId }
        let propertyNames = children
            .filter { $0.entity.entityType == .method || $0.entity.entityType == .function }
            .map(\.entity.name)

        guard propertyNames.count >= 2 else { return nil }

        // Look for recognizable field clusters.
        let names = Set(propertyNames.map { $0.lowercased() })
        if names.contains("id") || names.contains("uuid") {
            if names.contains("name") || names.contains("filename") || names.contains("title") {
                return "an identifiable record with metadata"
            }
            return "an identifiable entity"
        }
        return nil
    }

    // MARK: - String Utilities

    private static let roleSuffixes = [
        "Manager", "Service", "Coordinator", "Handler",
        "Controller", "Provider", "Repository", "Store",
        "Interactor", "UseCase",
    ]

    private static let viewSuffixes = [
        "View", "HUD", "Overlay", "Panel", "Sheet", "Dock",
        "Screen", "Page", "Cell", "Row",
    ]

    /// Strip a known suffix from a name to extract the subject.
    /// "SessionManager" → "Session"
    private static func extractSubject(from name: String, stripping suffixes: [String]) -> String {
        for suffix in suffixes {
            if name.hasSuffix(suffix) && name.count > suffix.count {
                let stripped = String(name.dropLast(suffix.count))
                return readableSubject(stripped)
            }
        }
        return readableSubject(name)
    }

    /// Convert a PascalCase name to a readable lowercase phrase.
    /// "SessionContext" → "session context"
    /// "AI" → "AI" (preserve acronyms)
    private static func readableSubject(_ name: String) -> String {
        let parts = splitCamelCase(name)
        if parts.isEmpty { return name.lowercased() }
        return parts.map { part in
            // Preserve all-caps acronyms.
            if part == part.uppercased() && part.count <= 4 { return part }
            return part.lowercased()
        }.joined(separator: " ")
    }

    /// Convert an entity name to readable form.
    /// "SessionManager" → "session manager"
    private static func readableEntityName(_ name: String) -> String {
        readableSubject(name)
    }

    /// Map a verb to its noun/gerund form for natural sentence composition.
    /// "create" → "creation", "build" → "building", "parse" → "parsing"
    private static func verbToNoun(_ verb: String) -> String {
        let mapping: [String: String] = [
            "create": "creation",
            "build": "building",
            "parse": "parsing",
            "resolve": "resolution",
            "detect": "detection",
            "classify": "classification",
            "validate": "validation",
            "capture": "capture",
            "extract": "extraction",
            "generate": "generation",
            "compute": "computation",
            "start": "startup",
            "stop": "shutdown",
            "close": "closing",
            "open": "opening",
            "load": "loading",
            "save": "saving",
            "sync": "sync",
            "restore": "restoration",
            "activate": "activation",
            "register": "registration",
            "request": "requests",
            "stream": "streaming",
            "watch": "watching",
            "observe": "observation",
            "handle": "handling",
            "process": "processing",
            "render": "rendering",
            "format": "formatting",
            "configure": "configuration",
            "update": "updates",
            "remove": "removal",
            "delete": "deletion",
            "read": "reading",
            "write": "writing",
            "send": "sending",
            "fetch": "fetching",
            "pin": "pinning",
            "unpin": "unpinning",
            "reparse": "reparsing",
            "ask": "queries",
        ]
        return mapping[verb] ?? "\(verb)ing"
    }

    /// Split a camelCase or PascalCase string into words.
    /// "buildFileIntelligence" → ["build", "File", "Intelligence"]
    /// "HTMLParser" → ["HTML", "Parser"]
    private static func splitCamelCase(_ string: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(string)

        for i in 0..<chars.count {
            let char = chars[i]
            if char.isUppercase {
                // Check if this starts a new word.
                if !current.isEmpty {
                    let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                    let prevIsLower = chars[i - 1].isLowercase
                    if prevIsLower || nextIsLower {
                        words.append(current)
                        current = String(char)
                        continue
                    }
                }
                current.append(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    /// Format a list for natural English: "a, b, and c"
    private static func formatList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items.last!)"
        }
    }

    /// Role-specific opening verb.
    private static func roleVerb(for role: FileRole) -> String {
        switch role {
        case .manager: return "Manages"
        case .coordinator: return "Coordinates"
        case .service: return "Provides"
        default: return "Handles"
        }
    }
}
