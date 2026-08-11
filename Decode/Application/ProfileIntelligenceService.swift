// ProfileIntelligenceService.swift — Decode Application
//
// Long-term, local-only user learning that adapts to each individual user.
//
// Responsibilities:
// - Record observations at coordinator completion points (Phase 2)
// - Derive a UserProfile from accumulated observations (Phase 3)
// - Cache the derived profile, invalidating on new observations
//
// Observations are the source of truth. The profile is a derived, cached view.
// Derivation uses pure functions — no side effects, easily testable.

import Foundation
import os.log

private let profileLog = Logger(subsystem: "com.decode.app", category: "profile-intelligence")

/// Service for recording user behavior observations and deriving a learning profile.
///
/// Created during `AppDependencies.performDeferredStartup()` after the database
/// is initialized. Coordinators call ``recordObservation(context:mode:observationType:isFollowUp:)``
/// at the same completion points where `VirtualSessionManager.recordInsight()` is called.
///
/// The derived ``UserProfile`` is cached in memory and invalidated whenever a new
/// observation is recorded. Re-derivation is lazy — triggered on the next access.
@MainActor
final class ProfileIntelligenceService {

    // MARK: - Dependencies

    private let repository: ProfileObservationRepository

    // MARK: - Cache

    /// Cached derived profile. `nil` means cache is cold (needs re-derivation).
    private var cachedProfile: UserProfile?

    /// Whether the cache has been invalidated since the last derivation.
    private var cacheValid = false

    /// The last profile that was successfully synced to the backend.
    /// Used to avoid redundant sync calls when the profile hasn't changed.
    private var lastSyncedProfile: UserProfile?

    // MARK: - Init

    init(repository: ProfileObservationRepository) {
        self.repository = repository
    }

    // MARK: - Recording (Phase 2)

    /// Number of observations recorded in this session (diagnostic counter).
    private(set) var recordedCount: Int = 0

    /// Number of observations that failed to persist in this session.
    private(set) var failedCount: Int = 0

    /// Record a user behavior observation.
    ///
    /// Called at coordinator completion points — the same locations where
    /// `VirtualSessionManager.recordInsight()` is called. Accepts the
    /// existing `InsightContext` directly to avoid duplicate context extraction.
    ///
    /// Recording is asynchronous — the coordinator is never blocked. Failures
    /// are logged via `os.Logger` (visible in Console.app) and tracked in
    /// ``failedCount`` for developer inspection.
    func recordObservation(
        context: InsightContext,
        mode: String,
        observationType: ProfileObservationType,
        isFollowUp: Bool = false
    ) {
        let observation = ProfileObservation(
            context: context,
            mode: mode,
            observationType: observationType,
            isFollowUp: isFollowUp
        )

        // Invalidate cache before persisting — ensures the next profile
        // access re-derives even if the write is still in flight.
        cacheValid = false
        cachedProfile = nil

        Task { [repository, weak self] in
            do {
                try await repository.insert(observation)
                self?.recordedCount += 1
                #if DEBUG
                print("[ProfileIntelligence] Recorded \(observationType.rawValue) observation (mode=\(mode), language=\(context.language ?? "nil"), total=\(self?.recordedCount ?? 0))")
                #endif
            } catch {
                self?.failedCount += 1
                profileLog.error("Failed to record observation: \(error.localizedDescription, privacy: .public)")
                #if DEBUG
                assertionFailure("[ProfileIntelligence] Observation write failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Profile Access (Phase 3)

    /// Returns the current derived user profile.
    ///
    /// Uses an in-memory cache that is invalidated whenever a new observation
    /// is recorded. If the cache is cold, queries all observations from the
    /// repository and runs the pure derivation functions.
    ///
    /// Returns ``UserProfile.empty`` if the database query fails.
    func currentProfile() async -> UserProfile {
        if cacheValid, let cached = cachedProfile {
            return cached
        }

        do {
            let observations = try await repository.fetchAll()
            let profile = Self.deriveProfile(from: observations)
            cachedProfile = profile
            cacheValid = true
            syncProfileIfChanged(profile)
            return profile
        } catch {
            profileLog.error("Failed to fetch observations for derivation: \(error.localizedDescription, privacy: .public)")
            #if DEBUG
            assertionFailure("[ProfileIntelligence] Derivation fetch failed: \(error)")
            #endif
            return .empty
        }
    }

    /// Invalidates the cached profile, forcing re-derivation on next access.
    /// Useful for developer tooling and testing.
    func invalidateCache() {
        cacheValid = false
        cachedProfile = nil
    }

    /// Deletes all stored observations, resets diagnostic counters, and
    /// invalidates the cache. Used by developer tooling (Profile Inspector).
    func resetAllData() async throws {
        try await repository.deleteAll()
        invalidateCache()
        recordedCount = 0
        failedCount = 0
        profileLog.info("Profile Intelligence data reset")
    }

    // MARK: - Profile Sync

    /// Sync the derived profile to the backend if it has meaningfully changed.
    ///
    /// Uses `UserProfile.Equatable` conformance to detect changes. The actual
    /// network call is fire-and-forget via ``ProfileSyncService`` — it never
    /// blocks the explanation path.
    private func syncProfileIfChanged(_ profile: UserProfile) {
        // Skip sync for empty profiles — nothing useful to report.
        guard profile.totalObservationCount > 0 else { return }

        // Skip if the profile hasn't changed since last sync.
        // `derivedAt` changes on every re-derivation, so exclude it from comparison.
        // We compare the substantive content by checking observation count and
        // the sub-profiles directly.
        if let last = lastSyncedProfile,
           last.technology == profile.technology,
           last.learning == profile.learning,
           last.coding == profile.coding,
           last.interaction == profile.interaction,
           last.preference == profile.preference,
           last.project == profile.project,
           last.totalObservationCount == profile.totalObservationCount {
            return
        }

        lastSyncedProfile = profile
        ProfileSyncService.sync(profile: profile)
    }

    // MARK: - Derivation (Phase 3 — Pure Functions)

    /// Derive a complete UserProfile from observations. Pure function.
    static func deriveProfile(from observations: [ProfileObservation]) -> UserProfile {
        guard !observations.isEmpty else { return .empty }

        return UserProfile(
            technology: deriveTechnologyProfile(from: observations),
            learning: deriveLearningProfile(from: observations),
            coding: deriveCodingProfile(from: observations),
            interaction: deriveInteractionProfile(from: observations),
            preference: derivePreferenceProfile(from: observations),
            project: deriveProjectProfile(from: observations),
            totalObservationCount: observations.count,
            lastObservationDate: observations.last?.timestamp,
            derivedAt: Date(),
            profileVersion: UserProfile.currentProfileVersion
        )
    }

    /// Derive technology profile — languages and primary language.
    static func deriveTechnologyProfile(from observations: [ProfileObservation]) -> TechnologyProfile {
        var languageCounts: [String: Int] = [:]
        for obs in observations {
            if let lang = obs.language, !lang.isEmpty {
                languageCounts[lang, default: 0] += 1
            }
        }

        let languages = languageCounts
            .map { LanguageFrequency(language: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        let primaryLanguage: String?
        if let top = languages.first, top.count >= ProfileIntelligenceConfig.minObservationsForConfidence {
            primaryLanguage = top.language
        } else {
            primaryLanguage = nil
        }

        return TechnologyProfile(languages: languages, primaryLanguage: primaryLanguage)
    }

    /// Derive learning profile — entity types, layers, file roles, exploration breadth.
    static func deriveLearningProfile(from observations: [ProfileObservation]) -> LearningProfile {
        var entityTypeCounts: [String: Int] = [:]
        var layerCounts: [String: Int] = [:]
        var fileRoleCounts: [String: Int] = [:]
        var distinctFiles: Set<String> = []
        var distinctEntities: Set<String> = []

        for obs in observations {
            if let et = obs.entityType, !et.isEmpty {
                entityTypeCounts[et, default: 0] += 1
            }
            if let ly = obs.layer, !ly.isEmpty {
                layerCounts[ly, default: 0] += 1
            }
            if let fr = obs.fileRole, !fr.isEmpty {
                fileRoleCounts[fr, default: 0] += 1
            }
            if let fp = obs.filePath, !fp.isEmpty {
                distinctFiles.insert(fp)
            }
            if let en = obs.entityName, !en.isEmpty {
                distinctEntities.insert(en)
            }
        }

        let limit = ProfileIntelligenceConfig.maxFrequentItems

        let frequentEntityTypes = entityTypeCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)

        let frequentLayers = layerCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)

        let frequentFileRoles = fileRoleCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)

        return LearningProfile(
            frequentEntityTypes: Array(frequentEntityTypes),
            frequentLayers: Array(frequentLayers),
            frequentFileRoles: Array(frequentFileRoles),
            distinctFilesExplored: distinctFiles.count,
            distinctEntitiesExplored: distinctEntities.count
        )
    }

    /// Derive coding profile — follow-up rate and counts.
    static func deriveCodingProfile(from observations: [ProfileObservation]) -> CodingProfile {
        let followUps = observations.filter { $0.isFollowUp }
        let explanations = observations.filter { !$0.isFollowUp }

        let followUpRate: Double
        if !observations.isEmpty {
            followUpRate = Double(followUps.count) / Double(observations.count)
        } else {
            followUpRate = 0
        }

        return CodingProfile(
            followUpRate: followUpRate,
            followUpCount: followUps.count,
            explanationCount: explanations.count
        )
    }

    /// Derive interaction profile — mode usage and primary mode.
    static func deriveInteractionProfile(from observations: [ProfileObservation]) -> InteractionProfile {
        var modeCounts: [String: Int] = [:]
        for obs in observations {
            modeCounts[obs.mode, default: 0] += 1
        }

        let modeUsage = modeCounts
            .map { ModeFrequency(mode: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        let primaryMode: String?
        if let top = modeUsage.first, top.count >= ProfileIntelligenceConfig.minObservationsForConfidence {
            primaryMode = top.mode
        } else {
            primaryMode = nil
        }

        return InteractionProfile(
            modeUsage: modeUsage,
            primaryMode: primaryMode,
            totalInteractions: observations.count
        )
    }

    /// Derive preference profile — follow-up depth and session mode preference.
    static func derivePreferenceProfile(from observations: [ProfileObservation]) -> PreferenceProfile {
        let explanationCount = observations.filter { !$0.isFollowUp }.count
        let followUpCount = observations.filter { $0.isFollowUp }.count

        let averageFollowUps: Double
        if explanationCount > 0 {
            averageFollowUps = Double(followUpCount) / Double(explanationCount)
        } else {
            averageFollowUps = 0
        }

        let sessionCount = observations.filter { $0.mode == "session" }.count
        let sessionPreference: Double
        if observations.count >= ProfileIntelligenceConfig.minObservationsForConfidence {
            sessionPreference = Double(sessionCount) / Double(observations.count)
        } else {
            sessionPreference = 0
        }

        return PreferenceProfile(
            averageFollowUpsPerSession: averageFollowUps,
            sessionModePreference: sessionPreference
        )
    }

    /// Derive project profile — workspace frequency and source apps.
    static func deriveProjectProfile(from observations: [ProfileObservation]) -> ProjectProfile {
        var workspaceCounts: [String: Int] = [:]
        var sourceApps: Set<String> = []

        for obs in observations {
            if let wsID = obs.workspaceID, !wsID.isEmpty {
                workspaceCounts[wsID, default: 0] += 1
            }
            if let app = obs.sourceApp, !app.isEmpty {
                sourceApps.insert(app)
            }
        }

        let workspaceFrequency = workspaceCounts
            .map { WorkspaceFrequency(workspaceID: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        return ProjectProfile(
            workspaceFrequency: workspaceFrequency,
            distinctWorkspaceCount: workspaceCounts.count,
            sourceApps: Array(sourceApps).sorted()
        )
    }
}
