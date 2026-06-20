import Foundation

/// Automatically resolves which session a code snippet belongs to.
///
/// Scores each open session against the selected snippet using multiple signals:
/// 1. **Entity containment** — snippet found inside a parsed entity's source text
/// 2. **Full file content** — snippet found in the session's file content
/// 3. **Recency** — recently active sessions get a small bonus
///
/// Returns a ``SessionResolution`` with confidence scoring so the caller can
/// decide whether to use the match or fall back to manual session selection.
///
/// ## Confidence Tiers
/// - **High (≥80)**: Entity-level match — snippet lives inside a known entity.
/// - **Medium (≥60)**: File-level match — snippet found in file content.
/// - **Low (<60)**: No reliable match — fall back to active session.
@MainActor
struct SessionResolver {

    // MARK: - Configuration

    /// Minimum snippet length for reliable matching. Shorter snippets are too
    /// ambiguous (e.g., `return`, `import Foundation`).
    private static let minimumSnippetLength = 15

    // MARK: - Scoring Weights

    /// Snippet is contained verbatim in a parsed entity's source text.
    private static let entityContainmentScore: Int = 100

    /// Snippet matches entity source after whitespace normalization.
    private static let normalizedEntityScore: Int = 80

    /// Snippet found in full file content (requires file read).
    private static let fileContentScore: Int = 60

    /// Bonus for the most recently updated session (tiebreaker).
    private static let recencyBonus: Int = 10

    /// Bonus for the currently active session (tiebreaker).
    private static let activeSessionBonus: Int = 5

    // MARK: - Confidence Thresholds

    /// Minimum confidence to auto-select a session without fallback.
    static let autoSelectThreshold: Int = 60

    // MARK: - Resolution

    /// Resolve the best matching session for a code snippet.
    ///
    /// - Parameters:
    ///   - snippet: The user's selected code text.
    ///   - sessions: All open managed sessions.
    ///   - pinnedSessionId: If set, this session is returned unconditionally.
    ///   - activeSessionId: The currently active session ID, used as fallback
    ///     and minor tiebreaker.
    /// - Returns: A resolution result with the matched session (or fallback)
    ///   and all candidate scores for debugging.
    func resolve(
        snippet: String,
        sessions: [UUID: ManagedSession],
        pinnedSessionId: UUID?,
        activeSessionId: UUID?
    ) -> SessionResolution {
        // 1. Pinned session override — unconditional.
        if let pinnedId = pinnedSessionId, let pinned = sessions[pinnedId] {
            #if DEBUG
            print("[SessionResolver] Using pinned session: \(pinned.session.fileName)")
            #endif
            return SessionResolution(
                session: pinned,
                confidence: 100,
                method: .pinned,
                candidates: []
            )
        }

        // 2. Trivial case — only one session open.
        let accessibleSessions = sessions.values.filter { $0.isFileAccessible }
        if accessibleSessions.count == 1, let only = accessibleSessions.first {
            #if DEBUG
            print("[SessionResolver] Single session: \(only.session.fileName)")
            #endif
            return SessionResolution(
                session: only,
                confidence: 100,
                method: .singleSession,
                candidates: [CandidateScore(session: only, score: 100, matchType: .singleSession)]
            )
        }

        // 3. Snippet too short — fall back to active session.
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < Self.minimumSnippetLength {
            #if DEBUG
            print("[SessionResolver] Snippet too short (\(trimmed.count) chars), falling back to active session")
            #endif
            return fallbackToActive(sessions: sessions, activeSessionId: activeSessionId, reason: .snippetTooShort)
        }

        // 4. Score all sessions.
        let recencyOrder = sessions.values
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
            .enumerated()
            .reduce(into: [UUID: Int]()) { dict, pair in
                dict[pair.element.session.id] = pair.offset
            }

        var candidates: [CandidateScore] = []

        for managed in accessibleSessions {
            let (matchScore, matchType) = scoreSession(
                managed: managed,
                snippet: trimmed
            )

            var totalScore = matchScore

            // Recency bonus: 10 for most recent, 5 for second, etc.
            if let rank = recencyOrder[managed.session.id] {
                let bonus = max(0, Self.recencyBonus - rank * 5)
                totalScore += bonus
            }

            // Active session tiebreaker.
            if managed.session.id == activeSessionId {
                totalScore += Self.activeSessionBonus
            }

            candidates.append(CandidateScore(
                session: managed,
                score: totalScore,
                matchType: matchType
            ))
        }

        candidates.sort { $0.score > $1.score }

        #if DEBUG
        for c in candidates {
            print("[SessionResolver] Candidate: \(c.session.session.fileName) score=\(c.score) match=\(c.matchType)")
        }
        #endif

        // 5. Evaluate results.
        guard let best = candidates.first else {
            return fallbackToActive(sessions: sessions, activeSessionId: activeSessionId, reason: .noSessions)
        }

        // Check if confidence meets threshold.
        if best.score >= Self.autoSelectThreshold {
            // Check for ambiguity: if second candidate is close, reduce confidence.
            let isAmbiguous: Bool
            if candidates.count >= 2 {
                let gap = best.score - candidates[1].score
                isAmbiguous = gap < 10 && candidates[1].score >= Self.autoSelectThreshold
            } else {
                isAmbiguous = false
            }

            if isAmbiguous {
                #if DEBUG
                print("[SessionResolver] Ambiguous match — top two within 10 points, falling back to active session")
                #endif
                return fallbackToActive(
                    sessions: sessions,
                    activeSessionId: activeSessionId,
                    reason: .ambiguous,
                    candidates: candidates
                )
            }

            #if DEBUG
            print("[SessionResolver] Auto-resolved: \(best.session.session.fileName) (confidence=\(best.score), method=\(best.matchType))")
            #endif
            return SessionResolution(
                session: best.session,
                confidence: best.score,
                method: .autoResolved,
                candidates: candidates
            )
        }

        // Below threshold — fall back.
        #if DEBUG
        print("[SessionResolver] Low confidence (\(best.score)), falling back to active session")
        #endif
        return fallbackToActive(
            sessions: sessions,
            activeSessionId: activeSessionId,
            reason: .lowConfidence,
            candidates: candidates
        )
    }

    // MARK: - Session Scoring

    /// Score a single session against the snippet.
    ///
    /// Returns the base score (before recency/active bonuses) and the match type.
    private func scoreSession(
        managed: ManagedSession,
        snippet: String
    ) -> (score: Int, matchType: MatchType) {
        // Tier 1: Exact entity containment (no file I/O).
        let entities = managed.parsedEntities
        let exactMatches = entities.filter { $0.sourceText.contains(snippet) }
        if !exactMatches.isEmpty {
            return (Self.entityContainmentScore, .entityContainment)
        }

        // Tier 2: Normalized whitespace entity match (no file I/O).
        let normalizedSnippet = normalizeWhitespace(snippet)
        let normalizedMatches = entities.filter {
            normalizeWhitespace($0.sourceText).contains(normalizedSnippet)
        }
        if !normalizedMatches.isEmpty {
            return (Self.normalizedEntityScore, .normalizedEntityContainment)
        }

        // Tier 3: Full file content match (requires file read).
        let url = URL(fileURLWithPath: managed.session.filePath)
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            if content.contains(snippet) {
                return (Self.fileContentScore, .fileContent)
            }
        }

        return (0, .noMatch)
    }

    /// Collapse runs of whitespace into single spaces for fuzzy matching.
    private func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Fallback

    private func fallbackToActive(
        sessions: [UUID: ManagedSession],
        activeSessionId: UUID?,
        reason: FallbackReason,
        candidates: [CandidateScore] = []
    ) -> SessionResolution {
        if let activeId = activeSessionId, let active = sessions[activeId] {
            return SessionResolution(
                session: active,
                confidence: 0,
                method: .fallbackToActive(reason),
                candidates: candidates
            )
        }
        return SessionResolution(
            session: nil,
            confidence: 0,
            method: .noMatch,
            candidates: candidates
        )
    }
}

// MARK: - Resolution Result

/// The result of automatic session resolution.
///
/// Used exclusively on `@MainActor` — not `Sendable` because it holds
/// references to `ManagedSession` (a `@MainActor`-isolated class).
struct SessionResolution {
    /// The resolved session, or `nil` if no session could be matched.
    let session: ManagedSession?

    /// Confidence score (0–110). Higher = more certain.
    let confidence: Int

    /// How the session was resolved.
    let method: ResolutionMethod

    /// All candidate sessions with their scores, for debugging.
    let candidates: [CandidateScore]
}

/// How the session was selected.
enum ResolutionMethod: CustomStringConvertible {
    case pinned
    case singleSession
    case autoResolved
    case fallbackToActive(FallbackReason)
    case noMatch

    var description: String {
        switch self {
        case .pinned: "pinned"
        case .singleSession: "single-session"
        case .autoResolved: "auto-resolved"
        case .fallbackToActive(let reason): "fallback-to-active(\(reason))"
        case .noMatch: "no-match"
        }
    }
}

/// Why automatic resolution fell back to the active session.
enum FallbackReason: CustomStringConvertible {
    case snippetTooShort
    case lowConfidence
    case ambiguous
    case noSessions

    var description: String {
        switch self {
        case .snippetTooShort: "snippet-too-short"
        case .lowConfidence: "low-confidence"
        case .ambiguous: "ambiguous"
        case .noSessions: "no-sessions"
        }
    }
}

/// How the snippet matched a session.
enum MatchType: CustomStringConvertible {
    case entityContainment
    case normalizedEntityContainment
    case fileContent
    case singleSession
    case noMatch

    var description: String {
        switch self {
        case .entityContainment: "entity-containment"
        case .normalizedEntityContainment: "normalized-entity"
        case .fileContent: "file-content"
        case .singleSession: "single-session"
        case .noMatch: "no-match"
        }
    }
}

/// A candidate session with its computed score.
struct CandidateScore {
    let session: ManagedSession
    let score: Int
    let matchType: MatchType
}
