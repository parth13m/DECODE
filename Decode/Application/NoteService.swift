import Foundation

/// Saves and manages explanation notes as Markdown files.
///
/// Notes are stored as `.md` files in `~/Library/Application Support/Decode/Notes/`.
/// SQLite stores only index metadata for fast lookup. The Markdown file is the
/// canonical source of truth.
@MainActor
final class NoteService {

    private let database: DatabaseServiceProtocol
    private let notesDirectory: URL

    init(database: DatabaseServiceProtocol) {
        self.database = database

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode/Notes", isDirectory: true)

        self.notesDirectory = appSupport

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Save

    /// Save a note from the current explanation HUD state.
    func saveNote(
        selectedCode: String,
        explanation: String,
        language: String?,
        mode: String?,
        workspacePath: String?,
        filePath: String?
    ) async throws -> Note {
        let now = Date()
        let title = generateTitle(from: selectedCode, filePath: filePath)
        let fileName = generateFileName(title: title, date: now)
        let id = UUID()

        let note = Note(
            id: id,
            title: title,
            fileName: fileName,
            selectedCode: selectedCode,
            explanation: explanation,
            language: language,
            mode: mode,
            workspacePath: workspacePath,
            filePath: filePath,
            createdAt: now
        )

        // Write the Markdown file.
        let markdown = renderMarkdown(note)
        let fileURL = notesDirectory.appendingPathComponent(fileName)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        // Index in SQLite.
        try await database.createNote(note)

        return note
    }

    // MARK: - Fetch

    /// Fetch all notes with their content loaded from Markdown files.
    func allNotes() async throws -> [Note] {
        let indexEntries = try await database.fetchAllNotes()

        return indexEntries.compactMap { entry in
            let fileURL = notesDirectory.appendingPathComponent(entry.fileName)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return nil
            }
            let (code, explanation) = parseMarkdownContent(content)
            return Note(
                id: entry.id,
                title: entry.title,
                fileName: entry.fileName,
                selectedCode: code,
                explanation: explanation,
                language: entry.language,
                mode: entry.mode,
                workspacePath: entry.workspacePath,
                filePath: entry.filePath,
                createdAt: entry.createdAt
            )
        }
    }

    // MARK: - Delete

    func deleteNote(_ note: Note) async throws {
        // Delete the Markdown file.
        let fileURL = notesDirectory.appendingPathComponent(note.fileName)
        try? FileManager.default.removeItem(at: fileURL)

        // Remove from index.
        try await database.deleteNote(id: note.id)
    }

    // MARK: - Title Generation

    /// Generate a title from the code content or file path.
    private func generateTitle(from code: String, filePath: String?) -> String {
        // Try to extract a function/class/struct name from the first few lines.
        let lines = code.components(separatedBy: "\n").prefix(10)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match common declaration patterns.
            for keyword in ["func ", "class ", "struct ", "enum ", "protocol ", "def ", "function ", "const ", "let ", "var "] {
                if trimmed.hasPrefix(keyword) || trimmed.hasPrefix("private \(keyword)") ||
                   trimmed.hasPrefix("public \(keyword)") || trimmed.hasPrefix("internal \(keyword)") {
                    // Extract the name (word after the keyword).
                    let afterKeyword: String
                    if let range = trimmed.range(of: keyword) {
                        afterKeyword = String(trimmed[range.upperBound...])
                    } else {
                        continue
                    }
                    let name = afterKeyword.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted).first ?? ""
                    if !name.isEmpty {
                        return name
                    }
                }
            }
        }

        // Fall back to file name without extension.
        if let filePath {
            let fileName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            if !fileName.isEmpty {
                return fileName
            }
        }

        // Last resort.
        return "Note"
    }

    // MARK: - File Name Generation

    private func generateFileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dateStr = formatter.string(from: date)

        // Sanitize title for file system.
        let sanitized = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            .prefix(50)

        return "\(dateStr)-\(sanitized).md"
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ note: Note) -> String {
        var md = "# \(note.title)\n\n"

        if let filePath = note.filePath {
            md += "**File:** `\(filePath)`\n\n"
        }

        if let language = note.language {
            md += "**Language:** \(language)\n\n"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        md += "**Date:** \(formatter.string(from: note.createdAt))\n\n"

        md += "---\n\n"
        md += "## Code\n\n"
        md += "```\(note.language ?? "")\n"
        md += note.selectedCode
        if !note.selectedCode.hasSuffix("\n") {
            md += "\n"
        }
        md += "```\n\n"

        md += "## Explanation\n\n"
        md += note.explanation
        if !note.explanation.hasSuffix("\n") {
            md += "\n"
        }

        return md
    }

    // MARK: - Markdown Parsing

    /// Extract code and explanation from a saved Markdown note.
    private func parseMarkdownContent(_ content: String) -> (code: String, explanation: String) {
        var code = ""
        var explanation = ""

        // Extract code block between ```...```
        if let codeStart = content.range(of: "## Code\n\n```"),
           let fenceEnd = content.range(of: "\n", range: codeStart.upperBound..<content.endIndex),
           let codeEnd = content.range(of: "\n```\n", range: fenceEnd.upperBound..<content.endIndex) {
            code = String(content[fenceEnd.upperBound..<codeEnd.lowerBound])
        }

        // Extract explanation after "## Explanation\n\n"
        if let explStart = content.range(of: "## Explanation\n\n") {
            explanation = String(content[explStart.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (code, explanation)
    }
}
