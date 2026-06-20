import Foundation

/// Snippet-anchored context assembled from an active Session.
///
/// Built by ``ContextBuilderService`` from the session's parsed entities and
/// the user's selected snippet. Instead of sending the entire file to the LLM,
/// this provides focused context: where the snippet lives in the file's
/// structure, the containing entity's source, and a structural outline.
///
/// Parent type and sibling information is conveyed through the file structure
/// outline, which shows the full entity hierarchy with a `← selected` marker.
///
/// Falls back to full file content only when the snippet cannot be matched to
/// an entity and the file is small enough.
struct SessionContext: Sendable {

    /// The session this context was built from.
    let sessionId: UUID

    /// The file name (e.g., "SessionManager.swift").
    let fileName: String

    /// Total number of entities in the session.
    let entityCount: Int

    /// Hierarchical outline of the file's entities with a marker on the
    /// entity that contains the snippet.
    /// ```
    /// class SessionManager
    ///   func createSession(url: URL) async throws [lines 80-130]
    ///   func reparseSession(id: UUID) async [lines 195-230] ← selected
    /// ```
    let fileStructureOutline: String

    /// Human-readable description of where the snippet is located.
    /// e.g., "Inside `reparseSession(id:)`, a method of `SessionManager` (lines 195-230)."
    /// Empty string if the snippet could not be located.
    let snippetLocationDescription: String

    /// Full source text of the entity that contains the snippet.
    /// `nil` when the snippet could not be matched to an entity.
    let containingEntitySource: String?

    /// Whether the system prompt contains source code (entity, full file,
    /// or surrounding code). When `true`, the user message can omit the
    /// snippet text because it is already embedded in the context.
    let hasSourceInContext: Bool

    /// Full file content, included only as a fallback when:
    /// - The snippet could not be matched to any entity, AND
    /// - The file is small enough (≤200 lines).
    /// `nil` in the normal (entity-matched) case.
    let fallbackFileContent: String?

    /// Lines surrounding the snippet in the source file (Tier 2.5).
    /// Populated when the snippet is not matched to an entity but can be
    /// located by text search in a large file. `nil` in Tier 1, 2, and 3.
    let surroundingCode: String?

    /// Line range where the snippet was found in the file (Tier 2.5).
    /// `nil` when the snippet could not be located by text search.
    let snippetLineRange: ClosedRange<Int>?

    /// The nearest parsed entity ending before the snippet (Tier 2.5).
    /// Provides structural anchoring when no entity contains the snippet.
    let nearestEntityAbove: NearestEntity?

    /// The nearest parsed entity starting after the snippet (Tier 2.5).
    /// Provides structural anchoring when no entity contains the snippet.
    let nearestEntityBelow: NearestEntity?

    /// Language-specific prompt guidance resolved from the file extension.
    /// `nil` for Swift files (default prompt is already Swift-optimized)
    /// and for unrecognized extensions.
    let languageGuidance: String?

    /// The context tier used, derived from which fields are populated.
    ///
    /// - `"tier1"` — Entity match (containingEntitySource is non-nil)
    /// - `"tier2"` — Full file fallback (fallbackFileContent is non-nil)
    /// - `"tier2.5"` — Surrounding code (surroundingCode is non-nil)
    /// - `"tier3"` — Outline only (all three are nil)
    var contextTier: String {
        if containingEntitySource != nil { return "tier1" }
        if fallbackFileContent != nil { return "tier2" }
        if surroundingCode != nil { return "tier2.5" }
        return "tier3"
    }
}

// MARK: - Nearest Entity

/// Structured data for an entity near the user's selected snippet.
///
/// Used by Tier 2.5 context to anchor the snippet's position relative
/// to known entities without pre-rendering presentation strings.
struct NearestEntity: Sendable {
    /// The entity's declaration signature (e.g., "func loadConfig()").
    let signature: String
    /// The entity's start line in the source file.
    let startLine: Int
    /// The entity's end line in the source file.
    let endLine: Int
}
