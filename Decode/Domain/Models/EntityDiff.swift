import Foundation

/// The result of comparing a fresh AST parse against the database's stored entities.
///
/// After re-parsing a file, each entity falls into one of three categories:
/// created (new entity not in DB), modified (exists but body hash changed),
/// or deleted (was in DB but no longer in the parsed output).
struct EntityDiff: Sendable {
    /// Entities discovered in the new parse that have no matching stableId in the database.
    let created: [CodeEntity]

    /// Entities whose stableId matches a DB record but whose body hash has changed.
    let modified: [CodeEntity]

    /// Entity IDs present in the database but absent from the new parse.
    let deleted: [UUID]
}
