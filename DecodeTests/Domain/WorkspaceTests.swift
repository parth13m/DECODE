import Foundation
import Testing
@testable import Decode

/// Tests for the Workspace domain model (T0.2).
struct WorkspaceTests {

    // MARK: - Helpers

    static func makeFileWorkspace(
        id: UUID = UUID(),
        rootPath: String = "/tmp/test.swift",
        rootFileName: String = "test.swift",
        summaryText: String = "",
        isCorrupted: Bool = false
    ) -> Workspace {
        Workspace(
            id: id,
            kind: .file,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            bookmarkData: Data([0x01, 0x02]),
            rootPath: rootPath,
            rootFileName: rootFileName,
            summaryText: summaryText,
            isCorrupted: isCorrupted
        )
    }

    static func makeDirectoryWorkspace(
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
            summaryText: "A project workspace",
            isCorrupted: false
        )
    }

    // MARK: - Identifiable

    @Test func identifiable() {
        let id = UUID()
        let workspace = Self.makeFileWorkspace(id: id)
        #expect(workspace.id == id)
    }

    // MARK: - Codable Round-Trip

    @Test func codableRoundTrip_file() throws {
        let original = Self.makeFileWorkspace()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == original)
        #expect(decoded.kind == .file)
        #expect(decoded.rootPath == "/tmp/test.swift")
        #expect(decoded.rootFileName == "test.swift")
    }

    @Test func codableRoundTrip_directory() throws {
        let original = Self.makeDirectoryWorkspace()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == original)
        #expect(decoded.kind == .directory)
        #expect(decoded.rootPath == "/tmp/project")
        #expect(decoded.rootFileName == "project")
    }

    // MARK: - Hashable

    @Test func hashable_differentIds() {
        let a = Self.makeFileWorkspace(id: UUID())
        let b = Self.makeFileWorkspace(id: UUID())
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test func hashable_sameId() {
        let id = UUID()
        var a = Self.makeFileWorkspace(id: id)
        var b = Self.makeFileWorkspace(id: id)
        // Mutate a var field — synthesised Hashable uses all fields.
        a.summaryText = "changed"
        b.summaryText = "different"
        // With synthesised Hashable, different summaryText → different hash.
        #expect(a != b)
    }

    // MARK: - Mutable vs Immutable Fields

    @Test func mutableFields() {
        var workspace = Self.makeFileWorkspace()
        let newDate = Date(timeIntervalSince1970: 9_000_000)
        workspace.updatedAt = newDate
        workspace.bookmarkData = Data([0xFF])
        workspace.rootPath = "/tmp/other.swift"
        workspace.rootFileName = "other.swift"
        workspace.summaryText = "updated"
        workspace.isCorrupted = true

        #expect(workspace.updatedAt == newDate)
        #expect(workspace.bookmarkData == Data([0xFF]))
        #expect(workspace.rootPath == "/tmp/other.swift")
        #expect(workspace.rootFileName == "other.swift")
        #expect(workspace.summaryText == "updated")
        #expect(workspace.isCorrupted == true)
    }
}
