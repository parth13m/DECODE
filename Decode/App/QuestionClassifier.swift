// QuestionClassifier.swift — Decode App
// E3-01: Question-Aware Scope Selection
//
// Classifies a query's purpose and optional question text into a
// (RetrievalIntent, RetrievalScope) pair. This replaces the hardcoded
// scope rule in PipelineQueryService with question-aware selection.
//
// The classifier uses the existing RetrievalIntent enum values (.explain,
// .impact, .dependencies, .overview) which already have operational
// budget weights and traversal configurations in RetrievalRuntime.
// This module simply selects the right intent based on available signals.

import Foundation
import RetrievalRuntime

// MARK: - Question Classification

/// The result of classifying a question into retrieval parameters.
struct QuestionClassification: Sendable, Equatable {
    /// The retrieval intent — determines budget allocation and traversal plan.
    let intent: RetrievalIntent

    /// The retrieval scope — determines how much scope evidence is gathered.
    let scope: RetrievalScope

    /// Which classification rule matched.
    let matchedRule: ClassificationRule
}

/// Identifies which classification rule produced the result.
enum ClassificationRule: String, Sendable, Equatable {
    /// Purpose-based default (no question text analyzed).
    case purposeDefault
    /// Matched impact keywords in question text.
    case impactKeywords
    /// Matched dependency keywords in question text.
    case dependencyKeywords
    /// Matched overview/architecture keywords in question text.
    case overviewKeywords
    /// Matched narrow/simple keywords in question text.
    case narrowKeywords
    /// Fallback when no keywords matched.
    case fallback
}

// MARK: - Question Classifier

/// Classifies query context into retrieval parameters.
///
/// Uses a two-phase approach:
/// 1. **Purpose-based defaults**: Maps the consumer purpose string to
///    a sensible (intent, scope) baseline.
/// 2. **Keyword refinement**: If question text is available, refines
///    the intent based on keyword patterns.
///
/// The classifier is stateless and deterministic — same inputs always
/// produce the same classification.
///
/// The current implementation uses keyword matching, which is intentionally
/// simple for alpha. It may later be replaced by semantic classification
/// (e.g., embedding-based or LLM-based) while preserving the same public
/// interface: `classify(purpose:questionHint:) -> QuestionClassification`.
enum QuestionClassifier {

    /// Classifies a query into retrieval parameters.
    ///
    /// - Parameters:
    ///   - purpose: The consumer purpose string ("explain", "improve", "followup").
    ///   - questionHint: Optional question text for keyword-based refinement.
    /// - Returns: The classified (intent, scope) pair with the matched rule.
    static func classify(
        purpose: String,
        questionHint: String? = nil
    ) -> QuestionClassification {
        // Phase 1: Purpose-based defaults.
        let baseline = purposeDefaults(for: purpose)

        // Phase 2: Keyword refinement (only if question text is available).
        guard let question = questionHint, !question.isEmpty else {
            return QuestionClassification(
                intent: baseline.intent,
                scope: baseline.scope,
                matchedRule: .purposeDefault
            )
        }

        return refineWithKeywords(
            question: question,
            baseline: baseline,
            purpose: purpose
        )
    }

    // MARK: - Purpose Defaults

    /// Returns baseline (intent, scope) for a given purpose string.
    ///
    /// M10: explain and followup default to .system scope to include
    /// project-level intelligence (system composition and emergent properties).
    /// - "improve" → (.explain, .local) — file-local evidence for code improvement
    /// - "explain" → (.explain, .system) — system-scope for explanations
    /// - "followup" → (.explain, .system) — default for follow-ups, refined by keywords
    private static func purposeDefaults(
        for purpose: String
    ) -> (intent: RetrievalIntent, scope: RetrievalScope) {
        switch purpose {
        case "improve":
            return (.explain, .local)
        case "explain":
            return (.explain, .system)
        case "followup":
            return (.explain, .system)
        default:
            return (.explain, .system)
        }
    }

    // MARK: - Keyword Refinement

    /// Refines the baseline classification using keyword patterns in the question text.
    ///
    /// Rules are evaluated in priority order. The first match wins.
    /// Priority: impact > dependencies > overview > narrow > fallback.
    private static func refineWithKeywords(
        question: String,
        baseline: (intent: RetrievalIntent, scope: RetrievalScope),
        purpose: String
    ) -> QuestionClassification {
        let q = question.lowercased()

        // Rule 1: Impact keywords — "what calls this", "who uses this", "what breaks"
        // → .impact intent with relational-heavy budget (20/60/20) and inverse traversal
        if matchesImpactPattern(q) {
            return QuestionClassification(
                intent: .impact,
                scope: max(baseline.scope, .module),
                matchedRule: .impactKeywords
            )
        }

        // Rule 2: Dependency keywords — "what does this depend on", "what does this call"
        // → .dependencies intent with forward traversal depth 2
        if matchesDependencyPattern(q) {
            return QuestionClassification(
                intent: .dependencies,
                scope: max(baseline.scope, .module),
                matchedRule: .dependencyKeywords
            )
        }

        // Rule 3: Overview keywords — "how does this fit", "architecture", "overview"
        // → .overview intent with system-scope traversal (M10)
        if matchesOverviewPattern(q) {
            return QuestionClassification(
                intent: .overview,
                scope: max(baseline.scope, .system),
                matchedRule: .overviewKeywords
            )
        }

        // Rule 4: Narrow keywords — "what does this line do", simple/local questions
        // → .explain intent with narrow/local scope
        if matchesNarrowPattern(q) {
            return QuestionClassification(
                intent: .explain,
                scope: .local,
                matchedRule: .narrowKeywords
            )
        }

        // Fallback: use purpose defaults.
        return QuestionClassification(
            intent: baseline.intent,
            scope: baseline.scope,
            matchedRule: .fallback
        )
    }

    // MARK: - Pattern Matching

    /// Impact patterns: questions about what depends on or is affected by an entity.
    static let impactKeywords: [String] = [
        "who calls", "what calls", "who uses", "what uses",
        "callers", "called by", "used by",
        "what depends on", "what relies on",
        "what breaks", "what would break", "what is affected",
        "impact", "affects", "downstream",
        "reverse dependencies", "dependents",
        "who conforms", "who implements", "who inherits",
        "references to", "referenced by",
    ]

    /// Dependency patterns: questions about what an entity depends on.
    static let dependencyKeywords: [String] = [
        "what does this depend on", "what does it depend on",
        "dependencies of", "depends on",
        "what does this call", "what does it call",
        "what does this use", "what does it use",
        "what does this import", "imports",
        "what does this inherit", "inherits from",
        "what does this conform to", "conforms to",
        "upstream", "required by",
    ]

    /// Overview patterns: questions about architectural context.
    static let overviewKeywords: [String] = [
        "overview", "architecture", "how does this fit",
        "role of", "purpose of", "responsibility",
        "high level", "high-level", "big picture",
        "how is this organized", "structure",
        "design pattern", "where does this fit",
        "how does this relate", "relationship to",
        "broader context", "system context",
    ]

    /// Narrow patterns: questions about specific lines or simple behavior.
    static let narrowKeywords: [String] = [
        "what does this line", "what does this do",
        "what happens here", "what is this",
        "this specific", "this particular",
        "just this", "only this",
        "simple", "basic",
        "syntax", "what type",
    ]

    private static func matchesImpactPattern(_ q: String) -> Bool {
        impactKeywords.contains { q.contains($0) }
    }

    private static func matchesDependencyPattern(_ q: String) -> Bool {
        dependencyKeywords.contains { q.contains($0) }
    }

    private static func matchesOverviewPattern(_ q: String) -> Bool {
        overviewKeywords.contains { q.contains($0) }
    }

    private static func matchesNarrowPattern(_ q: String) -> Bool {
        narrowKeywords.contains { q.contains($0) }
    }
}
