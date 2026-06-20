import Foundation
import SwiftTreeSitter
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterTypeScript

/// Maps file extensions to tree-sitter ``Language`` grammars.
///
/// Each supported language's grammar is compiled from C source at build time
/// via its SPM package. This registry provides the bridge between a file's
/// extension and the correct ``Language`` instance for parsing.
///
/// ## Adding a New Language
/// 1. Add the grammar SPM package to `project.yml` (packages + dependencies).
/// 2. Import the grammar module above.
/// 3. Add a new ``GrammarRegistration`` case with its extensions and `Language`.
/// 4. Add query files to `Decode/Infrastructure/AST/Queries/<language>/`.
enum GrammarRegistration: CaseIterable, Sendable {

    case python
    case javascript
    case typescript
    case html
    case css
    // case sql — excluded until upstream SPM package is fixed
    case java
    case csharp
    case c
    case cpp

    /// File extensions handled by this grammar (lowercase, no dot).
    var extensions: [String] {
        switch self {
        case .python: ["py"]
        case .javascript: ["js", "jsx", "mjs", "cjs"]
        case .typescript: ["ts", "tsx"]
        case .html: ["html", "htm"]
        case .css: ["css", "scss"]
        case .java: ["java"]
        case .csharp: ["cs"]
        case .c: ["c", "h"]
        case .cpp: ["cpp", "cxx", "cc", "hpp", "hxx"]
        }
    }

    /// The tree-sitter ``Language`` for this grammar.
    var language: Language {
        switch self {
        case .python: Language(language: tree_sitter_python())
        case .javascript: Language(language: tree_sitter_javascript())
        case .typescript: Language(language: tree_sitter_typescript())
        case .html: Language(language: tree_sitter_html())
        case .css: Language(language: tree_sitter_css())
        case .java: Language(language: tree_sitter_java())
        case .csharp: Language(language: tree_sitter_c_sharp())
        case .c: Language(language: tree_sitter_c())
        case .cpp: Language(language: tree_sitter_cpp())
        }
    }

    /// Display name for diagnostics and logging.
    var displayName: String {
        switch self {
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .html: "HTML"
        case .css: "CSS"
        case .java: "Java"
        case .csharp: "C#"
        case .c: "C"
        case .cpp: "C++"
        }
    }

    /// The subdirectory name under `Queries/` for this language's query files.
    var queryDirectory: String {
        switch self {
        case .python: "python"
        case .javascript: "javascript"
        case .typescript: "typescript"
        case .html: "html"
        case .css: "css"
        case .java: "java"
        case .csharp: "csharp"
        case .c: "c"
        case .cpp: "cpp"
        }
    }

    // MARK: - Lookup

    /// Resolve a grammar from a file name's extension.
    ///
    /// Returns `nil` for Swift files (handled by ``SwiftSyntaxParser``) and
    /// unrecognized extensions.
    static func from(fileName: String) -> GrammarRegistration? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return extensionMap[ext]
    }

    /// Pre-built extension → grammar lookup table.
    private static let extensionMap: [String: GrammarRegistration] = {
        var map: [String: GrammarRegistration] = [:]
        for grammar in GrammarRegistration.allCases {
            for ext in grammar.extensions {
                map[ext] = grammar
            }
        }
        return map
    }()
}
