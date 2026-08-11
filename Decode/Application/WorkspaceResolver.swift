import Foundation

/// Automatically resolves which workspace a code snippet belongs to.
///
/// Mirrors ``SessionResolver`` for ``ManagedWorkspace`` instances.
/// Scores each open workspace against the selected snippet using:
/// 1. **Entity containment** — snippet found inside a parsed entity's source text
/// 2. **Full file content** — snippet found in the workspace's file content
/// 3. **Recency** — recently active workspaces get a small bonus
///
/// ## Dual-Stack (W2)
/// During the W2 transition, ``SessionQuestionCoordinator`` tries workspace
/// resolution first. If no workspace resolves, it falls back to session
/// resolution via ``SessionResolver``. After W3, ``SessionResolver`` is
/// removed and this becomes the sole resolver.
@MainActor
struct WorkspaceResolver {

    // MARK: - Configuration

    /// Minimum snippet length for reliable matching.
    private static let minimumSnippetLength = 15

    // MARK: - Scoring Weights (identical to SessionResolver)

    private static let entityContainmentScore: Int = 100
    private static let normalizedEntityScore: Int = 80
    private static let fileContentScore: Int = 60
    private static let recencyBonus: Int = 10
    private static let activeWorkspaceBonus: Int = 5

    // MARK: - Confidence Thresholds

    static let autoSelectThreshold: Int = 60

    // MARK: - Resolution

    /// Resolve the best matching workspace for a code snippet.
    ///
    /// - Parameters:
    ///   - snippet: The user's selected code text.
    ///   - workspaces: All open managed workspaces.
    ///   - pinnedWorkspaceId: If set, this workspace is returned unconditionally.
    ///   - activeWorkspaceId: The currently active workspace ID, used as fallback.
    /// - Returns: A resolution result with the matched workspace and scores.
    func resolve(
        snippet: String,
        workspaces: [UUID: ManagedWorkspace],
        pinnedWorkspaceId: UUID?,
        activeWorkspaceId: UUID?
    ) -> WorkspaceResolution {
        // 1. Pinned workspace override — unconditional.
        if let pinnedId = pinnedWorkspaceId, let pinned = workspaces[pinnedId] {
            return WorkspaceResolution(
                workspace: pinned,
                confidence: 100,
                method: .pinned,
                candidates: []
            )
        }

        // 2. Trivial case — only one workspace open.
        let accessible = workspaces.values.filter { $0.isFileAccessible }
        if accessible.count == 1, let only = accessible.first {
            // For .directory workspaces, still identify which file within
            // the directory the snippet belongs to — the coordinator needs
            // a file path, not a directory path.
            var resolvedFile: String?
            if only.workspace.kind == .directory {
                let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= Self.minimumSnippetLength {
                    let (_, _, matchedPath) = scoreWorkspace(managed: only, snippet: trimmed)
                    resolvedFile = matchedPath
                }
            }
            return WorkspaceResolution(
                workspace: only,
                confidence: 100,
                method: .singleWorkspace,
                candidates: [WorkspaceCandidateScore(workspace: only, score: 100, matchType: .singleWorkspace)],
                resolvedFilePath: resolvedFile
            )
        }

        // 3. Snippet too short — fall back to active workspace.
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < Self.minimumSnippetLength {
            return fallbackToActive(
                workspaces: workspaces,
                activeWorkspaceId: activeWorkspaceId,
                reason: .snippetTooShort
            )
        }

        // 4. Score all workspaces.
        let recencyOrder = workspaces.values
            .sorted { $0.workspace.updatedAt > $1.workspace.updatedAt }
            .enumerated()
            .reduce(into: [UUID: Int]()) { dict, pair in
                dict[pair.element.workspace.id] = pair.offset
            }

        var candidates: [WorkspaceCandidateScore] = []

        for managed in accessible {
            let (matchScore, matchType, matchedFilePath) = scoreWorkspace(
                managed: managed,
                snippet: trimmed
            )

            var totalScore = matchScore

            if let rank = recencyOrder[managed.workspace.id] {
                let bonus = max(0, Self.recencyBonus - rank * 5)
                totalScore += bonus
            }

            if managed.workspace.id == activeWorkspaceId {
                totalScore += Self.activeWorkspaceBonus
            }

            candidates.append(WorkspaceCandidateScore(
                workspace: managed,
                score: totalScore,
                matchType: matchType,
                matchedFilePath: matchedFilePath
            ))
        }

        candidates.sort { $0.score > $1.score }

        // 5. Evaluate results.
        guard let best = candidates.first else {
            return fallbackToActive(
                workspaces: workspaces,
                activeWorkspaceId: activeWorkspaceId,
                reason: .noWorkspaces
            )
        }

        if best.score >= Self.autoSelectThreshold {
            let isAmbiguous: Bool
            if candidates.count >= 2 {
                let gap = best.score - candidates[1].score
                isAmbiguous = gap < 10 && candidates[1].score >= Self.autoSelectThreshold
            } else {
                isAmbiguous = false
            }

            if isAmbiguous {
                return fallbackToActive(
                    workspaces: workspaces,
                    activeWorkspaceId: activeWorkspaceId,
                    reason: .ambiguous,
                    candidates: candidates
                )
            }

            return WorkspaceResolution(
                workspace: best.workspace,
                confidence: best.score,
                method: .autoResolved,
                candidates: candidates,
                resolvedFilePath: best.matchedFilePath
            )
        }

        return fallbackToActive(
            workspaces: workspaces,
            activeWorkspaceId: activeWorkspaceId,
            reason: .lowConfidence,
            candidates: candidates
        )
    }

    // MARK: - Workspace Scoring

    private func scoreWorkspace(
        managed: ManagedWorkspace,
        snippet: String
    ) -> (score: Int, matchType: WorkspaceMatchType, matchedFilePath: String?) {
        // For .directory workspaces, search across all files' entities.
        if managed.workspace.kind == .directory && !managed.parsedEntitiesByFile.isEmpty {
            return scoreDirectoryWorkspace(managed: managed, snippet: snippet)
        }

        // For .file workspaces, search the single file's entities.
        // Tier 1: Exact entity containment.
        let entities = managed.parsedEntities
        if entities.contains(where: { $0.sourceText.contains(snippet) }) {
            return (Self.entityContainmentScore, .entityContainment, nil)
        }

        // Tier 2: Normalized whitespace entity match.
        let normalizedSnippet = normalizeWhitespace(snippet)
        if entities.contains(where: { normalizeWhitespace($0.sourceText).contains(normalizedSnippet) }) {
            return (Self.normalizedEntityScore, .normalizedEntityContainment, nil)
        }

        // Tier 3: Full file content match (only for .file workspaces).
        if managed.workspace.kind == .file {
            let url = URL(fileURLWithPath: managed.workspace.rootPath)
            if let content = try? String(contentsOf: url, encoding: .utf8),
               content.contains(snippet) {
                return (Self.fileContentScore, .fileContent, nil)
            }
        }

        return (0, .noMatch, nil)
    }

    /// Score a `.directory` workspace by searching entities across all indexed files.
    private func scoreDirectoryWorkspace(
        managed: ManagedWorkspace,
        snippet: String
    ) -> (score: Int, matchType: WorkspaceMatchType, matchedFilePath: String?) {
        let normalizedSnippet = normalizeWhitespace(snippet)

        // Search for exact entity containment across all files.
        for (filePath, entities) in managed.parsedEntitiesByFile {
            if entities.contains(where: { $0.sourceText.contains(snippet) }) {
                return (Self.entityContainmentScore, .entityContainment, filePath)
            }
        }

        // Search for normalized whitespace entity match across all files.
        for (filePath, entities) in managed.parsedEntitiesByFile {
            if entities.contains(where: { normalizeWhitespace($0.sourceText).contains(normalizedSnippet) }) {
                return (Self.normalizedEntityScore, .normalizedEntityContainment, filePath)
            }
        }

        // Tier 3: File content match — search each file's content.
        for (filePath, _) in managed.parsedEntitiesByFile {
            let url = URL(fileURLWithPath: filePath)
            if let content = try? String(contentsOf: url, encoding: .utf8),
               content.contains(snippet) {
                return (Self.fileContentScore, .fileContent, filePath)
            }
        }

        return (0, .noMatch, nil)
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Fallback

    private func fallbackToActive(
        workspaces: [UUID: ManagedWorkspace],
        activeWorkspaceId: UUID?,
        reason: WorkspaceFallbackReason,
        candidates: [WorkspaceCandidateScore] = []
    ) -> WorkspaceResolution {
        if let activeId = activeWorkspaceId, let active = workspaces[activeId] {
            return WorkspaceResolution(
                workspace: active,
                confidence: 0,
                method: .fallbackToActive(reason),
                candidates: candidates
            )
        }
        return WorkspaceResolution(
            workspace: nil,
            confidence: 0,
            method: .noMatch,
            candidates: candidates
        )
    }
}

// MARK: - Resolution Types

struct WorkspaceResolution {
    let workspace: ManagedWorkspace?
    let confidence: Int
    let method: WorkspaceResolutionMethod
    let candidates: [WorkspaceCandidateScore]

    /// For `.directory` workspaces, the path of the file within the workspace
    /// that matched the snippet. `nil` for `.file` workspaces or when no
    /// specific file matched.
    let resolvedFilePath: String?

    init(
        workspace: ManagedWorkspace?,
        confidence: Int,
        method: WorkspaceResolutionMethod,
        candidates: [WorkspaceCandidateScore],
        resolvedFilePath: String? = nil
    ) {
        self.workspace = workspace
        self.confidence = confidence
        self.method = method
        self.candidates = candidates
        self.resolvedFilePath = resolvedFilePath
    }
}

enum WorkspaceResolutionMethod: CustomStringConvertible {
    case pinned
    case singleWorkspace
    case autoResolved
    case fallbackToActive(WorkspaceFallbackReason)
    case noMatch

    var description: String {
        switch self {
        case .pinned: "pinned"
        case .singleWorkspace: "single-workspace"
        case .autoResolved: "auto-resolved"
        case .fallbackToActive(let reason): "fallback-to-active(\(reason))"
        case .noMatch: "no-match"
        }
    }
}

enum WorkspaceFallbackReason: CustomStringConvertible {
    case snippetTooShort
    case lowConfidence
    case ambiguous
    case noWorkspaces

    var description: String {
        switch self {
        case .snippetTooShort: "snippet-too-short"
        case .lowConfidence: "low-confidence"
        case .ambiguous: "ambiguous"
        case .noWorkspaces: "no-workspaces"
        }
    }
}

enum WorkspaceMatchType: CustomStringConvertible {
    case entityContainment
    case normalizedEntityContainment
    case fileContent
    case singleWorkspace
    case noMatch

    var description: String {
        switch self {
        case .entityContainment: "entity-containment"
        case .normalizedEntityContainment: "normalized-entity"
        case .fileContent: "file-content"
        case .singleWorkspace: "single-workspace"
        case .noMatch: "no-match"
        }
    }
}

struct WorkspaceCandidateScore {
    let workspace: ManagedWorkspace
    let score: Int
    let matchType: WorkspaceMatchType
    /// For `.directory` workspaces, the file within the workspace that matched.
    let matchedFilePath: String?

    init(
        workspace: ManagedWorkspace,
        score: Int,
        matchType: WorkspaceMatchType,
        matchedFilePath: String? = nil
    ) {
        self.workspace = workspace
        self.score = score
        self.matchType = matchType
        self.matchedFilePath = matchedFilePath
    }
}

// MARK: - Workspace Resolver Input

/// All data the coordinator needs to resolve a workspace.
///
/// Provided by a closure from ``AppDependencies`` so the coordinator
/// doesn't take a direct dependency on ``WorkspaceManager``.
struct WorkspaceResolverInput {
    let workspaces: [UUID: ManagedWorkspace]
    let activeWorkspaceId: UUID?
    let pinnedWorkspaceId: UUID?
}
