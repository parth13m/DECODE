// WorkspaceManagerTests.swift — DecodeTests
// Unit tests for WorkspaceManager (W1).

import Testing
import Foundation
import GRDB
@testable import Decode

// MARK: - Test Helpers

/// Creates a temporary Swift file with the given content.
/// Returns the file URL. Caller is responsible for cleanup.
@MainActor
private func createTempSwiftFile(
    name: String = "TestFile.swift",
    content: String = "struct Hello {\n    func greet() { }\n}\n"
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(name)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

/// Removes a temporary file and its parent directory.
private func cleanupTempFile(_ url: URL) {
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: dir)
}

/// Creates a temporary session state file URL for test isolation.
private func makeTempSessionStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-ss-\(UUID().uuidString).json")
}

/// Cleans up a temporary session state file.
private func cleanupSessionStateFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Creates an in-memory database with all migrations applied.
private func makeInMemoryDatabase() throws -> DatabaseService {
    // Use a temporary file-based DB since DatabaseService uses DatabasePool
    // which requires a file path.
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-db-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let dbPath = tmpDir.appendingPathComponent("test.sqlite3").path
    return try DatabaseService(path: dbPath)
}

// MARK: - WorkspaceManager Lifecycle Tests

@Suite(.serialized)
struct WorkspaceManagerLifecycleTests {

    // MARK: - Create File Workspace

    @Test @MainActor func createFileWorkspace_createsAndActivates() async throws {
        let manager = WorkspaceManager()
        let fileURL = try createTempSwiftFile()
        defer { cleanupTempFile(fileURL) }

        try await manager.createFileWorkspace(url: fileURL)

        #expect(manager.workspaces.count == 1)
        #expect(manager.activeWorkspaceId != nil)

        let managed = manager.activeWorkspace
        #expect(managed != nil)
        #expect(managed?.workspace.kind == .file)
        #expect(managed?.workspace.rootPath == fileURL.path)
        #expect(managed?.workspace.rootFileName == fileURL.lastPathComponent)
        #expect(managed?.isFileAccessible == true)
    }

    @Test @MainActor func createFileWorkspace_parsesEntities() async throws {
        let manager = WorkspaceManager()
        let content = "struct Greeting {\n    func sayHello() { }\n}\n"
        let fileURL = try createTempSwiftFile(content: content)
        defer { cleanupTempFile(fileURL) }

        try await manager.createFileWorkspace(url: fileURL)

        let managed = manager.activeWorkspace
        #expect(managed != nil)
        #expect(!managed!.parsedEntities.isEmpty)

        let entityNames = managed!.parsedEntities.map(\.entity.name)
        #expect(entityNames.contains("Greeting"))
    }

    @Test @MainActor func createFileWorkspace_buildsIntelligence() async throws {
        let manager = WorkspaceManager()
        let fileURL = try createTempSwiftFile()
        defer { cleanupTempFile(fileURL) }

        try await manager.createFileWorkspace(url: fileURL)

        let managed = manager.activeWorkspace
        #expect(managed?.fileIntelligence != nil)
        #expect(managed?.fileIntelligence?.fileName == fileURL.lastPathComponent)
    }

    @Test @MainActor func createFileWorkspace_reactivatesExisting() async throws {
        let manager = WorkspaceManager()
        let fileURL = try createTempSwiftFile()
        defer { cleanupTempFile(fileURL) }

        try await manager.createFileWorkspace(url: fileURL)
        let firstId = manager.activeWorkspaceId

        // Create a second workspace.
        let fileURL2 = try createTempSwiftFile(name: "Other.swift")
        defer { cleanupTempFile(fileURL2) }
        try await manager.createFileWorkspace(url: fileURL2)
        #expect(manager.workspaces.count == 2)

        // Re-opening the first file should reactivate, not create a new one.
        try await manager.createFileWorkspace(url: fileURL)
        #expect(manager.workspaces.count == 2)
        #expect(manager.activeWorkspaceId == firstId)
    }

    @Test @MainActor func createFileWorkspace_rejectsTooLargeFile() async throws {
        let manager = WorkspaceManager()
        // Create a file > 512 KB.
        let largeContent = String(repeating: "a", count: 513 * 1024)
        let fileURL = try createTempSwiftFile(content: largeContent)
        defer { cleanupTempFile(fileURL) }

        var didThrow = false
        do {
            try await manager.createFileWorkspace(url: fileURL)
        } catch is WorkspaceError {
            didThrow = true
        }
        #expect(didThrow)
        #expect(manager.workspaces.isEmpty)
    }

    // MARK: - Activate

    @Test @MainActor func activateWorkspace_setsActiveId() async throws {
        let manager = WorkspaceManager()
        let file1 = try createTempSwiftFile(name: "A.swift")
        let file2 = try createTempSwiftFile(name: "B.swift")
        defer { cleanupTempFile(file1); cleanupTempFile(file2) }

        try await manager.createFileWorkspace(url: file1)
        let id1 = manager.activeWorkspaceId!
        try await manager.createFileWorkspace(url: file2)
        #expect(manager.activeWorkspaceId != id1)

        manager.activateWorkspace(id: id1)
        #expect(manager.activeWorkspaceId == id1)
    }

    @Test @MainActor func activateWorkspace_ignoresUnknownId() async throws {
        let manager = WorkspaceManager()
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        let originalId = manager.activeWorkspaceId

        manager.activateWorkspace(id: UUID())
        #expect(manager.activeWorkspaceId == originalId)
    }

    // MARK: - Pin / Unpin

    @Test @MainActor func pinWorkspace_setsPinnedId() async throws {
        let manager = WorkspaceManager()
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        let id = manager.activeWorkspaceId!

        #expect(manager.pinnedWorkspaceId == nil)
        manager.pinWorkspace(id: id)
        #expect(manager.pinnedWorkspaceId == id)
    }

    @Test @MainActor func unpinWorkspace_clearsPinnedId() async throws {
        let manager = WorkspaceManager()
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        manager.pinWorkspace(id: manager.activeWorkspaceId!)
        #expect(manager.pinnedWorkspaceId != nil)

        manager.unpinWorkspace()
        #expect(manager.pinnedWorkspaceId == nil)
    }

    @Test @MainActor func pinWorkspace_ignoresUnknownId() async throws {
        let manager = WorkspaceManager()
        manager.pinWorkspace(id: UUID())
        #expect(manager.pinnedWorkspaceId == nil)
    }

    // MARK: - Close

    @Test @MainActor func closeWorkspace_removesFromMemory() async throws {
        let manager = WorkspaceManager()
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        let id = manager.activeWorkspaceId!
        #expect(manager.workspaces.count == 1)

        manager.closeWorkspace(id: id)
        #expect(manager.workspaces.isEmpty)
    }

    @Test @MainActor func closeWorkspace_clearsPinIfPinned() async throws {
        let manager = WorkspaceManager()
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        let id = manager.activeWorkspaceId!
        manager.pinWorkspace(id: id)
        #expect(manager.pinnedWorkspaceId == id)

        manager.closeWorkspace(id: id)
        #expect(manager.pinnedWorkspaceId == nil)
    }

    @Test @MainActor func closeWorkspace_activatesNextMostRecent() async throws {
        let manager = WorkspaceManager()
        let file1 = try createTempSwiftFile(name: "First.swift")
        let file2 = try createTempSwiftFile(name: "Second.swift")
        defer { cleanupTempFile(file1); cleanupTempFile(file2) }

        try await manager.createFileWorkspace(url: file1)
        let id1 = manager.activeWorkspaceId!
        try await manager.createFileWorkspace(url: file2)
        let id2 = manager.activeWorkspaceId!

        // Close the active one (id2) → id1 should become active.
        manager.closeWorkspace(id: id2)
        #expect(manager.activeWorkspaceId == id1)
    }

    @Test @MainActor func closeWorkspace_clearsActiveWhenLastClosed() async throws {
        let manager = WorkspaceManager()
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        let id = manager.activeWorkspaceId!

        manager.closeWorkspace(id: id)
        #expect(manager.activeWorkspaceId == nil)
    }

    // MARK: - Ordered Workspaces

    @Test @MainActor func orderedWorkspaces_sortedByUpdatedAt() async throws {
        let manager = WorkspaceManager()
        let file1 = try createTempSwiftFile(name: "Alpha.swift")
        let file2 = try createTempSwiftFile(name: "Beta.swift")
        defer { cleanupTempFile(file1); cleanupTempFile(file2) }

        try await manager.createFileWorkspace(url: file1)
        try await manager.createFileWorkspace(url: file2)

        let ordered = manager.orderedWorkspaces
        #expect(ordered.count == 2)
        // Most recently created (file2) should be first.
        #expect(ordered[0].workspace.rootFileName == "Beta.swift")
        #expect(ordered[1].workspace.rootFileName == "Alpha.swift")
    }
}

// MARK: - Database Persistence Tests

@Suite(.serialized)
struct WorkspaceManagerPersistenceTests {

    @Test @MainActor func createFileWorkspace_persistsToDatabase() async throws {
        let db = try makeInMemoryDatabase()
        let ssURL = makeTempSessionStateURL()
        defer { cleanupSessionStateFile(ssURL) }
        let manager = WorkspaceManager(database: db, sessionStateURL: ssURL)
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)

        let stored = try await db.fetchAllWorkspaces()
        #expect(stored.count == 1)
        #expect(stored[0].kind == .file)
        #expect(stored[0].rootPath == file.path)
        #expect(stored[0].rootFileName == file.lastPathComponent)
    }

    @Test @MainActor func restoreWorkspaces_loadsFromDatabase() async throws {
        let db = try makeInMemoryDatabase()
        let ssURL = makeTempSessionStateURL()
        defer { cleanupSessionStateFile(ssURL) }

        // Create and close a workspace.
        let file = try createTempSwiftFile(name: "Persistent.swift", content: "class Foo {}\n")
        defer { cleanupTempFile(file) }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: ssURL)
        try await manager1.createFileWorkspace(url: file)
        let originalId = manager1.activeWorkspaceId!
        // Simulate app shutdown — drop all in-memory state.

        // New manager instance — simulates app restart.
        // Uses the same session state URL so it reads the saved state.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: ssURL)
        #expect(manager2.workspaces.isEmpty)

        await manager2.restoreWorkspaces()
        #expect(manager2.workspaces.count == 1)
        #expect(manager2.activeWorkspaceId == originalId)

        let restored = manager2.workspaces[originalId]
        #expect(restored?.workspace.rootFileName == "Persistent.swift")
        #expect(restored?.workspace.kind == .file)
        // Entities should be re-parsed on restore.
        #expect(!restored!.parsedEntities.isEmpty)
    }

    @Test @MainActor func restoreWorkspaces_skipsDeletedFiles() async throws {
        let db = try makeInMemoryDatabase()
        let ssURL = makeTempSessionStateURL()
        defer { cleanupSessionStateFile(ssURL) }
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: ssURL)
        try await manager1.createFileWorkspace(url: file)

        // Delete the file before restore.
        try FileManager.default.removeItem(at: file)

        let manager2 = WorkspaceManager(database: db, sessionStateURL: ssURL)
        await manager2.restoreWorkspaces()
        #expect(manager2.workspaces.isEmpty)
    }

    @Test @MainActor func closeWorkspace_preservesInDatabase() async throws {
        let db = try makeInMemoryDatabase()
        let ssURL = makeTempSessionStateURL()
        defer { cleanupSessionStateFile(ssURL) }
        let manager = WorkspaceManager(database: db, sessionStateURL: ssURL)
        let file = try createTempSwiftFile()
        defer { cleanupTempFile(file) }

        try await manager.createFileWorkspace(url: file)
        let id = manager.activeWorkspaceId!

        manager.closeWorkspace(id: id)
        #expect(manager.workspaces.isEmpty)

        // Should still be in the database.
        let stored = try await db.fetchAllWorkspaces()
        #expect(stored.count == 1)
    }
}

// MARK: - WorkspaceError Tests

struct WorkspaceErrorTests {

    @Test func fileTooLargeDescription() {
        let error = WorkspaceError.fileTooLarge
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("512"))
    }

    @Test func binaryFileDescription() {
        let error = WorkspaceError.binaryFile
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("binary"))
    }
}

// MARK: - ManagedWorkspace Tests

struct ManagedWorkspaceTests {

    @Test @MainActor func identifiable() {
        let id = UUID()
        let workspace = Workspace(
            id: id,
            kind: .file,
            createdAt: .now,
            updatedAt: .now,
            bookmarkData: Data(),
            rootPath: "/tmp/test.swift",
            rootFileName: "test.swift",
            summaryText: "",
            isCorrupted: false
        )
        let managed = ManagedWorkspace(workspace: workspace, parsedEntities: [])
        #expect(managed.id == id)
    }

    @Test @MainActor func defaultState() {
        let workspace = Workspace(
            id: UUID(),
            kind: .file,
            createdAt: .now,
            updatedAt: .now,
            bookmarkData: Data(),
            rootPath: "/tmp/test.swift",
            rootFileName: "test.swift",
            summaryText: "",
            isCorrupted: false
        )
        let managed = ManagedWorkspace(workspace: workspace, parsedEntities: [])
        #expect(managed.isFileAccessible == true)
        #expect(managed.fileIntelligence == nil)
        #expect(managed.lastRefreshedAt != nil)
    }
}

// MARK: - Database CRUD Tests

@Suite(.serialized)
struct WorkspaceDatabaseCRUDTests {

    @Test func createAndFetchWorkspace() async throws {
        let db = try makeInMemoryDatabase()
        let workspace = Workspace(
            id: UUID(),
            kind: .file,
            createdAt: .now,
            updatedAt: .now,
            bookmarkData: Data([0x01]),
            rootPath: "/tmp/test.swift",
            rootFileName: "test.swift",
            summaryText: "Test workspace",
            isCorrupted: false
        )

        try await db.createWorkspace(workspace)
        let fetched = try await db.fetchWorkspace(id: workspace.id)
        #expect(fetched != nil)
        #expect(fetched?.id == workspace.id)
        #expect(fetched?.kind == .file)
        #expect(fetched?.rootPath == "/tmp/test.swift")
        #expect(fetched?.summaryText == "Test workspace")
    }

    @Test func fetchAllWorkspaces_orderedByUpdatedAt() async throws {
        let db = try makeInMemoryDatabase()
        let older = Workspace(
            id: UUID(), kind: .file,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000),
            bookmarkData: Data(),
            rootPath: "/tmp/old.swift", rootFileName: "old.swift",
            summaryText: "", isCorrupted: false
        )
        let newer = Workspace(
            id: UUID(), kind: .directory,
            createdAt: Date(timeIntervalSince1970: 2000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            bookmarkData: Data(),
            rootPath: "/tmp/new", rootFileName: "new",
            summaryText: "", isCorrupted: false
        )

        try await db.createWorkspace(older)
        try await db.createWorkspace(newer)

        let all = try await db.fetchAllWorkspaces()
        #expect(all.count == 2)
        #expect(all[0].rootFileName == "new")
        #expect(all[1].rootFileName == "old.swift")
    }

    @Test func updateWorkspace() async throws {
        let db = try makeInMemoryDatabase()
        var workspace = Workspace(
            id: UUID(), kind: .file,
            createdAt: .now, updatedAt: .now,
            bookmarkData: Data(),
            rootPath: "/tmp/test.swift", rootFileName: "test.swift",
            summaryText: "", isCorrupted: false
        )

        try await db.createWorkspace(workspace)
        workspace.summaryText = "Updated summary"
        workspace.updatedAt = Date(timeIntervalSince1970: 9999)
        try await db.updateWorkspace(workspace)

        let fetched = try await db.fetchWorkspace(id: workspace.id)
        #expect(fetched?.summaryText == "Updated summary")
    }

    @Test func deleteWorkspace() async throws {
        let db = try makeInMemoryDatabase()
        let workspace = Workspace(
            id: UUID(), kind: .file,
            createdAt: .now, updatedAt: .now,
            bookmarkData: Data(),
            rootPath: "/tmp/test.swift", rootFileName: "test.swift",
            summaryText: "", isCorrupted: false
        )

        try await db.createWorkspace(workspace)
        try await db.deleteWorkspace(id: workspace.id)

        let fetched = try await db.fetchWorkspace(id: workspace.id)
        #expect(fetched == nil)
    }

    @Test func fetchWorkspace_returnsNilForUnknownId() async throws {
        let db = try makeInMemoryDatabase()
        let fetched = try await db.fetchWorkspace(id: UUID())
        #expect(fetched == nil)
    }
}
