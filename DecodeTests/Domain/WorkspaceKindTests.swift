import Foundation
import Testing
@testable import Decode

/// Tests for the WorkspaceKind enum (T0.1).
struct WorkspaceKindTests {

    // MARK: - Raw Values

    @Test func rawValues() {
        #expect(WorkspaceKind.file.rawValue == "file")
        #expect(WorkspaceKind.directory.rawValue == "directory")
    }

    // MARK: - Codable

    @Test func codableRoundTrip_file() throws {
        let original = WorkspaceKind.file
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceKind.self, from: data)
        #expect(decoded == original)
    }

    @Test func codableRoundTrip_directory() throws {
        let original = WorkspaceKind.directory
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceKind.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Hashable

    @Test func hashable() {
        let set: Set<WorkspaceKind> = [.file, .directory, .file]
        #expect(set.count == 2)
    }

    // MARK: - Init from Raw Value

    @Test func initFromRawValue_valid() {
        #expect(WorkspaceKind(rawValue: "file") == .file)
        #expect(WorkspaceKind(rawValue: "directory") == .directory)
    }

    @Test func initFromRawValue_unknown() {
        #expect(WorkspaceKind(rawValue: "unknown") == nil)
        #expect(WorkspaceKind(rawValue: "") == nil)
        #expect(WorkspaceKind(rawValue: "File") == nil)
    }
}
