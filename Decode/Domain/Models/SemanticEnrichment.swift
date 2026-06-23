import Foundation

/// LLM-derived understanding of a source file, layered on top of
/// deterministic analysis.
///
/// Semantic enrichment interprets the objective facts produced by the
/// Deterministic Facts Engine. It does not replace deterministic analysis —
/// it augments it with reasoning that requires contextual understanding.
///
/// ## Understanding Layers
///
/// Each layer is an independent, optional enrichment computed via the
/// same pipeline: structured facts in, interpreted understanding out.
///
/// | Layer | Field | Status |
/// |-------|-------|--------|
/// | Purpose | `purpose` | Implemented — always present when enrichment succeeds |
/// | Behavior | `behavior` | Implemented — control flow, state transitions, side effects |
/// | Safety | `safety` | Implemented — error handling, concurrency model, resource lifecycle |
/// | Design | `design` | Implemented — architectural responsibility, patterns, trade-offs |
///
/// All four File Intelligence layers are now implemented. New layers are
/// added as optional fields. Existing fields and construction sites remain
/// unchanged — backward compatibility is preserved via default parameter values.
///
/// ## Lifecycle
///
/// Semantic enrichment is:
/// - **Lazy**: computed only when a user requests an explanation.
/// - **Cached**: keyed by `fileHash` — reused until the file changes.
/// - **Fallible**: if the LLM call fails, deterministic analysis is the fallback.
struct SemanticEnrichment: Sendable {

    /// LLM-derived purpose: a rich explanation of why this file exists,
    /// what responsibility it owns, and how it fits into the larger system.
    ///
    /// Augments the deterministic `FileIntelligence.purpose` (which is
    /// always available as a fallback). Semantic purpose is richer because
    /// the LLM can reason about entity relationships, imports, and naming
    /// patterns together rather than applying mechanical heuristics.
    let purpose: String

    /// LLM-derived behavioral understanding: how the file operates at
    /// runtime — its control flow patterns, state transitions, side effects,
    /// and interaction with external systems.
    ///
    /// `nil` when behavioral enrichment has not been computed or the LLM
    /// call did not produce behavioral output. The coordinator treats `nil`
    /// as "no behavioral context available" and omits it from the prompt.
    let behavior: String?

    /// LLM-derived safety understanding: how the file handles failure,
    /// manages concurrency, owns resources, and what assumptions or
    /// invariants it depends on for correct operation.
    ///
    /// `nil` when safety enrichment has not been computed or the LLM
    /// call did not produce safety output. The coordinator treats `nil`
    /// as "no safety context available" and omits it from the prompt.
    let safety: String?

    /// LLM-derived design understanding: the file's architectural
    /// responsibility, why its abstractions exist, notable design patterns,
    /// and engineering trade-offs a developer should understand.
    ///
    /// `nil` when design enrichment has not been computed or the LLM
    /// call did not produce design output. The coordinator treats `nil`
    /// as "no design context available" and omits it from the prompt.
    let design: String?

    /// The `fileHash` this enrichment was computed from.
    /// Used for cache validation — if the file's hash changes, this
    /// enrichment is stale.
    let fileHash: String

    /// When this enrichment was computed.
    let computedAt: Date

    init(
        purpose: String,
        behavior: String? = nil,
        safety: String? = nil,
        design: String? = nil,
        fileHash: String,
        computedAt: Date
    ) {
        self.purpose = purpose
        self.behavior = behavior
        self.safety = safety
        self.design = design
        self.fileHash = fileHash
        self.computedAt = computedAt
    }
}
