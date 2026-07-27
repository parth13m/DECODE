import Foundation

/// FSEvents-based recursive directory watcher for `.directory` workspaces.
///
/// Monitors all files under a root directory using `DispatchSource` on the
/// root directory file descriptor. Events are debounced at 500ms to coalesce
/// rapid save sequences (e.g., IDE auto-save, git operations). Changed files
/// are identified by comparing modification dates against a snapshot taken
/// at start time.
///
/// Only files matching ``IndexingCoordinator/supportedExtensions`` are
/// reported. Excluded directories (`.git`, `node_modules`, etc.) are
/// filtered at the event level.
///
/// ## Concurrency
/// All mutable state is guarded by a serial `DispatchQueue`. The
/// DispatchSource callback fires on a background queue.
/// `@unchecked Sendable` because `DispatchSource` and raw file descriptors
/// are not formally Sendable, but access is serialized.
final class DirectoryWatcherService: DirectoryWatcherProtocol, @unchecked Sendable {

    // MARK: - Configuration

    /// Debounce interval before scanning for changes.
    private static let debounceInterval: TimeInterval = 0.5

    // MARK: - Synchronization

    private let queue = DispatchQueue(label: "com.decode.directorywatcher", qos: .utility)

    // MARK: - State (accessed only on `queue`)

    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var continuation: AsyncStream<[FileChangeEvent]>.Continuation?
    private var debounceWorkItem: DispatchWorkItem?
    private var rootURL: URL?

    /// Snapshot of modification dates for all known source files.
    /// Built during `startWatching` and updated on each change detection.
    private var modDateSnapshot: [String: Date] = [:]

    // MARK: - DirectoryWatcherProtocol

    func startWatching(directoryURL: URL) -> AsyncStream<[FileChangeEvent]> {
        stopWatching()

        let (stream, continuation) = AsyncStream.makeStream(of: [FileChangeEvent].self)

        queue.sync {
            let fd = open(directoryURL.path, O_EVTONLY)

            guard fd >= 0 else {
                continuation.finish()
                return
            }

            self.directoryFD = fd
            self.continuation = continuation
            self.rootURL = directoryURL
            self.modDateSnapshot = Self.buildModDateSnapshot(rootURL: directoryURL)

            let dispatchSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: self.queue
            )

            dispatchSource.setEventHandler { [weak self] in
                self?.handleDirectoryEvent()
            }

            dispatchSource.setCancelHandler { [weak self] in
                if let self, self.directoryFD >= 0 {
                    close(self.directoryFD)
                    self.directoryFD = -1
                }
            }

            self.source = dispatchSource
            dispatchSource.resume()
        }

        return stream
    }

    func stopWatching() {
        queue.sync {
            stopWatchingInternal()
        }
    }

    deinit {
        stopWatchingInternal()
    }

    // MARK: - Private (called on `queue`)

    private func stopWatchingInternal() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let source {
            source.cancel()
        }
        source = nil

        continuation?.finish()
        continuation = nil
        rootURL = nil
        modDateSnapshot = [:]
    }

    /// Debounce directory events. Called on `queue`.
    private func handleDirectoryEvent() {
        debounceWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.scanForChanges()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// Scan the directory tree for changes since the last snapshot.
    /// Called on `queue` after debounce.
    private func scanForChanges() {
        guard let rootURL else { return }

        let currentSnapshot = Self.buildModDateSnapshot(rootURL: rootURL)
        var events: [FileChangeEvent] = []

        // Detect modified and new files.
        for (path, modDate) in currentSnapshot {
            if let previousDate = modDateSnapshot[path] {
                if modDate != previousDate {
                    events.append(FileChangeEvent(
                        fileURL: URL(fileURLWithPath: path),
                        kind: .modified,
                        detectedAt: Date()
                    ))
                }
            } else {
                // New file.
                events.append(FileChangeEvent(
                    fileURL: URL(fileURLWithPath: path),
                    kind: .modified,
                    detectedAt: Date()
                ))
            }
        }

        // Detect deleted files.
        for path in modDateSnapshot.keys where currentSnapshot[path] == nil {
            events.append(FileChangeEvent(
                fileURL: URL(fileURLWithPath: path),
                kind: .deleted,
                detectedAt: Date()
            ))
        }

        modDateSnapshot = currentSnapshot

        if !events.isEmpty {
            continuation?.yield(events)
        }
    }

    // MARK: - Snapshot Building

    /// Build a modification date snapshot for all supported source files
    /// under `rootURL`, respecting the exclusion list.
    static func buildModDateSnapshot(rootURL: URL) -> [String: Date] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshot: [String: Date] = [:]

        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent

            if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDir {
                if IndexingCoordinator.excludedDirectories.contains(fileName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            guard IndexingCoordinator.supportedExtensions.contains(ext) else { continue }

            if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                snapshot[fileURL.path] = modDate
            }
        }

        return snapshot
    }
}
