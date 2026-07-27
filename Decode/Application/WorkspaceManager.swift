import CryptoKit
import Foundation
import UpdateEngine

/// Manages the lifecycle of Workspace instances.
///
/// `WorkspaceManager` handles both `.file` and `.directory` workspaces.
/// For `.file` workspaces, behaviour is identical to the former
/// `SessionManager` for the single-file case. For `.directory` workspaces,
/// `IndexingCoordinator` handles batch ingestion through the pipeline.
///
/// ## Workspace Lifecycle
/// ```
/// createFileWorkspace(url:)  → workspace added, set as active, watcher started
/// activateWorkspace(id:)     → activeWorkspaceId updated
/// pinWorkspace(id:)          → pinnedWorkspaceId set (overrides auto-resolution)
/// unpinWorkspace()           → pinnedWorkspaceId cleared
/// closeWorkspace(id:)        → watcher stopped, workspace removed from memory
/// restoreWorkspaces()        → all workspaces loaded from DB, most recent activated
/// ```
@Observable
@MainActor
final class WorkspaceManager {

    // MARK: - State

    /// All in-memory workspaces, keyed by workspace ID.
    private(set) var workspaces: [UUID: ManagedWorkspace] = [:]

    /// The ID of the currently active workspace. Set by explicit user action.
    private(set) var activeWorkspaceId: UUID?

    /// The ID of a pinned workspace. When set, resolution uses this workspace
    /// unconditionally, bypassing automatic resolution. Set by explicit user
    /// action (e.g., dock context menu "Pin Workspace").
    private(set) var pinnedWorkspaceId: UUID?

    /// Ordered list of workspaces for UI display, sorted by most recently updated.
    var orderedWorkspaces: [ManagedWorkspace] {
        workspaces.values.sorted { $0.workspace.updatedAt > $1.workspace.updatedAt }
    }

    /// The active workspace, if any.
    var activeWorkspace: ManagedWorkspace? {
        guard let id = activeWorkspaceId else { return nil }
        return workspaces[id]
    }

    // MARK: - Dependencies

    private let swiftParser: SwiftSyntaxParser
    private let treeSitterParser: TreeSitterParser
    private let database: DatabaseService?

    /// Bridge for forwarding file change events to the understanding pipeline.
    /// Called when a workspace's watched file is modified. The closure receives
    /// the file path and change kind.
    var onFileChanged: ((_ filePath: String, _ kind: FileChangeKind) -> Void)?

    /// Pipeline batch ingestion closure. Set by AppDependencies to route
    /// file change events through `UnderstandingSystem.processChanges()`.
    /// Used by `IndexingCoordinator` for directory workspace ingestion.
    var processChanges: (@Sendable ([UpdateEngine.FileChangeEvent]) async -> UpdateEngine.ChangeSetResult)?

    /// File extensions that receive full SwiftSyntax AST parsing.
    private static let swiftExtensions: Set<String> = ["swift"]

    // MARK: - Init

    init(
        swiftParser: SwiftSyntaxParser = SwiftSyntaxParser(),
        treeSitterParser: TreeSitterParser = TreeSitterParser(),
        database: DatabaseService? = nil
    ) {
        self.swiftParser = swiftParser
        self.treeSitterParser = treeSitterParser
        self.database = database
    }

    /// Whether the given URL is a Swift source file eligible for AST parsing.
    private func isSwiftFile(_ url: URL) -> Bool {
        Self.swiftExtensions.contains(url.pathExtension.lowercased())
    }

    /// Parse a file using the appropriate parser and extract all deterministic facts.
    private func parseFile(source: String, url: URL) -> DetailedParseResult {
        let fileName = url.lastPathComponent
        if isSwiftFile(url) {
            return swiftParser.parseAllFacts(source: source, fileName: fileName)
        }
        return treeSitterParser.parseAllFacts(source: source, fileName: fileName)
    }

    /// Assemble a ``FileIntelligence`` from the results of parsing.
    private func buildFileIntelligence(
        workspaceId: UUID,
        fileName: String,
        filePath: String,
        fileHash: String,
        parseResult: DetailedParseResult,
        source: String
    ) -> FileIntelligence {
        let language = Self.detectLanguage(fileName: fileName)
        let newlineCount = source.filter { $0 == "\n" }.count
        let lineCount = source.isEmpty ? 0 : newlineCount + 1
        let outline = Self.buildStructureOutline(entities: parseResult.entities)

        let identity = FileIdentityClassifier.classify(
            fileName: fileName,
            entities: parseResult.entities,
            language: language,
            filePath: filePath
        )

        let purpose = FilePurposeDeriver.derivePurpose(
            fileName: fileName,
            identity: identity,
            entities: parseResult.entities
        )

        return FileIntelligence(
            sessionId: workspaceId,
            fileName: fileName,
            language: language,
            lineCount: lineCount,
            entities: parseResult.entities,
            structureOutline: outline,
            imports: parseResult.imports,
            relationships: parseResult.relationships,
            identity: identity,
            purpose: purpose,
            fileHash: fileHash,
            buildDate: Date()
        )
    }

    /// Detect the programming language from a file name.
    private static func detectLanguage(fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "swift" { return "swift" }
        if let grammar = GrammarRegistration.from(fileName: fileName) {
            return grammar.queryDirectory
        }
        return extensionToLanguage[ext] ?? ext
    }

    /// Extension-to-language fallback for files without parser support.
    private static let extensionToLanguage: [String: String] = [
        "rb": "ruby", "go": "go", "rs": "rust", "kt": "kotlin",
        "m": "objectivec", "mm": "objectivec", "sh": "bash",
        "zsh": "bash", "json": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "toml", "xml": "xml", "sql": "sql", "md": "markdown",
        "r": "r", "lua": "lua", "php": "php", "dart": "dart",
        "scala": "scala", "zig": "zig", "ex": "elixir", "exs": "elixir",
    ]

    /// Build a structure outline string from parsed entities.
    ///
    /// Produces a hierarchical text outline showing all entities with their
    /// line ranges, suitable for display in the Knowledge Inspector and
    /// as context for AI prompts.
    static func buildStructureOutline(entities: [ParsedEntity]) -> String {
        var lines: [String] = []

        let topLevel = entities.filter { $0.isTopLevel }
        let children = entities.filter { !$0.isTopLevel }

        var childrenByParent: [String: [ParsedEntity]] = [:]
        for child in children {
            if let pid = child.parentStableId {
                childrenByParent[pid, default: []].append(child)
            }
        }

        for parent in topLevel {
            lines.append("\(parent.signature) [lines \(parent.startLine)-\(parent.endLine)]")
            let kids = childrenByParent[parent.entity.stableId] ?? []
            for child in kids {
                lines.append("  \(child.signature) [lines \(child.startLine)-\(child.endLine)]")
            }
        }

        // Orphaned children (parent not in top-level list).
        let knownParents = Set(topLevel.map(\.entity.stableId))
        let orphans = children.filter {
            guard let pid = $0.parentStableId else { return false }
            return !knownParents.contains(pid)
        }
        for orphan in orphans {
            lines.append("\(orphan.signature) [lines \(orphan.startLine)-\(orphan.endLine)]")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Workspace Lifecycle

    /// Create a new `.file` workspace for the given file URL, or reactivate an existing one.
    ///
    /// If a workspace already exists for this file path, it is re-parsed and activated.
    /// Otherwise, a new workspace is created, persisted, and activated.
    ///
    /// Rejects files that are too large (>512 KB) or appear to be binary.
    func createFileWorkspace(url: URL) async throws {
        // Guard: file size.
        let size = fileSize(url)
        guard size <= AILimits.maxFileSizeBytes else {
            throw WorkspaceError.fileTooLarge
        }

        // Guard: binary file detection.
        if isBinaryFile(url) {
            throw WorkspaceError.binaryFile
        }

        // Check if we already have an in-memory workspace for this path.
        if let existing = workspaces.values.first(where: { $0.workspace.rootPath == url.path }) {
            await reparseFileWorkspace(id: existing.workspace.id)
            activateWorkspace(id: existing.workspace.id)
            return
        }

        // Check if a persisted workspace exists for this path.
        if let db = database {
            let allWorkspaces = try await db.fetchAllWorkspaces()
            if let persisted = allWorkspaces.first(where: { $0.rootPath == url.path }) {
                let source = try String(contentsOf: url, encoding: .utf8)
                let result = parseFile(source: source, url: url)
                let currentHash = sha256(source)

                let intelligence = buildFileIntelligence(
                    workspaceId: persisted.id,
                    fileName: persisted.rootFileName,
                    filePath: persisted.rootPath,
                    fileHash: currentHash,
                    parseResult: result,
                    source: source
                )
                let managed = ManagedWorkspace(
                    workspace: persisted,
                    parsedEntities: result.entities,
                    fileIntelligence: intelligence
                )
                workspaces[persisted.id] = managed
                startWatching(managed: managed)
                activateWorkspace(id: persisted.id)

                // Sync if file changed since last persistence.
                if currentHash != persisted.rootPath {
                    var updated = persisted
                    updated.updatedAt = Date()
                    try await db.updateWorkspace(updated)
                    workspaces[persisted.id]?.workspace = updated
                }
                return
            }
        }

        // Create a brand new workspace.
        let source = try String(contentsOf: url, encoding: .utf8)
        let result = parseFile(source: source, url: url)
        let now = Date()
        let workspace = Workspace(
            id: UUID(),
            kind: .file,
            createdAt: now,
            updatedAt: now,
            bookmarkData: bookmarkData(for: url),
            rootPath: url.path,
            rootFileName: url.lastPathComponent,
            summaryText: "",
            isCorrupted: false
        )

        if let db = database {
            try await db.createWorkspace(workspace)
        }

        let intelligence = buildFileIntelligence(
            workspaceId: workspace.id,
            fileName: workspace.rootFileName,
            filePath: workspace.rootPath,
            fileHash: sha256(source),
            parseResult: result,
            source: source
        )
        let managed = ManagedWorkspace(
            workspace: workspace,
            parsedEntities: result.entities,
            fileIntelligence: intelligence
        )
        workspaces[workspace.id] = managed
        startWatching(managed: managed)
        activateWorkspace(id: workspace.id)
    }

    /// Create a new `.directory` workspace for the given directory URL.
    ///
    /// If a workspace already exists for this path, it is reactivated.
    /// Otherwise, a new workspace is created, persisted, and indexing begins.
    func createDirectoryWorkspace(url: URL) async throws {
        // Check if we already have an in-memory workspace for this path.
        if let existing = workspaces.values.first(where: { $0.workspace.rootPath == url.path }) {
            activateWorkspace(id: existing.workspace.id)
            return
        }

        // Check if a persisted workspace exists for this path.
        if let db = database {
            let allWorkspaces = try await db.fetchAllWorkspaces()
            if let persisted = allWorkspaces.first(where: { $0.rootPath == url.path }) {
                let managed = ManagedWorkspace(
                    workspace: persisted,
                    parsedEntities: []
                )
                workspaces[persisted.id] = managed
                activateWorkspace(id: persisted.id)
                startIndexing(managed: managed)
                return
            }
        }

        // Create a brand new directory workspace.
        let now = Date()
        let workspace = Workspace(
            id: UUID(),
            kind: .directory,
            createdAt: now,
            updatedAt: now,
            bookmarkData: bookmarkData(for: url),
            rootPath: url.path,
            rootFileName: url.lastPathComponent,
            summaryText: "",
            isCorrupted: false
        )

        if let db = database {
            try await db.createWorkspace(workspace)
        }

        let managed = ManagedWorkspace(
            workspace: workspace,
            parsedEntities: []
        )
        workspaces[workspace.id] = managed
        activateWorkspace(id: workspace.id)
        startIndexing(managed: managed)
    }

    // MARK: - Directory Indexing

    /// Start indexing for a `.directory` workspace.
    private func startIndexing(managed: ManagedWorkspace) {
        guard managed.workspace.kind == .directory else { return }
        guard let processChanges else {
            #if DEBUG
            print("[WorkspaceManager] Cannot index: processChanges not set")
            #endif
            return
        }

        let coordinator = IndexingCoordinator()
        managed.indexingCoordinator = coordinator
        coordinator.start(
            rootPath: managed.workspace.rootPath,
            processChanges: processChanges
        )

        // Start directory watching for live file changes.
        startDirectoryWatching(managed: managed)
    }

    // MARK: - Directory Watching

    /// Start recursive directory watching for a `.directory` workspace.
    /// Changes are routed through `onFileChanged` to the understanding pipeline.
    private func startDirectoryWatching(managed: ManagedWorkspace) {
        guard managed.workspace.kind == .directory else { return }

        let dirURL = URL(fileURLWithPath: managed.workspace.rootPath)
        let eventStream = managed.directoryWatcher.startWatching(directoryURL: dirURL)
        let workspaceId = managed.workspace.id

        managed.directoryWatcherTask = Task { [weak self] in
            for await batch in eventStream {
                guard let self, !Task.isCancelled else { break }

                for event in batch {
                    self.onFileChanged?(event.fileURL.path, event.kind)
                }
            }

            // If stream ends, mark workspace as potentially stale.
            #if DEBUG
            print("[WorkspaceManager] Directory watcher stream ended for workspace \(workspaceId)")
            #endif
        }
    }

    /// Set the active workspace by ID. The workspace must exist in `workspaces`.
    func activateWorkspace(id: UUID) {
        guard workspaces[id] != nil else { return }
        activeWorkspaceId = id
    }

    /// Pin a workspace for manual override of automatic resolution.
    func pinWorkspace(id: UUID) {
        guard workspaces[id] != nil else { return }
        pinnedWorkspaceId = id
    }

    /// Unpin the currently pinned workspace, restoring automatic resolution.
    func unpinWorkspace() {
        pinnedWorkspaceId = nil
    }

    /// Close a workspace: stop its watcher and remove from memory.
    /// The workspace remains in the database for future restoration.
    func closeWorkspace(id: UUID) {
        guard let managed = workspaces[id] else { return }
        managed.stopWatching()
        managed.indexingCoordinator?.cancel()
        workspaces.removeValue(forKey: id)

        if pinnedWorkspaceId == id {
            pinnedWorkspaceId = nil
        }

        if activeWorkspaceId == id {
            activeWorkspaceId = orderedWorkspaces.first?.workspace.id
        }
    }

    /// Restore all workspaces from the database on app launch.
    /// The most recently updated workspace becomes active.
    func restoreWorkspaces() async {
        guard let db = database else { return }

        do {
            let allWorkspaces = try await db.fetchAllWorkspaces()

            for stored in allWorkspaces {
                let url = URL(fileURLWithPath: stored.rootPath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }

                // Directory workspaces: create managed workspace and re-index.
                if stored.kind == .directory {
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                          isDir.boolValue else { continue }
                    let managed = ManagedWorkspace(
                        workspace: stored,
                        parsedEntities: []
                    )
                    workspaces[stored.id] = managed
                    startIndexing(managed: managed)
                    continue
                }

                do {
                    let source = try String(contentsOf: url, encoding: .utf8)
                    let result = parseFile(source: source, url: url)
                    let currentHash = sha256(source)

                    let managed = ManagedWorkspace(
                        workspace: stored,
                        parsedEntities: result.entities
                    )
                    workspaces[stored.id] = managed
                    startWatching(managed: managed)

                    // Sync if changed while app was closed.
                    var workspaceForIntelligence = stored
                    if currentHash != stored.summaryText {
                        // Note: Workspace doesn't store fileHash — we track
                        // staleness via updatedAt. Just refresh the timestamp.
                        var updated = stored
                        updated.updatedAt = Date()
                        try await db.updateWorkspace(updated)
                        workspaces[stored.id]?.workspace = updated
                        workspaceForIntelligence = updated
                    }

                    let intelligence = buildFileIntelligence(
                        workspaceId: workspaceForIntelligence.id,
                        fileName: workspaceForIntelligence.rootFileName,
                        filePath: workspaceForIntelligence.rootPath,
                        fileHash: currentHash,
                        parseResult: result,
                        source: source
                    )
                    workspaces[stored.id]?.fileIntelligence = intelligence
                } catch {
                    #if DEBUG
                    print("[WorkspaceManager] Failed to restore workspace \(stored.rootFileName): \(error)")
                    #endif
                }
            }

            activeWorkspaceId = orderedWorkspaces.first?.workspace.id
        } catch {
            #if DEBUG
            print("[WorkspaceManager] Failed to load workspaces: \(error)")
            #endif
        }
    }

    // MARK: - File Watching

    private func startWatching(managed: ManagedWorkspace) {
        guard managed.workspace.kind == .file else { return }

        let fileURL = URL(fileURLWithPath: managed.workspace.rootPath)
        let eventStream = managed.fileWatcher.startWatching(fileURL: fileURL)
        let workspaceId = managed.workspace.id

        managed.watcherTask = Task { [weak self] in
            for await event in eventStream {
                guard let self, !Task.isCancelled else { break }

                self.onFileChanged?(event.fileURL.path, event.kind)

                switch event.kind {
                case .modified:
                    await self.reparseFileWorkspace(id: workspaceId)
                case .deleted:
                    self.workspaces[workspaceId]?.isFileAccessible = false
                case .moved(let newURL):
                    if let newURL {
                        self.workspaces[workspaceId]?.workspace.rootPath = newURL.path
                        self.workspaces[workspaceId]?.workspace.rootFileName = newURL.lastPathComponent
                        await self.reparseFileWorkspace(id: workspaceId)
                    } else {
                        self.workspaces[workspaceId]?.isFileAccessible = false
                    }
                case .inaccessible:
                    self.workspaces[workspaceId]?.isFileAccessible = false
                }
            }
        }
    }

    /// Re-parse a file workspace's source and rebuild intelligence.
    private func reparseFileWorkspace(id: UUID) async {
        guard let managed = workspaces[id],
              managed.workspace.kind == .file else { return }
        let url = URL(fileURLWithPath: managed.workspace.rootPath)

        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let result = parseFile(source: source, url: url)
            workspaces[id]?.parsedEntities = result.entities
            workspaces[id]?.lastRefreshedAt = Date()
            workspaces[id]?.isFileAccessible = true

            var currentWorkspace = managed.workspace
            if let db = database {
                var updated = managed.workspace
                updated.updatedAt = Date()
                try await db.updateWorkspace(updated)
                workspaces[id]?.workspace = updated
                currentWorkspace = updated
            }

            let intelligence = buildFileIntelligence(
                workspaceId: currentWorkspace.id,
                fileName: currentWorkspace.rootFileName,
                filePath: currentWorkspace.rootPath,
                fileHash: sha256(source),
                parseResult: result,
                source: source
            )
            workspaces[id]?.fileIntelligence = intelligence
        } catch {
            #if DEBUG
            print("[WorkspaceManager] Reparse failed for \(managed.workspace.rootFileName): \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    private func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func bookmarkData(for url: URL) -> Data {
        (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
    }

    private func isBinaryFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: AILimits.binaryDetectionSampleBytes) else { return false }
        return sample.contains(0x00)
    }
}

// MARK: - WorkspaceError

/// Errors specific to workspace creation validation.
enum WorkspaceError: LocalizedError {
    case fileTooLarge
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "File too large (>512 KB)."
        case .binaryFile:
            return "This file appears to be binary and cannot be used."
        }
    }
}

// MARK: - ManagedWorkspace

/// Runtime state for a single tracked workspace.
///
/// Bundles the persisted ``Workspace`` with in-memory state: parsed entities,
/// file intelligence, file watcher, and watcher task. For `.file` workspaces,
/// this is the sole workspace state container.
@Observable
@MainActor
final class ManagedWorkspace: Identifiable {
    /// Stable identity, captured at init from the Workspace's ID.
    nonisolated let id: UUID

    var workspace: Workspace
    var parsedEntities: [ParsedEntity]
    var fileIntelligence: FileIntelligence?

    /// Per-file entity map for `.directory` workspaces. Maps file paths to
    /// their parsed entities. For `.file` workspaces, contains a single entry
    /// keyed by `workspace.rootPath`.
    var parsedEntitiesByFile: [String: [ParsedEntity]] = [:]
    var lastRefreshedAt: Date?
    var isFileAccessible: Bool = true

    /// Metadata from the most recent question answered for this workspace.
    /// Set by ``SessionQuestionCoordinator`` after prompt construction.
    /// `nil` until the first question is asked.
    var lastQuestionContext: QuestionContext?

    /// Indexing coordinator for `.directory` workspaces. `nil` for `.file` workspaces.
    var indexingCoordinator: IndexingCoordinator?

    /// Recursive directory watcher for `.directory` workspaces.
    let directoryWatcher: DirectoryWatcherService

    let fileWatcher: FileWatcherService
    var watcherTask: Task<Void, Never>?

    /// Task consuming the directory watcher's event stream.
    var directoryWatcherTask: Task<Void, Never>?

    init(
        workspace: Workspace,
        parsedEntities: [ParsedEntity],
        fileIntelligence: FileIntelligence? = nil,
        fileWatcher: FileWatcherService = FileWatcherService(),
        directoryWatcher: DirectoryWatcherService = DirectoryWatcherService()
    ) {
        self.id = workspace.id
        self.workspace = workspace
        self.parsedEntities = parsedEntities
        self.fileIntelligence = fileIntelligence
        self.fileWatcher = fileWatcher
        self.directoryWatcher = directoryWatcher
        self.lastRefreshedAt = Date()
    }

    func stopWatching() {
        watcherTask?.cancel()
        watcherTask = nil
        fileWatcher.stopWatching()
        directoryWatcherTask?.cancel()
        directoryWatcherTask = nil
        directoryWatcher.stopWatching()
    }
}
