import Foundation

/// The aggregate root for a tracked context in Workspace Mode.
///
/// A workspace tracks either a single source file (`.file` kind, identical
/// to today's `Session`) or an entire project directory (`.directory` kind,
/// with full indexing and multi-file intelligence).
///
/// ## Relationship to Session
/// `Workspace` is the successor to `Session`. During the migration period
/// (W0–W2), both types coexist. After W3, `Session` is removed and
/// `Workspace` is the sole aggregate root.
///
/// ## Canonical vs Derived State
/// `Workspace` stores only canonical state — identity, root location,
/// bookmark, timestamps, summary. All derived state (parsed entities,
/// file intelligence, module list, DIR content) lives in `ManagedWorkspace`
/// (W1) and is recomputable from the understanding pipeline.
///
/// Maps to the `workspaces` table in the database.
struct Workspace: Identifiable, Sendable, Codable, Hashable {

    let id: UUID
    let kind: WorkspaceKind
    let createdAt: Date
    var updatedAt: Date

    /// Security-scoped bookmark data for file system access across app restarts.
    var bookmarkData: Data

    /// Canonical root path.
    /// - `.file`: absolute path to the tracked file
    ///   (e.g., `/Users/dev/project/Sources/Foo.swift`)
    /// - `.directory`: absolute path to the tracked directory
    ///   (e.g., `/Users/dev/project`)
    var rootPath: String

    /// Display name derived from the root path.
    /// - `.file`: file name (e.g., `Foo.swift`)
    /// - `.directory`: directory name (e.g., `project`)
    var rootFileName: String

    /// AI-generated high-level description of the workspace's purpose.
    var summaryText: String

    /// Whether the workspace's database records are known to be corrupted.
    var isCorrupted: Bool
}
