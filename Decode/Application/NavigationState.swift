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

    /// Select a file within the workspace.
    func selectFile(path: String?) {
        activeFilePath = path
        // Clear entity selection when switching files.
        activeEntityId = nil
    }

    /// Select an entity within the current file.
    func selectEntity(id: UUID?) {
        activeEntityId = id
    }
}
