import CryptoKit
import Foundation
import SwiftTreeSitter

/// Tree-sitter implementation of ``ASTParserProtocol`` for non-Swift languages.
///
/// Uses the tree-sitter incremental parsing library with per-language grammars
/// compiled from C source. The parser resolves the correct grammar from the
/// file name, parses the source into a concrete syntax tree, and extracts
/// structural entities using language-specific query patterns.
///
/// ## Supported Languages
/// See ``GrammarRegistration`` for the full list of supported grammars and
/// their file extension mappings.
///
/// ## Thread Safety
/// All state is local to each `parse` call. The ``SwiftTreeSitter.Parser``
/// instance is created per-call to avoid shared mutable state.
struct TreeSitterParser: ASTParserProtocol, Sendable {

    private let queryLoader = QueryLoader()

    // MARK: - ASTParserProtocol

    func parse(source: String, fileName: String) async throws -> ASTParseResult {
        let detailed = parseDetailed(source: source, fileName: fileName)
        return ASTParseResult(
            entities: detailed.map(\.entity),
            dependencies: []
        )
    }

    // MARK: - Detailed Parse

    /// Parse a source file using tree-sitter and extract enriched entities.
    ///
    /// Returns `ParsedEntity` objects compatible with those produced by
    /// ``SwiftSyntaxParser``. If no grammar or query is available for the
    /// file's language, returns an empty array.
    func parseDetailed(source: String, fileName: String) -> [ParsedEntity] {
        guard let grammar = GrammarRegistration.from(fileName: fileName) else {
            return []
        }

        let parser = Parser()
        do {
            try parser.setLanguage(grammar.language)
        } catch {
            #if DEBUG
            print("[TreeSitterParser] Failed to set language for \(grammar.displayName): \(error)")
            #endif
            return []
        }

        guard let mutableTree = parser.parse(source) else {
            #if DEBUG
            print("[TreeSitterParser] Failed to parse \(fileName)")
            #endif
            return []
        }

        guard let query = queryLoader.loadQuery(named: "entities", for: grammar) else {
            return []
        }

        let rawEntities = extractEntities(
            tree: mutableTree,
            query: query,
            source: source,
            fileName: fileName,
            grammar: grammar
        )

        return postProcess(entities: rawEntities, grammar: grammar)
    }

    // MARK: - Entity Extraction

    /// Execute a tree-sitter query and map matches to ``ParsedEntity`` values.
    ///
    /// Each query match is expected to capture:
    /// - `@name` — the entity's symbolic name
    /// - `@definition` — the full entity node (used for source text, line range)
    private func extractEntities(
        tree: MutableTree,
        query: Query,
        source: String,
        fileName: String,
        grammar: GrammarRegistration
    ) -> [ParsedEntity] {
        guard let rootNode = tree.rootNode else { return [] }

        let cursor = query.execute(node: rootNode, in: tree)

        var entities: [ParsedEntity] = []
        // Parser uses UTF-16LE encoding, so byte ranges are into UTF-16 data.
        let utf16Data = source.data(using: .utf16LittleEndian) ?? Data()
        let placeholderSessionId = UUID()

        while let match = cursor.next() {
            var nameText: String?
            var definitionNode: Node?

            for capture in match.captures {
                let captureName = capture.name
                switch captureName {
                case "name":
                    nameText = nodeString(for: capture.node, in: utf16Data)
                case "definition":
                    definitionNode = capture.node
                default:
                    break
                }
            }

            // For CSS patterns like @media that have no explicit @name capture,
            // use the first line of the definition as the name.
            let defNode: Node
            if let d = definitionNode {
                defNode = d
            } else {
                continue
            }

            let name: String
            if let n = nameText {
                name = n.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Fallback: derive name from the definition node's first line.
                let text = nodeString(for: defNode, in: utf16Data) ?? ""
                name = firstLine(of: text)
            }

            guard !name.isEmpty else { continue }

            let pointRange = defNode.pointRange
            let startLine = Int(pointRange.lowerBound.row) + 1
            let endLine = Int(pointRange.upperBound.row) + 1

            let sourceText = nodeString(for: defNode, in: utf16Data) ?? ""
            let signature = extractSignature(from: sourceText, grammar: grammar)
            let bodyHash = sha256(sourceText)

            let entityType = inferEntityType(
                nodeName: name,
                nodeType: defNode.nodeType,
                grammar: grammar
            )

            let entity = CodeEntity(
                id: UUID(),
                sessionId: placeholderSessionId,
                stableId: bodyHash,
                entityType: entityType,
                name: name,
                summaryText: "",
                hash: bodyHash,
                lastUpdated: Date()
            )

            let parsed = ParsedEntity(
                entity: entity,
                signature: signature,
                startLine: startLine,
                endLine: endLine,
                sourceText: sourceText,
                fileName: fileName,
                parentStableId: nil
            )

            entities.append(parsed)
        }

        return entities
    }

    // MARK: - Post-Processing

    /// Deduplicate and apply language-specific filters to extracted entities.
    private func postProcess(
        entities: [ParsedEntity],
        grammar: GrammarRegistration
    ) -> [ParsedEntity] {
        var result = entities

        // Deduplicate by line range — when multiple patterns match the same
        // node (e.g., export wrapping a function), keep the outermost match
        // which has the most context.
        result = deduplicateByRange(result)

        // HTML: filter to semantic elements only.
        if grammar == .html {
            result = filterHTMLToSemanticElements(result)
        }

        // Resolve parent-child relationships.
        result = resolveParentRelationships(result)

        return result
    }

    /// Remove duplicate entities that cover the same line range.
    /// Keeps the outermost (largest) entity when ranges overlap.
    private func deduplicateByRange(_ entities: [ParsedEntity]) -> [ParsedEntity] {
        var seen: [String: ParsedEntity] = [:]  // key: "startLine-endLine"

        for entity in entities {
            let key = "\(entity.startLine)-\(entity.endLine)"
            if let existing = seen[key] {
                // Keep the one with more source text (outermost).
                if entity.sourceText.count > existing.sourceText.count {
                    seen[key] = entity
                }
            } else {
                seen[key] = entity
            }
        }

        // Preserve original order.
        var result: [ParsedEntity] = []
        var usedKeys: Set<String> = []
        for entity in entities {
            let key = "\(entity.startLine)-\(entity.endLine)"
            if !usedKeys.contains(key), let best = seen[key] {
                result.append(best)
                usedKeys.insert(key)
            }
        }

        return result
    }

    /// HTML: keep only elements that represent meaningful structural sections.
    private static let semanticHTMLTags: Set<String> = [
        "html", "head", "body", "main", "nav", "header", "footer", "aside",
        "section", "article", "form", "table", "dialog", "details",
        "template", "script", "style", "div", "ul", "ol",
    ]

    private func filterHTMLToSemanticElements(
        _ entities: [ParsedEntity]
    ) -> [ParsedEntity] {
        entities.filter { entity in
            Self.semanticHTMLTags.contains(entity.entity.name.lowercased())
        }
    }

    /// Assign parent-child relationships based on line range containment.
    ///
    /// An entity is a child of another if its line range is fully contained
    /// within the other's range. The parent is the smallest containing entity.
    private func resolveParentRelationships(
        _ entities: [ParsedEntity]
    ) -> [ParsedEntity] {
        guard entities.count > 1 else { return entities }

        // Sort by line range size (largest first) for containment checks.
        let sorted = entities.sorted {
            ($0.endLine - $0.startLine) > ($1.endLine - $1.startLine)
        }

        // For each entity, find the smallest entity that fully contains it.
        var parentMap: [UUID: String] = [:]  // entity.id → parent.stableId

        for i in 0..<sorted.count {
            let child = sorted[i]
            var bestParent: ParsedEntity?
            var bestSize = Int.max

            for j in 0..<sorted.count {
                if i == j { continue }
                let candidate = sorted[j]

                // Check containment: candidate fully contains child.
                if candidate.startLine <= child.startLine
                    && candidate.endLine >= child.endLine
                    && (candidate.endLine - candidate.startLine) > (child.endLine - child.startLine)
                {
                    let size = candidate.endLine - candidate.startLine
                    if size < bestSize {
                        bestSize = size
                        bestParent = candidate
                    }
                }
            }

            if let parent = bestParent {
                parentMap[child.id] = parent.entity.stableId
            }
        }

        // Rebuild entities with parent relationships and adjusted entity types.
        return entities.map { entity in
            let parentStableId = parentMap[entity.id]
            var entityType = entity.entity.entityType

            // If this entity is a function inside a class/struct, it's a method.
            if parentStableId != nil && entityType == .function {
                if let parent = entities.first(where: { $0.entity.stableId == parentStableId }) {
                    let parentType = parent.entity.entityType
                    if parentType == .class || parentType == .struct || parentType == .protocol {
                        entityType = .method
                    }
                }
            }

            let updatedEntity = CodeEntity(
                id: entity.entity.id,
                sessionId: entity.entity.sessionId,
                stableId: entity.entity.stableId,
                entityType: entityType,
                name: entity.entity.name,
                summaryText: entity.entity.summaryText,
                hash: entity.entity.hash,
                lastUpdated: entity.entity.lastUpdated
            )

            return ParsedEntity(
                entity: updatedEntity,
                signature: entity.signature,
                startLine: entity.startLine,
                endLine: entity.endLine,
                sourceText: entity.sourceText,
                fileName: entity.fileName,
                parentStableId: parentStableId
            )
        }
    }

    // MARK: - Entity Type Inference

    /// Infer the ``EntityType`` from the tree-sitter node type and grammar.
    private func inferEntityType(
        nodeName: String,
        nodeType: String?,
        grammar: GrammarRegistration
    ) -> EntityType {
        let nt = nodeType ?? ""

        // Language-specific inference.
        switch grammar {
        case .python:
            if nt.contains("class") { return .class }
            return .function

        case .javascript, .typescript:
            if nt.contains("class") { return .class }
            if nt == "interface_declaration" { return .protocol }
            if nt == "enum_declaration" { return .enum }
            if nt == "type_alias_declaration" { return .struct }
            if nt == "method_definition" || nt == "method_signature"
                || nt == "abstract_method_signature"
            {
                return .method
            }
            // React component heuristic: PascalCase arrow function/function.
            if isReactComponentName(nodeName) { return .component }
            // Hook heuristic: starts with "use".
            if nodeName.hasPrefix("use") && nodeName.count > 3 {
                let fourthChar = nodeName[nodeName.index(nodeName.startIndex, offsetBy: 3)]
                if fourthChar.isUppercase { return .hook }
            }
            return .function

        case .java:
            if nt == "class_declaration" { return .class }
            if nt == "interface_declaration" { return .protocol }
            if nt == "enum_declaration" { return .enum }
            if nt == "method_declaration" || nt == "constructor_declaration" {
                return .method
            }
            return .function

        case .csharp:
            if nt == "class_declaration" || nt == "record_declaration" { return .class }
            if nt == "interface_declaration" { return .protocol }
            if nt == "struct_declaration" { return .struct }
            if nt == "enum_declaration" { return .enum }
            if nt == "method_declaration" || nt == "constructor_declaration" {
                return .method
            }
            return .function

        case .c:
            if nt == "struct_specifier" { return .struct }
            if nt == "enum_specifier" { return .enum }
            return .function

        case .cpp:
            if nt == "class_specifier" { return .class }
            if nt == "struct_specifier" { return .struct }
            if nt == "enum_specifier" { return .enum }
            if nt == "namespace_definition" { return .class }
            return .function

        case .html:
            return .component

        case .css:
            if nt == "media_statement" { return .class }
            if nt == "keyframes_statement" { return .function }
            return .function
        }
    }

    /// Check if a name follows PascalCase (React component convention).
    private func isReactComponentName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isUppercase && name.count > 1
    }

    // MARK: - Helpers

    /// Extract a node's text from the source using byte offsets.
    private func nodeString(for node: Node, in utf16Data: Data) -> String? {
        let startByte = Int(node.byteRange.lowerBound)
        let endByte = Int(node.byteRange.upperBound)
        guard startByte < endByte, endByte <= utf16Data.count else { return nil }
        return String(data: utf16Data[startByte..<endByte], encoding: .utf16LittleEndian)
    }

    /// Extract the declaration signature.
    private func extractSignature(from sourceText: String, grammar: GrammarRegistration) -> String {
        switch grammar {
        case .python:
            // Python: take up to the colon (def foo(x):)
            if let colonIndex = sourceText.firstIndex(of: ":") {
                let sig = sourceText[..<colonIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Only use colon-based extraction for def/class lines.
                if sig.hasPrefix("def ") || sig.hasPrefix("class ")
                    || sig.hasPrefix("async def ") || sig.hasPrefix("@")
                {
                    return sig
                }
            }
            // Fallback: first line.
            return firstLine(of: sourceText)

        case .css:
            // CSS: the selector or @-rule name is the signature.
            return firstLine(of: sourceText)

        case .html:
            // HTML: the opening tag is the signature.
            return firstLine(of: sourceText)

        default:
            // Brace-delimited languages: take text before first `{`.
            if let braceIndex = sourceText.firstIndex(of: "{") {
                return sourceText[..<braceIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return firstLine(of: sourceText)
        }
    }

    /// Return the first line of a string, trimmed.
    private func firstLine(of text: String) -> String {
        if let idx = text.firstIndex(of: "\n") {
            return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
