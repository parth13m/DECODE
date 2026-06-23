import Foundation

/// A single import declaration extracted from a source file.
///
/// Represents a dependency the file declares on an external module or symbol.
/// Used by File Intelligence to understand what the file needs from outside,
/// and by future Module Intelligence to resolve cross-file relationships.
struct ImportDeclaration: Sendable, Hashable {

    /// The module or package name (e.g., "Foundation", "SwiftUI", "numpy").
    let moduleName: String

    /// Specific symbols imported, if the language supports selective imports.
    /// e.g., `from os import path` → `["path"]`
    /// Empty for whole-module imports like `import Foundation`.
    let importedSymbols: [String]

    /// The style of import.
    let kind: ImportKind

    /// 1-based line number where the import appears in the source file.
    let line: Int

    /// The raw import statement text as written in the source.
    let rawText: String
}

/// The style of an import declaration.
///
/// Different languages have different import semantics. This enum
/// captures the common patterns across all supported languages.
enum ImportKind: String, Sendable, Codable, Hashable {
    /// Imports an entire module (e.g., `import Foundation`, `import numpy`).
    case module

    /// Imports specific symbols from a module (e.g., `from os import path`).
    case symbol

    /// Wildcard import (e.g., `from module import *`).
    case wildcard

    /// Side-effect import with no bindings (e.g., `import "styles.css"`).
    case sideEffect
}
