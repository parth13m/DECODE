import Foundation
import GRDB

/// Manages database schema migrations using GRDB's DatabaseMigrator.
///
/// Migration v1 creates the initial schema: sessions and entities tables
/// with appropriate indexes and foreign key constraints.
struct DecodeDatabaseMigrator {

    /// Register all migrations and run them against the database.
    static func migrate(_ db: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        // In debug builds, erase the database on schema change for easy iteration.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            // Sessions table
            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("bookmarkData", .blob).notNull()
                t.column("filePath", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("fileModifiedAt", .datetime).notNull()
                t.column("fileHash", .text).notNull()
                t.column("summaryText", .text).notNull().defaults(to: "")
                t.column("isCorrupted", .boolean).notNull().defaults(to: false)
            }

            // Entities table
            try db.create(table: "entities") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionId", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("stableId", .text).notNull()
                t.column("entityType", .text).notNull()
                t.column("name", .text).notNull()
                t.column("summaryText", .text).notNull().defaults(to: "")
                t.column("hash", .text).notNull()
                t.column("lastUpdated", .datetime).notNull()
            }

            // Index for fast entity lookup by session
            try db.create(
                index: "idx_entities_sessionId",
                on: "entities",
                columns: ["sessionId"]
            )

            // Index for stable ID lookups within a session
            try db.create(
                index: "idx_entities_stableId_sessionId",
                on: "entities",
                columns: ["stableId", "sessionId"],
                unique: true
            )
        }

        try migrator.migrate(db)
    }
}
