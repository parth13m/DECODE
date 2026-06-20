import Foundation

/// A directed edge in the structural dependency graph.
///
/// Represents a call or composition relationship between two entities:
/// the `parentId` entity calls or depends on the `childId` entity.
/// These edges are discovered during AST analysis and stored in a junction table.
///
/// Example: `login() -> validatePassword() -> getUser()` produces two edges:
///   - (parent: login, child: validatePassword)
///   - (parent: validatePassword, child: getUser)
///
/// Maps to the `entity_dependencies` table in the database.
struct EntityDependency: Sendable, Codable, Hashable {

    /// The entity that makes the call (caller / dependent).
    let parentId: UUID

    /// The entity that is called (callee / dependency).
    let childId: UUID
}
