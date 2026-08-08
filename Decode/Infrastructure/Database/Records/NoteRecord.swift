import Foundation
import GRDB

/// GRDB record type for the `notes` index table.
///
/// Stores metadata only — the canonical note content lives in a Markdown
/// file on disk. The ``fileName`` field is the relative file name within
/// the Notes directory.
struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"

    var id: String
    var title: String
    var fileName: String
    var language: String?
    var mode: String?
    var workspacePath: String?
    var filePath: String?
    var createdAt: Date

    // MARK: - Domain ↔ Record Mapping

    init(from note: Note) {
        self.id = note.id.uuidString
        self.title = note.title
        self.fileName = note.fileName
        self.language = note.language
        self.mode = note.mode
        self.workspacePath = note.workspacePath
        self.filePath = note.filePath
        self.createdAt = note.createdAt
    }

    func toDomain() -> Note? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        // Content is loaded from the Markdown file, not the database.
        return Note(
            id: uuid,
            title: title,
            fileName: fileName,
            selectedCode: "",
            explanation: "",
            language: language,
            mode: mode,
            workspacePath: workspacePath,
            filePath: filePath,
            createdAt: createdAt
        )
    }
}
