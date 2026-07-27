import Foundation
import Testing
@testable import Decode

/// Tests for ``ProjectExplorerView.buildTree`` file tree construction (W6).
@Suite(.serialized)
struct ProjectExplorerTreeTests {

    // MARK: - Basic Structure

    @Test @MainActor
    func emptyFilePathsReturnsEmptyTree() {
        let tree = ProjectExplorerView.buildTree(rootPath: "/tmp/project", filePaths: [])
        #expect(tree.isEmpty)
    }

    @Test @MainActor
    func singleTopLevelFile() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: ["/tmp/project/main.swift"]
        )
        #expect(tree.count == 1)
        #expect(tree[0].name == "main.swift")
        #expect(tree[0].isDirectory == false)
        #expect(tree[0].fullPath == "/tmp/project/main.swift")
    }

    @Test @MainActor
    func fileInSubdirectoryCreatesDirectoryNode() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: ["/tmp/project/Sources/main.swift"]
        )
        #expect(tree.count == 1)
        #expect(tree[0].isDirectory == true)
        #expect(tree[0].name == "Sources")
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].name == "main.swift")
        #expect(tree[0].children[0].fullPath == "/tmp/project/Sources/main.swift")
    }

    @Test @MainActor
    func nestedSubdirectories() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: ["/tmp/project/Sources/Core/App.swift"]
        )
        #expect(tree.count == 1) // Sources
        #expect(tree[0].isDirectory == true)
        #expect(tree[0].name == "Sources")
        #expect(tree[0].children.count == 1) // Core
        #expect(tree[0].children[0].isDirectory == true)
        #expect(tree[0].children[0].name == "Core")
        #expect(tree[0].children[0].children.count == 1) // App.swift
        #expect(tree[0].children[0].children[0].name == "App.swift")
    }

    @Test @MainActor
    func multipleFilesInSameDirectory() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: [
                "/tmp/project/Sources/a.swift",
                "/tmp/project/Sources/b.swift",
                "/tmp/project/Sources/c.swift",
            ]
        )
        #expect(tree.count == 1) // Sources directory
        #expect(tree[0].children.count == 3)
        // Files should be sorted.
        #expect(tree[0].children[0].name == "a.swift")
        #expect(tree[0].children[1].name == "b.swift")
        #expect(tree[0].children[2].name == "c.swift")
    }

    // MARK: - Directory Ordering

    @Test @MainActor
    func directoriesComeBeforeTopLevelFiles() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: [
                "/tmp/project/README.swift",
                "/tmp/project/Sources/main.swift",
            ]
        )
        // Directories first, then top-level files.
        #expect(tree.count == 2)
        #expect(tree[0].isDirectory == true)
        #expect(tree[0].name == "Sources")
        #expect(tree[1].isDirectory == false)
        #expect(tree[1].name == "README.swift")
    }

    // MARK: - File Count

    @Test @MainActor
    func fileCountForFileNodeIsOne() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: ["/tmp/project/main.swift"]
        )
        #expect(tree[0].fileCount == 1)
    }

    @Test @MainActor
    func fileCountForDirectoryIsRecursive() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: [
                "/tmp/project/Sources/a.swift",
                "/tmp/project/Sources/Core/b.swift",
                "/tmp/project/Sources/Core/c.swift",
            ]
        )
        // Sources has 3 total files (1 direct + 2 in Core).
        #expect(tree[0].fileCount == 3)
        // Core has 2 files.
        let coreNode = tree[0].children.first { $0.isDirectory && $0.name == "Core" }
        #expect(coreNode?.fileCount == 2)
    }

    // MARK: - Root Path Handling

    @Test @MainActor
    func rootPathWithTrailingSlash() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project/",
            filePaths: ["/tmp/project/main.swift"]
        )
        #expect(tree.count == 1)
        #expect(tree[0].name == "main.swift")
    }

    @Test @MainActor
    func rootPathWithoutTrailingSlash() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: ["/tmp/project/main.swift"]
        )
        #expect(tree.count == 1)
        #expect(tree[0].name == "main.swift")
    }

    // MARK: - Mixed Structure

    @Test @MainActor
    func mixedDirectoriesAndFiles() {
        let tree = ProjectExplorerView.buildTree(
            rootPath: "/tmp/project",
            filePaths: [
                "/tmp/project/Package.swift",
                "/tmp/project/Sources/App.swift",
                "/tmp/project/Sources/Models/User.swift",
                "/tmp/project/Tests/AppTests.swift",
            ]
        )
        // Should have: Sources dir, Tests dir, Package.swift.
        #expect(tree.count == 3)
        // Directories sorted first.
        #expect(tree[0].isDirectory == true) // Sources
        #expect(tree[1].isDirectory == true) // Tests
        #expect(tree[2].isDirectory == false) // Package.swift
        #expect(tree[2].name == "Package.swift")
    }
}
