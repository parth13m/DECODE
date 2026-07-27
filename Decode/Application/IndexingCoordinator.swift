import Foundation
import UpdateEngine

/// Coordinates batch ingestion of source files within a `.directory` workspace.
///
/// Responsible for:
/// 1. **Manifest scan** — discovering all source files under a root directory.
/// 2. **Batch ingestion** — grouping files into batches and feeding them through
///    ``UnderstandingSystem.processChanges()``.
/// 3. **Progress tracking** — publishing ``IndexingState`` for UI observation.
///
/// Each `.directory` ``ManagedWorkspace`` owns one `IndexingCoordinator`.
@Observable
@MainActor
final class IndexingCoordinator {

    // MARK: - State

    /// The current indexing state, observable by the UI.
    private(set) var state: IndexingState = .idle

    /// All discovered source file paths after a successful scan.
    private(set) var discoveredFiles: [String] = []

    // MARK: - Configuration

    /// Number of files processed per batch before yielding.
    nonisolated static let batchSize = 20

    /// File extensions eligible for indexing. Derived from parser support
    /// (SwiftSyntax for `.swift`, tree-sitter for the rest).
    nonisolated static let supportedExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx",
        "java", "c", "cpp", "h", "hpp", "cs",
        "html", "css",
        // Additional extensions from GrammarRegistration
        "mjs", "cjs", "htm", "scss", "cxx", "cc", "hxx",
    ]

    /// Directories excluded from scanning.
    nonisolated static let excludedDirectories: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", "Pods", "Carthage",
        "build", "Build", "DerivedData",
        ".build", ".swiftpm",
        ".xcodeproj", ".xcworkspace",
        "__pycache__", ".pytest_cache",
        "dist", ".next", ".nuxt",
        "vendor", ".gradle",
        ".idea", ".vscode",
    ]

    // MARK: - Private

    private var indexingTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start indexing all source files under `rootPath` through the understanding pipeline.
    ///
    /// - Parameters:
    ///   - rootPath: The root directory path to scan.
    ///   - processChanges: Closure that feeds file change events to the pipeline.
    ///     Signature matches `UnderstandingSystem.processChanges(_:)`.
    func start(
        rootPath: String,
        processChanges: @escaping @Sendable ([UpdateEngine.FileChangeEvent]) async -> UpdateEngine.ChangeSetResult
    ) {
        cancel()

        state = .scanning
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        indexingTask = Task { [weak self] in
            // 1. Manifest scan
            let files = Self.scanManifest(rootURL: rootURL)
            guard !Task.isCancelled else {
                await MainActor.run { self?.state = .idle }
                return
            }

            await MainActor.run {
                self?.discoveredFiles = files
            }

            guard !files.isEmpty else {
                await MainActor.run { self?.state = .complete(fileCount: 0) }
                return
            }

            // 2. Batch ingestion
            let totalFiles = files.count
            await MainActor.run {
                self?.state = .indexing(processed: 0, total: totalFiles)
            }

            let batches = Self.makeBatches(files: files, batchSize: Self.batchSize)
            var processed = 0

            for batch in batches {
                guard !Task.isCancelled else {
                    await MainActor.run { self?.state = .idle }
                    return
                }

                let events = batch.map { filePath in
                    UpdateEngine.FileChangeEvent(
                        filePath: filePath,
                        changeType: .modified
                    )
                }

                _ = await processChanges(events)
                processed += batch.count

                await MainActor.run {
                    self?.state = .indexing(processed: processed, total: totalFiles)
                }

                // Yield between batches to avoid starving the main thread.
                await Task.yield()
            }

            await MainActor.run {
                self?.state = .complete(fileCount: totalFiles)
            }
        }
    }

    /// Cancel any in-progress indexing.
    func cancel() {
        indexingTask?.cancel()
        indexingTask = nil
        state = .idle
    }

    // MARK: - Manifest Scanning

    /// Discover all source files under `rootURL`, respecting extension allowlist
    /// and directory exclusion list.
    ///
    /// Runs synchronously on the calling thread. For large directories, call
    /// from a background context.
    nonisolated static func scanManifest(rootURL: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [String] = []

        for case let fileURL as URL in enumerator {
            // Check if this is a directory we should skip.
            let fileName = fileURL.lastPathComponent
            if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDir {
                if excludedDirectories.contains(fileName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Check extension against allowlist.
            let ext = fileURL.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                files.append(fileURL.path)
            }
        }

        return files.sorted()
    }

    // MARK: - Batching

    /// Split a list of file paths into batches of `batchSize`.
    nonisolated static func makeBatches(files: [String], batchSize: Int) -> [[String]] {
        guard batchSize > 0 else { return [files] }
        var batches: [[String]] = []
        var start = files.startIndex
        while start < files.endIndex {
            let end = files.index(start, offsetBy: batchSize, limitedBy: files.endIndex) ?? files.endIndex
            batches.append(Array(files[start..<end]))
            start = end
        }
        return batches
    }
}

// MARK: - IndexingState

/// The state of directory workspace indexing.
enum IndexingState: Sendable, Equatable {
    /// No indexing in progress.
    case idle
    /// Scanning the directory for source files.
    case scanning
    /// Indexing files through the understanding pipeline.
    case indexing(processed: Int, total: Int)
    /// Indexing complete.
    case complete(fileCount: Int)
    /// Indexing failed.
    case failed(String)

    /// Whether indexing is currently active.
    var isActive: Bool {
        switch self {
        case .scanning, .indexing: return true
        default: return false
        }
    }

    /// Progress fraction (0.0–1.0) if in the `.indexing` state.
    var progressFraction: Double? {
        guard case .indexing(let processed, let total) = self,
              total > 0 else { return nil }
        return Double(processed) / Double(total)
    }
}
