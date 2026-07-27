import Foundation

/// Distinguishes how a workspace tracks its root target.
///
/// - `.file`: tracks a single source file (degenerate case, identical to
///   today's Session). `Workspace.rootPath` is the file path.
/// - `.directory`: tracks an entire project directory with full indexing.
///   `Workspace.rootPath` is the directory path.
///
/// Raw values are persisted as TEXT in SQLite. They must never change
/// after shipping.
enum WorkspaceKind: String, Sendable, Codable, Hashable {
    case file
    case directory
}
