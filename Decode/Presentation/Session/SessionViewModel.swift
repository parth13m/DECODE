import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// UI state for Session Mode.
///
/// Thin wrapper over ``SessionManager`` that provides view-specific state:
/// selected entity, loading indicators, file picker interaction. All session
/// lifecycle (create, parse, watch, persist) is delegated to the manager.
@Observable
@MainActor
final class SessionViewModel {

    // MARK: - UI State

    /// The currently selected entity for the detail panel.
    var selectedEntityID: UUID?

    /// Whether a file operation is in progress.
    private(set) var isLoading = false

    /// Error message from the most recent operation, if any.
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    let sessionManager: SessionManager

    // MARK: - Convenience Accessors

    /// The active session's managed state, or nil.
    var activeSession: ManagedSession? {
        sessionManager.activeSession
    }

    /// The file name of the active session.
    var fileName: String {
        activeSession?.session.fileName ?? "No file selected"
    }

    /// Parsed entities from the active session.
    var parsedEntities: [ParsedEntity] {
        activeSession?.parsedEntities ?? []
    }

    /// Whether the active session's file watcher is running.
    var isWatching: Bool {
        activeSession?.watcherTask != nil
    }

    /// Last refresh timestamp of the active session.
    var lastRefreshedAt: Date? {
        activeSession?.lastRefreshedAt
    }

    /// The selected entity, resolved from the ID.
    var selectedEntity: ParsedEntity? {
        guard let id = selectedEntityID else { return nil }
        return parsedEntities.first { $0.id == id }
    }

    /// All sessions for the session list.
    var allSessions: [ManagedSession] {
        sessionManager.orderedSessions
    }

    /// The active session ID, for highlighting in the session list.
    var activeSessionId: UUID? {
        sessionManager.activeSessionId
    }

    /// The pinned session ID, for showing pin indicator in the UI.
    var pinnedSessionId: UUID? {
        sessionManager.pinnedSessionId
    }

    // MARK: - Init

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: - Restore

    /// Restore all sessions from the database. Call once on view appear.
    func restoreSessions() async {
        await sessionManager.restoreSessions()
    }

    // MARK: - Actions

    /// Whether the session sheet should be auto-presented (e.g., after hotkey open).
    var shouldPresentSession = false

    /// Open a file picker and create/activate a session for the selected file.
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Select a code file"
        panel.allowedContentTypes = Self.supportedCodeTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await loadFile(url: url)
        }
    }

    /// Code file types accepted by the file picker.
    private static let supportedCodeTypes: [UTType] = {
        var types: [UTType] = [.swiftSource]
        // Common code file types by extension.
        let extensions = [
            "py", "js", "ts", "jsx", "tsx", "go", "rs", "java", "kt", "kts",
            "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm",
            "rb", "php", "cs", "scala", "dart", "lua", "r", "R",
            "sh", "bash", "zsh", "fish",
            "html", "css", "scss", "less", "json", "yaml", "yml", "toml", "xml",
            "sql", "graphql", "proto", "cmake",
            "md", "txt", "cfg", "ini", "conf",
        ]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        // Deduplicate (some extensions map to the same UTType).
        return Array(Set(types))
    }()

    /// Create or activate a session for the given URL.
    func loadFile(url: URL) async {
        isLoading = true
        errorMessage = nil
        selectedEntityID = nil

        do {
            try await sessionManager.createSession(url: url)
            isLoading = false
        } catch {
            errorMessage = "Failed to open: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Switch the active session.
    func switchToSession(id: UUID) {
        selectedEntityID = nil
        sessionManager.activateSession(id: id)
    }

    /// Close a session and remove it from memory.
    func closeSession(id: UUID) {
        if selectedEntityID != nil, sessionManager.activeSessionId == id {
            selectedEntityID = nil
        }
        sessionManager.closeSession(id: id)
    }

    /// Pin a session for manual override of automatic resolution.
    /// Unpins if the session is already pinned (toggle behavior).
    func togglePin(id: UUID) {
        if sessionManager.pinnedSessionId == id {
            sessionManager.unpinSession()
        } else {
            sessionManager.pinSession(id: id)
        }
    }
}
