import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// UI state for Session Mode.
///
/// Thin wrapper over ``WorkspaceManager`` that provides view-specific state:
/// selected entity, loading indicators, file picker interaction. All workspace
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

    /// Navigation state for `.directory` workspaces — tracks active file and entity.
    let navigationState = NavigationState()

    // MARK: - Dependencies

    let workspaceManager: WorkspaceManager

    // MARK: - Convenience Accessors

    /// The active workspace's managed state, or nil.
    var activeWorkspace: ManagedWorkspace? {
        workspaceManager.activeWorkspace
    }

    /// The file name of the active workspace.
    var fileName: String {
        activeWorkspace?.workspace.rootFileName ?? "No file selected"
    }

    /// Parsed entities from the active workspace.
    var parsedEntities: [ParsedEntity] {
        activeWorkspace?.parsedEntities ?? []
    }

    /// Whether the active workspace's file watcher is running.
    var isWatching: Bool {
        activeWorkspace?.watcherTask != nil
    }

    /// Last refresh timestamp of the active workspace.
    var lastRefreshedAt: Date? {
        activeWorkspace?.lastRefreshedAt
    }

    /// The selected entity, resolved from the ID.
    var selectedEntity: ParsedEntity? {
        guard let id = selectedEntityID else { return nil }
        return parsedEntities.first { $0.id == id }
    }

    /// All workspaces for the workspace list.
    var allWorkspaces: [ManagedWorkspace] {
        workspaceManager.orderedWorkspaces
    }

    /// The active workspace ID, for highlighting in the workspace list.
    var activeWorkspaceId: UUID? {
        workspaceManager.activeWorkspaceId
    }

    /// The pinned workspace ID, for showing pin indicator in the UI.
    var pinnedWorkspaceId: UUID? {
        workspaceManager.pinnedWorkspaceId
    }

    // MARK: - Knowledge Inspector Accessors

    /// File intelligence for the active workspace.
    var intelligence: FileIntelligence? {
        activeWorkspace?.fileIntelligence
    }

    /// Semantic enrichment (nil until the first question triggers LLM enrichment).
    var enrichment: SemanticEnrichment? {
        intelligence?.semanticEnrichment
    }

    /// File identity: role, layer, patterns.
    var identity: FileIdentity? {
        intelligence?.identity
    }

    /// Deterministic purpose string.
    var deterministicPurpose: String? {
        let p = intelligence?.purpose
        return (p?.isEmpty == false) ? p : nil
    }

    /// Structure outline text.
    var structureOutline: String? {
        let o = intelligence?.structureOutline
        return (o?.isEmpty == false) ? o : nil
    }

    /// All imports from the active workspace's file intelligence.
    var imports: [ImportDeclaration] {
        intelligence?.imports ?? []
    }

    /// All relationships from the active workspace's file intelligence.
    var relationships: [Relationship] {
        intelligence?.relationships ?? []
    }

    /// File language.
    var language: String? {
        intelligence?.language
    }

    /// File line count.
    var lineCount: Int? {
        intelligence?.lineCount
    }

    /// File hash.
    var fileHash: String? {
        intelligence?.fileHash
    }

    /// Intelligence build date.
    var buildDate: Date? {
        intelligence?.buildDate
    }

    /// The most recent question's reasoning context, if any.
    var lastQuestionContext: QuestionContext? {
        activeWorkspace?.lastQuestionContext
    }

    // MARK: - Directory Workspace Accessors

    /// Whether the active workspace is a directory workspace.
    var isDirectoryWorkspace: Bool {
        activeWorkspace?.workspace.kind == .directory
    }

    /// Indexing state for the active workspace (nil for .file workspaces).
    var indexingState: IndexingState? {
        activeWorkspace?.indexingCoordinator?.state
    }

    /// Discovered file paths for the active directory workspace.
    var discoveredFiles: [String] {
        activeWorkspace?.indexingCoordinator?.discoveredFiles ?? []
    }

    // MARK: - Derived Visualizations (computed from existing data, no new parsing)

    /// Entry points: entities that call others but are never called within this file.
    var entryPoints: [ParsedEntity] {
        guard let intel = intelligence else { return [] }
        let callRelationships = intel.relationships.filter { $0.kind == .calls }
        guard !callRelationships.isEmpty else { return [] }

        let callerIds = Set(callRelationships.map(\.sourceEntity))
        let calleeNames = Set(callRelationships.map(\.targetName))

        return intel.entities.filter {
            ($0.entity.entityType == .function || $0.entity.entityType == .method)
            && callerIds.contains($0.entity.stableId)
            && !calleeNames.contains($0.entity.name)
        }
    }

    /// External calls: function/method names called but not defined in this file.
    var externalCalls: [String] {
        guard let intel = intelligence else { return [] }
        let entityNames = Set(intel.entities.map(\.entity.name))
        let callRelationships = intel.relationships.filter { $0.kind == .calls }
        let externalTargets = callRelationships
            .filter { !entityNames.contains($0.targetName) }
            .map(\.targetName)
        return Array(Set(externalTargets)).sorted()
    }

    // MARK: - Init

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    // MARK: - Restore

    /// Restore all workspaces from the database. Call once on view appear.
    func restoreWorkspaces() async {
        await workspaceManager.restoreWorkspaces()
    }

    // MARK: - Actions

    /// Whether the session sheet should be auto-presented (e.g., after hotkey open).
    var shouldPresentSession = false

    /// Open a file picker and create/activate workspaces for the selected files.
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Select code files"
        panel.allowedContentTypes = Self.supportedCodeTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        Task {
            for url in urls {
                await loadFile(url: url)
            }
        }
    }

    /// Open a folder picker and create/activate a directory workspace.
    func openDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select a project folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await loadDirectory(url: url)
        }
    }

    /// Create or activate a directory workspace for the given URL.
    func loadDirectory(url: URL) async {
        isLoading = true
        errorMessage = nil
        selectedEntityID = nil

        do {
            try await workspaceManager.createDirectoryWorkspace(url: url)
            isLoading = false
        } catch {
            errorMessage = "Failed to open folder: \(error.localizedDescription)"
            isLoading = false
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

    /// Create or activate a workspace for the given URL.
    func loadFile(url: URL) async {
        isLoading = true
        errorMessage = nil
        selectedEntityID = nil

        do {
            try await workspaceManager.createFileWorkspace(url: url)
            isLoading = false
        } catch {
            errorMessage = "Failed to open: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Switch the active workspace.
    func switchToWorkspace(id: UUID) {
        selectedEntityID = nil
        workspaceManager.activateWorkspace(id: id)
    }

    /// Close a workspace and remove it from memory.
    func closeWorkspace(id: UUID) {
        if selectedEntityID != nil, workspaceManager.activeWorkspaceId == id {
            selectedEntityID = nil
        }
        workspaceManager.closeWorkspace(id: id)
    }

    /// Pin a workspace for manual override of automatic resolution.
    /// Unpins if the workspace is already pinned (toggle behavior).
    func togglePin(id: UUID) {
        if workspaceManager.pinnedWorkspaceId == id {
            workspaceManager.unpinWorkspace()
        } else {
            workspaceManager.pinWorkspace(id: id)
        }
    }
}
