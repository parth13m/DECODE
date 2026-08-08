// UserProfile.swift — Decode Domain
//
// Data models for Profile Intelligence — long-term, local-only user learning
// that adapts explanation depth and context to each individual user.
//
// A UserProfile is derived from accumulated ProfileObservations. It is never
// mutated directly — observations are the source of truth, and the profile
// is re-derived on demand.
//
// All models are Codable, Sendable, Equatable — suitable for caching and
// transport across actor boundaries.

import Foundation

// MARK: - Configuration

/// Central configuration for Profile Intelligence.
///
/// All Profile Intelligence constants live here. Follows the ``AILimits``
/// pattern — no magic numbers in derivation logic.
enum ProfileIntelligenceConfig {

    /// Minimum observations required before a derived dimension is considered
    /// confident. Below this threshold, dimensions return defaults.
    static let minObservationsForConfidence = 5

    /// Maximum number of items returned in frequency-ranked lists
    /// (e.g., frequent entity types, frequent layers, frequent file roles).
    static let maxFrequentItems = 5

    /// Current observation schema version. Stored on every observation
    /// for future-proof re-derivation.
    static let currentSchemaVersion = 1
}

// MARK: - UserProfile

/// Composite user profile derived from accumulated observations.
///
/// Contains 6 sub-profiles, each capturing a different dimension of user behavior.
/// Dimensions with insufficient observations (below
/// ``ProfileIntelligenceConfig/minObservationsForConfidence``) return sensible
/// defaults rather than speculative values.
struct UserProfile: Codable, Sendable, Equatable {

    let technology: TechnologyProfile
    let learning: LearningProfile
    let coding: CodingProfile
    let interaction: InteractionProfile
    let preference: PreferenceProfile
    let project: ProjectProfile

    /// Total number of observations this profile was derived from.
    let totalObservationCount: Int

    /// Timestamp of the most recent observation.
    let lastObservationDate: Date?

    /// Timestamp when this profile was derived.
    let derivedAt: Date

    /// Profile derivation version — incremented when derivation logic changes,
    /// allowing callers to detect stale cached profiles.
    let profileVersion: Int

    /// Current derivation version. Increment when derivation logic changes.
    static let currentProfileVersion = 1

    /// An empty profile with all defaults — returned when no observations exist.
    static let empty = UserProfile(
        technology: .empty,
        learning: .empty,
        coding: .empty,
        interaction: .empty,
        preference: .empty,
        project: .empty,
        totalObservationCount: 0,
        lastObservationDate: nil,
        derivedAt: .distantPast,
        profileVersion: currentProfileVersion
    )
}

// MARK: - TechnologyProfile

/// Languages and frameworks the user works with, derived from observation frequency.
struct TechnologyProfile: Codable, Sendable, Equatable {

    /// Languages observed with their occurrence counts, sorted by frequency descending.
    let languages: [LanguageFrequency]

    /// The user's most frequently observed language, or nil if below confidence threshold.
    let primaryLanguage: String?

    static let empty = TechnologyProfile(languages: [], primaryLanguage: nil)
}

/// A language and how many times it has been observed.
struct LanguageFrequency: Codable, Sendable, Equatable {
    let language: String
    let count: Int
}

// MARK: - LearningProfile

/// Topics and areas the user explores, indicating familiarity patterns.
struct LearningProfile: Codable, Sendable, Equatable {

    /// Entity types the user most frequently asks about (e.g., "function", "class").
    let frequentEntityTypes: [String]

    /// Architectural layers the user engages with most (e.g., "application", "infrastructure").
    let frequentLayers: [String]

    /// File roles the user explores most (e.g., "coordinator", "service").
    let frequentFileRoles: [String]

    /// Number of distinct files the user has explored.
    let distinctFilesExplored: Int

    /// Number of distinct entities the user has explored.
    let distinctEntitiesExplored: Int

    static let empty = LearningProfile(
        frequentEntityTypes: [],
        frequentLayers: [],
        frequentFileRoles: [],
        distinctFilesExplored: 0,
        distinctEntitiesExplored: 0
    )
}

// MARK: - CodingProfile

/// Coding behavior patterns derived from observation metadata.
struct CodingProfile: Codable, Sendable, Equatable {

    /// How often the user asks follow-up questions (ratio of follow-ups to total).
    let followUpRate: Double

    /// Total number of follow-up observations.
    let followUpCount: Int

    /// Total number of explanation observations (non-follow-up).
    let explanationCount: Int

    static let empty = CodingProfile(
        followUpRate: 0,
        followUpCount: 0,
        explanationCount: 0
    )
}

// MARK: - InteractionProfile

/// How the user interacts with Decode across modes.
struct InteractionProfile: Codable, Sendable, Equatable {

    /// Mode usage counts (e.g., "selection": 42, "session": 18).
    let modeUsage: [ModeFrequency]

    /// The user's most frequently used mode, or nil if below confidence threshold.
    let primaryMode: String?

    /// Total number of interactions across all modes.
    let totalInteractions: Int

    static let empty = InteractionProfile(
        modeUsage: [],
        primaryMode: nil,
        totalInteractions: 0
    )
}

/// A mode and how many times it has been used.
struct ModeFrequency: Codable, Sendable, Equatable {
    let mode: String
    let count: Int
}

// MARK: - PreferenceProfile

/// Explanation style preferences inferred from behavior.
struct PreferenceProfile: Codable, Sendable, Equatable {

    /// Average number of follow-ups per explanation session — indicates
    /// preference for depth vs. brevity.
    let averageFollowUpsPerSession: Double

    /// Ratio of session mode usage to total — indicates preference for
    /// workspace-aware explanations.
    let sessionModePreference: Double

    static let empty = PreferenceProfile(
        averageFollowUpsPerSession: 0,
        sessionModePreference: 0
    )
}

// MARK: - ProjectProfile

/// Repositories and workspaces the user works in.
struct ProjectProfile: Codable, Sendable, Equatable {

    /// Workspace IDs the user has interacted with, with frequency.
    let workspaceFrequency: [WorkspaceFrequency]

    /// Number of distinct workspaces the user has interacted with.
    let distinctWorkspaceCount: Int

    /// Source applications the user works in (e.g., "Xcode", "VS Code").
    let sourceApps: [String]

    static let empty = ProjectProfile(
        workspaceFrequency: [],
        distinctWorkspaceCount: 0,
        sourceApps: []
    )
}

/// A workspace and how many times the user has interacted with it.
struct WorkspaceFrequency: Codable, Sendable, Equatable {
    let workspaceID: String
    let count: Int
}
