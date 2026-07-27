import Foundation

/// A `CodeEntity` enriched with structural metadata from the AST.
///
/// Wraps the domain model with data derived during parsing: signature,
/// line range, source text, and parent relationship. This data is
/// essential for context building, session resolution, and the Session
/// Mode entity inspection UI.
///
/// Currently held in memory on `ManagedWorkspace.parsedEntities` and
/// rebuilt on each file parse. Future iterations will persist these
/// fields to enable cached File Intelligence.
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
