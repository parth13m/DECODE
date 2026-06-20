import Foundation

/// The outcome of a refactoring operation on a code entity.
struct RefactoringResult: Sendable {
    /// The entity that was refactored.
    let targetEntityId: UUID

    /// The original source code before refactoring.
    let originalSource: String

    /// The AI-generated replacement source code.
    let refactoredSource: String

    /// Whether the refactored code passed AST validation.
    let isValid: Bool
}

/// A scored candidate for automated refactoring.
///
/// The score formula from the spec:
/// `Score = function_length + (nesting_depth * 3) + (dependency_count * 2)`
struct RefactoringCandidate: Sendable {
    let entityId: UUID
    let entityName: String
    let score: Int
    let functionLength: Int
    let nestingDepth: Int
    let dependencyCount: Int
}
