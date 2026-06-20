import Foundation

/// The aggregate root for a tracked file context.
///
/// A Session represents a single file being tracked by Decode in Session Mode.
/// It owns all metadata, structural entities, documentation notes, and chat threads.
/// Removing a Session cascades deletion to all nested collections.
///
/// Maps to the `sessions` table in the database.
struct Session: Identifiable, Sendable, Codable, Hashable {

    let id: UUID
    let createdAt: Date
    var updatedAt: Date

    /// Security-scoped bookmark data for sandbox persistence across app restarts.
    var bookmarkData: Data

    // MARK: - File Metadata

    var filePath: String
    var fileName: String
    var fileSize: Int
    var fileModifiedAt: Date
    var fileHash: String

    // MARK: - Summary

    /// AI-generated high-level description of the file's purpose and architecture.
    var summaryText: String

    /// Whether the session's database records are known to be corrupted.
    var isCorrupted: Bool
}
