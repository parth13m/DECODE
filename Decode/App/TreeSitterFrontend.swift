// TreeSitterFrontend.swift — Decode App
// IAG-004 §18: Production producer — bridges TreeSitterParser
// to the ProducerRuntime via FrontendOutput.
//
// Handles all non-Swift languages supported by tree-sitter grammars:
// Python, JavaScript, TypeScript, HTML, CSS, Java, C#, C, C++.

import Foundation
import DIRCore
import ProducerRuntime

// MARK: - Tree-sitter Frontend

/// The contract and handler for the tree-sitter frontend producer.
///
/// Handles all non-Swift source files using tree-sitter grammars.
/// Delegates to `TreeSitterParser.parseAllFacts` and converts the result
/// into DIR-compatible `FrontendOutput` records at T0 using the shared
/// `FrontendOutputConversion`.
enum TreeSitterFrontend {

    /// Producer identity for the tree-sitter frontend.
    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "tree-sitter-frontend"),
        version: ProducerVersion(major: 1, minor: 0)
    )

    /// All file extensions handled by tree-sitter grammars.
    ///
    /// Mirrors `GrammarRegistration.allCases.flatMap(\.extensions)`.
    /// Kept as a literal set to avoid importing SwiftTreeSitter in this file.
    static let sourceFormats: Set<String> = [
        // Python
        "py",
        // JavaScript
        "js", "jsx", "mjs", "cjs",
        // TypeScript
        "ts", "tsx",
        // HTML
        "html", "htm",
        // CSS
        "css", "scss",
        // Java
        "java",
        // C#
        "cs",
        // C
        "c", "h",
        // C++
        "cpp", "cxx", "cc", "hpp", "hxx",
    ]

    /// The frontend contract for registration with ProducerRuntime.
    static let contract = FrontendContract(
        identity: identity,
        sourceFormats: sourceFormats,
        outputContract: OutputContract(
            predicates: FrontendOutputConversion.outputPredicates,
            tierRange: .t0 ... .t0
        )
    )

    /// The frontend handler that parses a non-Swift file and produces FrontendOutput records.
    ///
    /// Returns an empty array for unsupported file types (TreeSitterParser
    /// returns empty `DetailedParseResult` when no grammar matches).
    static let handler: @Sendable (
        _ filePath: String,
        _ identity: ProducerIdentity,
        _ outputContract: OutputContract
    ) async throws -> [FrontendOutput] = { filePath, _, _ in
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            return []
        }

        let contentHash = ContentHash(of: data)
        let version = VersionStamp(singleSource: contentHash)
        let fileName = url.lastPathComponent

        let parser = TreeSitterParser()
        let result = parser.parseAllFacts(source: source, fileName: fileName)

        return FrontendOutputConversion.convert(
            result: result,
            fileName: fileName,
            version: version
        )
    }
}
