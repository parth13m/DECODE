import Foundation

/// FSEvents-compatible file watcher using DispatchSource on the parent directory.
///
/// Monitors the parent directory of the target file (not the file itself) to survive
/// atomic saves. Most editors (Xcode, VS Code, vim) save via write-to-temp →
/// delete-original → rename-temp, which destroys file-level watchers. Watching the
/// directory FD survives this because the directory inode is stable.
///
/// Events are debounced (300ms) to collapse rapid atomic-save sequences into a single
/// change detection check. The check compares the file's modification date against
/// the last known value.
///
/// ## Concurrency
/// All mutable state is guarded by a serial `DispatchQueue`. The DispatchSource
/// callback fires on a background queue, so synchronization is required.
/// `@unchecked Sendable` because `DispatchSource` and raw file descriptors are
/// not formally Sendable, but access is serialized.
final class FileWatcherService: FileWatcherProtocol, @unchecked Sendable {

    // MARK: - Synchronization

    /// Serial queue guarding all mutable state.
    private let queue = DispatchQueue(label: "com.decode.filewatcher", qos: .utility)

    // MARK: - State (accessed only on `queue`)

    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var continuation: AsyncStream<FileChangeEvent>.Continuation?
    private var lastKnownModDate: Date?
    private var debounceWorkItem: DispatchWorkItem?
    private var watchedFileURL: URL?

    // MARK: - FileWatcherProtocol

    func startWatching(fileURL: URL) -> AsyncStream<FileChangeEvent> {
        // Stop any previous watcher before starting a new one.
        stopWatching()

        let (stream, continuation) = AsyncStream.makeStream(of: FileChangeEvent.self)

        queue.sync {
            let dirPath = fileURL.deletingLastPathComponent().path
            let fd = open(dirPath, O_EVTONLY)

            guard fd >= 0 else {
                continuation.finish()
                return
            }

            self.directoryFD = fd
            self.continuation = continuation
            self.watchedFileURL = fileURL
            self.lastKnownModDate = self.modificationDate(of: fileURL)

            let dispatchSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: self.queue
            )

            dispatchSource.setEventHandler { [weak self] in
                self?.handleDirectoryEvent()
            }

            dispatchSource.setCancelHandler { [weak self] in
                if let self {
                    if self.directoryFD >= 0 {
                        close(self.directoryFD)
                        self.directoryFD = -1
                    }
                }
            }

            self.source = dispatchSource
            dispatchSource.resume()
        }

        return stream
    }

    func stopWatching() {
        queue.sync {
            self.stopWatchingInternal()
        }
    }

    deinit {
        // DispatchSource must be cancelled before dealloc.
        // Direct access — deinit is single-threaded.
        stopWatchingInternal()
    }

    // MARK: - Private (called on `queue`)

    /// Cancel the dispatch source and clean up. Must be called on `queue`.
    private func stopWatchingInternal() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let source {
            source.cancel()  // Triggers cancelHandler which closes the FD.
        }
        source = nil

        continuation?.finish()
        continuation = nil
        watchedFileURL = nil
        lastKnownModDate = nil
    }

    /// Handle a directory-level filesystem event. Called on `queue`.
    ///
    /// Debounces by cancelling any pending check and scheduling a new one
    /// 300ms in the future. This collapses rapid atomic-save event sequences
    /// (write-temp, delete-original, rename-temp) into a single check.
    private func handleDirectoryEvent() {
        debounceWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.checkFileChanged()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Check whether the watched file's modification date has changed. Called on `queue`.
    private func checkFileChanged() {
        guard let fileURL = watchedFileURL else { return }

        // Check if file still exists.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            continuation?.yield(FileChangeEvent(
                fileURL: fileURL,
                kind: .deleted,
                detectedAt: Date()
            ))
            return
        }

        // Compare modification date.
        let currentModDate = modificationDate(of: fileURL)

        if currentModDate != lastKnownModDate {
            lastKnownModDate = currentModDate
            continuation?.yield(FileChangeEvent(
                fileURL: fileURL,
                kind: .modified,
                detectedAt: Date()
            ))
        }
    }

    /// Read the file's modification date from filesystem metadata.
    private func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
