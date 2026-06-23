import Foundation

/// The complete set of deterministic facts extracted from a single source file.
///
/// Produced by both `SwiftSyntaxParser.parseDetailed()` and
/// `TreeSitterParser.parseDetailed()`. Contains every objective fact
/// that can be derived from the AST without semantic reasoning.
///
/// This type grows as new deterministic extractors are added:
/// entities, imports, relationships, and in the future:
/// protocol conformances, inheritance, ownership, etc.
struct DetailedParseResult: Sendable {

    /// All code entities (functions, classes, structs, methods, etc.).
    let entities: [ParsedEntity]

    /// All import declarations found in the file.
    let imports: [ImportDeclaration]

    /// All structural relationships between entities discovered in the file.
    let relationships: [Relationship]
}
