// VirtualSessionManager.swift — Decode Application
//
// Manages the lifecycle, storage, and retrieval for Virtual Sessions.
//
// Virtual Sessions provide optional cross-mode investigation memory.
// When enabled, Decode maintains concise insight records across Selection,
// Screenshot, Session, and Follow-up interactions.
//
// ## Architecture
// - Application layer service (not a pipeline module)
// - Owned by AppDependencies, injected into coordinators
// - JSON persistence following the SessionStatePersistence pattern
// - Toggle-gated via @AppStorage (UserDefaults)
//
// ## Milestone 1 Scope
// - Session lifecycle (start, end, expire)
// - Investigation management (create, boundary detection, anchor evolution)
// - Insight recording with bounded storage
// - Persistence and restoration
// - Public API surface for Milestone 2 (retrieval, prompt injection)
//
// ## What Is NOT In Milestone 1
// - LLM-generated insight summaries (deterministic fallback only)
// - Prompt injection
// - Coordinator integration beyond dependency wiring
// - Retrieval scoring

import Foundation

/// Manages Virtual Session lifecycle, investigation tracking, and insight storage.
///
/// Created by ``AppDependencies`` during deferred startup. Coordinators receive
/// a reference but do not call recording or retrieval APIs until Milestone 2.
///
/// ## Thread Safety
/// All public methods are `@MainActor`-isolated, matching the coordinator pattern.
/// Persistence uses synchronous atomic writes (same as ``SessionStatePersistence``).
@Observable
@MainActor
final class VirtualSessionManager {

    // MARK: - State

    /// The active virtual session, or nil if disabled/expired.
    private(set) var activeSession: VirtualSession?

    /// Insights that were retrieved and injected into the most recent explanation prompt.
    /// Empty when no retrieval occurred or the session is inactive.
    /// Updated by ``formatInsightBlock(for:)`` each time insights are injected.
    private(set) var lastRetrievedInsights: [Insight] = []

    /// Whether virtual sessions are currently enabled.
    /// Reads from UserDefaults — the source of truth is the toggle.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// In-flight compression task. Only one runs at a time; new triggers
    /// cancel the previous one.
    private var compressionTask: Task<Void, Never>?

    // MARK: - Constants

    /// UserDefaults key for the virtual session toggle.
    static let enabledKey = "virtualSessionEnabled"

    // MARK: - Dependencies

    /// Closure that returns the current AI provider, or nil if not configured.
    /// Used for async working memory compression. Set during deferred startup
    /// (after `self` is fully initialized in ``AppDependencies``).
    var aiProvider: (@MainActor () -> (any AIProviderProtocol)?)?

    // MARK: - Persistence

    /// The file URL used for persistence.
    /// Overridable for testing.
    private let persistenceURL: URL

    // MARK: - Init

    /// Creates a new manager with the specified persistence URL.
    ///
    /// - Parameter persistenceURL: Where to persist the active session.
    ///   Defaults to `~/Library/Application Support/Decode/virtual-session.json`.
    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? Self.defaultFileURL
    }

    // MARK: - Session Lifecycle

    /// Starts a new virtual session.
    ///
    /// If a session is already active, this is a no-op. Call ``endSession()``
    /// first to replace an existing session.
    func startSession() {
        guard activeSession == nil else { return }
        activeSession = VirtualSession(
            id: UUID(),
            startedAt: Date(),
            investigations: []
        )
        save()

        #if DEBUG
        print("[VirtualSession] Session started: \(activeSession!.id)")
        #endif
    }

    /// Ends the active virtual session.
    ///
    /// Clears the active session and deletes the persisted file.
    func endSession() {
        guard activeSession != nil else { return }

        #if DEBUG
        print("[VirtualSession] Session ended: \(activeSession!.id)")
        #endif

        compressionTask?.cancel()
        compressionTask = nil
        activeSession = nil
        lastRetrievedInsights = []
        deletePersisted()
    }

    /// Checks whether the active session has expired, and ends it if so.
    ///
    /// Called during restoration and before recording new insights.
    /// Returns `true` if the session was expired and cleared.
    @discardableResult
    func expireIfNeeded() -> Bool {
        guard let session = activeSession, session.isExpired() else {
            return false
        }

        #if DEBUG
        print("[VirtualSession] Session expired: \(session.id) (last activity: \(session.lastActivityTimestamp))")
        #endif

        compressionTask?.cancel()
        compressionTask = nil
        activeSession = nil
        deletePersisted()
        return true
    }

    // MARK: - Toggle Integration

    /// Called when the user changes the Virtual Session toggle.
    ///
    /// When enabling: starts a new session (or keeps the existing one).
    /// When disabling: ends the active session.
    func handleToggleChanged(enabled: Bool) {
        if enabled {
            if activeSession == nil {
                startSession()
            }
        } else {
            endSession()
        }
    }

    // MARK: - Insight Recording

    /// Records a new insight into the active session.
    ///
    /// Determines whether the insight belongs to the active investigation
    /// or should start a new one based on structural affinity. Enforces
    /// storage bounds (insight count, character budget, investigation count).
    ///
    /// No-op if no session is active or the session has expired.
    ///
    /// - Parameters:
    ///   - understanding: What the user learned (1-sentence distillation).
    ///   - mode: The mode that produced this insight.
    ///   - context: Structural context for retrieval scoring.
    func recordInsight(
        understanding: String,
        mode: InsightMode,
        context: InsightContext
    ) {
        // Check preconditions.
        guard activeSession != nil else { return }
        if expireIfNeeded() { return }

        let insight = Insight(
            id: UUID(),
            timestamp: Date(),
            mode: mode,
            understanding: understanding,
            context: context
        )

        if activeSession!.investigations.isEmpty {
            // No investigations yet — start the first one.
            startNewInvestigation(with: insight, context: context)
        } else if shouldStartNewInvestigation(newContext: context) {
            // Low structural affinity — start a new investigation.
            startNewInvestigation(with: insight, context: context)
        } else {
            // Append to active investigation.
            appendToActiveInvestigation(insight: insight, context: context)
        }

        // Evolve working memory with the new understanding.
        evolveWorkingMemory(newUnderstanding: understanding, context: context)

        // Enforce storage bounds.
        enforceStorageLimits()

        save()
    }

    // MARK: - Investigation Boundary Detection

    /// Determines whether a new insight should start a new investigation
    /// based on structural affinity with the active investigation's anchor.
    func shouldStartNewInvestigation(newContext: InsightContext) -> Bool {
        guard let active = activeSession?.activeInvestigation else { return true }
        let anchor = active.anchor

        // If no structural content in anchor, can't compare — continue.
        guard !anchor.isEmpty else { return true }

        // Any file overlap → continue the investigation.
        if let fp = newContext.filePath, anchor.filePaths.contains(fp) {
            return false
        }

        // Any entity overlap → continue.
        if let en = newContext.entityName, anchor.entityNames.contains(en) {
            return false
        }

        // Current entity is a known relationship target → continue.
        if let en = newContext.entityName, anchor.relatedEntityNames.contains(en) {
            return false
        }

        // New context's related entities overlap with anchor's known entities → continue.
        if !newContext.relatedEntities.isEmpty {
            let overlap = newContext.relatedEntities.contains { anchor.entityNames.contains($0) }
            if overlap { return false }
        }

        // Module + layer overlap → probably related.
        let moduleOverlap = newContext.moduleName.map { anchor.moduleNames.contains($0) } ?? false
        let layerOverlap = newContext.layer.map { anchor.layers.contains($0) } ?? false

        if moduleOverlap && layerOverlap {
            return false
        }

        // Module overlap alone with >2 entities already → still related.
        if moduleOverlap && anchor.entityNames.count > 2 {
            return false
        }

        // No structural connection → new investigation.
        return true
    }

    // MARK: - Retrieval API (Milestone 2)

    /// Minimum score threshold for an insight to be included in retrieval results.
    /// Insights below this score are not relevant enough to inject into the prompt.
    static let minimumRetrievalScore: Double = 0.2

    /// Maximum character budget for the formatted insight block.
    /// Keeps prompt augmentation bounded regardless of session size.
    static let maxInsightBlockCharacters = 800

    /// Returns insights from the active session that are relevant to the given context,
    /// ordered by descending structural affinity score.
    ///
    /// Scoring is based on structural overlap between the query context and each
    /// insight's context: file path match (highest signal), entity overlap,
    /// related entity overlap, module + layer match, and module-only match.
    /// Only insights scoring above ``minimumRetrievalScore`` are returned.
    ///
    /// The result set is bounded by ``maxInsightBlockCharacters`` — insights are
    /// included in score order until the character budget would be exceeded.
    func relevantInsights(for context: InsightContext) -> [Insight] {
        guard let session = activeSession else { return [] }

        let allInsights = session.investigations.flatMap { $0.insights }
        guard !allInsights.isEmpty else { return [] }

        // Score and filter.
        var scored: [(Insight, Double)] = []
        for insight in allInsights {
            let score = affinityScore(query: context, insight: insight.context)
            if score >= Self.minimumRetrievalScore {
                scored.append((insight, score))
            }
        }

        // Sort by score descending, then by recency (most recent first for ties).
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.timestamp > b.0.timestamp
        }

        // Apply character budget.
        var result: [Insight] = []
        var charCount = 0
        for (insight, _) in scored {
            let newCount = charCount + insight.understanding.count
            if newCount > Self.maxInsightBlockCharacters && !result.isEmpty {
                break
            }
            result.append(insight)
            charCount = newCount
        }

        return result
    }

    /// Formats relevant insights as a prompt-injectable block.
    ///
    /// Returns nil when no relevant insights exist or the session is inactive.
    /// The block format is designed for system prompt injection:
    ///
    /// ```
    /// INVESTIGATION CONTEXT (from earlier in this session):
    /// - <understanding text>
    /// - <understanding text>
    /// Build on these insights. Do not repeat them.
    /// ```
    func formatInsightBlock(for context: InsightContext) -> String? {
        // Prefer investigation-level knowledge when available.
        if let investigation = bestMatchingInvestigation(for: context),
           let understanding = investigation.currentUnderstanding,
           !understanding.isEmpty {
            lastRetrievedInsights = investigation.insights
            var block = "INVESTIGATION CONTEXT (from earlier in this session):\n"
            block += understanding + "\n"
            block += "Build on this understanding. Do not repeat it."
            return block
        }

        // Fall back to insight-level retrieval (legacy sessions or cross-investigation).
        let insights = relevantInsights(for: context)
        lastRetrievedInsights = insights
        guard !insights.isEmpty else { return nil }

        var block = "INVESTIGATION CONTEXT (from earlier in this session):\n"
        for insight in insights {
            block += "- \(insight.understanding)\n"
        }
        block += "Build on these insights. Do not repeat them."
        return block
    }

    /// Returns the investigation with the highest average affinity to the query context.
    ///
    /// Only returns an investigation if at least one of its insights scores above
    /// the minimum retrieval threshold.
    private func bestMatchingInvestigation(for context: InsightContext) -> Investigation? {
        guard let session = activeSession else { return nil }

        var bestInvestigation: Investigation?
        var bestScore: Double = 0

        for investigation in session.investigations {
            guard !investigation.insights.isEmpty else { continue }

            // Use the max score across insights in this investigation.
            var maxScore: Double = 0
            for insight in investigation.insights {
                let score = affinityScore(query: context, insight: insight.context)
                if score > maxScore { maxScore = score }
            }

            if maxScore >= Self.minimumRetrievalScore && maxScore > bestScore {
                bestScore = maxScore
                bestInvestigation = investigation
            }
        }

        return bestInvestigation
    }

    // MARK: - Affinity Scoring

    /// Computes a structural affinity score between a query context and an insight context.
    ///
    /// Score components (max 1.0):
    /// - File path match: 0.5
    /// - Entity name overlap: 0.3
    /// - Related entity overlap: 0.2
    /// - Module + layer match: 0.15
    /// - Module-only match: 0.1
    /// - Same source app (Selection/Screenshot): 0.05
    ///
    /// Scores are additive and capped at 1.0.
    func affinityScore(query: InsightContext, insight: InsightContext) -> Double {
        var score = 0.0

        // File path match — strongest signal.
        if let qfp = query.filePath, let ifp = insight.filePath, qfp == ifp {
            score += 0.5
        }

        // Entity name overlap.
        if let qen = query.entityName, let ien = insight.entityName, qen == ien {
            score += 0.3
        }

        // Related entity overlap: query's entity appears in insight's related, or vice versa.
        if let qen = query.entityName, insight.relatedEntities.contains(qen) {
            score += 0.2
        } else if let ien = insight.entityName, query.relatedEntities.contains(ien) {
            score += 0.2
        } else if !query.relatedEntities.isEmpty && !insight.relatedEntities.isEmpty {
            let overlap = query.relatedEntities.contains { insight.relatedEntities.contains($0) }
            if overlap { score += 0.15 }
        }

        // Module + layer match.
        if let qm = query.moduleName, let im = insight.moduleName, qm == im {
            if let ql = query.layer, let il = insight.layer, ql == il {
                score += 0.15
            } else {
                score += 0.1
            }
        }

        // Same source app — weak signal for Selection/Screenshot modes.
        if let qsa = query.sourceApp, let isa = insight.sourceApp, qsa == isa {
            score += 0.05
        }

        return min(score, 1.0)
    }

    // MARK: - Persistence

    /// The default file URL: `~/Library/Application Support/Decode/virtual-session.json`.
    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Decode", isDirectory: true)
        return appSupport.appendingPathComponent("virtual-session.json")
    }

    /// Restores the active session from disk.
    ///
    /// Called during ``AppDependencies.performDeferredStartup()``.
    /// If the persisted session is expired, it is discarded.
    /// If the toggle is disabled, any persisted session is cleared.
    func restore() {
        guard isEnabled else {
            // Toggle is off — clear any leftover persisted state.
            deletePersisted()
            activeSession = nil
            return
        }

        guard let loaded = Self.load(from: persistenceURL) else {
            // No persisted session — start fresh if enabled.
            startSession()
            return
        }

        activeSession = loaded

        if expireIfNeeded() {
            // Expired — start fresh.
            startSession()
        }

        #if DEBUG
        if let session = activeSession {
            print("[VirtualSession] Restored session: \(session.id) (\(session.totalInsightCount) insights, \(session.investigations.count) investigations)")
        }
        #endif
    }

    /// Restore session from disk without blocking the main actor.
    ///
    /// File I/O runs on a background thread. Session logic (expiration,
    /// fresh start) runs on `@MainActor` after the read completes.
    /// If `activeSession` was set by another code path before the read
    /// finishes, the loaded data is discarded to avoid overwriting
    /// newer state.
    func restoreAsync() async {
        guard isEnabled else {
            deletePersisted()
            activeSession = nil
            return
        }

        let url = persistenceURL
        let loaded: VirtualSession? = await Task.detached {
            Self.load(from: url)
        }.value

        // Guard against stale-state overwrite: if something set
        // activeSession while we were reading from disk, don't clobber it.
        guard activeSession == nil else { return }

        guard let loaded else {
            startSession()
            return
        }

        activeSession = loaded

        if expireIfNeeded() {
            startSession()
        }

        #if DEBUG
        if let session = activeSession {
            print("[VirtualSession] Restored session (async): \(session.id) (\(session.totalInsightCount) insights, \(session.investigations.count) investigations)")
        }
        #endif
    }

    /// Saves the active session to disk.
    ///
    /// Uses atomic writes to prevent partial writes on crash or power loss.
    /// Called after every mutation (same incremental persistence as SessionState).
    func save() {
        guard let session = activeSession else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[VirtualSession] Failed to save: \(error)")
            #endif
        }
    }

    // MARK: - Private

    private func startNewInvestigation(with insight: Insight, context: InsightContext) {
        var anchor = InvestigationAnchor.empty
        anchor.absorb(context: context)

        let theme = buildInitialTheme(context: context)

        // Build initial knowledge from the first insight.
        let sentences = Self.decomposeSentences(insight.understanding)
        let knowledgeSentences = sentences.map { KnowledgeSentence(text: $0, reinforcementCount: 0) }
        let currentUnderstanding = sentences.isEmpty ? nil : sentences.joined(separator: "\n")

        var knownFiles: Set<String> = []
        if let fn = context.fileName { knownFiles.insert(fn) }

        var knownEntities: Set<String> = []
        if let en = context.entityName { knownEntities.insert(en) }
        for re in context.relatedEntities { knownEntities.insert(re) }

        let investigation = Investigation(
            id: UUID(),
            startedAt: Date(),
            theme: theme,
            insights: [insight],
            anchor: anchor,
            currentUnderstanding: currentUnderstanding,
            knowledgeSentences: knowledgeSentences.isEmpty ? nil : knowledgeSentences,
            knownFiles: knownFiles.isEmpty ? nil : knownFiles,
            knownEntities: knownEntities.isEmpty ? nil : knownEntities
        )

        activeSession?.investigations.append(investigation)

        #if DEBUG
        print("[VirtualSession] New investigation started: \(theme)")
        #endif
    }

    private func appendToActiveInvestigation(insight: Insight, context: InsightContext) {
        guard var session = activeSession,
              !session.investigations.isEmpty else { return }

        let lastIndex = session.investigations.count - 1
        session.investigations[lastIndex].insights.append(insight)
        session.investigations[lastIndex].anchor.absorb(context: context)

        // Evolve the investigation's living knowledge.
        evolveKnowledge(for: &session.investigations[lastIndex], newUnderstanding: insight.understanding)

        // Accumulate known files and entities.
        if let fn = context.fileName {
            if session.investigations[lastIndex].knownFiles == nil {
                session.investigations[lastIndex].knownFiles = []
            }
            session.investigations[lastIndex].knownFiles?.insert(fn)
        }
        if let en = context.entityName {
            if session.investigations[lastIndex].knownEntities == nil {
                session.investigations[lastIndex].knownEntities = []
            }
            session.investigations[lastIndex].knownEntities?.insert(en)
        }
        for re in context.relatedEntities {
            if session.investigations[lastIndex].knownEntities == nil {
                session.investigations[lastIndex].knownEntities = []
            }
            session.investigations[lastIndex].knownEntities?.insert(re)
        }

        // Update theme if the investigation has expanded scope.
        updateTheme(for: &session.investigations[lastIndex])

        activeSession = session
    }

    private func buildInitialTheme(context: InsightContext) -> String {
        if let fileName = context.fileName {
            return "Understanding \(fileName)"
        }
        if let entityName = context.entityName {
            return "Understanding \(entityName)"
        }
        if let sourceApp = context.sourceApp {
            return "Investigating code in \(sourceApp)"
        }
        return "Code investigation"
    }

    private func updateTheme(for investigation: inout Investigation) {
        let anchor = investigation.anchor

        if anchor.moduleNames.count >= 3 {
            let modules = anchor.moduleNames.sorted().joined(separator: ", ")
            investigation.theme = "Architectural investigation across \(modules)"
        } else if anchor.filePaths.count > 1 {
            let moduleName = anchor.moduleNames.first
            if let moduleName {
                investigation.theme = "Investigating \(moduleName) relationships"
            } else {
                investigation.theme = "Cross-file investigation"
            }
        }
        // Single-file investigation keeps its initial theme.
    }

    /// Enforces storage bounds by evicting the oldest data.
    private func enforceStorageLimits() {
        guard var session = activeSession else { return }

        // 1. Enforce investigation count limit — evict oldest.
        while session.investigations.count > VirtualSession.maxInvestigationCount {
            session.investigations.removeFirst()
        }

        // 2. Enforce total insight count — evict oldest insights from oldest investigations.
        while session.totalInsightCount > VirtualSession.maxInsightCount {
            guard !session.investigations.isEmpty else { break }
            if session.investigations[0].insights.isEmpty {
                session.investigations.removeFirst()
            } else {
                session.investigations[0].insights.removeFirst()
                // Remove empty investigations after eviction.
                if session.investigations[0].insights.isEmpty {
                    session.investigations.removeFirst()
                }
            }
        }

        // 3. Enforce total character budget — evict oldest insights.
        while session.totalCharacterCount > VirtualSession.maxTotalCharacters {
            guard !session.investigations.isEmpty else { break }
            if session.investigations[0].insights.isEmpty {
                session.investigations.removeFirst()
            } else {
                session.investigations[0].insights.removeFirst()
                if session.investigations[0].insights.isEmpty {
                    session.investigations.removeFirst()
                }
            }
        }

        activeSession = session
    }

    // MARK: - Working Memory

    /// Programming-generic stop words excluded from topic keyword extraction.
    /// Superset of ``stopWords`` — includes terms that carry no topic signal
    /// in a software engineering context.
    nonisolated static let topicStopWords: Set<String> = stopWords.union([
        "function", "method", "class", "struct", "enum", "protocol", "type",
        "variable", "property", "parameter", "argument", "return", "returns",
        "value", "object", "instance", "static", "private", "public", "internal",
        "import", "module", "file", "code", "line", "call", "calls", "called",
        "uses", "used", "using", "use", "handles", "handle", "handled",
        "creates", "create", "created", "provides", "provide",
        "takes", "takes", "given", "passed", "defined", "defines",
        "implements", "implementation", "pattern", "data", "string", "int",
        "bool", "array", "dictionary", "set", "list", "map", "key",
        "error", "nil", "null", "true", "false", "self", "super",
        "new", "default", "custom", "specific", "based", "main", "first",
        "multiple", "single", "when", "where", "how", "what", "like",
        "through", "between", "within", "across", "any", "other", "some"
    ])

    /// Returns the current working memory's prompt injection block, or nil.
    ///
    /// Unlike ``formatInsightBlock(for:)`` which requires a context and scores
    /// relevance, working memory is unconditionally injected when non-empty.
    func workingMemoryBlock() -> String? {
        guard let wm = activeSession?.workingMemory,
              !wm.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var block = "WORKING MEMORY (your evolving understanding from this session):\n"
        block += wm.content + "\n"
        block += "Build on this understanding. Do not repeat it."
        return block
    }

    /// Evolves working memory with a new understanding from an explanation.
    ///
    /// Handles topic switching (reset) and sentence-level evolution.
    /// Called after ``recordInsight`` has completed investigation management.
    func evolveWorkingMemory(
        newUnderstanding: String,
        context: InsightContext
    ) {
        guard activeSession != nil else { return }

        // Check for topic switch.
        if shouldSwitchWorkingMemory(newContext: context, newUnderstanding: newUnderstanding) {
            // Reset working memory for the new topic.
            var wm = WorkingMemory.empty(anchoredTo: context)
            let sentences = Self.decomposeSentences(newUnderstanding)
            wm.sentences = sentences.map { KnowledgeSentence(text: $0, reinforcementCount: 0) }
            wm.content = sentences.isEmpty ? "" : sentences.joined(separator: "\n")
            wm.topicKeywords = Self.extractTopicKeywords(from: newUnderstanding)
            activeSession?.workingMemory = wm
            save()
            return
        }

        // Initialize working memory if nil (first insight or legacy session).
        if activeSession?.workingMemory == nil {
            var wm = WorkingMemory.empty(anchoredTo: context)
            let sentences = Self.decomposeSentences(newUnderstanding)
            wm.sentences = sentences.map { KnowledgeSentence(text: $0, reinforcementCount: 0) }
            wm.content = sentences.isEmpty ? "" : sentences.joined(separator: "\n")
            wm.topicKeywords = Self.extractTopicKeywords(from: newUnderstanding)
            activeSession?.workingMemory = wm
            save()
            return
        }

        // Evolve existing working memory.
        var wm = activeSession!.workingMemory!
        wm.anchor.absorb(context: context)

        // Sentence-level evolution (reuses the same algorithm as investigation knowledge).
        let newSentences = Self.decomposeSentences(newUnderstanding)
        for candidate in newSentences {
            let candidateScore = Self.informationScore(candidate)

            var bestIndex: Int?
            var bestOverlap: Double = 0

            for (i, ks) in wm.sentences.enumerated() {
                let overlap = Self.wordOverlap(candidate, ks.text)
                if overlap >= Self.sentenceOverlapThreshold && overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = i
                }
            }

            if let matchIndex = bestIndex {
                let existingScore = Self.informationScore(wm.sentences[matchIndex].text)
                if candidateScore > existingScore {
                    wm.sentences[matchIndex].text = candidate
                    wm.sentences[matchIndex].reinforcementCount = 0
                } else {
                    wm.sentences[matchIndex].reinforcementCount += 1
                }
            } else {
                wm.sentences.append(KnowledgeSentence(text: candidate, reinforcementCount: 0))
            }
        }

        // Accumulate topic keywords.
        let newKeywords = Self.extractTopicKeywords(from: newUnderstanding)
        for keyword in newKeywords where !wm.topicKeywords.contains(keyword) {
            wm.topicKeywords.append(keyword)
        }
        // FIFO eviction for topic keywords.
        while wm.topicKeywords.count > WorkingMemory.maxTopicKeywords {
            wm.topicKeywords.removeFirst()
        }

        // Deterministic eviction to stay within hard limit.
        wm.sentences = Self.evictToFitBudget(wm.sentences, budget: WorkingMemory.maxContentCharacters)
        wm.content = wm.sentences.isEmpty ? "" : wm.sentences.map(\.text).joined(separator: "\n")

        activeSession?.workingMemory = wm
        save()

        // Trigger async LLM compression if content exceeds limit.
        if wm.content.count > WorkingMemory.maxContentCharacters {
            triggerCompression()
        }
    }

    /// Determines whether working memory should be reset for a new topic.
    ///
    /// Two-layer approach:
    /// - **Layer 1 (structural)**: For contexts with structural fields (Session Mode),
    ///   uses the same anchor-based comparison as investigation boundary detection.
    /// - **Layer 2 (semantic)**: For minimal contexts (Selection/Screenshot),
    ///   compares topic keywords — zero overlap with ≥2 evidence words triggers switch.
    func shouldSwitchWorkingMemory(
        newContext: InsightContext,
        newUnderstanding: String
    ) -> Bool {
        guard let wm = activeSession?.workingMemory else { return false }

        // Layer 1: Structural switching for contexts with structural data.
        let hasStructure = newContext.filePath != nil || newContext.entityName != nil || newContext.moduleName != nil
        if hasStructure {
            // Reuse investigation boundary detection against the WM anchor.
            let anchor = wm.anchor
            guard !anchor.isEmpty else { return false }

            if let fp = newContext.filePath, anchor.filePaths.contains(fp) { return false }
            if let en = newContext.entityName, anchor.entityNames.contains(en) { return false }
            if let en = newContext.entityName, anchor.relatedEntityNames.contains(en) { return false }
            if !newContext.relatedEntities.isEmpty {
                if newContext.relatedEntities.contains(where: { anchor.entityNames.contains($0) }) { return false }
            }
            let moduleOverlap = newContext.moduleName.map { anchor.moduleNames.contains($0) } ?? false
            let layerOverlap = newContext.layer.map { anchor.layers.contains($0) } ?? false
            if moduleOverlap && layerOverlap { return false }
            if moduleOverlap && anchor.entityNames.count > 2 { return false }

            return true
        }

        // Layer 2: Semantic switching for minimal contexts (Selection/Screenshot).
        guard !wm.topicKeywords.isEmpty else { return false }

        let newKeywords = Self.extractTopicKeywords(from: newUnderstanding)
        guard newKeywords.count >= 2 else { return false }

        let existingSet = Set(wm.topicKeywords)
        let overlap = newKeywords.filter { existingSet.contains($0) }

        return overlap.isEmpty
    }

    /// Extracts topic-significant keywords from an understanding string.
    ///
    /// Filters out programming-generic stop words (``topicStopWords``), short
    /// words (<3 chars), and numbers. Returns unique keywords in order of appearance.
    nonisolated static func extractTopicKeywords(from text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var keywords: [String] = []

        for word in words {
            guard word.count >= 3 else { continue }
            guard !topicStopWords.contains(word) else { continue }
            guard !word.allSatisfy(\.isNumber) else { continue }
            if seen.insert(word).inserted {
                keywords.append(word)
            }
        }

        return keywords
    }

    // MARK: - Working Memory Compression

    /// Triggers async LLM compression of working memory.
    ///
    /// Cancels any in-flight compression. The compressed result is validated
    /// (30–250 chars) before replacing the current content. On failure (no
    /// provider, LLM error, invalid response), falls back to deterministic
    /// eviction to stay under budget.
    private func triggerCompression() {
        compressionTask?.cancel()
        compressionTask = Task {
            await performCompression()
        }
    }

    /// Performs the actual LLM compression of working memory.
    private func performCompression() async {
        guard var wm = activeSession?.workingMemory,
              !wm.content.isEmpty else { return }

        guard let provider = aiProvider?() else {
            // No provider — deterministic fallback.
            deterministicCompress()
            return
        }

        let contentToCompress = wm.content
        let prompt = """
            Compress the following working memory into a dense summary under \
            \(WorkingMemory.compressionTargetCharacters) characters. Preserve all \
            key technical facts, entity names, and relationships. Remove filler \
            and redundancy. Output ONLY the compressed summary, no preamble.

            Working memory:
            \(contentToCompress)
            """

        do {
            let response = try await provider.generateCompletion(
                userContent: prompt,
                systemPrompt: "You are a precise technical summarizer. Output only the compressed summary.",
                mode: "compression"
            )

            // Validate response.
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 30 && trimmed.count <= WorkingMemory.compressionTargetCharacters else {
                #if DEBUG
                print("[VirtualSession] Compression response invalid length (\(trimmed.count) chars) — falling back")
                #endif
                deterministicCompress()
                return
            }

            // Check that we haven't been cancelled or session ended.
            guard activeSession?.workingMemory != nil else { return }

            // Apply compressed content.
            let compressedSentences = Self.decomposeSentences(trimmed)
            wm = activeSession!.workingMemory!
            wm.content = trimmed
            wm.sentences = compressedSentences.map { KnowledgeSentence(text: $0, reinforcementCount: 0) }
            wm.compressionCount += 1
            activeSession?.workingMemory = wm
            save()

            #if DEBUG
            print("[VirtualSession] Compressed working memory: \(contentToCompress.count) → \(trimmed.count) chars (compression #\(wm.compressionCount))")
            #endif
        } catch {
            #if DEBUG
            print("[VirtualSession] Compression failed: \(error.localizedDescription) — falling back")
            #endif
            deterministicCompress()
        }
    }

    /// Deterministic fallback compression: aggressively evict least-important
    /// sentences until content fits within the compression target.
    private func deterministicCompress() {
        guard var wm = activeSession?.workingMemory else { return }
        wm.sentences = Self.evictToFitBudget(wm.sentences, budget: WorkingMemory.compressionTargetCharacters)
        wm.content = wm.sentences.isEmpty ? "" : wm.sentences.map(\.text).joined(separator: "\n")
        wm.compressionCount += 1
        activeSession?.workingMemory = wm
        save()

        #if DEBUG
        print("[VirtualSession] Deterministic compression: evicted to \(wm.content.count) chars")
        #endif
    }

    // MARK: - Understanding Extraction

    /// Maximum character length for an extracted understanding string.
    /// Prevents storing excessively long paragraphs as investigation knowledge.
    nonisolated static let maxUnderstandingLength = 200

    /// Extracts the best available understanding from a raw LLM explanation.
    ///
    /// Uses a ranked extraction pipeline (no LLM call, fully deterministic):
    /// 1. `<tldr>` tag content (highest quality when present)
    /// 2. First meaningful paragraph (skipping section headers)
    /// 3. First meaningful sentence
    /// 4. Generic fallback (last resort)
    ///
    /// The result is cleaned: markdown formatting removed, XML tags stripped,
    /// whitespace normalized, trimmed to ``maxUnderstandingLength`` at a word boundary.
    ///
    /// - Parameters:
    ///   - explanationText: The full raw explanation text from the LLM stream.
    ///   - sourceApp: The source application name for the generic fallback.
    /// - Returns: A clean natural-language understanding string.
    nonisolated static func extractUnderstanding(
        from explanationText: String,
        sourceApp: String?
    ) -> String {
        let fallback = "Explored code selected in \(sourceApp ?? "an application")"

        guard !explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        // Strategy 1: TLDR tag.
        if let tldr = ExplanationTagParser.extractTLDR(from: explanationText) {
            return cleanAndTruncate(tldr)
        }

        // Strategy 2: First meaningful paragraph.
        if let paragraph = extractFirstParagraph(from: explanationText) {
            let cleaned = cleanAndTruncate(paragraph)
            if isMeaningful(cleaned) {
                return cleaned
            }
        }

        // Strategy 3: First meaningful sentence from any paragraph.
        if let sentence = extractFirstSentence(from: explanationText) {
            let cleaned = cleanAndTruncate(sentence)
            if isMeaningful(cleaned) {
                return cleaned
            }
        }

        // Strategy 4: Generic fallback.
        return fallback
    }

    /// Extracts the first meaningful paragraph from explanation text.
    ///
    /// Splits on blank lines. Skips lines that are purely markdown section
    /// headers (`**Bold Label**` on its own line). Returns the first paragraph
    /// that contains actual content.
    nonisolated static func extractFirstParagraph(from text: String) -> String? {
        // Split into paragraphs (separated by blank lines).
        let paragraphs = text.components(separatedBy: "\n\n")

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Split paragraph into lines and filter out section headers.
            let lines = trimmed.components(separatedBy: .newlines)
            var contentLines: [String] = []

            for line in lines {
                let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
                guard !lineTrimmed.isEmpty else { continue }

                // Skip markdown section headers: lines that are just **Bold Text**
                if isSectionHeader(lineTrimmed) { continue }

                // Skip bullet points — they're detail, not summary.
                if lineTrimmed.hasPrefix("•") || lineTrimmed.hasPrefix("- ") ||
                   lineTrimmed.hasPrefix("* ") {
                    continue
                }

                // Skip numbered list items.
                if lineTrimmed.first?.isNumber == true &&
                   lineTrimmed.dropFirst().hasPrefix(". ") {
                    continue
                }

                contentLines.append(lineTrimmed)
            }

            if !contentLines.isEmpty {
                return contentLines.joined(separator: " ")
            }
        }

        return nil
    }

    /// Extracts the first meaningful sentence from explanation text.
    ///
    /// Scans all lines for the first sentence (ending with period followed
    /// by space or end of string), skipping section headers and bullets.
    nonisolated static func extractFirstSentence(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if isSectionHeader(trimmed) { continue }
            if trimmed.hasPrefix("•") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                continue
            }

            // Find the first sentence boundary.
            let chars = Array(trimmed)
            for (i, char) in chars.enumerated() {
                if char == "." {
                    let isEnd = i == chars.count - 1
                    let followedBySpace = i + 1 < chars.count && chars[i + 1] == " "
                    if isEnd || followedBySpace {
                        let sentence = String(chars[...i])
                        let cleaned = sentence.trimmingCharacters(in: .whitespaces)
                        if cleaned.split(separator: " ").count >= 3 {
                            return cleaned
                        }
                    }
                }
            }

            // No period found — if the line itself is meaningful, return it.
            if trimmed.split(separator: " ").count >= 4 {
                return trimmed
            }
        }

        return nil
    }

    /// Whether a line is a markdown section header (e.g., `**Quick Explanation**`).
    ///
    /// Matches lines that are entirely bold text with no other content,
    /// such as `**Key Insight**`, `**Risks / Edge Cases**`, etc.
    nonisolated private static func isSectionHeader(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)

        // Pattern: starts with ** and ends with ** (entire line is bold).
        if stripped.hasPrefix("**") && stripped.hasSuffix("**") {
            let inner = stripped.dropFirst(2).dropLast(2)
            // Must have some content and no additional ** (not nested bold).
            return !inner.isEmpty && !inner.contains("**")
        }

        return false
    }

    /// Cleans extracted text by removing markdown formatting, XML tags,
    /// and normalizing whitespace. Truncates at a word boundary if needed.
    nonisolated static func cleanAndTruncate(_ text: String) -> String {
        var result = text

        // Remove XML-style tags (e.g., <hl>, </hl>, <note>, </note>).
        result = result.replacingOccurrences(
            of: "</?[a-zA-Z][a-zA-Z0-9]*>",
            with: "",
            options: .regularExpression
        )

        // Remove markdown bold (**text** → text).
        result = result.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "$1",
            options: .regularExpression
        )

        // Remove markdown inline code (`text` → text).
        result = result.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )

        // Normalize whitespace (collapse runs of spaces/newlines into single space).
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate at word boundary if over limit.
        if result.count > maxUnderstandingLength {
            result = truncateAtWordBoundary(result, maxLength: maxUnderstandingLength)
        }

        return result
    }

    /// Truncates text at a word or sentence boundary, preferring sentence boundaries.
    nonisolated private static func truncateAtWordBoundary(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }

        let prefix = String(text.prefix(maxLength))

        // Try to break at the last period within the prefix.
        if let lastPeriod = prefix.lastIndex(of: ".") {
            let distance = prefix.distance(from: prefix.startIndex, to: lastPeriod)
            if distance > maxLength / 3 { // Don't truncate to a tiny fragment.
                return String(prefix[...lastPeriod])
            }
        }

        // Break at the last space.
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }

        return prefix
    }

    /// Whether extracted text is meaningful (not just noise/formatting artifacts).
    nonisolated private static func isMeaningful(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count >= 3
    }

    // MARK: - Knowledge Evolution

    /// Maximum character budget for an investigation's `currentUnderstanding`.
    nonisolated static let maxUnderstandingCharacters = 600

    /// Minimum word-overlap ratio to consider two sentences as covering the same ground.
    nonisolated static let sentenceOverlapThreshold: Double = 0.6

    /// Common stop words excluded from information-density scoring.
    nonisolated static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "in", "on", "to", "of",
        "for", "and", "or", "by", "with", "that", "this", "it", "from", "as",
        "at", "be", "has", "have", "had", "not", "but", "its", "also", "can",
        "will", "does", "do", "if", "when", "which", "each", "all", "into",
        "than", "then", "been", "being", "so", "no", "only", "very", "just"
    ]

    /// Evolves an investigation's `currentUnderstanding` by integrating new knowledge.
    ///
    /// For each sentence in the new understanding:
    /// - If it overlaps heavily with an existing sentence and is **richer**
    ///   (more meaningful words), it **replaces** the existing sentence.
    /// - If it overlaps heavily but is **not richer**, the existing sentence
    ///   is **reinforced** (making it harder to evict).
    /// - If it has no high overlap with any existing sentence, it is **appended**
    ///   as genuinely new knowledge.
    ///
    /// After integration, if the understanding exceeds the character budget,
    /// the least important sentence is evicted based on information density,
    /// reinforcement count, and recency.
    func evolveKnowledge(for investigation: inout Investigation, newUnderstanding: String) {
        let newSentences = Self.decomposeSentences(newUnderstanding)
        guard !newSentences.isEmpty else { return }

        // Bootstrap knowledge sentences from nil (legacy investigation).
        if investigation.knowledgeSentences == nil {
            investigation.knowledgeSentences = []
        }

        var existing = investigation.knowledgeSentences!

        for candidate in newSentences {
            let candidateScore = Self.informationScore(candidate)

            // Find the best-matching existing sentence.
            var bestIndex: Int?
            var bestOverlap: Double = 0

            for (i, ks) in existing.enumerated() {
                let overlap = Self.wordOverlap(candidate, ks.text)
                if overlap >= Self.sentenceOverlapThreshold && overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = i
                }
            }

            if let matchIndex = bestIndex {
                // High overlap found — compare information density.
                let existingScore = Self.informationScore(existing[matchIndex].text)
                if candidateScore > existingScore {
                    // New sentence is richer → replace.
                    existing[matchIndex].text = candidate
                    // Reset reinforcement since the content changed.
                    existing[matchIndex].reinforcementCount = 0
                } else {
                    // Existing sentence is richer or equal → reinforce.
                    existing[matchIndex].reinforcementCount += 1
                }
            } else {
                // No match → genuinely new knowledge.
                existing.append(KnowledgeSentence(text: candidate, reinforcementCount: 0))
            }
        }

        // Evict least-important sentences until within character budget.
        existing = Self.evictToFitBudget(existing, budget: Self.maxUnderstandingCharacters)

        investigation.knowledgeSentences = existing
        investigation.currentUnderstanding = existing.isEmpty ? nil : existing.map(\.text).joined(separator: "\n")
    }

    // MARK: - Sentence Decomposition

    /// Splits text into individual knowledge sentences.
    ///
    /// Handles period-delimited sentences and newline-delimited statements.
    /// Filters out trivially short fragments (< 3 words).
    nonisolated static func decomposeSentences(_ text: String) -> [String] {
        // First split by newlines, then by sentence-ending punctuation.
        var sentences: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split on sentence-ending punctuation followed by a space or end-of-string.
            let parts = splitSentences(trimmed)
            for part in parts {
                let cleaned = part.trimmingCharacters(in: .whitespaces)
                // Filter trivially short fragments.
                let wordCount = cleaned.split(separator: " ").count
                if wordCount >= 3 {
                    sentences.append(cleaned)
                }
            }
        }
        return sentences
    }

    /// Splits a single line into sentences on period boundaries.
    nonisolated private static func splitSentences(_ text: String) -> [String] {
        var results: [String] = []
        var current = ""
        let chars = Array(text)

        for (i, char) in chars.enumerated() {
            current.append(char)
            if char == "." {
                // Check if this looks like a sentence boundary:
                // followed by space+uppercase, or end of string.
                let isEnd = i == chars.count - 1
                let isFollowedBySpace = i + 1 < chars.count && chars[i + 1] == " "
                let isFollowedByUpper = i + 2 < chars.count && chars[i + 2].isUppercase

                if isEnd || (isFollowedBySpace && (isFollowedByUpper || i + 2 >= chars.count)) {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                    current = ""
                }
            }
        }

        // Remaining text that didn't end with a period.
        let remaining = current.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            results.append(remaining)
        }

        return results
    }

    // MARK: - Word Overlap

    /// Computes word-overlap ratio between two sentences.
    ///
    /// `overlap(a, b) = |words(a) ∩ words(b)| / min(|words(a)|, |words(b)|)`
    ///
    /// Uses lowercased words for case-insensitive comparison.
    nonisolated static func wordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        let minCount = min(wordsA.count, wordsB.count)
        guard minCount > 0 else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        return Double(intersection) / Double(minCount)
    }

    // MARK: - Information Density

    /// Counts meaningful (non-stop) words in a sentence.
    ///
    /// Used to compare information density between two overlapping sentences.
    /// A sentence with more meaningful words carries more knowledge.
    nonisolated static func informationScore(_ text: String) -> Int {
        let words = text.lowercased().split(separator: " ").map(String.init)
        return words.filter { !stopWords.contains($0) }.count
    }

    // MARK: - Importance-Scored Eviction

    /// Computes an importance score for a knowledge sentence at a given position.
    ///
    /// Score components:
    /// - Meaningful word count × 0.5 (denser sentences carry more knowledge)
    /// - Reinforcement count × 2.0 (validated knowledge is harder to evict)
    /// - Recency bonus: +1.0 for the last sentence (most recently added/updated)
    nonisolated static func importanceScore(_ sentence: KnowledgeSentence, isLast: Bool) -> Double {
        let density = Double(informationScore(sentence.text)) * 0.5
        let reinforcement = Double(sentence.reinforcementCount) * 2.0
        let recency = isLast ? 1.0 : 0.0
        return density + reinforcement + recency
    }

    /// Evicts the least important sentences until total characters fit within budget.
    nonisolated static func evictToFitBudget(_ sentences: [KnowledgeSentence], budget: Int) -> [KnowledgeSentence] {
        var result = sentences
        while totalCharCount(result) > budget && result.count > 1 {
            // Find the sentence with the lowest importance score.
            var lowestIndex = 0
            var lowestScore = Double.infinity
            for (i, ks) in result.enumerated() {
                let isLast = (i == result.count - 1)
                let score = importanceScore(ks, isLast: isLast)
                if score < lowestScore {
                    lowestScore = score
                    lowestIndex = i
                }
            }
            result.remove(at: lowestIndex)
        }
        return result
    }

    /// Total character count across knowledge sentence texts.
    nonisolated private static func totalCharCount(_ sentences: [KnowledgeSentence]) -> Int {
        // Account for newline separators between sentences.
        let textChars = sentences.reduce(0) { $0 + $1.text.count }
        let separators = max(0, sentences.count - 1)
        return textChars + separators
    }

    private func deletePersisted() {
        try? FileManager.default.removeItem(at: persistenceURL)
    }

    /// Loads a VirtualSession from the given URL.
    ///
    /// `nonisolated static` so it can run from any isolation context
    /// (e.g., `Task.detached` during startup).
    nonisolated static func load(from url: URL) -> VirtualSession? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VirtualSession.self, from: data)
        } catch {
            #if DEBUG
            print("[VirtualSession] Failed to load (corrupt or incompatible): \(error)")
            #endif
            return nil
        }
    }
}
