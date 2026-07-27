import Foundation

/// Defines the contract for recursively monitoring a directory for file changes.
///
/// Used by `.directory` workspaces to detect modifications, additions, and
/// deletions within the project tree. Emits batched change events after
/// debouncing to avoid flooding the pipeline during rapid save sequences.
protocol DirectoryWatcherProtocol: Sendable {

    /// Begin watching the directory at the given URL recursively.
    ///
    /// Returns an `AsyncStream` that emits batches of ``FileChangeEvent``
    /// values whenever files within the directory are modified, added, or
    /// deleted. Events are debounced and coalesced per file.
    ///
    /// The stream ends when `stopWatching()` is called or the watcher is
    /// deallocated.
    func startWatching(directoryURL: URL) -> AsyncStream<[FileChangeEvent]>

    /// Stop watching the currently monitored directory.
    func stopWatching()
}
