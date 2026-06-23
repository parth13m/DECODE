import Foundation

/// The structural understanding Decode has built about a single source file.
///
/// File Intelligence is the foundation of Decode's understanding model.
/// It combines deterministic structural facts with progressive understanding
/// layers that mirror how an experienced engineer comprehends a file.
///
/// Understanding layers (all implemented):
/// - **Identity** (deterministic): Role, architectural layer, patterns — "What am I looking at?"
/// - **Purpose** (deterministic + semantic): Why this file exists — "Why is this file here?"
/// - **Behavior** (semantic): Control flow, state transitions, side effects
/// - **Safety** (semantic): Error handling, concurrency model, resource lifecycle
/// - **Design** (semantic): Architectural responsibility, patterns, trade-offs
///
/// Semantic layers are LLM-derived, lazy, and cached via ``SemanticEnrichment``.
///
/// Structural facts (deterministic):
/// - Entities, outline, imports, relationships, line count, language
///
/// File Intelligence is keyed to a specific version of a file via
/// `fileHash`. When the file changes, the intelligence is stale and
/// must be recomputed.
struct FileIntelligence: Sendable {

    /// The session this intelligence was built from.
    let sessionId: UUID

    /// The file name (e.g., "SessionManager.swift").
    let fileName: String

    /// Detected programming language (e.g., "swift", "python", "javascript").
    let language: String

    /// Total line count of the source file.
    let lineCount: Int

    /// All entities extracted from the file, enriched with structural metadata.
    let entities: [ParsedEntity]

    /// The hierarchical outline of the file's structure.
    /// Built from entities with indentation reflecting parent-child relationships.
    let structureOutline: String

    /// Import declarations extracted from the file.
    let imports: [ImportDeclaration]

    /// Structural relationships between entities in this file.
    /// Currently includes `.calls` relationships; future types will
    /// include conformances, inheritance, ownership, and references.
    let relationships: [Relationship]

    // MARK: - Understanding Layers

    /// Identity understanding: what this file is, its role and architectural layer.
    /// Answers "What am I looking at?" — the first thing an engineer recognizes.
    let identity: FileIdentity

    /// Deterministic purpose: why this file exists, derived from naming
    /// conventions and entity structure. Always available.
    /// A single sentence answering "Why is this file here?" — the anchor
    /// for all explanations within the file.
    /// Empty string when purpose cannot be meaningfully derived.
    let purpose: String

    /// LLM-derived semantic understanding. Computed lazily on first user
    /// question, cached by `fileHash`. `nil` until enrichment is triggered
    /// or if the LLM call fails (in which case `purpose` is the fallback).
    var semanticEnrichment: SemanticEnrichment?

    /// SHA-256 hash of the file content this intelligence was built from.
    /// Used as an invalidation key: if the file's hash changes, this
    /// intelligence is stale.
    let fileHash: String

    /// When this intelligence was computed.
    let buildDate: Date
}
