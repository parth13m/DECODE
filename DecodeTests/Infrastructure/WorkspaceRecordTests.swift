import Foundation
import Testing
import GRDB
@testable import Decode

/// Tests for WorkspaceRecord (T0.3) and v2_workspaces migration (T0.4).
struct WorkspaceRecordTests {

    // MARK: - Helpers

    private static func makeFileWorkspace(
        id: UUID = UUID(),
        rootPath: String = "/tmp/test.swift",
        rootFileName: String = "test.swift"
    ) -> Workspace {
        Workspace(
            id: id,
            kind: .file,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            bookmarkData: Data([0x01, 0x02]),
            rootPath: rootPath,
            rootFileName: rootFileName,
            summaryText: "A file workspace",
            isCorrupted: false
        )
    }

    private static func makeDirectoryWorkspace(
        id: UUID = UUID(),
        rootPath: String = "/tmp/project",
        rootFileName: String = "project"
    ) -> Workspace {
        Workspace(
            id: id,
            kind: .directory,
            createdAt: Date(timeIntervalSince1970: 2_000_000),
            updatedAt: Date(timeIntervalSince1970: 2_000_000),
            bookmarkData: Data([0x03, 0x04]),
            rootPath: rootPath,
            rootFileName: rootFileName,
            summaryText: "A directory workspace",
            isCorrupted: false
        )
    }

    /// Creates an in-memory database with all migrations applied.
    private static func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try DecodeDatabaseMigrator.migrate(db)
        return db
    }

    // MARK: - T0.3: WorkspaceRecord — Table Name

    @Test func tableName() {
        #expect(WorkspaceRecord.databaseTableName == "workspaces")
    }

    // MARK: - T0.3: WorkspaceRecord — Domain → Record

    @Test func fromDomain_file() {
        let id = UUID()
        let workspace = Self.makeFileWorkspace(id: id)
        let record = WorkspaceRecord(from: workspace)

        #expect(record.id == id.uuidString)
        #expect(record.kind == "file")
        #expect(record.rootPath == "/tmp/test.swift")
        #expect(record.rootFileName == "test.swift")
        #expect(record.summaryText == "A file workspace")
        #expect(record.isCorrupted == false)
        #expect(record.bookmarkData == Data([0x01, 0x02]))
    }

    @Test func fromDomain_directory() {
        let id = UUID()
        let workspace = Self.makeDirectoryWorkspace(id: id)
        let record = WorkspaceRecord(from: workspace)

        #expect(record.id == id.uuidString)
        #expect(record.kind == "directory")
        #expect(record.rootPath == "/tmp/project")
        #expect(record.rootFileName == "project")
        #expect(record.summaryText == "A directory workspace")
    }

    // MARK: - T0.3: WorkspaceRecord — Record → Domain

    @Test func toDomain_file() {
        let id = UUID()
        let workspace = Self.makeFileWorkspace(id: id)
        let record = WorkspaceRecord(from: workspace)
        let restored = record.toDomain()

        #expect(restored != nil)
        #expect(restored?.id == id)
        #expect(restored?.kind == .file)
        #expect(restored?.rootPath == "/tmp/test.swift")
        #expect(restored?.rootFileName == "test.swift")
        #expect(restored?.summaryText == "A file workspace")
        #expect(restored?.isCorrupted == false)
    }

    @Test func toDomain_directory() {
        let id = UUID()
        let workspace = Self.makeDirectoryWorkspace(id: id)
        let record = WorkspaceRecord(from: workspace)
        let restored = record.toDomain()

        #expect(restored != nil)
        #expect(restored?.kind == .directory)
        #expect(restored?.rootPath == "/tmp/project")
    }

    @Test func toDomain_invalidUUID() {
        var record = WorkspaceRecord(from: Self.makeFileWorkspace())
        record.id = "not-a-uuid"
        #expect(record.toDomain() == nil)
    }

    @Test func toDomain_invalidKind() {
        var record = WorkspaceRecord(from: Self.makeFileWorkspace())
        record.kind = "unknown"
        #expect(record.toDomain() == nil)
    }

    // MARK: - T0.3: WorkspaceRecord — Full Round-Trip

    @Test func domainRoundTrip() {
        let original = Self.makeFileWorkspace()
        let record = WorkspaceRecord(from: original)
        let restored = record.toDomain()

        #expect(restored == original)
    }

    // MARK: - T0.4: Migration — Table Exists

    @Test func migrationCreatesWorkspacesTable() throws {
        let db = try Self.makeDatabase()
        try db.read { db in
            let columns = try db.columns(in: "workspaces")
            let names = columns.map(\.name)

            #expect(names.contains("id"))
            #expect(names.contains("kind"))
            #expect(names.contains("createdAt"))
            #expect(names.contains("updatedAt"))
            #expect(names.contains("bookmarkData"))
            #expect(names.contains("rootPath"))
            #expect(names.contains("rootFileName"))
            #expect(names.contains("summaryText"))
            #expect(names.contains("isCorrupted"))
            #expect(columns.count == 9)
        }
    }

    // MARK: - T0.4: Migration — Sessions Table Dropped (v3)

    @Test func migrationDropsSessionsTable() throws {
        let db = try Self.makeDatabase()

        // After v3 migration, the sessions table should not exist.
        try db.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            #expect(!tables.contains("sessions"))
        }
    }

    // MARK: - T0.4: Migration — Unique rootPath Index

    @Test func uniqueRootPathConstraint() throws {
        let db = try Self.makeDatabase()

        let workspace1 = Self.makeFileWorkspace(rootPath: "/tmp/same.swift")
        let workspace2 = Self.makeFileWorkspace(rootPath: "/tmp/same.swift")

        try db.write { db in
            try WorkspaceRecord(from: workspace1).insert(db)
        }

        #expect(throws: (any Error).self) {
            try db.write { db in
                try WorkspaceRecord(from: workspace2).insert(db)
            }
        }
    }

    // MARK: - T0.4: Migration — DB Insert and Fetch

    @Test func dbInsertAndFetch() throws {
        let db = try Self.makeDatabase()
        let original = Self.makeDirectoryWorkspace()

        try db.write { db in
            try WorkspaceRecord(from: original).insert(db)
        }

        let fetched = try db.read { db in
            try WorkspaceRecord
                .filter(Column("id") == original.id.uuidString)
                .fetchOne(db)
        }

        #expect(fetched != nil)
        let restored = fetched?.toDomain()
        #expect(restored == original)
    }
}
