import Foundation
import GRDB

/// GRDB record type for the `entities` table.
///
/// Maps between the Domain `CodeEntity` model and the database row.
struct EntityRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entities"

    var id: String
    var sessionId: String
    var stableId: String
    var entityType: String
    var name: String
    var summaryText: String
    var hash: String
    var lastUpdated: Date

    // MARK: - Domain ↔ Record Mapping

    init(from entity: CodeEntity) {
        self.id = entity.id.uuidString
        self.sessionId = entity.sessionId.uuidString
        self.stableId = entity.stableId
        self.entityType = entity.entityType.rawValue
        self.name = entity.name
        self.summaryText = entity.summaryText
        self.hash = entity.hash
        self.lastUpdated = entity.lastUpdated
    }

    func toDomain() -> CodeEntity? {
        guard let uuid = UUID(uuidString: id),
              let sessUUID = UUID(uuidString: sessionId),
              let type = EntityType(rawValue: entityType)
        else { return nil }

        return CodeEntity(
            id: uuid,
            sessionId: sessUUID,
            stableId: stableId,
            entityType: type,
            name: name,
            summaryText: summaryText,
            hash: hash,
            lastUpdated: lastUpdated
        )
    }
}
