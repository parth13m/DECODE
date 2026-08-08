import Foundation

/// A saved explanation note. Canonical storage is a Markdown file on disk;
/// the database stores only index metadata for fast lookup.
struct Note: Identifiable, Sendable, Codable, Hashable {

    let id: UUID
    let title: String
    let fileName: String
    let selectedCode: String
    let explanation: String
    let language: String?
    let mode: String?
    let workspacePath: String?
    let filePath: String?
    let createdAt: Date
}
