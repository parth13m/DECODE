// SessionStateTests.swift — DecodeTests
//
// Tests for the SessionState model and its integration with WorkspaceManager.
//
// Verifies the separation between workspace history (database) and session
// state (JSON file):
// - Database stores all workspaces ever created (history/bookmarks).
// - SessionState stores only which workspaces were open, active, and pinned.
// - restoreWorkspaces() filters by session state, not by database contents.
// - First launch (no session state file) starts with a clean session.

import Testing
import Foundation
import GRDB
@testable import Decode

// MARK: - Test Helpers

/// Creates a temporary Swift file. Caller is responsible for cleanup.
@MainActor
private func createTempSwiftFile(
    name: String = "TestFile.swift",
    content: String = "struct Hello {\n    func greet() { }\n}\n"
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-session-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(name)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

/// Creates a temporary directory with Swift source files.
@MainActor
private func createTempDirectory(
    files: [(name: String, content: String)] = [
        ("Main.swift", "struct App {\n    func run() { }\n}\n"),
    ]
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-session-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for file in files {
        let fileURL = dir.appendingPathComponent(file.name)
        try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return dir
}

/// Removes a temporary file/directory.
private func cleanup(_ url: URL) {
    // Remove the file/dir itself; if it's a file inside a temp dir, remove the parent.
    try? FileManager.default.removeItem(at: url)
    let parent = url.deletingLastPathComponent()
    if parent.lastPathComponent.hasPrefix("decode-session-tests-") {
        try? FileManager.default.removeItem(at: parent)
    }
}

/// Creates an in-memory database with all migrations applied.
private func makeDatabase() throws -> DatabaseService {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-session-db-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let dbPath = tmpDir.appendingPathComponent("test.sqlite3").path
    return try DatabaseService(path: dbPath)
}

/// Creates a temporary session state file URL.
private func makeTempSessionStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-session-state-\(UUID().uuidString).json")
}

/// Cleans up a session state file.
private func cleanupSessionState(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - SessionState Model Tests

@Suite
struct SessionStateModelTests {

    @Test func encodeDecode_roundTrip() throws {
        let id1 = UUID()
        let id2 = UUID()
        let activeID = id1
        let pinnedID = id2

        let state = SessionState(
            openWorkspaceIDs: [id1, id2],
            activeWorkspaceID: activeID,
            pinnedWorkspaceID: pinnedID
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.openWorkspaceIDs == [id1, id2])
        #expect(decoded.activeWorkspaceID == activeID)
        #expect(decoded.pinnedWorkspaceID == pinnedID)
    }

    @Test func encodeDecode_nilFields() throws {
        let state = SessionState(
            openWorkspaceIDs: [],
            activeWorkspaceID: nil,
            pinnedWorkspaceID: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.openWorkspaceIDs.isEmpty)
        #expect(decoded.activeWorkspaceID == nil)
        #expect(decoded.pinnedWorkspaceID == nil)
    }
}

// MARK: - SessionStatePersistence Tests

@Suite
struct SessionStatePersistenceTests {

    @Test func save_and_load_roundTrip() {
        let url = makeTempSessionStateURL()
        defer { cleanupSessionState(url) }

        let id1 = UUID()
        let id2 = UUID()
        let state = SessionState(
            openWorkspaceIDs: [id1, id2],
            activeWorkspaceID: id1,
            pinnedWorkspaceID: id2
        )

        SessionStatePersistence.save(state, to: url)
        let loaded = SessionStatePersistence.load(from: url)

        #expect(loaded != nil)
        #expect(loaded == state)
    }

    @Test func load_missingFile_returnsNil() {
        let url = makeTempSessionStateURL()
        // Do not create the file.
        let loaded = SessionStatePersistence.load(from: url)
        #expect(loaded == nil)
    }

    @Test func load_corruptedFile_returnsNil() throws {
        let url = makeTempSessionStateURL()
        defer { cleanupSessionState(url) }

        // Write invalid JSON.
        try "{ this is not valid json }}}".data(using: .utf8)!.write(to: url)
        let loaded = SessionStatePersistence.load(from: url)
        #expect(loaded == nil)
    }

    @Test func load_emptyFile_returnsNil() throws {
        let url = makeTempSessionStateURL()
        defer { cleanupSessionState(url) }

        try Data().write(to: url)
        let loaded = SessionStatePersistence.load(from: url)
        #expect(loaded == nil)
    }

    @Test func delete_removesFile() {
        let url = makeTempSessionStateURL()
        let state = SessionState(openWorkspaceIDs: [UUID()], activeWorkspaceID: nil, pinnedWorkspaceID: nil)
        SessionStatePersistence.save(state, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        SessionStatePersistence.delete(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func save_overwritesExisting() {
        let url = makeTempSessionStateURL()
        defer { cleanupSessionState(url) }

        let id1 = UUID()
        let id2 = UUID()

        let state1 = SessionState(openWorkspaceIDs: [id1], activeWorkspaceID: id1, pinnedWorkspaceID: nil)
        SessionStatePersistence.save(state1, to: url)

        let state2 = SessionState(openWorkspaceIDs: [id2], activeWorkspaceID: id2, pinnedWorkspaceID: id2)
        SessionStatePersistence.save(state2, to: url)

        let loaded = SessionStatePersistence.load(from: url)
        #expect(loaded == state2)
    }
}

// MARK: - WorkspaceManager + SessionState Integration Tests

@Suite(.serialized)
struct SessionStateIntegrationTests {

    // MARK: - First Launch (No Session State)

    @Test @MainActor func firstLaunch_noSessionState_restoresNothing() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        // Create a workspace in the database via a first manager.
        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file)
        #expect(manager1.workspaces.count == 1)

        // Delete session state to simulate first launch after upgrade.
        SessionStatePersistence.delete(at: sessionURL)

        // A new manager restoring with no session state file → clean session.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()

        #expect(manager2.workspaces.isEmpty)
        #expect(manager2.activeWorkspaceId == nil)
    }

    @Test @MainActor func firstLaunch_workspacesStillInDatabase() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file)

        // Delete session state.
        SessionStatePersistence.delete(at: sessionURL)

        // Database still has the workspace.
        let stored = try await db.fetchAllWorkspaces()
        #expect(stored.count == 1)
        #expect(stored.first?.rootPath == file.path)
    }

    // MARK: - Save / Restore Round-Trip

    @Test @MainActor func createWorkspace_savesSessionState() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file)

        let state = SessionStatePersistence.load(from: sessionURL)
        #expect(state != nil)
        #expect(state?.openWorkspaceIDs.count == 1)
        #expect(state?.activeWorkspaceID == manager.activeWorkspaceId)
    }

    @Test @MainActor func restoreWorkspaces_restoresOnlyOpenWorkspaces() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file1 = try createTempSwiftFile(name: "File1.swift")
        defer { cleanup(file1) }
        let file2 = try createTempSwiftFile(name: "File2.swift")
        defer { cleanup(file2) }
        let file3 = try createTempSwiftFile(name: "File3.swift")
        defer { cleanup(file3) }

        // Create 3 workspaces.
        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file1)
        try await manager1.createFileWorkspace(url: file2)
        try await manager1.createFileWorkspace(url: file3)
        #expect(manager1.workspaces.count == 3)

        // Close workspace 2 — removes from memory and session state.
        let ws2Id = manager1.workspaces.values.first(where: { $0.workspace.rootPath == file2.path })!.workspace.id
        manager1.closeWorkspace(id: ws2Id)
        #expect(manager1.workspaces.count == 2)

        // Database still has all 3.
        let allStored = try await db.fetchAllWorkspaces()
        #expect(allStored.count == 3)

        // New manager restores only the 2 that were open.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()
        #expect(manager2.workspaces.count == 2)

        // The closed workspace should NOT be restored.
        #expect(manager2.workspaces[ws2Id] == nil)
    }

    @Test @MainActor func restoreWorkspaces_restoresActiveWorkspace() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file1 = try createTempSwiftFile(name: "Active1.swift")
        defer { cleanup(file1) }
        let file2 = try createTempSwiftFile(name: "Active2.swift")
        defer { cleanup(file2) }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file1)
        let ws1Id = manager1.activeWorkspaceId!

        try await manager1.createFileWorkspace(url: file2)
        // file2 is now active. Switch back to file1.
        manager1.activateWorkspace(id: ws1Id)
        #expect(manager1.activeWorkspaceId == ws1Id)

        // Restore in a new manager — should restore the active workspace.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()
        #expect(manager2.activeWorkspaceId == ws1Id)
    }

    @Test @MainActor func restoreWorkspaces_restoresPinnedWorkspace() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file)
        let wsId = manager1.activeWorkspaceId!
        manager1.pinWorkspace(id: wsId)
        #expect(manager1.pinnedWorkspaceId == wsId)

        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()
        #expect(manager2.pinnedWorkspaceId == wsId)
    }

    // MARK: - Close Workspace

    @Test @MainActor func closeWorkspace_removesFromSessionState() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file)
        let wsId = manager.activeWorkspaceId!

        // Session state has the workspace.
        var state = SessionStatePersistence.load(from: sessionURL)
        #expect(state?.openWorkspaceIDs.contains(wsId) == true)

        // Close it.
        manager.closeWorkspace(id: wsId)

        // Session state no longer has the workspace.
        state = SessionStatePersistence.load(from: sessionURL)
        #expect(state != nil)
        #expect(state?.openWorkspaceIDs.contains(wsId) == false)
    }

    @Test @MainActor func closeAllWorkspaces_sessionStateEmpty() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file)
        let wsId = manager.activeWorkspaceId!

        manager.closeWorkspace(id: wsId)

        let state = SessionStatePersistence.load(from: sessionURL)
        #expect(state != nil)
        #expect(state?.openWorkspaceIDs.isEmpty == true)
        #expect(state?.activeWorkspaceID == nil)
    }

    // MARK: - Corrupted Session State

    @Test @MainActor func corruptedSessionState_restoresNothing() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        // Create a workspace.
        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file)

        // Corrupt the session state file.
        try "not json!!!".data(using: .utf8)!.write(to: sessionURL)

        // New manager sees corrupt state → starts clean.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()

        #expect(manager2.workspaces.isEmpty)
        #expect(manager2.activeWorkspaceId == nil)
    }

    // MARK: - Historical Workspaces Not Reopened

    @Test @MainActor func historicalWorkspaces_notRestoredWithoutSessionState() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        // Create 5 workspaces, simulating historical accumulation.
        var files: [URL] = []
        for i in 1...5 {
            let f = try createTempSwiftFile(name: "History\(i).swift")
            files.append(f)
        }
        defer { files.forEach { cleanup($0) } }

        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        for f in files {
            try await manager1.createFileWorkspace(url: f)
        }
        #expect(manager1.workspaces.count == 5)

        // Close 3 workspaces — they become history.
        let idsToClose = Array(manager1.workspaces.keys.prefix(3))
        for id in idsToClose {
            manager1.closeWorkspace(id: id)
        }
        #expect(manager1.workspaces.count == 2)

        // Database still has all 5.
        let allStored = try await db.fetchAllWorkspaces()
        #expect(allStored.count == 5)

        // New manager restores only the 2 that were open.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()
        #expect(manager2.workspaces.count == 2)

        // Confirm closed workspaces are NOT in the restored set.
        for closedId in idsToClose {
            #expect(manager2.workspaces[closedId] == nil)
        }
    }

    // MARK: - Missing File Handling

    @Test @MainActor func restore_skipsDeletedFiles_updatesSessionState() async throws {
        let db = try makeDatabase()
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()

        let manager1 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        try await manager1.createFileWorkspace(url: file)
        let wsId = manager1.activeWorkspaceId!

        // Session state includes this workspace.
        var state = SessionStatePersistence.load(from: sessionURL)
        #expect(state?.openWorkspaceIDs.contains(wsId) == true)

        // Delete the file before restore.
        cleanup(file)

        // New manager can't restore it — file is gone.
        let manager2 = WorkspaceManager(database: db, sessionStateURL: sessionURL)
        await manager2.restoreWorkspaces()
        #expect(manager2.workspaces.isEmpty)

        // Session state is updated to reflect the actual restored set.
        state = SessionStatePersistence.load(from: sessionURL)
        #expect(state?.openWorkspaceIDs.isEmpty == true)
    }

    // MARK: - Incremental Persistence

    @Test @MainActor func activateWorkspace_savesSessionState() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file1 = try createTempSwiftFile(name: "A.swift")
        defer { cleanup(file1) }
        let file2 = try createTempSwiftFile(name: "B.swift")
        defer { cleanup(file2) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file1)
        let ws1Id = manager.activeWorkspaceId!

        try await manager.createFileWorkspace(url: file2)
        let ws2Id = manager.activeWorkspaceId!
        #expect(ws2Id != ws1Id)

        // Activate ws1.
        manager.activateWorkspace(id: ws1Id)

        let state = SessionStatePersistence.load(from: sessionURL)
        #expect(state?.activeWorkspaceID == ws1Id)
    }

    @Test @MainActor func pinWorkspace_savesSessionState() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file)
        let wsId = manager.activeWorkspaceId!

        manager.pinWorkspace(id: wsId)

        let state = SessionStatePersistence.load(from: sessionURL)
        #expect(state?.pinnedWorkspaceID == wsId)
    }

    @Test @MainActor func unpinWorkspace_savesSessionState() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file)
        let wsId = manager.activeWorkspaceId!

        manager.pinWorkspace(id: wsId)
        manager.unpinWorkspace()

        let state = SessionStatePersistence.load(from: sessionURL)
        #expect(state?.pinnedWorkspaceID == nil)
    }

    // MARK: - saveSessionState() Explicit Call

    @Test @MainActor func saveSessionState_capturesCurrentState() async throws {
        let sessionURL = makeTempSessionStateURL()
        defer { cleanupSessionState(sessionURL) }

        let file = try createTempSwiftFile()
        defer { cleanup(file) }

        let manager = WorkspaceManager(sessionStateURL: sessionURL)
        try await manager.createFileWorkspace(url: file)
        let wsId = manager.activeWorkspaceId!

        // Explicitly save (simulates willTerminateNotification).
        manager.saveSessionState()

        let state = SessionStatePersistence.load(from: sessionURL)
        #expect(state != nil)
        #expect(state?.openWorkspaceIDs == [wsId])
        #expect(state?.activeWorkspaceID == wsId)
    }
}
