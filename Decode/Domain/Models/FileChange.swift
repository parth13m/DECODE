import Foundation

/// Describes a detected change to the tracked file.
///
/// Produced by the FileWatcherService when a file system event occurs
/// and the change detection pipeline confirms the file content has changed.
enum FileChangeKind: Sendable {
    /// File content has been modified (hash differs from stored value).
    case modified
    /// File has been deleted from disk.
    case deleted
    /// File has been moved or renamed; the new URL is provided if resolvable.
    case moved(newURL: URL?)
    /// File exists but is no longer accessible (sandbox permission revoked).
    case inaccessible
}

/// An event emitted by the file monitoring system when a tracked file changes.
struct FileChangeEvent: Sendable {
    let fileURL: URL
    let kind: FileChangeKind
    let detectedAt: Date
}
