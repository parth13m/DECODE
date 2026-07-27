import Foundation
import GRDB

/// GRDB record type for the `workspaces` table.
///
/// Maps between the Domain `Workspace` model and the database row.
/// Uses `uuidString` for the primary key since GRDB stores UUIDs as TEXT.
///
/// Follows the same pattern as `SessionRecord`.
struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workspaces"

    var id: String
    var kind: String
    var createdAt: Date
    var updatedAt: Date
    var bookmarkData: Data
    var rootPath: String
    var rootFileName: String
    var summaryText: String
    var isCorrupted: Bool

    // MARK: - Domain ↔ Record Mapping

    init(from workspace: Workspace) {
        self.id = workspace.id.uuidString
        self.kind = workspace.kind.rawValue
        self.createdAt = workspace.createdAt
        self.updatedAt = workspace.updatedAt
        self.bookmarkData = workspace.bookmarkData
        self.rootPath = workspace.rootPath
        self.rootFileName = workspace.rootFileName
        self.summaryText = workspace.summaryText
        self.isCorrupted = workspace.isCorrupted
    }

    func toDomain() -> Workspace? {
        guard let uuid = UUID(uuidString: id),
              let workspaceKind = WorkspaceKind(rawValue: kind)
        else { return nil }

        return Workspace(
            id: uuid,
            kind: workspaceKind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            bookmarkData: bookmarkData,
            rootPath: rootPath,
            rootFileName: rootFileName,
            summaryText: summaryText,
            isCorrupted: isCorrupted
        )
    }
}
