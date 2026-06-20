import Foundation
import GRDB

/// GRDB record type for the `sessions` table.
///
/// Maps between the Domain `Session` model and the database row.
/// Uses `uuidString` for the primary key since GRDB stores UUIDs as TEXT.
struct SessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"

    var id: String
    var createdAt: Date
    var updatedAt: Date
    var bookmarkData: Data
    var filePath: String
    var fileName: String
    var fileSize: Int
    var fileModifiedAt: Date
    var fileHash: String
    var summaryText: String
    var isCorrupted: Bool

    // MARK: - Domain ↔ Record Mapping

    init(from session: Session) {
        self.id = session.id.uuidString
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.bookmarkData = session.bookmarkData
        self.filePath = session.filePath
        self.fileName = session.fileName
        self.fileSize = session.fileSize
        self.fileModifiedAt = session.fileModifiedAt
        self.fileHash = session.fileHash
        self.summaryText = session.summaryText
        self.isCorrupted = session.isCorrupted
    }

    func toDomain() -> Session? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Session(
            id: uuid,
            createdAt: createdAt,
            updatedAt: updatedAt,
            bookmarkData: bookmarkData,
            filePath: filePath,
            fileName: fileName,
            fileSize: fileSize,
            fileModifiedAt: fileModifiedAt,
            fileHash: fileHash,
            summaryText: summaryText,
            isCorrupted: isCorrupted
        )
    }
}
