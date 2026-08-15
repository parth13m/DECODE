import Foundation
import Testing
@testable import Decode

/// Tests for ``NavigationState`` (W6).
@Suite(.serialized)
struct NavigationStateTests {

    @Test @MainActor
    func initialStateIsNil() {
        let state = NavigationState()
        #expect(state.activeFilePath == nil)
        #expect(state.activeEntityId == nil)
    }

    @Test @MainActor
    func selectFileSetsPath() {
        let state = NavigationState()
        state.selectFile(path: "/tmp/project/main.swift")
        #expect(state.activeFilePath == "/tmp/project/main.swift")
    }

    @Test @MainActor
    func selectFileClearsEntityId() {
        let state = NavigationState()
        state.selectEntity(id: UUID())
        #expect(state.activeEntityId != nil)

        state.selectFile(path: "/tmp/project/other.swift")
        #expect(state.activeEntityId == nil)
    }

    @Test @MainActor
    func selectFileWithNilClearsPath() {
        let state = NavigationState()
        state.selectFile(path: "/tmp/project/main.swift")
        state.selectFile(path: nil)
        #expect(state.activeFilePath == nil)
    }

    @Test @MainActor
    func selectEntitySetsId() {
        let state = NavigationState()
        let id = UUID()
        state.selectEntity(id: id)
        #expect(state.activeEntityId == id)
    }

    @Test @MainActor
    func selectEntityWithNilClearsId() {
        let state = NavigationState()
        state.selectEntity(id: UUID())
        state.selectEntity(id: nil)
        #expect(state.activeEntityId == nil)
    }

    // MARK: - Folder Selection

    @Test @MainActor
    func selectFolderSetsFolderPath() {
        let state = NavigationState()
        state.selectFolder(relativePath: "Sources/Core")
        #expect(state.selectedFolderPath == "Sources/Core")
    }

    @Test @MainActor
    func selectFolderClearsFilePath() {
        let state = NavigationState()
        state.selectFile(path: "/tmp/project/main.swift")
        state.selectFolder(relativePath: "Sources")
        #expect(state.activeFilePath == nil)
        #expect(state.selectedFolderPath == "Sources")
    }

    @Test @MainActor
    func selectFileClearsFolderPath() {
        let state = NavigationState()
        state.selectFolder(relativePath: "Sources")
        state.selectFile(path: "/tmp/project/main.swift")
        #expect(state.selectedFolderPath == nil)
        #expect(state.activeFilePath == "/tmp/project/main.swift")
    }

    @Test @MainActor
    func selectFolderClearsEntityId() {
        let state = NavigationState()
        state.selectEntity(id: UUID())
        state.selectFolder(relativePath: "Sources")
        #expect(state.activeEntityId == nil)
    }

    // MARK: - Folder Expansion

    @Test @MainActor
    func toggleFolderExpansionAddsToSet() {
        let state = NavigationState()
        state.toggleFolderExpansion(relativePath: "Sources")
        #expect(state.expandedFolders.contains("Sources"))
    }

    @Test @MainActor
    func toggleFolderExpansionRemovesFromSet() {
        let state = NavigationState()
        state.toggleFolderExpansion(relativePath: "Sources")
        state.toggleFolderExpansion(relativePath: "Sources")
        #expect(!state.expandedFolders.contains("Sources"))
    }

    @Test @MainActor
    func multipleExpandedFolders() {
        let state = NavigationState()
        state.toggleFolderExpansion(relativePath: "Sources")
        state.toggleFolderExpansion(relativePath: "Tests")
        #expect(state.expandedFolders.count == 2)
        #expect(state.expandedFolders.contains("Sources"))
        #expect(state.expandedFolders.contains("Tests"))
    }

    @Test @MainActor
    func expandedFoldersPreservedOnFileSelection() {
        let state = NavigationState()
        state.toggleFolderExpansion(relativePath: "Sources")
        state.toggleFolderExpansion(relativePath: "Tests")
        state.selectFile(path: "/tmp/project/main.swift")
        #expect(state.expandedFolders.count == 2)
    }

    @Test @MainActor
    func expandedFoldersPreservedOnFolderSelection() {
        let state = NavigationState()
        state.toggleFolderExpansion(relativePath: "Sources")
        state.toggleFolderExpansion(relativePath: "Tests")
        state.selectFolder(relativePath: "Sources")
        #expect(state.expandedFolders.count == 2)
    }

    @Test @MainActor
    func initialFolderStateIsEmpty() {
        let state = NavigationState()
        #expect(state.selectedFolderPath == nil)
        #expect(state.expandedFolders.isEmpty)
    }
}
