import CryptoKit
import Foundation
import SwiftParser
import SwiftSyntax

/// Concrete SwiftSyntax implementation of ASTParserProtocol.
///
/// Parses Swift source files using SwiftSyntax to extract code entities
/// (functions, classes, structs, methods, protocols, enums) and their
/// dependency relationships.
///
/// Uses `SyntaxVisitor` to walk the AST and collect top-level and nested
/// declarations. Entity identity is based on a SHA-256 hash of the entity's
/// source text body.
///
/// Thread-safe: all state is local to each `parse` call.
struct SwiftSyntaxParser: ASTParserProtocol, Sendable {

    /// Parse a Swift source file and extract code entities.
    ///
    /// Conforms to `ASTParserProtocol`. Returns `CodeEntity` objects only.
    func parse(source: String, fileName: String) async throws -> ASTParseResult {
        let detailed = parseDetailed(source: source, fileName: fileName)
        return ASTParseResult(
            entities: detailed.map(\.entity),
            dependencies: []
        )
    }

    /// Parse a Swift source file and extract enriched entities with metadata.
    ///
    /// Returns `ParsedEntity` objects that include signature, line range, and
    /// source text in addition to the base `CodeEntity` fields. Used by
    /// `SessionViewModel` for the entity inspection UI.
    func parseDetailed(source: String, fileName: String) -> [ParsedEntity] {
        parseAllFacts(source: source, fileName: fileName).entities
    }

    /// Parse a Swift source file and extract all deterministic facts.
    ///
    /// Returns entities, import declarations, and relationships. This is
    /// the primary entry point for the Deterministic Facts Engine — every
    /// objective fact derivable from the Swift AST is extracted in a
    /// single walk plus a targeted call-extraction pass.
    func parseAllFacts(source: String, fileName: String) -> DetailedParseResult {
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        let collector = EntityCollector(
            source: source,
            fileName: fileName,
            locationConverter: converter
        )
        collector.walk(sourceFile)

        // Extract call relationships from function/method bodies.
        var relationships = CallExtractor.extractCalls(
            from: collector.parsedEntities,
            tree: sourceFile,
            locationConverter: converter
        )

        // Add structural relationships (conformance, inheritance, properties).
        relationships.append(contentsOf: collector.structuralRelationships)

        // Derive nested-type ownership from parent-child entity relationships.
        for entity in collector.parsedEntities {
            guard let parentId = entity.parentStableId else { continue }
            // Only record ownership for nested types, not methods.
            let entityType = entity.entity.entityType
            guard entityType == .class || entityType == .struct
                || entityType == .enum || entityType == .protocol
            else { continue }
            relationships.append(Relationship(
                kind: .owns,
                sourceEntity: parentId,
                targetName: entity.entity.name,
                line: entity.startLine
            ))
        }

        return DetailedParseResult(
            entities: collector.parsedEntities,
            imports: collector.importDeclarations,
            relationships: relationships
        )
    }
}

// MARK: - Entity Collector

/// SyntaxVisitor that walks a parsed Swift AST and extracts code entities.
///
/// Collects top-level declarations (functions, classes, structs, enums, protocols)
/// and methods nested inside type declarations. Each entity receives a stable
/// identity based on the SHA-256 hash of its source text.
private final class EntityCollector: SyntaxVisitor {

    /// The accumulated enriched entities discovered during the walk.
    private(set) var parsedEntities: [ParsedEntity] = []

    /// The accumulated import declarations discovered during the walk.
    private(set) var importDeclarations: [ImportDeclaration] = []

    /// Structural relationships discovered during the walk (conformance,
    /// inheritance, ownership). Call relationships are extracted separately
    /// by ``CallExtractor``.
    private(set) var structuralRelationships: [Relationship] = []

    /// The raw source text, used for extracting entity body text.
    private let source: String

    /// The file name.
    private let fileName: String

    /// Converts absolute source positions to line/column numbers.
    private let locationConverter: SourceLocationConverter

    /// Tracks the parent type name when visiting methods inside a class/struct/enum.
    private var currentTypeName: String?

    /// Tracks the parent type's stableId (body hash) for structural relationships.
    private var currentParentStableId: String?

    /// A placeholder session ID for in-memory use (no database yet).
    private let placeholderSessionId = UUID()

    init(source: String, fileName: String, locationConverter: SourceLocationConverter) {
        self.source = source
        self.fileName = fileName
        self.locationConverter = locationConverter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Imports

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let rawText = node.trimmedDescription
        let startLoc = locationConverter.location(for: node.positionAfterSkippingLeadingTrivia)

        // The import path is the sequence of access path components.
        // e.g., `import Foundation` → ["Foundation"]
        //        `import struct Foundation.URL` → ["Foundation", "URL"]
        let pathComponents = node.path.map(\.name.text)
        let moduleName = pathComponents.first ?? rawText

        // Swift `import` is always a whole-module import unless a kind is specified
        // (e.g., `import struct Foundation.URL`). The kind token, if present,
        // indicates a symbol-level import.
        let hasKind = node.importKindSpecifier != nil
        let kind: ImportKind = hasKind ? .symbol : .module
        let importedSymbols: [String] = hasKind && pathComponents.count > 1
            ? [pathComponents.dropFirst().joined(separator: ".")]
            : []

        let decl = ImportDeclaration(
            moduleName: moduleName,
            importedSymbols: importedSymbols,
            kind: kind,
            line: startLoc.line,
            rawText: rawText
        )
        importDeclarations.append(decl)

        return .skipChildren
    }

    // MARK: - Top-Level Declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let bodyText = node.trimmedDescription
        let entityType: EntityType = currentTypeName != nil ? .method : .function

        // Signature: everything before the body block.
        let signature = extractSignature(from: bodyText)

        addEntity(
            name: name,
            type: entityType,
            bodyText: bodyText,
            signature: signature,
            node: Syntax(node)
        )
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let bodyText = node.trimmedDescription
        let signature = extractSignature(from: bodyText)
        let parentHash = sha256(bodyText)

        addEntity(name: name, type: .class, bodyText: bodyText, signature: signature, node: Syntax(node))
        extractInheritance(from: node.inheritanceClause, ownerStableId: parentHash, node: node)

        let members = node.memberBlock.members
        extractProperties(from: members, ownerStableId: parentHash)

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        for member in members {
            walk(member)
        }
        currentTypeName = previousType
        currentParentStableId = previousParent
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let bodyText = node.trimmedDescription
        let signature = extractSignature(from: bodyText)
        let parentHash = sha256(bodyText)

        addEntity(name: name, type: .struct, bodyText: bodyText, signature: signature, node: Syntax(node))
        extractInheritance(from: node.inheritanceClause, ownerStableId: parentHash, node: node)

        let members = node.memberBlock.members
        extractProperties(from: members, ownerStableId: parentHash)

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        for member in members {
            walk(member)
        }
        currentTypeName = previousType
        currentParentStableId = previousParent
        return .skipChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let bodyText = node.trimmedDescription
        let signature = extractSignature(from: bodyText)
        let parentHash = sha256(bodyText)

        addEntity(name: name, type: .enum, bodyText: bodyText, signature: signature, node: Syntax(node))
        extractInheritance(from: node.inheritanceClause, ownerStableId: parentHash, node: node)

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        for member in node.memberBlock.members {
            walk(member)
        }
        currentTypeName = previousType
        currentParentStableId = previousParent
        return .skipChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let bodyText = node.trimmedDescription
        let signature = extractSignature(from: bodyText)
        let parentHash = sha256(bodyText)

        addEntity(name: name, type: .protocol, bodyText: bodyText, signature: signature, node: Syntax(node))
        // Protocol inheritance: `protocol Foo: Bar, Baz`
        extractInheritance(from: node.inheritanceClause, ownerStableId: parentHash, node: node)

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        for member in node.memberBlock.members {
            walk(member)
        }
        currentTypeName = previousType
        currentParentStableId = previousParent
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extendedTypeName = node.extendedType.trimmedDescription

        // Look up the extended type among already-collected entities.
        // If the type was declared earlier in the same file, attach
        // extension members as children of that type.
        let existingParent = parsedEntities.first {
            $0.entity.name == extendedTypeName && $0.isTopLevel
        }

        // Extension conformances: `extension Foo: Codable { }`
        // Attach to the extended type if found in this file.
        if let parent = existingParent {
            extractInheritance(
                from: node.inheritanceClause,
                ownerStableId: parent.entity.stableId,
                node: node
            )
        }

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = extendedTypeName
        currentParentStableId = existingParent?.entity.stableId
        for member in node.memberBlock.members {
            walk(member)
        }
        currentTypeName = previousType
        currentParentStableId = previousParent
        return .skipChildren
    }

    // MARK: - Helpers

    private func addEntity(
        name: String,
        type: EntityType,
        bodyText: String,
        signature: String,
        node: Syntax
    ) {
        let hash = sha256(bodyText)
        let displayName: String
        if let parent = currentTypeName, type == .method {
            displayName = "\(parent).\(name)"
        } else {
            displayName = name
        }

        let startLoc = locationConverter.location(for: node.positionAfterSkippingLeadingTrivia)
        let endLoc = locationConverter.location(for: node.endPositionBeforeTrailingTrivia)

        let entity = CodeEntity(
            id: UUID(),
            sessionId: placeholderSessionId,
            stableId: hash,
            entityType: type,
            name: displayName,
            summaryText: "",
            hash: hash,
            lastUpdated: Date()
        )

        let parsed = ParsedEntity(
            entity: entity,
            signature: signature,
            startLine: startLoc.line,
            endLine: endLoc.line,
            sourceText: bodyText,
            fileName: fileName,
            parentStableId: currentParentStableId
        )
        parsedEntities.append(parsed)
    }

    // MARK: - Relationship Extraction

    /// Extract conformance and inheritance relationships from an
    /// inheritance clause (`: Protocol1, Protocol2`).
    ///
    /// For `class` declarations, the first inherited type *might* be a
    /// superclass, but distinguishing superclass from protocol requires
    /// type resolution (not available from syntax alone). All items are
    /// recorded as `.conformsTo` — this is correct for structs, enums,
    /// and protocol inheritance, and conservative for classes.
    private func extractInheritance(
        from clause: InheritanceClauseSyntax?,
        ownerStableId: String,
        node: some SyntaxProtocol
    ) {
        guard let clause else { return }
        for inherited in clause.inheritedTypes {
            let typeName = inherited.type.trimmedDescription
            guard !typeName.isEmpty else { continue }
            let line = locationConverter.location(
                for: inherited.positionAfterSkippingLeadingTrivia
            ).line
            structuralRelationships.append(Relationship(
                kind: .conformsTo,
                sourceEntity: ownerStableId,
                targetName: typeName,
                line: line
            ))
        }
    }

    /// Extract stored property ownership relationships from a member block.
    ///
    /// Records `.owns` for each stored property (`let` or `var` without
    /// a getter-only computed body). Properties with only a `get` accessor
    /// are computed and not recorded as ownership.
    private func extractProperties(
        from members: MemberBlockItemListSyntax,
        ownerStableId: String
    ) {
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }

            for binding in varDecl.bindings {
                // Skip computed properties (those with only a getter).
                if let accessors = binding.accessorBlock {
                    // If the accessor block contains explicit get/set accessors,
                    // check for a setter. get-only = computed, skip.
                    if case .accessors(let accessorList) = accessors.accessors {
                        let hasSetter = accessorList.contains {
                            $0.accessorSpecifier.tokenKind == .keyword(.set)
                            || $0.accessorSpecifier.tokenKind == .keyword(.didSet)
                            || $0.accessorSpecifier.tokenKind == .keyword(.willSet)
                        }
                        if !hasSetter { continue }
                    }
                    // A code block accessor (= { ... }) is a computed property.
                    if case .getter = accessors.accessors { continue }
                }

                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                let propertyName = pattern.identifier.text
                let line = locationConverter.location(
                    for: binding.positionAfterSkippingLeadingTrivia
                ).line
                structuralRelationships.append(Relationship(
                    kind: .owns,
                    sourceEntity: ownerStableId,
                    targetName: propertyName,
                    line: line
                ))
            }
        }
    }

    // MARK: - Signature / Hash Helpers

    /// Extract the declaration signature by taking text before the first `{`.
    private func extractSignature(from bodyText: String) -> String {
        if let braceIndex = bodyText.firstIndex(of: "{") {
            return bodyText[..<braceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Call Extractor

/// Walks a Swift AST to extract function call sites and maps them to
/// their containing entities by line range containment.
///
/// This runs as a second pass after entity collection. It walks the
/// full tree once, collects all `FunctionCallExprSyntax` nodes with
/// their line positions, then assigns each call to the innermost
/// (smallest) containing entity.
private final class CallExtractor: SyntaxVisitor {

    /// A raw call site discovered during the walk.
    private struct CallSite {
        let calleeName: String
        let line: Int
    }

    private let locationConverter: SourceLocationConverter
    private var callSites: [CallSite] = []

    init(locationConverter: SourceLocationConverter) {
        self.locationConverter = locationConverter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = extractCalleeName(from: node.calledExpression) {
            let loc = locationConverter.location(for: node.positionAfterSkippingLeadingTrivia)
            callSites.append(CallSite(calleeName: name, line: loc.line))
        }
        // Continue walking — calls can be nested (e.g., foo(bar())).
        return .visitChildren
    }

    /// Extract the function/method name from a call expression's callee.
    ///
    /// Handles:
    /// - Direct calls: `foo()` → `"foo"`
    /// - Member calls: `self.foo()` → `"self.foo"`, `obj.bar()` → `"obj.bar"`
    /// - Chained access: `a.b.c()` → `"a.b.c"`
    /// - Initializers: `MyType()` → `"MyType"`
    ///
    /// Returns `nil` for complex expressions that don't have a clear
    /// symbolic name (closures, subscripts, tuple access, etc.).
    private func extractCalleeName(from expr: ExprSyntax) -> String? {
        // Direct identifier: `foo()`
        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }
        // Member access: `self.foo()`, `obj.bar()`, `Type.method()`
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            let member = memberAccess.declName.baseName.text
            if let base = memberAccess.base {
                if let baseName = extractCalleeName(from: base) {
                    return "\(baseName).\(member)"
                }
            }
            // Implicit member: `.foo()` — member name alone
            return member
        }
        // Identifiers that look like type names (e.g., `MyType()`)
        // are already handled by DeclReferenceExprSyntax above.
        return nil
    }

    /// Extract call relationships from parsed entities.
    ///
    /// Walks the full AST once to collect all call sites, then maps
    /// each call to the innermost containing entity by line range.
    static func extractCalls(
        from entities: [ParsedEntity],
        tree: SourceFileSyntax,
        locationConverter: SourceLocationConverter
    ) -> [Relationship] {
        // Only entities with bodies can contain calls.
        let callableEntities = entities.filter {
            $0.entity.entityType == .function
            || $0.entity.entityType == .method
        }
        guard !callableEntities.isEmpty else { return [] }

        let extractor = CallExtractor(locationConverter: locationConverter)
        extractor.walk(tree)

        guard !extractor.callSites.isEmpty else { return [] }

        // Map each call site to its innermost containing entity.
        var relationships: [Relationship] = []

        for site in extractor.callSites {
            // Find the smallest entity whose line range contains this call.
            var bestEntity: ParsedEntity?
            var bestSize = Int.max

            for entity in callableEntities {
                if entity.startLine <= site.line && site.line <= entity.endLine {
                    let size = entity.endLine - entity.startLine
                    if size < bestSize {
                        bestSize = size
                        bestEntity = entity
                    }
                }
            }

            if let owner = bestEntity {
                let rel = Relationship(
                    kind: .calls,
                    sourceEntity: owner.entity.stableId,
                    targetName: site.calleeName,
                    line: site.line
                )
                relationships.append(rel)
            }
        }

        return relationships
    }
}
