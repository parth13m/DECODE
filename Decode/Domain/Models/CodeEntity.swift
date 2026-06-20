import Foundation

/// A discrete semantic unit extracted from a source file by the AST parser.
///
/// Each CodeEntity represents a function, class, struct, method, protocol, component,
/// or hook discovered during AST analysis. Entities are identified by their structural
/// footprint (`stableId`) rather than line numbers, ensuring identity survives edits
/// above the entity in the file.
///
/// Maps to the `entities` table in the database.
struct CodeEntity: Identifiable, Sendable, Codable, Hashable {

    let id: UUID

    /// The session that owns this entity.
    let sessionId: UUID

    /// Durable identifier that survives renames when the body hash matches.
    /// Generated on first discovery, preserved across re-indexing runs.
    let stableId: String

    /// The structural category of this entity.
    var entityType: EntityType

    /// The symbolic name (e.g., function name, class name).
    var name: String

    /// AI-generated summary: purpose, responsibilities, and relationships.
    var summaryText: String

    /// SHA-256 hash of the entity's body, used for change detection.
    var hash: String

    var lastUpdated: Date
}

/// The structural category of a code entity extracted by the AST parser.
enum EntityType: String, Sendable, Codable, CaseIterable {
    case function
    case `class`
    case method
    case component
    case hook
    case `struct`
    case `protocol`
    case `enum`
}
