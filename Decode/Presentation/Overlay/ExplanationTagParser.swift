import Foundation
import SwiftUI

/// The 7 supported explanation tags.
enum ExplanationTag: String, CaseIterable {
    case hl
    case critical
    case tip
    case note
    case analogy
    case flow
    case tldr

    /// Whether this tag should render as a standalone visual block.
    var isBlock: Bool {
        switch self {
        case .tldr, .flow: return true
        case .hl, .critical, .tip, .note, .analogy: return false
        }
    }
}

/// A parsed segment of explanation text.
enum TaggedSegment: Equatable {
    /// Unstyled plain text (between or outside tags).
    case plain(String)
    /// Text wrapped in a recognized tag.
    case tagged(ExplanationTag, String)
}

/// A renderable block in the HUD. Each block becomes one SwiftUI view.
enum ContentBlock: Identifiable {
    /// One or more consecutive inline segments, rendered as a single
    /// AttributedString inside a Text view.
    case inlineRun(id: Int, segments: [TaggedSegment])
    /// A block-level TLDR card.
    case tldr(id: Int, content: String)
    /// A block-level flow diagram (also used for workflows, hierarchies,
    /// and branching flowcharts detected in V7 output).
    case flow(id: Int, content: String)
    /// A fenced code block with optional language label.
    case codeBlock(id: Int, language: String?, code: String)
    /// A parsed markdown table with headers and data rows.
    case table(id: Int, headers: [String], rows: [[String]])

    var id: Int {
        switch self {
        case .inlineRun(let id, _): return id
        case .tldr(let id, _): return id
        case .flow(let id, _): return id
        case .codeBlock(let id, _, _): return id
        case .table(let id, _, _): return id
        }
    }

    /// Return a copy of this block with a new ID.
    func withID(_ newID: Int) -> ContentBlock {
        switch self {
        case .inlineRun(_, let segments): return .inlineRun(id: newID, segments: segments)
        case .tldr(_, let content): return .tldr(id: newID, content: content)
        case .flow(_, let content): return .flow(id: newID, content: content)
        case .codeBlock(_, let language, let code):
            return .codeBlock(id: newID, language: language, code: code)
        case .table(_, let headers, let rows):
            return .table(id: newID, headers: headers, rows: rows)
        }
    }
}

/// Stateless parser that converts raw LLM output with custom tags into
/// styled content blocks for HUD rendering.
///
/// Pipeline: raw String -> [TaggedSegment] -> [ContentBlock] -> SwiftUI views
enum ExplanationTagParser {

    // MARK: - Stage 1: Scanner

    /// Parse raw explanation text into flat tagged segments.
    ///
    /// Single-pass linear scan. Unclosed tags are treated as plain text.
    /// Nested tags: outermost wins, inner markers become literal text.
    /// Every character in the input appears in exactly one output segment.
    static func parse(_ raw: String) -> [TaggedSegment] {
        guard !raw.isEmpty else { return [] }

        var segments: [TaggedSegment] = []
        var plainBuffer = ""
        var position = raw.startIndex

        while position < raw.endIndex {
            if raw[position] == "<" {
                // Try to match an opening tag.
                if let (tag, tagEnd) = matchOpeningTag(in: raw, at: position) {
                    // Look for the matching closing tag (case-insensitive to
                    // handle LLM output like `</Hl>` or `</HL>`).
                    let closeTag = "</\(tag.rawValue)>"
                    if let closeRange = raw.range(of: closeTag, options: .caseInsensitive, range: tagEnd..<raw.endIndex) {
                        let content = String(raw[tagEnd..<closeRange.lowerBound])

                        // Skip empty tags.
                        if !content.isEmpty {
                            // Flush plain buffer before emitting tagged segment.
                            if !plainBuffer.isEmpty {
                                segments.append(.plain(plainBuffer))
                                plainBuffer = ""
                            }
                            segments.append(.tagged(tag, content))
                        }

                        position = closeRange.upperBound
                        continue
                    }
                }

                // Not a recognized tag or no closing tag found — treat '<' as literal.
                plainBuffer.append(raw[position])
                position = raw.index(after: position)
            } else {
                plainBuffer.append(raw[position])
                position = raw.index(after: position)
            }
        }

        if !plainBuffer.isEmpty {
            segments.append(.plain(plainBuffer))
        }

        return segments
    }

    // MARK: - Stage 2: Grouper

    /// Group flat segments into renderable content blocks.
    ///
    /// Consecutive inline segments are collected into a single `.inlineRun`.
    /// Block-level tagged segments (tldr, flow) become standalone blocks.
    static func group(_ segments: [TaggedSegment]) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var inlineBuffer: [TaggedSegment] = []
        var nextID = 0

        for segment in segments {
            switch segment {
            case .tagged(let tag, let content) where tag.isBlock:
                // Flush inline buffer.
                if !inlineBuffer.isEmpty {
                    blocks.append(.inlineRun(id: nextID, segments: inlineBuffer))
                    nextID += 1
                    inlineBuffer = []
                }

                switch tag {
                case .tldr:
                    blocks.append(.tldr(id: nextID, content: content))
                case .flow:
                    blocks.append(.flow(id: nextID, content: content))
                default:
                    break // Other block tags would go here.
                }
                nextID += 1

            default:
                inlineBuffer.append(segment)
            }
        }

        if !inlineBuffer.isEmpty {
            blocks.append(.inlineRun(id: nextID, segments: inlineBuffer))
        }

        return blocks
    }

    // MARK: - Stage 3: AttributedString Builder

    /// Build a styled AttributedString from inline segments.
    ///
    /// Called for `.inlineRun` blocks only. Block-level tags are rendered
    /// by dedicated SwiftUI views, not this function.
    ///
    /// Plain segments are parsed as Markdown so `**bold**`, `` `code` ``,
    /// and other inline formatting renders correctly. Tagged segments use
    /// custom styling and skip Markdown processing.
    static func attributedString(from segments: [TaggedSegment]) -> AttributedString {
        var result = AttributedString()

        for segment in segments {
            switch segment {
            case .plain(let text):
                // Parse as Markdown to render bold, code spans, etc.
                // Fall back to plain text if Markdown parsing fails.
                var attr: AttributedString
                if let md = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    attr = md
                } else {
                    attr = AttributedString(text)
                }
                attr.font = .system(size: 13)
                result += attr

            case .tagged(let tag, let content):
                var attr = AttributedString(content)
                applyStyle(for: tag, to: &attr)
                result += attr
            }
        }

        return result
    }

    // MARK: - TLDR Extraction

    /// Extract the first `<tldr>` content from raw explanation text.
    ///
    /// Reuses the tag scanner without the full block-detection pipeline.
    /// Returns `nil` if no `<tldr>` tag is present or its content is empty.
    static func extractTLDR(from raw: String) -> String? {
        let segments = parse(raw)
        for segment in segments {
            if case .tagged(.tldr, let content) = segment {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    // MARK: - Convenience

    /// Raw string -> content blocks in one call.
    ///
    /// Pipeline: sanitize → detect block-level content (code blocks,
    /// tables, diagrams) → parse remaining text for tags → group.
    ///
    /// Block-level detection runs before tag parsing so that content
    /// inside fenced code blocks is protected from tag interpretation.
    static func blocks(from raw: String) -> [ContentBlock] {
        let sanitized = sanitize(raw)
        let detected = detectBlockLevelContent(from: sanitized)

        var result: [ContentBlock] = []
        for item in detected {
            switch item {
            case .plainText(let text):
                result.append(contentsOf: group(parse(text)))
            case .codeBlock(let language, let code):
                result.append(.codeBlock(id: 0, language: language, code: code))
            case .table(let headers, let rows):
                result.append(.table(id: 0, headers: headers, rows: rows))
            case .diagram(let content):
                result.append(.flow(id: 0, content: content))
            }
        }

        // Re-assign sequential IDs across all blocks.
        return result.enumerated().map { $1.withID($0) }
    }

    // MARK: - Output Sanitization

    /// Set of known tag names for fast lookup during sanitization.
    private static let knownTagNames: Set<String> = Set(ExplanationTag.allCases.map(\.rawValue))

    /// Sanitize raw LLM output before parsing.
    ///
    /// Four passes in order:
    /// 1. Strip markdown headings (`## Text` → `**Text**`)
    /// 2. Unwrap matched unknown tags (keep content, remove markers)
    /// 3. Strip orphan unknown tag markers
    /// 4. Collapse 3+ consecutive blank lines to 2
    ///
    /// Known tags pass through untouched. No content is ever deleted —
    /// only tag markers and heading prefixes are removed.
    static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        var text = raw

        // Pass 1: Convert markdown headings to bold text.
        // The renderer uses .inlineOnlyPreservingWhitespace which doesn't
        // support block-level headings — they leak as literal "## Text".
        text = stripMarkdownHeadings(text)

        // Pass 2: Unwrap matched unknown tags — keep inner content.
        // e.g., <trace>fib(4) → 3</trace> becomes fib(4) → 3
        text = unwrapUnknownTags(text)

        // Pass 3: Strip orphan unknown tag markers (<word> or </word>)
        // that don't have a matching pair.
        text = stripOrphanUnknownTags(text)

        // Pass 4: Collapse excessive blank lines (3+ → 2).
        text = collapseBlankLines(text)

        return text
    }

    /// Strip markdown heading prefixes and convert to bold.
    private static func stripMarkdownHeadings(_ text: String) -> String {
        // Match lines starting with 1-6 # followed by a space.
        // Replace with bold text so the visual hierarchy is preserved.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^(#{1,6})\s+(.+)$"#
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "**$2**"
        )
    }

    /// Unwrap matched unknown tag pairs, preserving inner content.
    ///
    /// Matches `<tagname>content</tagname>` where tagname is 2+ letters
    /// and NOT a known tag. Replaces with just the content.
    private static func unwrapUnknownTags(_ text: String) -> String {
        // Match <word>...</word> pairs (case-insensitive, non-greedy content).
        // Tag name must be 2+ alphabetic characters to avoid matching
        // single-letter generics like <T> or comparison operators.
        guard let regex = try? NSRegularExpression(
            pattern: #"<([a-zA-Z]{2,})(?:\s[^>]*)?>(.+?)</\1>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }

        var result = text
        // Iterate from last match to first to preserve string indices.
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()

        for match in matches {
            guard let tagNameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let tagName = String(result[tagNameRange]).lowercased()
            // Skip known tags — they should pass through to the parser.
            if knownTagNames.contains(tagName) { continue }
            let content = String(result[contentRange])
            result.replaceSubrange(fullRange, with: content)
        }

        return result
    }

    /// Strip unmatched opening or closing tags for unknown tag names.
    ///
    /// Catches leftover `<trace>` or `</trace>` that didn't form a pair.
    /// Only strips tags with 2+ letter names to avoid hitting generics.
    private static func stripOrphanUnknownTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"</?([a-zA-Z]{2,})(?:\s[^>]*)?>"#,
            options: .caseInsensitive
        ) else {
            return text
        }

        var result = text
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()

        for match in matches {
            guard let tagNameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else {
                continue
            }
            let tagName = String(result[tagNameRange]).lowercased()
            if knownTagNames.contains(tagName) { continue }
            result.replaceSubrange(fullRange, with: "")
        }

        return result
    }

    /// Collapse runs of 3+ blank lines into 2.
    private static func collapseBlankLines(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\n{3,}"#
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "\n\n"
        )
    }

    // MARK: - Block-Level Content Detection

    /// A detected block-level content type within plain text.
    private enum DetectedContent {
        case plainText(String)
        case codeBlock(language: String?, code: String)
        case table(headers: [String], rows: [[String]])
        case diagram(String)
    }

    /// Extract block-level content (code blocks, tables, structured diagrams)
    /// from sanitized text.
    ///
    /// Runs three detection passes in priority order:
    /// 1. Fenced code blocks (highest — content inside is protected)
    /// 2. Markdown tables
    /// 3. Structural diagrams (workflows, hierarchies, branching flowcharts)
    ///
    /// Plain text between detected blocks passes through the existing tag
    /// parser unchanged.
    private static func detectBlockLevelContent(from text: String) -> [DetectedContent] {
        guard !text.isEmpty else { return [] }

        // Pass 1: Extract fenced code blocks.
        let afterCodeBlocks = extractCodeBlocks(from: text)

        // Pass 2: Extract tables from remaining plain text.
        let afterTables = afterCodeBlocks.flatMap { block -> [DetectedContent] in
            guard case .plainText(let plainText) = block else { return [block] }
            return extractTables(from: plainText)
        }

        // Pass 3: Extract diagrams from remaining plain text.
        return afterTables.flatMap { block -> [DetectedContent] in
            guard case .plainText(let plainText) = block else { return [block] }
            return extractDiagrams(from: plainText)
        }
    }

    // MARK: Code Block Extraction

    /// Detect and extract fenced code blocks (``` ... ```).
    private static func extractCodeBlocks(from text: String) -> [DetectedContent] {
        let lines = text.components(separatedBy: "\n")
        var result: [DetectedContent] = []
        var plainLines: [String] = []
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                // Flush accumulated plain text.
                if !plainLines.isEmpty {
                    result.append(.plainText(plainLines.joined(separator: "\n")))
                    plainLines = []
                }

                let lang = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                var foundClose = false
                while i < lines.count {
                    let closeTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if closeTrimmed.hasPrefix("```") {
                        foundClose = true
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }

                if foundClose || !codeLines.isEmpty {
                    result.append(.codeBlock(
                        language: lang.isEmpty ? nil : lang,
                        code: codeLines.joined(separator: "\n")
                    ))
                } else {
                    // Unclosed — treat opening marker as plain text.
                    plainLines.append("```" + lang)
                }
                continue
            }

            plainLines.append(lines[i])
            i += 1
        }

        if !plainLines.isEmpty {
            result.append(.plainText(plainLines.joined(separator: "\n")))
        }

        return result
    }

    // MARK: Table Extraction

    /// Detect and extract markdown tables.
    ///
    /// A table requires: header row (|...|), separator row (|---|),
    /// and optionally data rows.
    private static func extractTables(from text: String) -> [DetectedContent] {
        let lines = text.components(separatedBy: "\n")
        var result: [DetectedContent] = []
        var plainLines: [String] = []
        var i = 0

        while i < lines.count {
            if isTableRow(lines[i])
                && i + 1 < lines.count
                && isTableSeparator(lines[i + 1]) {
                // Found table start.
                if !plainLines.isEmpty {
                    result.append(.plainText(plainLines.joined(separator: "\n")))
                    plainLines = []
                }

                var tableLines: [String] = []
                while i < lines.count
                        && (isTableRow(lines[i]) || isTableSeparator(lines[i])) {
                    tableLines.append(lines[i])
                    i += 1
                }

                if let (headers, rows) = parseMarkdownTable(tableLines) {
                    result.append(.table(headers: headers, rows: rows))
                } else {
                    plainLines.append(contentsOf: tableLines)
                }
                continue
            }

            plainLines.append(lines[i])
            i += 1
        }

        if !plainLines.isEmpty {
            result.append(.plainText(plainLines.joined(separator: "\n")))
        }

        return result
    }

    /// Check if a line looks like a markdown table row.
    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
            && trimmed.filter({ $0 == "|" }).count >= 3
    }

    /// Check if a line is a table separator row (e.g., |---|---|).
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") && trimmed.hasSuffix("|") else { return false }
        let inner = trimmed.dropFirst().dropLast()
        return inner.allSatisfy { "-:| ".contains($0) }
            && inner.contains("-")
    }

    /// Parse markdown table lines into headers and data rows.
    private static func parseMarkdownTable(
        _ lines: [String]
    ) -> (headers: [String], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }

        let headers = parseTableCells(lines[0])
        guard !headers.isEmpty else { return nil }

        // Skip separator row (index 1), collect data rows.
        var rows: [[String]] = []
        for line in lines.dropFirst(2) {
            if isTableSeparator(line) { continue }
            rows.append(parseTableCells(line))
        }

        return (headers, rows)
    }

    /// Split a table row into individual cell strings.
    private static func parseTableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: "|")
        // First and last elements are empty (before first | and after last |).
        return parts.dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Diagram Extraction

    /// Detect and extract structural diagrams (workflows, hierarchies,
    /// branching flowcharts) from plain text.
    ///
    /// A diagram is a contiguous group of non-blank lines containing at
    /// least one structural marker (↓ on its own line, or a line starting
    /// with a Unicode box-drawing character) and at least two total lines.
    ///
    /// Detected diagrams are routed to ``FlowBlockView`` for monospaced
    /// rendering. If the first line is a bold label (e.g., `**Workflow**`),
    /// it is split off as plain text so it renders with normal styling.
    private static func extractDiagrams(from text: String) -> [DetectedContent] {
        let lines = text.components(separatedBy: "\n")
        var result: [DetectedContent] = []
        var currentBlock: [String] = []

        func classifyAndFlush() {
            guard !currentBlock.isEmpty else { return }

            let structuralCount = currentBlock.filter { isDiagramLine($0) }.count

            if structuralCount >= 1 && currentBlock.count >= 2 {
                // Check if first line is a bold label to split off.
                let first = currentBlock[0].trimmingCharacters(in: .whitespaces)
                if first.hasPrefix("**") && !isDiagramLine(currentBlock[0])
                    && currentBlock.count > 2 {
                    result.append(.plainText(currentBlock[0]))
                    result.append(.diagram(
                        Array(currentBlock.dropFirst()).joined(separator: "\n")
                    ))
                } else {
                    result.append(.diagram(
                        currentBlock.joined(separator: "\n")
                    ))
                }
            } else {
                result.append(.plainText(
                    currentBlock.joined(separator: "\n")
                ))
            }

            currentBlock = []
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                classifyAndFlush()
                // Preserve blank line for prose spacing.
                result.append(.plainText(""))
            } else {
                currentBlock.append(line)
            }
        }

        classifyAndFlush()

        // Merge consecutive plain text blocks.
        var merged: [DetectedContent] = []
        for block in result {
            if case .plainText(let text) = block,
               let lastIdx = merged.indices.last,
               case .plainText(let prev) = merged[lastIdx] {
                merged[lastIdx] = .plainText(prev + "\n" + text)
            } else {
                merged.append(block)
            }
        }

        return merged
    }

    /// Check if a line is a structural diagram marker.
    ///
    /// Returns true for:
    /// - Lines that are solely `↓` (workflow step separator)
    /// - Lines starting with a Unicode box-drawing character (U+2500–U+257F):
    ///   includes ─ │ ├ └ ┌ ┐ and variants used in trees and flowcharts
    private static func isDiagramLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "↓" { return true }
        if let scalar = trimmed.unicodeScalars.first {
            let v = scalar.value
            if v >= 0x2500 && v <= 0x257F { return true }
        }
        return false
    }

    // MARK: - Private Helpers

    /// Try to match an opening tag at the given position.
    /// Returns the matched tag and the index immediately after the closing '>'.
    ///
    /// Tolerant of common LLM output variations:
    /// - Case-insensitive: `<HL>`, `<Hl>`, `<hL>` all match `hl`
    /// - Attributes ignored: `<hl class="x">` matches `hl`
    /// - Trailing whitespace: `<hl >` matches `hl`
    private static func matchOpeningTag(
        in string: String,
        at position: String.Index
    ) -> (ExplanationTag, String.Index)? {
        // Must start with '<'
        guard string[position] == "<" else { return nil }

        let afterOpen = string.index(after: position)
        guard afterOpen < string.endIndex else { return nil }

        // Must not be a closing tag.
        if string[afterOpen] == "/" { return nil }

        // Find the closing '>'.
        guard let closeBracket = string.range(
            of: ">",
            range: afterOpen..<string.endIndex
        )?.lowerBound else {
            return nil
        }

        let rawContent = String(string[afterOpen..<closeBracket])

        // Extract just the tag name: everything before the first space.
        // Handles attributes like `<hl class="x">` and whitespace like `<hl >`.
        let tagName = rawContent
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? rawContent

        guard let tag = ExplanationTag(rawValue: tagName.lowercased()) else {
            return nil
        }

        return (tag, string.index(after: closeBracket))
    }

    /// Apply inline styling for a given tag type.
    private static func applyStyle(for tag: ExplanationTag, to attr: inout AttributedString) {
        switch tag {
        case .hl:
            attr.font = .system(size: 13, weight: .semibold)
            attr.foregroundColor = Color(red: 0.80, green: 0.45, blue: 0.10)

        case .critical:
            attr.font = .system(size: 13, weight: .medium)
            attr.foregroundColor = Color(red: 0.75, green: 0.15, blue: 0.15)
            attr.backgroundColor = Color(red: 1.0, green: 0.93, blue: 0.92)

        case .tip:
            attr.font = .system(size: 13, weight: .medium)
            attr.foregroundColor = Color(red: 0.20, green: 0.55, blue: 0.25)
            attr.backgroundColor = Color(red: 0.93, green: 0.98, blue: 0.93)

        case .note:
            attr.font = .system(size: 13, weight: .medium)
            attr.foregroundColor = Color(red: 0.20, green: 0.40, blue: 0.70)
            attr.backgroundColor = Color(red: 0.93, green: 0.95, blue: 1.0)

        case .analogy:
            attr.font = .system(size: 13).italic()
            attr.foregroundColor = Color(red: 0.40, green: 0.30, blue: 0.65)

        case .flow, .tldr:
            // Block-level tags should not reach this function — they are
            // rendered by dedicated views. If they do, apply plain styling.
            attr.font = .system(size: 13)
        }
    }
}
