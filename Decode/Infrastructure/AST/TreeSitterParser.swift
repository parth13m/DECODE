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
        parseAllFacts(source: source, fileName: fileName).entities
    }

    /// Parse a source file and extract all deterministic facts.
    ///
    /// Returns entities and import declarations. This is the tree-sitter
    /// counterpart of ``SwiftSyntaxParser.parseAllFacts(source:fileName:)``.
    func parseAllFacts(source: String, fileName: String) -> DetailedParseResult {
        guard let grammar = GrammarRegistration.from(fileName: fileName) else {
            return DetailedParseResult(entities: [], imports: [], relationships: [])
        }

        let parser = Parser()
        do {
            try parser.setLanguage(grammar.language)
        } catch {
            #if DEBUG
            print("[TreeSitterParser] Failed to set language for \(grammar.displayName): \(error)")
            #endif
            return DetailedParseResult(entities: [], imports: [], relationships: [])
        }

        guard let mutableTree = parser.parse(source) else {
            #if DEBUG
            print("[TreeSitterParser] Failed to parse \(fileName)")
            #endif
            return DetailedParseResult(entities: [], imports: [], relationships: [])
        }

        // Extract entities.
        var entities: [ParsedEntity] = []
        if let query = queryLoader.loadQuery(named: "entities", for: grammar) {
            let rawEntities = extractEntities(
                tree: mutableTree,
                query: query,
                source: source,
                fileName: fileName,
                grammar: grammar
            )
            entities = postProcess(entities: rawEntities, grammar: grammar)
        }

        // Extract imports.
        let imports = extractImports(
            tree: mutableTree,
            source: source,
            grammar: grammar
        )

        // Extract call relationships.
        var relationships = extractCalls(
            tree: mutableTree,
            source: source,
            grammar: grammar,
            entities: entities
        )

        // Extract conformance, inheritance, and ownership relationships.
        let typeRelationships = extractTypeRelationships(
            entities: entities,
            grammar: grammar
        )
        relationships.append(contentsOf: typeRelationships)

        return DetailedParseResult(entities: entities, imports: imports, relationships: relationships)
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

    // MARK: - Import Extraction

    /// Extract import declarations using a tree-sitter imports query.
    ///
    /// Uses `imports.scm` query files with `@import` captures. Languages
    /// without an imports query file return an empty array.
    ///
    /// Import extraction is text-based: the full import statement text is
    /// parsed to extract module name, symbols, and kind. This avoids
    /// language-specific AST node traversal while supporting diverse
    /// import syntaxes (Python's `from X import Y`, JS's
    /// `import { X } from 'Y'`, Java's `import java.util.List`, etc.).
    private func extractImports(
        tree: MutableTree,
        source: String,
        grammar: GrammarRegistration
    ) -> [ImportDeclaration] {
        guard let query = queryLoader.loadQuery(named: "imports", for: grammar) else {
            return []
        }
        guard let rootNode = tree.rootNode else { return [] }

        let cursor = query.execute(node: rootNode, in: tree)
        let utf16Data = source.data(using: .utf16LittleEndian) ?? Data()

        var imports: [ImportDeclaration] = []

        while let match = cursor.next() {
            for capture in match.captures {
                guard capture.name == "import" else { continue }
                guard let rawText = nodeString(for: capture.node, in: utf16Data) else { continue }

                let line = Int(capture.node.pointRange.lowerBound.row) + 1
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

                let decl = Self.parseImportText(trimmed, line: line, grammar: grammar)
                imports.append(decl)
            }
        }

        return imports
    }

    /// Parse the raw text of an import statement into an `ImportDeclaration`.
    ///
    /// Handles the common import syntaxes across supported languages:
    /// - Python: `import X`, `from X import Y, Z`, `from X import *`
    /// - JS/TS: `import X from 'Y'`, `import { X } from 'Y'`, `import 'Y'`
    /// - Java: `import java.util.List;`, `import static java.util.Collections.*;`
    /// - C#: `using System.Collections.Generic;`
    /// - C/C++: `#include <stdio.h>`, `#include "header.h"`
    static func parseImportText(
        _ text: String,
        line: Int,
        grammar: GrammarRegistration
    ) -> ImportDeclaration {
        switch grammar {
        case .python:
            return parsePythonImport(text, line: line)
        case .javascript, .typescript:
            return parseJSImport(text, line: line)
        case .java:
            return parseJavaImport(text, line: line)
        case .csharp:
            return parseCSharpImport(text, line: line)
        case .c, .cpp:
            return parseCInclude(text, line: line)
        case .css, .html:
            // CSS @import and HTML are handled as side-effect imports.
            return ImportDeclaration(
                moduleName: text, importedSymbols: [], kind: .sideEffect,
                line: line, rawText: text
            )
        }
    }

    // MARK: - Language-Specific Import Parsing

    private static func parsePythonImport(_ text: String, line: Int) -> ImportDeclaration {
        // `from X import Y, Z` or `from X import *`
        if text.hasPrefix("from ") {
            let withoutFrom = text.dropFirst(5)
            if let importIdx = withoutFrom.range(of: " import ") {
                let moduleName = String(withoutFrom[..<importIdx.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let symbolsPart = String(withoutFrom[importIdx.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if symbolsPart == "*" {
                    return ImportDeclaration(
                        moduleName: moduleName, importedSymbols: [],
                        kind: .wildcard, line: line, rawText: text
                    )
                }
                let symbols = symbolsPart
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { item in
                        // Handle `X as Y` — keep the original name.
                        if let asRange = item.range(of: " as ") {
                            return String(item[..<asRange.lowerBound])
                        }
                        return item
                    }
                return ImportDeclaration(
                    moduleName: moduleName, importedSymbols: symbols,
                    kind: .symbol, line: line, rawText: text
                )
            }
        }
        // `import X` or `import X as Y`
        var moduleName = String(text.dropFirst(7)) // "import "
            .trimmingCharacters(in: .whitespaces)
        if let asRange = moduleName.range(of: " as ") {
            moduleName = String(moduleName[..<asRange.lowerBound])
        }
        return ImportDeclaration(
            moduleName: moduleName, importedSymbols: [],
            kind: .module, line: line, rawText: text
        )
    }

    private static func parseJSImport(_ text: String, line: Int) -> ImportDeclaration {
        // Side-effect: `import 'module'` or `import "module"`
        // Named: `import { X, Y } from 'module'`
        // Default: `import X from 'module'`
        // Namespace: `import * as X from 'module'`

        // Extract the module specifier (the quoted string).
        let modulePattern = text.range(of: #"['"]([^'"]+)['"]"#, options: .regularExpression)
        let moduleName: String
        if let range = modulePattern {
            var extracted = String(text[range])
            extracted = extracted.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            moduleName = extracted
        } else {
            // Fallback: use the raw text.
            moduleName = text
        }

        // Side-effect import: `import 'styles.css'`
        if text.hasPrefix("import ") && !text.contains(" from ") && !text.contains("{") {
            // Check if it's just `import 'module'` (no binding)
            let afterImport = text.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if afterImport.hasPrefix("'") || afterImport.hasPrefix("\"") {
                return ImportDeclaration(
                    moduleName: moduleName, importedSymbols: [],
                    kind: .sideEffect, line: line, rawText: text
                )
            }
        }

        // Wildcard: `import * as X from 'module'`
        if text.contains("* as ") {
            return ImportDeclaration(
                moduleName: moduleName, importedSymbols: [],
                kind: .wildcard, line: line, rawText: text
            )
        }

        // Named imports: `import { X, Y } from 'module'`
        if let braceStart = text.firstIndex(of: "{"),
           let braceEnd = text.firstIndex(of: "}") {
            let symbolsStr = text[text.index(after: braceStart)..<braceEnd]
            let symbols = symbolsStr.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { item -> String in
                    // Handle `X as Y` — keep the original name.
                    if let asRange = item.range(of: " as ") {
                        return String(item[..<asRange.lowerBound])
                    }
                    return item
                }
            return ImportDeclaration(
                moduleName: moduleName, importedSymbols: symbols,
                kind: .symbol, line: line, rawText: text
            )
        }

        // Default import: `import X from 'module'`
        return ImportDeclaration(
            moduleName: moduleName, importedSymbols: [],
            kind: .module, line: line, rawText: text
        )
    }

    private static func parseJavaImport(_ text: String, line: Int) -> ImportDeclaration {
        // `import java.util.List;` or `import static java.util.Collections.*;`
        var clean = text.trimmingCharacters(in: .whitespaces)
        if clean.hasSuffix(";") { clean = String(clean.dropLast()) }

        // Remove `import` keyword and optional `static`.
        clean = clean.replacingOccurrences(of: "import static ", with: "")
            .replacingOccurrences(of: "import ", with: "")
            .trimmingCharacters(in: .whitespaces)

        if clean.hasSuffix(".*") {
            let moduleName = String(clean.dropLast(2))
            return ImportDeclaration(
                moduleName: moduleName, importedSymbols: [],
                kind: .wildcard, line: line, rawText: text
            )
        }

        // Last component is the symbol, everything before is the package.
        if let dotIdx = clean.lastIndex(of: ".") {
            let moduleName = String(clean[..<dotIdx])
            let symbol = String(clean[clean.index(after: dotIdx)...])
            return ImportDeclaration(
                moduleName: moduleName, importedSymbols: [symbol],
                kind: .symbol, line: line, rawText: text
            )
        }

        return ImportDeclaration(
            moduleName: clean, importedSymbols: [],
            kind: .module, line: line, rawText: text
        )
    }

    private static func parseCSharpImport(_ text: String, line: Int) -> ImportDeclaration {
        // `using System.Collections.Generic;`
        // `using static System.Math;`
        // `using Alias = System.Collections.Generic.List<int>;`
        var clean = text.trimmingCharacters(in: .whitespaces)
        if clean.hasSuffix(";") { clean = String(clean.dropLast()) }
        clean = clean.replacingOccurrences(of: "using static ", with: "")
            .replacingOccurrences(of: "using ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Alias import: `Alias = Namespace`
        if clean.contains(" = ") {
            let parts = clean.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let moduleName = parts[1].trimmingCharacters(in: .whitespaces)
                let alias = parts[0].trimmingCharacters(in: .whitespaces)
                return ImportDeclaration(
                    moduleName: moduleName, importedSymbols: [alias],
                    kind: .symbol, line: line, rawText: text
                )
            }
        }

        return ImportDeclaration(
            moduleName: clean, importedSymbols: [],
            kind: .module, line: line, rawText: text
        )
    }

    private static func parseCInclude(_ text: String, line: Int) -> ImportDeclaration {
        // `#include <stdio.h>` or `#include "header.h"`
        var clean = text.trimmingCharacters(in: .whitespaces)
        clean = clean.replacingOccurrences(of: "#include", with: "")
            .trimmingCharacters(in: .whitespaces)
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "<>\""))
        return ImportDeclaration(
            moduleName: clean, importedSymbols: [],
            kind: .module, line: line, rawText: text
        )
    }

    // MARK: - Call Extraction

    /// Extract call relationships using a tree-sitter calls query.
    ///
    /// Uses `calls.scm` query files with `@call` and optional `@callee`
    /// captures. Each call site is mapped to the innermost containing
    /// entity by line range containment.
    ///
    /// Languages without a calls query file (HTML, CSS) return an empty
    /// array — these languages have no function call syntax.
    private func extractCalls(
        tree: MutableTree,
        source: String,
        grammar: GrammarRegistration,
        entities: [ParsedEntity]
    ) -> [Relationship] {
        guard let query = queryLoader.loadQuery(named: "calls", for: grammar) else {
            return []
        }
        guard let rootNode = tree.rootNode else { return [] }

        // Only functions and methods can contain calls.
        let callableEntities = entities.filter {
            $0.entity.entityType == .function
            || $0.entity.entityType == .method
            || $0.entity.entityType == .hook
        }
        guard !callableEntities.isEmpty else { return [] }

        let cursor = query.execute(node: rootNode, in: tree)
        let utf16Data = source.data(using: .utf16LittleEndian) ?? Data()

        var relationships: [Relationship] = []

        while let match = cursor.next() {
            var calleeText: String?
            var callNode: Node?

            for capture in match.captures {
                switch capture.name {
                case "callee":
                    calleeText = nodeString(for: capture.node, in: utf16Data)
                case "call":
                    callNode = capture.node
                default:
                    break
                }
            }

            guard let node = callNode else { continue }
            let line = Int(node.pointRange.lowerBound.row) + 1

            // Extract the callee name from either the dedicated @callee
            // capture or by parsing the full call expression text.
            let calleeName: String
            if let text = calleeText {
                calleeName = Self.normalizeCalleeName(
                    text.trimmingCharacters(in: .whitespacesAndNewlines),
                    grammar: grammar
                )
            } else if let fullText = nodeString(for: node, in: utf16Data) {
                calleeName = Self.extractCalleeFromCallText(
                    fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                    grammar: grammar
                )
            } else {
                continue
            }

            guard !calleeName.isEmpty else { continue }

            // Find the smallest containing entity.
            var bestEntity: ParsedEntity?
            var bestSize = Int.max

            for entity in callableEntities {
                if entity.startLine <= line && line <= entity.endLine {
                    let size = entity.endLine - entity.startLine
                    if size < bestSize {
                        bestSize = size
                        bestEntity = entity
                    }
                }
            }

            if let owner = bestEntity {
                relationships.append(Relationship(
                    kind: .calls,
                    sourceEntity: owner.entity.stableId,
                    targetName: calleeName,
                    line: line
                ))
            }
        }

        return relationships
    }

    /// Normalize a callee name captured by the @callee query pattern.
    ///
    /// For most languages, the captured text is already the callee name.
    /// Python attribute access (`obj.method`) and JS member expressions
    /// (`obj.method`) are preserved as-is since they represent the full
    /// qualified call target.
    private static func normalizeCalleeName(
        _ text: String,
        grammar: GrammarRegistration
    ) -> String {
        // Strip trailing parentheses and arguments if captured.
        if let parenIdx = text.firstIndex(of: "(") {
            return String(text[..<parenIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Extract the callee name from the full text of a call expression.
    ///
    /// Used when no `@callee` capture is available (Java, C#). Parses
    /// the call text to find the function/method name before the argument
    /// list.
    private static func extractCalleeFromCallText(
        _ text: String,
        grammar: GrammarRegistration
    ) -> String {
        switch grammar {
        case .java:
            return parseJavaCallee(text)
        case .csharp:
            return parseCSharpCallee(text)
        default:
            // Fallback: text before first `(`.
            if let parenIdx = text.firstIndex(of: "(") {
                return String(text[..<parenIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text
        }
    }

    /// Extract the callee from a Java method invocation or constructor call.
    ///
    /// Handles:
    /// - `method(args)` → `"method"`
    /// - `obj.method(args)` → `"obj.method"`
    /// - `this.method(args)` → `"this.method"`
    /// - `new MyClass(args)` → `"MyClass"`
    private static func parseJavaCallee(_ text: String) -> String {
        // Constructor: `new MyClass(...)`
        if text.hasPrefix("new ") {
            let afterNew = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if let parenIdx = afterNew.firstIndex(of: "(") {
                // Handle generic types: `new ArrayList<String>()`
                let beforeParen = String(afterNew[..<parenIdx])
                if let angleBracket = beforeParen.firstIndex(of: "<") {
                    return String(beforeParen[..<angleBracket])
                }
                return beforeParen
            }
            return afterNew
        }
        // Method invocation: text before `(`
        if let parenIdx = text.firstIndex(of: "(") {
            return String(text[..<parenIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Extract the callee from a C# invocation or constructor call.
    ///
    /// Handles:
    /// - `Method(args)` → `"Method"`
    /// - `obj.Method(args)` → `"obj.Method"`
    /// - `new MyClass(args)` → `"MyClass"`
    private static func parseCSharpCallee(_ text: String) -> String {
        // Constructor: `new MyClass(...)`
        if text.hasPrefix("new ") {
            let afterNew = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if let parenIdx = afterNew.firstIndex(of: "(") {
                let beforeParen = String(afterNew[..<parenIdx])
                if let angleBracket = beforeParen.firstIndex(of: "<") {
                    return String(beforeParen[..<angleBracket])
                }
                return beforeParen
            }
            return afterNew
        }
        // Invocation: text before `(`
        if let parenIdx = text.firstIndex(of: "(") {
            return String(text[..<parenIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Type Relationship Extraction

    /// Extract conformance, inheritance, and ownership relationships from
    /// the parsed entity list.
    ///
    /// - **Conformance/Inheritance**: Parsed from entity signatures. Each
    ///   language has distinct syntax for declaring inherited types.
    /// - **Ownership (nested types)**: Derived from `parentStableId` set
    ///   by `resolveParentRelationships()`.
    ///
    /// ## Language Coverage
    /// - Python: `class Foo(Bar, Baz):` → inherits Bar, conformsTo Baz
    /// - Java: `class Foo extends Bar implements I1, I2`
    /// - C#: `class Foo : Bar, IFoo` (first = inherits, I-prefixed = conformsTo)
    /// - TypeScript: `class Foo extends Bar implements I1`
    /// - JavaScript: `class Foo extends Bar`
    /// - C++: `class Foo : public Bar, public Baz`
    /// - C: structs have no inheritance
    /// - HTML/CSS: not applicable
    private func extractTypeRelationships(
        entities: [ParsedEntity],
        grammar: GrammarRegistration
    ) -> [Relationship] {
        var relationships: [Relationship] = []

        for entity in entities {
            let type = entity.entity.entityType

            // Conformance and inheritance from type declarations.
            if type == .class || type == .struct || type == .protocol || type == .enum {
                let inherited = Self.parseInheritanceFromSignature(
                    entity.signature,
                    entityType: type,
                    grammar: grammar
                )
                for (kind, targetName) in inherited {
                    relationships.append(Relationship(
                        kind: kind,
                        sourceEntity: entity.entity.stableId,
                        targetName: targetName,
                        line: entity.startLine
                    ))
                }
            }

            // Nested-type ownership from parentStableId.
            if let parentId = entity.parentStableId {
                if type == .class || type == .struct || type == .enum || type == .protocol {
                    relationships.append(Relationship(
                        kind: .owns,
                        sourceEntity: parentId,
                        targetName: entity.entity.name,
                        line: entity.startLine
                    ))
                }
            }
        }

        return relationships
    }

    /// Parse inheritance and conformance from an entity's declaration signature.
    ///
    /// Returns an array of (RelationshipKind, targetName) pairs. The
    /// distinction between inheritance and conformance is language-specific:
    ///
    /// - **Python**: First base class is `.inherits`, rest are `.conformsTo`
    ///   (Python uses mixins, not interfaces, but the structural pattern is
    ///   the same: primary base + additional protocols).
    /// - **Java**: `extends` → `.inherits`, `implements` → `.conformsTo`.
    /// - **C#**: First base type → `.inherits` (unless I-prefixed → `.conformsTo`).
    /// - **TypeScript**: `extends` → `.inherits`, `implements` → `.conformsTo`.
    /// - **JavaScript**: `extends` → `.inherits` (no interfaces in JS).
    /// - **C++**: All base specifiers → `.inherits` (C++ has multiple inheritance).
    /// - **C**: No inheritance mechanism for structs.
    static func parseInheritanceFromSignature(
        _ signature: String,
        entityType: EntityType,
        grammar: GrammarRegistration
    ) -> [(RelationshipKind, String)] {
        switch grammar {
        case .python:
            return parsePythonInheritance(signature)
        case .java:
            return parseJavaInheritance(signature)
        case .csharp:
            return parseCSharpInheritance(signature)
        case .javascript:
            return parseJSInheritance(signature)
        case .typescript:
            return parseTSInheritance(signature)
        case .cpp:
            return parseCppInheritance(signature)
        case .c, .html, .css:
            return []
        }
    }

    // MARK: - Language-Specific Inheritance Parsing

    /// Python: `class Foo(Bar, Baz, metaclass=ABCMeta):`
    ///
    /// First parent is treated as `.inherits`, additional parents as
    /// `.conformsTo` (mixin pattern). Keyword arguments like
    /// `metaclass=...` are filtered out.
    private static func parsePythonInheritance(
        _ signature: String
    ) -> [(RelationshipKind, String)] {
        // Extract content between parentheses.
        guard let parenStart = signature.firstIndex(of: "("),
              let parenEnd = signature.lastIndex(of: ")")
        else { return [] }

        let inner = signature[signature.index(after: parenStart)..<parenEnd]
        let parts = inner.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.contains("=") } // Remove keyword args like metaclass=
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return [] }

        var result: [(RelationshipKind, String)] = []
        for (i, part) in parts.enumerated() {
            let kind: RelationshipKind = i == 0 ? .inherits : .conformsTo
            result.append((kind, part))
        }
        return result
    }

    /// Java: `class Foo extends Bar implements I1, I2`
    private static func parseJavaInheritance(
        _ signature: String
    ) -> [(RelationshipKind, String)] {
        var result: [(RelationshipKind, String)] = []

        // Extract `extends X`
        if let extendsRange = signature.range(of: " extends ") {
            let afterExtends = signature[extendsRange.upperBound...]
            // Stop at `implements` or end of signature.
            let endMarker = afterExtends.range(of: " implements ")?.lowerBound
                ?? afterExtends.endIndex
            let superclass = afterExtends[..<endMarker]
                .trimmingCharacters(in: .whitespaces)
            // Handle generics: `extends Bar<T>` → "Bar"
            let cleaned = stripGenerics(superclass)
            if !cleaned.isEmpty {
                result.append((.inherits, cleaned))
            }
        }

        // Extract `implements I1, I2`
        if let implRange = signature.range(of: " implements ") {
            let afterImpl = String(signature[implRange.upperBound...])
            let interfaces = afterImpl.split(separator: ",")
                .map { stripGenerics($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            for iface in interfaces {
                result.append((.conformsTo, iface))
            }
        }

        return result
    }

    /// C#: `class Foo : Bar, IFoo, IBaz`
    ///
    /// C# convention: interfaces are prefixed with `I`. The first
    /// non-I-prefixed type is treated as `.inherits`.
    private static func parseCSharpInheritance(
        _ signature: String
    ) -> [(RelationshipKind, String)] {
        guard let colonIdx = signature.firstIndex(of: ":") else { return [] }

        // Don't confuse a namespace-qualified name with an inheritance colon.
        // Inheritance colon in C# comes after the class name, before the base list.
        let afterColon = signature[signature.index(after: colonIdx)...]
        // Stop at `where` (generic constraints).
        let endMarker = afterColon.range(of: " where ")?.lowerBound
            ?? afterColon.endIndex
        let baseList = afterColon[..<endMarker]

        let types = baseList.split(separator: ",")
            .map { stripGenerics($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }

        var result: [(RelationshipKind, String)] = []
        var foundSuperclass = false

        for typeName in types {
            // C# convention: interfaces start with 'I' followed by uppercase.
            let isInterface = typeName.count >= 2
                && typeName.hasPrefix("I")
                && typeName[typeName.index(after: typeName.startIndex)].isUppercase
            if isInterface {
                result.append((.conformsTo, typeName))
            } else if !foundSuperclass {
                result.append((.inherits, typeName))
                foundSuperclass = true
            } else {
                // Multiple non-I-prefixed types — shouldn't happen in valid C#,
                // but record as conformance to avoid data loss.
                result.append((.conformsTo, typeName))
            }
        }

        return result
    }

    /// JavaScript: `class Foo extends Bar`
    private static func parseJSInheritance(
        _ signature: String
    ) -> [(RelationshipKind, String)] {
        guard let extendsRange = signature.range(of: " extends ") else { return [] }
        let afterExtends = signature[extendsRange.upperBound...]
        // Stop at `{` or end.
        let endIdx = afterExtends.firstIndex(of: "{") ?? afterExtends.endIndex
        let superclass = afterExtends[..<endIdx]
            .trimmingCharacters(in: .whitespaces)
        guard !superclass.isEmpty else { return [] }
        return [(.inherits, superclass)]
    }

    /// TypeScript: `class Foo extends Bar implements I1, I2`
    private static func parseTSInheritance(
        _ signature: String
    ) -> [(RelationshipKind, String)] {
        var result: [(RelationshipKind, String)] = []

        if let extendsRange = signature.range(of: " extends ") {
            let afterExtends = signature[extendsRange.upperBound...]
            let endMarker = afterExtends.range(of: " implements ")?.lowerBound
                ?? afterExtends.firstIndex(of: "{")
                ?? afterExtends.endIndex
            let superclass = stripGenerics(
                String(afterExtends[..<endMarker]).trimmingCharacters(in: .whitespaces)
            )
            if !superclass.isEmpty {
                result.append((.inherits, superclass))
            }
        }

        if let implRange = signature.range(of: " implements ") {
            let afterImpl = String(signature[implRange.upperBound...])
            let endIdx = afterImpl.firstIndex(of: "{") ?? afterImpl.endIndex
            let interfaces = afterImpl[..<endIdx]
                .split(separator: ",")
                .map { stripGenerics($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            for iface in interfaces {
                result.append((.conformsTo, iface))
            }
        }

        return result
    }

    /// C++: `class Foo : public Bar, private Baz`
    ///
    /// C++ supports multiple inheritance. All base specifiers are recorded
    /// as `.inherits`. Access specifiers (`public`, `protected`, `private`)
    /// are stripped.
    private static func parseCppInheritance(
        _ signature: String
    ) -> [(RelationshipKind, String)] {
        guard let colonIdx = signature.firstIndex(of: ":") else { return [] }

        let afterColon = String(signature[signature.index(after: colonIdx)...])
        let bases = afterColon.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { base -> String in
                // Strip access specifier.
                var cleaned = base
                for spec in ["public ", "protected ", "private ", "virtual "] {
                    if cleaned.hasPrefix(spec) {
                        cleaned = String(cleaned.dropFirst(spec.count))
                    }
                }
                return stripGenerics(cleaned.trimmingCharacters(in: .whitespaces))
            }
            .filter { !$0.isEmpty }

        return bases.map { (.inherits, $0) }
    }

    /// Strip generic type parameters from a type name.
    /// `ArrayList<String>` → `ArrayList`, `Map<K, V>` → `Map`
    private static func stripGenerics(_ name: String) -> String {
        if let angleBracket = name.firstIndex(of: "<") {
            return String(name[..<angleBracket])
                .trimmingCharacters(in: .whitespaces)
        }
        return name
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
