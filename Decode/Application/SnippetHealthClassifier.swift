import Foundation
import SwiftTreeSitter

/// Classifies the health of a code snippet by parsing it with tree-sitter
/// and analyzing the resulting syntax tree for errors.
///
/// The classifier does NOT decide that code is broken. It provides evidence
/// and a confidence tier that steers the LLM prompt. The LLM remains
/// responsible for final judgment.
///
/// ## Confidence Philosophy
/// - Parser errors at snippet edges are almost always boundary artifacts
///   from partial selection — they carry low weight.
/// - Parser errors in the snippet interior (surrounded by valid nodes on
///   both sides) are strong evidence of real syntax problems.
/// - When full file context is available (Session Mode), the classifier
///   validates whether the same region has errors in the full file parse.
///   If the full file parses cleanly at the snippet's location, all
///   snippet-only errors are boundary artifacts.
///
/// ## Tiers
/// - ``HealthTier/silent``: No evidence of issues. Default.
/// - ``HealthTier/observe``: Ambiguous signals. LLM is *permitted* to
///   mention issues if it independently notices them.
/// - ``HealthTier/surface``: Moderate evidence. LLM receives evidence
///   and is allowed to use its judgment.
/// - ``HealthTier/diagnose``: High-confidence evidence. LLM is asked
///   to prioritize diagnosis.
struct SnippetHealthClassifier: Sendable {

    // MARK: - Public API

    /// Classify a snippet's health using tree-sitter analysis.
    ///
    /// - Parameters:
    ///   - snippet: The user's selected code text.
    ///   - language: The grammar to parse with (known from session file extension).
    ///   - fullFileSource: The full file content, if available. Used to validate
    ///     whether snippet errors are real or boundary artifacts.
    /// - Returns: A ``HealthClassification`` containing the tier and diagnostic hints.
    func classify(
        snippet: String,
        language: GrammarRegistration,
        fullFileSource: String?
    ) -> HealthClassification {
        // Short snippets (< 2 non-empty lines) are almost always fragments.
        let meaningfulLines = snippet
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard meaningfulLines.count >= 2 else {
            return HealthClassification(tier: .silent, hints: [])
        }

        // Parse the snippet in isolation.
        let parser = Parser()
        do {
            try parser.setLanguage(language.language)
        } catch {
            return HealthClassification(tier: .silent, hints: [])
        }

        guard let tree = parser.parse(snippet) else {
            return HealthClassification(tier: .silent, hints: [])
        }

        guard let rootNode = tree.rootNode else {
            return HealthClassification(tier: .silent, hints: [])
        }

        // If the root has no errors at all, nothing to report.
        guard rootNode.hasError else {
            return HealthClassification(tier: .silent, hints: [])
        }

        // Collect all ERROR and MISSING nodes.
        var errorNodes: [ErrorNodeInfo] = []
        collectErrorNodes(node: rootNode, snippet: snippet, into: &errorNodes)

        guard !errorNodes.isEmpty else {
            return HealthClassification(tier: .silent, hints: [])
        }

        // Classify each error as edge or interior.
        let snippetByteCount = snippet.data(using: .utf16LittleEndian)?.count
            ?? snippet.utf8.count
        classifyPositions(errors: &errorNodes, rootNode: rootNode, totalBytes: snippetByteCount)

        // If full file context is available, validate against it.
        if let fullSource = fullFileSource {
            let fullFileConfirms = validateAgainstFullFile(
                snippet: snippet,
                fullSource: fullSource,
                language: language,
                snippetErrors: errorNodes
            )
            if !fullFileConfirms {
                // Full file parses cleanly at this location — all errors are
                // boundary artifacts. Downgrade to silent.
                return HealthClassification(tier: .silent, hints: [])
            }
        }

        // Compute tier from the classified errors.
        let interiorErrors = errorNodes.filter { $0.position == .interior }
        let edgeErrors = errorNodes.filter { $0.position == .edge }

        let hints = errorNodes.map { error in
            DiagnosticHint(
                line: error.line,
                description: error.description,
                isInterior: error.position == .interior
            )
        }

        // Tier decision — conservative by design.
        if interiorErrors.count >= 3 {
            return HealthClassification(tier: .diagnose, hints: hints)
        }
        if interiorErrors.count >= 1 {
            return HealthClassification(tier: .surface, hints: hints)
        }
        // Edge-only errors with high density suggest wrong language or gibberish,
        // but we don't report that as a code health issue — it's a selection issue.
        if edgeErrors.count >= 4 {
            return HealthClassification(tier: .observe, hints: hints)
        }

        // Default: edge-only errors with low count → boundary artifacts.
        return HealthClassification(tier: .silent, hints: [])
    }

    // MARK: - Tree Walking

    /// Recursively collect ERROR and MISSING nodes from the syntax tree.
    private func collectErrorNodes(
        node: Node,
        snippet: String,
        into results: inout [ErrorNodeInfo]
    ) {
        let nodeType = node.nodeType ?? ""

        if nodeType == "ERROR" || node.isMissing {
            let pointRange = node.pointRange
            let line = Int(pointRange.lowerBound.row) + 1

            let description: String
            if node.isMissing {
                // MISSING nodes have a nodeType indicating what was expected.
                let expected = nodeType.isEmpty ? "token" : nodeType
                description = "Missing \(expected)"
            } else {
                // ERROR nodes — extract a short context string.
                let byteStart = Int(node.byteRange.lowerBound)
                let byteEnd = Int(node.byteRange.upperBound)
                let utf16Data = snippet.data(using: .utf16LittleEndian) ?? Data()
                let errorText: String
                if byteStart < byteEnd, byteEnd <= utf16Data.count {
                    let raw = String(
                        data: utf16Data[byteStart..<byteEnd],
                        encoding: .utf16LittleEndian
                    ) ?? ""
                    // Truncate for readability.
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    errorText = String(trimmed.prefix(40))
                } else {
                    errorText = ""
                }
                if errorText.isEmpty {
                    description = "Syntax error"
                } else {
                    description = "Unexpected: \(errorText)"
                }
            }

            results.append(ErrorNodeInfo(
                line: line,
                byteRange: node.byteRange,
                isMissing: node.isMissing,
                description: description,
                position: .unknown // classified later
            ))
            return // Don't recurse into ERROR subtrees.
        }

        // Recurse into children if this node or a descendant has errors.
        if node.hasError {
            for i in 0..<node.childCount {
                if let child = node.child(at: i) {
                    collectErrorNodes(node: child, snippet: snippet, into: &results)
                }
            }
        }
    }

    /// Classify each error as edge or interior based on its position in the tree.
    ///
    /// Edge: the error node is at the very start or very end of the snippet
    /// (within the first or last child of the root, or the first/last line).
    /// Interior: the error node has valid sibling nodes on both sides.
    private func classifyPositions(
        errors: inout [ErrorNodeInfo],
        rootNode: Node,
        totalBytes: Int
    ) {
        // Determine the byte boundaries for "edge" classification.
        // First and last top-level children define the edges.
        let firstChildEnd: UInt32
        let lastChildStart: UInt32

        if let first = rootNode.firstChild {
            firstChildEnd = first.byteRange.upperBound
        } else {
            firstChildEnd = 0
        }

        if let last = rootNode.lastChild {
            lastChildStart = last.byteRange.lowerBound
        } else {
            lastChildStart = UInt32(totalBytes)
        }

        for i in 0..<errors.count {
            let errorStart = errors[i].byteRange.lowerBound
            let errorEnd = errors[i].byteRange.upperBound

            // An error is "edge" if it overlaps with the first or last
            // top-level child's range, meaning it's at the snippet boundary.
            let isAtStart = errorStart <= firstChildEnd && errorStart == rootNode.byteRange.lowerBound
                || errors[i].line <= 1
            let isAtEnd = errorEnd >= lastChildStart && errorEnd >= rootNode.byteRange.upperBound - 1
                || errors[i].line >= Int(rootNode.pointRange.upperBound.row) + 1

            if isAtStart || isAtEnd {
                errors[i].position = .edge
            } else {
                errors[i].position = .interior
            }
        }
    }

    // MARK: - Full File Validation

    /// Check whether the snippet's errors also appear in the full file parse.
    ///
    /// If the full file parses cleanly at the snippet's line range, the
    /// snippet errors are boundary artifacts and this returns `false`.
    /// If the full file also has errors at the same location, returns `true`.
    private func validateAgainstFullFile(
        snippet: String,
        fullSource: String,
        language: GrammarRegistration,
        snippetErrors: [ErrorNodeInfo]
    ) -> Bool {
        // Find the snippet's location in the full file.
        guard let snippetRange = fullSource.range(of: snippet) else {
            // Try whitespace-normalized match.
            let normalized = normalizeWhitespace(snippet)
            let fullNormalized = normalizeWhitespace(fullSource)
            guard fullNormalized.contains(normalized) else {
                // Can't locate snippet in file — can't validate.
                // Conservative: treat errors as potentially real.
                return true
            }
            // Found via normalized match — still parse the full file.
            return fullFileHasErrorsNearSnippet(
                fullSource: fullSource,
                language: language,
                snippetText: snippet
            )
        }

        let snippetStartLine = fullSource[..<snippetRange.lowerBound]
            .components(separatedBy: "\n").count

        // Parse the full file.
        let parser = Parser()
        do {
            try parser.setLanguage(language.language)
        } catch {
            return true // Can't parse — be conservative.
        }

        guard let fullTree = parser.parse(fullSource),
              let fullRoot = fullTree.rootNode else {
            return true
        }

        // Check if the full file has errors in the snippet's line range.
        let snippetLineCount = snippet.components(separatedBy: "\n").count
        let snippetEndLine = snippetStartLine + snippetLineCount

        return regionHasErrors(
            node: fullRoot,
            startLine: snippetStartLine,
            endLine: snippetEndLine
        )
    }

    /// Check if the full file parse has errors near the snippet location.
    /// Used when exact range matching fails but normalized match succeeds.
    private func fullFileHasErrorsNearSnippet(
        fullSource: String,
        language: GrammarRegistration,
        snippetText: String
    ) -> Bool {
        let parser = Parser()
        do {
            try parser.setLanguage(language.language)
        } catch {
            return true
        }

        guard let fullTree = parser.parse(fullSource),
              let fullRoot = fullTree.rootNode else {
            return true
        }

        // If the full file root has no errors at all, nothing is real.
        return fullRoot.hasError
    }

    /// Recursively check whether any node in the given line range has errors.
    private func regionHasErrors(node: Node, startLine: Int, endLine: Int) -> Bool {
        let nodeStart = Int(node.pointRange.lowerBound.row) + 1
        let nodeEnd = Int(node.pointRange.upperBound.row) + 1

        // Skip nodes entirely outside the region.
        if nodeEnd < startLine || nodeStart > endLine {
            return false
        }

        // Check this node.
        let nodeType = node.nodeType ?? ""
        if (nodeType == "ERROR" || node.isMissing)
            && nodeStart >= startLine && nodeEnd <= endLine {
            return true
        }

        // Recurse into children.
        if node.hasError {
            for i in 0..<node.childCount {
                if let child = node.child(at: i) {
                    if regionHasErrors(node: child, startLine: startLine, endLine: endLine) {
                        return true
                    }
                }
            }
        }

        return false
    }

    // MARK: - Helpers

    private func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Types

/// The confidence tier for a snippet's health classification.
///
/// Tiers are ordered from least to most confident that real issues exist.
/// The system is conservative: SILENT is the default, and each higher tier
/// requires stronger evidence.
enum HealthTier: String, Sendable {
    /// No evidence of issues. No prompt changes.
    case silent
    /// Ambiguous signals. LLM is permitted to mention issues if it spots them.
    case observe
    /// Moderate evidence (interior errors). LLM receives evidence + judgment.
    case surface
    /// High-confidence evidence. LLM prioritizes diagnosis.
    case diagnose
}

/// The result of snippet health classification.
struct HealthClassification: Sendable {
    let tier: HealthTier
    let hints: [DiagnosticHint]
}

/// A single diagnostic hint from the tree-sitter parse.
///
/// These are evidence for the LLM, not conclusions. The LLM may dismiss
/// any hint as a partial-selection artifact.
struct DiagnosticHint: Sendable {
    /// 1-based line number within the snippet.
    let line: Int
    /// Human-readable description of the issue.
    let description: String
    /// Whether this error is in the snippet interior (vs edge).
    let isInterior: Bool
}

/// Internal representation of an error node during tree walking.
private struct ErrorNodeInfo {
    let line: Int
    let byteRange: Range<UInt32>
    let isMissing: Bool
    let description: String
    var position: ErrorPosition
}

/// Whether an error node is at a snippet boundary or in the interior.
private enum ErrorPosition {
    case unknown
    case edge
    case interior
}
