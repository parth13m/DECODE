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
}
