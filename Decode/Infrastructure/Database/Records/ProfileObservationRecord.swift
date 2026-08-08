import Foundation
import GRDB

/// GRDB record type for the `profile_observations` table.
///
/// Maps between the Domain `ProfileObservation` model and the database row.
/// Follows the same pattern as `WorkspaceRecord`, `EntityRecord`, `NoteRecord`.
struct ProfileObservationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profile_observations"

    var id: String
    var timestamp: Date
    var observationType: String
    var mode: String
    var isFollowUp: Bool
    var schemaVersion: Int
    var filePath: String?
    var fileName: String?
    var entityName: String?
    var entityType: String?
    var moduleName: String?
    var layer: String?
    var fileRole: String?
    var language: String?
    var sourceApp: String?
    var workspaceID: String?

    // MARK: - Domain ↔ Record Mapping

    init(from observation: ProfileObservation) {
        self.id = observation.id.uuidString
        self.timestamp = observation.timestamp
        self.observationType = observation.observationType.rawValue
        self.mode = observation.mode
        self.isFollowUp = observation.isFollowUp
        self.schemaVersion = observation.schemaVersion
        self.filePath = observation.filePath
        self.fileName = observation.fileName
        self.entityName = observation.entityName
        self.entityType = observation.entityType
        self.moduleName = observation.moduleName
        self.layer = observation.layer
        self.fileRole = observation.fileRole
        self.language = observation.language
        self.sourceApp = observation.sourceApp
        self.workspaceID = observation.workspaceID
    }

    func toDomain() -> ProfileObservation? {
        guard let uuid = UUID(uuidString: id),
              let type = ProfileObservationType(rawValue: observationType)
        else { return nil }

        return ProfileObservation(
            id: uuid,
            timestamp: timestamp,
            observationType: type,
            mode: mode,
            isFollowUp: isFollowUp,
            schemaVersion: schemaVersion,
            filePath: filePath,
            fileName: fileName,
            entityName: entityName,
            entityType: entityType,
            moduleName: moduleName,
            layer: layer,
            fileRole: fileRole,
            language: language,
            sourceApp: sourceApp,
            workspaceID: workspaceID
        )
    }
}
