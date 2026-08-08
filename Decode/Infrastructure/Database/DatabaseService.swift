import Foundation
import GRDB

/// Concrete GRDB-backed implementation of DatabaseServiceProtocol.
///
/// Uses a DatabasePool in WAL mode for concurrent read access during
/// background writes. All methods are nonisolated and thread-safe via
/// GRDB's internal serialization.
///
/// The database file is stored at `~/Library/Application Support/Decode/decode.sqlite3`.
final class DatabaseService: DatabaseServiceProtocol, Sendable {

    private let dbPool: DatabasePool

    /// Initialize with a specific database path.
    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("[SQL] \($0)") }
        }
        #endif

        dbPool = try DatabasePool(path: path, configuration: config)
        try DecodeDatabaseMigrator.migrate(dbPool)
    }

    /// Initialize with the default application support directory.
    convenience init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode", isDirectory: true)

        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        let dbPath = appSupport.appendingPathComponent("decode.sqlite3").path
        try self.init(path: dbPath)
    }

    // MARK: - Workspaces

    func createWorkspace(_ workspace: Workspace) async throws {
        let record = WorkspaceRecord(from: workspace)
        try await dbPool.write { db in
            try record.insert(db)
        }
    }

    func fetchWorkspace(id: UUID) async throws -> Workspace? {
        try await dbPool.read { db in
            try WorkspaceRecord
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)?
                .toDomain()
        }
    }

    func fetchAllWorkspaces() async throws -> [Workspace] {
        try await dbPool.read { db in
            try WorkspaceRecord
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
        let record = WorkspaceRecord(from: workspace)
        try await dbPool.write { db in
            try record.update(db)
        }
    }

    func deleteWorkspace(id: UUID) async throws {
        try await dbPool.write { db in
            _ = try WorkspaceRecord
                .filter(Column("id") == id.uuidString)
                .deleteAll(db)
        }
    }

    // MARK: - Entities

    func createEntity(_ entity: CodeEntity) async throws {
        let record = EntityRecord(from: entity)
        try await dbPool.write { db in
            try record.insert(db)
        }
    }

    func fetchEntities(sessionId: UUID) async throws -> [CodeEntity] {
        try await dbPool.read { db in
            try EntityRecord
                .filter(Column("sessionId") == sessionId.uuidString)
                .order(Column("name"))
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    func fetchEntity(id: UUID) async throws -> CodeEntity? {
        try await dbPool.read { db in
            try EntityRecord
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)?
                .toDomain()
        }
    }

    func fetchEntity(stableId: String, sessionId: UUID) async throws -> CodeEntity? {
        try await dbPool.read { db in
            try EntityRecord
                .filter(Column("stableId") == stableId && Column("sessionId") == sessionId.uuidString)
                .fetchOne(db)?
                .toDomain()
        }
    }

    func updateEntity(_ entity: CodeEntity) async throws {
        let record = EntityRecord(from: entity)
        try await dbPool.write { db in
            try record.update(db)
        }
    }

    func deleteEntity(id: UUID) async throws {
        try await dbPool.write { db in
            _ = try EntityRecord
                .filter(Column("id") == id.uuidString)
                .deleteAll(db)
        }
    }

    func deleteEntities(ids: [UUID]) async throws {
        let idStrings = ids.map { $0.uuidString }
        try await dbPool.write { db in
            _ = try EntityRecord
                .filter(idStrings.contains(Column("id")))
                .deleteAll(db)
        }
    }

    // MARK: - Entity Dependencies (not implemented yet)

    func createDependency(_ dependency: EntityDependency) async throws {
        fatalError("Entity dependencies not implemented in persistence milestone")
    }

    func fetchDependencies(parentId: UUID) async throws -> [EntityDependency] {
        return []
    }

    func fetchDependents(childId: UUID) async throws -> [EntityDependency] {
        return []
    }

    func deleteDependencies(parentId: UUID) async throws {}

    func replaceDependencies(parentId: UUID, newDependencies: [EntityDependency]) async throws {
        fatalError("Entity dependencies not implemented in persistence milestone")
    }

    // MARK: - Messages (not implemented yet)

    func createMessage(_ message: ChatMessage) async throws {
        fatalError("Messages not implemented in persistence milestone")
    }

    func fetchMessages(sessionId: UUID) async throws -> [ChatMessage] {
        return []
    }

    func deleteMessages(sessionId: UUID) async throws {}

    // MARK: - Notes

    func createNote(_ note: Note) async throws {
        let record = NoteRecord(from: note)
        try await dbPool.write { db in
            try record.insert(db)
        }
    }

    func fetchAllNotes() async throws -> [Note] {
        try await dbPool.read { db in
            try NoteRecord
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    func deleteNote(id: UUID) async throws {
        try await dbPool.write { db in
            _ = try NoteRecord
                .filter(Column("id") == id.uuidString)
                .deleteAll(db)
        }
    }

    // MARK: - Profile Observations

    func createProfileObservation(_ observation: ProfileObservation) async throws {
        let record = ProfileObservationRecord(from: observation)
        try await dbPool.write { db in
            try record.insert(db)
        }
    }

    func fetchAllProfileObservations() async throws -> [ProfileObservation] {
        try await dbPool.read { db in
            try ProfileObservationRecord
                .order(Column("timestamp").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    func fetchProfileObservations(since date: Date) async throws -> [ProfileObservation] {
        try await dbPool.read { db in
            try ProfileObservationRecord
                .filter(Column("timestamp") >= date)
                .order(Column("timestamp").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    func countProfileObservations() async throws -> Int {
        try await dbPool.read { db in
            try ProfileObservationRecord.fetchCount(db)
        }
    }

    func deleteAllProfileObservations() async throws {
        try await dbPool.write { db in
            _ = try ProfileObservationRecord.deleteAll(db)
        }
    }
}
