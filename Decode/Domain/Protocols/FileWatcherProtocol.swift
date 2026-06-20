import Foundation

/// Defines the contract for monitoring a file for changes.
///
/// The concrete implementation uses FSEvents to watch the parent directory
/// of the target file (not the file directly), because most editors use
/// atomic saves (write to temp, delete original, rename temp) which would
/// kill a file-level watcher.
protocol FileWatcherProtocol: Sendable {

    /// Begin watching for changes to the file at the given URL.
    ///
    /// Returns an `AsyncStream` that emits `FileChangeEvent` values whenever
    /// the watched file is modified, deleted, moved, or becomes inaccessible.
    /// The stream ends when `stopWatching()` is called or the watcher is deallocated.
    func startWatching(fileURL: URL) -> AsyncStream<FileChangeEvent>

    /// Stop watching the currently monitored file.
    func stopWatching()
}
