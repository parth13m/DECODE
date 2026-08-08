import SwiftUI

/// Renders a single saved note as a readable document.
struct NoteDetailView: View {

    let note: Note

    // Decode palette
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.45, green: 0.44, blue: 0.42)
    private let codeBg = Color(red: 0.96, green: 0.955, blue: 0.94)
    private let codeBorder = Color(red: 0.91, green: 0.90, blue: 0.88)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: - Title

                Text(note.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
                    .padding(.bottom, 8)

                // MARK: - Date & Metadata

                HStack(spacing: 6) {
                    Text(note.createdAt, format: .dateTime.month(.wide).day().year())
                        .font(.system(size: 13))
                        .foregroundStyle(textSecondary)

                    if let language = note.language {
                        Text("\u{00B7}")
                            .foregroundStyle(textSecondary)
                        Text(language)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(accentOrange)
                    }

                    if let mode = note.mode {
                        Text("\u{00B7}")
                            .foregroundStyle(textSecondary)
                        Text(mode.capitalized)
                            .font(.system(size: 13))
                            .foregroundStyle(textSecondary)
                    }

                    if let filePath = note.filePath {
                        Text("\u{00B7}")
                            .foregroundStyle(textSecondary)
                        Text(URL(fileURLWithPath: filePath).lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundStyle(textSecondary)
                    }
                }
                .padding(.bottom, 24)

                Divider()
                    .overlay(codeBorder)
                    .padding(.bottom, 24)

                // MARK: - Selected Code

                if !note.selectedCode.isEmpty {
                    Text("Selected Code")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(textPrimary)
                        .padding(.bottom, 10)

                    ScrollView([.horizontal, .vertical]) {
                        Text(note.selectedCode)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.22))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxHeight: 260)
                    .background(codeBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(codeBorder, lineWidth: 1)
                    )
                    .padding(.bottom, 28)
                }

                // MARK: - Explanation

                if !note.explanation.isEmpty {
                    Text("Explanation")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(textPrimary)
                        .padding(.bottom, 10)

                    Text(note.explanation)
                        .font(.system(size: 13.5))
                        .foregroundStyle(textPrimary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(warmBackground)
    }
}
