// VirtualSession.swift — Decode Domain
//
// Data models for Virtual Sessions — optional cross-mode investigation memory.
//
// A Virtual Session maintains a sequence of Investigations, each representing
// a living body of knowledge about a topic. Investigations store evolving
// knowledge (currentUnderstanding) synthesized from supporting evidence
// (Insights). Each new explanation refines the Investigation's knowledge
// rather than simply appending another record.
//
// All models are Codable, Sendable, and value types — suitable for JSON
// persistence following the SessionState pattern.

import Foundation

// MARK: - VirtualSession

/// A temporary investigation session spanning all Decode modes.
///
/// Contains a bounded sequence of ``Investigation`` threads. The session
/// starts when the user enables the Virtual Session toggle and ends when
/// they disable it or it expires due to inactivity.
struct VirtualSession: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var investigations: [Investigation]

    /// The session's working memory — a continuously evolving understanding
    /// of the current investigation topic, optimized for prompt injection.
    ///
    /// Unlike investigations (which organize knowledge by structural anchors),
    /// working memory is a single, bounded, always-current summary that is
    /// unconditionally injected into every prompt while active. Resets on
    /// topic switches.
    ///
    /// `nil` for legacy sessions that predate this field.
    var workingMemory: WorkingMemory?

    /// The most recent investigation, or nil if none exist.
    var activeInvestigation: Investigation? { investigations.last }

    /// Maximum number of insights retained across all investigations.
    static let maxInsightCount = 20

    /// Maximum total character budget across all insight understanding texts.
    static let maxTotalCharacters = 3000

    /// Maximum number of investigations per session.
    static let maxInvestigationCount = 5

    /// Inactivity duration after which the session expires (2 hours).
    static let expirationInterval: TimeInterval = 7200

    /// Total insight count across all investigations.
    var totalInsightCount: Int {
        investigations.reduce(0) { $0 + $1.insights.count }
    }

    /// Total character count across all insight understanding texts.
    var totalCharacterCount: Int {
        investigations.reduce(0) { total, investigation in
            total + investigation.insights.reduce(0) { $0 + $1.understanding.count }
        }
    }

    /// The timestamp of the most recent activity (latest insight or session start).
    var lastActivityTimestamp: Date {
        investigations.last?.insights.last?.timestamp ?? startedAt
    }

    /// Whether this session has expired due to inactivity.
    func isExpired(relativeTo now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastActivityTimestamp) > Self.expirationInterval
    }
}

// MARK: - Investigation

/// A coherent line of inquiry within a Virtual Session.
///
/// An investigation is a **living knowledge document** — it maintains a
/// synthesized `currentUnderstanding` that evolves as new explanations arrive.
/// Individual insights are preserved as supporting evidence but the
/// `currentUnderstanding` is the canonical knowledge representation.
///
/// An investigation starts implicitly when a new insight has low structural
/// affinity with the active investigation, and continues as long as insights
/// relate structurally (same file, module, entity relationships, etc.).
struct Investigation: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date

    /// 1-sentence characterization of the investigation, updated as insights accrue.
    var theme: String

    /// Ordered sequence of insights within this investigation (supporting evidence).
    var insights: [Insight]

    /// Structural anchor — the entity/file/module graph that this investigation
    /// revolves around. Updated as insights accrue.
    var anchor: InvestigationAnchor

    // MARK: - Living Knowledge (evolved from insights)

    /// The canonical knowledge representation for this investigation.
    ///
    /// Synthesized from individual insight understandings using sentence-level
    /// deduplication and information-density comparison. Updated every time a
    /// new insight is recorded. `nil` for legacy sessions that predate this field.
    var currentUnderstanding: String?

    /// Internal sentence-level tracking for the knowledge evolution algorithm.
    ///
    /// Each sentence in `currentUnderstanding` has a corresponding entry here
    /// that tracks reinforcement count for importance-scored eviction.
    /// `nil` for legacy sessions.
    var knowledgeSentences: [KnowledgeSentence]?

    /// File names this investigation has touched (e.g., "WorkspaceResolver.swift").
    /// Accumulated from insight contexts. `nil` for legacy sessions.
    var knownFiles: Set<String>?

    /// Entity names this investigation has built understanding about.
    /// Accumulated from insight contexts (entity names + related entities).
    /// `nil` for legacy sessions.
    var knownEntities: Set<String>?
}

// MARK: - KnowledgeSentence

/// A single sentence within an Investigation's `currentUnderstanding`,
/// with metadata for the knowledge evolution algorithm.
///
/// Tracks how many times later insights reinforced this sentence (high overlap
/// but lower information density, so the existing sentence was kept). Used for
/// importance-scored eviction when the character budget is exceeded.
struct KnowledgeSentence: Codable, Sendable, Equatable {

    /// The knowledge sentence text.
    var text: String

    /// How many times a later insight matched this sentence but did not replace it
    /// (because the existing sentence was richer). Higher = more foundational.
    var reinforcementCount: Int
}

// MARK: - WorkingMemory

/// A continuously evolving understanding of the current investigation topic.
///
/// Working Memory is a first-class concept separate from Investigations.
/// It is the **only** source of virtual session prompt injection —
/// investigations are archival, working memory is operational.
///
/// Key properties:
/// - **Bounded**: hard limit of 1000 characters, compressed to ~250 via LLM
/// - **Topic-aware**: resets when the user switches topics (structural anchor
///   change for Session Mode, topic keyword divergence for Selection/Screenshot)
/// - **Unconditional injection**: if content is non-empty, it is always injected
///   into the system prompt — no scoring, no threshold
struct WorkingMemory: Codable, Sendable, Equatable {

    /// The synthesized understanding text, ready for prompt injection.
    var content: String

    /// Sentence-level tracking for the knowledge evolution algorithm.
    /// Mirrors the `KnowledgeSentence` approach from Investigation.
    var sentences: [KnowledgeSentence]

    /// Structural anchor for topic boundary detection (Session Mode).
    /// When a new insight's context has zero structural overlap with this
    /// anchor, the working memory is reset.
    var anchor: InvestigationAnchor

    /// How many times this working memory has been LLM-compressed.
    /// Used for diagnostics and to avoid compression loops.
    var compressionCount: Int

    /// Accumulated topic keywords for semantic topic switching
    /// (Selection/Screenshot modes where structural context is minimal).
    ///
    /// Keywords are meaningful words extracted from each understanding,
    /// excluding programming-generic stop words. FIFO eviction at
    /// ``maxTopicKeywords``. Zero overlap with a new understanding's
    /// keywords (with ≥2 evidence words) triggers a topic switch.
    var topicKeywords: [String]

    /// Maximum number of topic keywords retained.
    static let maxTopicKeywords = 40

    /// Maximum character budget before compression is triggered.
    static let maxContentCharacters = 1000

    /// Target character count after LLM compression.
    static let compressionTargetCharacters = 250

    /// Creates an empty working memory anchored to the given context.
    static func empty(anchoredTo context: InsightContext) -> WorkingMemory {
        var anchor = InvestigationAnchor.empty
        anchor.absorb(context: context)
        return WorkingMemory(
            content: "",
            sentences: [],
            anchor: anchor,
            compressionCount: 0,
            topicKeywords: []
        )
    }
}

// MARK: - InvestigationAnchor

/// Structural knowledge accumulated across insights in an investigation.
///
/// The anchor evolves as new insights join the investigation, expanding the
/// set of known files, entities, modules, and relationships. Used for:
/// 1. Investigation boundary detection (should a new insight start a new investigation?)
/// 2. Retrieval scoring (which past insights are relevant to the current request?)
struct InvestigationAnchor: Codable, Sendable, Equatable {

    /// Primary file path(s) involved in this investigation.
    var filePaths: Set<String>

    /// Entity qualified names encountered (e.g., "WorkspaceResolver.resolve").
    var entityNames: Set<String>

    /// Module name(s) touched (e.g., "Application", "Infrastructure").
    var moduleNames: Set<String>

    /// Workspace ID, when available.
    var workspaceID: UUID?

    /// Architectural layer(s) touched (string representations of ArchitecturalLayer).
    var layers: Set<String>

    /// Relationship targets seen — entities this investigation has encountered
    /// as call targets, conformance targets, inheritance targets, etc.
    var relatedEntityNames: Set<String>

    /// Creates an empty anchor.
    static let empty = InvestigationAnchor(
        filePaths: [],
        entityNames: [],
        moduleNames: [],
        workspaceID: nil,
        layers: [],
        relatedEntityNames: []
    )

    /// Absorbs context from a new insight into this anchor.
    mutating func absorb(context: InsightContext) {
        if let fp = context.filePath { filePaths.insert(fp) }
        if let en = context.entityName { entityNames.insert(en) }
        if let mn = context.moduleName { moduleNames.insert(mn) }
        if let ly = context.layer { layers.insert(ly) }
        if let ws = context.workspaceID { workspaceID = ws }
        for re in context.relatedEntities {
            relatedEntityNames.insert(re)
        }
    }

    /// Whether this anchor has any structural content.
    var isEmpty: Bool {
        filePaths.isEmpty && entityNames.isEmpty && moduleNames.isEmpty
    }
}

// MARK: - Insight

/// A distilled understanding gained from a single Decode interaction.
///
/// An insight represents what the user *learned*, not what they *requested*.
/// The `understanding` field contains a concise characterization of the
/// knowledge gained, while `context` carries the structural metadata used
/// for retrieval scoring.
struct Insight: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let mode: InsightMode

    /// What the user learned — NOT a request log.
    /// Examples:
    ///   "WorkspaceResolver scores workspaces by entity containment,
    ///    with pinned workspace as unconditional override"
    ///   "The auth flow stores SHA-256 hash server-side, raw token client-side"
    let understanding: String

    /// Structural context — where this understanding came from.
    let context: InsightContext
}

/// The mode that produced an insight.
enum InsightMode: String, Codable, Sendable {
    case selection
    case screenshot
    case session
    case followUp = "follow_up"
}

// MARK: - InsightContext

/// Structural context for an insight, drawn from Decode's existing platform knowledge.
///
/// Every field maps to data already available in the coordinator at request time:
/// file intelligence, parsed entities, workspace resolution, etc. Used for
/// structural affinity scoring during retrieval.
struct InsightContext: Codable, Sendable, Equatable {

    /// Absolute file path, if known (Session Mode).
    let filePath: String?

    /// File name (e.g., "WorkspaceResolver.swift").
    let fileName: String?

    /// Resolved entity name (e.g., "WorkspaceResolver.resolve").
    let entityName: String?

    /// Entity type (e.g., "function", "class", "protocol").
    let entityType: String?

    /// Module name derived from directory (e.g., "Application").
    let moduleName: String?

    /// Architectural layer from FileIdentity (e.g., "application").
    let layer: String?

    /// File role from FileIdentity (e.g., "service", "coordinator").
    let fileRole: String?

    /// Detected programming language.
    let language: String?

    /// Source application name (e.g., "Xcode", "VS Code").
    let sourceApp: String?

    /// Workspace ID, when available.
    let workspaceID: UUID?

    /// Relationship targets from the entity's known relationships.
    /// Populated from FileIntelligence or DIR evidence when available.
    let relatedEntities: [String]

    /// Creates a minimal context with only source app information.
    /// Used for Selection and Screenshot modes where structural context is limited.
    static func minimal(sourceApp: String?) -> InsightContext {
        InsightContext(
            filePath: nil,
            fileName: nil,
            entityName: nil,
            entityType: nil,
            moduleName: nil,
            layer: nil,
            fileRole: nil,
            language: nil,
            sourceApp: sourceApp,
            workspaceID: nil,
            relatedEntities: []
        )
    }
}
