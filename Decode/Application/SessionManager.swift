import CryptoKit
import Foundation

/// Manages the lifecycle of multiple concurrent Sessions.
///
/// Each session is a file-scoped knowledge container: parsed entities, file
/// watcher, and database records. The manager tracks all sessions and provides
/// both manual session selection and automatic resolution support.
///
/// ## Session Resolution
/// The ``SessionQuestionCoordinator`` uses ``SessionResolver`` to automatically
/// determine which session a code snippet belongs to. ``activeSessionId`` serves
/// as a fallback when automatic resolution has low confidence, and
/// ``pinnedSessionId`` provides unconditional manual override.
///
/// ## Session Lifecycle
/// ```
/// createSession(url:) → session added to `sessions`, set as active, watcher started
/// activateSession(id:) → activeSessionId updated
/// pinSession(id:) → pinnedSessionId set (overrides auto-resolution)
/// unpinSession() → pinnedSessionId cleared
/// closeSession(id:) → watcher stopped, session removed from memory (stays in DB)
/// restoreSessions() → all sessions loaded from DB, most recent activated
/// ```
@Observable
@MainActor
final class SessionManager {

    // MARK: - State

    /// All in-memory sessions, keyed by session ID.
    private(set) var sessions: [UUID: ManagedSession] = [:]

    /// The ID of the currently active session. Set by explicit user action.
    private(set) var activeSessionId: UUID?

    /// The ID of a pinned session. When set, the ``SessionResolver`` uses this
    /// session unconditionally, bypassing automatic resolution. Set by explicit
    /// user action (e.g., dock context menu "Pin Session").
    private(set) var pinnedSessionId: UUID?

    /// Ordered list of sessions for UI display, sorted by most recently updated.
    var orderedSessions: [ManagedSession] {
        sessions.values.sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    /// The active session, if any.
    var activeSession: ManagedSession? {
        guard let id = activeSessionId else { return nil }
        return sessions[id]
    }

    /// Snapshot for the ``SessionQuestionCoordinator``.
    /// Returns `nil` if no session is active.
    var activeSessionSnapshot: ActiveSessionSnapshot? {
        guard let managed = activeSession else {
            return nil
        }
        return ActiveSessionSnapshot(
            session: managed.session,
            parsedEntities: managed.parsedEntities
        )
    }

    // MARK: - Dependencies

    private let swiftParser: SwiftSyntaxParser
    private let treeSitterParser: TreeSitterParser
    private let database: DatabaseService?

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
    ///
    /// Routes Swift files to ``SwiftSyntaxParser`` and supported non-Swift
    /// files to ``TreeSitterParser``. Returns an empty result for unsupported
    /// file types.
    private func parseFile(source: String, url: URL) -> DetailedParseResult {
        let fileName = url.lastPathComponent
        if isSwiftFile(url) {
            return swiftParser.parseAllFacts(source: source, fileName: fileName)
        }
        return treeSitterParser.parseAllFacts(source: source, fileName: fileName)
    }

    /// Assemble a ``FileIntelligence`` from the results of parsing.
    ///
    /// This captures all deterministic structural knowledge about a file
    /// immediately after parsing completes, plus understanding layers
    /// derived from the structural data. The intelligence is keyed to
    /// the file's current hash so it can be invalidated on file change.
    private func buildFileIntelligence(
        session: Session,
        parseResult: DetailedParseResult,
        source: String
    ) -> FileIntelligence {
        let language = Self.detectLanguage(fileName: session.fileName)
        let newlineCount = source.filter { $0 == "\n" }.count
        let lineCount = source.isEmpty ? 0 : newlineCount + 1
        let outline = Self.buildStructureOutline(entities: parseResult.entities)

        // Understanding Layer 1: Identity — "What am I looking at?"
        let identity = FileIdentityClassifier.classify(
            fileName: session.fileName,
            entities: parseResult.entities,
            language: language,
            filePath: session.filePath
        )

        // Understanding Layer 2: Purpose — "Why does this file exist?"
        let purpose = FilePurposeDeriver.derivePurpose(
            fileName: session.fileName,
            identity: identity,
            entities: parseResult.entities
        )

        return FileIntelligence(
            sessionId: session.id,
            fileName: session.fileName,
            language: language,
            lineCount: lineCount,
            entities: parseResult.entities,
            structureOutline: outline,
            imports: parseResult.imports,
            relationships: parseResult.relationships,
            identity: identity,
            purpose: purpose,
            fileHash: session.fileHash,
            buildDate: Date()
        )
    }

    /// Detect the programming language from a file name.
    ///
    /// Uses ``GrammarRegistration`` for languages with parser support,
    /// falls back to a simple extension map for others, and defaults
    /// to "swift" for `.swift` files.
    private static func detectLanguage(fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()

        // Swift is handled by SwiftSyntaxParser, not GrammarRegistration.
        if ext == "swift" { return "swift" }

        // Languages with tree-sitter parser support.
        if let grammar = GrammarRegistration.from(fileName: fileName) {
            return grammar.queryDirectory // e.g., "python", "javascript"
        }

        // Fallback for recognized extensions without parser support.
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

    /// Build an unmarked hierarchical outline of a file's entity structure.
    ///
    /// Top-level entities are unindented. Members are indented under their
    /// parent type. This is the baseline outline stored on ``FileIntelligence``.
    /// Snippet-specific markers (e.g., `← selected`) are added later by
    /// ``ContextBuilderService`` when building prompt context.
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

    // MARK: - Session Lifecycle

    /// Create a new session for the given file URL, or reactivate an existing one.
    ///
    /// If a session already exists for this file path, it is re-parsed and activated.
    /// Otherwise, a new session is created, persisted, and activated.
    ///
    /// Rejects files that are too large (>512 KB) or appear to be binary.
    func createSession(url: URL) async throws {
        // Guard: file size.
        let size = fileSize(url)
        guard size <= AILimits.maxFileSizeBytes else {
            throw SessionError.fileTooLarge
        }

        // Guard: binary file detection (scan first 8 KB for null bytes).
        if isBinaryFile(url) {
            throw SessionError.binaryFile
        }

        // Check if we already have an in-memory session for this file.
        if let existing = sessions.values.first(where: { $0.session.filePath == url.path }) {
            // Reactivate and re-parse.
            await reparseSession(id: existing.session.id)
            activateSession(id: existing.session.id)
            return
        }

        // Check if a persisted session exists for this file.
        if let db = database {
            let allSessions = try await db.fetchAllSessions()
            if let persisted = allSessions.first(where: { $0.filePath == url.path }) {
                // Restore from database.
                let source = try String(contentsOf: url, encoding: .utf8)
                let result = parseFile(source: source, url: url)

                let intelligence = buildFileIntelligence(session: persisted, parseResult: result, source: source)
                let managed = ManagedSession(session: persisted, parsedEntities: result.entities, fileIntelligence: intelligence)
                sessions[persisted.id] = managed
                startWatching(managed: managed)
                activateSession(id: persisted.id)

                // Sync if file changed.
                let currentHash = sha256(source)
                if currentHash != persisted.fileHash {
                    var updated = persisted
                    updated.updatedAt = Date()
                    updated.fileHash = currentHash
                    updated.fileModifiedAt = fileModificationDate(url) ?? Date()
                    updated.fileSize = fileSize(url)
                    try await db.updateSession(updated)
                    sessions[persisted.id]?.session = updated
                    try await syncEntitiesToDatabase(sessionId: persisted.id)
                }
                return
            }
        }

        // Create a brand new session.
        let source = try String(contentsOf: url, encoding: .utf8)
        let result = parseFile(source: source, url: url)
        let now = Date()
        let session = Session(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            bookmarkData: bookmarkData(for: url),
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileSize: fileSize(url),
            fileModifiedAt: fileModificationDate(url) ?? now,
            fileHash: sha256(source),
            summaryText: "",
            isCorrupted: false
        )

        if let db = database {
            try await db.createSession(session)
        }

        let intelligence = buildFileIntelligence(session: session, parseResult: result, source: source)
        let managed = ManagedSession(session: session, parsedEntities: result.entities, fileIntelligence: intelligence)
        sessions[session.id] = managed
        startWatching(managed: managed)
        activateSession(id: session.id)

        // Persist entities.
        if database != nil {
            try await syncEntitiesToDatabase(sessionId: session.id)
        }
    }

    /// Set the active session by ID. The session must exist in `sessions`.
    func activateSession(id: UUID) {
        guard sessions[id] != nil else { return }
        activeSessionId = id
    }

    /// Pin a session for manual override of automatic resolution.
    ///
    /// When pinned, the ``SessionResolver`` always returns this session
    /// regardless of snippet content. Pin is cleared when the session is closed.
    func pinSession(id: UUID) {
        guard sessions[id] != nil else { return }
        pinnedSessionId = id
    }

    /// Unpin the currently pinned session, restoring automatic resolution.
    func unpinSession() {
        pinnedSessionId = nil
    }

    /// Close a session: stop its watcher and remove from memory.
    /// The session remains in the database for future restoration.
    func closeSession(id: UUID) {
        guard let managed = sessions[id] else { return }
        managed.stopWatching()
        sessions.removeValue(forKey: id)

        // Clear pin if the closed session was pinned.
        if pinnedSessionId == id {
            pinnedSessionId = nil
        }

        // If we closed the active session, activate the next most recent.
        if activeSessionId == id {
            activeSessionId = orderedSessions.first?.session.id
        }
    }

    /// Restore all sessions from the database on app launch.
    /// The most recently updated session becomes active.
    func restoreSessions() async {
        guard let db = database else { return }

        do {
            let allSessions = try await db.fetchAllSessions()

            for stored in allSessions {
                let url = URL(fileURLWithPath: stored.filePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }

                do {
                    let source = try String(contentsOf: url, encoding: .utf8)
                    let result = parseFile(source: source, url: url)

                    var sessionForIntelligence = stored
                    let managed = ManagedSession(session: stored, parsedEntities: result.entities)
                    sessions[stored.id] = managed
                    startWatching(managed: managed)

                    // Sync if changed while app was closed.
                    let currentHash = sha256(source)
                    if currentHash != stored.fileHash {
                        var updated = stored
                        updated.updatedAt = Date()
                        updated.fileHash = currentHash
                        updated.fileModifiedAt = fileModificationDate(url) ?? Date()
                        updated.fileSize = fileSize(url)
                        try await db.updateSession(updated)
                        sessions[stored.id]?.session = updated
                        sessionForIntelligence = updated
                        try await syncEntitiesToDatabase(sessionId: stored.id)
                    }

                    // Build intelligence after session is fully up to date.
                    let intelligence = buildFileIntelligence(
                        session: sessionForIntelligence,
                        parseResult: result,
                        source: source
                    )
                    sessions[stored.id]?.fileIntelligence = intelligence
                } catch {
                    #if DEBUG
                    print("[SessionManager] Failed to restore session \(stored.fileName): \(error)")
                    #endif
                }
            }

            // Activate the most recently updated session.
            activeSessionId = orderedSessions.first?.session.id
        } catch {
            #if DEBUG
            print("[SessionManager] Failed to load sessions: \(error)")
            #endif
        }
    }

    // MARK: - File Watching

    private func startWatching(managed: ManagedSession) {
        let fileURL = URL(fileURLWithPath: managed.session.filePath)
        let eventStream = managed.fileWatcher.startWatching(fileURL: fileURL)
        let sessionId = managed.session.id

        managed.watcherTask = Task { [weak self] in
            for await event in eventStream {
                guard let self, !Task.isCancelled else { break }

                switch event.kind {
                case .modified:
                    await self.reparseSession(id: sessionId)
                case .deleted:
                    self.sessions[sessionId]?.isFileAccessible = false
                case .moved(let newURL):
                    if let newURL {
                        self.sessions[sessionId]?.session.filePath = newURL.path
                        self.sessions[sessionId]?.session.fileName = newURL.lastPathComponent
                        await self.reparseSession(id: sessionId)
                    } else {
                        self.sessions[sessionId]?.isFileAccessible = false
                    }
                case .inaccessible:
                    self.sessions[sessionId]?.isFileAccessible = false
                }
            }
        }
    }

    /// Re-parse a session's file and sync to database.
    private func reparseSession(id: UUID) async {
        guard let managed = sessions[id] else { return }
        let url = URL(fileURLWithPath: managed.session.filePath)

        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let result = parseFile(source: source, url: url)
            sessions[id]?.parsedEntities = result.entities
            sessions[id]?.lastRefreshedAt = Date()
            sessions[id]?.isFileAccessible = true

            // Sync to database.
            var currentSession = managed.session
            if let db = database {
                var updated = managed.session
                updated.updatedAt = Date()
                updated.fileHash = sha256(source)
                updated.fileModifiedAt = fileModificationDate(url) ?? Date()
                updated.fileSize = fileSize(url)
                try await db.updateSession(updated)
                sessions[id]?.session = updated
                currentSession = updated
                try await syncEntitiesToDatabase(sessionId: id)
            }

            // Rebuild intelligence from fresh parse.
            let intelligence = buildFileIntelligence(
                session: currentSession,
                parseResult: result,
                source: source
            )
            sessions[id]?.fileIntelligence = intelligence
        } catch {
            #if DEBUG
            print("[SessionManager] Reparse failed for \(managed.session.fileName): \(error)")
            #endif
        }
    }

    // MARK: - Entity Sync

    private func syncEntitiesToDatabase(sessionId: UUID) async throws {
        guard let db = database, let managed = sessions[sessionId] else { return }

        let storedEntities = try await db.fetchEntities(sessionId: sessionId)
        let storedByStableId = Dictionary(uniqueKeysWithValues: storedEntities.map { ($0.stableId, $0) })

        let currentEntities = managed.parsedEntities.map(\.entity)
        let currentByStableId = Dictionary(uniqueKeysWithValues: currentEntities.map { ($0.stableId, $0) })

        // Delete removed entities.
        let deletedIds = storedEntities
            .filter { currentByStableId[$0.stableId] == nil }
            .map(\.id)
        if !deletedIds.isEmpty {
            try await db.deleteEntities(ids: deletedIds)
        }

        // Insert or update.
        for entity in currentEntities {
            if let stored = storedByStableId[entity.stableId] {
                if stored.hash != entity.hash || stored.name != entity.name {
                    let updated = CodeEntity(
                        id: stored.id,
                        sessionId: sessionId,
                        stableId: entity.stableId,
                        entityType: entity.entityType,
                        name: entity.name,
                        summaryText: stored.summaryText,
                        hash: entity.hash,
                        lastUpdated: Date()
                    )
                    try await db.updateEntity(updated)
                }
            } else {
                let newEntity = CodeEntity(
                    id: entity.id,
                    sessionId: sessionId,
                    stableId: entity.stableId,
                    entityType: entity.entityType,
                    name: entity.name,
                    summaryText: "",
                    hash: entity.hash,
                    lastUpdated: Date()
                )
                try await db.createEntity(newEntity)
            }
        }
    }

    // MARK: - Helpers

    private func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func bookmarkData(for url: URL) -> Data {
        (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
    }

    /// Check if a file appears to be binary by scanning for null bytes.
    ///
    /// Reads the first `AILimits.binaryDetectionSampleBytes` bytes and checks
    /// for the presence of `0x00`. UTF-8 text files never contain null bytes.
    private func isBinaryFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: AILimits.binaryDetectionSampleBytes) else { return false }
        return sample.contains(0x00)
    }
}

// MARK: - SessionError

/// Errors specific to session creation validation.
enum SessionError: LocalizedError {
    case fileTooLarge
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "File too large (>512 KB)."
        case .binaryFile:
            return "This file appears to be binary and cannot be used in Session Mode."
        }
    }
}

// MARK: - ManagedSession

/// Runtime state for a single tracked session.
///
/// Bundles the persisted ``Session`` with in-memory state: parsed entities,
/// file watcher, and watcher task. Each ``ManagedSession`` is independent —
/// multiple sessions can watch different files concurrently.
@Observable
@MainActor
final class ManagedSession: Identifiable {
    /// Stable identity, captured at init from the Session's ID.
    /// `nonisolated` to satisfy `Identifiable` from a `@MainActor` class.
    nonisolated let id: UUID

    var session: Session
    var parsedEntities: [ParsedEntity]
    var fileIntelligence: FileIntelligence?
    var lastRefreshedAt: Date?
    var isFileAccessible: Bool = true

    /// Metadata from the most recent question answered for this session.
    /// Set by ``SessionQuestionCoordinator`` after prompt construction.
    /// `nil` until the first question is asked.
    var lastQuestionContext: QuestionContext?

    let fileWatcher: FileWatcherService
    var watcherTask: Task<Void, Never>?

    init(
        session: Session,
        parsedEntities: [ParsedEntity],
        fileIntelligence: FileIntelligence? = nil,
        fileWatcher: FileWatcherService = FileWatcherService()
    ) {
        self.id = session.id
        self.session = session
        self.parsedEntities = parsedEntities
        self.fileIntelligence = fileIntelligence
        self.fileWatcher = fileWatcher
        self.lastRefreshedAt = Date()
    }

    func stopWatching() {
        watcherTask?.cancel()
        watcherTask = nil
        fileWatcher.stopWatching()
    }
}
