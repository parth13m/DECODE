import Foundation

/// Tracks the user's navigation position within a `.directory` workspace.
///
/// For `.directory` workspaces, the user can browse multiple files. This
/// state object tracks which file and entity are currently selected in
/// the Knowledge Inspector.
///
/// For `.file` workspaces, the file path is implicitly the workspace's
/// `rootPath` and this state is unused.
@Observable
@MainActor
final class NavigationState {

    /// The path of the currently selected file within the workspace.
    /// `nil` when no file is selected (e.g., workspace just opened).
    var activeFilePath: String?

    /// The ID of the currently selected entity within the active file.
    /// `nil` when no entity is selected.
    var activeEntityId: UUID?

    /// The relative path of the currently selected folder in the project explorer.
    /// `nil` when no folder is selected (a file is selected instead).
    var selectedFolderPath: String?

    /// Which folders are expanded in the project explorer tree.
    var expandedFolders: Set<String> = []

    /// Select a file within the workspace.
    func selectFile(path: String?) {
        activeFilePath = path
        selectedFolderPath = nil
        // Clear entity selection when switching files.
        activeEntityId = nil
    }

    /// Select a folder in the project explorer.
    func selectFolder(relativePath: String?) {
        selectedFolderPath = relativePath
        activeFilePath = nil
        activeEntityId = nil
    }

    /// Toggle folder expansion without changing selection.
    func toggleFolderExpansion(relativePath: String) {
        if expandedFolders.contains(relativePath) {
            expandedFolders.remove(relativePath)
        } else {
            expandedFolders.insert(relativePath)
        }
    }

    /// Select an entity within the current file.
    func selectEntity(id: UUID?) {
        activeEntityId = id
    }
}
