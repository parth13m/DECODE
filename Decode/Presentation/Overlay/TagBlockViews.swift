import SwiftUI

/// Block-level TLDR summary card.
///
/// Rendered as a full-width card with a left accent border, warm cream
/// background, and summary icon. Appears at the top of the explanation.
struct TLDRBlockView: View {
    let content: String

    // Match HUD's existing color palette.
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBackground = Color(red: 0.97, green: 0.95, blue: 0.92)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentOrange)
                .padding(.top, 2)

            Text(content)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentOrange)
                .frame(width: 3)
        }
    }
}

/// Block-level execution/data flow card.
///
/// Rendered as a full-width card with monospaced text and a subtle gray
/// background. Preserves the arrow separators from the LLM output.
/// Also used for V7-detected workflows, hierarchies, and branching
/// flowcharts that are auto-routed here by the block detection stage.
struct FlowBlockView: View {
    let content: String

    private let cardBackground = Color(red: 0.95, green: 0.94, blue: 0.93)

    var body: some View {
        Text(content)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.35))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Block-level fenced code block.
///
/// Rendered with monospaced font, subtle background, and optional
/// language label. Preserves indentation and line breaks.
struct CodeBlockView: View {
    let language: String?
    let code: String

    private let cardBackground = Color(red: 0.95, green: 0.94, blue: 0.93)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.25))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, language != nil ? 6 : 10)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Block-level markdown table.
///
/// Rendered with a header row, separator, and data rows. Columns
/// expand equally. Long text wraps within cells. Cell content
/// supports inline Markdown (bold, inline code).
struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    private let headerBackground = Color(red: 0.93, green: 0.92, blue: 0.90)
    private let borderColor = Color(red: 0.88, green: 0.87, blue: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row.
            HStack(spacing: 0) {
                ForEach(headers.indices, id: \.self) { i in
                    cellText(headers[i], weight: .semibold)
                    if i < headers.count - 1 {
                        Divider()
                    }
                }
            }
            .background(headerBackground)

            Divider().overlay(borderColor)

            // Data rows.
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 0) {
                    ForEach(headers.indices, id: \.self) { colIdx in
                        let value = colIdx < rows[rowIdx].count
                            ? rows[rowIdx][colIdx] : ""
                        cellText(value, weight: .regular)
                        if colIdx < headers.count - 1 {
                            Divider()
                        }
                    }
                }
                if rowIdx < rows.count - 1 {
                    Divider().overlay(borderColor)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func cellText(_ text: String, weight: Font.Weight) -> some View {
        Text(Self.inlineMarkdown(text))
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    /// Parse cell text as inline Markdown for bold, code spans, etc.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        if let md = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return md
        }
        return AttributedString(text)
    }
}
