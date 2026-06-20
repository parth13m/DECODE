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
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        let collector = EntityCollector(
            source: source,
            fileName: fileName,
            locationConverter: converter
        )
        collector.walk(sourceFile)
        return collector.parsedEntities
    }
}

// MARK: - Parsed Entity

/// A `CodeEntity` enriched with display-only metadata from the AST.
///
/// Wraps the domain model with presentation data (signature, line range,
/// source text) that is derived during parsing but not persisted to the
/// database. Used by the Session Mode UI for entity inspection.
struct ParsedEntity: Identifiable, Sendable {
    /// The core domain model entity.
    let entity: CodeEntity

    /// The declaration signature without the body.
    /// e.g., `func quickSort(_ array: inout [Int], low: Int, high: Int)`
    let signature: String

    /// 1-based start line number in the source file.
    let startLine: Int

    /// 1-based end line number in the source file.
    let endLine: Int

    /// The full source text of the entity (including body).
    let sourceText: String

    /// The source file name.
    let fileName: String

    /// The `stableId` of the parent type entity, if this entity is a member.
    /// For example, a method inside a class has the class's stableId here.
    let parentStableId: String?

    var id: UUID { entity.id }

    /// Formatted line range string for display.
    var lineRangeDescription: String {
        startLine == endLine ? "Line \(startLine)" : "Lines \(startLine)–\(endLine)"
    }

    /// Whether this entity is a top-level declaration (not nested inside a type).
    var isTopLevel: Bool { parentStableId == nil }
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

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        if let members = node.memberBlock.members as MemberBlockItemListSyntax? {
            for member in members {
                walk(member)
            }
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

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        if let members = node.memberBlock.members as MemberBlockItemListSyntax? {
            for member in members {
                walk(member)
            }
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

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        if let members = node.memberBlock.members as MemberBlockItemListSyntax? {
            for member in members {
                walk(member)
            }
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

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = name
        currentParentStableId = parentHash
        if let members = node.memberBlock.members as MemberBlockItemListSyntax? {
            for member in members {
                walk(member)
            }
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

        let previousType = currentTypeName
        let previousParent = currentParentStableId
        currentTypeName = extendedTypeName
        currentParentStableId = existingParent?.entity.stableId
        if let members = node.memberBlock.members as MemberBlockItemListSyntax? {
            for member in members {
                walk(member)
            }
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
