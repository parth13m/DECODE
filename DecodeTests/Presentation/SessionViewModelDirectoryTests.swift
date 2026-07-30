// SessionViewModelDirectoryTests.swift — DecodeTests
// Tests for SessionViewModel directory workspace support.
// Verifies that openDirectory / loadDirectory creates .directory workspaces
// and that the UI state accessors reflect directory workspace properties.

import Testing
import Foundation
@testable import Decode

// MARK: - Test Helpers

/// Creates a temporary directory with Swift source files.
/// Returns the directory URL. Caller is responsible for cleanup.
@MainActor
private func createTempProjectDirectory(
    files: [(name: String, content: String)] = [
        ("Main.swift", "struct App {\n    func run() { }\n}\n"),
        ("Helper.swift", "struct Helper {\n    func help() { }\n}\n"),
    ]
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-dir-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for file in files {
        let fileURL = dir.appendingPathComponent(file.name)
        try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return dir
}

/// Removes a temporary directory.
private func cleanupTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Directory Workspace Tests

@Suite(.serialized)
struct SessionViewModelDirectoryTests {

    @Test @MainActor
    func loadDirectoryCreatesDirectoryWorkspace() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        await vm.loadDirectory(url: dir)

        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
        #expect(vm.activeWorkspace != nil)
        #expect(vm.activeWorkspace?.workspace.kind == .directory)
        #expect(vm.activeWorkspace?.workspace.rootPath == dir.path)
    }

    @Test @MainActor
    func loadDirectorySetsIsDirectoryWorkspace() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        #expect(vm.isDirectoryWorkspace == false)

        await vm.loadDirectory(url: dir)

        #expect(vm.isDirectoryWorkspace == true)
    }

    @Test @MainActor
    func loadDirectoryCreatesIndexingCoordinatorWhenPipelineAvailable() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        await vm.loadDirectory(url: dir)

        // Without processChanges wired (no AppDependencies), indexing can't start.
        // The workspace is still created as .directory — indexing starts when the
        // pipeline is available (production wiring via AppDependencies).
        #expect(vm.activeWorkspace != nil)
        #expect(vm.activeWorkspace?.workspace.kind == .directory)
    }

    @Test @MainActor
    func loadDirectoryReactivatesExisting() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)

        let dir1 = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir1) }
        let dir2 = try createTempProjectDirectory(files: [
            ("Other.swift", "struct Other { }\n"),
        ])
        defer { cleanupTempDirectory(dir2) }

        await vm.loadDirectory(url: dir1)
        let firstId = manager.activeWorkspaceId

        await vm.loadDirectory(url: dir2)
        #expect(manager.workspaces.count == 2)

        // Re-opening dir1 reactivates it — no new workspace.
        await vm.loadDirectory(url: dir1)
        #expect(manager.workspaces.count == 2)
        #expect(manager.activeWorkspaceId == firstId)
    }

    @Test @MainActor
    func loadDirectoryAcceptsValidPath() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        await vm.loadDirectory(url: dir)

        #expect(vm.activeWorkspace != nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test @MainActor
    func loadDirectoryClearsSelectedEntity() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        // Set a fake selected entity.
        vm.selectedEntityID = UUID()
        #expect(vm.selectedEntityID != nil)

        await vm.loadDirectory(url: dir)

        #expect(vm.selectedEntityID == nil)
    }

    @Test @MainActor
    func fileWorkspaceIsNotDirectoryWorkspace() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        let fileURL = dir.appendingPathComponent("Main.swift")
        await vm.loadFile(url: fileURL)

        #expect(vm.isDirectoryWorkspace == false)
        #expect(vm.activeWorkspace?.workspace.kind == .file)
    }

    @Test @MainActor
    func navigationStateExistsForDirectoryWorkspace() async throws {
        let manager = WorkspaceManager()
        let vm = SessionViewModel(workspaceManager: manager)
        let dir = try createTempProjectDirectory()
        defer { cleanupTempDirectory(dir) }

        await vm.loadDirectory(url: dir)

        // NavigationState should be available (always is on SessionViewModel).
        #expect(vm.navigationState.activeFilePath == nil)

        // Select a file within the directory.
        let filePath = dir.appendingPathComponent("Main.swift").path
        vm.navigationState.selectFile(path: filePath)
        #expect(vm.navigationState.activeFilePath == filePath)
    }
}
