import Foundation

/// The result of parsing a source file's AST.
///
/// Contains the extracted entities and the dependency edges between them.
struct ASTParseResult: Sendable {
    /// All code entities extracted from the file.
    let entities: [CodeEntity]

    /// Directed dependency edges between the extracted entities.
    let dependencies: [EntityDependency]
}

/// Defines the contract for parsing source files into semantic code entities.
///
/// The concrete implementation uses SwiftSyntax (for Swift files) or potentially
/// Tree-sitter (for other languages) to parse files into their structural components:
/// functions, classes, methods, structs, protocols, etc.
///
/// The parser runs on a background actor to avoid blocking the main thread,
/// as AST analysis is CPU-intensive.
protocol ASTParserProtocol: Sendable {

    /// Parse a source file and extract its code entities and dependency graph.
    ///
    /// - Parameters:
    ///   - source: The full source code text of the file.
    ///   - fileName: The file name (used for language detection and entity naming).
    /// - Returns: The extracted entities and their dependency relationships.
    func parse(source: String, fileName: String) async throws -> ASTParseResult
}
