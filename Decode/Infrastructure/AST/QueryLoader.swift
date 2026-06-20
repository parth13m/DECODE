import Foundation
import SwiftTreeSitter

/// Anchor class for `Bundle(for:)` lookups in the Decode module.
private final class BundleToken {}

/// Loads tree-sitter query files (.scm) for language-specific entity extraction.
///
/// Query files live under `Decode/Infrastructure/AST/Queries/<language>/` in the
/// source tree and are copied into the app bundle as resources.
struct QueryLoader: Sendable {

    /// Load a named query file for the given grammar.
    ///
    /// - Parameters:
    ///   - name: The query file name without extension (e.g., "entities").
    ///   - grammar: The grammar whose query directory to search.
    /// - Returns: A compiled ``Query`` ready for use with tree-sitter, or `nil`
    ///   if the query file does not exist or fails to compile.
    func loadQuery(named name: String, for grammar: GrammarRegistration) -> Query? {
        guard let url = queryFileURL(named: name, grammar: grammar) else {
            return nil
        }

        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            print("[QueryLoader] Failed to read query file: \(url.path)")
            #endif
            return nil
        }

        do {
            return try Query(language: grammar.language, data: Data(source.utf8))
        } catch {
            #if DEBUG
            print("[QueryLoader] Failed to compile query '\(name)' for \(grammar.displayName): \(error)")
            #endif
            return nil
        }
    }

    /// Check whether a query file exists for the given grammar.
    func hasQuery(named name: String, for grammar: GrammarRegistration) -> Bool {
        queryFileURL(named: name, grammar: grammar) != nil
    }

    // MARK: - Private

    /// Resolve the URL for a query file in the grammar's query directory.
    ///
    /// Searches multiple bundle locations to work in both app and test contexts.
    private func queryFileURL(named name: String, grammar: GrammarRegistration) -> URL? {
        let dir = grammar.queryDirectory

        for bundle in Self.searchBundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: "scm",
                subdirectory: "Queries/\(dir)"
            ) {
                return url
            }
        }

        return nil
    }

    /// Bundle search order: main bundle, then the bundle containing this code.
    ///
    /// In app context, `Bundle.main` has the Queries folder.
    /// In test context, `Bundle.main` is the test runner — fall back to
    /// the bundle that contains `BundleToken` (the Decode app bundle).
    private static let searchBundles: [Bundle] = {
        var bundles: [Bundle] = [.main]
        let tokenBundle = Bundle(for: BundleToken.self)
        if tokenBundle != .main {
            bundles.append(tokenBundle)
        }
        return bundles
    }()
}
